# EvoX Genesis: From AI vibe coding to Autonomous Software Evolution

--- ENGLISH VERSION ---

## Abstract

The rise of **"vibe coding"** — free-flowing, AI-assisted development powered by Large Language Models (LLMs) — has democratized software creation but inherits fundamental structural limitations: a hard scalability ceiling imposed by monolithic context windows, architectural blindness from flat-file perception, unconstrained editing scope, fragile session state, and single-path linear execution. As codebases grow beyond what a single conversation can hold, these limitations cause vibe coding to degrade from a productivity multiplier into an unreliable crutch.

EvoX Genesis is a decentralized, evolutionary software development framework designed to transcend these limitations. The system introduces a **Dual-Dimension Architecture** that intersects a *Spatial Dimension* — a hierarchical Context Tree providing semantic structural awareness — with a *Temporal Dimension* — a phylogenetic Directed Acyclic Graph (DAG) of immutable Git commits tracking evolutionary history. Within this framework, **transient agents** serve as pure transformation functions over `{commit, node_path} × objective → new_commit`, recursively decomposing tasks along the Context Tree to achieve unbounded scalability without context window exhaustion. The system supports two execution phases — *Genesis* (bootstrapping) and *Evolution* (iterative modification) — with Evolution further divided into *Simple* (top-down planning) and *Complex* (bottom-up novelty search with quality diversity) modes. This report presents the Genesis system's design philosophy, architectural principles, agent taxonomy, runtime mechanics, and situates it within the broader landscape of evolutionary computation and autonomous coding agents.

## 1. Introduction

### 1.1 The Rise and Limits of Vibe Coding

The widespread adoption of LLM-powered coding tools has given rise to **"vibe coding"** — a development practice where programmers interact with AI assistants in a free-flowing, conversational manner, accepting generated code based on whether it "feels right" rather than rigorously verifying every detail. Tools like Cursor, GitHub Copilot Workspace, Aider, and Claude Code have made this style of development accessible to millions, dramatically lowering the barrier to producing functional code. For small-scale projects and rapid prototyping, vibe coding is transformative.

However, as projects grow in size and complexity, vibe coding inherits and amplifies several fundamental limitations rooted in its underlying tool architecture:

**Problem 1: The Context Wall.** Traditional coding agents operate as monolithic, stateful processes that must load relevant codebase context into a single conversation window. As codebases grow, the agent faces an inexorable dilemma: either include more context (risking window exhaustion) or include less (missing critical dependencies). This creates a hard scalability ceiling — beyond a certain project size, the agent's understanding degrades, and its ability to make architecturally coherent changes collapses.

**Problem 2: Architectural Blindness.** Vibe coding tools perceive the codebase as a flat collection of files. Structure is discovered through exploration (grepping, reading files), which is both expensive — consuming precious context window capacity — and inherently incomplete. An agent has no inherited awareness of the system's architecture; it must reconstruct the big picture from scratch in every session, and it does so imperfectly.

**Problem 3: Unconstrained Editing Scope.** An agent asked to fix a bug in one module can freely modify any other module it deems relevant. There is no enforcement of architectural boundaries — the agent's edit scope is bounded only by its own judgment, which may be flawed, especially when operating with incomplete context (see Problem 2). This leads to architectural violations, unintended side effects, and tangled, low-cohesion codebases.

**Problem 4: Fragile Session State.** The agent's "memory" is its conversation history, which grows monotonically and can never be reset without losing context. If the session crashes, is interrupted, or becomes too long to manage, work may be lost. There is no principled recovery mechanism — the entire session must be restarted from scratch, with no guarantee of reproducing prior progress.

**Problem 5: Single-Path Execution.** Vibe coding follows a strictly linear trajectory: make changes → review → repeat. There is no mechanism to explore multiple alternative approaches in parallel, or to branch from a historical state to try a different strategy when the current path stalls. The developer is locked into a single line of evolution.

These problems are not merely inconveniences — they represent structural limitations that prevent vibe coding from scaling to the autonomous, large-scale software development that real-world projects demand.

### 1.2 How Genesis Solves These Problems

EvoX Genesis was designed from the ground up as a direct response to each of these limitations. The following table maps each vibe coding problem to the specific Genesis mechanism that resolves it:

| Vibe Coding Problem | Genesis Solution | Key Mechanism |
|---------------------|------------------|---------------|
| **Context Wall** (Problem 1) | Recursive decomposition with context isolation | Transient agents delegate to subagents at child nodes; each subagent's context footprint does not count against the parent's limits (§3.3) |
| **Architectural Blindness** (Problem 2) | Inherited spatial context via the Context Tree | Every agent inherits the architectural contract chain — Intent, API Surface, Routing Table — from root down to its assigned node (§2.1) |
| **Unconstrained Scope** (Problem 3) | Spatial contract enforcement | Agents can only modify files within their assigned node and its descendants; write permissions are hierarchically scoped and cannot be escalated (§3.4) |
| **Fragile Session State** (Problem 4) | Transient agents + Git-backed persistence | Agent state is fully captured by `{node_path, base_commit, current_commit}`; any crash is recovered by re-dispatching from the last commit (§3.1) |
| **Single-Path Execution** (Problem 5) | Phylogenetic DAG + worktree isolation | Agents branch from specific commits and explore independently in isolated worktrees; successful branches are selectively merged (§2.2, §5.1) |

This problem-to-solution correspondence is not incidental — each Genesis mechanism was designed as a principled response to a specific structural failure mode of the vibe coding paradigm. The remainder of this paper elaborates on each of these mechanisms in detail.

### 1.3 Design Principles

Genesis is founded on three core principles:

1. **Structural Awareness over Flat Files:** The codebase is not a flat collection of files but a hierarchical tree of semantic nodes, each carrying explicit architectural contracts. Agents navigate this tree spatially, always operating within a well-defined scope.

2. **Transient Agents over Stateful Sessions:** Agents are ephemeral, session-scoped functions with no persistent state. All persistent knowledge resides in the spatial dimension (Context Tree) or temporal dimension (Git history). This eliminates state corruption, enables trivial parallelization, and allows any agent to be instantiated at any point in the codebase's evolutionary history.

3. **Evolutionary Progress over Green Builds:** The system accepts partial progress — a version that implements one more feature or passes one more test is valued, even if other parts remain broken. This mirrors natural selection's gradual, directional improvement and enables rapid exploration of the solution space.

---

## 2. The Dual-Dimension Architecture

The central innovation of Genesis is the intersection of two orthogonal dimensions — spatial and temporal — that together provide complete state specification for any agent at any point in the codebase's lifetime.

### 2.1 The Spatial Dimension: The Context Tree

The Spatial Dimension models the codebase as a **Context Tree** — a recursive, hierarchical structure where every node represents a directory or file. The key innovation is the **Spatial Contract**: every directory node contains a `CONTEXT.md` file that serves as the directory's intrinsic attribute (conceptually similar to an extended file attribute), defining:

1. **Documentation:**
   - *Intent* — the directory's purpose and role in the system
   - *API Surface* — what modules, functions, and interfaces it exposes
   - *Constraints* — rules and guidelines for code within this directory

2. **Routing Table** — a mapping of responsibility areas to child subdirectories, enabling parent agents to delegate work to the correct child node without investigating the subtree's internals.

**Contextual Inheritance** flows top-down. An agent assigned to `src/auth/oauth/` builds its world view by aggregating the explicit context from Root → `src/` → `src/auth/` → `src/auth/oauth/`. This inherited context provides architectural coherence without requiring each agent to re-derive the entire system structure.

The formal Context Hierarchy applies down to the **directory level**. Once an agent targets a specific file, it relies on the LLM's natural code comprehension to navigate internal logic (docstrings, comments, code structure). This design decision reflects the observation that modern LLMs natively excel at file-level comprehension, making explicit sub-file modeling unnecessary.

### 2.1.1 Token Efficiency via Prefix-Tree Structure

The hierarchical context inheritance means that an agent's world view is built by concatenating ancestor CONTEXT.md files from the root down to its assigned node. Critically, because all agents within a subtree share the same set of ancestor nodes, this concatenation forms a **prefix tree (trie) of context**. When a parent agent delegates to multiple child agents, or when sequential agents work within the same subtree, the shared ancestor context tokens are already present in the LLM's Key-Value (KV) cache — they do not need to be recomputed.

This is a deliberate structural alignment between the Context Tree's hierarchy and how transformer attention caching works: the tree structure mirrors the cache locality of the underlying inference engine. The deeper the tree, the more prefix is reused across agents operating in that subtree. When a parent agent delegates to several children, each child's prompt begins with the same ancestor prefix that the parent has already processed, so the KV cache entries for those tokens are reused directly. This turns what would be O(n²) redundant attention computation for repeated context into near-O(1) for the shared prefix, making inference dramatically cheaper and faster as the system scales.

### 2.1.2 The Routing Table as a Delegation Compass

The routing table is not mere documentation — it is the mechanism that enables **precise delegation**. A parent agent, by reading its CONTEXT.md routing table, knows exactly which child node owns which functional area. When it receives an objective, it can route each subtask to the correct child node with high precision, without needing to investigate the subtree's internals or understand how the child is implemented.

