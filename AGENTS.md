## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- Elixir functions can have default arguments using the `arg \\ default` syntax. Notice that, when editing with regular expressions, the backslash `\` is a special character and must be escaped as `\\` in order to match it literally, and to match double backslashes you must use `\\\\`.
- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Filesystem path handling guidelines

- The standard way is to use absolute paths for the repository path (project path).
- Use relative paths inside the repository (relative to the repo root).
- If not specifically needed, the code should use assertive code that expects the path to follow these rules.

# **EvoGit 1.0 Design Specification**

## **1. Introduction**

EvoGit 1.0 is a decentralized, evolutionary software development framework. While the original EvoGit approach focused purely on the **Temporal Dimension** (a phylogenetic graph of code versions), it lacked structural awareness, treating codebases as flat collections of files.

EvoGit 1.0 introduces the **Spatial Dimension**—a hierarchical understanding of the codebase represented as a semantic tree. By intersecting these two dimensions, the system decomposes complex architectural tasks into manageable local evolutions.

Crucially, **Agents are stateless functions**. All persistent memory exists either in the spatial dimension (the context tree) or the temporal dimension (the Git history). Agents can be invoked with any state across these dimensions to perform a transformation, eliminating memory corruption issues and enabling seamless state rollbacks and parallelization.

---

## **2. The Dual-Dimension Architecture**

### **2.1 The Spatial Dimension: "The Context Tree"**
The codebase is a recursive tree where every node (directory or file) maintains a specific, inherited context.

* **Nodes:** Represent a hierarchy level. They can be a `Directory Node` (structural) or a `File Node` (leaf/implementation).
    * **Path:** Repository location (e.g., `doc/`, `lib/a.py`).
    * **Context:** Semantic rules. Defined by `CONTEXT.md` for directories, and header/module comments for files.
    * **Content:** Child nodes (for directories) or source code (for files).
* **The Spatial Contract:**
    * Every `Directory Node` *must* contain a `CONTEXT.md` file. Crucially, **this file is not treated as a normal file within the Git repository**. Instead, it is conceptually bound to the directory as an intrinsic attribute—functioning much like an extended filesystem attribute (xattr), but implemented as a standard text file so it does not require specialized OS-level `xattr` support. It acts as the directory's schema, defining its **Intent** (purpose), **API Surface** (exports), and **Constraints** (rules for children).
    * Every `File Node` (leaf) *must* include a header/module comment defining its role. Leaf nodes do not contain `CONTEXT.md` files.
* **Contextual Inheritance:** Agents dynamically build their "World View" by inheriting context top-down. For `src/foo/bar.py`, the agent aggregates goals and constraints from the Root `CONTEXT.md` $\rightarrow$ `src/ CONTEXT.md` $\rightarrow$ `src/foo/ CONTEXT.md` $\rightarrow$ `bar.py`'s header.

### **2.2 The Temporal Dimension: "The Phylogenetic Graph"**
Code evolves through a Directed Acyclic Graph (DAG) of immutable Git commits.

* **Directional Evolution ($v_{new} > v_{old}$):** A child commit is accepted *if and only if* it is measurably "better" than its parent.
* **Definition of "Better" (Partial Progress):** Unlike traditional CI/CD requiring a "Green Build," EvoGit accepts incremental improvements. A version is accepted if it passes more tests, implements a specific feature (verified by an LLM Judge), fixes an isolated bug, or improves readability—even if other system parts remain broken.
* **Evaluation Ranges:** * *Short-range (Neighboring Commits):* Loosely evaluated via diff inspection or basic tests to allow rapid, partial progress.
    * *Long-range (Major Versions/Tags):* Strictly evaluated via full test suites and code metrics to ensure overall systemic improvement.

---

## **3. The Stateless Agent Model**

In EvoGit 1.0, Agents do not maintain long-term memory. They are transient processes utilizing only short-term session memory, relying entirely on the Context Tree and Phylogenetic Graph for historical and structural awareness.

### **3.1 Definition & State**
An agent executes a functional transformation defined as:
$$NewState = Agent(State, Objective)$$

* **State:** A `{spatial, temporal}` tuple.
    * `spatial`: The node in the Context Tree where the agent operates, i.e., the directory or file path (e.g., `src/foo/` or `src/foo/bar.py`).
    * `temporal`: The Git commit SHA representing the code version, including two parts:
      * `base_commit`: The commit SHA the agent starts from.
      * `current_commit`: The commit SHA the agent is currently working on (initially the same as `base_commit`).
* **Objective:** A natural language directive (e.g., "Implement the User schema", "Investigate how to use this library").

### **3.2 Sub-Agent Delegation & Parallelism**
To prevent context bloat, agents heavily utilize recursive decomposition. A top-level agent spawns sub-agents with specific `State` and `Objective` parameters to handle individual modules or files.
* Sub-agents operate independently, returning text results, diff stats, and auto-generated commit SHAs to the parent.
* A sub-agent's context footprint does *not* count against the parent agent's session limits.

### **3.3 Execution Constraints (Forcing Micro-Evolutions)**
To guarantee small, reviewable, and incremental improvements, agents operate under strict lifecycle limits:
* **Session Length Limits:** Agents possess a maximum number of iterative loops.
* **Warning Triggers:** At 50% and 80% of their session limit, agents receive system prompts urging them to finalize tasks and report back.
* **Hard Termination:** Upon hitting the limit, the agent must yield to the parent agent, which then evaluates the partial progress and dictates the next evolutionary step.

