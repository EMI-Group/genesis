# Genesis: From AI Vibe Coding to Autonomous Software Evolution

## Abstract

Genesis is a neuro-symbolic framework that automates the creation and evolution of software through recursive hierarchical decomposition. It marries the pattern-recognition capabilities of large language models (the *neuro* component) with a principled evolutionary architecture grounded in fixed-point theory (the *symbolic* component). The system models a codebase along two orthogonal dimensions — a **spatial** Context Tree capturing hierarchical structure and a **temporal** phylogenetic DAG capturing evolutionary history. Through the iterative application of a *summary–code fixed-point operator*, Genesis guarantees that every level of the codebase reaches semantic convergence: each module's implementation faithfully realizes its declared intent, and each summary accurately reflects its implementation. This paper presents the framework's mathematical foundation, architectural design, and implementation, showing how the recursive application of a simple fixed-point principle yields a system capable of autonomously building and refining arbitrarily complex software.

---

## 1. Philosophy: The Neuro-Symbolic Design

The current paradigm of AI-assisted programming is dominated by end-to-end Large Language Models (LLMs). While LLMs excel at "vibe coding" — generating localized, contextually plausible snippets based on human prompts — they fundamentally fail at autonomous software engineering for large-scale systems. This failure stems from two inherent limitations of purely neural architectures:

1. **The Context Window Bottleneck:** End-to-end models require all relevant information to be packed into a finite context window. For a trivial script, this works. For an enterprise application, it is impossible. As the codebase grows, the LLM loses track of distant dependencies, global architectural constraints, and subtle state invariants.
2. **Error Compounding:** Software is a rigid, symbolic domain. A single hallucinated API call or a type mismatch breaks the entire build. In a purely neural generative process, slight probabilistic errors compound over time, inevitably leading to a divergent, uncompilable state.

Genesis solves this by adopting a **Neuro-Symbolic** architecture. It delegates the fuzzy, creative task of writing specific logic and translating natural language to the LLM (the *neuro* component). However, it wraps this generation within a rigid, deterministic scaffold (the *symbolic* component). The symbolic layer enforces the directory structure, manages the temporal version control (Git), executes the tools, isolates dependencies, and mathematically verifies progress. By bounding the LLM's operation to strictly defined local modules and orchestrating those modules via a hierarchical graph, Genesis prevents error compounding and bypasses the context window limit entirely.

---

## 2. Mathematical Formulation

We now formalize the problem of generating a codebase from a specification. This formulation is deliberately abstract: it applies not only to software but to any domain where a hierarchical artifact must satisfy a recursive consistency property.

### 2.1 The Summary–Code Fixed Point

Let $\mathcal{C}$ be the space of all possible codebases (or, more abstractly, all possible artifacts). Let $\mathcal{S}$ be the space of all possible summaries (specifications, intents, interfaces). Define two operators:

* **Summary operator** $\Sigma: \mathcal{C} \to \mathcal{S}$: given a codebase, extract its summary — what it does, what it exposes, what constraints it obeys.
* **Code operator** $\Gamma: \mathcal{S} \to \mathcal{C}$: given a summary, produce a codebase that realizes it.

A codebase $c \in \mathcal{C}$ is **self-consistent** (or *converged*) if applying the summary operator and then the code operator returns the original codebase — that is, the summary accurately describes the code and the code faithfully implements the summary. Formally, we require:

$$c = \Gamma(\Sigma(c))$$

This is a **fixed-point equation**. The codebase $c$ is a fixed point of the composite operator $\Gamma \circ \Sigma$. Equivalently, the summary $s = \Sigma(c)$ satisfies $s = \Sigma(\Gamma(s))$, meaning the summary is a fixed point of $\Sigma \circ \Gamma$.

### 2.2 The Iterative Convergence Process

The fixed-point equation $c = \Gamma(\Sigma(c))$ is not directly solvable — we cannot compute $\Gamma(\Sigma(c))$ in one step for a nontrivial codebase because $\Gamma$ itself is intractable. We therefore introduce time and iterate:

$$c_{t+1} = \Gamma(\Sigma(c_t))$$

Starting from an initial codebase $c_0$, we repeatedly: (1) extract the summary of the current codebase, (2) regenerate the codebase from that summary, and (3) check whether anything changed. The process converges when $c_{t+1} = c_t$.

### 2.3 Spatial Decomposition: The Hierarchical Fixed Point

The fixed-point property can be enforced **hierarchically**. A codebase is a set of modules $\{m_1, m_2, \ldots, m_n\}$ organized in a tree $\mathcal{T}$. Each module $m_i$ has a **local summary** $s_i$, a **local implementation** $b_i$, and a **decomposition** into child modules $\{m_j : j \in \text{children}(i)\}$.

