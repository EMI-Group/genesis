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

# ── remote daemons (`genesis remote …`) ─────────────────────────────────────
# Same stub-release technique. Per-scope supervisor shims make the user arm, the
# root (system-scope) arm and every running/stopped state provable without a
# real service manager: `systemctl is-active` follows an `active` marker that
# the `systemd-run` stub sets from the launched unit's --setenv contract, and
# `systemctl show -p Environment --value` reports that same contract back, so
# `remote status` can be checked against what was actually launched.

RUSER="$TMP/remote-user"
RROOT="$TMP/remote-root"
RSTATE="$TMP/remote-state"
RLOG="$TMP/remote-log"
RDATA="$TMP/data-remote"
RMOTE_NODE=genesis_remote_t1@127.0.0.1
mkdir -p "$RUSER" "$RROOT" "$RSTATE" "$RLOG" "$RDATA" "$TMP/runtime"

write_remote_shims() {
  rdir=$1

  cat >"$rdir/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$RLOG/systemctl.log"
if [ "\${1:-}" = "--user" ]; then shift; fi
case "\${1:-}" in
  is-active)
    if [ -e "$RSTATE/active" ]; then exit 0; fi
    exit 3
    ;;
  show)
    if [ -e "$RSTATE/active" ]; then
      printf 'EVOGIT_SERVER=1 RELEASE_NODE=%s RELEASE_COOKIE=stub GENESIS_REMOTE_DIST_PORT=%s\n' \
        "\$(cat "$RSTATE/node" 2>/dev/null || printf 'live@127.0.0.1')" \
        "\$(cat "$RSTATE/port" 2>/dev/null || printf '9000')"
    fi
    exit 0
    ;;
  stop)
    rm -f "$RSTATE/active"
    exit 0
    ;;
  show-environment) exit 0 ;;
esac
exit 0
STUB

  # Records the invocation and mirrors the launched contract into the marker
  # files `systemctl is-active` / `show` answer from.
  cat >"$rdir/systemd-run" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$RLOG/systemd-run.log"
rnode=""
rport=""
for a in "\$@"; do
  case \$a in
    --setenv=RELEASE_NODE=*) rnode=\${a#--setenv=RELEASE_NODE=} ;;
    --setenv=GENESIS_REMOTE_DIST_PORT=*) rport=\${a#--setenv=GENESIS_REMOTE_DIST_PORT=} ;;
  esac
done
printf '%s\n' "\${rnode:-live@127.0.0.1}" >"$RSTATE/node"
printf '%s\n' "\${rport:-9000}" >"$RSTATE/port"
if [ ! -e "$RSTATE/no-activate" ]; then : >"$RSTATE/active"; fi
exit 0
STUB

  cat >"$rdir/journalctl" <<STUB
#!/bin/sh
printf 'JOURNAL %s\n' "\$*"
exit 0
STUB

  cat >"$rdir/uname" <<STUB
#!/bin/sh
printf 'Linux\n'
STUB

  cat >"$rdir/curl" <<STUB
#!/bin/sh
exit 0
STUB

  chmod +x "$rdir/systemctl" "$rdir/systemd-run" "$rdir/journalctl" \
    "$rdir/uname" "$rdir/curl"
}

write_remote_shims "$RUSER"
write_remote_shims "$RROOT"

# A root login: `id -u` is 0, so the remote unit must use the system scope
# (there is no user manager or session bus behind a root SSH login).
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
# scope is not selected): every supervisor probe fails.
RFB="$TMP/remote-fb"
mkdir -p "$RFB"
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
chmod +x "$RFB/systemd-run" "$RFB/systemctl" "$RFB/launchctl" "$RFB/uname" "$RFB/id"

# reset_remote — clear the daemon marker files, invocation logs and data dir.
reset_remote() {
  rm -f "$RSTATE/active" "$RSTATE/no-activate" "$RSTATE/node" "$RSTATE/port"
  : >"$RLOG/systemctl.log"
  : >"$RLOG/systemd-run.log"
  rm -rf "$RDATA"
  mkdir -p "$RDATA"
}

export GENESIS_DATA_DIR="$RDATA"

# (a) the family is discoverable from both help paths.
expect_status 0 "help lists the remote family" "$GENESIS" help
contains "$(cat "$TMP/out")" "remote" "help must list the remote family"
expect_status 0 "remote help" "$GENESIS" remote help
out=$(cat "$TMP/out")
contains "$out" "remote start" "remote help must document remote start"
contains "$out" "--node" "remote help must document --node"
contains "$out" "--dist-port" "remote help must document --dist-port"
ok "help and 'remote help' document the remote family"

