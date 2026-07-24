# Genesis: From AI Vibe Coding to Autonomous Software Evolution

## Abstract

Current AI coding tools — from Copilot to Devin — demonstrate remarkable code generation capabilities through ReAct-style agent loops. Yet they remain limited by shallow symbolic scaffolds: flat context windows, no hierarchical abstraction, and no convergence guarantees. Genesis is a neuro-symbolic framework that addresses these limitations through recursive hierarchical decomposition. It marries the pattern-recognition capabilities of large language models (the *neuro* component) with a principled evolutionary architecture grounded in fixed-point theory (the *symbolic* component). The system models a codebase along two orthogonal dimensions — a **spatial** Context Tree capturing hierarchical structure and a **temporal** phylogenetic DAG capturing evolutionary history. Through the iterative application of a *summary–code fixed-point operator*, Genesis guarantees that every level of the codebase reaches semantic convergence: each module's implementation faithfully realizes its declared intent, and each summary accurately reflects its implementation. This paper presents the framework's mathematical foundation, architectural design, and implementation, showing how the recursive application of a simple fixed-point principle yields a system capable of autonomously building and refining arbitrarily complex software.

---
## 1. Philosophy: The Neuro-Symbolic Design

The current AI-assisted programming landscape is rich and evolving rapidly. Tools like GitHub Copilot, Cursor, Cline, Aider, Devin (Cognition AI), and research systems like SWE-agent have moved far beyond simple "prompt → code" generation. The newest entrants — Claude Code (Anthropic, launched 2025), an agentic coding CLI built into the Claude ecosystem, and Codex CLI (OpenAI, launched 2025), a terminal-based coding agent — push the frontier further still, with polished tool orchestration and deep editor integration. Yet, despite their recency and increasing sophistication, all of these tools share the same fundamental architecture. They integrate deeply with developer workflows: file systems, LSP-based code intelligence, terminal access, browser automation, Git history, and structured tool protocols like Anthropic's Model Context Protocol (MCP) (Anthropic, 2024). The ReAct loop (Yao et al., 2023) — reason, act, observe, repeat — is the de facto architecture: the LLM reasons about the task, invokes tools (read file, run test, search code), observes the results, and iterates. This is "vibe coding" in practice (Karpathy, 2025): describing intent in natural language and watching the AI manifest code. On benchmarks like SWE-bench (Jimenez et al., 2024), state-of-the-art systems now resolve a significant fraction of real-world GitHub issues.

It is critical to distinguish between *tool-level* improvements and *structural* ones. Language servers (LSP), MCP, browser automation, terminal access — these are all tool-level improvements. They give the agent better eyes and hands: go-to-definition, find-references, run commands, browse documentation. They make the agent more capable at *interacting* with a codebase, but they do not change the *architectural structure* of the agent loop itself. The ReAct loop is still a flat iteration regardless of how many sophisticated tools it has access to. Tool quality is not structural understanding. What is missing from all of these systems is a *symbolic model of the codebase itself* — hierarchical decomposition into modules and submodules, explicit interface contracts between components, formal dependency constraints, and convergence guarantees that the system is making measurable progress toward a well-defined goal. These are system-level, architectural concerns, not tool-level concerns. A tool can tell you where a function is defined or what tests exist; a structure can tell you that editing this module requires satisfying invariants at every dependent call site, that this subtree inherits constraints from its ancestors, and that the current state is measurably closer to or farther from a well-defined target. No amount of tooling provides this — it requires an explicit, persistent symbolic representation of the codebase's architecture.

