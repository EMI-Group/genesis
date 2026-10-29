#!/usr/bin/env bash
# Smoke test for the headless-server CLI (rel/overlays/bin/genesis).
#
# Self-contained: no real release and no real systemd/launchd. A stub boot
# script stands in for bin/genesis_server, and PATH is shadowed with failing
# systemd/launchd shims so the CLI takes its portable fallback branch on any
# host (CI included).
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

# expect_status <expected-exit> <description> <command...>
expect_status() {
  local expected=$1 desc=$2 rc=0
  shift 2
  "$@" >"$TMP/out" 2>&1 || rc=$?
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

printf '\nAll %d checks passed.\n' "$checks"
