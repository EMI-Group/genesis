#!/usr/bin/env bash
# Smoke test for the headless-server CLI (rel/overlays/bin/genesis).
#
# Self-contained: no real release and no real systemd/launchd. A stub boot
# script stands in for bin/genesis_server, and PATH is shadowed with failing
# systemd/launchd shims so the CLI takes its portable fallback branch on any
# host (CI included).
#
# It also covers the `genesis start` systemd-linger offer: the GENESIS_LINGER
# policies (ask/yes/no) and --no-linger, the non-TTY hint, the enable success
# and enable-failure warnings, and the fallback-backend / foreground gating.
# Stub systemd-run/systemctl/loginctl/curl binaries keep every real service
# manager, loginctl and network call out of the run, and the stub curl makes the
# /health poll return on the first try, so there is no 30s health wait.
#
# The `genesis remote …` section tests the single-instance contract (distribution
# is a runtime toggle signalled to the ONE server instance): its stubs start a
# real "instance" process that answers the CLI's control request, and every
# supervisor call answers from marker files — no service manager, no launcher and
# no network. Nothing else is left running when the run ends.
#
# The `genesis update` section drives the self-update path end to end against a
# fake install tree and real .tar.xz fixtures: feed/version comparison, the
# --check/--json exit codes, the busy-task and --force guards, the update lock,
# the atomic swap and the health-failure rollback. One stub curl serves the feed
# (primary and GitHub fallback), the asset, /server/status and /health, so no
# network is touched.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLI_SRC="$REPO_ROOT/rel/overlays/bin/genesis"

checks=0

ok() { checks=$((checks + 1)); printf 'ok %d - %s\n' "$checks" "$*"; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# contains <haystack> <needle> <message>
contains() {
  case $1 in
    *"$2"*) return 0 ;;
  esac
  fail "$3 (expected '$2' in: $1)"
}

# not_contains <haystack> <needle> <message>
not_contains() {
  case $1 in
    *"$2"*) fail "$3 (unexpected '$2' in: $1)" ;;
  esac
}

# expect_status <expected-exit> <description> <command...>
# stdin is /dev/null so non-interactive (non-TTY) branches are deterministic.
expect_status() {
  local expected=$1 desc=$2 rc=0
  shift 2
  "$@" >"$TMP/out" 2>&1 </dev/null || rc=$?
  if [ "$rc" -ne "$expected" ]; then
    fail "$desc: expected exit $expected, got $rc; output: $(cat "$TMP/out")"
  fi
}

[ -f "$CLI_SRC" ] || fail "missing $CLI_SRC"
[ -x "$CLI_SRC" ] || fail "$CLI_SRC is not executable"

sh -n "$CLI_SRC" || fail "sh -n failed for $CLI_SRC"
ok "the CLI is executable and passes sh -n"

TMP=$(mktemp -d)