The benchmarks used to evaluate these tools, however, reflect a narrow conception of software engineering. Standard benchmarks like HumanEval (Chen et al., 2021) and MBPP (Austin et al., 2021) measure the ability to generate isolated functions from docstrings — typically 5–20 lines of self-contained Python. SWE-bench (Jimenez et al., 2024) raises the bar by testing whether a system can resolve real GitHub issues, but even this frames programming as a single-patch activity: locate the right file, make a targeted edit, pass the existing test suite. Missing from the evaluation landscape is any standardized benchmark for *project-level generation* — the task of creating an entire multi-file, multi-module codebase from a natural language specification. Individual researchers and developers have conducted informal, small-scale comparisons of LLMs on project-generation tasks (e.g., asking different models to build the same application from scratch and comparing build correctness, code organization, and architectural coherence), but these experiments remain ad hoc, unstandardized, and absent from the mainstream evaluation canon. The field lacks a rigorous, widely adopted benchmark for the kind of end-to-end software synthesis that Genesis targets.

But beneath the sophistication of these tools lies a surprisingly simple loop. The ReAct pattern — however augmented with better tools, better prompts, or better models — is fundamentally a flat, memoryless iteration: (1) serialize state into a prompt, (2) ask the LLM what to do, (3) execute the chosen tool, (4) repeat. MCP and LSP, for all their utility, are tool-layer improvements, not structural ones. They make tools more interoperable (MCP standardizes how tools are described and invoked) and code intelligence more precise (LSP provides go-to-definition, find-references, diagnostics), but the loop itself — serialize state → prompt LLM → execute tool → repeat — remains unchanged. Valmeekam et al. (2023) demonstrated through the PlanBench benchmark that LLMs — including GPT-4 — achieve only ~35% accuracy on complex planning tasks, with performance collapsing as plan length and constraint density increase. This directly undermines the assumption that a flat ReAct loop can reliably orchestrate large-scale software engineering. The agent still has no persistent hierarchical model of the codebase. Claude Code, Codex CLI, and similar products add genuine polish: better system prompts, richer tool palettes, more refined UX. But they do not escape the flat ReAct paradigm. They are sophisticated tool orchestrators, not neuro-symbolic architectures. There is no deep symbolic model of the codebase being modified. The "state" is whatever fits in the context window. There is no persistent hierarchical understanding — the agent doesn't know that `src/auth/oauth/` is a child of `src/auth/` with inherited constraints. There is no mathematical notion of progress or convergence — the agent just keeps looping until it runs out of budget or declares success. When it fails, it fails silently, often producing plausible-looking but incorrect code. The symbolic layer in these tools is shallow: a tool dispatcher, a file system, and a Git wrapper.

The distinction matters. A tool can answer "what file defines function X?" (LSP) or "what tests exercise this module?" (terminal + grep), but a structure can answer "module Y depends on module Z via interface I, and editing Z requires satisfying contract C at every call site in Y." A tool can tell you that a file exists; a structure can tell you that this file lives in a subtree that inherits constraints from its ancestors, that it exposes a specific API to its siblings, and that modifying it may violate invariants declared three levels up in the hierarchy. No amount of tooling gives you the latter — it requires an explicit symbolic representation of the codebase's architecture: interfaces, dependencies, constraints, and the rules that govern how they compose. There is no structural verification, no fixed-point check, no guarantee that the implementation matches the intent.

This shallow symbolic scaffold makes current tools brittle for autonomous, large-scale software engineering:

