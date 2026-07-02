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
| `EvoGit.AgentSpec` | Structured specification for spawning agents; `opts` keyword list carries `:archive` and other runtime flags |
| `EvoGit.AgentScheduler` | GenServer managing agent lifecycles, worktree pool, ETS state (`:evogit_agent_state`, `:evogit_sched_meta`, `:evogit_archive_records`), slot management |
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
- Agents are transient modules using `EvoGit.Agent` behaviour; the framework manages state via ETS.
- Agent execution happens in **isolated git worktrees** managed by `AgentScheduler` — never on the main working copy.
- Subdirectories follow Elixir convention: `./lib/evo_git/<subdir>/` maps to `EvoGit.<Subdir>` namespace.
- **Three-level configuration**: `EvoGit.Config` merges built-in defaults → user config (`~/.config/genesis/config.toml`) → runtime overrides. No default model or username is hardcoded.
- **Slot discipline**: All LLM calls must acquire/release slots via `AgentScheduler`; rate-limit errors trigger a 60-second global backoff. Tool executions are independently throttled via `max_tool_concurrency`.
- **Task-scoped naming**: Worktree directories use `worker_T<task_number>_A<task_local_id>`, branches use `evogit-agent-T<task_number>-A<task_local_id>`. The `task_id` is a 16-char hex GUID used for global identification (archive refs, task grouping); the `task_number` is a short integer (from a linear scan of `.evogit/workers/`) used only for naming.
- `EvoGit.Defaults` is a backward-compatibility shim. New code should use `EvoGit.Config` directly.
- **Task Archive (opt-in)**: When `:archive` is enabled (`--archive` CLI flag → `runtime_opts` → `AgentSpec.opts` → `AgentState.archive`), each agent's completion (`CompleteTask.complete/4`) writes `refs/genesis/archive/T{task_id}-A{agent_id}-start` and `-final` git refs (protecting commits from gc), adds per-agent `usage` to the git note metadata, and writes an archive record to the `:evogit_archive_records` ETS table. At root-agent completion, the scheduler collects all records for the task and injects them into the `Result.archive_records` field, which flows through `merge_and_report/3` to the final result map. When archive is disabled (default), behavior is identical to pre-feature.
