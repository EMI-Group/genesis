# Rel — Mix Release Overlays

## Intent

Release configuration for the Mix releases defined in `../mix.exs`: `genesis` (full, desktop-capable), `genesis_desktop` (Tauri-bundled), `genesis_remote` (headless evo_git-only daemon for SSH remote dev) and `genesis_server` (headless dashboard server shipped with the `genesis` lifecycle CLI).

## Architecture

Every release is built from the top-level EEx templates (`vm.args.eex`, `remote.vm.args.eex`, `env.sh.eex`, `env.bat.eex`); release-specific behavior comes from EEx conditionals on `@release.name`.
`./overlays/` is the only overlay directory an actual release applies: `genesis_server` declares `overlays: ["rel/overlays"]` in `../mix.exs`, so `rel/overlays/bin/genesis` lands in `<release>/bin/genesis` (Mix's file copy preserves the exec bit).
The per-release directories `./genesis/` and `./genesis_remote/` are NOT applied by Mix — they are documentation copies of the intended per-release configuration.

## Routing Table

- `./overlays/bin/genesis` → headless-server CLI shipped inside the `genesis_server` release (see "Genesis Server CLI")
- `./genesis/` → Per-release template copies (not applied by Mix — documentation only)
- `./genesis_remote/` → Per-release template copies (not applied by Mix — documentation only)

## API Surface

### Top-Level Files (applied to every release)

| File | Purpose |
|------|---------|
| `vm.args.eex` | VM arguments template for ALL releases. Uses EEx conditionals: `genesis_remote` gets EPMD-less distribution (`-epmd_module Elixir.EvoGit.EpmdDist`, `-start_epmd false`, `-dist_listen true`, pinned port 9000); other releases get the same EPMD-less setup but listen on ports 9100-9200 (distribution is NOT started at boot — it is enabled on-demand when a remote connection is initiated). Also sets only the scheduler busy-wait flags (`+sbwt none`, `+sbwtdcpu none`, `+sbwtdio none`) — process/atom limits (`+P`/`+t`) are deliberately left at the OTP defaults. |
| `remote.vm.args.eex` | VM arguments for the `remote` and `rpc` shell commands. Same EEx conditional: EPMD-less for `genesis_remote`, plain EPMD-disable for others. |
| `env.sh.eex` | Shell environment template for ALL releases. EEx conditional: `genesis_remote` exports `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE="${RELEASE_NODE:-genesis_remote@127.0.0.1}"` (respects pre-existing env var), and `RELEASE_COOKIE`; other releases get commented-out examples only. |
| `env.bat.eex` | Windows batch environment template. |

### Overlays (applied by the `genesis_server` release)

| File | Purpose |
|------|---------|
| `overlays/bin/genesis` | POSIX `sh` CLI copied to `<release>/bin/genesis`: `serve`/`run`, `start`, `stop`, `restart`, `status`, `logs`, `url`, `version`, `help`. |

### Per-Release Directories (documentation only — NOT applied by Mix)

- `./genesis/` — Intended vm.args/env for the `genesis` release
- `./genesis_remote/` — Intended vm.args/env for the `genesis_remote` release (EPMD-less dist on port 9000, distribution env vars)

These directories exist as documentation of the intended per-release configuration. They are NOT automatically applied by Mix. To wire them up, custom release `:steps` would need to be added to the release definitions in `mix.exs`.

## Genesis Server CLI (`overlays/bin/genesis`)

`genesis_server` is the headless distribution: `evo_git` + `evo_dash` with `include_erts: true`, `overlays: ["rel/overlays"]`, baked `config: [evo_dash: [server_release: true]]`, and deliberately NO `wx` (headless hosts lack wxWidgets; the dashboard's directory picker already degrades to manual path entry).
Server mode is detected in `../config/runtime.exs` from that baked `server_release` flag (or `EVOGIT_SERVER=1`); the CLI only exports `PHX_IP` and `PORT` (plus `PHX_HOST` when `--host` is given) and execs `<release>/bin/genesis_server start`.
The CLI is POSIX `sh` with `set -eu` and never needs a running BEAM for lifecycle commands.

Commands: bare `genesis` == `genesis serve`; `serve`/`run [--ip ADDR] [--port N]` runs in the foreground (prints the URL, then `exec`s the release; a wildcard bind is annotated); `start [--ip] [--port] [--foreground|-f]` daemonizes; `stop`, `restart`, `status`, `logs [-f]`, `url`, `version`, `help`; an unknown command prints usage and exits 2.
`--ip`/`--port` accept both `--flag value` and `--flag=value`.

Release discovery: `$0` is resolved through symlinks with a portable `readlink` loop (no `readlink -f` — absent on macOS/BSD), then `GENESIS_HOME` is the parent of the script's directory when that directory is `bin`, else the directory itself; an explicit `$GENESIS_HOME` wins. A missing `$GENESIS_HOME/bin/genesis_server` fails with "not inside a Genesis server release; set GENESIS_HOME=…".

Backends, chosen per host by `systemd_usable` → `launchd_usable` → pidfile fallback:
`systemd` — `systemd-run --user --unit=genesis-server --collect --property=Restart=on-failure --property=RestartSec=5 --setenv=PHX_IP=… --setenv=PORT=… <launcher> start` (a `reset-failed` precedes it; `--collect` removes the transient unit on exit, `Restart=on-failure` restarts a crashed server); stop is `systemctl --user stop` + `reset-failed`; logs are `journalctl --user -u genesis-server -n 200 [-f]`.
`launchd` — writes/refreshes `~/Library/LaunchAgents/com.genesis.server.plist` (RunAtLoad + KeepAlive, `EnvironmentVariables` with PHX_IP/PORT, StandardOut/ErrPath = the CLI log file) and `launchctl bootout` (when loaded) → `bootstrap gui/<uid>`; stop is `bootout`; logs tail the plist's `StandardOutPath`.
`fallback` (no systemd user manager — containers, minimal distros — or no launchd) — `setsid` (else `nohup`) in the background with `<data_dir>/server.pid` and `<data_dir>/server.log`; stop sends TERM to the pid.
`start` on an already-running service says so and exits 0; `stop` on a stopped service says "not running" and exits 0.

State and paths: the last ip/port are persisted in `<data_dir>/server.env` as `GENESIS_IP=…` / `GENESIS_PORT=…` (parsed, never sourced) and reused when flags are absent (e.g. by `restart`, `url`, `status`).
`<data_dir>` is `$GENESIS_DATA_DIR`, else `$XDG_DATA_HOME/genesis` (`$HOME/.local/share/genesis` when unset) on Linux, else `~/Library/Application Support/genesis` on macOS — mirroring `EvoGit.Platform.data_dir/0`.
Defaults are ip `127.0.0.1` and port `9999`.

Health probe: `GET <url>/health` via `curl -fsS -m 3`, falling back to `wget -qO- -T 3`, else "no curl/wget" (the probe is inconclusive).
IPv6 bind addresses are bracketed in URLs (`http://[::1]:9999`), and a wildcard bind (`0.0.0.0`/`::`) is displayed as `127.0.0.1` for click-through.
`start` polls the probe for up to 30s after launching and prints success with the URL, or failure plus the last log lines; `status` exits 0 only when the probe returns HTTP 200.

Smoke test: `scripts/test-genesis-cli.sh` (bash) builds a temp release with a stub `bin/genesis_server`, shadows systemd/launchd with failing stubs, and asserts help/version/url, flag parsing, the state file, symlink discovery, status failures and exit codes — no real release or service manager needed.

## Known Issues / Notes for Agents

- **No log configuration exists in `rel/`**: none of the env.sh/env.bat/vm.args templates redirect stdout/stderr or set `LOG_*` / `RELEASE_LOG_*` / `ERL_*` log env vars. Desktop log-file redirection is configured OUTSIDE this directory in `../config/runtime.exs` (desktop mode detection via `:desktop_release` flag or `EVOGIT_DESKTOP=1`; Logger `:default_handler` → file at `EvoGit.Platform.data_dir()/logs/backend.log` — `~/.local/share/genesis/logs/` on Linux, `~/Library/Application Support/genesis/logs/` on macOS, `%APPDATA%/genesis/logs/` on Windows; 10 MB × 5 rotated files). `rel/genesis_remote/` has no log config — the remote daemon logs to stdout (captured by systemd-run/launchd). The `genesis` CLI captures daemon output in `<data_dir>/server.log` only for the launchd/pidfile backends; systemd keeps it in the user journal.
- There is no `rel/genesis_desktop/` overlay directory — the desktop release uses the top-level EEx templates.
- `rel/overlays/bin/genesis` must keep its executable bit in git (it is copied verbatim into the release, and release tarballs are extracted without a re-chmod step).

## Constraints

- These are EEx templates — `@release.name` (atom) and other release variables are available.
- VM args templates: do NOT set `-mode`, `-name`, `-sname`, or `-setcookie` — these are configured via env vars.
- VM args templates: do NOT cap the VM with `+P` (max processes) or `+t` (max atoms) — leave both at the OTP defaults.
- Shell env templates: use `export` for variables consumed by the VM/release boot scripts.
- EEx conditionals use string comparison on `@release.name`: `@release.name == :genesis_remote` (atom comparison).
- `overlays/bin/genesis` must stay POSIX `sh` (no bash arrays/`local`/`[[ ]]`), `set -eu`, quoted expansions, and rely only on coreutils plus a curl-or-wget health probe.

## Design Decisions

- **EEx conditionals instead of per-release overlays**: Mix does not automatically apply `rel/<release_name>/` overlays. EEx conditionals in the top-level templates achieve the same result more maintainably than adding custom `:steps` to each release definition (which would require duplicating the desktop optimization flags). `rel/overlays/` is used only for the release-wide file overlay (`bin/genesis`) that `genesis_server` declares explicitly.
- **`genesis_server` has no `wx`**: headless servers usually have no wxWidgets runtime, and a missing wx module would fail the whole release boot; the dashboard's directory picker already falls back to manual entry, so dropping it is lossless there.
- **A shell CLI instead of a BEAM-based control command**: `status`/`stop`/`logs` must work when the server cannot boot (bad config, missing ERTS, busy port), so lifecycle commands only use the platform supervisor and the HTTP probe. `serve` is a thin `exec`, keeping the process a direct child of the supervisor.
- **`readlink` loop instead of `readlink -f`**: macOS/BSD `readlink` has no `-f`, and the installer links `~/.local/bin/genesis` to the release, so symlink resolution must be portable.
- **No `+P`/`+t` caps — OTP defaults for process and atom limits**: an 80000 atom cap caused atom-table exhaustion in production and a silent, zero-log VM boot failure (the VM dies before Logger is configured); the idle-memory saving does not justify it, so the templates set only the scheduler busy-wait flags.
- **`remote.vm.args.eex` is required by Mix**: Mix requires this file for the `remote` and `rpc` commands. Without it, Mix falls back to a cached split from `vm.args.eex` which may not include EEx-processed content correctly.
- **EPMD-less distribution via custom `-epmd_module`**: EPMD-less distribution uses a custom `-epmd_module` callback module (`EvoGit.EpmdDist`) that implements the `erl_epmd` behaviour without contacting any external process. It uses `:persistent_term` as the node→port registry: the remote daemon registers its own listen port at boot, and the local dashboard registers remote-node port mappings (discovered at `Node.connect` time from the SSH tunnel's local port) via `EpmdDist.register_target/2`. This makes `port_please/2` return the correct port directly — no EPMD process needed, no connection refused errors. Do NOT use `-erl_epmd_port N` instead: it sets the EPMD listening port but does NOT prevent `erl_epmd` from trying to connect to a real `epmd` process on port 4369 (causing `econnrefused` in the absence of a running EPMD).