1. **The Context Window Bottleneck (Reframed):** Current tools pack all relevant state into a flat context window. As the codebase grows, the agent must either omit critical context (losing awareness of distant dependencies and architectural constraints) or exceed the window. The ReAct loop has no mechanism for hierarchical abstraction — every detail competes for attention at the same level.

   This bottleneck is not merely about the raw token limit — it is a compound problem spanning model capability, economic cost, and structural degradation:

   **Performance degradation under long contexts.** Although newer models advertise context windows of 128K, 200K, or even 1M tokens, empirical studies show that model performance degrades significantly as input length grows. Liu et al. (2024) demonstrated in their "Lost in the Middle" study that LLMs struggle to attend to information positioned in the middle of long inputs — retrieval accuracy drops substantially when relevant facts are located away from the beginning or end of the context. The "needle-in-a-haystack" pressure test (Kamradt, 2023) reveals that even state-of-the-art models miss key details buried within large contexts: a single fact injected into a 100K-token document may go entirely unnoticed by the model. In software engineering, this means that as a codebase grows beyond a few thousand lines, the model's effective recall of architectural constraints, type signatures, and cross-module dependencies deteriorates — even if those details are technically within the context window. The model may "see" every line of code yet fail to synthesize them into a coherent understanding of the system. Hsieh et al. (2024) reinforced these findings with RULER, a synthetic benchmark demonstrating that even models advertising 128K+ context windows exhibit sharp accuracy declines beyond 8K–32K tokens in retrieval and multi-hop reasoning tasks. Levy et al. (2024) showed that long contexts disproportionately degrade performance on tasks requiring fine-grained cross-reference across distant passages — precisely the scenario faced by coding agents tracking type definitions, imports, and call sites scattered across a large project.

   **Economic cost of long contexts.** The transformer architecture's self-attention mechanism (Vaswani et al., 2017) means that each generated token must attend to every input token — the computational cost of producing output scales directly with the length of the input. Tay et al. (2022) surveyed the landscape of efficient transformer variants, cataloging dozens of approaches — sparse attention, linear attention, kernel methods, recurrence — all attempting to mitigate this fundamental quadratic complexity. Yet none eliminate it entirely; the trade-off between context fidelity and computational cost remains an open problem. This is reflected in how API providers bill: per input token and per output token. A longer prompt costs more not only because you are sending more data, but because generating each output token becomes more expensive when the model must attend to a larger context. Even with caching optimizations — providers like OpenAI and Anthropic offer discounted "cached input" pricing for repeated prompt prefixes — the fundamental scaling remains: longer context is never free, it comes with additional cost at every generation step. A single ReAct loop iteration over a modest project of 50,000 lines can consume hundreds of thousands of input tokens once file contents, tool outputs, and conversation history are serialized. Over dozens or hundreds of iterations, the cost becomes prohibitive for sustained autonomous development. The economic pressure to truncate context directly conflicts with the need for comprehensive codebase awareness.

   **Structural flattening.** Writing a software project is not merely about generating correct code — it is about organizing that code into a coherent, maintainable structure: modules, interfaces, separation of concerns, dependency direction, and architectural invariants. In a flat ReAct loop, code, tool-call outputs, error messages, file paths, conversation history, and structural metadata are all serialized into a single undifferentiated token stream. There is no explicit representation of the project's hierarchical structure, no principled separation between *what* a module does (its interface) and *how* it does it (its implementation), and no mechanism to enforce that local edits preserve global invariants. The model must implicitly reconstruct the project's architecture from a flattened text dump on every iteration — a task that becomes combinatorially harder as the project grows. The result is code that may pass unit tests but suffers from architectural decay: duplicated logic, broken abstractions, circular dependencies, and inconsistent conventions that accumulate silently across iterations.

2. **Error Compounding Without Convergence:** Without a mathematical notion of progress, errors compound. A hallucinated API call or a type mismatch breaks the build. In a flat ReAct loop, there is no structural guarantee that the system moves toward correctness — it just keeps sampling and hoping. The agent may fix one bug while introducing two more, with no way to verify that the overall state is improving. Zhang et al. (2023) surveyed hallucination in large language models and found that even state-of-the-art systems generate factually incorrect content 15–25% of the time across various benchmarks — a rate that, when compounded across dozens of interdependent code edits in a flat ReAct loop, virtually guarantees eventual divergence.

