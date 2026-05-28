# Agent Scheduler Data Structures

## Intent
Contains data struct models and extracted helper modules used internally by the parent `EvoGit.AgentScheduler` GenServer. The data structs back two dedicated ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) that track live agent execution state and scheduling metadata respectively. The helper modules encapsulate slot management and worktree lifecycle logic extracted from the main GenServer for maintainability.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.AgentState` | Live spatial/temporal state for a **running** agent. Stored in `:evogit_agent_state` ETS. Fields: `context` (ReqLLM.Context \| nil), `context_node` (ContextNode), `phylo_node` (PhyloGraphNode \| nil), `event_sink` (pid \| nil), `llm_model`, `max_retries`, `max_depth`, `parent_id`, `objective`, `repo_id` (atom, default `:primary`). Enforced keys: `[:context_node, :llm_model, :max_retries, :max_depth]`. |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduling metadata for a **registered** agent. Stored in `:evogit_sched_meta` ETS. Fields: `id`, `depth`, `spec` (AgentSpec), `status` (`:pending \| :running \| :waiting \| :ready`), `worktree`, `task_ref`, `from`, `parent_id`, `task_id` (groups agents from the same top-level `run_agent` call), `retries`, `result_sent`, `sub_agent_from`, `total_sub_specs`, `pending_sub_agents` (MapSet), `sub_agent_results` (map), `sub_agent_indices` (map). Enforced keys: `[:id, :depth, :spec]`. |
| `EvoGit.AgentScheduler.Slots` | LLM and tool slot management as pure functions operating on scheduler state. Handles request/release, global backoff for rate-limit errors, and pending queue grants. Extracted from the parent GenServer. |
| `EvoGit.AgentScheduler.Worktrees` | Worktree lifecycle management as pure functions: initialization, teardown, assignment/preparation, init script execution, deletion, and orphaned branch cleanup. Extracted from the parent GenServer. |

## Constraints
- Data structs are plain data with no behaviour or callbacks.
- **Helper modules contain business logic**: `Slots` and `Worktrees` are pure-function modules that operate on the scheduler's state map. They are called by the parent GenServer's callbacks but do not maintain their own state.
- **Ownership model**: `AgentState` is owned by agent processes (scheduler writes initial values, agents update `phylo_node` and `context`). `SchedMeta` is owned **exclusively** by the scheduler process; agents never read or write it.
- Both structs are persisted in dedicated ETS tables created by the parent `AgentScheduler` GenServer, not in this directory.
- New fields may be added to either struct as scheduling features evolve, but ownership boundaries must be respected.
