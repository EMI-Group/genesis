# config/

## Intent
Environment-based Elixir configuration for the EvoGit umbrella project. Follows standard Phoenix `Config` patterns with compile-time overrides per environment and runtime secret management. This directory handles **infrastructure-level** application config only — LLM, scheduler, and agent configuration is managed by `EvoGit.Config` via TOML files.

## Routing Table
None — leaf directory (Elixir config files only).

## API Surface

| File | Purpose | Phase |
|------|---------|-------|
| `config.exs` | Base config — endpoint, asset builders (esbuild/tailwind), logger, JSON lib, `req_llm` HTTP timeouts, sandbox mode | Compile |
| `dev.exs` | Dev overrides — port 4100, code reloader, asset watchers, debug errors | Compile |
| `test.exs` | Test overrides — port 4002, server disabled, warning-level logger | Compile |
| `prod.exs` | Production overrides — static cache manifest, info-level logger | Compile |
| `runtime.exs` | Secrets & dynamic config — `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `PHX_SERVER`, `PHX_IP`; desktop-mode detection via compile-time `:desktop_release` flag (from `genesis_desktop` release in `mix.exs`) OR `EVOGIT_DESKTOP` env var (sets `localhost`/`http`/`check_origin: false` for Tauri WebView). Desktop bind address defaults to loopback (127.0.0.1) for security; `PHX_IP` env var overrides (e.g. `0.0.0.0` for remote access). **Desktop log file**: in desktop mode the default `:logger_std_h` handler is redirected from stdout to `<Platform.data_dir()>/logs/backend.log` (`EvoGit.Platform.data_dir()`: `$XDG_DATA_HOME`/`~/.local/share` on Linux, `~/Library/Application Support` on macOS, `%APPDATA%` on Windows; app name `genesis`). Rotating: 10 MB × 5 files. Path must be a charlist. Falls back to console if `mkdir_p` fails; path announced via `IO.puts("[desktop] Logging to file: ...")` | Runtime |

## Constraints
- **Load order**: `config.exs` imports `{env}.exs` at the bottom — env files override base.
- **Runtime vs compile-time**: Only `runtime.exs` references environment variables; all others are compile-time only.
- **No business logic**: Directory contains only Elixir config files.
- **`dev.local.exs`**: Optional, git-ignored, for developer-specific overrides.
- **Umbrella layout**: Asset paths reference `apps/evo_dash/assets`.
- **LLM config split**: Elixir config handles HTTP timeouts/infrastructure; TOML handles model selection, concurrency, API keys. These are separate systems that don't overlap.
- **Backward compat**: `EvoGit.Defaults` module delegates all calls to `EvoGit.Config.resolve/1`

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
- **No model, provider, or API key config** is set here — those come from TOML (see below)

### In TOML files (via `EvoGit.Config` at `apps/evo_git/lib/evo_git/config/config.ex`)
The **3-level configuration system** (resolved at runtime, not via Elixir `Config`):
1. **Application defaults** — Hardcoded in `EvoGit.Config.defaults/0`: scheduler settings, empty `llm`/`user` maps, sandbox `:auto`, evolution parameters, truncation limits. **No default model or username is provided.**
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant, cross-platform):
   - `[llm]` → `model = "provider:model"` (e.g. `"anthropic:claude-sonnet-4-20250514"`), `compression_threshold_tokens`
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
