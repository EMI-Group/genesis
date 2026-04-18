# config/

## Intent
This directory contains all configuration files for the **EvoGit** umbrella Elixir project. It follows the standard Phoenix framework configuration pattern using Elixir's `Config` module, with environment-specific overrides and runtime secret management. The configuration serves two OTP applications:

- **`:evo_dash`** — The Phoenix web dashboard (LiveView UI, endpoint, asset pipeline)
- **`:evo_git`** — The core Git automation/agent engine (LLM integration, concurrency, retry logic)

## API Surface

| File | Purpose |
|---|---|
| `config.exs` | **Base configuration** — loaded first for all environments. Sets up EvoDash endpoint (Bandit adapter, LiveView signing salt), esbuild/tailwind asset builders, logger format, and Jason as JSON library. Imports the environment-specific file at the bottom. |
| `dev.exs` | **Development overrides** — HTTP port 4100 (overridable via `PORT` env), code reloader enabled, esbuild/tailwind watchers with `--watch`, debug errors, LiveView debug annotations, dev routes enabled, warning-level logger. Optionally imports `dev.local.exs` if present (git-ignored). |
| `test.exs` | **Test overrides** — HTTP port 4002, server disabled, warning-level logger, runtime plug init mode, LiveView expensive runtime checks enabled. |
| `prod.exs` | **Production compile-time overrides** — static asset cache manifest, info-level logger. Runtime secrets are handled in `runtime.exs`. |
| `runtime.exs` | **Runtime configuration** — executed after compilation, before system start. Reads `PHX_SERVER` env to enable server. In `:prod` env, reads `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, and `DNS_CLUSTER_QUERY` from environment variables (raises if `SECRET_KEY_BASE` is missing). |

### Key Configuration Values

**evo_git settings** (defined in `EvoGit.Defaults`, passed via opts at runtime):
- `max_concurrency: 3` — Max parallel tasks
- `max_retries: 15` — Maximum retry attempts for operations
- `agent_max_retries: 3` — Maximum retries for agent-specific operations
- `max_agent_depth: 5` — Maximum agent recursion depth
- `llm_model` — Default: `"zai_coding_plan:glm-5"`

These values are no longer stored in Application config. They are defined in `EvoGit.Defaults` and passed explicitly through opts/state to all modules.

**evo_dash endpoint** (EvoDashWeb.Endpoint):
- Adapter: `Bandit.PhoenixAdapter`
- PubSub: `EvoDash.PubSub`
- Asset builders: esbuild `0.25.4`, tailwind `4.1.7` (referencing `apps/evo_dash/assets`)

## Constraints
- **Load order matters**: `config.exs` is loaded first and imports the environment-specific file (`#{config_env()}.exs`) at the bottom, so env files override base settings.
- **Runtime vs compile-time**: Only `runtime.exs` may reference environment variables for secrets; `config.exs`, `dev.exs`, `test.exs`, and `prod.exs` are compile-time.
- **No source code**: This directory must contain only Elixir config files — no modules, no business logic.
- **`dev.local.exs`**: May exist locally for developer-specific overrides; it is git-ignored and never committed.
- **Umbrella structure**: Asset paths in esbuild/tailwind config reference `apps/evo_dash/assets`, reflecting the umbrella project layout.
- **Environment variable dependencies** (production): `SECRET_KEY_BASE` (required), `PHX_HOST`, `PORT`, `PHX_SERVER`, `DNS_CLUSTER_QUERY`.
