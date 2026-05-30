# config/

## Intent
Environment-based Elixir configuration for the EvoGit umbrella project. Follows standard Phoenix `Config` patterns with compile-time overrides per environment and runtime secret management.

## Config Files

| File | Purpose | Phase |
|------|---------|-------|
| `config.exs` | Base config — endpoint, asset builders (esbuild/tailwind), logger, JSON lib | Compile |
| `dev.exs` | Dev overrides — port 4100, code reloader, asset watchers, debug errors | Compile |
| `test.exs` | Test overrides — port 4002, server disabled, runtime checks | Compile |
| `prod.exs` | Production overrides — static cache manifest, info-level logger | Compile |
| `runtime.exs` | Secrets & dynamic config — `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, etc. | Runtime |

## Key Configuration Categories

- **`evo_git`** — Concurrency, retry, agent depth, and LLM model defaults. Defined in `EvoGit.Defaults` and passed via opts, not Application config.
- **`evo_dash`** — Phoenix endpoint (Bandit adapter, LiveView signing salt, PubSub), asset builders pointing at `apps/evo_dash/assets`.

## Constraints
- **Load order**: `config.exs` imports `{env}.exs` at the bottom — env files override base.
- **Runtime vs compile-time**: Only `runtime.exs` references environment variables; all others are compile-time only.
- **No business logic**: Directory contains only Elixir config files.
- **`dev.local.exs`**: Optional, git-ignored, for developer-specific overrides.
- **Umbrella layout**: Asset paths reference `apps/evo_dash/assets`.