This eliminates the expensive and error-prone exploration that traditional agents must perform — grepping through directories, reading files to discover structure, and inferring responsibility boundaries from code. The routing table effectively makes each parent agent an informed dispatcher: it knows the system's decomposition at a glance. This also means delegation errors are minimized. An agent does not accidentally send database work to the authentication subsystem, because the routing table explicitly maps "database" to the correct child node. The routing table thus transforms delegation from a fuzzy, exploratory process into a deterministic lookup.

### 2.1.3 Accumulated Wisdom: Context as Inherited Experience

The Context Tree is not just static architecture documentation — it is a living repository of **accumulated wisdom**. Every agent that works at a node can record what it learned: a tricky constraint discovered during implementation, an important trap that caused a bug, a design decision and its rationale, a performance gotcha. These are recorded in the CONTEXT.md's Constraints and Intent sections, persisting beyond the agent's transient session.

Future agents working at the same node inherit this wisdom immediately — they start their work already knowing the important traps and design decisions, without having to rediscover them through trial and error. This creates a **self-improving** property: the system gets smarter over time because every agent's hard-won insights are persisted and inherited. An agent working in a mature subtree benefits from the collective experience of all agents that came before. The cost of learning a lesson is paid once, by the first agent that encounters it, and that lesson is then available to every subsequent agent at no additional cost.

### 2.1.4 The Self-Evolving Context Tree

The above properties converge on the deepest insight: the Context Tree is genuinely **self-evolving**. The hierarchical context is not passive documentation — it is effectively **part of the agent's behavior specification**. Agents read CONTEXT.md to know how to behave: what constraints to follow, what the intent is, where to route work. But agents also **update** CONTEXT.md as they work: when they discover a new constraint, resolve a trap, change an API, or learn a better way to do something, they persist this new knowledge into the context.

This creates a feedback loop: the context shapes agent behavior, and agent behavior shapes the context. Over time, the Context Tree evolves — not just the code, but the knowledge that guides code creation. This is analogous to **epigenetic inheritance** in biology: beyond the static genome (the initial architecture), there is a dynamic layer of inherited modifications that accumulates through lived experience and shapes how genes are expressed. The Context Tree is both genotype (structural contract) and this epigenetic memory. This is the deepest sense in which the system is "self-evolving": the very knowledge that governs agent behavior is itself a living, growing artifact that improves through use.

### 2.2 The Temporal Dimension: The Phylogenetic Graph

The Temporal Dimension models code evolution as a **Phylogenetic Graph** — a Directed Acyclic Graph (DAG) of immutable Git commits. The biological metaphor is deliberate: each commit is an organism in an evolutionary lineage, with parent-child relationships representing ancestry.

Key properties of the temporal dimension:

- **Directional Evolution ($v_{new} > v_{old}$):** A child commit is accepted only if it is measurably "better" than its parent. This is enforced by evaluation at each merge point.
- **Partial Progress Acceptance:** Unlike traditional CI/CD pipelines requiring a fully passing build, Genesis accepts incremental improvements. A version that passes more tests, implements a feature, or improves readability is accepted — even if other system parts remain broken. This is critical for rapid evolutionary exploration.
- **Evaluation Ranges:** Neighboring commits are loosely evaluated (diff inspection, targeted tests) to allow rapid progress, while major milestones are strictly evaluated (full test suites, quality metrics) to ensure systemic improvement.

The intersection of spatial and temporal dimensions is powerful: an agent's complete state is specified by `{node_path, base_commit, current_commit, objective}` — a tuple that uniquely identifies what the agent sees, where it started, where it is, and what it must achieve.

---

## 3. The Transient Agent Model

### 3.1 Formal Definition

An agent in Genesis is a pure function:

$$NewState = Agent(State, Objective)$$

where:

$$State = (node\_path, base\_commit, current\_commit)$$

The agent receives its spatial assignment (`node_path`), temporal anchor (`base_commit` — the commit it branches from), current temporal position (`current_commit` — what it has produced so far), and a natural language `objective`. It returns a new state, typically advancing `current_commit` through one or more Git commits.

Critically, agents maintain **no long-term memory**. They rely entirely on:
- The Context Tree (inherited spatial context) for architectural awareness
- The Git history (temporal dimension) for understanding prior work and decisions
- A short-term session memory (the current conversation with the LLM) that is discarded upon completion

This lack of persistent state has profound implications:
- Any agent can be instantiated at any point in the codebase's evolution
- Agents can be trivially parallelized — no shared mutable state
- State rollback is as simple as checking out a historical commit
- Agent crashes are recoverable — the scheduler re-dispatches from the last committed state

### 3.2 Agent Taxonomy

Genesis employs a specialized agent taxonomy, where each agent type has a distinct role, toolset, and delegation configuration. Agents are categorized by their interaction type with the Context Tree:

**Read-Write Agents** (can modify code):
| Agent | Role | Description |
|-------|------|-------------|
| **Manager** | Orchestrator | Plans, delegates, validates — does NOT implement directly. Coordinates work via subagents, resolving conflicts and ensuring quality. |
| **Generalist** | Full-stack engineer | Versatile agent that investigates, plans, and implements autonomously. Can delegate to investigators and executors. |
| **Executor** | Implementation specialist | Receives well-defined objectives and executes precise, targeted code changes. Focuses strictly on the assigned scope. |
| **CodebaseArchitect** | Greenfield designer | Creates project skeletons from scratch. Works in three phases: skeleton design → implementation → review. |
| **SkillExtractor** | Knowledge distiller | Analyzes completed work and distills reusable knowledge into skills for future agents. |

**Read-Only Agents** (can read and update CONTEXT.md, but not modify code):
| Agent | Role | Description |
|-------|------|-------------|
| **CodebaseInvestigator** | Code analyst | Deep, read-only codebase analysis. Finds code, traces dependencies, understands patterns. Can update CONTEXT.md. |
| **ContextExtractor** | Context builder | Extracts semantic context from existing codebases into CONTEXT.md files, building the Context Tree. |
| **TaskScheduler** | Workflow planner | Transforms rough objectives into structured, ordered execution sequences with node assignments. |
| **GenesisPlanner** | Architecture planner | Produces dependency-aware execution plans for genesis-stage architecture work. |
| **Evaluator** | Quality verifier | Reviews code changes against objectives, checking correctness, completeness, and quality. |

This specialization mirrors the division of labor in human software teams: architects design, managers coordinate, engineers implement, investigators research, and evaluators verify.

### 3.3 Recursive SubAgent Delegation

The key mechanism enabling unbounded scalability is **recursive subagent delegation**. When an agent encounters work that belongs in a child node of the Context Tree, it does not attempt to handle it directly. Instead, it:

1. Commits its current pending changes (enforced by auto-commit fallback)
2. Yields its execution slot (releasing the worktree for reuse)
3. Spawns a subagent at the child node with a specific objective
4. Waits for the subagent to complete and return its results
5. Resumes execution, incorporating the subagent's results

The critical property is that **the subagent's context footprint does not count against the parent's session limits**. The parent receives only a compressed result (text summary, diff stats, commit SHA) — not the subagent's full conversation history. This means:

- A parent agent at the root can delegate to a child agent, which delegates to a grandchild, and so on — to arbitrary depth — without any single agent's context window being exhausted.
- The recursive structure mirrors the Context Tree's hierarchy, ensuring that each agent operates only within its spatial scope.

This is fundamentally different from traditional coding agents, where all work occurs within a single conversation context that grows linearly with the scope of work.

### 3.4 Enforcing the Spatial Contract

To maintain architectural integrity, Genesis enforces a **spatial contract** through permission rules:

1. **Read-only agents can only spawn read-only subagents.** Write permissions cannot be escalated through delegation — if a parent is authorized only to read, its children cannot perform unauthorized writes.

2. **Read-write agents can spawn both types, but read-write subagents must operate within the same or child nodes of the parent's assigned node.** Write scope cannot be escalated beyond the parent's authority.

3. **File operations are node-scoped.** An agent assigned to `src/foo/` may only modify files within `src/foo/` and its descendant directories.

This hierarchical permission system ensures that agents respect architectural boundaries and cannot make unauthorized changes to other parts of the codebase. It transforms the Context Tree from a passive documentation structure into an active enforcement mechanism.

---

## 4. Runtime Execution Phases

### 4.1 Phase 1: Genesis (Bootstrapping)

The Genesis phase initializes the Context Tree and Phylogenetic Graph. It operates in two modes depending on whether the target is an existing codebase or a blank slate.

**Mode A — Existing Codebase (Context Extraction):**
The system spawns a `ContextExtractor` agent at the repository root. This agent recursively descends through the directory structure, spawning subagents for each child directory to analyze code, extract APIs, document intent, and establish the Context Tree. The process uses **Fixed Point Convergence**: after initial extraction, the parent agent reviews aggregated context for discrepancies and may spawn correction subagents. This loop repeats until the context stabilizes (reaches a fixed point).

A **Convergence Circuit Breaker** prevents infinite loops: agents evaluate context changes based *only* on functional API surface modifications (not phrasing or stylistic preferences), and a hard iteration limit guarantees mathematical termination.

**Mode B — New Codebase (Architecture and Implementation):**
A `CodebaseArchitect` agent interprets the user's prompt and drafts the initial architectural plan at the root node. It then operates in three phases:
1. **Skeleton Design:** Creates the folder tree with CONTEXT.md files, establishing the spatial hierarchy.
2. **Implementation:** Populates code files, delegating to child architects for subdirectories.
3. **Review & Refinement:** Reviews the overall structure, debugs issues, and finalizes.