For a module $m_i$, define:

* **Local summary operator** $\sigma_i$: given $b_i$ and child summaries $\{s_j\}_{j \in \text{children}(i)}$, produce a summary $s_i$.
* **Local code operator** $\gamma_i$: given $s_i$, produce $b_i$ and delegate child summaries $\{s_j\}$ to child modules.

The hierarchical fixed point requires, for every module $i$:

$$(b_i, \{s_j\}) = \gamma_i(\sigma_i(b_i, \{s_j\}))$$

Every module is self-consistent *given* the summaries of its children. This is a recursive fixed point: the root delegates to children, children delegate to grandchildren, down to the leaves.

### 2.4 Spatiotemporal Dynamics

Let $m_i^{(t)}$ denote module $i$ at time $t$. The evolution of module $i$ is governed by:

$$(b_i^{(t+1)}, \{s_j^{(t+1)}\}_{j \in \text{children}(i)}) = \gamma_i\left(\sigma_i\left(b_i^{(t)}, \{s_j^{(t)}\}_{j \in \text{children}(i)}\right)\right)$$

This is analogous to the Bellman equation. The correctness of a module depends on the correctness of its children. Every point in the iteration $(c_t)$ is a valid, potentially deployable state, modeling the *partial progress acceptance* principle.

### 2.5 Partial Order and Convergence Guarantees

To rigorously define "progress," we must establish a way to compare codebases. However, it is mathematically and practically meaningless to compare two entirely unrelated codebases (e.g., comparing the Chrome repository to the Linux kernel).

Therefore, we restrict our comparison to "similar" codebases. We define $\mathcal{C}$ as a **partially ordered set (poset)** equipped with a relation $\preceq$. We declare that $c_1 \preceq c_2$ (meaning $c_2$ is greater than or equal to $c_1$ in quality/completeness) **if and only if** $c_2$ is exactly one evolutionary step (one Git commit) away from $c_1$ and represents a measurable improvement (e.g., passing tests, fulfilling a missing sub-summary).

Under this constrained poset definition, convergence guarantees become clear:

1. **Finite Space:** If the scope of the problem is bounded (e.g., a specific algorithm or a clearly scoped feature), the set of valid states is finite. Because our evolutionary operator strictly moves up the partial order ($\dots \preceq c_t \preceq c_{t+1} \dots$), the system is guaranteed to converge to a **maximal element** where $c_{t+1} = c_t$. This is the fixed point of completion.
2. **Infinite Space:** If the problem scope is open-ended (e.g., a complex, ever-expanding software ecosystem), the poset is infinite. The system will never reach an absolute fixed point but will **evolve forever**, continually migrating to strictly superior states without diverging into chaos.

---

## 3. High-Level Design

We now translate the abstract fixed-point formulation into concrete software engineering constructs.

To visualize this, imagine a user provides the ultimate summary: *"Build a scalable e-commerce web app with a product catalog and user checkout."* The root agent cannot build this in one step. Instead, it decomposes the problem spatially and resolves it temporally.

**Iterative Convergence & Spatial Decomposition Example:**

```text
[ ROOT: "E-Commerce App" ]
          |
          +---> [ MODULE A: "Frontend UI" ] 
          |       - Expects: REST API for products & checkout
          |
          +---> [ MODULE B: "Backend API" ]
                  - Expects: Database schema for products

```

1. **Decomposition:** The Root Agent decomposes the app into `Frontend` and `Backend`. It creates local summaries (`CONTEXT.md`) for both.
2. **Delegation:** It spawns a sub-agent for the Frontend and another for the Backend.
3. **Recursive Resolution:** The Backend agent further decomposes into `Database` and `Auth` modules.
4. **Convergence Verification:** Once the Frontend implements its UI and the Backend serves the API, the Root Agent evaluates if their *combined execution* satisfies the original summary. If it does, the tree converges.

### 3.1 The Transient Agent Model

An agent in Genesis is a **stateless, preemptible function** that transforms a module from one state to another:

`NewState = Agent(node_path, base_commit, objective)`

Agents have no persistent memory. Memory lives in two places:

* **Spatial memory:** The Context Tree (`CONTEXT.md` routing tables).
* **Temporal memory:** The Git history (DAG of commits).

Because agents are stateless, they can be paused, preempted, and resumed at any time by the system scheduler. If an agent crashes, it is simply resurrected from the `(node_path, base_commit, objective)` tuple.

### 3.2 The Context Tree: Spatial Dimension

The codebase is a rooted tree $\mathcal{T} = (V, E)$ where nodes are directories containing a `CONTEXT.md` file. The `CONTEXT.md` contains the module's Intent, API Surface, Constraints, and a Routing Table mapping concerns to child subdirectories. Parent agents do not read child code; they read child summaries.

