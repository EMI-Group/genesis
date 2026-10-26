#!/usr/bin/env bash
#
# desktop-smoke.sh — MANUAL, release-time smoke test for the packaged desktop app.
#
# Proves the REAL packaged artifact boots: the Tauri shell (in its `--headless`
# mode) resolves the bundled Elixir release, starts the BEAM and serves the
# dashboard over HTTP. Nothing else in the repo exercises the packaged release
# `vm.args`, the bundled ERTS or the sidecar layout, so this is the only test
# that can catch a boot-only failure — e.g. the release that shipped
# `+t 80000`, which exhausted the atom table and made the desktop app fail to
# start on ALL platforms with a silent, zero-log boot failure.
#
# Run it explicitly (it is deliberately NEVER a flake `checks` entry and never
# wired into CI — it builds the whole desktop app and boots a real BEAM):
#
#   nix run .#desktop-smoke
#
# The flake app wrapper exports GENESIS_DESKTOP_APP (the `packages.desktop`
# store path) and puts curl / coreutils / grep / procps on PATH.

readonly SMOKE_MARK="[smoke]"

# Cold-boot budget for HTTP 200: the release boot runs migrations, loads the
# asset manifest and starts the Phoenix endpoint. Deliberately generous so a
# slow machine is not reported as a failure.
readonly READY_TIMEOUT_SECS=180
readonly SHUTDOWN_TIMEOUT_SECS=45
readonly PORT_CLOSE_TIMEOUT_SECS=30
readonly LEFTOVER_TIMEOUT_SECS=15

# Boot-failure signatures written to the data-dir logs. "atom table" /
# "no more index entries" are the atom-exhaustion wording of the historical
# `+t 80000` regression; "failed to start" and "CRASH" cover a release that
# boots but dies while starting applications.
readonly BOOT_FAILURE_MARKERS='atom table|no more index entries|failed to start|CRASH'

# A VM process/atom cap flag at the start of a vm.args line (`+t 80000`,
# `+P 1000000`). Deliberately NOT matched mid-line: the packaged vm.args
# documents the removed caps in a comment ("Capping them (+P/+t) caused ...").
readonly VM_CAP_PATTERN='^[[:space:]]*\+(t|P)[[:space:]]'

SMOKE_TMP=""
HEADLESS_PID=""
SHELL_LOG=""
BACKEND_LOG=""

# ── Helpers ──────────────────────────────────────────────────────────

die() {
  printf '%s FAIL: %s\n' "$SMOKE_MARK" "$*" >&2
  exit 1
}

info() {
  printf '%s %s\n' "$SMOKE_MARK" "$*"
}

now_secs() {
  date +%s
}

# True when something already answers on 127.0.0.1:<port>. The Tauri shell
# honors $PORT only while that port is free and otherwise picks an ephemeral
# port of its own — which would leave the readiness poll watching the wrong
# port — so the port is probed before it is handed over.
port_taken() {
  curl --silent --output /dev/null --max-time 1 "http://127.0.0.1:$1/" >/dev/null 2>&1
}

# Pick a free-ish TCP port for the backend: randomized in a high range, a few
# candidates, each probed with curl.
pick_port() {
  local attempt port
  for ((attempt = 0; attempt < 10; attempt++)); do
    port=$((20000 + (RANDOM % 40000)))
    if ! port_taken "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

# True while <pid> is a live process. A zombie child still satisfies `kill -0`
# until it is reaped, so the process state is checked as well — otherwise the
# bounded shutdown wait would always run to its deadline.
process_alive() {
  local pid="$1"
  local state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || return 1
  case "$state" in
    "" | Z*) return 1 ;;
  esac
  return 0
}

# Print the tail of every relevant log (used on failure).
show_logs() {
  local file
  for file in "$SMOKE_TMP/headless.log" "$SHELL_LOG" "$BACKEND_LOG"; do
    if [ -n "$file" ] && [ -f "$file" ]; then
      printf '%s --- %s (last 40 lines) ---\n' "$SMOKE_MARK" "$file" >&2
      tail -n 40 "$file" >&2 || true
    fi
  done
}

# This script and every one of its ancestors — never a leftover release
# process, even when a caller's command line happens to mention the release
# path (grep -vxF filters these out of the pgrep result).
ancestor_pids() {
  local pid="$$"
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    printf '%s\n' "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || pid=""
  done
}

# True when <pid> is one of the packaged release's own processes: the launcher
# script or the BEAM it execs. Combined with the path match from pgrep this
# keeps the leftover check targeted — a process that merely MENTIONS the
# release path in its arguments (an editor, a shell, the nix invocation) is not
# a leftover. Matches both the short comm name and a full executable path.
is_release_process() {
  local pid="$1"
  local comm
  comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || return 1
  case "$comm" in
    beam.smp | beam | erlexec | genesis_desktop | genesis_desktop.bat) return 0 ;;
    */beam.smp | */beam | */erlexec | */genesis_desktop | */genesis_desktop.bat) return 0 ;;
  esac
  return 1
}