# The remote section runs REAL "server instance" processes (the CLI signals
# their pids), so the scratch-tree teardown must kill whatever they left behind
# as well — a failed check mid-way must never leak a process.
cleanup_fixtures() {
  _cf_pids=""
  for _cf_file in "${RSTATE:-$TMP}"/*.pid "${RDATA:-$TMP}"/server.pid "$TMP/instance-pids"; do
    [ -f "$_cf_file" ] || continue
    _cf_pids="$_cf_pids $(cat "$_cf_file" 2>/dev/null || true)"
  done
  for _cf_pid in $_cf_pids; do
    kill -TERM "$_cf_pid" 2>/dev/null || true
  done
  return 0
}
trap 'cleanup_fixtures; rm -rf "$TMP"' EXIT

RELEASE="$TMP/release"
mkdir -p "$RELEASE/bin" "$TMP/shim" "$TMP/data" "$TMP/alias"

# Stub release boot script: records argv/env, never serves HTTP.
cat >"$RELEASE/bin/genesis_server" <<'STUB'
#!/bin/sh
if [ -n "${STUB_LOG:-}" ]; then
  printf 'ARGS=%s\n' "$*" >>"$STUB_LOG"
  printf 'PHX_IP=%s\n' "${PHX_IP:-}" >>"$STUB_LOG"
  printf 'PORT=%s\n' "${PORT:-}" >>"$STUB_LOG"
fi
case ${1:-} in
  version) printf '9.9.9-stub\n' ;;
  start) printf 'STUB_START PHX_IP=%s PORT=%s\n' "${PHX_IP:-}" "${PORT:-}" ;;
  *) printf 'STUB %s\n' "$*" ;;
esac
STUB
chmod +x "$RELEASE/bin/genesis_server"

cp "$CLI_SRC" "$RELEASE/bin/genesis"
chmod +x "$RELEASE/bin/genesis"

# Shadow supervisors so service detection is deterministic everywhere.
for tool in systemd-run systemctl launchctl journalctl; do
  printf '#!/bin/sh\nexit 1\n' >"$TMP/shim/$tool"
  chmod +x "$TMP/shim/$tool"
done

# Recording, failing loginctl: any linger probe on a non-systemd backend would
# leave a trace here, so "never called" is provable instead of assumed.
cat >"$TMP/shim/loginctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/shim/loginctl.calls"
exit 1
STUB
chmod +x "$TMP/shim/loginctl"

GENESIS="$RELEASE/bin/genesis"

unset GENESIS_HOME || true
export GENESIS_DATA_DIR="$TMP/data"
export STUB_LOG="$TMP/stub.log"
export PATH="$TMP/shim:$PATH"

# ── help / version / url defaults ────────────────────────────────────────────
expect_status 0 "help" "$GENESIS" help
out=$(cat "$TMP/out")
contains "$out" "serve" "help must list serve"
contains "$out" "start" "help must list start"
contains "$out" "status" "help must list status"
contains "$out" "stop" "help must list stop"
ok "help exits 0 and lists serve/start/status/stop"

expect_status 0 "--help" "$GENESIS" --help
ok "--help exits 0"

expect_status 0 "version" "$GENESIS" version
[ "$(cat "$TMP/out")" = "genesis 9.9.9-stub" ] || fail "version output: $(cat "$TMP/out")"
ok "version prints the release's version (from the stub)"

expect_status 0 "--version" "$GENESIS" --version
ok "--version exits 0"

expect_status 0 "url" "$GENESIS" url
out=$(cat "$TMP/out")
[ "$out" = "http://127.0.0.1:9999" ] || fail "default url: '$out'"
ok "url defaults to http://127.0.0.1:9999"

# ── flag parsing: --flag value and --flag=value ──────────────────────────────
expect_status 0 "serve --port 8080" "$GENESIS" serve --port 8080
out=$(cat "$TMP/out")
contains "$out" "http://127.0.0.1:8080" "serve must print the dashboard URL"
contains "$out" "PHX_IP=127.0.0.1 PORT=8080" "serve must export PHX_IP/PORT to the launcher"
grep -qx 'GENESIS_IP=127.0.0.1' "$TMP/data/server.env" || fail "state file missing GENESIS_IP"
grep -qx 'GENESIS_PORT=8080' "$TMP/data/server.env" || fail "state file missing GENESIS_PORT=8080"
ok "serve --port 8080 exports the port and persists it in server.env"

expect_status 0 "url after serve" "$GENESIS" url
[ "$(cat "$TMP/out")" = "http://127.0.0.1:8080" ] || fail "url after serve: $(cat "$TMP/out")"
ok "url reads the saved port back from the state file"

expect_status 0 "serve --ip=0.0.0.0 --port=8081" "$GENESIS" serve --ip=0.0.0.0 --port=8081
out=$(cat "$TMP/out")
contains "$out" "http://127.0.0.1:8081" "a wildcard bind must display as loopback"
contains "$out" "PHX_IP=0.0.0.0 PORT=8081" "the wildcard bind ip must reach the launcher"
grep -qx 'GENESIS_IP=0.0.0.0' "$TMP/data/server.env" || fail "state file missing GENESIS_IP=0.0.0.0"
ok "--flag=value form is parsed and a wildcard bind is shown as loopback"

expect_status 0 "serve --ip 10.0.0.5 --port 8082" "$GENESIS" serve --ip 10.0.0.5 --port 8082
out=$(cat "$TMP/out")
contains "$out" "http://10.0.0.5:8082" "a concrete bind ip must be advertised"
expect_status 0 "url after explicit ip" "$GENESIS" url
[ "$(cat "$TMP/out")" = "http://10.0.0.5:8082" ] || fail "url after explicit ip: $(cat "$TMP/out")"
ok "--flag value form is parsed and persisted"

expect_status 0 "url with IPv6" "$GENESIS" url --ip ::1 --port 9999
[ "$(cat "$TMP/out")" = "http://[::1]:9999" ] || fail "IPv6 url: $(cat "$TMP/out")"
ok "IPv6 bind addresses are bracketed in the URL"

expect_status 0 "start --foreground" "$GENESIS" start --foreground --ip 127.0.0.1 --port 8083
contains "$(cat "$TMP/out")" "http://127.0.0.1:8083" "start --foreground must run in the foreground"
ok "start --foreground behaves like serve (no daemon, no health poll)"

# ── symlinked install and GENESIS_HOME override ──────────────────────────────
ln -s "$RELEASE/bin/genesis" "$TMP/alias/genesis"
expect_status 0 "url through a symlink" "$TMP/alias/genesis" url
[ "$(cat "$TMP/out")" = "http://127.0.0.1:8083" ] || fail "symlinked url: $(cat "$TMP/out")"
ok "release discovery follows symlinks"

rc=0
GENESIS_HOME="$TMP/not-a-release" "$GENESIS" status >"$TMP/out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a missing bin/genesis_server must exit non-zero"
grep -q 'not inside a Genesis server release' "$TMP/out" ||
  fail "missing release must be reported clearly: $(cat "$TMP/out")"
ok "a missing bin/genesis_server fails with a clear message"

# ── failure paths ────────────────────────────────────────────────────────────
expect_status 2 "unknown command" "$GENESIS" bogus
contains "$(cat "$TMP/out")" "unknown command" "unknown command must be reported"
ok "an unknown command exits 2"

expect_status 1 "invalid --port" "$GENESIS" serve --port=nope
ok "a non-numeric --port is rejected"

expect_status 1 "status on a dead port" "$GENESIS" status --ip 127.0.0.1 --port 1
out=$(cat "$TMP/out")
contains "$out" "http://127.0.0.1:1" "status must print the URL"
contains "$out" "unreachable" "status must report the failed probe"
ok "status on a dead port prints a summary and exits non-zero"

# ── systemd + lingering ──────────────────────────────────────────────────────
# `genesis start` offers (or, under GENESIS_LINGER=yes, performs)
# `loginctl enable-linger`. No real service manager, loginctl or network is
# touched: systemd-run/systemctl/loginctl/curl/uname are stubbed below, and the
# stub curl makes the /health poll succeed on the first try.
unset GENESIS_LINGER || true

SYSD="$TMP/sysd"
FB="$TMP/fb"
mkdir -p "$SYSD" "$FB" "$TMP/runtime" "$TMP/data-sysd" "$TMP/data-fb"

# systemctl: a live user instance (show-environment succeeds), an inactive unit
# (is-active fails), and successful reset-failed/stop.
cat >"$SYSD/systemctl" <<STUB
#!/bin/sh
if [ "\${1:-}" = "--user" ]; then
  case "\${2:-}" in
    show-environment) exit 0 ;;
    is-active) exit 1 ;;
  esac
fi
exit 0
STUB

# systemd-run: record the invocation, so the systemd backend is provable.
cat >"$SYSD/systemd-run" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/sysd/systemd-run.log"
exit 0
STUB

cat >"$SYSD/journalctl" <<STUB
#!/bin/sh
exit 0
STUB

# curl: report the dashboard healthy immediately (no 30s health wait).
cat >"$SYSD/curl" <<STUB
#!/bin/sh
exit 0
STUB

# loginctl: `show-user` reports the state file; `enable-linger` records the call
# and then succeeds — unless the linger.fail marker makes it fail.
cat >"$SYSD/loginctl" <<STUB
#!/bin/sh
case "\${1:-}" in
  show-user)
    printf 'Linger=%s\n' "\$(cat "$TMP/sysd/linger.state" 2>/dev/null || printf 'no')"
    exit 0
    ;;
  enable-linger)
    printf '%s\n' "\$*" >>"$TMP/sysd/loginctl.calls"
    if [ -e "$TMP/sysd/linger.fail" ]; then exit 1; fi
    printf 'yes\n' >"$TMP/sysd/linger.state"
    exit 0
    ;;
esac
exit 0
STUB

# uname: always Linux, so backend selection is deterministic on macOS/CI hosts
# too (systemd usability requires `uname -s` == Linux).
cat >"$SYSD/uname" <<STUB
#!/bin/sh
printf 'Linux\n'
STUB

chmod +x "$SYSD/systemctl" "$SYSD/systemd-run" "$SYSD/journalctl" "$SYSD/curl" \
  "$SYSD/loginctl" "$SYSD/uname"

# reset_sysd [state] — truncate the invocation logs, clear the failure marker
# and set the linger state (`no` unless told otherwise).
reset_sysd() {
  : >"$SYSD/systemd-run.log"
  : >"$SYSD/loginctl.calls"
  rm -f "$SYSD/linger.fail"
  printf '%s\n' "${1:-no}" >"$SYSD/linger.state"
}

# A separate data dir keeps this section's server.env/pidfile state away from
# the checks above.
export GENESIS_DATA_DIR="$TMP/data-sysd"
export XDG_RUNTIME_DIR="$TMP/runtime"
export PATH="$SYSD:$PATH"

# (a) default policy, lingering disabled, non-TTY stdin → hint only.
reset_sysd no
expect_status 0 "start with lingering disabled (default policy)" \
  "$GENESIS" start --ip 127.0.0.1 --port 18080
out=$(cat "$TMP/out")
contains "$out" "lingering" "the default policy must mention lingering"
contains "$out" "log out" "the hint must explain the logout consequence"
contains "$out" "loginctl enable-linger" "the hint must show how to enable it"
contains "$out" "is healthy" "the server must still start and report healthy"
[ -s "$SYSD/systemd-run.log" ] ||
  fail "the systemd backend must call systemd-run: $(cat "$TMP/out")"
if [ -s "$SYSD/loginctl.calls" ]; then
  fail "the default policy must not enable lingering: $(cat "$SYSD/loginctl.calls")"
fi
ok "start hints at lingering on a non-TTY (systemd backend, warn-only)"

# (b) GENESIS_LINGER=yes enables it exactly once.
reset_sysd no
expect_status 0 "start with GENESIS_LINGER=yes" \
  env GENESIS_LINGER=yes "$GENESIS" start --ip 127.0.0.1 --port 18081
out=$(cat "$TMP/out")
contains "$out" "Enabled systemd lingering for" "GENESIS_LINGER=yes must enable lingering"
contains "$out" "keeps running after you log out" "the success message must explain the benefit"
not_contains "$out" "still reports disabled" "a confirmed enable must not warn again"
calls=$(grep -c '^enable-linger ' "$SYSD/loginctl.calls" || true)
[ "$calls" = 1 ] ||
  fail "expected exactly one enable-linger call, got '$calls': $(cat "$SYSD/loginctl.calls")"
grep -qx "enable-linger $(id -un)" "$SYSD/loginctl.calls" ||
  fail "enable-linger must target the current user: $(cat "$SYSD/loginctl.calls")"
ok "GENESIS_LINGER=yes enables lingering once for the current user"

# (c) GENESIS_LINGER=no silences the offer entirely.
reset_sysd no
expect_status 0 "start with GENESIS_LINGER=no" \
  env GENESIS_LINGER=no "$GENESIS" start --ip 127.0.0.1 --port 18082
out=$(cat "$TMP/out")
not_contains "$out" "linger" "GENESIS_LINGER=no must stay silent about lingering"
if [ -s "$SYSD/loginctl.calls" ]; then
  fail "GENESIS_LINGER=no must not call loginctl: $(cat "$SYSD/loginctl.calls")"
fi
ok "GENESIS_LINGER=no silences the linger offer"

# (d) --no-linger does the same under the default policy.
reset_sysd no
expect_status 0 "start --no-linger" \
  "$GENESIS" start --no-linger --ip 127.0.0.1 --port 18083
out=$(cat "$TMP/out")
not_contains "$out" "linger" "--no-linger must stay silent about lingering"
if [ -s "$SYSD/loginctl.calls" ]; then
  fail "--no-linger must not call loginctl: $(cat "$SYSD/loginctl.calls")"
fi
ok "--no-linger suppresses the linger offer"

# (e) lingering already enabled → nothing to say.
reset_sysd yes
expect_status 0 "start with lingering already enabled" \
  "$GENESIS" start --ip 127.0.0.1 --port 18084
out=$(cat "$TMP/out")
not_contains "$out" "linger" "an enabled linger state must stay silent"
if [ -s "$SYSD/loginctl.calls" ]; then
  fail "an enabled linger state must not call enable-linger: $(cat "$SYSD/loginctl.calls")"
fi
ok "an already-enabled linger state is not re-offered"

# (f) a failing enable-linger only warns; the server still starts.
reset_sysd no
: >"$SYSD/linger.fail"
expect_status 0 "start with a failing enable-linger" \
  env GENESIS_LINGER=yes "$GENESIS" start --ip 127.0.0.1 --port 18085
out=$(cat "$TMP/out")
contains "$out" "could not enable systemd lingering" "a failed enable must warn"
[ -s "$SYSD/systemd-run.log" ] ||
  fail "the server must start even when linger fails: $(cat "$TMP/out")"
ok "a failed enable-linger warns and the server still starts"

# (g) backend gating: no usable supervisor → the fallback branch, no linger probe.
for tool in systemd-run systemctl launchctl; do
  printf '#!/bin/sh\nexit 1\n' >"$FB/$tool"
done
cat >"$FB/uname" <<STUB
#!/bin/sh
printf 'Linux\n'
STUB
cat >"$FB/curl" <<STUB
#!/bin/sh
exit 0
STUB
cat >"$FB/loginctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/fb/loginctl.calls"
exit 0
STUB
chmod +x "$FB/systemd-run" "$FB/systemctl" "$FB/launchctl" "$FB/uname" \
  "$FB/curl" "$FB/loginctl"

expect_status 0 "start on the fallback backend with GENESIS_LINGER=yes" \
  env GENESIS_DATA_DIR="$TMP/data-fb" PATH="$FB:$PATH" GENESIS_LINGER=yes \
  "$GENESIS" start --ip 127.0.0.1 --port 18086
out=$(cat "$TMP/out")
contains "$out" "fallback backend" "an unusable supervisor must select the fallback backend"
not_contains "$out" "linger" "the fallback backend must not mention lingering"
[ ! -e "$FB/loginctl.calls" ] ||
  fail "the fallback backend must not call loginctl: $(cat "$FB/loginctl.calls")"
ok "the fallback backend never probes lingering (no enable-linger, no show-user)"

# (h) foreground `serve` never probes lingering, even with the policy set.
reset_sysd no
expect_status 0 "serve with GENESIS_LINGER=yes" \
  env GENESIS_LINGER=yes "$GENESIS" serve --ip 127.0.0.1 --port 18087
out=$(cat "$TMP/out")
not_contains "$out" "linger" "serve must not probe lingering"
if [ -s "$SYSD/loginctl.calls" ]; then
  fail "serve must not call loginctl: $(cat "$SYSD/loginctl.calls")"
fi
ok "serve (foreground) never probes lingering"

# (i) help documents the escape hatches.
expect_status 0 "help with linger options" "$GENESIS" help
out=$(cat "$TMP/out")
contains "$out" "--no-linger" "help must list --no-linger"
contains "$out" "GENESIS_LINGER" "help must document GENESIS_LINGER"
ok "help documents --no-linger and GENESIS_LINGER"

# Every non-systemd path above ran with the failing shims on PATH: if any of
# them had probed lingering, the real loginctl would have been reachable.
if [ -e "$TMP/shim/loginctl.calls" ]; then
  fail "loginctl must never be invoked without the systemd backend: $(cat "$TMP/shim/loginctl.calls")"
fi
ok "no fallback/foreground path ever invoked loginctl"

# ── remote development (`genesis remote …`) ─────────────────────────────────
# Distribution is a RUNTIME TOGGLE on the ONE server instance: the CLI writes
# `<data dir>/remote/control.request`, SIGHUPs that instance's main pid and
# polls `dist.env` for an answer carrying its own sequence number. No second
# process, unit or pidfile is ever created.
#
# So the harness runs a real "instance" process (`instance.sh` below) and
# shadows the supervisors, which makes every state provable without a real
# service manager:
#   systemd-run  starts the instance and marks the unit active
#   systemctl    is-active / show -p MainPID / stop answer from marker files
#   launchctl    print / bootstrap / bootout / list do the same on the launchd arm
# `sleep` is stubbed to a few REAL milliseconds per step, so the CLI's 100 ms
# poll budget (and the `--wait` floor) is still walked step by step, just in
# well under a second instead of ten.

RUSER="$TMP/remote-user"
RROOT="$TMP/remote-root"
RFB="$TMP/remote-fb"
RLD="$TMP/remote-launchd"
RSTATE="$TMP/remote-state"
RLOG="$TMP/remote-log"
RDATA="$TMP/data-remote"
RELEASE_FB="$TMP/release-fb"
RMOTE_NODE=genesis_remote_t1@127.0.0.1
RMOTE_STALE_NODE=genesis_remote_stale@127.0.0.1
mkdir -p "$RUSER" "$RROOT" "$RFB" "$RLD" "$RSTATE" "$RLOG" "$RDATA" \
  "$RELEASE_FB/bin" "$TMP/home"

# The harness itself must keep real time even after the stub dirs (which shadow
# `sleep`) are put on PATH.
REAL_SLEEP=$(command -v sleep)
[ -n "$REAL_SLEEP" ] || fail "no sleep binary on PATH"
: >"$TMP/instance-pids"

# The ONE server instance. On SIGHUP it reads control.request and answers it in
# dist.env exactly like EvoGit.DaemonControl does, so `remote start/stop/status`
# can be checked against what the CLI actually sent:
#   - `hup.count` counts every signal (proving the CLI signalled the instance)
#   - `$RSTATE/mute-hup` makes it ignore the request (a silent daemon)
#   - `$RSTATE/error` makes it answer RESULT=error with that file's message
#   - `$RSTATE/quit` ends the loop
# The harness ticks every ~5ms (the stub `sleep`), so a signal is noticed fast,
# and the handler is armed before `instance.ready` appears — the stubs that
# start the instance wait for that marker, so a SIGHUP can never race the arming.
cat >"$RSTATE/instance.sh" <<'INSTANCE'
#!/bin/sh
RSTATE=$1
RDATA=$2
on_hup() {
  printf 'hup\n' >>"$RSTATE/hup.count"
  if [ -e "$RSTATE/mute-hup" ]; then return 0; fi
  req=$RDATA/remote/control.request
  [ -f "$req" ] || return 0
  # Evidence for the assertions: the request's mode and its full body.
  ls -l "$req" | awk '{print $1}' >"$RSTATE/request.mode"
  cp "$req" "$RSTATE/request.body"
  action=$(sed -n 's/^ACTION=//p' "$RSTATE/request.body" | tail -n 1)
  node=$(sed -n 's/^NODE=//p' "$RSTATE/request.body" | tail -n 1)
  port=$(sed -n 's/^DIST_PORT=//p' "$RSTATE/request.body" | tail -n 1)
  seq=$(sed -n 's/^SEQ=//p' "$RSTATE/request.body" | tail -n 1)
  enabled=0
  if [ "$action" = enable ]; then enabled=1; fi
  result=ok
  message=""
  if [ -e "$RSTATE/error" ]; then
    result=error
    message=$(cat "$RSTATE/error")
  fi
  mkdir -p "$RDATA/remote"
  {
    printf 'GENESIS_DIST_ENABLED=%s\n' "$enabled"
    printf 'GENESIS_NODE=%s\n' "$node"
    printf 'GENESIS_DIST_PORT=%s\n' "$port"
    printf 'GENESIS_CONTROL_SEQ=%s\n' "$seq"
    printf 'GENESIS_CONTROL_RESULT=%s\n' "$result"
    if [ -n "$message" ]; then printf 'GENESIS_CONTROL_MESSAGE=%s\n' "$message"; fi
  } >"$RDATA/remote/dist.env.tmp"
  mv -f "$RDATA/remote/dist.env.tmp" "$RDATA/remote/dist.env"
  rm -f "$req"
}
trap 'on_hup' HUP
: >"$RSTATE/instance.ready"
printf 'instance started (stub)\n'

while [ ! -e "$RSTATE/quit" ]; do sleep 0.05; done
exit 0
INSTANCE
chmod +x "$RSTATE/instance.sh"

# write_sleep_stub <dir> — the CLI polls in 100 ms steps, so a no-op `sleep`
# would make the budget vanish; a few real milliseconds keep the loop's shape
# (same step count, same floor) while costing nothing.
write_sleep_stub() {
  cat >"$1/sleep" <<STUB
#!/bin/sh
exec $REAL_SLEEP 0.005
STUB
  chmod +x "$1/sleep"
}

# write_remote_shims <dir> — systemd/journalctl/curl/uname/sleep stubs.
write_remote_shims() {
  rdir=$1

  cat >"$rdir/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$RLOG/systemctl.log"
if [ "\${1:-}" = "--user" ]; then shift; fi
cmd=\${1:-}
if [ \$# -gt 0 ]; then shift; fi
unit=""
for a in "\$@"; do
  case \$a in
    --quiet | -q | -p | --value | MainPID) ;;
    *) unit=\$a ;;
  esac
done
case \$cmd in
  show-environment) exit 0 ;;
  is-active)
    case \$unit in
      genesis-server)
        if [ -e "$RSTATE/active" ]; then exit 0; fi
        ;;
      *)
        if [ -e "$RSTATE/legacy-active" ]; then exit 0; fi
        ;;
    esac
    exit 3
    ;;
  show)
    # show genesis-server -p MainPID --value → the instance's main pid.
    if [ "\$unit" = genesis-server ] && [ -e "$RSTATE/active" ] &&
      [ -f "$RSTATE/instance.pid" ]; then
      cat "$RSTATE/instance.pid"
    fi
    exit 0
    ;;
  stop)
    case \$unit in
      genesis-server)
        rm -f "$RSTATE/active"
        if [ -f "$RSTATE/instance.pid" ]; then
          kill -TERM "\$(cat "$RSTATE/instance.pid")" 2>/dev/null || true
          rm -f "$RSTATE/instance.pid"
        fi
        ;;
      *)
        rm -f "$RSTATE/legacy-active"
        if [ -f "$RSTATE/legacy.pid" ]; then
          kill -TERM "\$(cat "$RSTATE/legacy.pid")" 2>/dev/null || true
          rm -f "$RSTATE/legacy.pid"
        fi
        ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB

  # Records the invocation and starts the shared instance for the one unit the
  # server may own; --collect/--property/--setenv are only ever recorded.
  cat >"$rdir/systemd-run" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$RLOG/systemd-run.log"
unit=""
for a in "\$@"; do
  case \$a in
    --unit=*) unit=\${a#--unit=} ;;
  esac
done
if [ "\$unit" = genesis-server ]; then
  : >"$RSTATE/active"
  "$RSTATE/instance.sh" "$RSTATE" "$RDATA" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "\$!" >"$RSTATE/instance.pid"
  printf '%s\n' "\$!" >>"$TMP/instance-pids"
  # Do not report the unit started before the instance can take a signal.
  _sr_n=0
  while [ ! -e "$RSTATE/instance.ready" ] && [ "\$_sr_n" -lt 200 ]; do
    "$REAL_SLEEP" 0.005
    _sr_n=\$((_sr_n + 1))
  done
fi
exit 0
STUB

  cat >"$rdir/journalctl" <<STUB
#!/bin/sh
printf 'JOURNAL %s\n' "\$*"
exit 0
STUB

  cat >"$rdir/uname" <<'STUB'
#!/bin/sh
printf 'Linux\n'
STUB

  cat >"$rdir/curl" <<STUB
#!/bin/sh
# A real /health probe takes time; this one takes just enough for the instance
# to have armed its signal handler (the fallback arm cannot gate on ready).
"$REAL_SLEEP" 0.05
exit 0
STUB

  chmod +x "$rdir/systemctl" "$rdir/systemd-run" "$rdir/journalctl" \
    "$rdir/uname" "$rdir/curl"
  write_sleep_stub "$rdir"
}

write_remote_shims "$RUSER"
write_remote_shims "$RROOT"

# A root login: `id -u` is 0, so the LEGACY daemon an old bootstrap launched
# there is stopped in the SYSTEM scope (no user manager over SSH). The shared
# instance itself is still a `--user` service.
cat >"$RROOT/id" <<'STUB'
#!/bin/sh
case ${1:-} in
  -u) printf '0\n' ;;
  -un) printf 'root\n' ;;
  *) printf '0\n' ;;
esac
STUB
chmod +x "$RROOT/id"

# A host with neither systemd nor launchd and a non-root login (so the system
# scope is not selected): every supervisor probe fails. `setsid` is reduced to
# an exec so the pidfile names the instance itself instead of a re-exec parent.
for tool in systemd-run systemctl launchctl; do
  printf '#!/bin/sh\nexit 1\n' >"$RFB/$tool"
done
cat >"$RFB/uname" <<'STUB'
#!/bin/sh
printf 'Linux\n'
STUB
cat >"$RFB/id" <<'STUB'
#!/bin/sh
case ${1:-} in
  -u) printf '1000\n' ;;
  -un) printf 'someone\n' ;;
  *) printf '1000\n' ;;
esac
STUB
cat >"$RFB/curl" <<'STUB'
#!/bin/sh
exit 0
STUB
cat >"$RFB/setsid" <<'STUB'
#!/bin/sh
exec "$@"
STUB
chmod +x "$RFB/systemd-run" "$RFB/systemctl" "$RFB/launchctl" "$RFB/uname" \
  "$RFB/id" "$RFB/curl" "$RFB/setsid"
write_sleep_stub "$RFB"

# A second, tiny release for the fallback arm: its launcher IS the instance, so
# the pid recorded in <data dir>/server.pid stays alive.
cp "$CLI_SRC" "$RELEASE_FB/bin/genesis"
chmod +x "$RELEASE_FB/bin/genesis"
cat >"$RELEASE_FB/bin/genesis_server" <<STUB
#!/bin/sh
case \${1:-} in
  start) exec "$RSTATE/instance.sh" "$RSTATE" "$RDATA" ;;
  *) printf 'STUB %s\n' "\$*" ;;
esac
STUB
chmod +x "$RELEASE_FB/bin/genesis_server"
GENESIS_FB="$RELEASE_FB/bin/genesis"

# macOS/launchd: `print` distinguishes the legacy per-target label from the one
# server label, `bootstrap` starts the instance and `list` reports its pid.
cat >"$RLD/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$RLOG/launchctl.log"
case "\${1:-}" in
  print)
    case "\${2:-}" in
      *com.genesis.remote.*) exit 1 ;;
      *com.genesis.server)
        if [ -e "$RSTATE/launchd-loaded" ]; then exit 0; fi
        ;;
    esac
    exit 1
    ;;
  bootstrap)
    : >"$RSTATE/launchd-loaded"
    "$RSTATE/instance.sh" "$RSTATE" "$RDATA" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "\$!" >"$RSTATE/launchd.pid"
    printf '%s\n' "\$!" >>"$TMP/instance-pids"
    _lc_n=0
    while [ ! -e "$RSTATE/instance.ready" ] && [ "\$_lc_n" -lt 200 ]; do
      "$REAL_SLEEP" 0.005
      _lc_n=\$((_lc_n + 1))
    done
    exit 0
    ;;
  bootout)
    rm -f "$RSTATE/launchd-loaded"
    if [ -f "$RSTATE/launchd.pid" ]; then
      kill -TERM "\$(cat "$RSTATE/launchd.pid")" 2>/dev/null || true
      rm -f "$RSTATE/launchd.pid"
    fi
    exit 0
    ;;
  list)
    if [ -e "$RSTATE/launchd-loaded" ] && [ -f "$RSTATE/launchd.pid" ]; then
      printf '"PID" = %s;\n' "\$(cat "$RSTATE/launchd.pid")"
      exit 0
    fi
    exit 1
    ;;
esac
exit 0
STUB
cat >"$RLD/uname" <<'STUB'
#!/bin/sh
printf 'Darwin\n'
STUB
cat >"$RLD/id" <<'STUB'
#!/bin/sh
case ${1:-} in
  -u) printf '1000\n' ;;
  -un) printf 'someone\n' ;;
  *) printf '1000\n' ;;
esac
STUB
cat >"$RLD/curl" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$RLD/launchctl" "$RLD/uname" "$RLD/id" "$RLD/curl"
write_sleep_stub "$RLD"

# The PATH the arms shadow: everything the earlier sections added, so each arm
# only has to prepend its own stub dir.
REMOTE_BASE_PATH=$PATH
export GENESIS_DATA_DIR="$RDATA"
export GENESIS_LINGER=no

# count_lines <file> — line count (0 when the file is absent), without the
# padding `wc` adds on some hosts. Used for the instance's SIGHUP tally and the
# supervisor invocation logs.
count_lines() {
  if [ -f "$1" ]; then wc -l <"$1" 2>/dev/null | tr -d ' '; else printf '0'; fi
}

# kill_instances <pidfile>... — TERM the pids those files name and wait (briefly,
# real time) until they are gone, so an instance from the previous group cannot
# answer the next group's signal.
kill_instances() {
  _ki_pids=""
  for _ki_f in "$@"; do
    if [ -f "$_ki_f" ]; then _ki_pids="$_ki_pids $(cat "$_ki_f")"; fi
  done
  if [ -z "$_ki_pids" ]; then return 0; fi
  for _ki_pid in $_ki_pids; do
    kill -TERM "$_ki_pid" 2>/dev/null || true
  done
  _ki_n=0
  while [ "$_ki_n" -lt 30 ]; do
    _ki_alive=0
    for _ki_pid in $_ki_pids; do
      if kill -0 "$_ki_pid" 2>/dev/null; then _ki_alive=1; fi
    done
    if [ "$_ki_alive" -eq 0 ]; then return 0; fi
    "$REAL_SLEEP" 0.005
    _ki_n=$((_ki_n + 1))
  done
  return 0
}

# reset_remote — stop every instance an arm started, then clear the control
# state, the markers and the data dir.
reset_remote() {
  : >"$RSTATE/quit"
  kill_instances "$RSTATE/instance.pid" "$RSTATE/legacy.pid" \
    "$RSTATE/launchd.pid" "$RDATA/server.pid"
  rm -f "$RSTATE/active" "$RSTATE/legacy-active" "$RSTATE/launchd-loaded" \
    "$RSTATE/mute-hup" "$RSTATE/error" "$RSTATE/quit" "$RSTATE/hup.count" \
    "$RSTATE/instance.ready" "$RSTATE/request.mode" "$RSTATE/request.body"
  : >"$RLOG/systemctl.log"
  : >"$RLOG/systemd-run.log"
  : >"$RLOG/launchctl.log"
  rm -rf "$RDATA"
  mkdir -p "$RDATA"
}

# The remote arms export their own PATH and GENESIS_DATA_DIR stays $RDATA; the
# per-arm state below is only ever read through the stub dirs prepended to PATH.
export PATH="$RUSER:$REMOTE_BASE_PATH"

# (a) the family is discoverable from both help paths, and the help states the
# single-instance model.
expect_status 0 "help lists the remote family" "$GENESIS" help
contains "$(cat "$TMP/out")" "remote" "help must list the remote family"
expect_status 0 "remote help" "$GENESIS" remote help
out=$(cat "$TMP/out")
contains "$out" "remote start" "remote help must document remote start"
contains "$out" "--node" "remote help must document --node"
contains "$out" "--dist-port" "remote help must document --dist-port"
contains "$out" "RUNTIME TOGGLE" "remote help must state that distribution is a runtime toggle"
contains "$out" "single instance" "remote help must document the one shared instance"
ok "help and 'remote help' document the single-instance remote family"

# (b) --node/--cookie are required (usage error, exit 2).
expect_status 2 "remote start without --node" "$GENESIS" remote start --cookie cook123
contains "$(cat "$TMP/out")" "--node is required" "a missing --node must be a usage error"
expect_status 2 "remote start without --cookie" "$GENESIS" remote start --node "$RMOTE_NODE"
contains "$(cat "$TMP/out")" "--cookie is required" "a missing --cookie must be a usage error"
ok "remote start requires --node and --cookie (exit 2)"

# (c) a cold host: the instance is brought up first (`genesis start` semantics),
# then distribution is enabled on it at runtime.
reset_remote
expect_status 0 "remote start (user scope)" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 --wait 5
out=$(cat "$TMP/out")
contains "$out" "Genesis server starting (systemd backend)." \
  "a cold host must start the shared instance first"
contains "$out" "Dashboard: http://127.0.0.1:9999" "the instance start must print the dashboard URL"
contains "$out" "Genesis server is healthy: http://127.0.0.1:9999" \
  "the instance must be healthy before distribution is enabled"
[ "$(tail -n 1 "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9101" ] ||
  fail "the canonical running line must be the LAST line, got: $(cat "$TMP/out")"
runlog=$(cat "$RLOG/systemd-run.log")
contains "$runlog" "--user" "a non-root host must start the instance in the user scope"
not_contains "$runlog" "--system" "a non-root host must not use the system scope"
contains "$runlog" "--unit=genesis-server" "the ONE server unit must be started"
not_contains "$runlog" "--unit=genesis-remote" "no per-target daemon unit may ever be created"
not_contains "$runlog" "RELEASE_NODE" "distribution must not be baked into the instance launch"
contains "$runlog" "--setenv=GENESIS_DATA_DIR=$RDATA" "the instance must share this CLI's data dir"
contains "$runlog" "--setenv=PHX_IP=127.0.0.1" "the instance must receive the bind address"
contains "$runlog" "--property=Restart=on-failure" "a crashed instance must be restarted"
contains "$runlog" "$RELEASE/bin/genesis_server start" "the release launcher must be started"
grep -qx -- '--user reset-failed genesis-server' "$RLOG/systemctl.log" ||
  fail "a stale failed unit must be reset first: $(cat "$RLOG/systemctl.log")"
ok "a cold host starts the ONE instance, then reports the canonical running line"

# (d) the request the instance saw: 0600, complete, and atomically placed.
[ "$(cat "$RSTATE/request.mode")" = "-rw-------" ] ||
  fail "the control request must be 0600, got '$(cat "$RSTATE/request.mode")'"
body=$(cat "$RSTATE/request.body")
contains "$body" "ACTION=enable" "the request must enable distribution"
grep -qx "NODE=$RMOTE_NODE" "$RSTATE/request.body" ||
  fail "the request must carry NODE: $body"
grep -qx 'COOKIE=cook123' "$RSTATE/request.body" ||
  fail "the request must carry the cookie: $body"
grep -qx 'DIST_PORT=9101' "$RSTATE/request.body" ||
  fail "the request must carry DIST_PORT: $body"
grep -q '^SEQ=[0-9][0-9]*$' "$RSTATE/request.body" ||
  fail "the request must carry a sequence number: $body"
if ls -d "$RDATA"/remote/.control.request.tmp.* >/dev/null 2>&1; then
  fail "a temp request file was left behind: $(ls -d "$RDATA"/remote/.control.request.tmp.*)"
fi
ok "the control request is 0600, complete, sequenced and leaves no temp file"

# (e) already enabled for this node → idempotent: no signal, no new instance.
runs_before=$(count_lines "$RLOG/systemd-run.log")
hups_before=$(count_lines "$RSTATE/hup.count")
expect_status 0 "remote start while distribution is already enabled" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101
[ "$(cat "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9101" ] ||
  fail "an enabled node must print the canonical line, got: $(cat "$TMP/out")"
[ "$(count_lines "$RLOG/systemd-run.log")" -eq "$runs_before" ] ||
  fail "an already-running instance must not be started again: $(cat "$RLOG/systemd-run.log")"
[ "$(count_lines "$RSTATE/hup.count")" -eq "$hups_before" ] ||
  fail "an already-enabled node must not be signalled again"
ok "an already-enabled node is reported without a signal or a second instance"

# (f) --force re-enables on the SAME instance.
runs_before=$(count_lines "$RLOG/systemd-run.log")
hups_before=$(count_lines "$RSTATE/hup.count")
pid_before=$(cat "$RSTATE/instance.pid")
expect_status 0 "remote start --force" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 \
  --wait 5 --force
[ "$(tail -n 1 "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9101" ] ||
  fail "--force must end with the canonical line, got: $(cat "$TMP/out")"
[ "$(count_lines "$RSTATE/hup.count")" -gt "$hups_before" ] ||
  fail "--force must signal the instance again"
[ "$(cat "$RSTATE/instance.pid")" = "$pid_before" ] ||
  fail "--force must keep the same instance, got $(cat "$RSTATE/instance.pid") (was $pid_before)"
[ "$(count_lines "$RLOG/systemd-run.log")" -eq "$runs_before" ] ||
  fail "--force must not start a second instance: $(cat "$RLOG/systemd-run.log")"
ok "remote start --force re-enables distribution on the same instance"

# (g) status reports the daemon's published state — never a stale legacy file.
mkdir -p "$RDATA/remote"
printf 'GENESIS_NODE=%s\nGENESIS_DIST_PORT=9999\n' "$RMOTE_STALE_NODE" \
  >"$RDATA/remote/genesis-remote-t1.env"
expect_status 0 "remote status (running)" "$GENESIS" remote status --unit genesis-remote-t1
[ "$(cat "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9101" ] ||
  fail "status must report dist.env, not a stale legacy <unit>.env, got: $(cat "$TMP/out")"
cp "$RSTATE/instance.pid" "$RSTATE/instance.pid.off"
rm -f "$RSTATE/instance.pid"
expect_status 1 "remote status when the instance is down" "$GENESIS" remote status
[ "$(cat "$TMP/out")" = "stopped" ] ||
  fail "a down instance must print exactly 'stopped', got: $(cat "$TMP/out")"
mv "$RSTATE/instance.pid.off" "$RSTATE/instance.pid"
printf 'GENESIS_DIST_ENABLED=0\nGENESIS_NODE=%s\nGENESIS_DIST_PORT=9101\n' "$RMOTE_NODE" \
  >"$RDATA/remote/dist.env"
expect_status 1 "remote status while distribution is disabled" "$GENESIS" remote status
[ "$(cat "$TMP/out")" = "stopped" ] ||
  fail "a disabled daemon must print exactly 'stopped', got: $(cat "$TMP/out")"
ok "status reports dist.env only (legacy state cannot rename the daemon)"

# (h) stop detaches distribution but keeps the HTTP instance running.
expect_status 0 "remote stop" "$GENESIS" remote stop --unit genesis-remote-t1
[ "$(cat "$TMP/out")" = "Remote daemon stopped (unit genesis-remote-t1)." ] ||
  fail "stop must print the stopped unit, got: $(cat "$TMP/out")"
grep -qx 'ACTION=disable' "$RSTATE/request.body" ||
  fail "stop must send ACTION=disable: $(cat "$RSTATE/request.body")"
if grep -q '^COOKIE=' "$RSTATE/request.body"; then
  fail "a disable request must not carry the cookie: $(cat "$RSTATE/request.body")"
fi
grep -qx 'GENESIS_DIST_ENABLED=0' "$RDATA/remote/dist.env" ||
  fail "the daemon must report distribution disabled: $(cat "$RDATA/remote/dist.env")"
systemctl --user is-active --quiet genesis-server ||
  fail "remote stop must leave the server instance active"
kill -0 "$(cat "$RSTATE/instance.pid")" 2>/dev/null ||
  fail "remote stop must leave the server instance alive"
rm -f "$RSTATE/instance.pid"
expect_status 0 "remote stop when the instance is down" "$GENESIS" remote stop
[ "$(cat "$TMP/out")" = "Remote daemon is not running (unit genesis-remote)." ] ||
  fail "a down instance must report 'not running', got: $(cat "$TMP/out")"
ok "remote stop detaches distribution, keeps the instance running and is idempotent"

# (i) the SEQ handshake: a stale dist.env answer is never mistaken for this
# call's, and --wait is floored at 10s.
reset_remote
expect_status 0 "setup: bring the instance up" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 --wait 5
printf 'GENESIS_DIST_ENABLED=1\nGENESIS_NODE=%s\nGENESIS_DIST_PORT=9101\nGENESIS_CONTROL_SEQ=999999\nGENESIS_CONTROL_RESULT=ok\n' \
  "$RMOTE_STALE_NODE" >"$RDATA/remote/dist.env"
: >"$RSTATE/mute-hup"
hups_before=$(count_lines "$RSTATE/hup.count")
expect_status 1 "remote start --wait 1 (the instance never answers)" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 --wait 1
out=$(cat "$TMP/out")
contains "$out" "did not answer within 10s." "--wait must be floored at 10s"
contains "$out" "Recent logs:" "a timeout must print the instance log tail"
not_contains "$out" "running node=" "a stale dist.env answer must not count as success"
[ "$(count_lines "$RSTATE/hup.count")" -gt "$hups_before" ] ||
  fail "the CLI must signal the instance it is waiting on"
rm -f "$RSTATE/mute-hup"
ok "a stale dist.env answer is rejected and --wait is floored at 10s"

# (j) a daemon-side failure is surfaced verbatim.
printf 'the distribution listener is already bound\n' >"$RSTATE/error"
expect_status 1 "remote start with a daemon-side error" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 \
  --wait 5 --force
out=$(cat "$TMP/out")
contains "$out" "the distribution listener is already bound" \
  "the daemon's message must reach the caller"
not_contains "$out" "running node=" "a failed enable must not print the running line"
rm -f "$RSTATE/error"
ok "a daemon error is reported verbatim and exits 1"

# (k) a legacy per-target daemon is stopped — in the scope it was launched in —
# and only the shared instance is ever started.
reset_remote
: >"$RSTATE/legacy-active"
"$REAL_SLEEP" 300 </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" >"$RSTATE/legacy.pid"
printf '%s\n' "$!" >>"$TMP/instance-pids"
expect_status 0 "remote start with a legacy daemon running" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 \
  --wait 5 --unit genesis-remote-t1
out=$(cat "$TMP/out")
printf '%s\n' "$out" | grep -qx 'Stopped the legacy remote daemon (unit genesis-remote-t1); distribution now runs on the shared server instance.' ||
  fail "the legacy daemon must be reported as stopped: $out"
syslog=$(cat "$RLOG/systemctl.log")
contains "$syslog" "stop genesis-remote-t1" "the legacy unit must be stopped"
contains "$syslog" "reset-failed genesis-remote-t1" "the legacy unit must be reset"
[ ! -e "$RSTATE/legacy-active" ] || fail "the legacy unit marker must be gone"
[ "$(grep -o -- '--unit=[^ ]*' "$RLOG/systemd-run.log" | sort -u)" = "--unit=genesis-server" ] ||
  fail "only the shared instance may be started: $(cat "$RLOG/systemd-run.log")"

# The same cleanup on a root login talks to the SYSTEM scope (an old SSH
# bootstrap launched its daemon there); the instance itself stays a user unit.
export PATH="$RROOT:$REMOTE_BASE_PATH"
reset_remote
: >"$RSTATE/legacy-active"
expect_status 0 "remote start with a legacy daemon (root login)" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 \
  --wait 5 --unit genesis-remote-t1
syslog=$(cat "$RLOG/systemctl.log")
grep -qx 'stop genesis-remote-t1' "$RLOG/systemctl.log" ||
  fail "a root login must stop the legacy unit in the system scope: $syslog"
not_contains "$syslog" "--user stop genesis-remote-t1" "a root login has no user manager"
contains "$(cat "$RLOG/systemd-run.log")" "--user --unit=genesis-server" \
  "the shared instance itself is still a user service"
export PATH="$RUSER:$REMOTE_BASE_PATH"
ok "a legacy per-target daemon is stopped in its own scope, instance only"

# (l) logs are the INSTANCE's logs, and the per-mode flags are gated.
expect_status 0 "remote logs" "$GENESIS" remote logs
contains "$(cat "$TMP/out")" "JOURNAL --user -u genesis-server -n 200" \
  "remote logs must tail the instance journal"
expect_status 0 "remote logs -n 5" "$GENESIS" remote logs -n 5
contains "$(cat "$TMP/out")" "--user -u genesis-server -n 5" "-n must reach journalctl"
expect_status 0 "remote logs -f" "$GENESIS" remote logs -f
contains "$(cat "$TMP/out")" "--user -u genesis-server -n 200 -f" "-f must be forwarded"
expect_status 2 "remote status -f" "$GENESIS" remote status -f
contains "$(cat "$TMP/out")" "--follow/--lines are only valid for 'genesis remote logs'" \
  "-f must be rejected outside logs"
expect_status 2 "remote status --force" "$GENESIS" remote status --force
contains "$(cat "$TMP/out")" \
  "--node/--cookie/--dist-port/--wait/--force are only valid for 'genesis remote start'" \
  "--force must be rejected outside start"
ok "remote logs tail the instance journal; logs-only/start-only flags are gated"

# (m) fallback backend: the pidfile IS the instance, and status follows it.
export PATH="$RFB:$REMOTE_BASE_PATH"
reset_remote
expect_status 0 "remote start (fallback backend)" \
  "$GENESIS_FB" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9103 --wait 5
out=$(cat "$TMP/out")
contains "$out" "Genesis server starting (fallback backend)." \
  "an unusable supervisor must select the fallback backend"
[ "$(tail -n 1 "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9103" ] ||
  fail "the fallback backend must reach the canonical line, got: $(cat "$TMP/out")"
[ -f "$RDATA/server.pid" ] || fail "the fallback backend must write <data>/server.pid"
grep -q 'instance started (stub)' "$RDATA/server.log" ||
  fail "the fallback backend must write <data>/server.log: $(cat "$RDATA/server.log" 2>/dev/null)"
kill -0 "$(cat "$RDATA/server.pid")" 2>/dev/null ||
  fail "the pidfile must name a live instance"
[ ! -s "$RLOG/systemd-run.log" ] ||
  fail "the fallback backend must never call systemd-run: $(cat "$RLOG/systemd-run.log")"
expect_status 0 "remote status (fallback, running)" "$GENESIS_FB" remote status
[ "$(cat "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9103" ] ||
  fail "fallback status must follow the pidfile, got: $(cat "$TMP/out")"
# A pidfile naming a process that is gone is not a running instance.
kill_instances "$RDATA/server.pid"
rm -f "$RDATA/server.pid"
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" || true
printf '%s\n' "$dead_pid" >"$RDATA/server.pid"
expect_status 1 "remote status (fallback, dead pid)" "$GENESIS_FB" remote status
[ "$(cat "$TMP/out")" = "stopped" ] ||
  fail "a dead pidfile must print 'stopped', got: $(cat "$TMP/out")"
ok "the fallback backend uses server.pid/server.log and status follows the pidfile"

# (n) launchd backend: one plist for the ONE instance, pid via `launchctl list`.
export PATH="$RLD:$REMOTE_BASE_PATH"
SAVED_HOME=$HOME
reset_remote
export HOME="$TMP/home"
expect_status 0 "remote start (launchd)" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9104 --wait 5
[ "$(tail -n 1 "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9104" ] ||
  fail "the launchd backend must reach the canonical line, got: $(cat "$TMP/out")"
PLIST="$TMP/home/Library/LaunchAgents/com.genesis.server.plist"
[ -f "$PLIST" ] || fail "the launchd backend must write $PLIST"
plist=$(cat "$PLIST")
contains "$plist" "<string>com.genesis.server</string>" "the plist must carry the server label"
not_contains "$plist" "com.genesis.remote" "no per-target launchd label may be written"
contains "$plist" "<string>$RELEASE/bin/genesis_server</string>" \
  "ProgramArguments must launch the release"
contains "$plist" "<key>GENESIS_DATA_DIR</key><string>$RDATA</string>" \
  "the instance must share this CLI's data dir"
contains "$plist" "<key>RunAtLoad</key><true/>" "the plist must RunAtLoad"
grep -q '^bootstrap gui/1000 ' "$RLOG/launchctl.log" ||
  fail "the plist must be bootstrapped into gui/<uid>: $(cat "$RLOG/launchctl.log")"
expect_status 0 "remote status (launchd)" "$GENESIS" remote status
[ "$(cat "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9104" ] ||
  fail "launchd status must resolve the pid through launchctl list, got: $(cat "$TMP/out")"
grep -q '^list com.genesis.server$' "$RLOG/launchctl.log" ||
  fail "status must ask launchctl for the instance pid: $(cat "$RLOG/launchctl.log")"
expect_status 0 "remote stop (launchd)" "$GENESIS" remote stop
[ "$(cat "$TMP/out")" = "Remote daemon stopped (unit genesis-remote)." ] ||
  fail "launchd stop must print the stopped unit, got: $(cat "$TMP/out")"
[ -e "$RSTATE/launchd-loaded" ] ||
  fail "remote stop must leave the instance loaded (only distribution is detached)"
export HOME="$SAVED_HOME"
ok "the launchd backend bootstraps the one instance plist and stops via control"

# (o) usage errors.
export PATH="$RUSER:$REMOTE_BASE_PATH"
expect_status 2 "unknown remote command" "$GENESIS" remote bogus
contains "$(cat "$TMP/out")" "unknown remote command" "an unknown subcommand must be reported"
expect_status 1 "remote start with a bad --dist-port" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port nope
contains "$(cat "$TMP/out")" "invalid port: nope" "a non-numeric --dist-port must be rejected"
ok "an unknown remote subcommand exits 2 and a bad --dist-port exits 1"

# ── self-update (`genesis update` / `genesis upgrade`) ──────────────────────
# The update path is exercised end to end without a network, a service manager
# or a release build: a fake install tree (`bin/genesis`, a stub launcher and
# `releases/start_erl.data`) is swapped for real .tar.xz fixtures, and ONE stub
# curl answers the release feed (primary + GitHub fallback), the asset, the
# running instance's /server/status and the /health probe.
#
# The fallback (pidfile) backend is deliberate: `service_active` then follows
# `<data dir>/server.pid`, so a real planted process is the "running server" the
# busy/stop assertions observe, and `start` runs the stub launcher itself.
# `sleep` is stubbed to a few real milliseconds, so the health budget (and the
# 10-step stop wait) finish in milliseconds instead of tens of seconds.

UPDP="$TMP/update"
UPDP_STATE="$UPDP/state"
UPDP_SHIM="$UPDP/shim"
UPDP_RISCV="$UPDP/shim-riscv"
UPDP_WORK="$UPDP/work"
UPDP_ART="$UPDP/artifacts"
mkdir -p "$UPDP_STATE" "$UPDP_SHIM" "$UPDP_RISCV" "$UPDP_WORK" \
  "$UPDP_ART" "$UPDP/build"

UPDP_INSTALL=""
UPDP_CLI=""

export GENESIS_LINGER=no
unset GENESIS_HOME || true
unset XDG_RUNTIME_DIR || true
export UPDP_STATE
export UPDP_LOG="$UPDP_STATE/launcher.log"

# Failing supervisors force the fallback (pidfile) backend; `setsid` is reduced
# to an exec so <data>/server.pid names the launcher itself.
for tool in systemd-run systemctl launchctl; do
  printf '#!/bin/sh\nexit 1\n' >"$UPDP_SHIM/$tool"
  chmod +x "$UPDP_SHIM/$tool"
done

cat >"$UPDP_SHIM/uname" <<'STUB'
#!/bin/sh
case ${1:-} in
  -m) printf 'x86_64\n' ;;
  *) printf 'Linux\n' ;;
esac
STUB
cat >"$UPDP_SHIM/setsid" <<'STUB'
#!/bin/sh
exec "$@"
STUB
cat >"$UPDP_RISCV/uname" <<'STUB'
#!/bin/sh
case ${1:-} in
  -m) printf 'riscv64\n' ;;
  *) printf 'Linux\n' ;;
esac
STUB
chmod +x "$UPDP_SHIM/uname" "$UPDP_SHIM/setsid" "$UPDP_RISCV/uname"
write_sleep_stub "$UPDP_SHIM"

# ONE curl for every HTTP call the update path makes. The URL is always the
# LAST argument and `-o` names the destination, so no per-call parsing is
# needed. `primary.down` makes the proxy base unreachable (the GitHub fallback
# must then be used), `active_tasks` feeds /server/status, and `health.ok` — a
# marker the running instance owns — is what /health answers from.
cat >"$UPDP_SHIM/curl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$UPDP_STATE/curl.log"
url=""
dest=""
prev=""
for a in "\$@"; do
  case \$prev in -o | --output) dest=\$a ;; esac
  prev=\$a
  url=\$a
done
case \$url in
  http://feed.invalid/*)
    if [ -e "$UPDP_STATE/primary.down" ]; then exit 22; fi
    ;;
esac
case \$url in
  */health)
    # Give a just-started launcher a moment to publish its marker.
    "$REAL_SLEEP" 0.02
    [ -e "$UPDP_STATE/health.ok" ] || exit 22
    exit 0
    ;;
  */server/status)
    _n=\$(cat "$UPDP_STATE/active_tasks" 2>/dev/null || printf '0')
    _v=\$(cat "$UPDP_STATE/instance.version" 2>/dev/null || printf '0.0.0')
    _body=\$(printf '{"status":"ok","version":"%s","active_tasks":%s}' "\$_v" "\$_n")
    if [ -n "\$dest" ]; then printf '%s\n' "\$_body" >"\$dest"; else printf '%s\n' "\$_body"; fi
    exit 0
    ;;
  *.tar.xz.sha256) exit 22 ;;
  *.tar.xz) src="$UPDP_STATE/asset.tar.xz" ;;
  *latest.json) src="$UPDP_STATE/latest.json" ;;
  *) exit 22 ;;
