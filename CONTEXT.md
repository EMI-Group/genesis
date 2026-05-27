# EvoGit 1.0 — Root

## Intent

EvoGit is a **decentralized, evolutionary software development framework** built in Elixir. It treats a codebase as a hierarchical tree of "Context Nodes" (Spatial Dimension) and evolves it through a DAG of Git commits (Temporal Dimension). AI agents recursively build and optimize software by leveraging the Context Tree for architectural coherence and the Phylogenetic Graph for code evolution.

This is an **Elixir umbrella project** with two child applications:

| App | Directory | Purpose |
|-----|-----------|---------|
| `:evo_git` | `./apps/evo_git/` | Core runtime — agent execution, Git interactions, dual-dimension architecture, CLI |
| `:evo_dash` | `./apps/evo_dash/` | Phoenix LiveView dashboard — real-time visualization of Context Tree, agent activity, task management |

The detailed design document can be found in AGENTS.md.

## Routing Table
- `./apps/` → Umbrella child applications (`./evo_git/` core runtime, `./evo_dash/` web dashboard)
- `./config/` → Environment-based Elixir configuration (`config.exs` + environment overrides)
- `./example_design/` → Example design documents (sample `evoclass.json`)

## API Surface

### Top-Level Files
| File | Purpose |
|------|---------|
| `mix.exs` | Umbrella Mix project — defines apps_path, release config (`:evogit` release with both apps) |
| `AGENTS.md` | Full EvoGit 1.0 design specification (dual-dimension architecture, stateless agent model, runtime phases) |
| `README.md` | User-facing documentation: installation, CLI commands, architecture overview |
| `.formatter.exs` | `mix format` configuration (standard Elixir patterns) |
| `LICENSE` | Project license |

### Directories
| Directory | Purpose |
|-----------|---------|
| `./apps/` | Umbrella child applications (`./evo_git/`, `./evo_dash/`) |
| `./config/` | Environment-based configuration (`config.exs` + env overrides) |
| `./example_design/` | Example design document (`evoclass.json` — a multi-level course generation design) |

### CLI Interface (via `mix run`)
```bash
# Genesis: Create a new codebase from a prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "<prompt>" [-f file] [-c concurrency] [-p path] [-R name:path]

# Evolution: Modify/fix an existing codebase
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<objective>" [-p path] [-R name:path]

# Multi-Repo Options:
#   -R, --foreign-repo <name:path | path>
#       Add a foreign repository for cross-repo operations.
#       Can be specified multiple times. If name is omitted,
#       the directory basename is used. (e.g., -R original:/Source/proj)
```

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                     EvoGit Umbrella Root                     │
│                                                              │
│  ┌─────────────────────────┐  ┌───────────────────────────┐ │
│  │    ./apps/evo_git/      │  │    ./apps/evo_dash/       │ │
│  │     (Core Runtime)      │  │     (Web Dashboard)       │ │
│  │                         │  │                           │ │
│  │  CLI → Runtime          │  │  TaskRegistry ←→ Runtime  │ │
│  │  AgentScheduler (ETS)   │  │  Phoenix LiveView UI      │ │
│  │  Agents (LLM-powered)   │  │  Endpoint (Bandit)        │ │
│  │  ContextNode (Spatial)  │  │  Assets (Tailwind/DaisyUI)│ │
│  │  PhyloGraphNode (Temp.) │  │                           │ │
│  │  Git Adapter (CLI)      │  │                           │ │
│  │  ProjectConfig (evogit.toml)                              │
│  └─────────────────────────┘  └───────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────┐  ┌───────────────────────────┐ │
│  │    ./config/            │  │  ./example_design/         │ │
│  │     Environment config  │  │   Sample design documents  │ │
│  └─────────────────────────┘  └───────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Multi-Repo Support

EvoGit supports cross-repository operations, allowing agents to spawn subagents that work on **foreign repositories** alongside the primary project. This enables use cases like referencing an original codebase while generating a rewrite, or coordinating changes across related repositories.

#### Core Components

