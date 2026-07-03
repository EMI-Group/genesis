# LiveView Pages

## Intent
Phoenix LiveView modules and templates for the EvoDash interactive UI — real-time task management, agent inspection, runtime configuration, and user help.

## API Surface

| Module | Route | Summary |
|--------|-------|---------|
| `DashboardLive` | `GET /` | Project-based task dashboard with genesis/evolve forms, auto-mode detection, real-time task cards, and project tabs. Delegates to `TaskRegistry` and `DashboardComponents`. |
| `ReviewLive` | `GET /review/:task_id` | Code review page — diff viewer with syntax highlighting, commit list, agent summary, and action buttons (Merge, Reject, Continue, Create GitHub PR, Extract Skills). The Extract Skills action opens a modal for an optional user note, then starts an `:extract_skills` task via `TaskRegistry` that spawns a `SkillExtractor` agent to distill PR knowledge into `.agents/skills/` files. |
| `AgentsLive` | `GET /agents` | Recursive agent tree inspector with selectable agent detail panel. Reads from ETS tables, auto-refreshes every 500ms. Uses `AgentsComponents.agent_tree/1`. |
| `SettingsLive` | `GET /settings` | Runtime scheduler configuration (concurrency, retries, depth, LLM model). Shows config status warnings. Updates via `AgentScheduler.update_config/1`. Auto-refreshes every 2s. |
| `SystemLive` | `GET /system` | System page: scheduler controls (pause/resume), system controls (restart/stop the Erlang VM), system self-check, plus usage guides and references (example config, CLI usage, FAQ, credentials). |

### Templates
- **`agents_live.html.heex`** — Companion template for `AgentsLive` with sidebar tree + detail panel layout.

### Shared Conventions
- All LiveViews use `use EvoDashWeb, :live_view` and import `CoreComponents` and `Layouts`.
- All pages use `EvoDashWeb.Layouts.app/1` layout with `current_page` for nav highlighting.
- Styled with DaisyUI/Tailwind CSS; business logic delegated to context modules.

## Constraints
- Each LiveView uses either an inline `render/1` or a companion `.html.heex` template — not both. (Three render inline; `AgentsLive` uses a separate template.)
- Auto-refresh intervals must be gated behind `connected?/1` to avoid leaking timers.
- Naming: `<name>_live.ex` for modules, `<name>_live.html.heex` for companion templates.
- **No `try/rescue` around config/core-value loading.** LiveViews must NOT wrap `EvoGit.Config.*`, `EvoGit.AgentScheduler.*`, or `EvoGit.SystemCheck.*` calls in `try/rescue`. If these crash, the LiveView SHOULD crash truthfully — displaying a wrong default value (e.g. `false`, `%{}`, `100_000`) is worse than a visible crash, and the supervision tree handles recovery. Defensive `rescue _ -> default` around these functions is an anti-pattern and must be removed.
- **`try/rescue` for external boundaries requires a justification comment.** The only accepted use is around genuinely untrusted external execution (e.g. `System.cmd` running project-config-defined shell commands in `DashboardLive`'s `run_command`), where a user-friendly error flash is better UX than a LiveView crash. Every retained `try/rescue` must carry a comment explaining why it is justified.
- **Atom conversion from untrusted input uses whitelist lookups, not `try/rescue`.** For converting user-supplied strings (URL params, form POST data) to atoms, use explicit `Map` lookups (`Map.get/2`, `Map.fetch/2`) or `case` against a known whitelist — never `String.to_existing_atom/1` wrapped in `try/rescue`, and never `String.to_atom/1` (atom-table exhaustion DoS risk).
