# Genesis 1.0

Genesis is a decentralized, evolutionary software development framework powered by AI agents. It treats your codebase as a hierarchical **Context Tree** (spatial dimension) and evolves it through a **Phylogenetic Graph** of Git commits (temporal dimension) — intersecting structural awareness with temporal evolution to achieve architecturally coherent software development.

## Why Genesis?

**Unbounded scale without context limits.** Traditional coding agents hit context window ceilings on large codebases. Genesis solves this through recursive decomposition: each agent operates only within its assigned node, delegating to child agents for subtrees. Subagent context footprints never count against the parent's limits, enabling work on arbitrarily large projects.

**Evolutionary, not just generative.** Unlike one-shot code generators, Genesis evolves code through a phylogenetic DAG of Git commits. Partial progress is accepted — a version that passes more tests or implements one more feature is valued, even if other parts remain broken. This mirrors natural selection: gradual, directional improvement.

**Stateless agents, persistent architecture.** Agents are pure functions with no long-term memory. All structural and historical knowledge lives in the Context Tree and Git history. This means any agent can be instantiated at any point in the codebase's evolution, rolled back, or parallelized without state corruption.

**Two evolution modes.** *Simple mode* handles well-defined tasks through top-down planning and hierarchical delegation. *Complex mode* tackles open-ended problems through bottom-up novelty search with quality diversity (MAP-Elites), using cross-domain code exaptation guided by LLM semantic bridging.

**Built-in safety.** All LLM-generated code runs under platform-appropriate sandboxing (systemd-run on Linux, sandbox-exec on macOS), with strict spatial-contract enforcement preventing unauthorized cross-boundary modifications.

## Installation

1.  **Clone the repository:**
    ```bash
    git clone <repository_url>
    cd evogit
    ```

2.  **Install dependencies:**
    ```bash
    mix deps.get
    ```

3.  **Configure your LLM:**
    ```bash
    mix run -e 'EvoGit.CLI.main(System.argv())' -- setup
    ```
    This runs a guided wizard that writes your LLM provider, model, and API key to `~/.config/evogit/config.toml`.

## Usage

Genesis is a CLI tool. You can run it using `mix run` to execute the CLI entry point.

### Commands

#### 1. Genesis (Creation Phase)

Recursively generates a repository skeleton and implementation based on a high-level prompt.

```bash
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "<Your Prompt>"
```

**Options:**

*   `--file`, `-f`: Read the prompt from a file.
*   `--concurrency`, `-c`: Number of parallel LLM workers (default: 3).
*   `--tool-concurrency`: Number of parallel tool executions (default: 2).
*   `--path`, `-p`: Path to the git repository (default: current directory).
*   `-R name:/path`: Reference a foreign repository (repeatable).

**Examples:**

```bash
# Direct prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "Create a Phoenix web app for a Todo list"

# From file with custom path
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis -f design_doc.md --path /path/to/repo

# Reference a foreign repository
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "Port this project to Rust" -R original:/Source/legacy-project
```

#### 2. Evolution Phase

Fixes bugs, optimizes performance, or adds features to an existing project.

```bash
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<Objective>"
```

**Options:**

*   `--mode`, `-d`: Evolution mode — `simple` (default) for well-defined tasks, `complex` for open-ended exploration.
*   `--path`, `-p`: Path to the git repository (default: current directory).
*   `--node`, `-n`: Target a specific directory node (default: root).
*   `-R name:/path`: Reference a foreign repository (repeatable).
*   `--concurrency`, `-c`: Number of parallel workers.

**Complex mode flags** (open-ended evolution):

*   `--pool-size`, `-s`: Entropy pool size (default: 30).
*   `--generations`, `-g`: Maximum evolution generations (default: 10).
*   `--crossover-rate`: Crossover probability (default: 0.7).
*   `--mutation-rate`: Mutation probability (default: 0.3).
*   `-S file`: Seed fragment file(s) (repeatable).
*   `-C concept`: Concept expansion seeds (repeatable).

**Examples:**

```bash
# Simple evolution — clear task
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "Fix the race condition in the worker pool"

# Complex evolution — open-ended optimization
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "Optimize the rendering pipeline for latency" -d complex
```

### Configuration Options

*   `--concurrency`, `-c`: Sets the number of concurrent LLM API calls (default: 3).
*   `--tool-concurrency`: Sets the number of concurrent tool executions (default: 2).
*   `--retries`, `-r`: Sets the maximum number of crash retries per agent (default: 3).
*   `--max-turns`, `-t`: Sets the maximum number of iterative loops per agent session.
*   `--model`, `-m`: Override the LLM model for this session.
*   `--path`, `-p`: Path to the git repository (default: current directory).
*   `--help`, `-h`: Show help message.

## Architecture

*   **Spatial Dimension:** The codebase is a tree of Context Nodes. Each directory has a `CONTEXT.md` defining its intent, API, constraints, and a routing table to child nodes.
*   **Temporal Dimension:** Code evolves via Git commits. Agents branch off, attempt changes, and successful branches are merged.
*   **Agents:** Stateless functions that transform `{commit, node_path}` + `objective` → `new_commit`. Specialized roles include Managers, Executors, Investigators, Architects, and more.
*   **Scheduler:** Manages a pool of isolated Git worktrees with cooperative multitasking, LLM/tool slot management, and rate-limit backoff.

## Output

Genesis works in `.evogit/workers/` directory using Git worktrees. It commits changes to your repository on isolated branches, optionally creating pull requests for review.

## Dashboard

Genesis includes a web dashboard (`evo_dash`) for real-time visualization of the agent tree, task management, code review, and runtime configuration:

```bash
mix phx.server
```

Open `http://localhost:4100` to access the dashboard.