Genesis addresses this by taking the neuro-symbolic architecture seriously — building a *deep* symbolic scaffold rather than a shallow one. Marcus (2020) argued for neuro-symbolic integration as the path to robust AI, identifying compositionality, systematicity, and causal reasoning as capabilities that purely neural systems cannot acquire from data alone. Like current tools, it uses LLMs as the "neuro" component for pattern recognition, code generation, and natural language understanding. But unlike them, it embeds this within a principled symbolic framework (Hitzler & Sarker, 2022). The neuro-symbolic concept learner (Mao et al., 2019) demonstrated that combining neural perception with symbolic program execution yields stronger generalization than either component alone — a principle that Genesis extends from visual reasoning to software architecture.

- **Hierarchical decomposition (the Context Tree):** The codebase is organized as a rooted tree where each node carries a CONTEXT.md — a formal summary declaring intent, API surface, and constraints. Parent agents do not read child code; they read child summaries. This is hierarchical abstraction: each level only needs to know what its children *promise* to do, not how they do it. No flat context window can match this.

- **Temporal evolution with convergence guarantees:** The Phylogenetic Graph (Git DAG) models evolution. Each commit is a measurable improvement over its parent. The system iterates toward a fixed point where the implementation matches the specification at every level — a mathematical notion of "done" that flat ReAct loops lack.

- **Persistent spatial and temporal memory:** Memory lives in the Context Tree (spatial) and Git history (temporal) — not in a volatile context window. Agents are stateless functions that read from and write to these persistent structures.

- **Deterministic symbolic verification:** The runtime enforces invariants deterministically — spatial authority (agents can only write within their assigned node), tool budgets, sandboxing. The symbolic layer doesn't just dispatch tools; it *governs* the entire process.

The rest of this paper formalizes this architecture: the fixed-point mathematics (Section 2), the spatial and temporal dimensions (Section 3), the agent delegation model (Sections 4–5), and the implementation (Section 6).

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

This formulation draws on the foundational fixed-point theory established by Tarski (1955), who proved that every monotone function on a complete lattice has a complete lattice of fixed points — a result that underpins the semantics of recursive definitions across computer science. Cousot & Cousot (1977) applied this fixed-point framework to program analysis through abstract interpretation, showing how concrete program semantics can be systematically approximated by abstract domains — a conceptual precursor to the summary–code abstraction at the heart of Genesis.

### 2.2 The Iterative Convergence Process

The fixed-point equation $c = \Gamma(\Sigma(c))$ is not directly solvable — we cannot compute $\Gamma(\Sigma(c))$ in one step for a nontrivial codebase because $\Gamma$ itself is intractable. We therefore introduce time and iterate:

$$c_{t+1} = \Gamma(\Sigma(c_t))$$

Starting from an initial codebase $c_0$, we repeatedly: (1) extract the summary of the current codebase, (2) regenerate the codebase from that summary, and (3) check whether anything changed. The process converges when $c_{t+1} = c_t$.

### 2.3 Spatial Decomposition: The Hierarchical Fixed Point

The fixed-point property can be enforced **hierarchically**. A codebase is a set of modules $\{m_1, m_2, \ldots, m_n\}$ organized in a tree $\mathcal{T}$. Each module $m_i$ has a **local summary** $s_i$, a **local implementation** $b_i$, and a **decomposition** into child modules $\{m_j : j \in \text{children}(i)\}$.

Simon (1962) identified hierarchical decomposition as a universal principle of complex systems, arguing that hierarchy is not merely an organizational convenience but a fundamental strategy for managing complexity — systems organized hierarchically evolve faster and adapt more readily than non-hierarchical systems of comparable scale.

For a module $m_i$, define:

* **Local summary operator** $\sigma_i$: given $b_i$ and child summaries $\{s_j\}_{j \in \text{children}(i)}$, produce a summary $s_i$.
* **Local code operator** $\gamma_i$: given $s_i$, produce $b_i$ and delegate child summaries $\{s_j\}$ to child modules.

The hierarchical fixed point requires, for every module $i$:

$$(b_i, \{s_j\}) = \gamma_i(\sigma_i(b_i, \{s_j\}))$$

Every module is self-consistent *given* the summaries of its children. This is a recursive fixed point: the root delegates to children, children delegate to grandchildren, down to the leaves.