# Never leave a stray app behind, whatever path the failure took.
cleanup() {
  if [ -n "$HEADLESS_PID" ] && process_alive "$HEADLESS_PID"; then
    kill -TERM "$HEADLESS_PID" 2>/dev/null || true
    sleep 2
    if process_alive "$HEADLESS_PID"; then
      kill -KILL "$HEADLESS_PID" 2>/dev/null || true
    fi
  fi
}

trap cleanup EXIT

# ── 1. Locate and sanity-check the package layout ────────────────────

APP_ROOT="${GENESIS_DESKTOP_APP:-}"
if [ -z "$APP_ROOT" ]; then
  die "GENESIS_DESKTOP_APP is unset — run this through 'nix run .#desktop-smoke'"
fi
[ -d "$APP_ROOT" ] || die "GENESIS_DESKTOP_APP does not exist: $APP_ROOT"

DESKTOP_BIN="$APP_ROOT/bin/genesis-desktop"
BACKEND_LINK="$APP_ROOT/lib/genesis-desktop/resources/genesis-backend"
LAUNCHER="$BACKEND_LINK/bin/genesis_desktop"

# genesis-desktop.nix installs the Tauri binary under
# $out/lib/genesis-desktop and symlinks the Mix release to
# resources/genesis-backend. If that layout ever drifts, this script would
# silently test nothing — fail loudly instead.
[ -x "$DESKTOP_BIN" ] || die "packaged Tauri binary missing or not executable: $DESKTOP_BIN"
[ -x "$LAUNCHER" ] ||
  die "packaged release launcher missing or not executable: $LAUNCHER (did the genesis-desktop.nix layout change?)"

# Physical path of the release (the symlink target) — the string the BEAM's
# own command line carries, used for the leftover-process check.
RELEASE_ROOT="$(cd "$BACKEND_LINK" && pwd -P)" || die "cannot resolve the release path of $BACKEND_LINK"

info "package:  $APP_ROOT"
info "release:  $RELEASE_ROOT"

# ── 2. Regression guard: no +t / +P caps in the packaged vm.args ─────

vm_args_found=0
for vm_args_file in "$BACKEND_LINK"/releases/*/vm.args; do
  [ -f "$vm_args_file" ] || continue
  vm_args_found=1
  if grep -Eq "$VM_CAP_PATTERN" "$vm_args_file"; then
    printf '%s offending lines in %s:\n' "$SMOKE_MARK" "$vm_args_file" >&2
    grep -nE "$VM_CAP_PATTERN" "$vm_args_file" >&2 || true
    die "the packaged vm.args caps the VM process/atom tables (+t/+P). The historical '+t 80000' cap exhausted the atom table and made the desktop app fail to start on ALL platforms with a silent, zero-log boot failure. Remove the cap from rel/genesis/vm.args.eex."
  fi
done
[ "$vm_args_found" -eq 1 ] ||
  die "no releases/*/vm.args found under $BACKEND_LINK — cannot verify the VM flags"
info "vm.args: no +t / +P caps"

# ── 3. Isolated runtime environment ─────────────────────────────────

SMOKE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/genesis-desktop-smoke.XXXXXX")" ||
  die "could not create a temporary directory"

# A throwaway HOME / data / config dir keeps the smoke test away from the
# developer's real tasks.sqlite and config.toml (no config.toml also means the
# backend resolves its data dir to $XDG_DATA_HOME/genesis, where the logs are
# asserted below).
export HOME="$SMOKE_TMP/home"
export XDG_DATA_HOME="$SMOKE_TMP/data"
export XDG_CONFIG_HOME="$SMOKE_TMP/config"
export XDG_RUNTIME_DIR="$SMOKE_TMP/run"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# WebKit's DMA-BUF renderer needs a GPU/compositor; harmless in headless mode
# but kept so this script stays usable if the flow ever moves to a GUI probe.
export WEBKIT_DISABLE_DMABUF_RENDERER=1

SHELL_LOG="$XDG_DATA_HOME/genesis/logs/shell.log"
BACKEND_LOG="$XDG_DATA_HOME/genesis/logs/backend.log"

info "temp dir: $SMOKE_TMP"

# ── 4. Start the packaged app headless ──────────────────────────────

PORT="$(pick_port)" || die "could not find a free TCP port in 20000-59999"
export PORT

info "starting '$DESKTOP_BIN --headless' on port $PORT"
START_SECS="$(now_secs)"
"$DESKTOP_BIN" --headless >"$SMOKE_TMP/headless.log" 2>&1 &
HEADLESS_PID=$!

