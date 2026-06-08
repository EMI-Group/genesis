# Genesis 1.0

Genesis is a decentralized, evolutionary software development framework. It treats your codebase as a hierarchical tree of "Context Nodes" (Spatial Dimension) and evolves it through a Directed Acyclic Graph of Git commits (Temporal Dimension).

It uses AI Agents to recursively build and optimize software, leveraging a "Context Tree" to maintain architectural coherence and a "Phylogenetic Graph" to manage code evolution.

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
*   `--concurrency`, `-c`: Number of parallel workers (default: 3).
*   `--path`, `-p`: Path to the git repository (default: current directory).

**Examples:**

```bash
# Direct prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "Create a Phoenix web app for a Todo list"

# From file with custom path
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis -f design_doc.md --path /path/to/repo
```

#### 2. Evolution Phase

Fixes bugs, optimizes performance, or adds features to an existing project.

```bash
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<Objective>"
```

**Options:**

*   `--path`, `-p`: Path to the git repository (default: current directory).

**Examples:**

```bash
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "Fix the race condition in the worker pool" --path /path/to/repo
```

### Configuration Options

*   `--concurrency`, `-c`: Sets the number of concurrent agents/workers (default: 3).
*   `--retries`, `-r`: Sets the maximum number of retries for failed agents (default: 3).
*   `--path`, `-p`: Path to the git repository (default: current directory).
*   `--help`, `-h`: Show help message.

## Architecture

*   **Spatial Dimension:** The codebase is a tree of Context Nodes. Each directory has a `CONTEXT.md` defining its intent, API, and constraints.
*   **Temporal Dimension:** Code evolves via Git commits. Agents branch off, attempt changes, and successful branches are merged.
*   **Agents:** Stateless functions that transform `{commit, node_path}` + `objective` -> `new_commit`.

## Output

Genesis works in `.evogit/workers/` directory using Git worktrees. It commits changes to your repository.
