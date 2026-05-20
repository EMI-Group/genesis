# Agent Scheduler Data Structures

## Intent
Contains the plain-struct data models used internally by the parent `EvoGit.AgentScheduler` GenServer. These structs back two dedicated ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) that track live agent execution state and scheduling metadata respectively.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.AgentState` | Live spatial/temporal state for a **running** agent. Stored in `:evogit_agent_state` ETS. Fields: `context_node` (ContextNode), `phylo_node` (PhyloGraphNode \| nil), `event_sink` (pid \| nil). Enforced keys: `[:context_node]`. |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduling metadata for a **registered** agent. Stored in `:evogit_sched_meta` ETS. Fields: `id`, `depth`, `spec` (AgentSpec), `status` (`:pending \| :running \| :waiting \| :ready`), `worktree`, `task_ref`, `from`, `parent_id`, `retries`, `result_sent`, `sub_agent_from`, `pending_sub_agents` (MapSet), `sub_agent_results` (map). Enforced keys: `[:id, :depth, :spec]`. |

## Routing Table

This directory has no child subdirectories — all work is handled by the individual files within this directory (`agent_state.ex`, `sched_meta.ex`). For any changes to the AgentState or SchedMeta data structures, work directly on the relevant file in this node; no subagent delegation to child paths is needed.

## Constraints
- These are plain data structs with no behaviour or callbacks — no business logic here.
- **Ownership model**: `AgentState` is owned by agent processes (scheduler writes initial values, agents update `phylo_node`). `SchedMeta` is owned **exclusively** by the scheduler process; agents never read or write it.
- Both structs are persisted in dedicated ETS tables created by the parent `AgentScheduler` GenServer, not in this directory.
- New fields may be added to either struct as scheduling features evolve, but ownership boundaries must be respected.
