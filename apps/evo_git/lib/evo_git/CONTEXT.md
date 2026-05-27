# EvoGit Core Library — `lib/evo_git/`

## Intent
This directory contains the core source code of the `:evo_git` OTP application. It implements EvoGit's dual-dimension architecture: the **Agent system** (LLM-powered autonomous agents with tool-calling loops), the **AgentScheduler** (GenServer managing agent lifecycles, worktrees, and ETS state), **Core** domain types (ContextNode, PhyloGraphNode), **Git adapter**, and **Runtime** phases (Genesis, Evolution).

## Routing Table
- `./agent/` → Agent implementations (Generalist, CodebaseInvestigator, CodebaseArchitect, ContextExtractor, Planner, Executor, Manager, Evaluator) and 14+ LLM tool modules
- `./agent_scheduler/` → `AgentState` and `SchedMeta` structs for ETS-backed agent state
- `./core/` → `ContextNode` (spatial tree) and `PhyloGraphNode` (temporal graph) data structures
- `./adapters/` → `Git` CLI adapter — worktree-focused wrapper around `System.cmd("git", ...)`
- `./runtime/` → Genesis (creation), Evolution (refinement loop), Prompts (LLM templates)

## API Surface

### Top-Level Modules (in this directory)
| Module | File | Description |
|---|---|---|
| `EvoGit` | `evo_git.ex` | Sandboxing utilities (`sandbox_args/4`), safe shell command execution via `system_cmd/3` |
| `EvoGit.Application` | `application.ex` | OTP application callback — starts `AgentScheduler` and `TaskSupervisor` |
| `EvoGit.Agent` | `agent.ex` | **Behaviour module** — `use EvoGit.Agent` injects the complete agent loop, tool dispatch, subagent management, context compression, budget warnings, and `complete_task` |
| `EvoGit.AgentSpec` | `agent_spec.ex` | Structured spec for spawning agents: `%{context_node, phylo_node, agent_module, objective, opts}` |
| `EvoGit.AgentScheduler` | `agent_scheduler.ex` | **GenServer** — worktree pool, agent lifecycle (register → dispatch → run → recycle), subagent spawning, crash retry, ETS state management |
| `EvoGit.Task` | `task.ex` | High-level orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | `runtime.ex` | Top-level coordinator: Genesis → Evolution phases |
| `EvoGit.ProjectConfig` | `project_config.ex` | Reads `evogit.toml` from repo root |

### Agent Lifecycle (Spec → Execution → Completion)

```
1. Task.mutate/3 (or Task.diagnose/3) creates an AgentSpec
2. AgentScheduler.run_agent(spec) — blocks until agent completes
   a. register_agent() — assigns ID, writes AgentState + SchedMeta to ETS
   b. try_dispatch() — creates persistent worktree, prepares git state, spawns Task
3. Agent.run(objective) — enters the agent loop
   a. load_worktree_path() — re-reads from ETS each turn
   b. Builds dynamic context tree, injects as user prompt
   c. loop() → do_turn() → LLM call → process_tool_calls()
4. complete_task tool → syncs commit → CompleteTask.complete() → writes git note
5. AgentScheduler handles result, merges subagent branches, recycles worktree
```

### Tool Assignment Architecture
- `available_tools/0` in each agent = `EvoGit.Agent.Tools.schemas()` ++ `subagent_schemas()` ++ `[CompleteTask.schema()]`
- Agents can override `available_tools/0` to restrict their toolset (e.g., CodebaseInvestigator removes write tools)
- `effective_tools/1` strips subagent tools when at max depth
- Tool execution: `EvoGit.Agent.Tools.execute(name, args, repo_path, repo_root, node_path)` dispatches to specialized modules

### Key Overridable Callbacks (via `use EvoGit.Agent`)
| Callback | Default | Purpose |
|---|---|---|
| `system_prompt/0` | `""` | Agent's behavior, persona, and rules (MUST NOT contain objective or context) |
| `available_tools/0` | All standard tools + subagent schemas + CompleteTask | LLM tool schemas for this agent |
| `subagent_modules/0` | `[]` | List of agent modules that can be spawned as subagents |
| `subagent_tool_name/0` | `nil` | Tool name when this agent appears as a subagent |
| `subagent_tool_description/0` | `""` | Tool description when this agent appears as a subagent |
| `agent_type/0` | `:read_write` | `:read` or `:read_write` — controls spatial contract validation |

### ETS Tables
| Table | Owner | Contents |
|---|---|---|
| `:evogit_agent_state` | Agent processes | `AgentState` — context_node, phylo_node, event_sink, llm_model, context |
| `:evogit_sched_meta` | Scheduler process | `SchedMeta` — status, worktree, task_ref, parent tracking, retry counts |

### Agent Status Lifecycle
```
:pending → :running → (crash → retry → :pending)* → completion → recycled
                    ↘ :waiting (subagents spawned) → :ready → :running (resumed) → completion
```

## Constraints
- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd("git", ...)` outside adapters.
- Agents are stateless modules — all persistent state lives in ETS tables.
- The `use EvoGit.Agent` macro injects the complete agent loop; agents only override callbacks.
- System prompts MUST NOT contain dynamic state, objectives, or context trees.
- Worktrees are persistent per-agent (created on first dispatch, reused on retry, deleted on recycle).
- Agents commit before delegating subagents (auto-commit fallback enforced by scheduler).
- Tool outputs are truncated at 128KB to prevent context bloat.
- Agent loop has a 30-minute LLM time budget, 128 max turns, with graduated warnings at 25%/50%/80%.
