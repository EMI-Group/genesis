# **EvoX Genesis 1.0 Design Specification**

## **1. Introduction**

EvoX Genesis 1.0 is a decentralized, evolutionary software development framework. It models a codebase along two orthogonal dimensions — a **Spatial Dimension** (a hierarchical Context Tree of semantic nodes) and a **Temporal Dimension** (a phylogenetic DAG of immutable Git commits). By intersecting these dimensions, the system decomposes complex architectural tasks into manageable, locally-scoped evolutions carried out by AI agents.

The original EvoGit approach focused purely on the temporal dimension — a phylogenetic graph of code versions — but lacked structural awareness, treating codebases as flat collections of files. Genesis 1.0 introduces the spatial dimension to provide agents with hierarchical architectural context at every level of granularity.

A foundational principle is that **agents are transient functions with session-scoped memory**. All persistent memory exists either in the spatial dimension (the Context Tree) or the temporal dimension (the Git history). An agent can be invoked with any combination of states drawn from these dimensions to perform a transformation. This eliminates memory corruption issues and enables seamless state rollbacks and parallelization.

---

## **2. The Dual-Dimension Architecture**

### **2.1 The Spatial Dimension: "The Context Tree"**

The codebase is modeled as a recursive tree where every node (directory or file) maintains a specific, inherited context.

- **Nodes:** Represent a hierarchy level as either a `Directory Node` (structural) or a `File Node` (leaf/implementation). Nodes contain a path, context rules, and content.
- **The Spatial Contract (Directory):** Every directory node contains a `CONTEXT.md` file. This file is conceptually bound to the directory as an intrinsic attribute (similar to an extended file attribute), acting as the directory's schema and routing table. It defines:
  1. **Documentation:** **Intent**, **API Surface**, and **Constraints** — the directory's purpose, what it exposes, and the rules for code within it.
  2. **Routing Table:** A mapping of responsibility areas to child subdirectories, enabling parent agents to determine which subdirectory owns which domain/module/feature without investigating the subtree.
- **Contextual Inheritance:** Agents dynamically build their "world view" by inheriting context top-down. For `src/foo/bar.py`, the agent aggregates the explicit, system-managed context from Root → `src/` → `src/foo/`, and then relies on the LLM's natural code comprehension to parse `bar.py`'s internal logic.
- **The Boundary of Explicit Context:** The formal, system-managed Context Hierarchy applies down to the directory level. Once an agent targets a file node, it relies entirely on the LLM's innate ability to comprehend implicit, file-level context (docstrings, comments, code structure).

### **2.2 The Temporal Dimension: "The Phylogenetic Graph"**

Code evolves through a Directed Acyclic Graph (DAG) of immutable Git commits.

- **Directional Evolution:** ($v_{new} > v_{old}$) A child commit is accepted if and only if it is measurably "better" than its parent.
- **Partial Progress Acceptance:** Unlike traditional CI/CD requiring a "Green Build," Genesis accepts incremental improvements. A version is accepted if it passes more tests, implements a feature, or improves readability — even if other system parts remain broken.
- **Evaluation Ranges:** Neighboring commits are loosely evaluated (diff inspection, basic tests) to allow rapid progress. Major versions or tags are strictly evaluated (full test suites, metrics) to ensure systemic improvement.

---

## **3. The Transient Agent Model**

Agents do not maintain long-term memory. They are transient processes utilizing short-term session memory, relying entirely on the Context Tree and Phylogenetic Graph for historical and structural awareness.

### **3.1 Definition & State**

An agent executes a functional transformation:
$$NewState = Agent(State, Objective)$$

The `State` is defined by:
- **Spatial State:** The specific node path in the Context Tree where the agent is authorized to operate (e.g., `src/foo/`).
- **Temporal State (Base Commit):** The commit SHA the agent branches from.
- **Temporal State (Current Commit):** The commit SHA the agent is currently working on (initially matches the Base Commit).
- **Objective:** A natural language directive.

### **3.2 SubAgent Delegation**

To prevent context bloat, agents recursively decompose tasks. A parent agent spawns subagents with distinct `State` and `Objective` parameters to handle specific modules. Subagents return text results, diff stats, and auto-generated commit SHAs. Their context footprint does *not* count against the parent's session limits — this is a key property that enables unbounded recursive depth without context window exhaustion.

### **3.3 Agent Taxonomy**

Agents are divided into specialized roles, each with its own system prompt, toolset, and delegation configuration:

| Agent | Role | Type | Key Capabilities |
|-------|------|------|-----------------|
| **Manager** | Gradual improvements, bug fixing, refining | Read-Write | Does NOT do initial implementation; coordinates refinements via subagents |
| **Generalist** | Versatile full-stack agent | Read-Write | Investigates, plans, and implements autonomously |
| **Executor** | Precise, targeted code changes | Read-Write | Focused implementation from well-defined objectives |
| **CodebaseLead** | Greenfield architecture & accountability | Read-Write | Accountable for all code in its node path; directly responsible for architecture only (structure, CONTEXT.md, public API). Delegates implementation to Manager. Uses Executor for design artifacts. 3-phase: architecture & design → implementation delegation → review & accountability |
| **CodebaseInvestigator** | Deep codebase analysis | Read-Only | Read-only investigation; can update CONTEXT.md |
| **ContextExtractor** | Semantic context extraction | Read-Only | Builds CONTEXT.md tree from existing codebases |
| **TaskScheduler** | Execution sequence planning | Read-Only | Transforms objectives into ordered task sequences |
| **GenesisPlanner** | Genesis-stage planning | Read-Only | Dependency-aware execution plans for architecture |
| **Evaluator** | Code change verification | Read-Only | Reviews diffs against objectives; checks quality |
| **SkillExtractor** | Knowledge distillation | Read-Write | Distills reusable knowledge from completed PRs into skills |

### **3.4 Execution Constraints**

- **Session Limits:** Agents possess a strict maximum number of iterative loops (turns).
- **Warning Triggers:** At 50% and 80% of their session limit, agents receive system prompts urging them to report back.
- **Hard Termination:** Upon hitting the limit, the agent yields to the parent, which evaluates progress and dictates next steps.
- **Context Compression:** When total tokens exceed a configurable threshold, the framework automatically compresses chat history to stay within context limits.

### **3.5 Worktree Interactions & Auto-Commits**

Agents run in isolated Git worktrees and must maintain clean states:
- **Pre-Delegation Cleanliness:** Before calling a subagent, a parent agent must commit pending changes.
- **Completion Cleanliness:** Upon finishing a task, agents must commit their final changes.
- **Auto-Commit Fallback:** If an agent fails to commit, the system automatically commits changes. This guarantees that an agent can be put to sleep and cleanly resurrected later using just its commit SHA and node path.

---

## **4. Runtime Execution Phases**

### **4.1 Phase 1: Genesis (Bootstrapping)**

Initialize the Context Tree and Phylogenetic Graph, starting from either an existing codebase or a blank slate.

**Mode A: Existing Codebase**
- A `ContextExtractor` agent at the repository root recursively spawns subagents for child directories to extract existing context and build the semantic tree structure.
- **Fixed Point Convergence:** The parent agent aggregates context. If discrepancies exist, it spawns subagents to modify child nodes. This loop repeats until a fixed point is reached.
- **Convergence Circuit Breaker:** To prevent infinite loops of subjective semantic tweaking, agents evaluate context changes based *only* on functional API surface modifications, not phrasing. A hard iteration limit guarantees termination.

**Mode B: New Codebase (Two-Root-Agent Mode)**
Genesis Mode B spawns TWO sequential root agents sharing a single `task_id`:

1. **Architecture root agent (`CodebaseLead`)**: Interprets the user's prompt at the root node, drafts the initial architectural plan, creates the folder tree with CONTEXT.md files, defines the public API (interfaces, shared types, directory structure), and recursively delegates child directory architecture to `subagent_codebase_lead` subagents. Uses `subagent_executor` for design artifacts (creating files, running init commands). Does NOT implement code — its direct responsibility is architecture only.
2. **Implementation root agent (`Manager`)**: Starts from the architect's final commit. Receives a combined objective (original user prompt + architect's result report). Reviews the established architecture, identifies unimplemented work, and delegates implementation to Executor subagents. Completes the codebase to fulfill the original objective.

Usage/cost tracking is aggregated across both root agents: combined token usage, agent count, and archive records are merged into the final result. Archive records from the architecture phase are cleared from ETS before the implementation phase to prevent double-counting (both agents share the same `task_id`).
- Fixed Point Convergence applies identically, with the same circuit breaker.

### **4.2 Phase 2: Evolution**

Mutate the codebase based on task ambiguity.

**Mode A: Simple Evolution (Top-Down)**
Used for clear, well-defined tasks (e.g., fixing reproducible bugs, adding specified features). A `Manager` agent maps the spatial context, analyzes the objective, and delegates execution to `Executor` subagents in the appropriate child nodes. The recursive decomposition follows the Context Tree structure:
- **Recursive Realization:** Agents only edit/investigate files within their assigned node level and delegate to subagents for child nodes.
- **Fixed Point Convergence:** The parent agent evaluates subagent results. If the objective is not met, it spawns new subagents until the task is complete or the session limit is reached.

---

## **5. Implementation Specifications**

### **5.1 Core Technology**
- **Runtime:** **Elixir/OTP**. Selected for lightweight processes, fault tolerance, and an actor model that naturally mirrors the transient agent design.
- **Version Control:** **Git CLI** (via thin adapter). libgit2 bindings are explicitly avoided to minimize complexity and ease debugging.

### **5.2 The Agent Scheduler & Git Isolation**