### **3.4 Worktree Interactions & Git Commits**
The agents run in isolated `git worktree` environments.
1. Each agent starts with a clean checkout of the commit specified in its `State`.
2. Agents need to make sure to keep the worktree clean when calling sub-agents, that is, before calling a sub-agent, the parent agent must commit any changes it has made.
3. Upon completion, agents must commit their changes.

In step 2 and 3, if the agent doesn't commit, the system will automatically commit the changes with a message like `Agent: <objective> (auto-commit)` (except for files ignored by `.gitignore`, those will be discarded). This also ensure that we can put agents to sleep and wake them up later with the same state, as the state is always represented by a commit SHA and a node path.

---

## **4. Runtime Execution Phases**

### **4.1 Phase 1: Genesis (Bootstrapping)**
**Goal:** Recursively generate the repository skeleton based on user prompts and prior knowledge.

1.  **Initialization:** The system ingests the high-level prompt, initializes the Git repo, and provisions worktrees.
2.  **Planning:** Inside the current node, the Agent writes the context (e.g., `CONTEXT.md`), outlining Intent, API Surface, and Constraints for that specific level.
3.  **Realization:** The Agent creates empty subdirectories/files matching the new context (if a directory) or generates source code (if a leaf file).
4.  **Recursion:** The system spawns new Agent instances for every child node created, repeating the process down the tree.

### **4.2 Phase 2: Evolution**
**Goal:** Mutate the codebase from the Genesis skeleton or an existing temporal state. The system dynamically selects an approach based on task ambiguity.

**Mode A: Simple Evolution (Top-Down Execution)**
Used for clear, well-defined tasks (e.g., refactoring a specific module, fixing a reproducible bug, adding docs).
* **Flow:** The top-level agent deploys `investigator` sub-agents to map the necessary spatial context. With a clear map, it outlines a step-by-step plan. It then dispatches `executor` sub-agents to perform the writes, followed by `evaluator` sub-agents to verify the diffs before accepting the changes.

**Mode B: Complex Evolution (Bottom-Up Search)**
Used for ambiguous, open-ended tasks (e.g., system-wide optimization, massive structural refactors). Planning is discarded in favor of parallelized trial-and-error.
* **Flow:** The parent agent defines a "Search Space" of potential solutions. It spawns concurrent sub-agents to test these directions via local file changes. Based on the sub-agents' feedback, the parent prunes failed branches and heavily parallelizes the successful ones.
* **Strategy - Differential Evolution:** The system analyzes a human-optimized "reference" module, extracts the transformation pattern, and applies it sequentially across similar codebase modules, accepting only the permutations that yield improvements.
* **Strategy - Co-evolution:** For interdependent systems (e.g., frontend and backend APIs), the system concurrently mutates both nodes, evaluating the joint state against the high-level objective.

---

## **5. Implementation Specifications**

### **5.1 Core Technology**
* **Runtime:** **Elixir**. Selected for its robust concurrency (OTP), fault tolerance, and actor model, which maps flawlessly to independent, stateless Agents.
* **VCS:** **Git CLI**. Currently we don't use libgit bindings, because the cli provides all necessary functionality and it's easier to debug and maintain. We can consider libgit bindings in the future, but right now we want to minimize complexity and dependencies.

### **5.2 Git Isolation & Worktrees**
To guarantee strict isolation for parallel agent executions:
1.  **Immutability:** The main user checkout is *never* directly modified by an agent.
2.  **Pool Management:** The system maintains a pool of $N$ available `git worktree` slots located at `.evogit/worktrees/worker_<i>/`.
3.  **Agent Lifecycle:** * Agents are dispatched to an available worktree slot.
    * Modifications are committed with semantic messages: `Agent: <objective>`.
    * Metadata (Context, LLM reasoning) is attached via `git notes` for traceability.
4.  **Agent Actions:** Agents can execute most of the Git CLI commands within their worktree, except for certain commands that would affect the global repository state or move the current workspace to a different commit, those commands include:
    * `git push` and `git pull` (to prevent agents from modifying the remote repository or pulling changes that could cause conflicts)
    * `git checkout` and `git reset` (to prevent agents from moving to a different commit than the one they were assigned to)
    * `git rebase` (to prevent agents from rebasing branches, which should be done by the parent agent after evaluating the results of the child agent)
5.  **User Handoff:** Once an evolutionary branch is complete, the user is notified. A `git merge --no-commit` is executed against the main working directory, allowing the user to review and finalize the transaction.

### **5.3 Tooling & Security**
* **JSON Handling:** Utilize Elixir 1.18+'s standard `JSON` library for speed. Only fall back to `Jason` if pretty-printing is explicitly required.
* **Telemetry:** Use Elixir's standard `Logger` with appropriate strict log levels.
* **Sandboxing:** LLM code execution is jailed using `systemd-run`. This grants read/write access to the `.evogit/worktrees/worker_<i>/` path, but enforces strict read-only access to the host OS, alongside hard CPU, memory, and syscall limitations. *(Note: This mitigates buggy scripts, but is not a bulletproof security sandbox against intentionally malicious agents).*
* **Interface:** EvoGit operates entirely as a Command Line Interface (CLI) tool.