This recursive construction is grounded in Kleene's first recursion theorem (Kleene, 1952), which provides the classical semantics for recursive definitions via least fixed points in complete partial orders. Scott (1976) developed domain theory — the mathematical framework of complete partial orders and continuous functions — which provides the formal underpinning for reasoning about convergence and approximation in hierarchical systems like Genesis.

### 2.4 Spatiotemporal Dynamics

Let $m_i^{(t)}$ denote module $i$ at time $t$. The evolution of module $i$ is governed by:

$$(b_i^{(t+1)}, \{s_j^{(t+1)}\}_{j \in \text{children}(i)}) = \gamma_i\left(\sigma_i\left(b_i^{(t)}, \{s_j^{(t)}\}_{j \in \text{children}(i)}\right)\right)$$

This is analogous to the Bellman equation (Bellman, 1957). The correctness of a module depends on the correctness of its children. Every point in the iteration $(c_t)$ is a valid, potentially deployable state, modeling the *partial progress acceptance* principle.

### 2.5 Partial Order and Convergence Guarantees

To rigorously define "progress," we must establish a way to compare codebases. However, it is mathematically and practically meaningless to compare two entirely unrelated codebases (e.g., comparing the Chrome repository to the Linux kernel).

Therefore, we restrict our comparison to "similar" codebases. We define $\mathcal{C}$ as a **partially ordered set (poset)** equipped with a relation $\preceq$. We declare that $c_1 \preceq c_2$ (meaning $c_2$ is greater than or equal to $c_1$ in quality/completeness) **if and only if** $c_2$ is exactly one evolutionary step (one Git commit) away from $c_1$ and represents a measurable improvement (e.g., passing tests, fulfilling a missing sub-summary).

The poset framework for program semantics is standard in the abstract interpretation literature (Nielson et al., 1999), where partial orders capture the relative precision of program analyses and Galois connections formalize the relationship between concrete and abstract domains.

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

The codebase is a rooted tree $\mathcal{T} = (V, E)$ where nodes are directories containing a `CONTEXT.md` file. The `CONTEXT.md` contains the module's Intent, API Surface, Constraints, and a Routing Table mapping concerns to child subdirectories. Parent agents do not read child code; they read child summaries. This is the principle of information hiding elevated to an architectural mandate — a direct extension of Parnas (1972), who established that modules should encapsulate design decisions likely to change, exposing only their interfaces to the rest of the system.

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

The actor model, first proposed by Hewitt et al. (1973) and later developed into a complete theory of concurrent computation by Agha (1986), provides the foundation for this architecture: independent computational agents communicate exclusively through asynchronous message passing, with no shared mutable state — the same isolation principle that Genesis applies at the architectural level through Git worktrees.

```text
EvoGit.AgentGroupSupervisor (one_for_all)
├── Task.Supervisor         — Agent Task supervisor (spawns/kills agents)
└── EvoGit.AgentScheduler   — The central GenServer orchestrator

```

If an agent process crashes (e.g., unparseable LLM output), the `Task.Supervisor` kills it. The `AgentScheduler` detects the `DOWN` message, safely releases the agent's slots and worktree, and queues it for a retry from its last safe Git commit.

Armstrong (2003) codified the "let it crash" philosophy underlying Erlang's supervision trees: instead of defensive programming that anticipates and handles every possible failure, build systems where isolated processes are supervised by parent processes that detect failures and restart components from known-good states. Genesis adopts this philosophy directly — when an agent process crashes due to unparseable LLM output, the supervisor kills it and the scheduler resurrects it from its last safe Git commit.

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