For each planned submodule, child architects are recursively spawned to initialize the corresponding nodes. The same Fixed Point Convergence with circuit breaker applies.

### 4.2 Phase 2: Evolution

The Evolution phase modifies an existing codebase based on an objective. The mode is selected based on task clarity, not task size.

**Mode A — Simple Evolution (Top-Down):**
Used for clear, well-defined tasks where the path to the solution is understood. A `Manager` agent at the target node:
1. Maps the spatial context by reading the Context Tree routing table
2. Analyzes the objective to identify required steps
3. Optionally spawns a `TaskScheduler` to produce a structured execution sequence for complex objectives
4. Delegates each step to `Executor` subagents in the appropriate child nodes
5. Validates results, resolves conflicts, and iterates until the objective is met

The decomposition follows the Context Tree: agents only edit files within their assigned node level, delegating to subagents for any child node work. This ensures **Recursive Realization** — the implementation structure mirrors the architectural structure.

Fixed Point Convergence applies: if the objective is not met after subagent completion, the parent spawns new subagents to continue iterating until completion or session limits are reached.

**Mode B — Open-Ended Evolution (Bottom-Up):**
Used for open-ended tasks requiring exploration and creative problem-solving (e.g., "optimize this algorithm for latency"). This mode runs a full evolutionary loop inspired by novelty search and quality diversity:

1. **Entropy Pool Initialization:** The system populates a diverse pool of code fragments drawn from unrelated paradigms (physics engines, game loops, data pipelines, graph algorithms, etc.). These fragments are selected not for fitness but for diversity.

2. **Novelty Search:** Fragments are evaluated based on how *differently* they behave compared to the rest of the pool. Novelty is measured via:
   - **Structural features** — Abstract Syntax Tree (AST) analysis capturing code structure
   - **Behavioral profiles** — LLM classification of functional behavior

3. **LLM-Powered Variation:** The LLM acts as the variation operator:
   - **Crossover** — semantically fuses two distinct fragments, extracting core logic from one domain and applying its structure to another (exaptation)
   - **Mutation** — modifies a fragment's logic while preserving its behavioral profile

4. **Quality Diversity (MAP-Elites):** A grid archive preserves diverse approaches. Each cell maps a behavior descriptor (complexity × paradigm) to its most novel fragment, ensuring that unconventional but unique solutions are preserved as valuable genetic material.

5. **Solution Synthesis:** After the evolution converges (or reaches maximum generations), the system collects the most novel and diverse fragments and asks the LLM to synthesize a coherent solution. This solution is applied to the codebase via a Manager agent.

This bottom-up mode embodies **Algorithmic Serendipity** — the system is designed to discover unexpected solutions by leveraging the LLM's semantic understanding to bridge disjoint domains.

---

## 5. The Agent Scheduler and Git Isolation

### 5.1 Worktree-Based Isolation

Genesis manages execution through an **Agent Scheduler** analogous to operating system process scheduling. The constrained resource is a fixed pool of Git worktree slots — isolated working copies of the repository. This design provides several critical properties:

1. **Immutability of the Main Checkout:** The user's primary working copy is never directly modified by any agent. All changes occur in isolated worktrees.

2. **Execution Lifecycle:** Agents begin in a `waiting` state. When a worktree slot becomes available, the scheduler assigns it to a waiting agent, checks out the agent's exact `current_commit`, and begins execution. This ensures resuming agents do not overwrite prior progress.

3. **Cooperative Multitasking (Yielding):** Worktrees cannot be locked idle. When an agent needs to spawn subagents, it must yield: commit pending changes, transition to `waiting`, and release the worktree. The scheduler can then assign the worktree to other queued agents (including the newly spawned subagents). Once subagents complete, the parent agent is re-queued for a worktree to resume.

4. **Persistent Worktrees:** Worktrees are persistent per-agent across retries — created on initial dispatch, reused on retry, and cleaned up only on final completion. This preserves partial work across crashes.

### 5.2 Slot Management and Rate Limiting

The scheduler manages two independent resource pools with FIFO queuing:

- **LLM Slots:** Govern concurrent LLM API calls. Default size is configurable. When the LLM provider returns a rate-limit error, a global backoff is triggered — all LLM calls pause for a cooldown period (default: 60 seconds) before retrying.

- **Tool Slots:** Govern concurrent tool executions (shell commands, file operations, web searches). Independently throttled from LLM calls.

This dual-pool design recognizes that LLM API calls and local tool executions have fundamentally different bottleneck characteristics: LLM calls are constrained by external rate limits, while tool executions are constrained by local system resources.

---

## 6. Genesis vs. Traditional Evolutionary Algorithms

### 6.1 Fundamental Differences

While Genesis draws inspiration from evolutionary computation, it differs fundamentally from traditional evolutionary algorithms (EAs) in several key dimensions:

| Dimension | Traditional EA | Genesis |
|-----------|---------------|---------|
| **Representation** | Flat encodings (bit strings, real-valued vectors) | Hierarchical Context Tree with semantic nodes |
| **Search Space** | Fixed-dimensional parameter space | Unbounded tree of architectural structures |
| **Variation Operators** | Mathematical (crossover, mutation on encodings) | LLM-powered semantic synthesis |
| **Selection** | Fitness-proportional or rank-based | Novelty-based + architectural coherence constraints |
| **Structure** | Linear population of individuals | Tree-structured, recursive decomposition |
| **Convergence** | Fitness convergence to optima | Fixed-point convergence on architectural consistency |
| **Operators** | Domain-agnostic, syntactic | Domain-aware, semantic (via LLM) |

**1. Tree-Structured Evolution vs. Flat Populations:**
Traditional EAs evolve a flat population of individuals, each a complete candidate solution represented as a fixed-length encoding. Genesis, by contrast, evolves a *tree of agents* that recursively decompose the problem. Each agent evolves its local subtree independently, with parent agents coordinating the integration. This mirrors how complex organisms develop: not as a flat genome, but as a hierarchical differentiation process where each cell specializes according to its position in the developmental tree.

**2. Recursive Expansion vs. Generational Iteration:**
Traditional EAs iterate over discrete generations: evaluate all individuals → select → vary → replace. Genesis uses **recursive expansion**: an agent at the root decomposes its objective into child objectives, each child further decomposes, and so on until leaf-level tasks are reached. This is closer to recursive function evaluation than to population-based optimization. The "generation" concept is replaced by the depth of recursive delegation.

**3. Fixed-Point Convergence vs. Fitness Optimization:**
Traditional EAs converge when the population's average fitness stabilizes near an optimum. Genesis converges when the Context Tree reaches a **fixed point** — a state where further agent iterations produce no functional API surface changes. This is analogous to the fixed-point semantics in denotational semantics or the convergence of iterative equation solvers. The Convergence Circuit Breaker (evaluation based only on functional changes, hard iteration limit) guarantees this process terminates.

**4. LLM as Semantic Variation Operator:**
In traditional EAs, crossover and mutation are syntactic operations on the encoding — they have no understanding of what the encoding *means*. In Genesis's complex evolution mode, the LLM serves as the variation operator, performing **semantic crossover** (extracting the core logic from one domain and applying its structure to another) and **semantic mutation** (modifying logic while understanding its implications). This transforms blind search into guided exploration.

**5. Novelty Search and Quality Diversity:**
Genesis's complex mode incorporates insights from the novelty search and quality diversity literature. Rather than optimizing toward a single fitness peak, it maintains a MAP-Elites archive that preserves diverse behavioral strategies. This is particularly suited for open-ended problems where the optimal approach is unknown, as it ensures the system explores a wide region of the solution space rather than converging prematurely.

### 6.2 Conceptual Positioning

Genesis can be understood as a **developmental evolution system** — bridging the gap between evolutionary computation and developmental biology. In biology, the genotype (DNA) does not directly specify the phenotype (organism); rather, a developmental process reads the genotype and produces the organism through cell division, differentiation, and morphogenesis. Similarly, in Genesis:

- The **genotype** is the combination of the user's prompt, the Context Tree structure, and the Git history.
- The **developmental process** is the recursive agent delegation tree — each agent "differentiates" based on its node position and objective.
- The **phenotype** is the resulting codebase.

This developmental perspective explains why Genesis can produce architecturally coherent results: the Context Tree provides the positional information (like morphogen gradients in biology) that guides each agent's specialization, while the spatial contract ensures that each agent's contribution integrates coherently with the whole.

---

## 7. Genesis vs. Traditional Coding Agents

### 7.1 Architectural Differences

The landscape of LLM-based coding agents has expanded rapidly, with tools like Claude Code, GitHub Copilot Workspace, Cursor, and Aider gaining adoption. Genesis differs from these in several fundamental ways:

**1. Transient Agents vs. Stateful Sessions:**

Traditional coding agents (e.g., Claude Code) operate as a single, stateful conversation. The agent loads context, makes changes, and iterates — all within one continuous session. The agent's "memory" is the conversation history, which grows monotonically.

Genesis agents are **transient functions**. An agent's state is fully captured by `{node_path, base_commit, current_commit}`. There is no persistent state carried between invocations — only the spatial context (Context Tree) and temporal context (Git history) persist. This means:
- Agents can be trivially parallelized (no shared mutable state)
- Crashes are fully recoverable (re-dispatch from last commit)
- Context never accumulates beyond a single agent's session