esac
[ -f "\$src" ] || exit 22
if [ -n "\$dest" ]; then cp "\$src" "\$dest"; else cat "\$src"; fi
exit 0
STUB
chmod +x "$UPDP_SHIM/curl"

# write_launcher <path> <version> <ok|fail> — a stub release launcher.
# `version` answers with the REAL Mix release shape, `<release name> <vsn>` (a
# genuine `bin/genesis_server version` prints `genesis_server 0.13.12`), so the
# CLI's release-name normalization is what the installed/staged version checks
# exercise. The staged-version check still reads the staged
# `releases/start_erl.data`, which is what keeps the `mismatch` fixture
# observable; `start` publishes or clears the /health marker of that version.
write_launcher() {
  cat >"$1" <<STUB
#!/bin/sh
case \${1:-} in
  version) printf 'genesis_server %s\n' "$2" ;;
  start)
    printf 'LAUNCH $2\n' >>"\$UPDP_LOG"
    case $3 in
      ok) : >"\$UPDP_STATE/health.ok" ;;
      fail) rm -f "\$UPDP_STATE/health.ok" ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$1"
}

# write_manifest <file> <version> <sha256> [pub_date] [notes]
write_manifest() {
  cat >"$1" <<EOF
{
  "version": "$2",
  "notes": "${5:-}",
  "pub_date": "${4:-}",
  "platforms": {},
  "server": {
    "linux_x64": {
      "url": "https://genesis.evox.group/dl/genesis_server_linux_x64.tar.xz",
      "sha256": "$3"
    }
  }
}
EOF
}