| Component | Module | Role |
|-----------|--------|------|
| `ForeignRepo` struct | `EvoGit.Core.ForeignRepo` | Represents a registered repo with `id` (atom), `root` (absolute path), and `name` (human-readable). Provides path resolution (`resolve_path/2`, `normalize_path/2`) to map absolute filesystem paths to repo-relative paths. |
| CLI parsing | `EvoGit.CLI` | Parses `-R`/`--foreign-repo` flags (supports multiple). Format: `-R name:/path` or `-R /path` (basename becomes name). |
| TOML config | `EvoGit.ProjectConfig` | Reads `[foreign_repos]` section from `evogit.toml`. Each entry requires `path` and optionally `name`. |
| Agent dispatch | `EvoGit.Agent` | When an LLM calls a subagent tool with an **absolute path**, the path is resolved against all registered repos. Foreign repos are checked first (primary last). A **relative path** stays in the same repo as the parent agent. |
| Scheduler | `EvoGit.AgentScheduler` | Stores registered repos in GenServer state. Creates worktrees under the foreign repo's `.evogit/workers/` directory. Skips spatial contract validation for cross-repo subagents. |

#### Configuration

**CLI flag** (recommended):
```bash
-R original:/Source/original-proj -R reference:/Source/rust-rewrite
```

**evogit.toml** (alternative):
```toml
[foreign_repos.original]
path = "/Source/original-proj"

[foreign_repos.reference]
path = "/Source/rust-rewrite-proj"
name = "Reference Implementation"
```

#### Cross-Repo Agent Flow

```
CLI: -R original:/Source/original-proj
  → ForeignRepo{id: :original, root: "/Source/original-proj"}
  → AgentScheduler.register_foreign_repos/1 (stored in state.repos)

Agent LLM calls subagent tool with path: "/Source/original-proj/src/main.py"
  → resolve_subagent_path detects absolute path
  → ForeignRepo.resolve_path → {:ok, :original, "./src/main.py"}
  → AgentSpec{repo_id: :original, ...}
  → Worktree created at "/Source/original-proj/.evogit/workers/worker_N"
  → Subagent commits to foreign repo's git database (not merged into primary)
```

#### Key Behaviors
- **Path-based routing:** Absolute paths trigger cross-repo resolution; relative paths stay in the parent's repo.
- **Independent worktrees:** Each foreign repo gets its own `.evogit/workers/` directory for agent worktrees.
- **Merge isolation:** Cross-repo subagent results are **not merged** into the primary repo. Each repo maintains its own commit history.
- **Spatial contract bypass:** Foreign repo subagents skip spatial contract validation since they operate on independent repository trees.
- **Init script scoping:** Worktree initialization scripts only run for the `:primary` repo, not foreign repos.

### Key Design Concepts
1. **Spatial Dimension (Context Tree):** Every directory has a `CONTEXT.md` defining Intent, API Surface, and Constraints. Agents inherit context top-down.
2. **Temporal Dimension (Phylogenetic Graph):** Code evolves via Git commits. Agents work in isolated worktrees; successful branches are merged.
3. **Stateless Agents:** `NewState = Agent(State, Objective)`. All persistent memory lives in the Context Tree or Git history.
4. **Worktree Isolation:** Agents never modify the main checkout. Work happens in `.evogit/workers/` with cooperative multitasking.
5. **Project Configuration:** An optional `evogit.toml` file at the repo root allows project-level customization. Currently supports `worktree.script` for running initialization scripts after worktree creation.
6. **Multi-Repo Support:** Agents can operate across multiple Git repositories simultaneously. Foreign repos are registered via CLI flags or `evogit.toml` configuration. Agents spawn subagents to foreign repos by specifying absolute paths, which are automatically resolved to the correct repo. Each repo maintains its own worktrees, commit history, and spatial contracts independently.

## Constraints
- **Umbrella structure:** All dependencies, build artifacts, and the lockfile live at the root level (`./deps/`, `./_build/`, `mix.lock`).
- **Elixir ~> 1.18:** Required for the standard `JSON` library.
- **Git CLI:** The sole version control interface (no libgit2 bindings).
- **No source code at root:** All application source code lives under `./apps/`.
- **Every directory must have a `CONTEXT.md`:** This is the spatial contract that agents read and maintain.
- **Agents commit before delegating:** Worktrees must be clean before spawning subagents (auto-commit fallback enforced).
- **Sandboxing:** LLM-generated code runs under `systemd-run` with strict filesystem, CPU, memory, and syscall restrictions.
- **Foreign repo paths must be absolute:** Both CLI `-R` flags and `evogit.toml` `[foreign_repos]` entries require absolute paths. Agents use absolute paths to route subagents to foreign repos.
- **Cross-repo results are not merged:** Subagents operating on foreign repos commit independently. Results are reported to the parent agent but no cross-repo merge is performed.

## Development Notes

- Run `mix precommit` to format code and run tests before committing.
- Use `mix test` to execute the test suite.
- Use `mix deps.get` to fetch dependencies.
- Use `mix compile` to compile the project and check for compilation errors.
