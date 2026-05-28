# EvoGit — Core Runtime Application

## Intent
The `:evo_git` OTP application is the heart of the EvoGit umbrella project. It implements an evolutionary software development runtime where autonomous LLM-powered agents create, analyze, and modify codebases using git worktree isolation. The system models a codebase as a **Context Tree** (spatial dimension) and a **Phylogenetic Graph** (temporal dimension), enabling agents to navigate, mutate, and evolve code in isolated sandboxes.

## Routing Table
- `./lib/` → Application source code (agents, core domain, adapters, runtime, scheduler)
- `./test/` → ExUnit test suite (core, adapters, agent tools, project config tests)

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                    EvoGit.CLI / Application              │  Entry points
├──────────────────────────────────────────────────────────┤
│                    EvoGit.Runtime                        │  Genesis → Evolution phases
│               ┌──────────────────────┐                   │
│               │    Runtime.Prompts   │                   │  LLM prompt templates
│               └──────────────────────┘                   │
├──────────────────────────────────────────────────────────┤
│  EvoGit.Task                                             │  Agent orchestration (mutate, diagnose, resolve)
│               ┌──────────────────────┐                   │
│               │   AgentScheduler     │                   │  GenServer: worktree pool, lifecycle, ETS state
│               │   ├─ AgentState      │                   │  Agent spatial/temporal state + conversation context
│               │   └─ SchedMeta       │                   │  Scheduling metadata (incl. task_id grouping)
│               │   ├─ LLM Slots       │                   │  Concurrency + global backoff (60s rate-limit cooldown)
│               │   └─ Tool Slots      │                   │  Independent tool execution semaphore
│               └──────────────────────┘                   │
├──────────────────────────────────────────────────────────┤
│  Agents (use EvoGit.Agent behaviour)                     │
│    Generalist │ CodebaseInvestigator │ CodebaseArchitect │  Agent implementations
│    ContextExtractor                                    │
│    + Agent.Tools (14 LLM tool schemas)                   │
├──────────────────────────────────────────────────────────┤
│  EvoGit.Core                                             │
│    ContextNode (Spatial)  │  PhyloGraphNode (Temporal)  │  Domain data structures
├──────────────────────────────────────────────────────────┤
│  EvoGit.Adapters.Git                                     │  Git CLI wrapper (worktree-focused)
├──────────────────────────────────────────────────────────┤
│  EvoGit.ProjectConfig                                    │  Reads evogit.toml project config
├──────────────────────────────────────────────────────────┤
│  EvoGit.Defaults                                         │  Single source of truth for runtime defaults
└──────────────────────────────────────────────────────────┘
```

## API Surface

### Top-Level Modules
| Module | File | Description |
|---|---|---|
| `EvoGit` | `./lib/evo_git.ex` | Sandboxing utilities (`sandbox_args/4`), safe shell command execution via `system_cmd/3` |
| `EvoGit.Application` | `./lib/evo_git/application.ex` | OTP application callback (starts `AgentScheduler`) |
| `EvoGit.CLI` | `./lib/evo_git/cli.ex` | Command-line interface entry point; parses `--tool-concurrency` among other flags |
| `EvoGit.Agent` | `./lib/evo_git/agent.ex` | Behaviour module for agents (`use EvoGit.Agent`); injects agent loop, subagent tools, `complete_task` |
| `EvoGit.AgentSpec` | `./lib/evo_git/agent_spec.ex` | Structured specification for spawning agents (context_node, phylo_node, agent_module, objective) |
| `EvoGit.AgentScheduler` | `./lib/evo_git/agent_scheduler.ex` | GenServer managing agent lifecycles, worktree pool, ETS state, LLM/tool slot management, and orphaned branch cleanup |
| `EvoGit.Task` | `./lib/evo_git/task.ex` | Agent orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | `./lib/evo_git/runtime.ex` | Top-level coordinator: Genesis then Evolution |
| `EvoGit.ProjectConfig` | `./lib/evo_git/project_config.ex` | Reads and parses `evogit.toml` from repo root; provides `worktree_script/1` accessor |
| `EvoGit.Defaults` | `./lib/evo_git/defaults.ex` | Single source of truth for all runtime default values (max_concurrency, max_tool_concurrency, etc.) |
| `EvoGit.Platform` | `./lib/evo_git/platform.ex` | Cross-platform OS detection and data directory resolution (`data_dir/0` respects XDG, macOS, Windows conventions) |

### Subdirectories
| Directory | Description |
|---|---|
| `./lib/evo_git/core/` | `ContextNode` (spatial tree) and `PhyloGraphNode` (temporal graph) data structures |
| `./lib/evo_git/adapters/` | `Git` CLI adapter — thin wrapper around `System.cmd("git", ...)` |
| `./lib/evo_git/agent/` | Agent implementations (Generalist, Investigator, Architect, ContextExtractor) + 14 LLM tool schemas |
| `./lib/evo_git/runtime/` | Genesis (creation), Evolution (refinement loop), and Prompts (LLM templates) |
| `./lib/evo_git/agent_scheduler/` | `AgentState` and `SchedMeta` structs backing ETS tables |
| `./test/` | ExUnit tests using real git operations on temp directories |

### Key Types
- **Agent**: `state :: %{context_node: ContextNode.t(), phylo_node: PhyloGraphNode.t()}` — stateless; `NewState = Agent(State, Objective)`
- **AgentSpec**: `%{context_node, phylo_node, agent_module, objective, opts}` — complete spec for spawning an agent
- **AgentState**: `%{context, context_node, phylo_node, event_sink, llm_model, max_retries, max_depth, parent_id, objective, repo_id}` — live ETS state for running agents
- **SchedMeta**: `%{id, depth, status, worktree, parent_id, task_id, spec, ...}` — scheduler bookkeeping per agent

### Slot Management API (AgentScheduler)
| Function | Description |
|---|---|
| `request_llm_slot/2` | Request an LLM execution slot; blocks until available (respects `max_concurrency`). |
| `release_llm_slot/1` | Release an LLM slot after call completes (success or failure). |
| `report_llm_error/2` | Report an LLM error type (e.g., `:rate_limit`). Rate-limit errors trigger a 60-second global backoff; all waiting agents are delayed. |
| `request_tool_slot/2` | Request a tool execution slot; blocks until available (respects `max_tool_concurrency`). |
| `release_tool_slot/1` | Release a tool slot after execution completes. |

### Dependencies
- `req_llm ~> 1.10` — LLM client for agent reasoning and tool calling
- `retry ~> 0.19` — Retry logic for resilient operations
- `toml ~> 0.7` — TOML configuration file parser for `evogit.toml` project config

## Constraints
- Part of an **umbrella project** — build artifacts, deps, and lockfile live at the repository root (`../../_build`, `../../deps`, `../../mix.lock`).
- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd("git", ...)` in domain modules.
- Agents are stateless modules using `EvoGit.Agent` behaviour; the framework manages state via ETS.
- Agent execution happens in **isolated git worktrees** managed by `AgentScheduler` — never on the main working copy.
- The `EvoGit.Agent` `use` macro injects the agent loop, tool dispatch, subagent management, and `complete_task` tool automatically.
- Subdirectories follow Elixir convention: `./lib/evo_git/<subdir>/` maps to `EvoGit.<Subdir>` namespace.
- Project-level configuration is read from `evogit.toml` in the repo root via `EvoGit.ProjectConfig`. Currently supports `worktree.script` — a script that runs after worktree creation with `$SOURCE_REPO_PATH` and `$TARGET_WORKTREE_PATH` env vars.
- **LLM slot management**: All LLM calls must acquire a slot via `request_llm_slot/2` and release via `release_llm_slot/1`. Rate-limit errors trigger a global 60-second backoff across all agents.
- **Tool slot management**: Tool executions are independently throttled via `request_tool_slot/2` / `release_tool_slot/1` with `max_tool_concurrency` (default: 2).
- **Orphaned branch cleanup**: On initialization, the scheduler removes stale `evogit-agent*` branches from previous runs.
- **Task ID tracking**: Each top-level `run_agent` call is assigned a unique `task_id`; all subagents within that run inherit the same `task_id` for grouping.