# sha256_of <file> — the digest the CLI itself would compute.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    fail "neither sha256sum nor shasum is available to build the release fixtures"
  fi
}

# installed_version <release tree> — the version its start_erl.data names.
installed_version() {
  awk 'NF >= 2 { print $2; exit }' "$1/releases/start_erl.data" 2>/dev/null || true
}

# build_release_tree <name> <version> <ok|fail> — a REAL .tar.xz fixture whose
# tarball root is `genesis_server/`, exactly like the published asset.
build_release_tree() {
  _bt="$UPDP/build/$1"
  rm -rf "$_bt"
  mkdir -p "$_bt/genesis_server/bin" "$_bt/genesis_server/releases"
  cp "$CLI_SRC" "$_bt/genesis_server/bin/genesis"
  chmod +x "$_bt/genesis_server/bin/genesis"
  write_launcher "$_bt/genesis_server/bin/genesis_server" "$2" "$3"
  printf 'erts-15.0.1 %s\n' "$2" >"$_bt/genesis_server/releases/start_erl.data"
  tar -cJf "$UPDP_ART/$1.tar.xz" -C "$_bt" genesis_server
}

build_release_tree good 0.13.0 ok
build_release_tree bad 0.14.1 fail
build_release_tree mismatch 0.0.9 ok
GOOD_SHA=$(sha256_of "$UPDP_ART/good.tar.xz")
BAD_SHA=$(sha256_of "$UPDP_ART/bad.tar.xz")
MISMATCH_SHA=$(sha256_of "$UPDP_ART/mismatch.tar.xz")

