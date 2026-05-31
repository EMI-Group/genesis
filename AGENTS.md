# **EvoGit 1.0 Design Specification**

## **1. Introduction**

EvoGit 1.0 is a decentralized, evolutionary software development framework. While the original EvoGit approach focused purely on the **Temporal Dimension** (a phylogenetic graph of code versions), it lacked structural awareness, treating codebases as flat collections of files.

EvoGit 1.0 introduces the **Spatial Dimension**—a hierarchical understanding of the codebase represented as a semantic tree. By intersecting these two dimensions, the system decomposes complex architectural tasks into manageable local evolutions.

Crucially, **Agents are stateless functions**. All persistent memory exists either in the spatial dimension (the context tree) or the temporal dimension (the Git history). Agents can be invoked with any state across these dimensions to perform a transformation, eliminating memory corruption issues and enabling seamless state rollbacks and parallelization.

---

## **2. The Dual-Dimension Architecture**

### **2.1 The Spatial Dimension: "The Context Tree"**
The codebase is a recursive tree where every node (directory or file) maintains a specific, inherited context.

* **Nodes:** Represent a hierarchy level as either a `Directory Node` (structural) or a `File Node` (leaf/implementation). Nodes contain a path, context rules, and content.
* **The Spatial Contract (Directory):** Every `Directory Node` *must* contain a `CONTEXT.md` file. This file is not treated as a normal code file within the Git repository. It is conceptually bound to the directory as an intrinsic attribute (similar to an `xattr`) acting as the directory's schema and routing table. It defines two things:
  1. **Documentation:** **Intent**, **API Surface**, and **Constraints** — the directory's purpose, what it exposes, and the rules for code within it.
  2. **Routing Table:** A mapping of responsibility areas to child subdirectories, enabling parent agents to determine which subdirectory owns which domain/module/feature. This is represented as a simple markdown list (e.g., `* `src/auth/` → Authentication & authorization logic`). The routing table allows agents to efficiently delegate work to the correct child node without needing to investigate the entire subtree.
* **The Boundary of Explicit Context (File Level):** While a single code file technically contains its own internal hierarchy of context (module-level docstrings, class/function docstrings, and inline comments), EvoGit 1.0 **does not explicitly model or enforce this sub-file context**. Modern LLMs natively excel at comprehending implicit, file-level context from standard code structures. Therefore, the formal, system-managed Context Hierarchy applies only down to the directory level. Once an agent targets a `File Node`, it relies entirely on the LLM's natural code comprehension to navigate the file's internal logic.
* **Contextual Inheritance:** Agents dynamically build their "World View" by inheriting context top-down. For `src/foo/bar.py`, the agent aggregates the explicit, system-managed context from the Root `CONTEXT.md` $\rightarrow$ `src/ CONTEXT.md` $\rightarrow$ `src/foo/ CONTEXT.md`, and then relies on its innate abilities to parse `bar.py`'s internal code comments.

### **2.2 The Temporal Dimension: "The Phylogenetic Graph"**
Code evolves through a Directed Acyclic Graph (DAG) of immutable Git commits.

* **Directional Evolution:** ($v_{new} > v_{old}$) A child commit is accepted *if and only if* it is measurably "better" than its parent.
* **Partial Progress Acceptance:** Unlike traditional CI/CD requiring a "Green Build," EvoGit accepts incremental improvements. A version is accepted if it passes more tests, implements a feature, or improves readability—even if other system parts remain broken.
* **Evaluation Ranges:** Neighboring commits are loosely evaluated (diff inspection, basic tests) to allow rapid progress. Major versions or tags are strictly evaluated (full test suites, metrics) to ensure systemic improvement.

---

## **3. The Stateless Agent Model**

In EvoGit 1.0, Agents do not maintain long-term memory. They are transient processes utilizing short-term session memory, relying entirely on the Context Tree and Phylogenetic Graph for historical and structural awareness.

### **3.1 Definition & State**
An agent executes a functional transformation defined as:
$$NewState = Agent(State, Objective)$$