# Poll for readiness; returns 0 on HTTP 200, 2 when the app died first.
wait_ready() {
  local deadline status body
  deadline=$(($(now_secs) + READY_TIMEOUT_SECS))
  body="$SMOKE_TMP/index.html"
  while [ "$(now_secs)" -lt "$deadline" ]; do
    if ! process_alive "$HEADLESS_PID"; then
      return 2
    fi
    if status="$(curl --silent --max-time 5 --output "$body" --write-out '%{http_code}' \
      "http://127.0.0.1:$PORT/" 2>/dev/null)"; then
      if [ "$status" = "200" ]; then
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

ready_status=0
wait_ready || ready_status=$?

if [ "$ready_status" -ne 0 ]; then
  show_logs
  if [ "$ready_status" -eq 2 ]; then
    die "the packaged app exited before serving HTTP on port $PORT — see the logs above"
  fi
  die "no HTTP 200 from http://127.0.0.1:$PORT/ within ${READY_TIMEOUT_SECS}s — see the logs above"
fi

STARTUP_SECS=$(($(now_secs) - START_SECS))
info "dashboard served HTTP 200 after ${STARTUP_SECS}s"

# A 200 alone is not proof of a working dashboard: the body must be the
# dashboard HTML, not an error/placeholder page.
if ! grep -qi '<html' "$SMOKE_TMP/index.html"; then
  show_logs
  die "HTTP 200 but the response body is not dashboard HTML (no '<html' marker); see $SMOKE_TMP/index.html"
fi

# ── 5. The backend really booted the BEAM ───────────────────────────

for log_file in "$SHELL_LOG" "$BACKEND_LOG"; do
  if [ ! -s "$log_file" ]; then
    show_logs
    die "expected a non-empty log at $log_file — a zero-log boot is the atom-table failure signature"
  fi
done

if grep -Eq "$BOOT_FAILURE_MARKERS" "$SHELL_LOG" "$BACKEND_LOG"; then
  printf '%s boot-failure markers:\n' "$SMOKE_MARK" >&2
  grep -nE "$BOOT_FAILURE_MARKERS" "$SHELL_LOG" "$BACKEND_LOG" >&2 || true
  show_logs
  die "the data-dir logs contain boot-failure markers (atom table / failed to start / CRASH)"
fi

info "logs: no boot-failure markers"

# ── 6. Shut down cleanly and assert nothing is left behind ──────────

info "stopping the app (SIGTERM)"
kill -TERM "$HEADLESS_PID" 2>/dev/null || die "could not signal the app (pid $HEADLESS_PID)"

shutdown_deadline=$(($(now_secs) + SHUTDOWN_TIMEOUT_SECS))
while process_alive "$HEADLESS_PID"; do
  if [ "$(now_secs)" -ge "$shutdown_deadline" ]; then
    kill -KILL "$HEADLESS_PID" 2>/dev/null || true
    HEADLESS_PID=""
    show_logs
    die "the app did not exit within ${SHUTDOWN_TIMEOUT_SECS}s of SIGTERM"
  fi
  sleep 1
done
wait "$HEADLESS_PID" 2>/dev/null || true
HEADLESS_PID=""

# The listening socket must be gone: an orphaned backend holds it open.
port_closed=0
port_deadline=$(($(now_secs) + PORT_CLOSE_TIMEOUT_SECS))
while [ "$(now_secs)" -lt "$port_deadline" ]; do
  if ! port_taken "$PORT"; then
    port_closed=1
    break
  fi
  sleep 1
done
if [ "$port_closed" -ne 1 ]; then
  show_logs
  die "port $PORT still accepts connections after shutdown — the backend did not stop"
fi

# Targeted leftover check: processes whose command line carries THIS release's
# path (both the physical store path and the packaged symlink path) AND that
# are a release process by name. A broad `beam.smp` match would trip over
# unrelated BEAM processes on the machine.
ANCESTORS_FILE="$SMOKE_TMP/ancestors"
ancestor_pids >"$ANCESTORS_FILE"

leftover_pids=""
leftover_deadline=$(($(now_secs) + LEFTOVER_TIMEOUT_SECS))
while [ "$(now_secs)" -lt "$leftover_deadline" ]; do
  candidates="$(
    {
      pgrep -f "$RELEASE_ROOT" || true
      pgrep -f "$BACKEND_LINK" || true
    } | sort -u | grep -vxF -f "$ANCESTORS_FILE" || true
  )"
  leftover_pids=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if is_release_process "$candidate"; then
      leftover_pids="$leftover_pids $candidate"
    fi
  done <<<"$candidates"
  leftover_pids="${leftover_pids# }"
  if [ -z "$leftover_pids" ]; then
    break
  fi
  sleep 1
done
if [ -n "$leftover_pids" ]; then
  show_logs
  die "release processes survived shutdown (pids: $leftover_pids)"
fi

info "PASS — packaged desktop app booted in ${STARTUP_SECS}s, served the dashboard on port $PORT, and shut down cleanly (logs: $XDG_DATA_HOME/genesis/logs)"
info "artifacts kept in $SMOKE_TMP (safe to delete)"