# (b) --node/--cookie are required (usage error, exit 2).
expect_status 2 "remote start without --node" "$GENESIS" remote start --cookie cook123
contains "$(cat "$TMP/out")" "--node is required" "a missing --node must be a usage error"
expect_status 2 "remote start without --cookie" "$GENESIS" remote start --node "$RMOTE_NODE"
contains "$(cat "$TMP/out")" "--cookie is required" "a missing --cookie must be a usage error"
ok "remote start requires --node and --cookie (exit 2)"

# (c) non-root: user scope, full six-variable environment contract.
export PATH="$RUSER:$PATH"
reset_remote
expect_status 0 "remote start (user scope)" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 \
  --unit genesis-remote-t1 --wait 5
out=$(cat "$TMP/out")
[ "$out" = "Remote daemon running (node $RMOTE_NODE, dist port 9101)" ] ||
  fail "remote start must print one running line, got: '$out'"
runlog=$(cat "$RLOG/systemd-run.log")
contains "$runlog" "--user" "a non-root remote unit must use the user scope"
not_contains "$runlog" "--system" "a non-root remote unit must not use the system scope"
contains "$runlog" "--unit=genesis-remote-t1" "the unit name must reach systemd-run"
contains "$runlog" "$RELEASE/bin/genesis_server start" "the release launcher must be started"
contains "$runlog" "--property=Restart=on-failure" "a crashed daemon must be restarted"
for var in EVOGIT_SERVER=1 EVOGIT_REMOTE_DAEMON=1 RELEASE_DISTRIBUTION=name \
  "RELEASE_NODE=$RMOTE_NODE" RELEASE_COOKIE=cook123 GENESIS_REMOTE_DIST_PORT=9101; do
  contains "$runlog" "--setenv=$var" "--setenv must carry $var"
done
contains "$runlog" "--setenv=HOME=" "--setenv must carry HOME (data-dir resolution)"
contains "$runlog" "--setenv=GENESIS_DATA_DIR=$RDATA" "--setenv must carry an explicit GENESIS_DATA_DIR"
ok "remote start exports the six contract vars (+HOME/GENESIS_DATA_DIR) in the user scope"

grep -qx "GENESIS_NODE=$RMOTE_NODE" "$RDATA/remote/genesis-remote-t1.env" ||
  fail "the persisted env file must hold GENESIS_NODE: $(cat "$RDATA/remote/genesis-remote-t1.env" 2>/dev/null)"
grep -qx 'GENESIS_DIST_PORT=9101' "$RDATA/remote/genesis-remote-t1.env" ||
  fail "the persisted env file must hold GENESIS_DIST_PORT: $(cat "$RDATA/remote/genesis-remote-t1.env" 2>/dev/null)"
ok "remote start persists <unit>.env with GENESIS_NODE/GENESIS_DIST_PORT"

# (d) already running → no restart, exit 0.
reset_remote
: >"$RSTATE/active"
expect_status 0 "remote start while already running" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --unit genesis-remote-t1
contains "$(cat "$TMP/out")" "already running" "a running daemon must be reported, not restarted"
[ -s "$RLOG/systemd-run.log" ] &&
  fail "an already-running daemon must not be restarted: $(cat "$RLOG/systemd-run.log")"
ok "remote start is a no-op while the daemon is already running"

# (e) --force stops first, then starts.
reset_remote
: >"$RSTATE/active"
expect_status 0 "remote start --force" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9101 \
  --unit genesis-remote-t1 --wait 5 --force
contains "$(cat "$TMP/out")" "Remote daemon running" "--force must end with a running daemon"
grep -qx -- '--user stop genesis-remote-t1' "$RLOG/systemctl.log" ||
  fail "--force must stop the running unit first: $(cat "$RLOG/systemctl.log")"
[ -s "$RLOG/systemd-run.log" ] || fail "--force must start the unit again"
ok "remote start --force stops then starts"

# (f) status reads the LIVE unit environment, not a stale <unit>.env.
reset_remote
: >"$RSTATE/active"
printf '%s\n' "$RMOTE_NODE" >"$RSTATE/node"
printf '9101\n' >"$RSTATE/port"
mkdir -p "$RDATA/remote"
printf 'GENESIS_NODE=genesis_remote_stale@127.0.0.1\nGENESIS_DIST_PORT=9999\n' \
  >"$RDATA/remote/genesis-remote-t1.env"
