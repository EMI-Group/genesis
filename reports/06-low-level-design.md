
## 5. Low-Level Design

### 5.1 The Actor Model and Supervision Tree

Genesis utilizes the BEAM (Erlang VM) actor model. Processes communicate via message passing, and a supervision tree handles fault tolerance.

```text
EvoGit.AgentGroupSupervisor (one_for_all)
├── Task.Supervisor         — Agent Task supervisor (spawns/kills agents)
└── EvoGit.AgentScheduler   — The central GenServer orchestrator

```

If an agent process crashes (e.g., unparseable LLM output), the `Task.Supervisor` kills it. The `AgentScheduler` detects the `DOWN` message, safely releases the agent's slots and worktree, and queues it for a retry from its last safe Git commit.

### 5.2 The Git Worktree Mechanism

Git worktrees are the primary isolation primitive.

* **Isolation:** Each agent gets an independent working directory (`git worktree add`).
* **Efficiency:** Worktrees share the `.git` object database. Creating one is proportional to the working tree size, not the repository history.
* **Reclamation:** On completion, the scheduler merges the branch and deletes the worktree.

### 5.3 Slot Management and Backoff

LLM API calls consume slots from per-model pools.

* **Global Backoff:** If a rate-limit error occurs, that specific model's pool enters a 60-second backoff. Waiting agents are re-queued. This completely prevents the "thundering herd" problem while allowing cheaper, unrestricted models to continue executing on other branches.

### 5.4 The Turn Loop

Each agent executes a strictly budgeted turn loop:

1. **Sync state:** Update token usage.
2. **LLM call:** Acquire slot, call LLM, release slot.
3. **Tool dispatch:** Execute file edits or subagent spawns.
4. **Commit sync:** Update the temporal DAG with side-effects.
5. **Grace period:** At the absolute turn limit, the agent receives a forced system warning to safely conclude its work, ensuring clean termination rather than arbitrary string truncation.

---