**2. Recursive Decomposition vs. Monolithic Context:**

Traditional agents face a hard scalability ceiling: the entire relevant codebase context must fit within the LLM's context window. As projects grow, agents either miss important context (degraded quality) or exceed the window (failure).

Genesis solves this through **recursive decomposition with context isolation**. Each agent operates only within its node's scope, seeing only:
- The inherited Context Tree path (lightweight, structural)
- Files within its assigned node
- Results from completed subagents (compressed summaries, not full conversations)

The subagent's context footprint does not count against the parent's limits. This enables work on **arbitrarily large codebases** — the depth of recursive delegation scales with the project's architectural depth, not with its total size.

**3. Spatial Contract Enforcement vs. Unconstrained Editing:**

Traditional agents have unrestricted access to the entire codebase. An agent asked to fix a bug in `src/auth/` might also modify `src/db/` or `src/api/` if it deems it necessary. This can lead to architectural violations and unintended side effects.

Genesis enforces the **spatial contract**: an agent assigned to `src/auth/` can only modify files within `src/auth/` and its descendants. Write permissions are hierarchically scoped and cannot be escalated. This transforms the codebase from an undifferentiated blob into a structured space with explicit boundaries.

**4. Phylogenetic Evolution vs. Linear Editing:**

Traditional agents work linearly: they make changes, the user reviews, and the process repeats. There is no concept of branching, parallel exploration, or selective merging.

Genesis uses a **phylogenetic DAG**: agents branch from specific commits, explore independently, and successful branches are selectively merged. This enables:
- **Parallel exploration** of multiple approaches
- **Partial progress acceptance** — a branch that fixes one bug is valuable even if others remain
- **Temporal rollback** — any agent can examine or branch from any historical commit
- **Bisect-style debugging** — spawn agents at different commits to identify when a regression was introduced

**5. Architectural Awareness vs. Flat File Perception:**

Traditional agents perceive the codebase as a flat collection of files. They discover structure through exploration (grepping, reading files), which consumes context window capacity and is inherently incomplete.

