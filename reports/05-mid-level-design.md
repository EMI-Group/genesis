
## 4. Mid-Level Design

### 4.1 The Agent Scheduler

Because agents are transient and stateless, Genesis utilizes a central **Agent Scheduler** to manage them like an operating system manages processes. The scheduler manages limited computational resources: Git worktrees, LLM API slots, and tool execution slots.

**Agent Lifecycle States:**

```text
pending → running ⇄ waiting → ready → running → (complete)
              ↓
           blocked (when paused, preempted, or slot-starved)

```

**Cooperative Yielding:** When an agent spawns subagents, it must *yield* its resources. It commits pending changes, transitions to `waiting`, and releases its worktree and LLM slots back to the pool. This allows massive parallel execution without deadlocking system resources.

### 4.2 The Context Tree as a Prefix Tree for KV Cache

The directory-based Context Tree acts as a prefix tree. The context prompt for `./src/auth/oauth/` is simply the context prompt of `./src/auth/` appended with local details. This design naturally aligns with LLM Key-Value (KV) caching mechanisms for highly efficient token processing during deep descents.

### 4.3 Subagent Call Modeling

Subagent execution is a pure function: `subagent(node_path, base_commit, objective)`.

* **Parallel composition:** Independent child tasks are spawned concurrently in isolated worktrees and combined via Git octopus merges.
* **Sequential composition:** Dependent tasks are scheduled sequentially, passing the child commit hash forward.

### 4.4 The Neuro-Symbolic Loop in Detail

1. **Symbolic → Neuro:** Context tree state is serialized into a text prompt.
2. **Neuro computation:** The LLM generates tool calls based on pattern recognition.
3. **Neuro → Symbolic:** The runtime executes the tools (file I/O, Git) and alters the file system.
4. **Symbolic verification:** The runtime checks invariants (budget, spatial constraints) deterministically.

### 4.5 The Skills System

Skills are an extension of the Context Tree. While `CONTEXT.md` is eagerly loaded, skills (reusable scripts, complex configurations) are lazily loaded. They are tied to specific nodes in the tree, allowing agents to explicitly call for extended context only when the task requires it.

---