The `State` is defined by the following attributes:
* **Spatial State:** The specific node path in the Context Tree where the agent is authorized to operate (e.g., `src/foo/`).
* **Temporal State (Base Commit):** The commit SHA the agent branches from.
* **Temporal State (Current Commit):** The commit SHA the agent is currently working on (initially matches the Base Commit).
* **Objective:** A natural language directive (e.g., "Implement the User schema").

### **3.2 SubAgent Delegation**
To prevent context bloat, agents recursively decompose tasks. A top-level agent spawns subagents with distinct `State` and `Objective` parameters to handle specific modules. Subagents return text results, diff stats, and auto-generated commit SHAs to the parent. Their context footprint does *not* count against the parent's session limits.

### **3.3 Execution Constraints**
* **Session Limits:** Agents possess a strict maximum number of iterative loops.
* **Warning Triggers:** At 50% and 80% of their session limit, agents receive system prompts urging them to report back.
* **Hard Termination:** Upon hitting the limit, the agent must yield to the parent, which evaluates the progress and dictates the next step.

### **3.4 Worktree Interactions & Auto-Commits**
Agents run in isolated Git worktrees and must maintain clean states:
* **Pre-Delegation Cleanliness:** Before calling a subagent, a parent agent *must* commit any pending changes it has made.
* **Completion Cleanliness:** Upon finishing a task, agents must commit their final changes.
* **Auto-Commit Fallback:** If an agent fails to commit in either scenario, the system automatically commits the changes using `Agent: <objective> (auto-commit)`, discarding `.gitignore` files. This guarantees that an agent can be put to sleep and cleanly resurrected later using just its commit SHA and node path.

---

## **4. Runtime Execution Phases**

### **4.1 Phase 1: Genesis (Bootstrapping)**
Initialize the Context Tree and Phylogenetic Graph, starting from either an existing codebase or a blank slate.

**Mode A: Existing Codebase**
* **Root Initialization:** The system spawns an investigator agent at the repository root on the latest commit.
* **Recursive Analysis:** The agent spawns subagents for child directories/files to extract existing context and build the semantic tree structure. *(Note: File-level extraction is minimal, relying mostly on existing code comments).*
* **Fixed Point Convergence:** The parent agent aggregates the context. If discrepancies exist, it spawns subagents to modify the child nodes. This loop repeats until a "fixed point" is reached.
    * **Convergence Circuit Breaker:** To prevent infinite loops of subjective semantic tweaking by the LLM, agents are strictly instructed to evaluate context changes based *only* on functional API surface modifications, not phrasing. Additionally, the system enforces a hard limit on iterations (e.g., maximum 3 passes per node) to guarantee mathematical termination.

**Mode B: New Codebase**
* **Root Initialization:** An agent interprets the user's prompt at the root node and drafts the initial architectural plan in the root `CONTEXT.md`.
* **Recursive Realization:** For each planned submodule, spawn subagents to initialize the corresponding child nodes and populate their `CONTEXT.md` files.
* **Fixed Point Convergence:** Identical to Mode A, utilizing the same Convergence Circuit Breaker to ensure the generated structure finalizes efficiently.

### **4.2 Phase 2: Evolution**
Mutate the codebase based on task ambiguity.

* **Mode A: Simple Evolution (Top-Down):** Used for clear tasks (e.g., fixing reproducible bugs). The top-level agent (generalist) maps the spatial context, then analyzes the objective to identify the steps needed to achieve it. It can spawn codebase_investigator subagents to gather additional context if needed. Then it handle the editing of files within their assigned node level and spawns generalist subagents to execute each step in child nodes.
    * **Recursive Realization:** The steps are also executed recursively, meaning the agents should only be editing / investigating files within their assigned node level, and delegate to subagents for any child nodes.
    * **Fixed Point Convergence:** The parent agent evaluates the results of its subagents. If the objective is not met, it spawns new subagents to continue iterating until the task is complete or the session limit is reached.
