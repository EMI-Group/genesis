# EvoGit — Core Runtime Application

## Intent
The `:evo_git` OTP application implements an evolutionary software development runtime where LLM-powered agents create, analyze, and modify codebases using git worktree isolation. The system models a codebase as a **Context Tree** (spatial dimension) and a **Phylogenetic Graph** (temporal dimension).

## Routing Table
| Directory | Purpose |
|---|---|
| `./lib/` | Application source (agents, core domain, adapters, runtime, scheduler, config) |
| `./test/` | ExUnit test suite using real git operations on temp directories |

## Top-Level Modules
| Module | Description |
|---|---|
| `EvoGit` | Sandboxed command execution via `EvoGit.Sandbox` (`sandbox_run/4`, `sandbox_args/4` delegates to platform backend) |
| `EvoGit.Application` | OTP application callback (starts `AgentScheduler`, conditionally `SandboxSlice` on Linux) |
| `EvoGit.CLI` | Command-line interface entry point |
| `EvoGit.Agent` | Behaviour module for agents; injects agent loop, tool dispatch, subagent management |
| `EvoGit.Agent.Usage` | Cumulative token and cost usage tracking (`Usage` struct with `add/2`, `from_response_usage/1`, `zero/0`) |
| `EvoGit.AgentSpec` | Structured specification for spawning agents; `opts` keyword list carries `:archive`, `:model_id`, and other runtime flags |
| `EvoGit.AgentScheduler` | GenServer managing agent lifecycles, worktree pool, ETS state (`:evogit_agent_state`, `:evogit_sched_meta`, `:evogit_archive_records`), slot management. **Task-status model**: only `:pending | :running | :waiting | :ready | :blocked` — there is **NO `:failed` status in the core runtime**. The only task-level status broadcast is `{:task_status, task_id, :finalizing}` via `Runtime.Helpers.notify_finalizing/1` (PubSub topic `"tasks"`). The `:failed`/`:completed`/`:cancelled` task statuses are a **dashboard (`evo_dash`) concept** derived from agent result tuples and wrapper-process `:DOWN` messages (see `EvoDash.TaskRegistry`). |
| `EvoGit.Sandbox` | Multi-platform sandbox dispatch (selects Linux/macOS/None backend based on platform) |
| `EvoGit.SandboxSlice` | GenServer managing the `evogit.slice` systemd user slice (Linux only) |
| `EvoGit.Task` | Agent orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | Top-level coordinator: Genesis and Evolution phases |
| `EvoGit.Runtime.Helpers` | Shared helper functions for runtime phases (merge_and_report, notify_finalizing, generate_branch_name, new_codebase?, validate_node_path, resolve_starting_commit) |
| `EvoGit.ProjectConfig` | Reads and parses `genesis.toml` from repo root |
| `EvoGit.Review` | Code review operations: load diff data, merge/reject branches, manual GitHub PR creation |
| `EvoGit.Config` | Unified 3-level configuration resolver (defaults → user TOML → runtime overrides) |
| `EvoGit.Defaults` | Backward-compatibility shim delegating to `EvoGit.Config` |
| `EvoGit.Platform` | Cross-platform OS detection, config/data directory resolution |
| `EvoGit.Nix` | Nix develop integration helper — builds the dev env ONCE via `nix print-dev-env`, caches the bash script to `<data_dir>/nix-dev-env.sh`, and sources it per tool call via `bash -c`. `active?/0` gate gracefully disables nix if the build fails |

## Subdirectories
| Directory | Purpose |
|---|---|
| `./lib/evo_git/core/` | `ContextNode` (spatial) and `PhyloGraphNode` (temporal) data structures |
| `./lib/evo_git/adapters/` | `Git` CLI adapter — thin wrapper around `System.cmd("git", ...)` |
| `./lib/evo_git/agent/` | Agent behaviour, tool library, context compression, subagent processing, usage tracking |
| `./lib/evo_git/agents/` | Agent implementations (Manager, Executor, TaskScheduler, Investigator, Architect, Extractor, Evaluator) |
| `./lib/evo_git/runtime/` | Genesis, Evolution, and Prompts (LLM templates) |
| `./lib/evo_git/agent_scheduler/` | `AgentState`, `SchedMeta`, `Slots`, `Worktrees` — ETS schemas and helper logic |
| `./lib/evo_git/config/` | `EvoGit.Config` — defaults, user TOML, credentials, API keys |
| `./lib/evo_git/sandbox/` | `EvoGit.Sandbox` — multi-platform sandbox backends (Linux, macOS, None) |