# The planted "server instance": it owns /health until something stops it, and
# TERM removes the marker too, so a restart has to republish it (that is what
# makes a rollback observable rather than a stale marker).
cat >"$UPDP_STATE/instance.sh" <<STUB
#!/bin/sh
state=\$1
: >"\$state/health.ok"
trap 'rm -f "\$state/health.ok"; exit 0' TERM INT
while :; do "$REAL_SLEEP" 0.05; done
STUB
chmod +x "$UPDP_STATE/instance.sh"

# reset_update [version] [ok|fail] — a fresh install tree, data dir, feed and
# markers, so no case can leak into the next.
reset_update() {
  kill_instances "$UPDP/data/server.pid"
  rm -rf "$UPDP_WORK" "$UPDP/data"
  mkdir -p "$UPDP_WORK/install/bin" "$UPDP_WORK/install/releases" "$UPDP/data"
  UPDP_INSTALL="$UPDP_WORK/install"
  UPDP_CLI="$UPDP_INSTALL/bin/genesis"
  cp "$CLI_SRC" "$UPDP_CLI"
  chmod +x "$UPDP_CLI"
  write_launcher "$UPDP_INSTALL/bin/genesis_server" "${1:-0.12.0}" "${2:-ok}"
  printf 'erts-15.0.1 %s\n' "${1:-0.12.0}" >"$UPDP_INSTALL/releases/start_erl.data"
  : >"$UPDP_INSTALL/.old-sentinel"
  : >"$UPDP_STATE/curl.log"
  : >"$UPDP_STATE/launcher.log"
  printf '0\n' >"$UPDP_STATE/active_tasks"
  printf '%s\n' "${1:-0.12.0}" >"$UPDP_STATE/instance.version"
  rm -f "$UPDP_STATE/primary.down" "$UPDP_STATE/health.ok" \
    "$UPDP_STATE/latest.json" "$UPDP_STATE/asset.tar.xz"
}

