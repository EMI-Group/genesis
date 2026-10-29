# config/

## Intent
Environment-based Elixir configuration for the EvoGit umbrella project. Follows standard Phoenix `Config` patterns with compile-time overrides per environment and runtime secret management. This directory handles **infrastructure-level** application config only — LLM, scheduler, and agent configuration is managed by `EvoGit.Config` via TOML files.

## Routing Table
None — leaf directory (Elixir config files only).

## API Surface

| File | Purpose | Phase |
|------|---------|-------|
| `config.exs` | Base config — endpoint, asset builders (esbuild/tailwind), logger, JSON lib, `req_llm` HTTP timeouts, sandbox mode. The `:logger, :default_formatter` metadata list carries `[:request_id, :remote_ip, :remote_port]` so connection-scoped log lines (e.g. Bandit `Read timeout`) are tagged with the peer address — the signal that distinguishes an IPv6-preferring client from the IPv4-only desktop loopback bind | Compile |
| `dev.exs` | Dev overrides — port 4100, code reloader, asset watchers, debug errors | Compile |
| `test.exs` | Test overrides — port 4002, server disabled, warning-level logger | Compile |
| `prod.exs` | Production overrides — static cache manifest, info-level logger | Compile |
| `runtime.exs` | Secrets & dynamic config — `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `PHX_SERVER`, `PHX_IP`; desktop-mode detection via the `:desktop_release` app-env flag (`genesis_desktop` release in `mix.exs`) OR the Tauri-set `EVOGIT_DESKTOP` env var — in practice only the env var is ever set (see the release-`config:` gotcha in "Server Mode" below) (endpoint `scheme: "http"` + `check_origin: false` for Tauri WebView); server-mode detection via `RELEASE_NAME == "genesis_server"` (the reliable signal — the release launcher always exports it), `EVOGIT_SERVER=1`, or the in-practice-unused `:server_release` app-env flag (see "Server Mode" below). Desktop bind address defaults to loopback (127.0.0.1) for security; `PHX_IP` env var overrides (e.g. `0.0.0.0` for remote access). **The desktop endpoint `url:` host mirrors the resolved bind address** (`:inet.ntoa(desktop_ip)` → `"127.0.0.1"` by default, or the `PHX_IP` / `[server] listen_ip` value; also the loopback fallback for an unparseable address) rather than the literal `"localhost"` — the socket binds IPv4 loopback only, while macOS/Windows resolve `localhost` to `::1` first, so a `localhost` URL would advertise an address no client preferring IPv6 can reach (boot-log `Access EvoDashWeb.Endpoint at …` + any future absolute-URL generation). Port logic is shared by all modes, and the endpoint branch is a three-way `cond` — desktop → server mode (see "Server Mode" below) → the unchanged generic-prod branch (PHX_HOST / 443 / https / `{0,0,0,0,0,0,0,0}`); `config.exs` still sets the compile-time `url: [host: "localhost"]` default that these branches override in prod. **Desktop log file**: in desktop mode the default `:logger_std_h` handler is redirected from stdout to `<Platform.data_dir()>/logs/backend.log` (`EvoGit.Platform.data_dir()`: `$XDG_DATA_HOME`/`~/.local/share` on Linux, `~/Library/Application Support` on macOS, `%APPDATA%` on Windows; app name `genesis`). Rotating: 10 MB × 5 files. Path must be a charlist. Falls back to console if `mkdir_p` fails; path announced via `IO.puts("[desktop] Logging to file: ...")` | Runtime |

## Boot-Time Behavior (desktop release / sidecar)

`runtime.exs` is evaluated by the release's `Config.Provider` at boot BEFORE any application starts — a `raise`/`exit` here aborts the whole backend start, so the sidecar process exits and the Tauri shell's readiness probe (`BACKEND_READY_TIMEOUT_SECS = 30`, `desktop/src-tauri/src/main.rs:41`) shows the "Genesis backend unavailable" page.

**Env parsed at boot** (all set by the Tauri shell — `desktop/src-tauri/src/sidecar.rs:110-126`, `desktop/src-tauri/src/main.rs:548-571`): `PORT` (numeric free port), `PHX_IP` (default `127.0.0.1`), `PHX_SERVER=true`, `SECRET_KEY_BASE` (hardcoded desktop key), `RELEASE_DISTRIBUTION=none`, `EVOGIT_DESKTOP=1`, `EVOGIT_LIFETIME_PORT` (optional). Desktop mode is detected by `Application.get_env(:evo_dash, :desktop_release, false) or System.get_env("EVOGIT_DESKTOP") == "1"` (runtime.exs:157-159); the `desktop_release: true` baked by the `genesis_desktop` release definition in `mix.exs` never reaches sys.config, so in practice the Tauri env var is the only live signal.

**Boot I/O** (all fast; no network): `EvoGit.Config.resolve()` (runtime.exs:92) reads `~/.config/genesis/config.toml` via `EvoGit.Config.user_config/0` → `cached_file_read` (`File.stat` + `File.read`, `:persistent_term`-cached by mtime+size) then runs `EvoGit.Config.Schema.validate/1`; `EvoGit.Platform.data_dir/0` (runtime.exs:281, and again in server mode for the persisted secret key) resolves `[:data, :dir]` (schema default `nil` → platform default) via `EvoGit.Config.resolve` + path joins + `System.user_home!()`; `File.mkdir_p(<data_dir>/logs)` (runtime.exs:283) creates the log dir; `EvoGit.ReqLLMPool.desired_count/1` (runtime.exs:111) is pure math `max(total+2, 8)` and `Finch.Pool.Strategy.RoundRobin.new()` allocates an `:atomics` ref.

**Malformed/missing config.toml does NOT crash or hang the backend**: `read_toml_file/3` rescues `File.read`/`TomlElixir.decode` errors → `Logger.warning` + returns `%{}` (`apps/evo_git/lib/evo_git/config/config.ex:465-483`); `Schema.validate/1` uses the non-raising `safe_get_in` and merely collects errors → warnings (`config.ex:168-184`).

**Reachable `raise`s**: only the missing-`SECRET_KEY_BASE` `raise` (runtime.exs:245), and it is reached only when the operator set neither the env var nor desktop/server mode (desktop short-circuits to the hardcoded key, server mode to the persisted key — neither ever raises). No `System.halt`/`System.stop`/`exit` anywhere in this directory. Inference-only raise risks: `System.user_home!()` if `HOME` is unset (via `Platform.data_dir/config_dir`) and `String.to_integer(PORT)` if `PORT` is non-numeric (the shell always sets a numeric value).

**Not version- or release-path-keyed**: every path here is a home-based user dir (`~/.config/genesis`, `<data_dir>` = `~/.local/share/genesis` on Linux, `<data_dir>/logs`) that survives updates — `runtime.exs` never references the release directory. The boot work in this directory is therefore identical on the first boot from a freshly-updated release dir vs a later boot, so nothing here explains a first-launch-after-update slowness/failure.

**Logging — `backend.log` semantics** (how to read a user's `backend.log`): log lines ARE timestamped — `config.exs:58-60` sets `format: "$time $metadata[$level] $message\n"` with `metadata: [:request_id, :remote_ip, :remote_port]`; the line format carries **no PID**, so a `#PID<…>` appears only inside crash/supervisor REPORT bodies (e.g. `Process #PID<0.123.0> terminating`) — those PIDs are the ONLY in-file discriminator between a freshly spawned BEAM (pid counter reset) and an in-node OTP `System.restart/0` (counter continues), and no OS pid is ever logged.
Level is `:info` in prod (`prod.exs:11`) and the release payload is prod; dev overrides only the format (`"[$level] $message\n"`, `dev.exs:59`).
In desktop mode the default `:logger_std_h` handler is redirected from stdout to `<data_dir>/logs/backend.log` (`runtime.exs:280-313` — `type: :file`, no `modes` override); stdout is still used for the `IO.puts("[desktop] Logging to file: …")` announcement (`runtime.exs:302`) and as the fallback when the log dir can't be created (`runtime.exs:308`).
**The file is APPENDED, never truncated** — `logger_std_h` opens file handlers in append mode, so ONE `backend.log` accumulates the boot sequence of EVERY backend launch (and of every in-process runtime restart); a file containing three boot sequences is normal and proves nothing by itself about how many OS processes ran.
Rotation (`max_no_bytes: 10_000_000`, `max_no_files: 5` — `runtime.exs:292-298`) RENAMES the current file to `backend.log.0` … `.4` (`FileName.0` is the NEWEST archive — OTP `logger_std_h` docs; archives past 5 are deleted) and never rewrites the live file; worst-case disk ≈ 50–60 MB (live file + up to 5 archives of 10 MB — the source comment's "50 MB" counts only the archives).
Server mode does NOT take this branch (it keeps console/stdout logging — see "Server Mode").
No other code owns this file: neither app writes, reconfigures, or deletes it (no `Logger.configure`/`add_handler`/`File.rm` on log paths anywhere in the umbrella) — this handler is the only writer.

**Desktop port is SINGLE-SHOT.** `PORT` is read exactly ONCE per BEAM at config-provider time (`runtime.exs:251-269`) and feeds both `http: [ip: …, port: port]` and `url: [host: …, port: port]` (`runtime.exs:347-361` for desktop, `:363-379` for server mode), so the advertised URL and the listener can never disagree, and **a single BEAM can never end up listening on a different port than its `PORT` env var** (nothing re-reads `PORT`; the app's only `config_change` → `Phoenix.Endpoint.Supervisor.config_change/3` never restarts or re-binds the listener).
A non-numeric `PORT` raises `String.to_integer/1` at boot; an OCCUPIED port fails Bandit's bind → the endpoint child fails → `EvoDash.Application.start/2` aborts with NO retry and NO alternative port, and since `evo_dash` is `:permanent` in the release the whole VM goes down (the Tauri watchdog then classifies a non-zero exit and respawns). Free-port selection/fallback exists only OUTSIDE the BEAM (shell startup `resolve_backend_port`); the only in-BEAM failure window is a shell-probe/bind race.

Nothing in this directory restarts or stops the runtime — no `System.stop/halt/restart`, `:init.stop`, or `Application.stop`, and no disk/memory monitor: disk-full is handled at the write choke points in `:evo_git` (logged, degraded), never by exiting. The only restart-adjacent knob here is `finalizing_watchdog_grace_minutes` (`config.exs:73`), which merely flips a stuck task row to `:failed` without touching the VM.

## Server Mode (headless `genesis_server` release)

A first-class mode for the `genesis_server` release (both apps, no wx), for serving the dashboard headlessly over plain HTTP (LAN IP / hostname) instead of through a desktop WebView.
Detection: `Application.get_env(:evo_dash, :server_release, false) or System.get_env("EVOGIT_SERVER") == "1" or System.get_env("RELEASE_NAME") == "genesis_server"` — `RELEASE_NAME` is the PRIMARY (reliable) signal: the release launcher always exports it, and the `genesis` CLI additionally exports `EVOGIT_SERVER=1`; either suffices.
**Gotcha — the `config:` option of a Mix release definition in this umbrella project does NOT appear in the generated `releases/<vsn>/sys.config` when `runtime.exs` evaluates.** So on a real `genesis_server` boot the baked `server_release` app-env flag reads `false` and detection rides on `RELEASE_NAME`; `mix.exs`'s `genesis_desktop` `desktop_release` flag behaves the same, which is why desktop mode really relies on the Tauri-set `EVOGIT_DESKTOP=1`. Do not rely on a baked release flag for mode detection (relying on it made `runtime.exs` fall into the generic-prod branch and abort boot with "environment variable SECRET_KEY_BASE is missing").
The shared `server_mode` binding is defined at the top of `runtime.exs` and used both by the endpoint-server toggle (`server: true`) and the prod block.
Endpoint: `server: true`, `url: [host: <PHX_HOST env, else the resolved bind address>, port: port, scheme: "http"]`, `check_origin: false`.
`check_origin: false` is required because the dashboard is reached over plain http via a LAN IP / hostname that no fixed origin allowlist can cover (same reasoning as desktop, different origin shape).
Bind address: same resolution/validation as desktop — `PHX_IP` env → config.toml `[:server, :listen_ip]` → `127.0.0.1` fallback, with the `:inet.parse_address` parse, loopback fallback and `IO.warn` on an unparseable value.
Port: `PORT` env → config.toml `[:server, :listen_port]` (schema default 9999); the desktop-only `9999` safety net does not apply (server mode is not a desktop release).
`secret_key_base`: `SECRET_KEY_BASE` env wins; otherwise a key is persisted at `<EvoGit.Platform.data_dir()>/secret_key_base` — read when present, else 48 random bytes Base64-encoded, written non-raising (`File.write(path, secret, [:binary])`) followed by `File.chmod(path, 0o600)`, with the data dir created first.
The persisted key is stable across restarts (cookies/sessions keep working); any read/write/mkdir/resolve failure warns via `IO.warn` and falls back to the generated in-memory key so boot never aborts on permissions.
Logging: server mode keeps console (stdout/stderr) logging — journald captures it; it deliberately does NOT enter the desktop `backend.log` file-handler branch (`desktop_mode` stays false).
Remote-dev daemon unaffected: the `genesis_remote` guard at the top of the prod block is unchanged (that release is `evo_git`-only and has no endpoint at all).

**How it differs from desktop mode**

| Aspect | Desktop (`genesis_desktop`) | Server (`genesis_server`) |
|--------|------------------------------|---------------------------|
| Trigger | `EVOGIT_DESKTOP=1` (Tauri sidecar; the `desktop_release` flag never reaches sys.config) | `RELEASE_NAME=genesis_server` (release launcher) / `EVOGIT_SERVER=1` |
| Bind default | loopback (127.0.0.1) | loopback (127.0.0.1) |
| Port source | `PORT` (shell-picked free port) → `9999` | `PORT` → `[server] listen_port` (9999) |
| `secret_key_base` | fixed hardcoded local key / `SECRET_KEY_BASE` | `SECRET_KEY_BASE` → persisted `<data_dir>/secret_key_base` (0600) |
| Logging | rotating `<data_dir>/logs/backend.log` | console/stdout (journald) |
| Lifecycle | Tauri sidecar + lifetime pipe + watchdog | operator/`genesis` CLI managed process |

## Constraints
- **Load order**: `config.exs` imports `{env}.exs` at the bottom — env files override base.
- **Runtime vs compile-time**: Only `runtime.exs` references environment variables; all others are compile-time only.
- **No business logic**: Directory contains only Elixir config files.
- **`dev.local.exs`**: Optional, git-ignored, for developer-specific overrides.
- **Umbrella layout**: Asset paths reference `apps/evo_dash/assets`.
- **LLM config split**: Elixir config handles HTTP timeouts/infrastructure; TOML handles model selection, concurrency, API keys. These are separate systems that don't overlap.

## LLM-Related Configuration

### In this directory (Elixir Application Config)
- **`req_llm`** timeouts in `config.exs` (lines 61–68):
  - `receive_timeout`: 600_000 ms (10 min) — default HTTP response timeout
  - `metadata_timeout`: 600_000 ms — streaming metadata collection timeout
  - `thinking_timeout`: 1_000_000 ms (~17 min) — extended timeout for reasoning models
- **`req_llm`** Finch streaming pool in `runtime.exs` (lines 23–80) — **dynamically sized** from the **total LLM concurrency** across all configured model profiles (`[[llm.models]]` → `concurrency` per profile). Effective concurrency = `max(Σ profile concurrencies, default_llm_max_concurrency)`: unknown model ids (per-task `-m` flags not matching any profile) are gated by `[scheduler] default_llm_max_concurrency` as an **independent slot bucket** (each model profile has its own slot pool; unknown models share the default bucket), so the default must be counted even when profiles exist. When no profiles are configured (fresh install / legacy flat `[llm]` config), the effective concurrency is just `default_llm_max_concurrency`. Configured via the full `finch:` override form (NOT the `stream_pool_*` shorthand — those keys are only consumed by ReqLLM's `get_default_pools/0`, which is bypassed when `finch.pools` is set):
  - `finch.pools.default.count`: `EvoGit.ReqLLMPool.desired_count(total_concurrency)` = `max(total_concurrency + 2, 8)` — number of pool processes (shards) in ReqLLM's Finch pool. With `size: 2` each shard holds up to 2 connections (opened lazily on checkout), so capacity = `count × 2` concurrent HTTP/1 streams per origin. The +2/floor-8 formula lives **only** in `EvoGit.ReqLLMPool.desired_count/1` (single source of truth, shared with the runtime reconciliation module — do NOT duplicate it inline). For single-model config with default `concurrency=3`, this is `max(3+2, 8) = 8` (ReqLLM's own default). For multi-model configs, the pool grows to accommodate all models running concurrently.
  - **Per-origin semantics**: Finch materializes one pool **per origin** (`scheme://host:port`), lazily, from this single `:default` template — capacity is per-origin, not global. Summing total concurrency is the safe upper bound because any single origin's demand ≤ total (requests to origin A only use pool A).
  - `finch.pools.default.size`: 2 — connections per pool process (per-shard upper bound; connections open lazily on checkout). `size: 2` IS a valid pool-template key in finch 0.23.0.
  - `finch.pools.default.protocols`: `[:http1]` — HTTP/1 only (no HTTP/2 multiplexing)
  - `finch.pools.default.start_pool_metrics?`: `true` — **required** so `Finch.get_pool_status(ReqLLM.Finch, :default)` can enumerate materialized origins; `EvoGit.ReqLLMPool` depends on this to dynamically reconcile the pool at runtime. Without it, reconciliation is a silent no-op (`{:error, :not_found}` always).
  - `stream_pool_strategy`: `{Finch.Pool.Strategy.RoundRobin, counter}` — top-level key, read at CALL time (`streaming/finch_client.ex:426-428`), NOT part of the pool config — the per-request `pool_strategy` opt for RoundRobin shard selection (required to spread requests across the `size: 2` shards). `counter = Finch.Pool.Strategy.RoundRobin.new()` (an `:atomics` ref); a bare module would crash (`mod.select(entries, nil)` → badarg). There is NO `strategy:` key in the pool template — NimbleOptions raises on unknown keys at boot.
  - `stream_pool_timeout`: 300_000 ms (5 min) — top-level key, read at CALL time (`streaming/finch_client.ex:299-305`), NOT part of the pool config — time to wait for a free pool connection before the "excess queuing" RuntimeError
  - Runs at boot *before* `:req_llm` starts its Finch pool, sizing it correctly. The `+2` buffer (inside `EvoGit.ReqLLMPool.desired_count/1`) covers auxiliary non-slot-gated LLM calls — the only such calls today are the LLM self-check (`system_check.ex`) and PR-title generation (`pull_request.ex`); context compression IS slot-gated.
  - **Dynamic reconciliation**: `EvoGit.ReqLLMPool` (apps/evo_git) grow-only resizes the pool at runtime when (a) scheduler config changes (`AgentScheduler.update_config` — dashboard saves, `reload_config`, `save_user_config`) and (b) the Finch "excess queuing" RuntimeError is observed in the agent retry loop (`ToolDispatch.call_llm_with_retry`). Pools are materialized lazily per provider origin; new origins appear at the boot `count` until the next reconcile/error-bump.
  - **Single shared pool**: all providers/models share this one Finch pool — there is no per-model or per-provider pool. The pool is sized to the effective total concurrency (profile sum ∪ default bucket) so that all models can run at full concurrency simultaneously.
- **`evo_git` sandbox** in `config.exs` (line 58): `sandbox: :auto` (can be overridden by TOML)
- **`evo_git` stuck-`:finalizing` watchdog grace** in `config.exs` (`config :evo_git` block): `finalizing_watchdog_grace_minutes: 60` — minutes a task may remain `:finalizing` before `EvoGit.TaskRegistry` resolves it to `:failed`; `false` disables the watchdog. Overridden to `1` in `test.exs` (short grace so tests exercise the watchdog fast)
- **No model, provider, or API key config** is set here — those come from TOML (see below)

### In TOML files (via `EvoGit.Config` at `apps/evo_git/lib/evo_git/config/config.ex`)
The **3-level configuration system** (resolved at runtime, not via Elixir `Config`):
1. **Application defaults** — Hardcoded in `EvoGit.Config.defaults/0`: scheduler settings, empty `llm`/`user` maps, sandbox `:auto`, evolution parameters, truncation limits. **No default model or username is provided.**
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant, cross-platform):
   - `[llm]` → `model = "provider:model"` (e.g. `"anthropic:claude-sonnet-4-20250514"`), `[[llm.models]]` profiles (`id`, `model`, `concurrency`, optional `context_window` default 200_000, generation params, peak/off-peak fields), optional `compression_threshold_tokens` override (nil = derive from the profile's `context_window`), `tool_result_pruning`, `tool_result_pruning_target_fraction`
   - `[scheduler]` → `default_llm_max_concurrency`, `max_tool_concurrency`, `agent_max_retries`, `max_agent_depth`, `max_retries`
   - `[user]` → `github_username`
   - `[sandbox]` → `mode` ("auto"|"enabled"|"disabled")
   - `[evolution]` → evolutionary algorithm parameters
   - `[truncation]` → tool output and context size limits
3. **Runtime overrides** — CLI flags and dashboard settings, stored in `AgentScheduler` GenServer state

### Credentials (API keys)
- Stored in `~/.config/genesis/credentials.toml` (separate from config for security)
- Format: `PROVIDER_API_KEY = "key-value"` (e.g. `ANTHROPIC_API_KEY = "sk-ant-..."`)
- On load, `EvoGit.Config.credentials/0` reads the file and sets each key-value as an environment variable via `System.put_env/2`
- Supported providers: Google, Anthropic, OpenAI, ZAI, DeepSeek, Groq, Tavily
- The provider is determined from the `[llm] model` format `"provider:model"`

### Per-project config
- `EvoGit.ProjectConfig` reads `genesis.toml` from the repo root (not from `~/.config/genesis/`)
- Supports `worktree.script` and `foreign_repos` sections

## Key Configuration Categories

- **`evo_dash`** — Phoenix endpoint (Bandit adapter, LiveView signing salt, PubSub), asset builders pointing at `apps/evo_dash/assets`
- **`req_llm`** — HTTP timeouts for the LLM HTTP client library
- **`evo_git`** — Infrastructure-level settings only (sandbox mode); all runtime defaults managed by `EvoGit.Config`
