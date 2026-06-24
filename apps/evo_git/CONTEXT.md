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
| `EvoGit.AgentSpec` | Structured specification for spawning agents |
| `EvoGit.AgentScheduler` | GenServer managing agent lifecycles, worktree pool, ETS state, slot management |
| `EvoGit.Sandbox` | Multi-platform sandbox dispatch (selects Linux/macOS/None backend based on platform) |
| `EvoGit.SandboxSlice` | GenServer managing the `evogit.slice` systemd user slice (Linux only) |
| `EvoGit.Task` | Agent orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | Top-level coordinator: Genesis and Evolution phases |
| `EvoGit.Runtime.Helpers` | Shared helper functions for runtime phases (merge_and_report, notify_finalizing, generate_branch_name, new_codebase?, validate_node_path, resolve_starting_commit) |
| `EvoGit.ProjectConfig` | Reads and parses `evogit.toml` from repo root |
| `EvoGit.Review` | Code review operations: load diff data, merge/reject branches, manual GitHub PR creation |
| `EvoGit.Config` | Unified 3-level configuration resolver (defaults → user TOML → runtime overrides) |
| `EvoGit.Defaults` | Backward-compatibility shim delegating to `EvoGit.Config` |
| `EvoGit.Platform` | Cross-platform OS detection, config/data directory resolution |

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
- Agents are stateless modules using `EvoGit.Agent` behaviour; the framework manages state via ETS.
- Agent execution happens in **isolated git worktrees** managed by `AgentScheduler` — never on the main working copy.
- Subdirectories follow Elixir convention: `./lib/evo_git/<subdir>/` maps to `EvoGit.<Subdir>` namespace.
- **Three-level configuration**: `EvoGit.Config` merges built-in defaults → user config (`~/.config/evogit/config.toml`) → runtime overrides. No default model or username is hardcoded.
- **Slot discipline**: All LLM calls must acquire/release slots via `AgentScheduler`; rate-limit errors trigger a 60-second global backoff. Tool executions are independently throttled via `max_tool_concurrency`.
- **Task-scoped naming**: Worktree directories use `worker_T<task_id>_A<task_local_id>`, branches use `evogit-agent-T<task_id>-A<task_local_id>`. Each top-level run gets a unique `task_id` inherited by all subagents.
- `EvoGit.Defaults` is a backward-compatibility shim. New code should use `EvoGit.Config` directly.
