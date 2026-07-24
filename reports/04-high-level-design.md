
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