Genesis manages execution through an internal **Agent Scheduler**, analogous to OS process scheduling. The constrained system resource is a fixed pool of Git worktree slots.

1. **Immutability:** The main user checkout is never directly modified by an agent.
2. **Execution Lifecycle:** All agents start in a `waiting` state. When a worktree slot becomes available, the scheduler assigns it to a waiting agent, checks out the agent's `current_commit`, and begins execution.
3. **Cooperative Multitasking (Yielding):** Worktrees cannot be locked idle. When an agent needs to call subagents, it must *yield* execution — commit pending changes, transition to `waiting`, and release the worktree for other agents (including the newly spawned subagents). Once subagents complete, the parent is re-queued.
4. **Slot Management:** Two independent slot pools — **LLM slots** (for LLM API calls, with global rate-limit backoff) and **Tool slots** (for tool executions like shell commands). Both use FIFO queuing.
5. **Depth Limits:** The runtime tracks recursive delegation depth. Upon reaching a configured maximum, agents are blocked from spawning further subagents.
6. **Command Restrictions:** Agents are prohibited from `push`, `pull`, `checkout`, `reset`, and `rebase` — preventing global state modification and temporal tracking disruption.
7. **User Handoff:** Upon completion, the system creates an isolated branch and optionally a pull request for human review.

### **5.3 Tooling & Security**
- **Multi-Platform Sandboxing:** Code generated by LLMs is jailed using platform-appropriate mechanisms: `systemd-run` on Linux, `sandbox-exec` on macOS, and direct execution on Windows. The sandbox grants read/write access to the assigned worktree but enforces read-only access to the host OS with resource caps.
- **Tool Library:** Agents have access to a rich toolset including file I/O, ripgrep search, glob matching, shell execution, web search, context management, and git history search.
- **Delegation Hinting:** When an agent repeatedly edits files in a child directory, the framework suggests spawning a subagent for that subtree — encouraging proper hierarchical decomposition.

### **5.4 Enforcing the Spatial Contract**

Agents are divided into two categories:
1. **Read-Only Agents:** Can read files and update CONTEXT.md, but cannot modify code.
2. **Read-Write Agents:** Can read and write all files within their scoped node.

Delegation rules:
1. Read-Only agents can only spawn Read-Only subagents — write permissions cannot be escalated.
2. Read-Write agents can spawn both types, but read-write subagents must operate within the same or child nodes of the parent's assigned node — write scope cannot be escalated beyond the parent's authority.

File operations are similarly restricted: agents may only modify files within their scoped node and its descendants.

### **5.5 Dynamic Skills System**

Skills are **custom tools defined as markdown files** (`.agents/skills/`). Each skill has YAML frontmatter (name, description, parameters) and a body containing an executable bash block. Skills are loaded at runtime as LLM-callable tools, enabling project-specific automation without modifying framework source.

Skills are **globally defined** but **hierarchically enabled** per Context Tree node. Each `CONTEXT.md` may carry a `skill:` list naming active skills. Skills inherit downward: enabling at a parent node makes the skill available to all agents in that subtree.

The **SkillExtractor** agent automatically analyzes completed work and distills reusable knowledge into new skills, creating a self-improving system where successful strategies are captured for future agents.

### **5.6 Multi-Repository Support**

The system supports referencing external repositories ("foreign repos") via absolute paths. This enables cross-repository tasks such as porting codebases, referencing legacy implementations, or coordinating changes across multiple repos. Foreign repos are registered at phase initialization and tracked per-agent. Write-capable agents are not permitted in foreign repos — only read-only investigation is allowed.

### **5.7 Configuration**

A three-level configuration system:
1. **Application defaults** — built-in defaults (no model or username hardcoded).
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant), defining LLM model, scheduler settings, sandbox mode, etc.
3. **Runtime overrides** — session-level overrides via CLI flags or dashboard settings.

Per-project configuration (`genesis.toml`) supports worktree initialization scripts, custom development commands, and foreign repo definitions.

---

## **6. Web Dashboard**

The `evo_dash` application provides a Phoenix LiveView dashboard for real-time visualization and task management:
- **Project-based task management** — launch and monitor genesis/evolution tasks.
- **Agent tree inspector** — visualize the recursive agent hierarchy with live status.
- **Code review interface** — GitHub-style diff viewer with merge/reject actions.
- **Runtime settings** — adjust scheduler/sandbox configuration; GUI editor for config files.
- **Desktop mode** — runs as a native desktop application wrapping the web interface.

---

## **7. Project Structure**

This project uses an umbrella structure to separate the core runtime from the web-based dashboard:

1. **`evo_git`** — Core runtime: agent execution, Git interactions, scheduler, sandboxing, dual-dimension architecture, and CLI.
2. **`evo_dash`** — Phoenix LiveView dashboard: task management, agent tree visualization, code review, and settings.