expect_status 0 "remote status (running)" "$GENESIS" remote status --unit genesis-remote-t1
out=$(cat "$TMP/out")
[ "$out" = "running node=$RMOTE_NODE dist_port=9101" ] ||
  fail "status must report the live node/dist port, got: '$out'"
grep -qx -- '--user show genesis-remote-t1 -p Environment --value' "$RLOG/systemctl.log" ||
  fail "status must read the live unit environment: $(cat "$RLOG/systemctl.log")"
ok "status reports the live unit environment (a stale state file cannot rename a daemon)"

# (g) stopped → `stopped`, exit 1.
reset_remote
expect_status 1 "remote status when stopped" "$GENESIS" remote status --unit genesis-remote-t1
[ "$(cat "$TMP/out")" = "stopped" ] ||
  fail "a stopped daemon must print exactly 'stopped', got: $(cat "$TMP/out")"
ok "status prints 'stopped' and exits 1 when the daemon is down"

# (h) stop is idempotent.
reset_remote
: >"$RSTATE/active"
expect_status 0 "remote stop" "$GENESIS" remote stop --unit genesis-remote-t1
contains "$(cat "$TMP/out")" "stopped" "stop must report the stopped unit"
grep -qx -- '--user stop genesis-remote-t1' "$RLOG/systemctl.log" ||
  fail "stop must call systemctl stop: $(cat "$RLOG/systemctl.log")"
expect_status 0 "remote stop when already stopped" "$GENESIS" remote stop --unit genesis-remote-t1
contains "$(cat "$TMP/out")" "not running" "a stopped unit must report 'not running'"
ok "remote stop is idempotent (exit 0 both times)"

# (i) root: system scope (no user manager, no session bus).
reset_remote
export PATH="$RROOT:$PATH"
expect_status 0 "remote start (root, system scope)" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9102 \
  --unit genesis-remote-root --wait 5
runlog=$(cat "$RLOG/systemd-run.log")
contains "$runlog" "--system" "a root login must launch the unit in the system scope"
not_contains "$runlog" "--user" "a root login has no user manager"
contains "$runlog" "--unit=genesis-remote-root" "the unit name must reach systemd-run"
contains "$runlog" "--setenv=RELEASE_NODE=$RMOTE_NODE" "the contract env must reach the system unit"
syslog=$(cat "$RLOG/systemctl.log")
not_contains "$syslog" "--user" "root must query the system-scope manager"
contains "$syslog" "reset-failed genesis-remote-root" "a stale failed unit must be reset first"
expect_status 0 "remote status (root)" "$GENESIS" remote status --unit genesis-remote-root
[ "$(cat "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9102" ] ||
  fail "root status must report the live unit, got: $(cat "$TMP/out")"
ok "a root login runs and queries the remote unit in the system scope"

# (j) logs read the journal in the unit's scope.
expect_status 0 "remote logs (root)" "$GENESIS" remote logs --unit genesis-remote-root
out=$(cat "$TMP/out")
contains "$out" "JOURNAL" "logs must read the journal on the systemd backend"
contains "$out" "-u genesis-remote-root" "logs must target the unit"
not_contains "$out" "--user" "root reads the system journal"
expect_status 2 "remote status with --follow" "$GENESIS" remote status --follow
contains "$(cat "$TMP/out")" "only valid for 'genesis remote logs'" \
  "--follow must be rejected outside logs"
ok "logs tail the journal in the unit's scope and reject logs-only flags"

# (k) a daemon that never comes up fails with the log tail.
reset_remote
: >"$RSTATE/no-activate"
expect_status 1 "remote start --wait 1 that never comes up" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --unit genesis-remote-slow --wait 1
out=$(cat "$TMP/out")
contains "$out" "did not start within 1s" "an unavailable daemon must fail"
contains "$out" "JOURNAL" "the failure must print the log tail"
ok "a daemon that never comes up exits 1 and prints the log tail"

# (l) fallback backend: detached pidfile + log file, no wait.
reset_remote
expect_status 0 "remote start (fallback backend, --wait 0)" \
  env PATH="$RFB:$PATH" "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 \
  --dist-port 9103 --unit genesis-remote-fb --wait 0
contains "$(cat "$TMP/out")" "Remote daemon running (node $RMOTE_NODE, dist port 9103)" \
  "--wait 0 must report success without polling"
[ -f "$RDATA/remote/genesis-remote-fb.pid" ] ||
  fail "the fallback backend must write <unit>.pid"
[ -f "$RDATA/remote/genesis-remote-fb.log" ] ||
  fail "the fallback backend must write <unit>.log"
grep -qx "GENESIS_NODE=$RMOTE_NODE" "$RDATA/remote/genesis-remote-fb.env" ||
  fail "the fallback backend must persist <unit>.env"
ok "the fallback backend detaches with a pidfile, a log file and the state file"

# (m) macOS/launchd: a per-unit plist with the same environment contract.
RLD="$TMP/remote-launchd"
rmkdir_home="$TMP/home"
mkdir -p "$RLD" "$rmkdir_home"
cat >"$RLD/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$RLOG/launchctl.log"
case "\${1:-}" in
  print)
    if [ -e "$RSTATE/launchd-loaded" ]; then exit 0; fi
    exit 1
    ;;
  bootstrap)
    : >"$RSTATE/launchd-loaded"
    exit 0
    ;;
  bootout)
    rm -f "$RSTATE/launchd-loaded"
    exit 0
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
chmod +x "$RLD/launchctl" "$RLD/uname" "$RLD/id"