## Constraints
- Part of an **umbrella project** — deps, build artifacts, and lockfile live at the repository root.
- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd("git", ...)` in domain modules.

### Distribution & Release Setup (relevant to remote/SSH features)
- **Erlang distribution is DISABLED by default.** `rel/vm.args.eex` (line 28) hard-codes `-start_epmd false` (enabled, not commented). `rel/remote.vm.args.eex` exists for remote console but has epmd/dist commented out. `rel/env.sh.eex` / `rel/env.bat.eex` contain commented-out `RELEASE_DISTRIBUTION`/`RELEASE_NODE` examples. The desktop release (Tauri sidecar) explicitly sets `RELEASE_DISTRIBUTION=none` (see `desktop/src-tauri/src/sidecar.rs`).
- **Phoenix.PubSub uses the bare `{Phoenix.PubSub, name: EvoGit.PubSub}`** (see `EvoGit.Application.start/2`, line 21) with NO adapter options → defaults to the PG2 adapter. EvoDash has its own separate `EvoDash.PubSub`. **PubSub does NOT work across nodes** without distribution + a distributed adapter; out of the box everything is single-node/local.
- **No `Node.set_cookie`, `Node.connect`, `:net_kernel`, or `inet_dist_listen` anywhere** in `evo_git/lib`. Distribution would need to be re-enabled (remove `-start_epmd false`, set `RELEASE_DISTRIBUTION=name`/`sname` + a cookie) to support multi-node features.
- Release definitions live in the **umbrella root** `mix.exs` (`releases: [genesis:, genesis_desktop:]`), not under `apps/evo_git/rel/`. There are **no `apps/evo_git/rel/` overlays** — all `rel/` overlays are at the repo root (`rel/`).
- **Endpoint bind config** is resolved in `config/runtime.exs` (prod only): `PORT`/`PHX_IP` env vars take priority, else `config.toml` `[server] listen_port`/`listen_ip` (schema-defined in `EvoGit.Config.Schema.Definitions`). Desktop mode binds loopback by default; non-desktop prod binds `{0,0,0,0,0,0,0,0}` (all interfaces).
- Agents are transient modules using `EvoGit.Agent` behaviour; the framework manages state via ETS.
- Agent execution happens in **isolated git worktrees** managed by `AgentScheduler` — never on the main working copy.
- Subdirectories follow Elixir convention: `./lib/evo_git/<subdir>/` maps to `EvoGit.<Subdir>` namespace.
- **Three-level configuration**: `EvoGit.Config` merges built-in defaults → user config (`~/.config/genesis/config.toml`) → runtime overrides. No default model or username is hardcoded.
- **Slot discipline**: All LLM calls must acquire/release slots via `AgentScheduler`. **Multi-model support**: the runtime supports multiple LLM models simultaneously, each with its own independent concurrency slots, generation params, and per-model 60-second backoff (a rate-limit on one model does NOT block agents using other models). Config via `[[llm.models]]` TOML array-of-tables (each profile: `id`, `model`, `concurrency`, generation params). Old flat `[llm]` config auto-migrates to a single-profile list with id `"default"` **at load time only** (`Config.resolve/0` → `migrate_llm_models/1`). On **save** (`Config.save_user_config/1`), flat gen-param fields are stripped from the written TOML when `llm.models` is non-empty — only `[[llm.models]]` + `compression_threshold_tokens` are written (the new standard). `stringify_keys` recurses into lists so atom-keyed profile maps serialize correctly. `AgentSpec.model_id` binds an agent to a profile; child agents inherit the parent's `model_id` by default. Tool executions are independently throttled via `max_tool_concurrency`.
- **Task-scoped naming**: Worktree directories use `worker_T<task_number>_A<task_local_id>`, branches use `evogit-agent-T<task_number>-A<task_local_id>`. The `task_id` is a 16-char hex GUID used for global identification (archive refs, task grouping); the `task_number` is a short integer (from a linear scan of `.genesis/workers/`) used only for naming.
- `EvoGit.Defaults` is a backward-compatibility shim. New code should use `EvoGit.Config` directly.

### ⚠️ `mix run` starts BOTH umbrella apps (including :evo_dash)
**The documented CLI invocation `mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis|evolve|setup` runs at the umbrella root and Mix starts ALL umbrella apps by default** (only `--no-start` suppresses this, which the documented invocation does NOT use). This means **`:evo_dash` is started alongside `:evo_git`**, which brings up the **full `EvoDash.Application` supervision tree** — including `EvoDash.Store` (SQLite) and `EvoDash.TaskRegistry`. The core runtime (`EvoGit.Application`, `Genesis.run/2`, `Evolution.run/2`, `AgentScheduler`) has **ZERO code-level coupling** to EvoDash (it never references `EvoDash.*`, `EvoDash.Store`, or `EvoDash.TaskRegistry`, and never starts them directly) — the coupling is purely structural: both apps live in the same umbrella and Mix starts them together. The only EvoDash references in `evo_git/lib` are: (1) `EvoGit.SystemCheck` (read-only diagnostics for the dashboard Help page, guarded by try/rescue so it crashes-safe when EvoDash is absent), and (2) documentation/comments. **Consequence: a `genesis`/`evolve` CLI run brings up an `EvoDash.TaskRegistry` that runs `reconcile_task_status` against the shared platform SQLite DB (`<data_dir>/genesis/tasks.sqlite`). If that DB already has in-progress `:running` tasks from another instance whose `:evogit_sched_meta` ETS is in a *different* BEAM VM, the freshly-started Registry marks them `:failed`.** This is the same DB the dashboard uses. To run the CLI WITHOUT starting EvoDash, you would need `mix run --no-start -e '...'` plus manual `Application.ensure_all_started(:evo_git)` — but the documented/standard invocation does NOT do this.
- **Task Archive (opt-in)**: When `:archive` is enabled (`--archive` CLI flag → `runtime_opts` → `AgentSpec.opts` → `AgentState.archive`), each agent's completion (`CompleteTask.complete/4`) writes `refs/genesis/archive/T{task_id}-A{agent_id}-start` and `-final` git refs (protecting commits from gc), adds per-agent `usage` to the git note metadata, and writes an archive record to the `:evogit_archive_records` ETS table. The archive record is a plain map with: core fields (`agent_id`, `parent_id`, `depth`, `objective`, `result`, `base_commit`, `final_commit`, `archive_ref_start`/`final`, `branch_name`, `usage`, `compression_count`, `repo_path`, `repo_id`, `repo_root`, `started_at`, `completed_at`); `:llm_settings` (model name, `model_id` profile identifier, `context_compression_threshold`, and all generation params like `temperature`, `reasoning_effort`, `max_tokens`); `:agent_settings` (`max_turns`, `max_retries`, `max_agent_depth`); and `:foreign_repos` (list of `%{id, root, description}` maps for all configured foreign repos). At root-agent completion, the scheduler collects all records for the task and injects them into the `Result.archive_records` field, which flows through `merge_and_report/3` to the final result map. When archive is disabled (default), behavior is identical to pre-feature.
- **No `try/rescue` anti-pattern**: `try/rescue` is normally a code smell in Elixir — it usually indicates we lack a clean process structure or supervision tree, and are manually handling process lifetimes or masking bugs. **Do NOT add new `try/rescue` blocks.** Before reaching for one, ask: (1) Do we really expect that error? If not → **let it crash**; the supervision tree / restart logic handles recovery (crashing is better than a silent error or corrupted value). (2) If we DO need to handle it, can we do it cleanly? Prefer `case`/`if`/`cond`/`with` with non-crashing function variants (`Regex.compile` not `Regex.compile!`, `JSON.encode/2` not `Jason.encode!/2` + rescue, `:persistent_term.get/2` not `get/1` + rescue, `Integer.parse/1` not `String.to_integer/1` + rescue). Only use `try/rescue` in the rare justified cases listed below. **Every `try/rescue` that remains in the codebase MUST have a comment explaining why it is justified** (answer both questions above).
  - **Justified `try/rescue` cases (rare):** `terminate/2` or cleanup/shutdown code that must never crash the caller; centralized exception boundaries (e.g. `safe_llm_call/2` in the evolution engine, the single rescue for all evolution LLM calls); `SystemCheck` public diagnostics functions that must never crash the dashboard LiveView; `String.to_existing_atom/1` on untrusted user config keys where there is no non-crashing variant; `try/catch` around functions with no non-crashing variant (e.g. `Path.wildcard`). See `EvoDash.Store` for a good "crash philosophy" reference doc.
  - **Eliminate immediately:** `try/rescue` around `!`-suffixed functions that have non-crashing variants; silent `rescue _ -> :ok` swallows; LLM-call rescues that degrade silently to defaults (either add retry logic or let it crash); broad rescues that hide bugs; redundant internal-helper rescues when the public entry point already rescues.