* **Mode B: Open-Ended Evolution (Bottom-Up):** Used for open-ended tasks requiring exploration and creative problem-solving (e.g., system-wide optimization, algorithm discovery). Instead of planning and delegating, the system runs an evolutionary loop powered by novelty search and quality diversity.
    * **Core Philosophy — Algorithmic Serendipity:** The system is an engine for discovering unexpected solutions. It leverages Open-Ended Evolution and Quality Diversity, maintaining a chaotic repository of cross-domain code (the **Entropy Pool**) and using the LLM as a semantic bridge to achieve **exaptation** — co-opting code from one domain to solve problems in entirely different domains.
    * **The Entropy Pool:** A diverse collection of code fragments drawn from unrelated paradigms (physics engines, game loops, data pipelines, graph algorithms, etc.). The LLM's semantic understanding recognizes abstract logic patterns across these disjointed pieces (e.g., "collision detection" is fundamentally "boundary comparison").
    * **Novelty Search Selection:** Fragments are NOT selected based on fitness or proximity to the objective. Instead, they are selected based on how *differently* they behave compared to the rest of the pool — measured via structural features (AST analysis) and behavioral profiles (LLM classification).
    * **LLM Synthesis (Crossover/Mutation):** The LLM acts as the crossover operator, semantically fusing two distinct, novel fragments. It extracts core logic from one domain and applies its structure to another, generating new functional code.
    * **Quality Diversity (MAP-Elites):** A grid archive preserves diverse approaches. Each cell maps a behavior descriptor (complexity × paradigm) to its most novel fragment. This ensures that weird, inefficient, but highly unique code is preserved as valuable genetic material.
    * **The Algorithmic Loop:**
      1. **Selection:** Pull novel fragments from the Entropy Pool based on novelty scores.
      2. **Synthesis:** LLM semantically merges selected parents into new child fragments.
      3. **Evaluation:** Run child code in sandbox, profile behavior, calculate novelty score.
      4. **Replacement:** If the child is novel, insert into the pool and evict the most redundant fragment.
    * **Solution Synthesis:** After the evolution converges (or reaches max generations), the system collects the most novel and diverse fragments, then asks the LLM to synthesize a final coherent solution informed by the evolved genetic material. This solution is applied to the codebase via a Manager agent.
    * **Configuration:** Pool size, generations, crossover/mutation rates, and stagnation limits are configurable via `config.toml` `[evolution]` section or CLI flags (`--pool-size`, `--generations`, `--crossover-rate`, `--mutation-rate`).
* **Mode C: Recursive Realization:** This mode is strictly for realizing the whole codebase after Genesis mode B (new codebase). After the genesis mode B finishes, the repo contains full context hierarchy but no actual code. This phases is basically the same as Gensis mode A, except that the objective is to realize the codebase based on the context hierarchy.

Please note that "simple" doesn't necessarily mean the code change is small or trivial, and "complex" doesn't necessarily mean the code change is large. The distinction is based on the clarity and the understanding of the task rather than its size. For example:
* A "simple" evolution could involve a significant code change if the task is well-defined and the path to the solution is clear, e.g., build a static website using a specific framework that has feature A, B and C, and the agent can decompose the task into clear steps and execute them. Therefore, even if it requires thousands or tens of thousands of lines of code, it is still considered "simple".
* A "complex" evolution could involve a small code change if the task is ambiguous and requires exploration, e.g., optimize the latency of this algorithm, where neither the agent nor the user know how to achieve this, and the agent needs to experiment with different approaches and learn from the results. Maybe there exists a one-line change that can significantly improve the performance, but we don't know what it is.

---

## **5. Implementation Specifications**

### **5.1 Core Technology**
* **Runtime:** **Elixir**. Selected for OTP concurrency, lightweight processes, fault tolerance, and its actor model perfectly mirroring our stateless agent design.
* **Version Control:** **Git CLI**. The libgit2 bindings are explicitly avoided to minimize complexity, dependencies, and to ease debugging.

