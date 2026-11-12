# Rel — Mix Release Overlays

## Intent

Release configuration for the Mix releases defined in `../mix.exs`: `genesis` (full, desktop-capable), `genesis_desktop` (Tauri-bundled) and `genesis_server` (the ONLY headless distribution — dashboard server AND SSH remote-dev daemon, shipped with the `genesis` lifecycle CLI).

## Architecture

Every release is built from the top-level EEx templates (`vm.args.eex`, `remote.vm.args.eex`, `env.sh.eex`, `env.bat.eex`); release-specific behavior comes from EEx conditionals on `@release.name`.
`./overlays/` is the only overlay directory an actual release applies: `genesis_server` declares `overlays: ["rel/overlays"]` in `../mix.exs`, so `rel/overlays/bin/genesis` lands in `<release>/bin/genesis` (Mix's file copy preserves the exec bit).
The per-release directory `./genesis/` is NOT applied by Mix — it is a documentation copy of the intended per-release configuration.
SSH remote development drives ONE shared `genesis_server` instance per host and never a second process: the existing `genesis-server` unit (HTTP dashboard always on) is the only thing `genesis remote start` may launch, and Erlang distribution is toggled on it at RUNTIME.
The toggle is owned by `EvoGit.DaemonControl` inside that BEAM: the CLI writes `<data_dir>/remote/control.request`, sends `SIGHUP` to the instance's main pid, and accepts only an answer from `<data_dir>/remote/dist.env` whose `GENESIS_CONTROL_SEQ` matches the seq it just sent.
`<data_dir>/remote/desired.env` (daemon-written, 0600) is the durable intent a restarted instance re-adopts at boot, so `dist.env` stays truthful across restarts.

## Routing Table

- `./overlays/bin/genesis` → headless-server CLI shipped inside the `genesis_server` release (see "Genesis Server CLI")
- `./genesis/` → Per-release template copies (not applied by Mix — documentation only)

## API Surface

### Top-Level Files (applied to every release)

| File | Purpose |
|------|---------|
| `vm.args.eex` | VM arguments template for ALL releases. EPMD-less distribution for every release (`-start_epmd false`, `-epmd_module Elixir.EvoGit.EpmdDist`, `-dist_listen true`; distribution is NOT started at boot for local dashboards — it is enabled on-demand when a remote connection is initiated). `genesis`/`genesis_desktop` also pin `-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9200`; `genesis_server` deliberately omits any `inet_dist_listen_*` range (its listen port is pinned at launch via `GENESIS_REMOTE_DIST_PORT` → `ELIXIR_ERL_OPTIONS`, and a vm-args value would win). Also sets only the scheduler busy-wait flags (`+sbwt none`, `+sbwtdcpu none`, `+sbwtdio none`) — process/atom limits (`+P`/`+t`) are deliberately left at the OTP defaults. |
| `remote.vm.args.eex` | VM arguments for the `remote` and `rpc` shell commands: plain EPMD-less distribution (`-start_epmd false`, `-epmd_module Elixir.EvoGit.EpmdDist`). |
| `env.sh.eex` | Shell environment template for ALL releases. When `GENESIS_REMOTE_DIST_PORT` is set, prepends `-kernel inet_dist_listen_min $GENESIS_REMOTE_DIST_PORT inet_dist_listen_max $GENESIS_REMOTE_DIST_PORT` to `ELIXIR_ERL_OPTIONS` (any existing value preserved) — a launch-time port pin for a daemon started in the legacy remote-daemon mode; the CLI's runtime toggle does not need it, because `EvoGit.Distribution.enable_runtime/3` pins `:kernel inet_dist_listen_min/max` itself before starting `:net_kernel`. Otherwise it only carries commented-out examples. |
| `env.bat.eex` | Windows batch environment template. |

### Overlays (applied by the `genesis_server` release)

| File | Purpose |
|------|---------|
| `overlays/bin/genesis` | POSIX `sh` CLI copied to `<release>/bin/genesis`: `serve`/`run`, `start`, `stop`, `restart`, `status`, `logs`, `url`, `version`, `update`/`upgrade`, `help`, plus the runtime-distribution family `remote start`/`remote stop`/`remote status`/`remote logs`/`remote help`, which toggles Erlang distribution on the shared instance (see "Genesis Server CLI"). |

### Per-Release Directories (documentation only — NOT applied by Mix)

- `./genesis/` — Intended vm.args/env for the `genesis` release

This directory exists as documentation of the intended per-release configuration. It is NOT automatically applied by Mix. To wire it up, custom release `:steps` would need to be added to the release definitions in `mix.exs`.

## Genesis Server CLI (`overlays/bin/genesis`)

`genesis_server` is the headless distribution: `evo_git` + `evo_dash` with `include_erts: true`, `overlays: ["rel/overlays"]`, baked `config: [evo_dash: [server_release: true]]`, and deliberately NO `wx` (headless hosts lack wxWidgets; the dashboard's directory picker already degrades to manual path entry).
Server mode is detected in `../config/runtime.exs` from that baked `server_release` flag (or `EVOGIT_SERVER=1`); the CLI only exports `PHX_IP` and `PORT` (plus `PHX_HOST` when `--host` is given) and execs `<release>/bin/genesis_server start`.
The CLI is POSIX `sh` with `set -eu` and never needs a running BEAM for lifecycle commands.

Commands: bare `genesis` == `genesis serve`; `serve`/`run [--ip ADDR] [--port N]` runs in the foreground (prints the URL, then `exec`s the release; a wildcard bind is annotated); `start [--ip] [--port] [--foreground|-f] [--no-linger]` daemonizes; `stop`, `restart`, `status`, `logs [-f]`, `url`, `version`, `update` (alias `upgrade`), `help`; an unknown command prints usage and exits 2.
`--no-linger` is a global flag (parsed by `parse_flags`, so `restart` inherits it).
`--ip`/`--port` accept both `--flag value` and `--flag=value`.

Environment: `GENESIS_LINGER` (`ask` default, `yes`/`enable` = enable lingering without prompting, `no`/`skip` = say and probe nothing) is the only linger control besides `--no-linger`.
`GENESIS_HOME` and `GENESIS_DATA_DIR` are the other two environment overrides (release root, state/log directory).

Release discovery: `$0` is resolved through symlinks with a portable `readlink` loop (no `readlink -f` — absent on macOS/BSD), then `GENESIS_HOME` is the parent of the script's directory when that directory is `bin`, else the directory itself; an explicit `$GENESIS_HOME` wins. A missing `$GENESIS_HOME/bin/genesis_server` fails with "not inside a Genesis server release; set GENESIS_HOME=…".

Installed version (shared by `genesis version` and `genesis update`): the boot script's `version` answer is parsed to its version TOKEN — a real Mix boot script prints `<release name> <vsn>`, so the SECOND whitespace-separated field is taken (a single-field answer is used unchanged) — falling back to `releases/start_erl.data` field 2 (the staged-tree check `upd_tree_version` always reads that file), then `unknown`.

Backends, chosen per host by `systemd_usable` → `launchd_usable` → pidfile fallback:
`systemd` — `systemd-run --user --unit=genesis-server --collect --property=Restart=on-failure --property=RestartSec=5 --setenv=PHX_IP=… --setenv=PORT=… <launcher> start` (a `reset-failed` precedes it; `--collect` removes the transient unit on exit, `Restart=on-failure` restarts a crashed server); stop is `systemctl --user stop` + `reset-failed`; logs are `journalctl --user -u genesis-server -n 200 [-f]`.
`launchd` — writes/refreshes `~/Library/LaunchAgents/com.genesis.server.plist` (RunAtLoad + KeepAlive, `EnvironmentVariables` with PHX_IP/PORT, StandardOut/ErrPath = the CLI log file) and `launchctl bootout` (when loaded) → `bootstrap gui/<uid>`; stop is `bootout`; logs tail the plist's `StandardOutPath`.
`fallback` (no systemd user manager — containers, minimal distros — or no launchd) — `setsid` (else `nohup`) in the background with `<data_dir>/server.pid` and `<data_dir>/server.log`; stop sends TERM to the pid.
Lingering (systemd backend ONLY, called from `start` as `ensure_linger <backend>` right before `do_start` — so `restart` inherits it and `serve` never runs it): `linger_state` prints exactly one of `enabled` / `disabled` / `unknown` from `loginctl show-user <user>` (`Linger=yes|no`, the full-property form — older loginctl has no `--value`), falling back to `[ -e /var/lib/systemd/linger/<user> ]` when loginctl is missing or its output is unusable (absent marker = `unknown`, never `disabled`).
When the state is `disabled`, `start` offers `loginctl enable-linger <user>`: it prompts only on a TTY (empty/`y`/`Y`/`yes`/`YES` = consent, one line read so `set -eu` survives EOF), never blocks a non-TTY stdin (scripts/CI/containers get the hint instead), honours `GENESIS_LINGER=ask|yes|no` (default `ask`; `yes`/`enable` enables unprompted, `no`/`skip` prints nothing and probes nothing, case-insensitive) and `--no-linger`.
Every linger path only warns (the confirmation goes to stdout, the prompt and all warnings to stderr) and always returns 0 — a refusal or a failed `loginctl` never changes `start`'s exit status, and there is no retry loop (one re-probe after enabling prints the "still disabled" warning).
`start` on an already-running service says so and exits 0; `stop` on a stopped service says "not running" and exits 0.

State and paths: the last ip/port are persisted in `<data_dir>/server.env` as `GENESIS_IP=…` / `GENESIS_PORT=…` (parsed, never sourced) and reused when flags are absent (e.g. by `restart`, `url`, `status`).
`<data_dir>` is `$GENESIS_DATA_DIR`, else `$XDG_DATA_HOME/genesis` (`$HOME/.local/share/genesis` when unset) on Linux, else `~/Library/Application Support/genesis` on macOS — mirroring `EvoGit.Platform.data_dir/0`.
Defaults are ip `127.0.0.1` and port `9999`.

Health probe: `GET <url>/health` via `curl -fsS -m 3`, falling back to `wget -qO- -T 3`, else "no curl/wget" (the probe is inconclusive).
IPv6 bind addresses are bracketed in URLs (`http://[::1]:9999`), and a wildcard bind (`0.0.0.0`/`::`) is displayed as `127.0.0.1` for click-through.
`start` polls the probe for up to 30s after launching and prints success with the URL, or failure plus the last log lines; `status` exits 0 only when the probe returns HTTP 200.

Self-update (`genesis update`, alias `genesis upgrade`) replaces the release tree the CLI itself lives in, and touches the running server only after the release has been fetched, verified, extracted and version-checked.
The release feed is `latest.json`: `<GENESIS_DOWNLOAD_BASE>/latest.json` for the newest build, `<base>/<tag>/latest.json` for a pinned `--version`, with the fallbacks `<GENESIS_DOWNLOAD_FALLBACK_BASE>/latest/download/latest.json` and `<fallback>/download/<tag>/latest.json`.
`GENESIS_DOWNLOAD_BASE` (default `https://genesis.evox.group/dl`) and `GENESIS_DOWNLOAD_FALLBACK_BASE` (default `https://github.com/EMI-Group/genesis/releases`) are read at run time and their trailing slashes are trimmed.
The manifest carries `version`, `notes`, `pub_date` and a `server` object keyed by platform (`linux_x64`, `linux_arm64`, `darwin_arm64`), each entry holding an asset `url` and a `sha256`; it is parsed line-oriented with `sed`/`awk`, so the CLI never needs jq or python.
The tarball is `genesis_server_<platform>.tar.xz` from the same two bases (`<base>/<asset>` for latest, `<base>/<tag>/<asset>` when pinned), and any other platform fails with `no Genesis server build for <platform>` plus the available list.
Verification prefers the manifest's `sha256`, falls back to a published `<url>.sha256`, and warns on stderr and continues when neither exists — the same tolerance as `scripts/install.sh`, so the first upgrade away from an older release still works.
Extraction uses `tar -xJf` and tolerates both a `genesis_server/` tarball root and a flat archive; `bin/genesis_server` must exist and the staged `releases/start_erl.data` release version must match the target version, else nothing is swapped and the server stays untouched.
Flags (both `--flag value` and `--flag=value`): `--check` (check only, never download/install/stop), `--json` (with `--check`: ONE stdout line `{"current":…,"latest":…,"available":true|false}`, plus `pub_date` only when the release publishes one), `--version TAG` (`v0.13.0` or `0.13.0`; normalized to `v…` for URLs and displayed without it), `--force`, `--wait N` (health budget after the restart, default 30, digits only, at least 1) and `--no-linger`.
Exit codes are `0` success or already up to date, `10` update available (`--check` only), `1` failure and `2` usage error; `genesis update --help` prints that contract.
Latest mode never downgrades while an explicit `--version` may install any release, and a target equal to the installed version prints `Genesis <v> is up to date.` and exits 0 without downloading or stopping anything (an undeterminable installed version only warns and treats the manifest version as available).
Safety gate, only while an instance is running: `GET <dashboard url>/server/status` returns `active_tasks`, and a non-zero count refuses the update (exit 1) with `The Genesis server has <n> active task(s)` unless `--force` is passed, an absent/unparseable field only warns, and when `service_active` is false yet `/health` answers a foreground `genesis serve` is refused unless `--force`.
Concurrent updates are serialized by an atomic `mkdir` lock at `<data dir>/update.lock` stamped with `$$`: a live owner means `another update is in progress` (exit 1), a dead owner's lock is recovered and retried, and the EXIT/INT/TERM trap always releases it.
The mutating path fails with a clear message before any download when the install directory's parent is not writable.
The upgrade downloads into a temp dir, stages the tree beside the install (`mktemp -d` in the install parent), stops the service through `do_stop` and waits for `service_active` to go false, moves the live tree to `<install>.old.$$`, moves the staged tree into place, `chmod +x`es `<install>/bin/*`, then restarts through `start_and_wait` with the last `server.env` ip/port and the `--wait` health budget.
A new version that does not become healthy is stopped and the previous tree restored with `The new version did not become healthy; rolling back to <old>.`; the restart of the old version is verified too, and if it also fails both failures are reported with `genesis logs` as the pointer.
On success the CLI prints `Genesis updated: <old> → <new>` and deletes the old tree; when the server was not running it swaps without stop/restart and tells the user to run `genesis start`.
Distribution needs no handling here: the restarted instance re-adopts its intent from `<data dir>/remote/desired.env` at boot.
The other asserted output lines are `Update available: <latest> (installed <current>)`, "Run `genesis update` to install it." (inner backticks included), `Downloading <asset> (<version>)`, `Checksum verified.`, `Installing Genesis <version> to <dir>`, `Stopping the Genesis server.` and `Starting the Genesis server.`.
Remote development (`genesis remote`) is a runtime TOGGLE on the ONE shared instance: exactly one `genesis_server` process per host (the `genesis-server` unit, HTTP always on), with Erlang distribution enabled or disabled on demand — no second unit, no second process, no restart.
Instance discovery reuses the server-side helpers: `service_backend` (systemd user scope / launchd / pidfile fallback), `service_active` and `instance_pid` (systemd `systemctl --user show genesis-server -p MainPID --value`, launchd's `launchctl list com.genesis.server` pid column, else the first line of `<data_dir>/server.pid`).
`genesis remote start --node NODE --cookie COOKIE [--dist-port 9000] [--unit genesis-remote] [--wait 30] [--force]` runs four steps: (1) stop a legacy per-target daemon unit that is still active (system scope when the login is root — the only remaining use of the per-unit helpers) and say so; (2) when the instance is not running, bring it up exactly like `genesis start` (`effective_ip`/`effective_port`, `state_save`, `ensure_linger`, `do_start`, `wait_for_health`, printing the instance-start lines, then the logs tail and exit 1 on failure); (3) when `dist.env` already reports `GENESIS_DIST_ENABLED=1` for that node and `--force` was not passed, print the canonical line and exit 0 without signalling; (4) otherwise write the request and signal, then print exactly `running node=<node> dist_port=<port>` and exit 0 on `GENESIS_CONTROL_RESULT=ok`, the daemon's `GENESIS_CONTROL_MESSAGE` on stderr with exit 1 on `error`, or a diagnostic plus the instance log tail with exit 1 when no matching answer arrives within `--wait`.
`--node`/`--cookie` are required (missing → usage error, exit 2), `--dist-port` is validated as a port (invalid → exit 1), `--wait` is digits-only and floored at 10s (`--wait 0` no longer skips a wait: the daemon's answer is the only evidence the toggle happened), and `--unit` is restricted to `[A-Za-z0-9._-]` and survives only as a compatibility name for legacy cleanup and for the messages/log filters.
`remote stop [--unit NAME]` disables distribution and KEEPS the HTTP instance running (`genesis stop` is what stops the instance): no instance → `Remote daemon is not running (unit NAME).` exit 0; answer `ok` → `Remote daemon stopped (unit NAME).` exit 0; answer `error` → the daemon's message, exit 1; no answer within 10s → diagnostic plus the log tail, exit 1.
`remote status [--unit NAME]` prints `running node=<node> dist_port=<port>` and exits 0 only while the instance is up AND `dist.env` reports `GENESIS_DIST_ENABLED=1`; otherwise it prints `stopped` and exits 1, so a stale `dist.env` can never outlive the instance that wrote it.
`remote logs [--unit NAME] [-f] [-n N]` delegates to the INSTANCE log (`journalctl --user -u genesis-server`, launchd's `StandardOutPath`, else `<data_dir>/server.log`), which also carries the control-plane messages.
`remote help` and the top-level `usage()` describe the toggle, the `--wait` floor, the compatibility-only `--unit`, and that `remote stop` only detaches distribution; an unknown subcommand prints usage and exits 2.

Control protocol (`<data_dir>/remote/`, owned by `EvoGit.DaemonControl`; the CLI never talks to the BEAM over distribution):
`control.request` — CLI-written, atomic (tmp file + `mv -f`), mode 0600 (`umask 077` in a subshell plus `chmod 600`) because it carries the cookie, one plain `KEY=VALUE` per line, each key parsed individually and never sourced or `eval`ed: `ACTION=enable|disable`, `NODE`, `COOKIE`, `DIST_PORT`, `SEQ` (the CLI's own `$$`; a disable request carries only `ACTION` and `SEQ`).
The signal is `kill -HUP <instance main pid>`; a failed signal removes the request again (the CLI then reports exit 3 → "not running") so the next call is unambiguous.
`dist.env` — daemon-written, the authoritative ACTUAL state: `GENESIS_DIST_ENABLED=1|0`, `GENESIS_NODE` (the node it actually came up as), `GENESIS_DIST_PORT` (`unknown` when nil), `GENESIS_CONTROL_SEQ`, `GENESIS_CONTROL_RESULT=ok|error`, `GENESIS_CONTROL_MESSAGE` (one line).
The CLI polls that file in 100ms steps and accepts an answer ONLY when `GENESIS_CONTROL_SEQ` equals the seq it just sent, so a stale file from an earlier call can never be mistaken for a fresh answer.
`desired.env` (daemon-written, 0600, only after a SUCCESSFUL action) is the durable intent a restarted instance re-adopts at boot, which is why `dist.env` stays truthful across `genesis restart`.

Smoke test: `scripts/test-genesis-cli.sh` (bash) builds a temp release with a stub `bin/genesis_server`, shadows systemd/launchd with failing stubs, and asserts help/version/url, flag parsing, the state file, symlink discovery, status failures and exit codes — no real release or service manager needed.
Its remote section asserts the single-instance toggle against a background fake instance (a `SIGHUP`-trapping stub that writes `dist.env` echoing the `SEQ` it read from `control.request`) with a `systemctl show -p MainPID` stub: cold-host start-then-enable with exactly one `systemd-run --unit=genesis-server`, `control.request` at mode 0600, the canonical `running node=… dist_port=…` line, an idempotent re-start that sends no signal, `--force`, a stale `dist.env` that never matches (timeout, never a false success), an `error` answer, legacy-unit cleanup, stop-disables-but-keeps-the-instance, `remote logs` delegation and the usage-error exit codes.
Its update section drives a stub curl/wget against a fixture `latest.json` and a fixture `genesis_server_<platform>.tar.xz`: `--check` exit 10 with the availability line, `--check --json` printing exactly one JSON line, the up-to-date no-op exiting 0 and writing nothing into the data dir, a pinned `--version` (and its `v…` spelling), the download/checksum/extract path, a checksum mismatch and a staged-version mismatch aborting with the server untouched, and the lock/`--force`/usage-error exit codes.

## Known Issues / Notes for Agents

- **No log configuration exists in `rel/`**: none of the env.sh/env.bat/vm.args templates redirect stdout/stderr or set `LOG_*` / `RELEASE_LOG_*` / `ERL_*` log env vars. Desktop log-file redirection is configured OUTSIDE this directory in `../config/runtime.exs` (desktop mode detection via `:desktop_release` flag or `EVOGIT_DESKTOP=1`; Logger `:default_handler` → file at `EvoGit.Platform.data_dir()/logs/backend.log` — `~/.local/share/genesis/logs/` on Linux, `~/Library/Application Support/genesis/logs/` on macOS, `%APPDATA%/genesis/logs/` on Windows; 10 MB × 5 rotated files). The single instance logs to stdout, captured by whatever supervises it (`journalctl --user -u genesis-server` on systemd, the launchd plist's `StandardOutPath`, `<data_dir>/server.log` on the fallback backend) — which is exactly what `genesis logs` and `genesis remote logs` read, including the distribution control-plane messages. The `genesis` CLI captures daemon output in `<data_dir>/server.log` only for the launchd/pidfile backends; systemd keeps it in the user journal.
- There is no `rel/genesis_desktop/` overlay directory — the desktop release uses the top-level EEx templates.
- `rel/overlays/bin/genesis` must keep its executable bit in git (it is copied verbatim into the release, and release tarballs are extracted without a re-chmod step).
- Only `genesis_server` declares `overlays:` (in `../mix.exs`), so anything placed in `rel/overlays/` lands in that release alone — the `genesis` and `genesis_desktop` releases ship no overlay files.
- `genesis update` replaces the WHOLE install tree (stage beside the install, `cp -R`, `mv` swap, rollback by `mv` back), so any extra file shipped anywhere under the release root travels with an update automatically and needs no updater change.
- The post-swap loop in `genesis update` `chmod +x`es every REGULAR file in `<release>/bin/*`, which is how an overlay file's exec bit survives a release tarball extracted without one.
- The legacy per-target daemon helpers (`remote_service_backend`, `remote_systemd_scope`, `do_remote_stop`, the remote launchd plist helpers) survive ONLY so `genesis remote start` can stop an `<unit>` left behind by an older bootstrap; nothing may start such a unit again.

## Constraints

- These are EEx templates — `@release.name` (atom) and other release variables are available.
- VM args templates: do NOT set `-mode`, `-name`, `-sname`, or `-setcookie` — these are configured via env vars.
- VM args templates: do NOT cap the VM with `+P` (max processes) or `+t` (max atoms) — leave both at the OTP defaults.
- Shell env templates: use `export` for variables consumed by the VM/release boot scripts.
- EEx conditionals compare the atom `@release.name` (e.g. `@release.name == :genesis_server`).
- `vm.args.eex` must NOT set an `inet_dist_listen_*` range for `genesis_server`: its distribution port comes from the toggle request at runtime (`EvoGit.Distribution.enable_runtime/3` pins `:kernel inet_dist_listen_min/max` right before starting `:net_kernel`), and a launch-time pin cannot override a vm-args key (a file value wins over `ELIXIR_ERL_OPTIONS`, and a second `-kernel` flag cannot override an earlier one), so a boot-time range would silently fight the port the SSH tunnel forwards to.
- `overlays/bin/genesis` must stay POSIX `sh` (no bash arrays/`local`/`[[ ]]`), `set -eu`, quoted expansions, and rely only on coreutils plus a curl-or-wget health probe.
- `overlays/bin/genesis` is deliberately ONE self-contained file and its length (2500+ lines) is intentional: a release overlay is copied verbatim into `<release>/bin/` and cannot source siblings, so a new capability is a new section in this file, never a second script.
- The updater never stops or replaces anything before the download, the checksum and the staged release version have been validated, and the previous tree is deleted only after the new version answers `/health` — a failed or interrupted update must leave a bootable install behind.
- The remote control plane never sources or `eval`s `control.request`/`dist.env` (each key is read with `sed` and validated) and never writes the cookie anywhere but `control.request` (0600); the only thing it sends is a `SIGHUP` to the instance's own main pid.
- Linger handling is systemd-only and best-effort: never probe or invoke `loginctl` on the `launchd`/`fallback` backends or from `serve`, never prompt when stdin is not a TTY, and never fail (or `die`/`exit`) `start` because of a declined, impossible or failed linger — the server must still start.
- A `genesis_server` release must be built AFTER `mix assets.deploy` (in `apps/evo_dash`): the prod endpoint loads `priv/static/cache_manifest.json` and boot aborts without it, so a bare local `mix release genesis_server` produces an unstartable release (the CI server job runs the shared `setup-mix` action that deploys assets).
- Server mode is detected at runtime from `RELEASE_NAME=genesis_server` (exported by the generated launcher), not from the release definition's `config:` — that option does not reach the generated sys.config in this umbrella project.
- There is no separate remote-daemon boot mode: `EVOGIT_REMOTE_DAEMON` is inert, and `runtime.exs` starts the endpoint whenever `PHX_SERVER` is set, the release is the desktop build, or `EVOGIT_SERVER=1` (what the CLI exports), so HTTP is always on for the single instance and distribution is the only runtime-toggled part.

## Design Decisions

- **EEx conditionals instead of per-release overlays**: Mix does not automatically apply `rel/<release_name>/` overlays. EEx conditionals in the top-level templates achieve the same result more maintainably than adding custom `:steps` to each release definition (which would require duplicating the desktop optimization flags). `rel/overlays/` is used only for the release-wide file overlay (`bin/genesis`) that `genesis_server` declares explicitly.
- **`genesis_server` has no `wx`**: headless servers usually have no wxWidgets runtime, and a missing wx module would fail the whole release boot; the dashboard's directory picker already falls back to manual entry, so dropping it is lossless there.
- **ONE instance per host, distribution toggled at runtime**: an SSH bootstrap used to start a second, distribution-only daemon unit beside the dashboard's `genesis-server`, so a host could end up running two servers with two SQLite stores and two sets of worktrees. Remote development is therefore a toggle on the instance the dashboard already serves: HTTP stays up, `genesis remote start` only ever launches the `genesis-server` unit, and a later toggle needs no restart — the reason the port/name/cookie live in a request file rather than in the launch environment.
- **A control file plus `SIGHUP`, not distribution RPC**: the CLI must work before (or without) a working distribution link, and it is the only thing that knows the pid, so the request/answer exchange goes through `<data_dir>/remote/` — atomic 0600 writes, a `kill -HUP` to wake `EvoGit.DaemonControl`, and a SEQ echoed back into `dist.env` so a stale answer can never be mistaken for a fresh one.
- **One distribution port pin, at enable time**: the toggle's port reaches the VM through `EvoGit.Distribution.enable_runtime/3` (which pins `:kernel inet_dist_listen_min/max` itself), so a single release serves both a plain dashboard server and an SSH-tunnelled one without a second release definition; `env.sh.eex`'s launch-time `GENESIS_REMOTE_DIST_PORT` pin survives only for the legacy daemon mode.
- **A shell CLI instead of a BEAM-based control command**: `status`/`stop`/`logs` must work when the server cannot boot (bad config, missing ERTS, busy port), so lifecycle commands only use the platform supervisor and the HTTP probe. `serve` is a thin `exec`, keeping the process a direct child of the supervisor.
- **Lingering is offered, never required, on `start`**: a `systemd-run --user` unit belongs to the user's session and systemd tears it down at logout unless lingering is enabled, which users experience as "the background server randomly dies"; `start` therefore probes `loginctl show-user` and offers `loginctl enable-linger` (asking only on a TTY, auto-yes under `GENESIS_LINGER=yes`, silence under `no`/`--no-linger`). The fix is advisory rather than fatal — polkit may deny the call, containers often have no loginctl, and starting the server matters more than the linger state, so every outcome degrades to a warning with the manual command.
- **`readlink` loop instead of `readlink -f`**: macOS/BSD `readlink` has no `-f`, and the installer links `~/.local/bin/genesis` to the release, so symlink resolution must be portable.
- **No `+P`/`+t` caps — OTP defaults for process and atom limits**: an 80000 atom cap caused atom-table exhaustion in production and a silent, zero-log VM boot failure (the VM dies before Logger is configured); the idle-memory saving does not justify it, so the templates set only the scheduler busy-wait flags.
- **`remote.vm.args.eex` is required by Mix**: Mix requires this file for the `remote` and `rpc` commands. Without it, Mix falls back to a cached split from `vm.args.eex` which may not include EEx-processed content correctly.
- **EPMD-less distribution via custom `-epmd_module`**: EPMD-less distribution uses a custom `-epmd_module` callback module (`EvoGit.EpmdDist`) that implements the `erl_epmd` behaviour without contacting any external process. It uses `:persistent_term` as the node→port registry: the instance registers its own listen port when the toggle enables distribution, and the local dashboard registers remote-node port mappings (discovered at `Node.connect` time from the SSH tunnel's local port) via `EpmdDist.register_target/2`. This makes `port_please/2` return the correct port directly — no EPMD process needed, no connection refused errors. Do NOT use `-erl_epmd_port N` instead: it sets the EPMD listening port but does NOT prevent `erl_epmd` from trying to connect to a real `epmd` process on port 4369 (causing `econnrefused` in the absence of a running EPMD).