Genesis provides **inherited architectural context** through the Context Tree. An agent at `src/auth/oauth/` automatically knows:
- What `src/auth/` does (from its CONTEXT.md)
- What the entire system does (from the root CONTEXT.md)
- Where to delegate work (from the routing table)
- What constraints apply (from each level's constraints)

This architectural awareness is **structural, not discovered** — it is inherited as part of the agent's initialization, not derived through expensive exploration. Furthermore, because the inherited context is structured as a prefix tree, the shared ancestor tokens maximize KV cache reuse, making inference far cheaper than flat-context approaches where every agent must re-process the full codebase from scratch. And because agents persist their discoveries into CONTEXT.md as they work, the context itself accumulates wisdom over time — making the system genuinely self-improving, not merely self-executing.

### 7.2 Summary Comparison Table

| Feature | Traditional Coding Agents | Genesis |
|---------|--------------------------|---------|
| State model | Stateful session | Transient function |
| Scalability | Limited by context window | Unbounded (recursive decomposition) |
| Architecture awareness | Discovered through exploration | Inherited via Context Tree |
| Codebase perception | Flat files | Hierarchical semantic tree |
| Editing scope | Unconstrained | Spatially scoped and enforced |
| Evolution model | Linear editing | Phylogenetic DAG with branching |
| Parallelism | Limited (single session) | Native (worktree pool + subagents) |
| Crash recovery | Session-dependent | Fully recoverable (commit-based) |
| Temporal navigation | Current state only | Any commit in history |
| Quality assurance | Manual review | Automated evaluation + spatial contract |

---

## 8. Additional Design Features

### 8.1 Dynamic Skills System

Genesis incorporates a **Dynamic Skills System** that enables project-specific automation without modifying the framework source. Skills are custom tools defined as markdown files with YAML frontmatter (name, description, parameters) and an executable body. They are loaded at runtime as LLM-callable tools.

Architecturally, Skills follow the **exact same hierarchy-context design pattern** as CONTEXT.md. They are **globally defined** but **hierarchically enabled** per Context Tree node — each CONTEXT.md may specify which skills are active at that level, and skills inherit downward through the tree, just as contextual contracts do. The distinction is **not architectural**: Skills do not introduce a new design paradigm. The only difference is their **purpose**. While CONTEXT.md stores structural and architectural contracts (Intent, API Surface, Constraints, Routing), Skills are specialized for storing more complex, procedural **experience** — reusable strategies, workflows, and operational know-how that an agent has learned. In other words, Skills extend the same hierarchical context inheritance mechanism that CONTEXT.md already uses, but are specialized for capturing complex experiential knowledge rather than structural contracts.

A **SkillExtractor** agent automatically analyzes completed work and distills reusable knowledge into new skills, creating a self-improving system where successful strategies are captured for future agents. This mirrors the concept of *genetic memory* in evolutionary systems — successful adaptations are encoded and inherited by future generations.

### 8.2 Multi-Repository Support

Genesis supports referencing external repositories ("foreign repos") via absolute paths. This enables cross-repository tasks such as:
- Porting a codebase from one language/framework to another
- Referencing a legacy implementation during modernization
- Coordinating changes across multiple related repositories

Foreign repos are registered at phase initialization and tracked per-agent. To maintain safety, only read-only investigation is permitted in foreign repos — write-capable agents cannot modify external codebases.

### 8.3 Multi-Platform Sandboxing

All LLM-generated code execution is sandboxed using platform-appropriate mechanisms:
- **Linux:** `systemd-run` with strict resource limits (CPU, memory, syscall caps), read-only host filesystem access, and read-write access only to the assigned worktree.
- **macOS:** `sandbox-exec` with filesystem isolation profiles.
- **Windows:** Direct execution (sandboxing capabilities are limited).

This ensures that even if an LLM generates malicious or buggy code, the blast radius is limited to the agent's worktree and cannot affect the host system.

### 8.4 Context Compression

When an agent's total token count exceeds a configurable threshold, the framework automatically compresses the chat history. This compression preserves essential information (decisions made, files modified, key findings) while discarding verbose intermediate outputs. This allows individual agents to work on complex tasks within their node without hitting hard context limits, while still maintaining the transient principle — the compressed context is transient and discarded upon agent completion.

### 8.5 Delegation Hinting

When an agent repeatedly edits files in a child directory (below its assigned node), the framework tracks these write operations. After exceeding a threshold (default: 5 writes to the same child directory), a gentle hint is appended to the tool output suggesting the agent spawn a subagent for that subtree. This encourages proper hierarchical decomposition without forcing it — agents that are making quick, one-off edits in a child directory are not interrupted, but agents that are effectively "living" in a child directory are nudged toward proper delegation.

---

## 9. Implementation Technology

Genesis is implemented in **Elixir/OTP**, selected for several properties that align with the framework's design:

- **Actor Model Concurrency:** Elixir's lightweight processes and message-passing model naturally mirror the transient agent design. Each agent runs as an isolated process, and the scheduler coordinates them through message passing.
- **Fault Tolerance:** OTP's supervision trees provide crash recovery and retry logic — critical for a system where LLM API calls may fail and agents may crash.
- **Pattern Matching and Immutability:** Elixir's functional paradigm enforces immutability, preventing the kind of shared-state bugs that plague object-oriented agent implementations.

Version control is handled exclusively through the **Git CLI** (via a thin adapter), deliberately avoiding libgit2 bindings to minimize complexity and maximize debuggability.

The system uses a **three-level configuration** hierarchy: application defaults → user configuration (`~/.config/evogit/config.toml`, XDG-compliant) → session-level runtime overrides (via CLI flags or dashboard settings). This ensures sensible defaults while allowing full user customization.

---

## 10. Conclusion

EvoX Genesis represents a novel approach to autonomous software development that synthesizes insights from evolutionary computation, developmental biology, and hierarchical software architecture. Its key contributions are:

1. **The Dual-Dimension Architecture** — intersecting a spatial Context Tree with a temporal phylogenetic DAG to provide complete state specification for any agent at any evolutionary point.

2. **The Transient Agent Model** — agents as pure functions over `{commit, node_path} × objective`, enabling unbounded scalability through recursive decomposition with context isolation.

3. **Spatial Contract Enforcement** — hierarchical permission scoping that transforms architectural documentation into an active enforcement mechanism.

4. **Multi-Modal Evolution** — supporting both top-down planning (simple mode) and bottom-up novelty search with quality diversity (complex mode), catering to both well-defined and open-ended tasks.

5. **LLM as Semantic Variation Operator** — using the LLM's semantic understanding to perform meaningful crossover and mutation across domain boundaries, enabling algorithmic serendipity.

6. **The Self-Evolving Context Tree** — the hierarchical context is not static documentation but a living artifact that agents both read and update, accumulating wisdom over time. This makes the system genuinely self-evolving: the knowledge governing agent behavior improves through use, creating a positive feedback loop between structure and agency.

These design choices position Genesis not merely as a coding assistant, but as an **evolutionary software development framework** — one that treats software creation as a hierarchical, recursive, evolutionary process guided by architectural contracts and powered by semantic AI operators. The framework's ability to scale to arbitrarily large codebases, recover from any failure, and explore solution spaces through both directed planning and open-ended novelty search makes it a distinct contribution to the field of autonomous software engineering.

---

# EvoX Genesis：从AI vibe coding到自主软件演化

--- 中文版本 ---

## 摘要

**"Vibe coding"**——由大语言模型（LLM）驱动的自由流式AI辅助开发——的兴起，虽然使软件创建民主化，但继承了根本性的结构限制：单体式上下文窗口带来的硬性可扩展性上限、扁平文件感知导致的架构盲目性、不受约束的编辑范围、脆弱的会话状态，以及单路径的线性执行。随着代码库增长超出单一对话所能容纳的范围，这些限制使vibe coding从生产力倍增器退化为不可靠的拐杖。

EvoX Genesis是一个去中心化的演化式软件开发框架，旨在超越这些限制。该系统引入了**双维度架构**，将提供语义结构感知的*空间维度*——层次化上下文树——与追踪演化历史的*时间维度*——不可变Git提交的系统发育有向无环图（DAG）——相交融合。在此框架中，**无状态智能体**作为纯变换函数运行于 `{commit, node_path} × objective → new_commit`，沿上下文树递归分解任务，从而在无上下文窗口耗尽的情况下实现无界可扩展性。系统支持两个执行阶段——*创世*（引导）和*演化*（迭代修改），其中演化进一步分为*简单*（自顶向下规划）和*复杂*（基于新颖性搜索和质量多样性的自底向上）两种模式。本报告呈现Genesis系统的设计哲学、架构原理、智能体分类学、运行时机制，并将其置于演化计算和自主编程智能体的更广阔背景中。

## 1. 引言

### 1.1 Vibe Coding的兴起与局限

基于LLM的编程工具的广泛采用催生了**"vibe coding"**——一种开发实践，程序员以自由流式、对话式的方式与AI助手交互，根据代码"感觉对不对"来接受生成的代码，而非严格验证每一个细节。Cursor、GitHub Copilot Workspace、Aider和Claude Code等工具使这种开发方式触达了数百万人，极大地降低了产出可用代码的门槛。对于小规模项目和快速原型开发，vibe coding是变革性的。

然而，随着项目规模和复杂性的增长，vibe coding继承并放大了几个根植于其底层工具架构的根本性限制：

**问题1：上下文之墙。** 传统编程智能体作为单体式、有状态的进程运行，必须将相关代码库上下文加载到单一对话窗口中。随着代码库增长，智能体面临一个不可回避的困境：要么包含更多上下文（冒着窗口耗尽的风险），要么包含更少（遗漏关键依赖）。这造成了硬性可扩展性上限——超过一定的项目规模，智能体的理解能力下降，其进行架构一致性修改的能力崩溃。

**问题2：架构盲目性。** Vibe coding工具将代码库感知为扁平的文件集合。结构通过探索（搜索、读取文件）来发现，这不仅昂贵——消耗宝贵的上下文窗口容量——而且本质上不完整。智能体没有继承的系统架构感知能力；它必须在每次会话中从零开始重建全局图景，而且这种重建是不完美的。

**问题3：无约束的编辑范围。** 被要求修复一个模块中bug的智能体可以自由修改它认为相关的任何其他模块。没有对架构边界的强制执行——智能体的编辑范围仅受其自身判断的限制，而特别是在上下文不完整时（见问题2），这种判断可能是有缺陷的。这导致架构违规、意外副作用以及低内聚的混乱代码库。

**问题4：脆弱的会话状态。** 智能体的"记忆"是其对话历史，单调增长且无法在不丢失上下文的情况下重置。如果会话崩溃、被中断或变得过长而难以管理，工作可能会丢失。没有原则性的恢复机制——整个会话必须从头开始，且无法保证重现先前的进展。

**问题5：单路径执行。** Vibe coding遵循严格的线性轨迹：修改→审查→重复。没有并行探索多种替代方案的机制，也没有在当前路径停滞时从历史状态分支以尝试不同策略的机制。开发者被锁定在单一的演化路线上。

这些问题不仅仅是不便——它们代表了阻止vibe coding扩展到现实世界项目所需的自主、大规模软件开发的结构性限制。

### 1.2 Genesis如何解决这些问题

EvoX Genesis从头开始设计，作为对这些限制中每一个的直接回应。下表将每个vibe coding问题映射到解决它的具体Genesis机制：

| Vibe Coding问题 | Genesis解决方案 | 关键机制 |
|----------------|----------------|---------|
| **上下文之墙**（问题1） | 具有上下文隔离的递归分解 | 无状态智能体在子节点处委托给子智能体；每个子智能体的上下文足迹不计入父智能体的限制（§3.3） |
| **架构盲目性**（问题2） | 通过上下文树继承的空间上下文 | 每个智能体从根到其分配节点继承架构契约链——意图、API表面、路由表（§2.1） |
| **无约束范围**（问题3） | 空间契约强制执行 | 智能体只能修改其分配节点及其后代内的文件；写权限是层次化范围的，不能升级（§3.4） |
| **脆弱会话状态**（问题4） | 无状态智能体 + Git支撑的持久化 | 智能体状态完全由`{node_path, base_commit, current_commit}`捕获；任何崩溃通过从最后提交重新分发来恢复（§3.1） |
| **单路径执行**（问题5） | 系统发育DAG + 工作树隔离 | 智能体从特定提交分支并在隔离的工作树中独立探索；成功分支被选择性合并（§2.2、§5.1） |

这种问题到解决方案的对应并非偶然——每个Genesis机制都是作为对vibe coding范式特定结构性失败模式的原则性回应而设计的。本文的其余部分详细阐述这些机制中的每一个。

### 1.3 设计原则

Genesis建立在三个核心原则之上：

1. **结构感知优于扁平文件：** 代码库不是文件的扁平集合，而是语义节点的层次化树，每个节点携带明确的架构契约。智能体在空间上导航这棵树，始终在明确定义的范围内操作。

2. **无状态智能体优于有状态会话：** 智能体是瞬态的、无状态的函数。所有持久化知识驻留在空间维度（上下文树）或时间维度（Git历史）中。这消除了状态损坏，实现了平凡的并行化，并允许任何智能体在代码库演化历史的任何点被实例化。

3. **演化进步优于绿色构建：** 系统接受部分进步——实现了多一个功能或通过了多一个测试的版本是有价值的，即使其他部分仍然损坏。这镜像了自然选择的渐进式、方向性改进，并实现了对解空间的快速探索。

---

## 2. 双维度架构

Genesis的核心创新是两个正交维度——空间和时间——的交集，它们共同为智能体在代码库生命周期的任何点提供完整的状态规范。

### 2.1 空间维度：上下文树

空间维度将代码库建模为**上下文树**——一种递归的层次化结构，其中每个节点代表一个目录或文件。关键创新是**空间契约**：每个目录节点包含一个`CONTEXT.md`文件，作为目录的内在属性（概念上类似于扩展文件属性），定义：

1. **文档：**
   - *意图* — 目录在系统中的目的和角色
   - *API表面* — 它暴露的模块、函数和接口
   - *约束* — 该目录内代码的规则和指南

2. **路由表** — 将责任区域映射到子目录，使父智能体能够将工作委托给正确的子节点，而无需调查子树的内部。

**上下文继承**自顶向下流动。被分配到`src/auth/oauth/`的智能体通过聚合从根 → `src/` → `src/auth/` → `src/auth/oauth/`的显式上下文来构建其世界观。这种继承的上下文提供了架构一致性，而不需要每个智能体重新推导整个系统结构。

正式的上下文层次结构下至**目录级别**。一旦智能体针对特定文件，它就依赖LLM的自然代码理解能力来导航内部逻辑（文档字符串、注释、代码结构）。这一设计决策反映了现代LLM在文件级理解方面的天然优势，使得显式的子文件建模变得不必要。

### 2.1.1 通过前缀树结构实现令牌效率

层次化的上下文继承意味着，智能体的世界观是通过将从根到其分配节点的祖先CONTEXT.md文件拼接而构建的。关键在于，由于子树内的所有智能体共享相同的祖先节点集合，这种拼接形成了一棵**上下文的前缀树（trie）**。当父智能体委托给多个子智能体，或当顺序智能体在同一子树内工作时，共享的祖先上下文令牌已经存在于LLM的键值（KV）缓存中——它们不需要被重新计算。

这是上下文树层次结构与Transformer注意力缓存工作方式之间的刻意结构对齐：树结构镜像了底层推理引擎的缓存局部性。树越深，在该子树中操作的智能体之间复用的前缀就越多。当父智能体委托给多个子智能体时，每个子智能体的提示以与父智能体已处理内容相同的祖先前缀开始，因此这些令牌的KV缓存条目被直接复用。这将本应是对重复上下文的O(n²)冗余注意力计算转化为共享前缀的近O(1)，使推理在系统扩展时显著更廉价、更快速。

### 2.1.2 路由表作为委托指南针

路由表不仅仅是文档——它是实现**精确委托**的机制。父智能体通过读取其CONTEXT.md路由表，准确知道哪个子节点拥有哪个功能区域。当它接收到一个目标时，可以高精度地将每个子任务路由到正确的子节点，而无需调查子树的内部或了解子节点的实现方式。

这消除了传统智能体必须执行的昂贵且易错的探索——搜索目录、读取文件以发现结构、从代码推断责任边界。路由表实际上使每个父智能体成为一个知情的调度器：它一目了然地了解系统的分解。这也意味着委托错误被最小化。智能体不会意外地将数据库工作发送到认证子系统，因为路由表明确地将"数据库"映射到正确的子节点。因此，路由表将委托从模糊的、探索性的过程转变为确定性的查找。

### 2.1.3 积累的智慧：上下文作为继承的经验

上下文树不仅仅是静态的架构文档——它是一个**积累的智慧**的活态仓库。在每个节点工作的每个智能体都可以记录它所学到的东西：实现过程中发现的棘手约束、导致bug的重要陷阱、设计决策及其理由、性能注意事项。这些被记录在CONTEXT.md的约束和意图部分中，在智能体的瞬态会话之后持久化。

在同一节点工作的未来智能体立即继承这些智慧——它们在开始工作时就已经知道了重要的陷阱和设计决策，而无需通过试错重新发现它们。这创造了一种**自我改进**的特性：系统随着时间的推移变得更聪明，因为每个智能体来之不易的洞见都被持久化并继承。在成熟的子树中工作的智能体受益于之前所有智能体的集体经验。学习一个教训的代价只支付一次——由第一个遇到它的智能体承担——然后该教训就可以无额外成本地提供给每个后续智能体。

### 2.1.4 自我演化的上下文树

上述特性汇聚为最深刻的洞见：上下文树是真正**自我演化**的。层次化的上下文不是被动的文档——它实际上是**智能体行为规范的一部分**。智能体读取CONTEXT.md来了解如何行动：遵循什么约束、意图是什么、将工作路由到哪里。但智能体在工作时也会**更新**CONTEXT.md：当它们发现新的约束、解决一个陷阱、更改API或学到更好的做事方式时，它们会将这些新知识持久化到上下文中。

这创造了一个反馈循环：上下文塑造智能体行为，而智能体行为也塑造上下文。随着时间的推移，上下文树发生演化——不仅是代码，还有指导代码创建的知识。这类似于生物学中的**表观遗传继承**：在静态基因组（初始架构）之外，还存在一层通过生活经验积累的动态遗传修饰，它塑造了基因的表达方式。上下文树既是基因型（结构契约），也是这种表观遗传记忆。这是系统"自我演化"的最深层含义：指导智能体行为的知识本身就是一种活的、不断增长的制品，它通过使用而不断改进。

### 2.2 时间维度：系统发育图

时间维度将代码演化建模为**系统发育图**——不可变Git提交的有向无环图（DAG）。生物学比喻是刻意的：每次提交是演化谱系中的一个有机体，父子关系代表血统。

时间维度的关键属性：

- **方向性演化（$v_{new} > v_{old}$）：** 子提交仅在可测量地"优于"其父提交时才被接受。这在每个合并点通过评估来强制执行。
- **部分进步接受：** 与要求完全通过构建的传统CI/CD管道不同，Genesis接受增量改进。通过更多测试、实现功能或提高可读性的版本被接受——即使系统的其他部分仍然损坏。这对于快速演化探索至关重要。
- **评估范围：** 相邻提交被宽松评估（差异检查、针对性测试）以允许快速进展，而主要里程碑被严格评估（完整测试套件、质量指标）以确保系统性改进。

空间和时间维度的交集是强大的：智能体的完整状态由`{node_path, base_commit, current_commit, objective}`指定——这个元组唯一标识了智能体看到什么、从哪里开始、当前在哪里以及必须实现什么。

---

## 3. 无状态智能体模型

### 3.1 形式化定义

Genesis中的智能体是一个纯函数：

$$NewState = Agent(State, Objective)$$

其中：

$$State = (node\_path, base\_commit, current\_commit)$$

智能体接收其空间分配（`node_path`）、时间锚点（`base_commit`——它从中分支的提交）、当前时间位置（`current_commit`——它迄今为止产生的结果）以及自然语言`objective`。它返回一个新状态，通常通过一次或多次Git提交推进`current_commit`。

关键的是，智能体维护**没有长期记忆**。它们完全依赖：
- 上下文树（继承的空间上下文）用于架构感知
- Git历史（时间维度）用于理解先前的工作和决策
- 短期会话记忆（与LLM的当前对话），在完成时被丢弃

这种无状态性具有深远的影响：
- 任何智能体都可以在代码库演化的任何点被实例化
- 智能体可以被平凡地并行化——没有共享的可变状态
- 状态回滚就像签出历史提交一样简单
- 智能体崩溃是可恢复的——调度器从最后提交的状态重新分发

### 3.2 智能体分类学

Genesis采用专门的智能体分类学，其中每种智能体类型具有不同的角色、工具集和委托配置。智能体按其与上下文树的交互类型进行分类：

**读写智能体**（可以修改代码）：
| 智能体 | 角色 | 描述 |
|-------|------|-------------|
| **Manager** | 编排者 | 规划、委托、验证——不直接实现。通过子智能体协调工作，解决冲突并确保质量。 |
| **Generalist** | 全栈工程师 | 多面手智能体，能自主调查、规划和实现。可以委托给调查者和执行者。 |
| **Executor** | 实现专家 | 接收明确定义的目标并执行精确、有针对性的代码修改。严格专注于分配范围。 |
| **CodebaseArchitect** | 绿地设计师 | 从零开始创建项目骨架。分三阶段工作：骨架设计 → 实现 → 审查。 |
| **SkillExtractor** | 知识蒸馏器 | 分析已完成的工作，将可重用的知识蒸馏为技能，供未来智能体使用。 |

**只读智能体**（可以读取和更新CONTEXT.md，但不能修改代码）：
| 智能体 | 角色 | 描述 |
|-------|------|-------------|
| **CodebaseInvestigator** | 代码分析师 | 深度只读代码库分析。查找代码、追踪依赖、理解模式。可以更新CONTEXT.md。 |
| **ContextExtractor** | 上下文构建者 | 从现有代码库中提取语义上下文到CONTEXT.md文件，构建上下文树。 |
| **TaskScheduler** | 工作流规划者 | 将粗略目标转化为具有节点分配的结构化、有序执行序列。 |
| **GenesisPlanner** | 架构规划者 | 为创世阶段的架构工作生成依赖感知的执行计划。 |
| **Evaluator** | 质量验证者 | 对照目标审查代码变更，检查正确性、完整性和质量。 |

这种专门化镜像了人类软件团队中的劳动分工：架构师设计、管理者协调、工程师实现、调查者研究、评估者验证。

### 3.3 递归子智能体委托

实现无界可扩展性的关键机制是**递归子智能体委托**。当智能体遇到属于上下文树子节点的工作时，它不会尝试直接处理。相反，它：

1. 提交当前待处理的变更（由自动提交回退强制执行）
2. 让出其执行槽位（释放工作树以供重用）
3. 在子节点处以特定目标生成一个子智能体
4. 等待子智能体完成并返回结果
5. 恢复执行，纳入子智能体的结果

关键属性是**子智能体的上下文足迹不计入父智能体的会话限制**。父智能体只接收压缩的结果（文本摘要、差异统计、提交SHA）——而不是子智能体的完整对话历史。这意味着：

- 根节点的父智能体可以委托给子智能体，子智能体再委托给孙智能体，依此类推——到任意深度——而不会耗尽任何单个智能体的上下文窗口。
- 递归结构镜像了上下文树的层次结构，确保每个智能体仅在其空间范围内操作。

这与传统编程智能体根本不同，在传统智能体中，所有工作都在单一对话上下文中进行，该上下文随工作范围线性增长。

### 3.4 空间契约的强制执行

为维护架构完整性，Genesis通过权限规则强制执行**空间契约**：

1. **只读智能体只能生成只读子智能体。** 写权限不能通过委托升级——如果父智能体仅被授权读取，其子智能体不能执行未授权的写入。

2. **读写智能体可以生成两种类型，但读写子智能体必须在父智能体分配节点的相同或子节点内操作。** 写范围不能升级到超出父智能体的权限。

3. **文件操作是节点范围的。** 被分配到`src/foo/`的智能体只能修改`src/foo/`及其后代目录内的文件。

这种层次化权限系统确保智能体尊重架构边界，不能对代码库的其他部分进行未授权的修改。它将上下文树从被动的文档结构转变为主动的强制执行机制。

---

## 4. 运行时执行阶段

### 4.1 第一阶段：创世（引导）

创世阶段初始化上下文树和系统发育图。它根据目标是现有代码库还是空白起点，以两种模式运行。

**模式A — 现有代码库（上下文提取）：**
系统在仓库根目录生成一个`ContextExtractor`智能体。该智能体递归下降到目录结构中，为每个子目录生成子智能体来分析代码、提取API、记录意图并建立上下文树。该过程使用**不动点收敛**：初始提取后，父智能体审查聚合的上下文以发现差异，并可能生成纠正子智能体。这个循环重复直到上下文稳定（达到不动点）。

**收敛断路器**防止无限循环：智能体*仅*基于功能性API表面修改（而非措辞或风格偏好）评估上下文变更，硬性迭代限制保证数学上的终止性。

**模式B — 新代码库（架构与实现）：**
`CodebaseArchitect`智能体解释用户的提示并在根节点草拟初始架构计划。然后它分三阶段运行：
1. **骨架设计：** 创建带有CONTEXT.md文件的文件夹树，建立空间层次结构。
2. **实现：** 填充代码文件，委托子架构师处理子目录。
3. **审查与精炼：** 审查整体结构，调试问题并最终完成。

对于每个计划的子模块，递归生成子架构师来初始化相应的节点。相同的不动点收敛与断路器适用。

### 4.2 第二阶段：演化

演化阶段基于目标修改现有代码库。模式的选择基于任务清晰度，而非任务大小。

**模式A — 简单演化（自顶向下）：**
用于清晰的、明确定义的任务，其中到解决方案的路径是已知的。目标节点处的`Manager`智能体：
1. 通过读取上下文树路由表映射空间上下文
2. 分析目标以识别所需步骤
3. 对于复杂目标，可选地生成`TaskScheduler`来产生结构化执行序列
4. 将每个步骤委托给相应子节点中的`Executor`子智能体
5. 验证结果，解决冲突，并迭代直到目标达成

分解遵循上下文树：智能体仅编辑其分配节点级别内的文件，对任何子节点工作委托给子智能体。这确保了**递归实现**——实现结构镜像架构结构。

不动点收敛适用：如果子智能体完成后目标未达成，父智能体生成新的子智能体继续迭代，直到完成或达到会话限制。

**模式B — 开放式演化（自底向上）：**
用于需要探索和创造性问题解决的开放式任务（如"优化此算法的延迟"）。此模式运行受新颖性搜索和质量多样性启发的完整演化循环：

1. **熵池初始化：** 系统用来自不相关范式（物理引擎、游戏循环、数据管道、图算法等）的多样化代码片段填充池。这些片段不是因为适应度而是因为多样性被选择。

2. **新颖性搜索：** 基于*不同*于池中其余片段的程度评估片段。新颖性通过以下方式测量：
   - **结构特征** — 捕获代码结构的抽象语法树（AST）分析
   - **行为特征** — 功能行为的LLM分类

3. **LLM驱动的变异：** LLM作为变异算子：
   - **交叉** — 语义上融合两个不同的片段，从一个领域提取核心逻辑并将其结构应用于另一个领域（扩展适应）
   - **突变** — 在保留行为特征的同时修改片段的逻辑

4. **质量多样性（MAP-Elites）：** 网格档案保留多样化的方法。每个单元格将行为描述符（复杂度 × 范式）映射到其最新颖的片段，确保非常规但独特的解决方案作为有价值的遗传物质被保留。

5. **解合成：** 演化收敛（或达到最大代数）后，系统收集最新颖和最多样化的片段，并要求LLM合成一个连贯的解决方案。该解决方案通过Manager智能体应用于代码库。

这种自底向上的模式体现了**算法意外发现**——系统被设计为通过利用LLM的语义理解来桥接不相交的领域，从而发现意想不到的解决方案。

---

## 5. 智能体调度器与Git隔离

### 5.1 基于工作树的隔离

Genesis通过类似于操作系统进程调度的**智能体调度器**管理执行。受约束的资源是固定数量的Git工作树槽位——仓库的隔离工作副本。此设计提供了几个关键属性：

1. **主签出的不可变性：** 用户的主要工作副本从不会被任何智能体直接修改。所有变更都发生在隔离的工作树中。

2. **执行生命周期：** 智能体从`waiting`状态开始。当工作树槽位可用时，调度器将其分配给等待中的智能体，签出智能体的精确`current_commit`，并开始执行。这确保恢复的智能体不会覆盖先前的进展。

3. **协作式多任务（让出）：** 工作树不能被空闲锁定。当智能体需要生成子智能体时，它必须让出：提交待处理变更，转换为`waiting`状态，并释放工作树。调度器随后可以将工作树分配给其他排队的智能体（包括新生成的子智能体）。子智能体完成后，父智能体重新排队等待工作树以恢复。

4. **持久化工作树：** 工作树在重试之间为每个智能体持久化——在初始分发时创建，在重试时重用，仅在最终完成时清理。这在崩溃之间保留了部分工作。

### 5.2 槽位管理与速率限制

调度器管理两个具有FIFO排队的独立资源池：

- **LLM槽位：** 管理并发的LLM API调用。默认大小可配置。当LLM提供商返回速率限制错误时，触发全局退避——所有LLM调用暂停一个冷却期（默认：60秒），然后重试。

- **工具槽位：** 管理并发的工具执行（shell命令、文件操作、网络搜索）。与LLM调用独立限流。

这种双池设计认识到LLM API调用和本地工具执行具有根本不同的瓶颈特征：LLM调用受外部速率限制约束，而工具执行受本地系统资源约束。

---

## 6. Genesis与传统演化算法的比较

### 6.1 根本差异

虽然Genesis从演化计算中汲取灵感，但它在几个关键维度上与传统演化算法（EA）根本不同：

| 维度 | 传统EA | Genesis |
|------|--------|---------|
| **表示** | 扁平编码（位串、实值向量） | 带有语义节点的层次化上下文树 |
| **搜索空间** | 固定维度参数空间 | 无界的架构结构树 |
| **变异算子** | 数学的（编码上的交叉、突变） | LLM驱动的语义合成 |
| **选择** | 适应度比例或基于排名 | 基于新颖性 + 架构一致性约束 |
| **结构** | 个体线性种群 | 树状结构、递归分解 |
| **收敛** | 适应度收敛到最优 | 对架构一致性的不动点收敛 |
| **算子** | 领域无关、语法层面 | 领域感知、语义层面（通过LLM） |

**1. 树状演化 vs. 扁平种群：**
传统EA演化扁平的个体种群，每个个体是表示为固定长度编码的完整候选解。Genesis相反，演化一棵*智能体树*，递归地分解问题。每个智能体独立地演化其局部子树，父智能体协调集成。这镜像了复杂有机体如何发育：不是作为扁平基因组，而是作为层次化分化过程，其中每个细胞根据其在发育树中的位置而特化。

**2. 递归展开 vs. 世代迭代：**
传统EA在离散世代上迭代：评估所有个体 → 选择 → 变异 → 替换。Genesis使用**递归展开**：根节点处的智能体将其目标分解为子目标，每个子代进一步分解，以此类推直到到达叶级任务。这更接近递归函数求值，而非基于种群的优化。"世代"概念被递归委托的深度所取代。

**3. 不动点收敛 vs. 适应度优化：**
传统EA在种群的平均适应度稳定于最优附近时收敛。Genesis在上下文树达到**不动点**时收敛——即进一步智能体迭代不产生功能性API表面变更的状态。这类似于指称语义中的不动点语义或迭代方程求解器的收敛。收敛断路器（仅基于功能变更的评估、硬性迭代限制）保证此过程终止。

**4. LLM作为语义变异算子：**
在传统EA中，交叉和突变是编码上的语法操作——它们不理解编码*意味着*什么。在Genesis的复杂演化模式中，LLM作为变异算子，执行**语义交叉**（从一个领域提取核心逻辑并将其结构应用于另一个领域）和**语义突变**（在理解其含义的情况下修改逻辑）。这将盲目搜索转变为引导式探索。

**5. 新颖性搜索与质量多样性：**
Genesis的复杂模式融合了新颖性搜索和质量多样性文献的洞见。它不是优化向单一适应度峰值，而是维护一个MAP-Elites档案来保留多样化的行为策略。这特别适合最优方法未知的开放式问题，因为它确保系统探索解空间的广阔区域，而非过早收敛。

### 6.2 概念定位

Genesis可以被理解为**发育演化系统**——弥合演化计算与发育生物学之间的差距。在生物学中，基因型（DNA）不直接指定表型（有机体）；相反，发育过程读取基因型并通过细胞分裂、分化和形态发生产生有机体。类似地，在Genesis中：

- **基因型**是用户提示、上下文树结构和Git历史的组合。
- **发育过程**是递归智能体委托树——每个智能体根据其节点位置和目标"分化"。
- **表型**是最终的代码库。

这种发育视角解释了为什么Genesis能够产生架构一致的结果：上下文树提供位置信息（类似于生物学中的形态发生素梯度）来引导每个智能体的特化，而空间契约确保每个智能体的贡献与整体协调地集成。

---

## 7. Genesis与传统编程智能体的比较

### 7.1 架构差异

基于LLM的编程智能体领域快速扩展，Claude Code、GitHub Copilot Workspace、Cursor和Aider等工具获得了广泛采用。Genesis在几个根本方面与这些不同：

**1. 无状态智能体 vs. 有状态会话：**

传统编程智能体（如Claude Code）作为单一的有状态对话运行。智能体加载上下文、进行修改并迭代——所有这些都在一个连续会话中。智能体的"记忆"是对话历史，单调增长。

Genesis智能体是**无状态函数**。智能体的状态完全由`{node_path, base_commit, current_commit}`捕获。调用之间不携带对话历史——只有空间上下文（上下文树）和时间上下文（Git历史）持久化。这意味着：
- 智能体可以被平凡地并行化（无共享可变状态）
- 崩溃完全可恢复（从最后提交重新分发）
- 上下文不会累积超过单个智能体的会话

**2. 递归分解 vs. 单体上下文：**

传统智能体面临硬性可扩展性上限：整个相关代码库上下文必须适合LLM的上下文窗口。随着项目增长，智能体要么遗漏重要上下文（质量下降），要么超出窗口（失败）。

Genesis通过**具有上下文隔离的递归分解**解决此问题。每个智能体仅在其节点范围内操作，只看到：
- 继承的上下文树路径（轻量级、结构化）
- 分配节点内的文件
- 已完成子智能体的结果（压缩摘要，而非完整对话）

子智能体的上下文足迹不计入父智能体的限制。这使得能够处理**任意大的代码库**——递归委托的深度随项目的架构深度扩展，而非随其总大小。

**3. 空间契约强制执行 vs. 无约束编辑：**

传统智能体对整个代码库有不受限制的访问权。被要求修复`src/auth/`中bug的智能体如果认为必要，也可能修改`src/db/`或`src/api/`。这可能导致架构违规和意外的副作用。

Genesis强制执行**空间契约**：被分配到`src/auth/`的智能体只能修改`src/auth/`及其后代内的文件。写权限是层次化范围的，不能升级。这将代码库从无差别的blob转变为具有明确边界的结构化空间。

**4. 系统发育演化 vs. 线性编辑：**

传统智能体线性工作：进行修改、用户审查、重复过程。没有分支、并行探索或选择性合并的概念。

Genesis使用**系统发育DAG**：智能体从特定提交分支、独立探索、成功分支被选择性合并。这实现了：
- 多种方法的**并行探索**
- **部分进步接受**——修复一个bug的分支即使其他bug仍然存在也是有价值的
- **时间回滚**——任何智能体可以检查或从任何历史提交分支
- **二分式调试**——在不同提交处生成智能体以识别回归何时引入

**5. 架构感知 vs. 扁平文件感知：**

传统智能体将代码库感知为扁平的文件集合。它们通过探索（搜索、读取文件）发现结构，这消耗上下文窗口容量且本质上不完整。

Genesis通过上下文树提供**继承的架构上下文**。`src/auth/oauth/`处的智能体自动知道：
- `src/auth/`做什么（从其CONTEXT.md）
- 整个系统做什么（从根CONTEXT.md）
- 在哪里委托工作（从路由表）
- 适用什么约束（从每一级的约束）

这种架构感知是**结构化的，非发现的**——它作为智能体初始化的一部分被继承，而非通过昂贵的探索推导。此外，由于继承的上下文被结构化为前缀树，共享的祖先令牌最大化了KV缓存复用，使推理远比扁平上下文方法廉价——在后者中，每个智能体都必须从头重新处理整个代码库。而且，由于智能体在工作时将其发现持久化到CONTEXT.md中，上下文本身随着时间的推移积累智慧——使系统真正具有自我改进性，而不仅仅是自我执行。

### 7.2 总结比较表

| 特性 | 传统编程智能体 | Genesis |
|------|-------------|---------|
| 状态模型 | 有状态会话 | 无状态函数 |
| 可扩展性 | 受上下文窗口限制 | 无界（递归分解） |
| 架构感知 | 通过探索发现 | 通过上下文树继承 |
| 代码库感知 | 扁平文件 | 层次化语义树 |
| 编辑范围 | 无约束 | 空间范围限定并强制执行 |
| 演化模型 | 线性编辑 | 带分支的系统发育DAG |
| 并行性 | 有限（单一会话） | 原生（工作树池+子智能体） |
| 崩溃恢复 | 依赖会话 | 完全可恢复（基于提交） |
| 时间导航 | 仅当前状态 | 历史中的任何提交 |
| 质量保证 | 人工审查 | 自动评估+空间契约 |

---

## 8. 其他设计特性

### 8.1 动态技能系统

Genesis包含一个**动态技能系统**，无需修改框架源码即可实现项目特定的自动化。技能是定义为带有YAML前置元数据（名称、描述、参数）和可执行体的markdown文件的自定义工具。它们在运行时作为LLM可调用工具加载。

在架构上，技能遵循与CONTEXT.md**完全相同的层次化上下文设计模式**。技能是**全局定义**但按上下文树节点**层次化启用**的——每个CONTEXT.md可以指定在该级别激活哪些技能，技能在树中向下继承，正如上下文契约一样。这一区别**不是架构上的**：技能并不引入新的设计范式。唯一的区别在于其**用途**。CONTEXT.md存储的是结构化和架构化的契约（意图、API表面、约束、路由），而技能则专门用于存储更复杂的、过程性的**经验**——智能体学到的可重用策略、工作流和操作知识。换言之，技能扩展了CONTEXT.md已经使用的相同层次化上下文继承机制，但专门用于捕获复杂的经验性知识，而非结构化契约。

**SkillExtractor**智能体自动分析已完成的工作，将可重用的知识蒸馏为新技能，创建一个自我改进的系统，其中成功的策略被捕获以供未来智能体使用。这镜像了演化系统中*遗传记忆*的概念——成功的适应性被编码并由后代继承。

### 8.2 多仓库支持

Genesis支持通过绝对路径引用外部仓库（"外部仓库"）。这使得跨仓库任务成为可能，例如：
- 将代码库从一种语言/框架移植到另一种
- 在现代化过程中引用遗留实现
- 协调多个相关仓库的变更

外部仓库在阶段初始化时注册并按智能体跟踪。为维护安全性，外部仓库中只允许只读调查——有写能力的智能体不能修改外部代码库。

### 8.3 多平台沙箱化

所有LLM生成的代码执行使用平台适当的机制进行沙箱化：
- **Linux：** `systemd-run`，具有严格的资源限制（CPU、内存、系统调用上限）、只读主机文件系统访问，且仅对分配的工作树有读写权限。
- **macOS：** `sandbox-exec`，具有文件系统隔离配置。
- **Windows：** 直接执行（沙箱化能力有限）。

这确保即使LLM生成恶意或有缺陷的代码，爆炸半径也仅限于智能体的工作树，不能影响主机系统。

### 8.4 上下文压缩

当智能体的总令牌数超过可配置阈值时，框架自动压缩聊天历史。这种压缩保留基本信息（做出的决策、修改的文件、关键发现），同时丢弃冗长的中间输出。这允许单个智能体在其节点内处理复杂任务而不会达到硬性上下文限制，同时仍然维护无状态原则——压缩的上下文是瞬态的，在智能体完成时被丢弃。

### 8.5 委托提示

当智能体重复编辑子目录（低于其分配节点）中的文件时，框架跟踪这些写操作。超过阈值（默认：对同一子目录5次写入）后，工具输出中会附加一个温和的提示，建议智能体为该子树生成子智能体。这鼓励正确的层次化分解而不强制执行——在子目录中进行快速、一次性编辑的智能体不会被中断，但实际上"居住"在子目录中的智能体会被引导走向正确的委托。

---

## 9. 实现技术

Genesis使用**Elixir/OTP**实现，选择它是因为几个与框架设计一致的属性：

- **Actor模型并发：** Elixir的轻量级进程和消息传递模型自然地镜像无状态智能体设计。每个智能体作为隔离进程运行，调度器通过消息传递协调它们。
- **容错性：** OTP的监督树提供崩溃恢复和重试逻辑——这对于LLM API调用可能失败和智能体可能崩溃的系统至关重要。
- **模式匹配与不可变性：** Elixir的函数式范式强制不可变性，防止了困扰面向对象智能体实现的共享状态错误。

版本控制完全通过**Git CLI**处理（通过薄适配器），刻意避免libgit2绑定以最小化复杂性并最大化可调试性。

系统使用**三级配置**层次结构：应用默认值 → 用户配置（`~/.config/evogit/config.toml`，XDG兼容） → 会话级运行时覆盖（通过CLI标志或仪表盘设置）。这确保了合理的默认值，同时允许完全的用户自定义。

---

## 10. 结论

EvoX Genesis代表了一种自主软件开发的全新方法，综合了演化计算、发育生物学和层次化软件架构的洞见。其关键贡献包括：

1. **双维度架构** ——将空间上下文树与时间系统发育DAG相交，为任何演化点上的任何智能体提供完整的状态规范。

2. **无状态智能体模型** ——智能体作为`{commit, node_path} × objective`上的纯函数，通过具有上下文隔离的递归分解实现无界可扩展性。

3. **空间契约强制执行** ——层次化权限范围限定，将架构文档转变为主动的强制执行机制。

4. **多模态演化** ——同时支持自顶向下规划（简单模式）和基于新颖性搜索与质量多样性的自底向上（复杂模式），兼顾明确定义和开放式任务。

5. **LLM作为语义变异算子** ——利用LLM的语义理解在领域边界间执行有意义的交叉和突变，实现算法意外发现。

6. **自我演化的上下文树** ——层次化上下文不是静态文档，而是智能体既读取又更新的活的制品，随时间积累智慧。这使系统真正实现自我演化：指导智能体行为的知识通过使用而改进，在结构与能动性之间创造正向反馈循环。

这些设计选择使Genesis不仅仅是一个编程助手，而是一个**演化式软件开发框架**——它将软件创建视为一个由架构契约指导、由语义AI算子驱动的层次化、递归的演化过程。该框架扩展到任意大代码库的能力、从任何故障中恢复的能力，以及通过定向规划和开放式新颖性搜索探索解空间的能力，使其成为自主软件工程领域的独特贡献。

---

*This document serves as the technical foundation for academic writing about the EvoX Genesis system. It covers design-level concepts without code-level implementation details.*