Genesis mirrors well-engineered human software organizations. This alignment is not merely metaphorical. Conway (1968) famously observed that the structure of a software system reflects the communication structure of the organization that built it — "organizations which design systems are constrained to produce designs which are copies of the communication structures of these organizations." Genesis inverts this principle: by designing the organizational structure first (through the Context Tree hierarchy), the system ensures that the resulting software architecture mirrors a well-designed communication topology. The Context Tree represents the team hierarchy: a tech lead defines the architecture (summaries) and delegates modules to senior engineers, who further decompose and delegate to junior engineers (executors). The Phylogenetic Graph represents version control. The fixed-point framework captures the engineering intuition that a project is "done" only when the implementation matches the specification at every level. Parnas (1972) established that the criterion for decomposing a system into modules should be the encapsulation of design decisions likely to change. Genesis operationalizes this principle: each module's CONTEXT.md declares its stable interface (the summary) while isolating the volatile implementation details within the module boundary — a direct realization of Parnas's information-hiding principle at the architectural level.

### 7.2 Scalability Properties

* **Depth independence:** Deepening the Context Tree does not increase any single agent's cognitive load.
* **Breadth parallelism:** Sibling modules evolve concurrently.
* **Incremental progress:** There is no "all or nothing" threshold. Because every verified step moves up the poset, every node in the temporal DAG represents a deployable, stable state.

---
## References

1. d'Avila Garcez, A., & Lamb, L. C. (2023). Neurosymbolic AI: The 3rd Wave. *Artificial Intelligence Review*, 56(11), 12387–12406.

2. Yao, S., Zhao, J., Yu, D., Du, N., Shafran, I., Narasimhan, K., & Cao, Y. (2023). ReAct: Synergizing Reasoning and Acting in Language Models. *Proceedings of the Eleventh International Conference on Learning Representations (ICLR)*.

3. Jimenez, C. E., Yang, J., Wettig, A., Yao, S., Pei, K., Press, O., & Narasimhan, K. (2024). SWE-bench: Can Language Models Resolve Real-World GitHub Issues? *Proceedings of the Twelfth International Conference on Learning Representations (ICLR)*.

