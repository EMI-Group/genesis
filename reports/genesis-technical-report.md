# Genesis: A Recursive Neuro-Symbolic Framework for Automated Software Evolution

## Abstract

Genesis is a neuro-symbolic framework that automates the creation and evolution of software through recursive hierarchical decomposition. It marries the pattern-recognition capabilities of large language models (the *neuro* component) with a principled evolutionary architecture grounded in fixed-point theory (the *symbolic* component). The system models a codebase along two orthogonal dimensions — a **spatial** Context Tree capturing hierarchical structure and a **temporal** phylogenetic DAG capturing evolutionary history. Through the iterative application of a *summary–code fixed-point operator*, Genesis guarantees that every level of the codebase reaches semantic convergence: each module's implementation faithfully realizes its declared intent, and each summary accurately reflects its implementation. This paper presents the framework's mathematical foundation, architectural design, and implementation, showing how the recursive application of a simple fixed-point principle yields a system capable of autonomously building and refining arbitrarily complex software.

---

## 1. Philosophy: The Neuro-Symbolic Design

### 1.1 Beyond Pure Neural Approaches

A purely neural approach to code generation — feeding a prompt to an LLM and accepting its output — suffers from fundamental limitations. The LLM's context window imposes a hard ceiling on the complexity of software it can produce in a single pass. No matter how capable the model, a monolithic generation process cannot produce a million-line codebase; the attention mechanism's quadratic complexity and the fixed context budget constrain what can be reasoned about simultaneously.

More subtly, LLMs lack *grounding*. An LLM generates tokens that *look like* code, but it has no mechanism to verify that the generated implementation satisfies the declared specification, that all edge cases are handled, or that cross-module interfaces are consistent. The model can produce plausible-looking code that compiles but is semantically wrong — an insidious failure mode that compounds as codebases grow.

### 1.2 The Symbolic Scaffold

Genesis addresses these limitations by providing a **symbolic scaffold** — a structured, mathematically-grounded framework within which neural generation operates. The key insight is that while an LLM cannot directly produce a large, correct codebase, it *can* reliably perform small, locally-scoped tasks when given precise context. The symbolic scaffold decomposes the global problem into an hierarchy of local subproblems, each small enough to fit within an LLM's effective reasoning budget, and provides mechanisms for verification, iteration, and convergence.

The symbolic component serves three roles:

1. **Decomposition**: A recursive spatial structure (the Context Tree) that breaks the codebase into modules, each with a declared intent and interface. This structure mirrors how human engineers organize software — hierarchical, with well-defined responsibilities at each level.

2. **Evolution**: A temporal model (the Phylogenetic Graph) that treats code changes as mutations in a directed acyclic graph of immutable states. This enables partial-progress acceptance, rollback, branching, and crossover — the primitives of an evolutionary process.

3. **Convergence**: A fixed-point formulation that defines what it means for a codebase to be "complete." The system iterates until each module's implementation matches its declared summary and each summary accurately describes its implementation. This provides a termination criterion and a measure of progress.

### 1.3 Why This Combination Works

The neuro component (the LLM) provides *generative capability* — the ability to produce plausible code, documentation, and architectural decisions from natural language. The symbolic component provides *structure, memory, and convergence guarantees* — the ability to decompose problems, track history, verify consistency, and iterate toward correctness.

Neither component alone suffices. The LLM without structure produces unbounded, unverifiable output. The symbolic scaffold without the LLM is an empty framework with no generative power. Together, they form a system that is both creative (capable of generating novel solutions) and rigorous (guaranteed to converge to a consistent state).

---

## 2. Mathematical Formulation

We now formalize the problem of generating a codebase from a specification. This formulation is deliberately abstract: it applies not only to software but to any domain where a hierarchical artifact must satisfy a recursive consistency property.

### 2.1 The Summary–Code Fixed Point

Let $\mathcal{C}$ be the space of all possible codebases (or, more abstractly, all possible artifacts). Let $\mathcal{S}$ be the space of all possible summaries (specifications, intents, interfaces). Define two operators:

- **Summary operator** $\Sigma: \mathcal{C} \to \mathcal{S}$: given a codebase, extract its summary — what it does, what it exposes, what constraints it obeys.
- **Code operator** $\Gamma: \mathcal{S} \to \mathcal{C}$: given a summary, produce a codebase that realizes it.

A codebase $c \in \mathcal{C}$ is **self-consistent** (or *converged*) if applying the summary operator and then the code operator returns the original codebase — that is, the summary accurately describes the code and the code faithfully implements the summary. Formally, we require:

$$c = \Gamma(\Sigma(c))$$

This is a **fixed-point equation**. The codebase $c$ is a fixed point of the composite operator $\Gamma \circ \Sigma$. Equivalently, the summary $s = \Sigma(c)$ satisfies $s = \Sigma(\Gamma(s))$, meaning the summary is a fixed point of $\Sigma \circ \Gamma$.

