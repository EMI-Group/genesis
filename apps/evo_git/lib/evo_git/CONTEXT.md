# EvoGit Core Library — `lib/evo_git/`

## Intent
This directory contains the core source code of the `:evo_git` OTP application. It implements EvoGit's dual-dimension architecture: the **Agent system** (LLM-powered autonomous agents with tool-calling loops), the **AgentScheduler** (GenServer managing agent lifecycles, worktrees, and ETS state), **Core** domain types (ContextNode, PhyloGraphNode, ForeignRepo), **Git adapter**, and **Runtime** phases (Genesis, Evolution).

### Multi-Repo Support
The system supports operating across multiple Git repositories simultaneously. A **primary** repo (the project being evolved) can reference one or more **foreign repos** (e.g., an original codebase, a reference implementation). Foreign repos are configured in `evogit.toml` under `[foreign_repos]` and registered with the `AgentScheduler` at runtime. Agents can spawn **cross-repo subagents** by passing an absolute path to a node in a foreign repo — the system resolves the path to the correct repo, creates a worktree in that repo's `.evogit/workers/` directory, and runs the subagent there. Cross-repo subagent results are not merged back into the primary repo (they commit to their own repo's worktree).

## Routing Table
- `./agent/` → Agent behaviour module (`EvoGit.Agent`), tool library (14+ LLM tools), context compression, and subagent processing
- `./agents/` → Agent type implementations (Generalist, Manager, Executor, Planner, CodebaseInvestigator, CodebaseArchitect, ContextExtractor, Evaluator) and Warnings utility
- `./agent_scheduler/` → `AgentState` and `SchedMeta` structs for ETS-backed agent state
- `./core/` → `ContextNode` (spatial tree), `PhyloGraphNode` (temporal graph), and `ForeignRepo` (multi-repo references) data structures
- `./adapters/` → `Git` CLI adapter — worktree-focused wrapper around `System.cmd("git", ...)`
- `./runtime/` → Genesis (creation), Evolution (refinement loop), Prompts (LLM templates)

## API Surface

### Top-Level Modules (in this directory)
| Module | File | Description |
|---|---|---|
| `EvoGit` | `evo_git.ex` | Sandboxing utilities (`sandbox_args/4`), safe shell command execution via `system_cmd/3` |
| `EvoGit.Application` | `application.ex` | OTP application callback — starts `AgentScheduler` and `TaskSupervisor` |
| `EvoGit.Agent` | `agent.ex` | **Behaviour module** — `use EvoGit.Agent` injects the complete agent loop, tool dispatch, subagent management, context compression, budget warnings, cross-repo subagent spawning, and `complete_task` |
| `EvoGit.AgentSpec` | `agent_spec.ex` | Structured spec for spawning agents: `%{context_node, phylo_node, agent_module, objective, repo_id, opts}` — `repo_id` determines which repo's worktree is used |
| `EvoGit.AgentScheduler` | `agent_scheduler.ex` | **GenServer** — worktree pool, agent lifecycle (register → dispatch → run → recycle), subagent spawning (same-repo and cross-repo), crash retry, ETS state management, foreign repo registry |
| `EvoGit.Task` | `task.ex` | High-level orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | `runtime.ex` | Top-level coordinator: Genesis → Evolution phases; registers foreign repos from CLI/config |
| `EvoGit.ProjectConfig` | `project_config.ex` | Reads `evogit.toml` from repo root; provides `worktree_script/1` and `foreign_repos/1` accessors |

### Multi-Repo Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Configuration                             │
│  evogit.toml → [foreign_repos.original] path = "/Source/orig"   │
│  CLI flags  → -R original:/Source/orig                          │
│               -R reference:/Source/ref                           │
├──────────────────────────────────────────────────────────────────┤
│                     Registration (Startup)                       │
│  ProjectConfig.foreign_repos/1 → [ForeignRepo.t()]              │
│  CLI.parse_foreign_repos/1      → [ForeignRepo.t()]             │
│  AgentScheduler.register_foreign_repos/1 → stores in GenServer  │
├──────────────────────────────────────────────────────────────────┤
│                    Cross-Repo Subagent Spawning                  │
│  Agent calls subagent tool with absolute path (e.g.,             │
│    "/Source/orig/src/main.rs")                                   │
│  → Agent.build_subagent_specs/2 resolves path via                │
│    ForeignRepo.resolve_path/2                                    │
│  → AgentSpec created with target repo_id                         │
│  → AgentScheduler creates worktree in foreign repo               │
│  → Subagent runs and commits in foreign repo worktree            │
│  → Result NOT merged into primary repo (no cross-repo merge)    │
└──────────────────────────────────────────────────────────────────┘
```

#### Key Multi-Repo Functions
| Module | Function | Description |
|---|---|---|
| `AgentScheduler` | `register_foreign_repos/1` | Registers `[ForeignRepo.t()]` with the scheduler |
| `AgentScheduler` | `get_foreign_repos/0` | Returns all registered repos (including primary) |
| `AgentScheduler` | `repo_root_for/1` | Resolves a `repo_id` to its absolute root path |
| `Agent` (macro) | `resolve_subagent_path/3` | Determines if a subagent path is same-repo or cross-repo; resolves absolute paths to `(repo_id, repo_root, rel_path)` |
| `ProjectConfig` | `foreign_repos/1` | Parses `[foreign_repos]` from `evogit.toml` into `[ForeignRepo.t()]` |

### Agent Lifecycle (Spec → Execution → Completion)

```
1. Task.mutate/3 (or Task.diagnose/3) creates an AgentSpec (with repo_id)
2. AgentScheduler.run_agent(spec) — blocks until agent completes
   a. register_agent() — assigns ID, writes AgentState + SchedMeta to ETS
   b. try_dispatch() — creates persistent worktree in the correct repo (based on repo_id), prepares git state, spawns Task
3. Agent.run(objective) — enters the agent loop
   a. load_worktree_path() — re-reads from ETS each turn
   b. Builds dynamic context tree, injects as user prompt
   c. loop() → do_turn() → LLM call → process_tool_calls()
4. complete_task tool → syncs commit → CompleteTask.complete() → writes git note
5. AgentScheduler handles result, merges same-repo subagent branches, recycles worktree
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
| `:evogit_agent_state` | Agent processes | `AgentState` — context_node, phylo_node, event_sink, llm_model, context, repo_id |
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
- **Cross-repo subagents** commit to their foreign repo's worktree — their changes are NOT merged back into the primary repo. The parent agent receives a note indicating how many cross-repo subagents completed.
- **Foreign repo worktrees** are created under the foreign repo's `.evogit/workers/` directory, using the foreign repo's git database.
- **Path resolution**: Relative paths in subagent calls always resolve to the primary repo. Absolute paths are resolved against all registered foreign repos (foreign repos checked first, primary last).