### 3.3 The Phylogenetic Graph: Temporal Dimension

The temporal dimension is a Directed Acyclic Graph (DAG) of immutable Git commits. Branches represent alternative evolutionary paths, and merges represent phylogenetic crossover (combining successful features). The partial order $c_t \preceq c_{t+1}$ is physically represented by the parent-child relationship of verified commits.

### 3.4 Agent Delegation as Hierarchical Fixed-Point Iteration

When an agent operates on module $i$:

1. **Summarize:** Reads current implementation and child summaries.
2. **Plan:** Compares current state against objective. If satisfied, return success (fixed point).
3. **Delegate:** Spawns stateless subagents for child work based on the routing table.
4. **Validate:** Merges child results and evaluates. Iterates if necessary.

---

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

## 6. Implementation Details

### 6.1 Language and Runtime

Genesis is implemented in **Elixir** running on the Erlang VM (BEAM). BEAM processes are extremely cheap (microseconds to spawn). Genesis spawns one BEAM process per agent per turn. A traditional OS-thread model (like Python) would be prohibitively expensive and lack native supervision trees.

### 6.2 ETS as Shared State

Erlang Term Storage (ETS) serves as the system's high-speed working memory:

* `:evogit_agent_state` (Owned by Agents): Live context, objective data.
* `:evogit_sched_meta` (Owned by Scheduler): Worktree assignments, relationships.

The ownership split eliminates concurrency bugs. The scheduler never mutates an agent's internal state. Because ETS survives process crashes, if the scheduler fails, it reboots and instantly reads ETS to resume orchestration.

### 6.3 Sandboxing

Code generated by LLMs executes under strict sandboxing:

* **Linux:** `systemd-run --user` with a dedicated slice, enforcing CPU, memory, and task limits.
* **macOS:** `sandbox-exec` with a profile granting read/write only to the specific agent's worktree.

### 6.4 Configuration System

A three-level hierarchy (Application Defaults $\to$ User XDG Config $\to$ CLI Overrides) allows per-project configurations, foreign repository definitions, and dynamic model swapping.

### 6.5 The Two-Phase Genesis Process

Creating a greenfield codebase uses a two-phase process:

1. **Architecture Phase (`CodebaseLead` agent):** Recursively creates directory structures and `CONTEXT.md` files. It establishes the symbolic summaries but writes *no code*.
2. **Implementation Phase (`Manager/Executor` agents):** Iterates through the tree, producing the actual code to satisfy the summaries until the fixed point is reached.

### 6.6 Tool Library

Agents have access to deterministic tools: File I/O (`read_file`, `write_file`), Search (`rg`), Git operations via sandboxed Bash, Context Management, and dynamic Delegation (`subagent_executor`).

### 6.7 Agent Taxonomy

* **Manager / Executor:** Read-Write agents for orchestration and code implementation.
* **CodebaseLead:** Architecture design for greenfield projects.
* **CodebaseInvestigator / ContextExtractor:** Read-Only agents for deep semantic analysis and generating `CONTEXT.md` trees on legacy repositories.
* **Evaluator:** Read-Only quality verification agents.

---

## 7. Discussion

### 7.1 Relationship to Classical Software Engineering

Genesis mirrors well-engineered human software organizations. The Context Tree represents the team hierarchy: a tech lead defines the architecture (summaries) and delegates modules to senior engineers, who further decompose and delegate to junior engineers (executors). The Phylogenetic Graph represents version control. The fixed-point framework captures the engineering intuition that a project is "done" only when the implementation matches the specification at every level.

### 7.2 Scalability Properties

* **Depth independence:** Deepening the Context Tree does not increase any single agent's cognitive load.
* **Breadth parallelism:** Sibling modules evolve concurrently.
* **Incremental progress:** There is no "all or nothing" threshold. Because every verified step moves up the poset, every node in the temporal DAG represents a deployable, stable state.

---

## References

1. Garcez, A. d'Avila, & Lamb, L. C. (2020). *Neurosymbolic AI: The 3rd Wave*. Artificial Intelligence Review, 56(1), 1-20.
2. Yao, S., Zhao, J., Yu, D., Du, N., Shafran, I., Narasimhan, K., & Cao, Y. (2022). *ReAct: Synergizing Reasoning and Acting in Language Models*. arXiv preprint arXiv:2210.03629.
3. Jimenez, C. E., et al. (2023). *SWE-bench: Can Language Models Resolve Real-World GitHub Issues?* arXiv preprint arXiv:2310.06770.
4. Cousot, P., & Cousot, R. (1977). *Abstract Interpretation: A Unified Lattice Model for Static Analysis of Programs by Construction or Approximation of Fixpoints*. POPL '77.