In practice, neither equality holds exactly. A codebase may have bugs (the implementation doesn't match the intent), missing features (the summary describes things not yet built), or stale documentation (the summary fails to describe actual behavior). The fixed-point formulation gives us a precise definition of correctness: a codebase is correct when it's a fixed point of $\Gamma \circ \Sigma$.

### 2.2 The Iterative Convergence Process

The fixed-point equation $c = \Gamma(\Sigma(c))$ is not directly solvable — we cannot compute $\Gamma(\Sigma(c))$ in one step for a nontrivial codebase because $\Gamma$ itself is intractable (it requires generating an entire codebase from a summary). We therefore introduce time and iterate:

$$c_{t+1} = \Gamma(\Sigma(c_t))$$

Starting from an initial codebase $c_0$ (possibly empty), we repeatedly: (1) extract the summary of the current codebase, (2) regenerate the codebase from that summary, and (3) check whether anything changed. The process converges when $c_{t+1} = c_t$, i.e., when the summary faithfully describes the code and the code faithfully implements the summary.

However, this simple iteration has a critical problem: the operator $\Gamma \circ \Sigma$ is not guaranteed to be a contraction, and the iteration may oscillate or diverge. Moreover, computing $\Gamma(\Sigma(c_t))$ over an entire codebase is exactly the problem we're trying to solve — it's too large for a single LLM call.

### 2.3 Spatial Decomposition: The Hierarchical Fixed Point

The key insight is that the fixed-point property can be enforced **hierarchically**. A codebase is not a monolithic entity; it decomposes into modules, each with its own summary and implementation. Let a codebase $c$ be a set of modules $\{m_1, m_2, \ldots, m_n\}$ organized in a tree $\mathcal{T}$. Each module $m_i$ has:

- A **local summary** $s_i \in \mathcal{S}$: its CONTEXT.md, declaring intent, API surface, and constraints.
- A **local implementation** $b_i \in \mathcal{C}_i$: the actual code in that module.
- A **decomposition** into child modules $\{m_j : j \in \text{children}(i)\}$, where each child has its own summary and implementation.

For a module $m_i$, define:

- **Local summary operator** $\sigma_i$: given the implementation $b_i$ and child summaries $\{s_j\}_{j \in \text{children}(i)}$, produce a summary $s_i$. This captures the idea that a module's summary should describe both its own code and the capabilities of its children.
- **Local code operator** $\gamma_i$: given a summary $s_i$, produce an implementation $b_i$ and delegate child summaries $\{s_j\}$ to child modules.

Then the hierarchical fixed point requires, for every module $i$:

$$(b_i, \{s_j\}) = \gamma_i(\sigma_i(b_i, \{s_j\}))$$

That is, every module is self-consistent *given* the summaries of its children. This is a **recursive fixed point**: the root module delegates to children, children delegate to grandchildren, and consistency must hold at every level.

### 2.4 Spatiotemporal Dynamics

We now introduce both spatial and temporal indices. Let $m_i^{(t)}$ denote module $i$ at time $t$. The state of module $i$ at time $t$ is its implementation $b_i^{(t)}$ and its summary $s_i^{(t)}$. The evolution of module $i$ is governed by:

$$(b_i^{(t+1)}, \{s_j^{(t+1)}\}_{j \in \text{children}(i)}) = \gamma_i\left(\sigma_i\left(b_i^{(t)}, \{s_j^{(t)}\}_{j \in \text{children}(i)}\right)\right)$$

This is analogous to the **Bellman equation** in reinforcement learning, where the value of a state depends on the values of successor states. Here, the correctness of a module depends on the correctness of its children. The "value function" is the summary, the "policy" is the implementation, and "optimality" is the fixed point where summary and implementation agree.

The key properties of this formulation:

1. **Every point in the iteration is a valid state.** Unlike optimization procedures that are only useful at convergence, every $(c_t)$ in the sequence is a potentially useful codebase. It may have bugs or missing features, but it compiles, runs, and can be deployed. This is the *partial progress acceptance* principle: a version is accepted if it improves the codebase, even if other parts remain broken.

2. **If the fixed point is unreachable, evolution continues indefinitely.** The system never "fails" — it keeps producing incrementally better states. This models real software development, where perfect correctness is asymptotically approached but never fully achieved.

3. **The decomposition enables parallel evolution.** Modules at the same depth that don't depend on each other can evolve simultaneously. The spatial tree structure naturally exposes parallelism: siblings are independent given their parent's summary.

### 2.5 From Continuous to Discrete Time

In functional programming terms, the fixed point $c = \Gamma(\Sigma(c))$ is the solution to a recursive equation. To compute it, we unfold the recursion into an explicit time dimension:

```haskell
-- The fixed point as a limit
converged :: Codebase -> Codebase
converged c = let c' = generate (summarize c)
              in if c' == c then c else converged c'

-- Unfolded into discrete time steps
evolve :: Codebase -> [Codebase]
evolve c0 = c0 : evolve (generate (summarize c0))
```

In Genesis, each time step corresponds to a Git commit. The commit DAG records the evolutionary history, enabling branching (try multiple approaches), rollback (revert to a previous state), and crossover (merge features from different branches).

---

## 3. High-Level Design

We now translate the mathematical formulation into a concrete design for automated software development. The abstraction level here bridges the gap between the general fixed-point theory and the specific mechanisms of the Genesis runtime.

### 3.1 The Transient Agent Model

An **agent** is a stateless function that transforms a module from one state to another:

```
NewState = Agent(State, Objective)
```

The agent's state is defined by four components:

| Component | Meaning | Mathematical Analog |
|-----------|---------|---------------------|
| `node_path` | Position in the Context Tree (spatial) | Module index $i$ |
| `base_commit` | The Git commit the agent starts from (temporal origin) | Initial time $t$ |
| `current_commit` | The Git commit the agent is building (temporal position) | Current time $t'$ |
| `objective` | Natural language directive | The target summary $s_i$ |

Critically, the agent has **no persistent memory**. All persistent memory resides in one of two places:

- **Spatial memory**: The Context Tree — `CONTEXT.md` files in each directory, storing summaries, routing tables, and design rationale.
- **Temporal memory**: The Git history — an immutable, append-only DAG of commits recording every state the codebase has passed through.

This design has profound implications. An agent can be resurrected from any `(node_path, commit_sha, objective)` tuple — it's a pure function of these inputs. There is no "agent memory corruption," no "lost context," and no difficulty in rolling back. Want to try a different approach? Branch from an earlier commit and re-invoke the agent. Want to parallelize? Spawn two agents from the same base commit with different objectives. The Git DAG handles merging.

### 3.2 The Context Tree: Spatial Dimension

The Context Tree is the hierarchical decomposition of the codebase into directories, each with a `CONTEXT.md` file serving as its summary. Formally, it's a rooted tree $\mathcal{T} = (V, E)$ where:

- Each node $v \in V$ is a directory with a `CONTEXT.md` file.
- The root node `./` contains the top-level summary.
- Edges represent parent-child directory relationships.
- Each `CONTEXT.md` contains: **Intent** (what this module does), **API Surface** (what it exposes), **Constraints** (rules for code within), and a **Routing Table** (mapping of concerns to child subdirectories).

A key design decision: the Context Tree provides explicit, structured context only down to the **directory level**. Within a directory, the agent relies on the LLM's natural ability to comprehend file-level context (docstrings, comments, code structure). This boundary prevents context bloat — we don't need a `CONTEXT.md` for every file, only for every semantically meaningful module boundary.

The **Routing Table** is what enables hierarchical decomposition without global knowledge. A parent agent doesn't need to understand the internals of its children — it only needs to know which child owns which concern. When an objective requires work in "the authentication module," the root agent consults its routing table, finds that auth lives under `./src/auth/`, and delegates there — without ever reading a single file in that subtree.

### 3.3 The Phylogenetic Graph: Temporal Dimension

The temporal dimension is modeled as a Directed Acyclic Graph (DAG) of immutable Git commits. Each commit is a snapshot of the entire codebase at a point in time. The DAG structure (rather than a linear chain) enables branching and merging:

- **Branches** represent alternative evolutionary paths — different approaches to the same problem.
- **Merges** represent phylogenetic crossover — combining successful features from different branches.
- **The partial order** $v_{\text{new}} > v_{\text{old}}$ is defined by acceptance: a child commit is accepted if and only if it is measurably "better" than its parent on some criterion (more tests passing, new feature implemented, etc.).

The DAG structure naturally supports the fixed-point iteration. Each iteration $c_t \to c_{t+1}$ is a commit. The "distance" to the fixed point is measured by how much changed between iterations. When two consecutive states are identical (no files changed), the fixed point is reached at that level.

### 3.4 Agent Delegation as Hierarchical Fixed-Point Iteration

The agent's core operation maps directly to the local fixed-point operator. When an agent at module $i$ receives an objective:

1. **Summarize** ($\sigma_i$): The agent reads the current implementation $b_i$ and the summaries $\{s_j\}$ of its children (via their `CONTEXT.md` files). It forms an understanding of the current state.

2. **Plan**: The agent compares the current state against the objective. If the objective is already satisfied, it returns success (the module is at a local fixed point). Otherwise, it identifies what needs to change.

3. **Delegate** ($\gamma_i$): For work in child modules, the agent spawns subagents. Each subagent receives:
   - A `node_path` pointing to the child directory
   - A `base_commit` (the current state)
   - An `objective` (what the child should become)

4. **Validate**: When subagents return, the agent evaluates their results against the objective. If satisfied, it commits and returns. If not, it spawns new subagents with refined objectives — iterating toward the fixed point.

This process is identical at every level of the tree. The root agent delegates to top-level module agents, who delegate to sub-module agents, and so on — recursively until the leaves. At each level, the agent follows the same summarize→plan→delegate→validate loop, and each level can iterate independently until its local fixed point is reached.

### 3.5 Pseudocode

```
function run_agent(node_path, base_commit, objective):
    current_commit = base_commit
    iteration = 0

    while iteration < max_iterations:
        // Summarize: read current state
        context = build_context_tree(node_path, current_commit)
        child_summaries = read_child_contexts(node_path, current_commit)
        implementation = read_implementation(node_path, current_commit)

        // Plan: compare against objective
        gaps = analyze(objective, context, child_summaries, implementation)

        if gaps is empty:
            return success(current_commit)  // Fixed point reached

        // Delegate: spawn subagents for child work
        child_specs = []
        for each gap in gaps:
            child_path = routing_table.lookup(gap.domain)
            child_specs.append({
                node_path: child_path,
                base_commit: current_commit,
                objective: gap.objective
            })

        // Commit before delegating (required by worktree model)
        current_commit = commit_pending_changes()

        // Spawn subagents in parallel
        results = spawn_subagents_parallel(child_specs)

        // Merge results (phylogenetic crossover)
        current_commit = octopus_merge(current_commit, results.commits)

        // Validate
        if all_succeeded(results):
            iteration += 1
            continue  // Next iteration to check if fixed point reached
        else:
            // Some subagents failed — try again with refined objectives
            iteration += 1
            continue

    return partial_success(current_commit)  // Best effort reached
```

---

## 4. Mid-Level Design

This section describes the key architectural components that make the high-level design operational. These are design choices — *what* the system does, not *how* it's implemented.

### 4.1 The Agent Scheduler

The Agent Scheduler is the central orchestrator, analogous to an operating system's process scheduler. It manages a fixed pool of computational resources — Git worktrees, LLM API slots, and tool execution slots — and allocates them to agents.

**Resource Pools:**

- **Worktree pool**: Each agent runs in an isolated Git worktree (a separate working directory sharing the same `.git` repository). The pool size limits how many agents can execute concurrently.
- **LLM slots**: Each LLM API call consumes a slot from a per-model pool. Multiple model pools enable using different providers with independent concurrency limits. When a rate-limit error occurs, the affected model's pool enters a global backoff period (60 seconds), preventing all agents from hammering the same API.
- **Tool slots**: Tool executions (shell commands, file operations) consume from a shared pool, preventing resource exhaustion from too many concurrent processes.

**Agent Lifecycle States:**

```
pending → running ⇄ waiting → ready → running → (complete)
              ↓
           blocked (when paused or slot-starved)
```

- `pending`: Agent is registered but hasn't started yet.
- `running`: Agent is actively executing its turn loop.
- `waiting`: Agent has spawned subagents and yielded its worktree; waiting for results.
- `ready`: All subagents have completed; parent is ready to resume.
- `blocked`: Agent is `running` but waiting for an LLM or tool slot.

**Cooperative Yielding**: When an agent spawns subagents, it must *yield* — commit pending changes, transition to `waiting`, and release its worktree. This is not a limitation but a feature: it ensures worktree resources are used efficiently, enables parallel subagent execution, and naturally enforces the "commit before delegate" discipline required by the temporal dimension.

### 4.2 The Context Tree as a Prefix Tree for KV Cache

The Context Tree has a property that makes it particularly well-suited for LLM inference: it's a **prefix tree**. An agent at path `./src/auth/oauth/` inherits the context chain:

```
./CONTEXT.md → ./src/CONTEXT.md → ./src/auth/CONTEXT.md → ./src/auth/oauth/CONTEXT.md
```

For the LLM, this means the context prompt for a child agent is a *prefix* of the context prompt for its parent (plus the child's own `CONTEXT.md`). In transformer architectures with Key-Value (KV) caching, this prefix property enables efficient inference: the KV cache computed for the shared prefix can be reused across sibling agents and between parent and child. While Genesis doesn't currently exploit this optimization at the inference level, the structural property exists and is a deliberate design choice — it means that as the tree deepens, the *additional* context needed per agent grows only by the size of one `CONTEXT.md` file, not by the cumulative depth.

### 4.3 Subagent Call Modeling

A subagent call is modeled as a function application with well-defined semantics:

```
subagent_result = subagent(node_path, base_commit, objective)
```

Where:
- **Input**: `node_path` (spatial locus), `base_commit` (temporal origin), `objective` (natural language directive)
- **Output**: `result` containing `{status, current_commit, diff_stats, report, usage}`
- **Side effects**: The subagent creates new commits in the repository

This is a pure function from the parent's perspective: given the same inputs, a subagent produces the same outputs (deterministic given the LLM's behavior). The subagent's internal iterations, its own subagent delegations, and its turn-by-turn LLM interactions are all encapsulated — the parent sees only the final result.

**Parallel composition**: Multiple subagent calls with no mutual dependencies can be issued simultaneously. The system spawns them in parallel, each in its own isolated worktree. Results are collected and merged via an octopus merge (Git's multi-parent merge). This is the primary parallelism mechanism in Genesis.

**Sequential composition**: When subagent B depends on subagent A's output, they must run sequentially. The parent agent orchestrates this by spawning A, waiting for its result, then spawning B with A's output incorporated into B's objective. The task scheduler agent can plan these dependency chains before execution begins.

### 4.4 The Neuro-Symbolic Loop in Detail

Each agent turn follows a neuro-symbolic cycle:

1. **Symbolic → Neuro**: The agent's current state (context tree, objective, recent tool outputs) is serialized into a prompt — a textual representation fed to the LLM. This is the symbolic-to-neural bridge: structured state becomes natural language.

2. **Neuro computation**: The LLM processes the prompt and produces a response — typically one or more tool calls. This is pure pattern recognition and generation, operating entirely in the neural domain.

3. **Neuro → Symbolic**: The tool calls are parsed and executed by the symbolic runtime. File reads, writes, searches, git operations, and subagent spawns all happen through deterministic, verifiable code paths. The results become structured state.

4. **Symbolic verification**: Before the next turn, the system checks invariants: Is the agent within its turn budget? Is the spatial contract being respected? Has the current commit advanced? These checks are purely symbolic — they don't depend on LLM judgment.

This alternation between neural generation and symbolic execution is the engine that drives convergence. The LLM proposes changes; the symbolic runtime applies them, checks constraints, and feeds the results back. Errors are caught by the symbolic layer, not by hoping the LLM notices them.

### 4.5 The Skills System

Skills are reusable, parameterized procedures defined as markdown files with YAML frontmatter. Each skill contains an executable bash block that the runtime can invoke as a tool. Skills are globally defined (in `.agents/skills/`) but hierarchically enabled per Context Tree node via `CONTEXT.md` front matter.

This creates a **self-improving loop**: the SkillExtractor agent analyzes completed work and distills successful patterns into new skills. Future agents in the same subtree automatically gain access to these skills, enabling cumulative learning across the evolutionary history.

---

## 5. Low-Level Design

At this level, we describe the concrete runtime mechanisms that implement the design. These are implementation choices — *how* the system achieves its goals, given the constraints of the Elixir/OTP runtime.

### 5.1 The Actor Model and Supervision Tree

Genesis is built on the Erlang/OTP actor model, where each component is a lightweight process communicating via message passing. The supervision tree provides fault tolerance: when a component crashes, its supervisor restarts it according to a configured strategy.

The supervision tree is structured as follows:

```
EvoGit.Supervisor (one_for_one)
├── ETS Tables (application-owned, survive restarts)
│   ├── :evogit_agent_state      — Agent-owned live state
│   ├── :evogit_sched_meta       — Scheduler-owned metadata
│   └── :evogit_archive_records  — Task archive (duplicate_bag)
├── Phoenix.PubSub               — Real-time event broadcasting
├── RemoteConnection.Registry    — Named process registry
├── RemoteConnection.Supervisor  — Dynamic SSH tunnel processes
├── EvoGit.Store                 — SQLite persistence (xqlite)
├── EvoGit.TaskRegistry          — Long-lived task management
├── EvoGit.AgentScheduler.WorktreeManager — Isolated filesystem I/O
├── EvoGit.AgentGroupSupervisor (one_for_all)
│   ├── Task.Supervisor          — Agent Task supervisor
│   └── EvoGit.AgentScheduler    — The central GenServer
├── [Linux] SandboxProcessRegistry — Monitor sandboxed processes
└── [Linux] SandboxSlice          — systemd cgroup resource limits
```

**Crash survival strategy:**

- **Agent crashes**: Each agent runs as a `Task` under `Task.Supervisor`. If an agent crashes, the scheduler detects it via a `DOWN` monitor message. The crash handler releases all slots (preventing resource leaks), then either retries the agent (if under the retry limit) or marks it as permanently failed and notifies the parent.
- **Scheduler crashes**: The `AgentGroupSupervisor` uses `one_for_all` — if the scheduler crashes, the TaskSupervisor also restarts. ETS tables are owned by the Application process, so they survive scheduler restarts with all state intact.
- **WorktreeManager crashes**: Isolated under `one_for_one` — its crash doesn't affect the scheduler. Pending worktree deletions may be lost, but worktrees are idempotently cleaned on next initialization.
- **Sandbox crashes**: Linux sandbox components (SandboxProcessRegistry, SandboxSlice) are optional and isolated. Their failure doesn't affect core operation.

The design philosophy follows Erlang's "let it crash" approach: components are designed to crash cleanly and restart from known-good state. There is no defensive error handling in the hot path — crashes propagate to supervisors, which restore the system to a consistent state.

### 5.2 ETS as Shared State

Two ETS (Erlang Term Storage) tables serve as the system's working memory:

| Table | Owner | Contents |
|-------|-------|----------|
| `:evogit_agent_state` | Agent processes | `%AgentState{}`: context, context_node, phylo_node, model, objective, usage, turn count, etc. |
| `:evogit_sched_meta` | Scheduler process | `%SchedMeta{}`: status, worktree assignment, parent/child tracking, retries, task ref |

The ownership split is deliberate: agents own their live state (what they're working on), the scheduler owns scheduling metadata (how they relate to other agents). Agents update their phylo_node after each commit; the scheduler reads this to track progress. The scheduler never touches agent state; agents never touch scheduling metadata. This eliminates an entire class of concurrency bugs.

Every ETS write to `:evogit_agent_state` triggers a PubSub broadcast, enabling the web dashboard to display real-time agent status without polling.

### 5.3 The Git Worktree Mechanism

Git worktrees are the isolation primitive. A Git worktree is an additional working directory attached to the same repository, with its own branch and working tree but sharing the same object database. This means:

- **Isolation**: Each agent has its own working directory. Concurrent agents never conflict on file operations.
- **Efficiency**: Worktrees share the `.git` object database. Creating a worktree is O(size of working tree), not O(size of repository history).
- **Branch-based**: Each worktree has its own branch. Agents commit freely without affecting the main branch. The scheduler merges successful branches back.

**Worktree lifecycle:**

1. **Creation**: `git worktree add --detach <path> <base_commit>` creates a detached worktree at the agent's base commit.
2. **Preparation**: `git clean -fdx` removes untracked files; `git checkout <commit>` ensures the correct starting point.
3. **Execution**: The agent runs in the worktree, committing changes as it works. Each commit advances the `current_commit` pointer.
4. **Reclamation**: On agent completion, the scheduler merges the agent's branch (via octopus merge for subagent results) and asynchronously deletes the worktree via `git worktree remove`.

**Naming convention**: Worktree directories follow the pattern `worker_T<task_num>_A<agent_id>` under `.genesis/workers/`. Branch names follow `evogit-agent-T<task_num>-A<agent_id>`. This enables the scheduler to identify and clean up orphaned worktrees from previous crashed runs.

**Why worktrees instead of clones**: Git clones would duplicate the entire object database, making agent spawning prohibitively slow for large repositories. Worktrees share the object database, making agent creation O(working tree size) regardless of history depth. This is essential for the fast agent spawning required by the recursive decomposition pattern.

### 5.4 Slot Management and Backoff

LLM API calls are the system's primary bottleneck. Genesis manages them through a sophisticated slot system:

**Per-model pools**: Each configured LLM model has its own slot pool with independent concurrency limits. This allows using a fast, cheap model for simple tasks and a powerful, rate-limited model for complex tasks — the slow model's rate limiting doesn't block the fast model's throughput.

**Grant algorithm**: When a slot is released, the scheduler scans the waiting queue and grants the slot to the most eligible waiter. "Eligible" means not in backoff for that model. Among eligible waiters, the one that was most recently granted a slot gets priority (preventing starvation), with depth as a tiebreaker (shallower agents first, since they block more of the tree).

**Backoff mechanism**: When a rate-limit error is detected for a model, that model's entire pool enters backoff for 60 seconds. All waiting agents for that model are re-queued with a backoff timestamp. A retry timer fires after 65 seconds to re-process the queue. This prevents the classic "thundering herd" problem where all agents simultaneously retry after being rate-limited.

### 5.5 The Turn Loop

Each agent executes a turn loop, processing one LLM interaction per turn:

```
Turn:
  1. Context compression (if needed): Truncate oldest messages to stay within token budget.
  2. Turn warning check: At 50% and 80% of turn budget, inject system warnings.
  3. Sync state to ETS: Update turn count, token usage, current commit.
  4. Turn-limit recovery check: If turn limit exceeded, enter grace period.
  5. LLM call: Acquire LLM slot → call LLM with tools → release slot.
  6. Tool dispatch:
     - complete_task → agent finishes successfully.
     - Subagent call → commit → spawn subagents → wait → merge results.
     - Standard tool → execute → format result → append to context.
     - No tool calls → nudge LLM (up to 3 times) → if still none, protocol violation.
  7. Commit sync: Update phylo_node.current_commit after tool side effects.
  8. Recurse to next turn.
```

Key design points:
- **Grace period**: When the agent hits its turn limit, it gets exactly one more turn with an urgent system message to call `complete_task`. This prevents truncation at arbitrary points — the agent always gets a chance to finalize.
- **Auto-commit fallback**: A `try/after` block ensures that on ANY exit path (normal completion, crash, turn limit), pending changes are committed. This guarantees the worktree is clean before the scheduler processes the result.
- **No-tool-call nudging**: If the LLM returns a text response without tool calls, the system appends a nudge message and re-prompts (up to 3 times). This handles a common LLM failure mode without crashing or spinning forever.

---

## 6. Implementation Details

### 6.1 Language and Runtime

Genesis is implemented in **Elixir**, a functional language running on the Erlang VM (BEAM). This choice is motivated by several factors:

- **Lightweight processes**: BEAM processes are extremely cheap (microseconds to spawn, kilobytes of memory). Genesis spawns one BEAM process per agent per turn, plus processes for timers, monitors, and PubSub subscribers. A traditional OS-thread model would be prohibitively expensive.
- **Actor model**: BEAM's actor model naturally maps to Genesis's agent model. Each agent is a process; message passing enables clean separation between scheduler, agents, and tools.
- **Fault tolerance**: BEAM's supervision trees provide the crash-recovery infrastructure that Genesis relies on. The "let it crash" philosophy eliminates defensive error handling from application code.
- **ETS**: Erlang Term Storage provides fast, in-memory shared state without external dependencies. The two-ETS-table design (agent state + sched meta) leverages ETS's concurrent read capabilities.
- **Immutable data**: Elixir's immutable data structures eliminate an entire class of bugs related to shared mutable state, which is critical when agents run concurrently in separate processes.

### 6.2 External Dependencies

**Git CLI**: All Git operations use the command-line `git` binary via `System.cmd/3`. This choice avoids libgit2 bindings, which would introduce NIF complexity, potential memory corruption, and version compatibility issues. The CLI approach is slower per-operation but simpler, more debuggable, and trivially portable. Environment variables are pinned (`LC_ALL=C` for locale-independent output, `GIT_EDITOR=true` for non-interactive operation).

**LLM Integration**: The `ReqLLM` library provides a unified interface to multiple LLM providers. It handles streaming responses, tool-call parsing, and context management. Provider-specific details (API keys, endpoints, model names) are abstracted behind a common API.

**Phoenix PubSub**: Used for real-time event broadcasting from the scheduler to the web dashboard. The PG2 adapter (backed by BEAM's `:pg` module) enables cluster-aware broadcasting — when the dashboard connects to a remote Genesis node over Erlang distribution, PubSub messages propagate automatically.

**SQLite (via xqlite)**: Persistent storage for tasks and projects. The GenServer-based wrapper provides async-friendly database access within the BEAM ecosystem. WAL mode is enabled for concurrent read performance.

**TomlElixir**: Parses TOML configuration files (`~/.config/genesis/config.toml`, project `genesis.toml`).

### 6.3 Sandboxing

Code generated by LLMs executes under platform-appropriate sandboxing:

- **Linux**: `systemd-run --user` with a dedicated systemd slice (`evogit.slice`). The slice enforces CPU, memory, and task count limits. Each sandboxed command runs as a transient service unit; if the agent process crashes, the `SandboxProcessRegistry` detects it via process monitoring and stops the orphaned service.
- **macOS**: `sandbox-exec` with a custom profile that grants read/write access to the agent's worktree but read-only access elsewhere.
- **Windows**: Direct execution (sandboxing not yet implemented).

Resource limits are configurable via the TOML configuration file.

### 6.4 Configuration System

Genesis uses a three-level configuration hierarchy:

1. **Application defaults**: Built-in sensible defaults (no model or username hardcoded).
2. **User config**: `~/.config/genesis/config.toml`, following XDG conventions. Contains LLM model profiles, scheduler settings, sandbox configuration, etc.
3. **Runtime overrides**: CLI flags and dashboard settings that override both defaults and user config for the current session.

Per-project configuration (`genesis.toml` at the repository root) supports worktree initialization scripts (e.g., copying build caches), custom development commands, and foreign repository definitions.

### 6.5 The Two-Phase Genesis Process

Creating a codebase from scratch (Genesis Mode B) uses a two-phase process:

**Phase 1 — Architecture** (`CodebaseLead` agent):
- Interprets the user's prompt at the root node.
- Designs the directory structure, creates `CONTEXT.md` files, and defines public APIs.
- Recursively delegates child directory architecture to `CodebaseLead` subagents.
- Does NOT implement code — its output is the architectural skeleton.

**Phase 2 — Implementation** (`Manager` agent):
- Starts from the architect's final commit.
- Reviews the established architecture and identifies unimplemented work.
- Delegates implementation to `Executor` subagents at each module.
- Iterates until all modules are fully implemented.

This separation mirrors the summary→code fixed-point dynamic: Phase 1 establishes summaries (CONTEXT.md files defining intent), Phase 2 produces code that realizes those summaries.

### 6.6 Tool Library

Agents have access to a comprehensive toolset:

| Category | Tools | Purpose |
|----------|-------|---------|
| File I/O | `read_file`, `write_file`, `edit_file`, `create_files`, `make_dir` | Code manipulation |
| Search | `rg` (ripgrep), `glob`, `search_context`, `search_history`, `search_web` | Codebase exploration |
| Execution | `run_bash` | Shell command execution |
| Git | Via `run_bash` with sandbox restrictions | Version control operations |
| Context | `read_context`, `write_context`, `edit_context` | CONTEXT.md management |
| Delegation | `subagent_manager`, `subagent_executor`, `subagent_task_scheduler`, `subagent_codebase_investigator` | Hierarchical decomposition |
| Skills | `skill_list`, `skill_read`, `skill_add`, `skill_edit`, `skill_remove`, `skill_enable`, `skill_disable`, `skill_where` | Dynamic skill management |

### 6.7 Agent Taxonomy

| Agent | Role | Type | Key Capability |
|-------|------|------|---------------|
| **Manager** | Orchestration, refinement | Read-Write | Coordinates child agents; does not do initial implementation |
| **Executor** | Targeted code changes | Read-Write | Precise implementation from well-defined objectives |
| **CodebaseLead** | Architecture design | Read-Write | Designs structure, CONTEXT.md, public APIs for greenfield projects |
| **CodebaseInvestigator** | Deep analysis | Read-Only | Investigates codebase, answers queries, updates CONTEXT.md |
| **ContextExtractor** | Semantic extraction | Read-Only | Builds CONTEXT.md tree from existing codebases |
| **TaskScheduler** | Execution planning | Read-Only | Transforms objectives into ordered task sequences |
| **GenesisPlanner** | Genesis planning | Read-Only | Dependency-aware execution plans for architecture |
| **Evaluator** | Quality verification | Read-Only | Reviews diffs against objectives |
| **SkillExtractor** | Knowledge distillation | Read-Write | Distills successful patterns into reusable skills |

---

## 7. Discussion

### 7.1 Relationship to Classical Software Engineering

Genesis's architecture mirrors the structure of well-engineered software organizations. The Context Tree corresponds to a team hierarchy: a tech lead defines the architecture and delegates modules to senior engineers, who further decompose and delegate to individual contributors. The Phylogenetic Graph corresponds to version control: every change is tracked, branches enable parallel work, and merges combine contributions. The fixed-point formulation captures the engineering intuition that software is "done" when the implementation matches the specification at every level.

### 7.2 Relationship to Reinforcement Learning

The spatiotemporal fixed-point equation bears a structural similarity to the Bellman optimality equation. In RL, the value of a state is defined recursively in terms of the values of successor states; in Genesis, the correctness of a module is defined recursively in terms of the correctness of its children. The "policy" (implementation) and "value function" (summary) co-evolve toward a joint fixed point. The key difference is that Genesis uses LLMs as the optimization mechanism rather than gradient descent — but the mathematical structure is the same.

### 7.3 Scalability Properties

The recursive decomposition pattern gives Genesis several scalability properties:

- **Depth independence**: Adding more levels to the Context Tree doesn't increase any single agent's cognitive load. Each agent only sees its own level's context plus inherited summaries.
- **Breadth parallelism**: Sibling modules at the same depth are independent and can evolve simultaneously. The degree of parallelism scales with the breadth of the tree.
- **Incremental progress**: Partial states are valid and deployable. A codebase can be used and improved incrementally; there's no "all or nothing" threshold.

### 7.4 Limitations and Future Work

- **LLM dependence**: The quality of generated code is bounded by LLM capability. Improvements in foundation models directly improve Genesis output.
- **Verification depth**: While the fixed-point formulation guarantees structural consistency, semantic correctness (does the code actually do what the summary says?) still relies on testing and LLM judgment.
- **Convergence guarantees**: The fixed-point iteration is not guaranteed to converge to a global optimum — only to a local fixed point where no further changes are proposed. This is analogous to gradient descent converging to a local minimum.

---

## References

1. Genesis Design Specification (`AGENTS.md`) — The original human-written design document describing the dual-dimension architecture, transient agent model, and runtime phases.

2. Erlang/OTP Documentation — The actor model, supervision trees, and ETS that form Genesis's runtime foundation. See: https://www.erlang.org/doc

3. Elixir Programming Language — The functional language used for Genesis's implementation. See: https://elixir-lang.org

4. Git Worktree Documentation — The isolation primitive enabling concurrent agent execution. See: https://git-scm.com/docs/git-worktree

5. Sutton, R.S. & Barto, A.G. — *Reinforcement Learning: An Introduction*. The Bellman equation and fixed-point formulation that inspired Genesis's spatiotemporal dynamics.

6. ReqLLM Library — The LLM integration layer providing unified access to multiple AI providers with streaming and tool-call support.

7. Phoenix PubSub — Real-time event broadcasting for dashboard-agent communication. See: https://hexdocs.pm/phoenix_pubsub

8. `systemd-run` / `sandbox-exec` — Platform-specific sandboxing mechanisms for LLM-generated code execution.