### **5.2 The Agent Scheduler & Git Isolation**
EvoGit manages execution through an internal **Agent Scheduler**, analogous to OS process or thread scheduling. The constrained system resource is a fixed pool of $N$ `git worktree` slots located at `.evogit/worktrees/worker_<i>/`.

1. **Immutability:** The main user checkout is *never* directly modified by an agent.
2. **Execution Lifecycle:** All agents are initially spawned by the scheduler into a `waiting` state. When a worktree slot becomes available, the scheduler assigns it to a waiting agent, **checks out the exact `current_commit` (not the `base_commit`)** specified in the agent's temporal state, and begins execution. This ensures resuming agents do not overwrite unyielded progress.
3. **Cooperative Multitasking (Yielding):** Worktrees cannot be locked idle. When an agent needs to call subagents, it must *yield* execution.
    * Before yielding, the agent must clean its workspace (committing any pending changes, or relying on the auto-commit fallback detailed in Section 3.4).
    * The parent agent is then transitioned back to the `waiting` state.
    * The worktree is instantly released back to the scheduler to execute other queued agents (including the newly spawned subagents).
    * Once the subagents complete, the parent agent is re-queued for a worktree to resume its evaluation.
4. **Data Tracing:** Agents commit semantic messages (`Agent: <objective>`) and attach metadata (Context, LLM reasoning) via `git notes`.
5. **Depth Limits:** The runtime tracks the recursive depth of agent delegation. Upon reaching a configured maximum depth, agents are blocked from spawning further subagents.
6. **Command Restrictions:** Agents are prohibited from executing commands that alter global state or break temporal tracking:
    * **No `push` or `pull`:** Prevents remote modification or conflict ingestion.
    * **No `checkout` or `reset`:** Prevents agents from abandoning their assigned temporal state.
    * **No `rebase`:** History manipulation is strictly reserved for the parent agent evaluating child results.
7. **User Handoff:** Upon completion of a high-level objective, the system alerts the user and runs `git merge --no-commit` into the main directory for human review.

### **5.3 Tooling & Security**
* **JSON Parsing:** Elixir 1.18+ standard `JSON` library is required for speed; `Jason` is permitted only for pretty-printing.
* **Formatting:** `mix format` should be used for all code formatting.
* **Logging:** Elixir standard `Logger` utilizing strict hierarchical levels.
* **Sandboxing:** Code generated by LLMs is jailed using `systemd-run`, granting read/write to the assigned worktree but enforcing strict read-only access to the host OS, with hard CPU, memory, and syscall caps.

### **5.4 Enforcing the Spatial Contract**
The agents are divided into two categories based on their interaction with the Context Tree:
1. Read-Only Agents: These agents can mostly only read files from the repo.
2. Read-Write Agents: These agents can read and write files in the repo.

When spawning subagents, we enforce the following rules:
1. Read-Only Agents can only spawn other Read-Only subagents, and cannot spawn Read-Write subagents. This ensures that if the parent agent is only authorized to read, its subagents cannot perform unauthorized writes.
2. Read-Write Agents can spawn both Read-Only and Read-Write subagents, but the read-write subagents must operate within the same node or child nodes of the parent agent's assigned node. This ensures that if the write permissions cannot be escalated.

Similarly, file operations are also restricted, where agents should only modify files that are within their scoped node. For example, if an agent is assigned to operate on `src/foo/`, it should only modify files within `src/foo/` and its child directories. This will make sure that the agents are respecting the spatial contract and not making unauthorized changes to other parts of the codebase.

---

# Project structure

This project uses an umbrella structure to separate the core runtime from the web-based dashboard interface.

The two main applications are:
1. `evo_git`: The core runtime responsible for agent execution, Git interactions, and the dual-dimension architecture.
2. `evo_dash`: A simple Phoenix LiveView dashboard for visualizing the Context Tree, Phylogenetic Graph, and agent activity in real-time.
