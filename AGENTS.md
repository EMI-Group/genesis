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

EvoGit 1.0 is a decentralized, evolutionary software development framework that supersedes the original EvoGit approach. While the original paper focused on the **Temporal Dimension** (a phylogenetic graph of code versions), it lacked structural awareness, treating codebases as flat collections of files.
EvoGit 1.0 introduces the **Spatial Dimension**—a hierarchical understanding of the codebase. By treating a repository as a semantic tree of "Context Nodes," the system can decompose complex architectural tasks into manageable local evolutions.

## **2. Core Concepts**

The system operates on the intersection of two dimensions:

### **2.1 The Spatial Dimension: "The Context Tree"**

The codebase is structured as a recursive tree where every node (directory or file) has a specific context.

* **Nodes:** A node represents a hierarchy level. It can be a **Directory Node** (structural) or a **File Node** (leaf/implementation).
* **Context Contract:**
  * Every Directory Node MUST contain a file named CONTEXT.md. This file acts as the explicit schema for that hierarchy level, strictly defining its **Intent** (purpose), its **API Surface** (exports), and its **Constraints** (rules for children).
  * Every code file must include a header comment / module comment or similar that defines its purpose and any relevant constraints.
  * The context from the parent node is **inherited** by all child nodes, ensuring alignment with high-level goals, thus forming a **Contextual Hierarchy**.
* **Leaf Nodes:** Source code files (e.g., user.ex, utils.py) are leaf nodes. They do not contain CONTEXT.md; their content is the implementation of their parent's context.

### **2.2 The Temporal Dimension: "The Phylogenetic Graph"**

We retain the original EvoGit core: code evolves through a Directed Acyclic Graph (DAG) of Git commits.

* **Strict Partial Order (**$v\_{new} \> v\_{old}$**):** Evolution is directional. A child commit is accepted *if and only if* it is measurably "better" than its parent.
* **Definition of "Better":** Unlike traditional CI/CD which demands a "Green Build" (passing all tests), EvoGit accepts partial progress. A version is better if:
  * It passes *more* tests than the ancestor.
  * It implements a requested feature (verified by an LLM Judge).
  * It fixes a specific bug, even if other parts of the system are still broken.
* **Immutable History:** Git commits serve as the immutable record of this evolutionary process.

## **3. The Agent Model**

In EvoGit 1.0, an Agent is not a persistent entity but a **stateless function**.

### **3.1 Definition**

An agent is a process that executes the following functional transformation:
$$NewState \= Agent(State, Objective)$$

### **3.2 State & Input**

* **State:** A tuple {commit_sha, node_path}.
  * commit_sha: The specific point in the temporal timeline the agent is branching from.
  * node_path: The specific location in the spatial hierarchy the agent is allowed to modify.
* **Objective:** A string input describing the task (e.g., "Fix the race condition in the worker pool" or "Implement the User schema").

### **3.3 Context Construction**

When an agent runs, it constructs its "World View" dynamically:

1. **Local Context:** Reads CONTEXT.md (or file content) at node_path.
2. **Ancestral Context:** Reads CONTEXT.md of the parent, grandparent, up to the root. This ensures the agent aligns with high-level architectural goals.
3. **Siblings:** Explicit sibling context is **not** necessary.

## **4. Runtime Process**

The system runs in two distinct stages.

### **Stage 1: Genesis (Creation Phase)**

*Goal: Recursively generate the repository skeleton.*

1. **Initialization:** User provides a high-level prompt on how to build the project, what is the goal of the project etc, and initialize the git repository and several worktrees if not already initialized.
2. **Planning:** Inside the working directory Agent creates the context defining the architecture of that level based on the user's instructions and the context inherited from parent nodes. For directories, this is a CONTEXT.md file. For files, this is a header comment or module comment. The planning includes:
   * Defining the Intent of the directory / file.
   * Specifying the API Surface (what modules/files it will contain), and a rough outline of the file structures.
   * Outlining Constraints for child nodes.
3. **Realization:** Given the newly created context, the Agent:
   * For directories, the agent will create the next level of empty subdirectories and files as specified in the context (CONTEXT.md).
   * For files, the agent will generate the full implementation code that satisfies the context (header comment or module comment).
4. **Recursion:** For each child node (directory or file), the system spawns a new Agent instance, running from step 2.

### **Stage 2: Optimization (The Evolutionary Loop)**