# plant_instance — a live pidfile instance plus <data>/server.pid naming it;
# prints its pid.
plant_instance() {
  "$UPDP_STATE/instance.sh" "$UPDP_STATE" </dev/null >/dev/null 2>&1 &
  _pl_pid=$!
  printf '%s\n' "$_pl_pid" >"$UPDP/data/server.pid"
  printf '%s\n' "$_pl_pid" >>"$TMP/instance-pids"
  _pl_n=0
  while [ ! -e "$UPDP_STATE/health.ok" ] && [ "$_pl_n" -lt 200 ]; do
    "$REAL_SLEEP" 0.005
    _pl_n=$((_pl_n + 1))
  done
  printf '%s\n' "$_pl_pid"
}

export GENESIS_DATA_DIR="$UPDP/data"
export GENESIS_DOWNLOAD_BASE="http://feed.invalid/dl"
export GENESIS_DOWNLOAD_FALLBACK_BASE="http://fallback.invalid/releases"
export PATH="$UPDP_SHIM:$REMOTE_BASE_PATH"

# (a) the family and its flags are discoverable.
reset_update
expect_status 0 "update help" "$UPDP_CLI" update --help
out=$(cat "$TMP/out")
contains "$out" "--check" "update help must document --check"
contains "$out" "--json" "update help must document --json"
contains "$out" "--version TAG" "update help must document --version"
contains "$out" "--force" "update help must document --force"
contains "$out" "--wait N" "update help must document --wait"
contains "$out" "alias: genesis upgrade" "update help must document the alias"
expect_status 0 "top-level help lists update" "$UPDP_CLI" help
out=$(cat "$TMP/out")
contains "$out" "update" "help must list the update command"
contains "$out" "upgrade" "help must list the upgrade alias"
ok "help and 'update --help' document the self-update family and its flags"