4. Cousot, P., & Cousot, R. (1977). Abstract Interpretation: A Unified Lattice Model for Static Analysis of Programs by Construction or Approximation of Fixpoints. *Proceedings of the 4th ACM SIGACT-SIGPLAN Symposium on Principles of Programming Languages (POPL '77)*, 238–252.

5. Wei, J., Wang, X., Schuurmans, D., Bosma, M., Ichter, B., Xia, F., Chi, E. H., Le, Q. V., & Zhou, D. (2022). Chain-of-Thought Prompting Elicits Reasoning in Large Language Models. *Advances in Neural Information Processing Systems 35 (NeurIPS)*.

6. Yang, J., Jimenez, C. E., Wettig, A., Lieret, K., Yao, S., Narasimhan, K., & Press, O. (2024). SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering. *Advances in Neural Information Processing Systems 37 (NeurIPS)*.

7. Vaswani, A., Shazeer, N., Parmar, N., Uszkoreit, J., Jones, L., Gomez, A. N., Kaiser, Ł., & Polosukhin, I. (2017). Attention Is All You Need. *Advances in Neural Information Processing Systems 30 (NeurIPS)*.

8. Liu, N. F., Lin, K., Hewitt, J., Paranjape, A., Bevilacqua, M., Petroni, F., & Liang, P. (2024). Lost in the Middle: How Language Models Use Long Contexts. *Transactions of the Association for Computational Linguistics (TACL)*, 12, 1571–1593.

9. Chen, M., Tworek, J., Jun, H., Yuan, Q., Pinto, H. P. d. O., Kaplan, J., Edwards, H., Burda, Y., Joseph, N., Brockman, G., et al. (2021). Evaluating Large Language Models Trained on Code. *arXiv preprint arXiv:2107.03374*.

10. Austin, J., Odena, A., Nye, M., Bosma, M., Michalewski, H., Dohan, D., Jiang, E., Cai, C., Terry, M., Le, Q., & Sutton, C. (2021). Program Synthesis with Large Language Models. *arXiv preprint arXiv:2108.07732*.

11. Kamradt, G. (2023). Needle In A Haystack — Pressure Testing LLMs. *GitHub repository*. https://github.com/gkamradt/LLMTest_NeedleInAHaystack

12. Karpathy, A. (2025). Vibe Coding. *X/Twitter post*.

13. Anthropic. (2024). Model Context Protocol Specification. https://modelcontextprotocol.io/

14. Valmeekam, K., Olmo, A., Sreedharan, S., & Kambhampati, S. (2023). On the Planning Abilities of Large Language Models: A Critical Investigation. *Advances in Neural Information Processing Systems 36 (NeurIPS)*.

15. Hsieh, C.-P., Sun, S., Kriman, S., Acharya, S., Rekesh, D., Jia, F., & Ginsburg, B. (2024). RULER: What's the Real Context Size of Your Long-Context Language Models? *Proceedings of the 2024 Conference on Empirical Methods in Natural Language Processing (EMNLP)*.

16. Levy, M., Jacoby, A., & Goldberg, Y. (2024). Same Task, More Tokens: The Impact of Input Length on the Reasoning Performance of Large Language Models. *Findings of the Association for Computational Linguistics: ACL 2024*.

17. Tay, Y., Dehghani, M., Bahri, D., & Metzler, D. (2022). Efficient Transformers: A Survey. *ACM Computing Surveys*, 55(6), 1–28.

18. Zhang, Y., Li, Y., Cui, L., Cai, D., Liu, L., Fu, T., Huang, X., Zhao, E., Zhang, Y., Chen, Y., et al. (2023). Siren's Song in the AI Ocean: A Survey on Hallucination in Large Language Models. *arXiv preprint arXiv:2309.01219*.

19. Marcus, G. (2020). The Next Decade in AI: Four Steps Towards Robust Artificial Intelligence. *arXiv preprint arXiv:2002.06177*.

20. Hitzler, P., & Sarker, M. K. (Eds.). (2022). Neuro-Symbolic Artificial Intelligence: The State of the Art. *IOS Press*.

21. Mao, J., Gan, C., Kohli, P., Tenenbaum, J. B., & Wu, J. (2019). The Neuro-Symbolic Concept Learner: Interpreting Scenes, Words, and Sentences From Natural Supervision. *Proceedings of the International Conference on Learning Representations (ICLR)*.

22. Tarski, A. (1955). A Lattice-Theoretical Fixpoint Theorem and Its Applications. *Pacific Journal of Mathematics*, 5(2), 285–309.

23. Simon, H. A. (1962). The Architecture of Complexity. *Proceedings of the American Philosophical Society*, 106(6), 467–482.

24. Kleene, S. C. (1952). Introduction to Metamathematics. *D. Van Nostrand Company*.

25. Scott, D. (1976). Data Types as Lattices. *SIAM Journal on Computing*, 5(3), 522–587.

26. Bellman, R. (1957). Dynamic Programming. *Princeton University Press*.

27. Nielson, F., Nielson, H. R., & Hankin, C. (1999). Principles of Program Analysis. *Springer*.

28. Parnas, D. L. (1972). On the Criteria To Be Used in Decomposing Systems into Modules. *Communications of the ACM*, 15(12), 1053–1058.

29. Conway, M. E. (1968). How Do Committees Invent? *Datamation*, 14(4), 28–31.

30. Hewitt, C., Bishop, P., & Steiger, R. (1973). A Universal Modular ACTOR Formalism for Artificial Intelligence. *Proceedings of the 3rd International Joint Conference on Artificial Intelligence (IJCAI '73)*, 235–245.

31. Agha, G. (1986). Actors: A Model of Concurrent Computation in Distributed Systems. *MIT Press*.

32. Armstrong, J. (2003). Making Reliable Distributed Systems in the Presence of Software Errors. *PhD Thesis, Royal Institute of Technology (KTH), Stockholm*.