*Goal: Fix bugs, optimize performance, or add features.*
This phase uses a **Diagnosis -> Dispatch -> Evolution -> Merge** cycle.

#### **Step A: Diagnosis & Hypothesis**

An **Analyst Agent** (or a human operator) analyzes the current codebase, execution logs, or error reports to identify a weakness (e.g., "Login is slow"). It proposes potential locations (node_path) that might be responsible.

#### **Step B: Strategy Selection**

The system checks the Analyst's output:

1. **High Certainty:** If the Analyst identifies a specific file (e.g., "The SQL query in auth.py is missing an index"), the system dispatches a **Single Agent** to that node.
2. **Low Certainty (Random Credit Assignment):** If the cause is ambiguous (e.g., "It could be the database, or the API handler, or the frontend cache"), the system triggers **Random Credit Assignment**.
   * It dispatches $N$ agents in parallel.
   * Each agent targets a different suspected node_path (different layers of the hierarchy).

#### **Step C: Execution (Parallel Evolution)**

Each dispatched agent:

1. **Forks:** Find a unoccupied worktree, checkout the commit in detached HEAD state.
2. **Acts:** Calls EvoGit.Agent.Generalist to modify files within its node_path to satisfy the objective.
3. **Commits:** Saves the changes by creating a new commit in the worktree.

#### **Step D: Pre-Filtering (Sanity Check)**

Before merging, the system runs a basic validation (Step D from the previous design) to discard completely broken branches. Branches that fail to compile or introduce regression are pruned immediately.

#### **Step E: Iterative Merge & Resolution**

Instead of simply picking one winner, the system attempts to synthesize the best traits of the remaining branches.

1. **Reduction Loop:** The system takes the surviving $N$ branches and iteratively reduces them to a target count $M$ (default $M=2$).
2. **Pairwise Merge:** In each iteration, two branches are selected.
3. **The Merge Agent:** An Agent is spawned to resolve the merge. It inspects the diffs of Branch A and Branch B against the Base.
   * **Inspect:** The agent analyzes the semantic intent of both changes.
   * **Resolve:** It decides to either:
     * **Synergize:** Combine non-conflicting, beneficial features from both (taking the "best of both worlds").
     * **Select:** If changes conflict logically, pick the superior implementation based on the original objective.
   * **Commit:** A new merged branch is created.
4. This repeats until only $M$ evolved branches remain.

#### **Step F: Human Finalization**

The system presents a final lineup of $M+1$ versions to the user:

1. **The Candidates:** The $M$ evolved/merged branches.
2. **The Baseline:** The original version (before any changes).
3. **Decision:** The human reviews the diffs/logs and selects the winner to become the new commit.

## **5. Implementation Guidelines**

### **5.1 Tech Stack**

* **Main Program:** **Elixir**. Chosen for its robust concurrency (OTP), fault tolerance, and actor model which maps perfectly to independent Agents.
* **Version Control:** **Git**. use the git command line.

### **5.3 Git Integration Details**

To ensure strict isolation between agents running in parallel:

1. **Never modify the main checkout.**
2. **Worktrees:** Every agent action sequence happens in:
   .evogit/worktrees/worker_<i>/
3. **Lifecycle:**
   A pool manager keeps track of N available worker resources, that is N available worktree slots.

   When an agent is dispatched:
   * Agent performs edits in that worktree.
   * git commit -am "Agent: <objective>"
   * Attach other information as git notes for traceability.

### **5.4 CLI Interface**

The evogit is used as a cli tool, so it should provide necessary commands to run the whole system.

### **5.5 Other Considerations**

- Json library: By default, please use `JSON`, since elixir 1.18, JSON is included in the standard library, it uses the same API as `Jason`, but better. Use `Jason` only if you need to do pretty printing of JSON, since `JSON` does not support that.
- Logging: use `Logger` module from elixir standard library, and log at appropriate levels (debug, info, warn, error) depending on the importance of the message.
- Sandbox: the project come with a simple sandbox environment for running tools for the LLM. Specifically, it uses systemd-run to create a sandboxed environment read-write access to the codebase path, but read-only access to the rest of the system, and with limited CPU, memory resources and limited system calls. This is to prevent malicious or buggy code from doing harm to the system. Please note that this is a simple sandbox to prevent misbehaving commands from doing too much damage, but it is not a full security sandbox that can prevent malicious agents.