# (b) already on the feed's version: up to date, exit 0, nothing downloaded.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.12.0 ""
expect_status 0 "update --check (up to date)" "$UPDP_CLI" update --check
out=$(cat "$TMP/out")
contains "$out" "Genesis 0.12.0 is up to date." "an equal version must report up to date"
if grep -q 'tar\.xz' "$UPDP_STATE/curl.log"; then
  fail "a check-only run must not fetch the asset: $(cat "$UPDP_STATE/curl.log")"
fi
expect_status 0 "upgrade --check is the alias" "$UPDP_CLI" upgrade --check
contains "$(cat "$TMP/out")" "is up to date" "upgrade must behave like update"
ok "update --check on an up-to-date install exits 0 and downloads nothing"

# (b2) the launcher answers `version` with the real Mix shape (`<release name>
# <vsn>`): the release name must be stripped everywhere it would leak — into
# `genesis version`, into the up-to-date comparison and into the --json payload.
reset_update 0.13.0
ver=$("$UPDP_CLI" version </dev/null)
[ "$ver" = "genesis 0.13.0" ] ||
  fail "genesis version must strip the release name, got: $ver"
write_manifest "$UPDP_STATE/latest.json" 0.13.0 ""
expect_status 0 "update --check (Mix-shaped launcher version)" "$UPDP_CLI" update --check
contains "$(cat "$TMP/out")" "Genesis 0.13.0 is up to date." \
  "a two-token launcher answer must compare equal to the feed version"
rc=0
"$UPDP_CLI" update --check --json >"$TMP/upd-json" 2>"$TMP/upd-json-err" </dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "--check --json with a two-token launcher answer must exit 0, got $rc"
json=$(cat "$TMP/upd-json")
contains "$json" '"current":"0.13.0"' \
  "the JSON must carry the normalized installed version"
not_contains "$json" "genesis_server" \
  "the launcher's release name must never reach the JSON"
[ ! -s "$TMP/upd-json-err" ] || fail "--check --json must keep stderr quiet: $(cat "$TMP/upd-json-err")"
ok "a Mix-shaped launcher version is normalized for version, --check and --json"

# (c) a newer feed version: exit 10, the human summary and the hint.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "" "2026-11-01T00:00:00Z" \
  "Faster updates."
expect_status 10 "update --check (update available)" "$UPDP_CLI" update --check
out=$(cat "$TMP/out")
contains "$out" "Update available: 0.13.0 (installed 0.12.0)" \
  "the newer version and the installed one must be named"
contains "$out" "Released: 2026-11-01T00:00:00Z" "the release date must be shown"
contains "$out" "Notes:" "the release notes must be shown"
contains "$out" "Run \`genesis update\` to install it." "the install hint must be shown"
if grep -q 'tar\.xz' "$UPDP_STATE/curl.log"; then
  fail "a check-only run must not fetch the asset: $(cat "$UPDP_STATE/curl.log")"
fi
ok "update --check reports a newer release, its notes and the install hint (exit 10)"

# (d) --check --json is ONE line of machine-readable JSON on stdout.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "" "2026-11-01T00:00:00Z"
rc=0
"$UPDP_CLI" update --check --json >"$TMP/upd-json" 2>"$TMP/upd-json-err" </dev/null || rc=$?
[ "$rc" -eq 10 ] || fail "--check --json with a newer release must exit 10, got $rc"
[ "$(wc -l <"$TMP/upd-json" | tr -d ' ')" = 1 ] ||
  fail "--check --json must print exactly one line: $(cat "$TMP/upd-json")"
json=$(cat "$TMP/upd-json")
contains "$json" '"available":true' "the JSON must report the update as available"
contains "$json" '"current":"0.12.0"' "the JSON must carry the installed version"
contains "$json" '"latest":"0.13.0"' "the JSON must carry the feed version"
contains "$json" '"pub_date":"2026-11-01T00:00:00Z"' "the JSON must carry the release date"
not_contains "$json" "Update available" "--json must not print human prose"
[ ! -s "$TMP/upd-json-err" ] || fail "--check --json must keep stderr quiet: $(cat "$TMP/upd-json-err")"
# Up to date, and the manifest publishes no date: `false` and no pub_date key.
write_manifest "$UPDP_STATE/latest.json" 0.12.0 ""
rc=0
"$UPDP_CLI" update --check --json >"$TMP/upd-json" 2>/dev/null </dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "--check --json on an up-to-date install must exit 0, got $rc"
json=$(cat "$TMP/upd-json")
contains "$json" '"available":false' "the JSON must report an up-to-date install as false"
not_contains "$json" '"pub_date"' "an unpublished date must be omitted from the JSON"
ok "--check --json prints one JSON line (and omits an absent pub_date)"

# (e) a running instance with active tasks refuses the update and changes nothing.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "$GOOD_SHA"
cp "$UPDP_ART/good.tar.xz" "$UPDP_STATE/asset.tar.xz"
printf '2\n' >"$UPDP_STATE/active_tasks"
pid=$(plant_instance)
expect_status 1 "update with active tasks" "$UPDP_CLI" update
out=$(cat "$TMP/out")
contains "$out" "The Genesis server has 2 active task(s)" "the active task count must be reported"
contains "$out" "pass --force to update anyway" "the override must be explained"
if grep -q 'tar\.xz' "$UPDP_STATE/curl.log"; then
  fail "a refused update must download nothing: $(cat "$UPDP_STATE/curl.log")"
fi
[ "$(installed_version "$UPDP_INSTALL")" = 0.12.0 ] || fail "a refused update must not change the install"
[ -e "$UPDP_INSTALL/.old-sentinel" ] || fail "a refused update must keep the old tree"
[ ! -e "$UPDP/data/update.lock" ] || fail "a refused update must release the lock"
kill -0 "$pid" 2>/dev/null || fail "a refused update must leave the server running"
ok "update refuses a busy instance (exit 1) and downloads nothing"

