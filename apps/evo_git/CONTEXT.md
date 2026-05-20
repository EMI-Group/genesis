# EvoGit — Core Runtime Application

## Intent
The `:evo_git` OTP application is the heart of the EvoGit umbrella project. It implements an evolutionary software development runtime where autonomous LLM-powered agents create, analyze, and modify codebases using git worktree isolation. The system models a codebase as a **Context Tree** (spatial dimension) and a **Phylogenetic Graph** (temporal dimension), enabling agents to navigate, mutate, and evolve code in isolated sandboxes.

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
│               │   ├─ AgentState      │                   │  Agent spatial/temporal state
│               │   └─ SchedMeta       │                   │  Scheduling metadata
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
└──────────────────────────────────────────────────────────┘
```

## API Surface

### Top-Level Modules
| Module | File | Description |
|---|---|---|
| `EvoGit` | `lib/evo_git.ex` | Sandboxing utilities (`sandbox_args/4`), safe shell command execution via `system_cmd/3` |
| `EvoGit.Application` | `lib/evo_git/application.ex` | OTP application callback (starts `AgentScheduler`) |
| `EvoGit.CLI` | `lib/evo_git/cli.ex` | Command-line interface entry point |
| `EvoGit.Agent` | `lib/evo_git/agent.ex` | Behaviour module for agents (`use EvoGit.Agent`); injects agent loop, subagent tools, `complete_task` |
| `EvoGit.AgentSpec` | `lib/evo_git/agent_spec.ex` | Structured specification for spawning agents (context_node, phylo_node, agent_module, objective) |
| `EvoGit.AgentScheduler` | `lib/evo_git/agent_scheduler.ex` | GenServer managing agent lifecycles, worktree pool, and ETS state |
| `EvoGit.Task` | `lib/evo_git/task.ex` | Agent orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | `lib/evo_git/runtime.ex` | Top-level coordinator: Genesis then Evolution |
| `EvoGit.ProjectConfig` | `lib/evo_git/project_config.ex` | Reads and parses `evogit.toml` from repo root; provides `worktree_script/1` accessor |

### Subdirectories
| Directory | Description |
|---|---|
| `lib/evo_git/core/` | `ContextNode` (spatial tree) and `PhyloGraphNode` (temporal graph) data structures |
| `lib/evo_git/adapters/` | `Git` CLI adapter — thin wrapper around `System.cmd("git", ...)` |
| `lib/evo_git/agent/` | Agent implementations (Generalist, Investigator, Architect, ContextExtractor) + 14 LLM tool schemas |
| `lib/evo_git/runtime/` | Genesis (creation), Evolution (refinement loop), and Prompts (LLM templates) |
| `lib/evo_git/agent_scheduler/` | `AgentState` and `SchedMeta` structs backing ETS tables |
| `test/` | ExUnit tests using real git operations on temp directories |

### Key Types
- **Agent**: `state :: %{context_node: ContextNode.t(), phylo_node: PhyloGraphNode.t()}` — stateless; `NewState = Agent(State, Objective)`
- **AgentSpec**: `%{context_node, phylo_node, agent_module, objective, opts}` — complete spec for spawning an agent
- **AgentState**: `%{context_node, phylo_node, event_sink}` — live ETS state for running agents
- **SchedMeta**: `%{id, depth, status, worktree, parent_id, spec, ...}` — scheduler bookkeeping per agent

### Dependencies
- `req_llm ~> 1.10` — LLM client for agent reasoning and tool calling
- `retry ~> 0.19` — Retry logic for resilient operations
- `toml ~> 0.7` — TOML configuration file parser for `evogit.toml` project config

## Routing Table

The following table maps areas of concern to child node paths, so parent agents know where to spawn subagents:

| Concern / Area | Child Node Path |
|---|---|
| Agent implementations & LLM tool definitions | `lib/evo_git/agent/` |
| LLM tool implementations (file, git, bash, search, etc.) | `lib/evo_git/agent/tools/` |
| Core domain models (ContextNode, PhyloGraphNode) | `lib/evo_git/core/` |
| Git CLI adapter (worktree, merge, diff, notes, etc.) | `lib/evo_git/adapters/` |
| Runtime orchestration (Genesis, Evolution, Prompts) | `lib/evo_git/runtime/` |
| Agent scheduler data structures (AgentState, SchedMeta) | `lib/evo_git/agent_scheduler/` |
| ExUnit tests | `test/` |

When a task involves agent behavior, system prompts, or delegation logic, delegate to `lib/evo_git/agent/`. For core data structures like ContextNode, delegate to `lib/evo_git/core/`. For git operations, delegate to `lib/evo_git/adapters/`. For runtime flow (Genesis/Evolution), delegate to `lib/evo_git/runtime/`. For scheduler internals, delegate to `lib/evo_git/agent_scheduler/`. For test changes, delegate to `test/`.

## Constraints
- Part of an **umbrella project** — build artifacts, deps, and lockfile live at the repository root (`../../_build`, `../../deps`, `../../mix.lock`).
- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd("git", ...)` in domain modules.
- Agents are stateless modules using `EvoGit.Agent` behaviour; the framework manages state via ETS.
- Agent execution happens in **isolated git worktrees** managed by `AgentScheduler` — never on the main working copy.
- The `EvoGit.Agent` `use` macro injects the agent loop, tool dispatch, subagent management, and `complete_task` tool automatically.
- Subdirectories follow Elixir convention: `lib/evo_git/<subdir>/` maps to `EvoGit.<Subdir>` namespace.
- Project-level configuration is read from `evogit.toml` in the repo root via `EvoGit.ProjectConfig`. Currently supports `worktree.script` — a script that runs after worktree creation with `$SOURCE_REPO_PATH` and `$TARGET_WORKTREE_PATH` env vars.
