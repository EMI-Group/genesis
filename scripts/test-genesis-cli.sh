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
trap 'rm -rf "$TMP"' EXIT

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

printf '\nAll %d checks passed.\n' "$checks"