# (f) --force bypasses that guard and performs the full staged swap.
expect_status 0 "update --force over a busy instance" \
  "$UPDP_CLI" update --force --wait 3
out=$(cat "$TMP/out")
contains "$out" "updating anyway (--force)" "--force must acknowledge the active tasks"
contains "$out" "Downloading genesis_server_linux_x64.tar.xz (0.13.0)" "the asset must be fetched"
contains "$out" "Checksum verified." "the checksum must be verified before the swap"
contains "$out" "Installing Genesis 0.13.0 to $UPDP_INSTALL" "the install target must be named"
contains "$out" "Stopping the Genesis server." "the running service must be stopped"
contains "$out" "Starting the Genesis server." "the new version must be started"
contains "$out" "Genesis updated: 0.12.0 → 0.13.0" "the version transition must be reported"
[ "$(installed_version "$UPDP_INSTALL")" = 0.13.0 ] || fail "the install must carry the new version"
[ ! -e "$UPDP_INSTALL/.old-sentinel" ] || fail "the install tree must have been replaced"
[ -e "$UPDP_INSTALL/bin/genesis_server" ] || fail "the new tree must carry its launcher"
[ -e "$UPDP_INSTALL/bin/genesis" ] || fail "the new tree must carry the CLI"
grep -qx 'LAUNCH 0.13.0' "$UPDP_STATE/launcher.log" ||
  fail "the new version must have been started: $(cat "$UPDP_STATE/launcher.log")"
if kill -0 "$pid" 2>/dev/null; then
  fail "the old instance must have been stopped (pid $pid is alive)"
fi
if ls -d "$UPDP_INSTALL".old.* >/dev/null 2>&1; then
  fail "the previous tree must be removed after a healthy start: $(ls -d "$UPDP_INSTALL".old.*)"
fi
if ls -d "$UPDP_WORK"/.genesis-update.* >/dev/null 2>&1; then
  fail "no staging directory may be left behind: $(ls -d "$UPDP_WORK"/.genesis-update.*)"
fi
[ ! -e "$UPDP/data/update.lock" ] || fail "a completed update must release its lock"
ok "update --force stops, swaps, restarts and reports the transition"

# (g) a corrupt download is rejected before the server is touched.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 \
  "0000000000000000000000000000000000000000000000000000000000000000"
cp "$UPDP_ART/good.tar.xz" "$UPDP_STATE/asset.tar.xz"
pid=$(plant_instance)
expect_status 1 "update with a checksum mismatch" "$UPDP_CLI" update
out=$(cat "$TMP/out")
contains "$out" "checksum mismatch" "a bad digest must be reported"
not_contains "$out" "Stopping the Genesis server." "a bad digest must abort before the stop"
[ "$(installed_version "$UPDP_INSTALL")" = 0.12.0 ] || fail "a bad digest must not change the install"
[ -e "$UPDP_INSTALL/.old-sentinel" ] || fail "a bad digest must keep the old tree"
kill -0 "$pid" 2>/dev/null || fail "a bad digest must leave the server running"
ok "a checksum mismatch aborts before any stop and keeps the old tree"

# (h) the new version never becomes healthy → roll back to the old one.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.14.1 "$BAD_SHA"
cp "$UPDP_ART/bad.tar.xz" "$UPDP_STATE/asset.tar.xz"
pid=$(plant_instance)
expect_status 1 "update rolling back" "$UPDP_CLI" update --wait 3
out=$(cat "$TMP/out")
not_contains "$out" "Genesis updated" "a rolled-back update must not report success"
contains "$out" "rolling back to 0.12.0" "the failed version must roll back"
contains "$out" "Genesis update failed; the previous version is running." \
  "the rollback outcome must be reported"
[ "$(installed_version "$UPDP_INSTALL")" = 0.12.0 ] || fail "the rollback must restore the old version"
[ -e "$UPDP_INSTALL/.old-sentinel" ] || fail "the rollback must restore the old tree"
grep -qx 'LAUNCH 0.14.1' "$UPDP_STATE/launcher.log" ||
  fail "the new version must have been tried: $(cat "$UPDP_STATE/launcher.log")"
grep -qx 'LAUNCH 0.12.0' "$UPDP_STATE/launcher.log" ||
  fail "the old version must have been restarted: $(cat "$UPDP_STATE/launcher.log")"
if ls -d "$UPDP_INSTALL".old.* >/dev/null 2>&1; then
  fail "the rollback must consume its kept-aside tree: $(ls -d "$UPDP_INSTALL".old.*)"
fi
ok "an unhealthy new version rolls back and the previous version runs again"

# (i) a tarball whose own version disagrees with the feed aborts pre-stop.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "$MISMATCH_SHA"
cp "$UPDP_ART/mismatch.tar.xz" "$UPDP_STATE/asset.tar.xz"
pid=$(plant_instance)
expect_status 1 "update with a staged version mismatch" "$UPDP_CLI" update
out=$(cat "$TMP/out")
contains "$out" "the downloaded release is 0.0.9 but 0.13.0 was requested; nothing was changed" \
  "a mismatched staged release must be refused"
not_contains "$out" "Stopping the Genesis server." "a version mismatch must abort before the stop"
[ "$(installed_version "$UPDP_INSTALL")" = 0.12.0 ] || fail "a version mismatch must not change the install"
kill -0 "$pid" 2>/dev/null || fail "a version mismatch must leave the server running"
ok "a staged version mismatch aborts before any stop, server untouched"

# (j) an unsupported architecture is refused with the published build list.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "$GOOD_SHA"
SAVED_UPDP_PATH=$PATH
export PATH="$UPDP_RISCV:$UPDP_SHIM:$REMOTE_BASE_PATH"
expect_status 1 "update on an unsupported architecture" "$UPDP_CLI" update --check
out=$(cat "$TMP/out")
contains "$out" "no Genesis server build for Linux/riscv64" \
  "an unsupported architecture must be named"
contains "$out" "linux_x64, linux_arm64, darwin_arm64" \
  "the supported builds must be listed"
export PATH="$SAVED_UPDP_PATH"
ok "an unsupported architecture fails with the published build list"

# (k) flags and the update lock: usage errors, a live lock refuses, a stale one
# is recovered.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "$GOOD_SHA"
cp "$UPDP_ART/good.tar.xz" "$UPDP_STATE/asset.tar.xz"
expect_status 2 "update with an unknown flag" "$UPDP_CLI" update --bogus
contains "$(cat "$TMP/out")" "unknown option for 'genesis update': --bogus" \
  "an unknown flag must be a usage error"
expect_status 2 "update with a non-numeric --wait" "$UPDP_CLI" update --wait nope
ok "unknown update flags and a bad --wait exit 2"

mkdir -p "$UPDP/data/update.lock"
printf '%s\n' "$$" >"$UPDP/data/update.lock/pid"
expect_status 1 "update while another update holds the lock" "$UPDP_CLI" update
contains "$(cat "$TMP/out")" "another update is in progress" \
  "a live lock owner must be reported"
[ -d "$UPDP/data/update.lock" ] || fail "a live lock must not be removed"
[ "$(installed_version "$UPDP_INSTALL")" = 0.12.0 ] || fail "a locked-out update must not change the install"
# A lock whose owner is gone is stale: it must be recovered, not wedge updates.
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" || true
printf '%s\n' "$dead_pid" >"$UPDP/data/update.lock/pid"
expect_status 0 "update recovering a stale lock" "$UPDP_CLI" update --wait 3
out=$(cat "$TMP/out")
contains "$out" "Genesis updated: 0.12.0 → 0.13.0" "a stale lock must be recovered"
contains "$out" "The server was not running" "a stopped server must not be restarted"
[ "$(installed_version "$UPDP_INSTALL")" = 0.13.0 ] || fail "a recovered update must install the new version"
[ ! -e "$UPDP/data/update.lock" ] || fail "the recovered lock must be released"
ok "a live lock refuses the update and a stale lock is recovered"

# (l) --version pins the feed/asset URLs, and a dead primary base falls back to
# the GitHub release feed.
reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "$GOOD_SHA"
cp "$UPDP_ART/good.tar.xz" "$UPDP_STATE/asset.tar.xz"
expect_status 10 "update --check --version" "$UPDP_CLI" update --check --version 0.13.0
out=$(cat "$TMP/out")
contains "$out" "Update available: 0.13.0 (installed 0.12.0)" "a pinned tag must be used as the target"
grep -q "http://feed.invalid/dl/v0.13.0/latest.json" "$UPDP_STATE/curl.log" ||
  fail "a pinned tag must shape the feed URL: $(cat "$UPDP_STATE/curl.log")"
ok "--version pins the release tag into the feed URL"

reset_update
write_manifest "$UPDP_STATE/latest.json" 0.13.0 "$GOOD_SHA"
cp "$UPDP_ART/good.tar.xz" "$UPDP_STATE/asset.tar.xz"
: >"$UPDP_STATE/primary.down"
expect_status 10 "update --check with the primary feed down" "$UPDP_CLI" update --check
out=$(cat "$TMP/out")
contains "$out" "Update available: 0.13.0 (installed 0.12.0)" \
  "the fallback feed must still answer the check"
grep -q "http://fallback.invalid/releases/latest/download/latest.json" "$UPDP_STATE/curl.log" ||
  fail "the GitHub fallback manifest must be tried: $(cat "$UPDP_STATE/curl.log")"
expect_status 0 "update with the primary feed down" "$UPDP_CLI" update --wait 3
out=$(cat "$TMP/out")
contains "$out" "Genesis updated: 0.12.0 → 0.13.0" "the fallback feed must complete the update"
grep -q "http://fallback.invalid/releases/latest/download/genesis_server_linux_x64.tar.xz" \
  "$UPDP_STATE/curl.log" ||
  fail "the asset must be fetched from the fallback base: $(cat "$UPDP_STATE/curl.log")"
[ "$(installed_version "$UPDP_INSTALL")" = 0.13.0 ] || fail "the fallback update must install the new version"
ok "a dead primary feed base falls back to the GitHub manifest and asset"

printf '\nAll %d checks passed.\n' "$checks"
