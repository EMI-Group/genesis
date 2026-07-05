# config/

## Intent
Environment-based Elixir configuration for the EvoGit umbrella project. Follows standard Phoenix `Config` patterns with compile-time overrides per environment and runtime secret management. This directory handles **infrastructure-level** application config only — LLM, scheduler, and agent configuration is managed by `EvoGit.Config` via TOML files.

## Config Files

| File | Purpose | Phase |
|------|---------|-------|
| `config.exs` | Base config — endpoint, asset builders (esbuild/tailwind), logger, JSON lib, `req_llm` HTTP timeouts, sandbox mode | Compile |
| `dev.exs` | Dev overrides — port 4100, code reloader, asset watchers, debug errors | Compile |
| `test.exs` | Test overrides — port 4002, server disabled, warning-level logger | Compile |
| `prod.exs` | Production overrides — static cache manifest, info-level logger | Compile |
| `runtime.exs` | Secrets & dynamic config — `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `PHX_SERVER`, `PHX_IP`; desktop-mode detection via compile-time `:desktop_release` flag (from `genesis_desktop` release in `mix.exs`) OR `EVOGIT_DESKTOP` env var (sets `localhost`/`http`/`check_origin: false` for Tauri WebView). Desktop bind address defaults to loopback (127.0.0.1) for security; `PHX_IP` env var overrides (e.g. `0.0.0.0` for remote access) | Runtime |

## LLM-Related Configuration

### In this directory (Elixir Application Config)
- **`req_llm`** timeouts in `config.exs` (lines 61–68):
  - `receive_timeout`: 600_000 ms (10 min) — default HTTP response timeout
  - `metadata_timeout`: 600_000 ms — streaming metadata collection timeout
  - `thinking_timeout`: 1_000_000 ms (~17 min) — extended timeout for reasoning models
- **`req_llm`** Finch streaming pool in `runtime.exs` (lines 23–53) — **dynamically sized** from the **total LLM concurrency across all model profiles** (`[[llm.models]]` → `concurrency` per profile). When no profiles are configured (fresh install / legacy flat `[llm]` config), falls back to `[scheduler] max_concurrency`:
  - `stream_pool_count`: `max(sum_of_profile_concurrencies + 2, 8)` — number of connections in ReqLLM's Finch streaming pool. For single-model config with default `concurrency=3`, this is `max(3+2, 8) = 8` (ReqLLM's own default). For multi-model configs, the pool grows to accommodate all models running concurrently.
  - `stream_pool_size`: 1 — connections per pool
  - `stream_pool_protocols`: `[:http1]` — HTTP/1 only (no HTTP/2 multiplexing)
  - `stream_pool_timeout`: 120_000 ms (2 min) — time to wait for a free pool connection
  - Runs at boot *before* `:req_llm` starts its Finch pool, sizing it correctly. The `+2` buffer covers auxiliary non-slot-gated LLM calls (context compression, evolution synthesis, novelty metrics).
  - **Single shared pool**: all providers/models share this one Finch pool — there is no per-model or per-provider pool. The pool is sized to the *sum* of per-model slot pools so that all models can run at full concurrency simultaneously.
- **`evo_git` sandbox** in `config.exs` (line 58): `sandbox: :auto` (can be overridden by TOML)
- **No model, provider, or API key config** is set here — those come from TOML (see below)

### In TOML files (via `EvoGit.Config` at `apps/evo_git/lib/evo_git/config/config.ex`)
The **3-level configuration system** (resolved at runtime, not via Elixir `Config`):
1. **Application defaults** — Hardcoded in `EvoGit.Config.defaults/0`: scheduler settings, empty `llm`/`user` maps, sandbox `:auto`, evolution parameters, truncation limits. **No default model or username is provided.**
2. **User config** — `~/.config/evogit/config.toml` (XDG-compliant, cross-platform):
   - `[llm]` → `model = "provider:model"` (e.g. `"anthropic:claude-sonnet-4-20250514"`), `compression_threshold_tokens`
   - `[scheduler]` → `max_concurrency`, `max_tool_concurrency`, `agent_max_retries`, `max_agent_depth`, `max_retries`
   - `[user]` → `github_username`
   - `[sandbox]` → `mode` ("auto"|"enabled"|"disabled")
   - `[evolution]` → evolutionary algorithm parameters
   - `[truncation]` → tool output and context size limits
3. **Runtime overrides** — CLI flags and dashboard settings, stored in `AgentScheduler` GenServer state

### Credentials (API keys)
- Stored in `~/.config/evogit/credentials.toml` (separate from config for security)
- Format: `PROVIDER_API_KEY = "key-value"` (e.g. `ANTHROPIC_API_KEY = "sk-ant-..."`)
- On load, `EvoGit.Config.credentials/0` reads the file and sets each key-value as an environment variable via `System.put_env/2`
- Supported providers: Google, Anthropic, OpenAI, ZAI, DeepSeek, Groq, Tavily
- The provider is determined from the `[llm] model` format `"provider:model"`

### Per-project config
- `EvoGit.ProjectConfig` reads `evogit.toml` from the repo root (not from `~/.config/evogit/`)
- Supports `worktree.script` and `foreign_repos` sections

## Key Configuration Categories

- **`evo_dash`** — Phoenix endpoint (Bandit adapter, LiveView signing salt, PubSub), asset builders pointing at `apps/evo_dash/assets`
- **`req_llm`** — HTTP timeouts for the LLM HTTP client library
- **`evo_git`** — Infrastructure-level settings only (sandbox mode); all runtime defaults managed by `EvoGit.Config`

## Constraints
- **Load order**: `config.exs` imports `{env}.exs` at the bottom — env files override base.
- **Runtime vs compile-time**: Only `runtime.exs` references environment variables; all others are compile-time only.
- **No business logic**: Directory contains only Elixir config files.
- **`dev.local.exs`**: Optional, git-ignored, for developer-specific overrides.
- **Umbrella layout**: Asset paths reference `apps/evo_dash/assets`.
- **LLM config split**: Elixir config handles HTTP timeouts/infrastructure; TOML handles model selection, concurrency, API keys. These are separate systems that don't overlap.
- **Backward compat**: `EvoGit.Defaults` module delegates all calls to `EvoGit.Config.resolve/1`