reset_remote
: >"$RLOG/launchctl.log"
expect_status 0 "remote start (launchd)" \
  env PATH="$RLD:$PATH" HOME="$rmkdir_home" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port 9104 \
  --unit genesis-remote-mac --wait 5
contains "$(cat "$TMP/out")" "Remote daemon running (node $RMOTE_NODE, dist port 9104)" \
  "the launchd backend must report the running daemon"
PLIST="$rmkdir_home/Library/LaunchAgents/com.genesis.remote.genesis-remote-mac.plist"
[ -f "$PLIST" ] || fail "the launchd backend must write $PLIST"
plist=$(cat "$PLIST")
contains "$plist" "com.genesis.remote.genesis-remote-mac" "the label must carry the unit name"
contains "$plist" "<string>$RELEASE/bin/genesis_server</string>" "ProgramArguments must launch the release"
contains "$plist" "<key>RunAtLoad</key><true/>" "the plist must RunAtLoad"
contains "$plist" "<key>KeepAlive</key><true/>" "the plist must KeepAlive"
contains "$plist" "<key>RELEASE_NODE</key><string>$RMOTE_NODE</string>" \
  "the plist must carry RELEASE_NODE"
contains "$plist" "<key>GENESIS_REMOTE_DIST_PORT</key><string>9104</string>" \
  "the plist must carry GENESIS_REMOTE_DIST_PORT"
contains "$plist" "<key>EVOGIT_REMOTE_DAEMON</key><string>1</string>" \
  "the plist must carry EVOGIT_REMOTE_DAEMON"
contains "$plist" "<string>$RDATA/remote/genesis-remote-mac.log</string>" \
  "StandardOutPath must be <data dir>/remote/<unit>.log"
grep -q "^bootstrap gui/1000 " "$RLOG/launchctl.log" ||
  fail "the plist must be bootstrapped into gui/<uid>: $(cat "$RLOG/launchctl.log")"
expect_status 0 "remote status (launchd)" \
  env PATH="$RLD:$PATH" HOME="$rmkdir_home" "$GENESIS" remote status --unit genesis-remote-mac
[ "$(cat "$TMP/out")" = "running node=$RMOTE_NODE dist_port=9104" ] ||
  fail "launchd status must fall back to the persisted env file, got: $(cat "$TMP/out")"
expect_status 0 "remote stop (launchd)" \
  env PATH="$RLD:$PATH" HOME="$rmkdir_home" "$GENESIS" remote stop --unit genesis-remote-mac
contains "$(cat "$TMP/out")" "stopped" "a booted-out launchd unit must report stopped"
ok "the launchd backend writes a per-unit plist with the full environment contract"

# (n) usage errors.
expect_status 2 "unknown remote command" "$GENESIS" remote bogus
contains "$(cat "$TMP/out")" "unknown remote command" "an unknown subcommand must be reported"
expect_status 1 "remote start with a bad --dist-port" \
  "$GENESIS" remote start --node "$RMOTE_NODE" --cookie cook123 --dist-port nope
ok "an unknown remote subcommand exits 2 and a bad --dist-port exits 1"

printf '\nAll %d checks passed.\n' "$checks"
