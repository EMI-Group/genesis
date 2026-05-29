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

# Concurrency Options:
#   -c, --concurrency <n>
#       Set number of concurrent agents / LLM calls.
#       --tool-concurrency <n>
#       Set number of concurrent tool executions.
#   Note: CLI flags apply session-level overrides. Default values come from
#   user config (~/.config/evogit/config.toml).

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
│  │  ├─ LLM Slots + Backoff │  │  Endpoint (Bandit)        │ │
│  │  ├─ Tool Slots          │  │  Assets (Tailwind/DaisyUI)│ │
│  │  Agents (LLM-powered)   │  │                           │ │
│  │  ContextNode (Spatial)  │  │                           │ │
│  │  PhyloGraphNode (Temp.) │  │                           │ │
│  │  Git Adapter (CLI)      │  │                           │ │
│  │  ProjectConfig (evogit.toml)                              │
│  │  Config (3-level resolver)   │                           │
│  │  ├─ Defaults (built-in)     │                           │
│  │  ├─ User Config (TOML)      │                           │
│  │  └─ Runtime Override        │                           │
│  └─────────────────────────┘  └───────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────┐  ┌───────────────────────────┐ │
│  │    ./config/            │  │  ./example_design/         │ │
│  │     Environment config  │  │   Sample design documents  │ │
│  └─────────────────────────┘  └───────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Slot Management & Backoff

The `AgentScheduler` manages two independent slot pools that gate agent resource usage:

| Slot Pool | Config Key | Default | CLI Flag | Backoff |
|-----------|-----------|---------|----------|---------|
| **LLM Slots** | `max_concurrency` | 3 | `-c` / `--concurrency` | Yes — 60s global cooldown on rate-limit errors (`report_llm_error/2`) |
| **Tool Slots** | `max_tool_concurrency` | 2 | `--tool-concurrency` | No — simple semaphore |

Both use blocking `GenServer.call` — agents wait in FIFO queues when no slots are available and are granted slots via `GenServer.reply/2` when freed.

```
Agent calls LLM → request_llm_slot(agent_id)
  ├─ slot available → granted immediately
  └─ no slot / in backoff → queued, blocked

LLM returns rate_limit error → report_llm_error(agent_id, :rate_limit)
  → All waiting agents get 60s backoff timestamp
  → retry_llm_waiting timer fires at 65s to unstick any stragglers

Agent finishes LLM call → release_llm_slot(agent_id)
  → grant_pending_llm_slots drains queue (skipping still-in-backoff entries)
```

### Configuration Architecture

EvoGit uses a three-level configuration system with increasing priority:

| Level | Source | Override Scope | Example |
|-------|--------|---------------|---------|
| **Defaults** | `EvoGit.Config.defaults/0` | All sessions | `max_concurrency: 3` |
| **User Config** | `~/.config/evogit/config.toml` | All sessions | `[llm] model = "..."` |
| **Runtime Override** | `AgentScheduler.update_config/1` | Current session only | CLI `-c 5` flag |

**Key principle**: No default model or username — users must configure these via user config.

#### User Config (`~/.config/evogit/config.toml`)
```toml
[scheduler]
max_concurrency = 3
max_tool_concurrency = 2
agent_max_retries = 3
max_agent_depth = 8
max_retries = 15

[llm]
model = "zai_coding_plan:glm-5"
compression_threshold_tokens = 100_000

[user]
github_username = "your-username"
```

#### Environment (`.env`)

API keys are loaded at startup by `EvoGit.Config.load_env/0` from `~/.config/evogit/.env` using standard `KEY=VALUE` format (one per line):

```env
GOOGLE_API_KEY=AIza...
ZAI_API_KEY=sk-...
```

`load_env/0` sets these as environment variables, which ReqLLM and the `api_key/1` function read natively. Keys can also be set directly in the environment without a `.env` file.

### Orphaned Branch Cleanup

On scheduler initialization (`ensure_initialized`), the scheduler runs `clean_orphaned_branches/1` which:
1. Lists all `evogit-agent*` branches via `git branch --list`
2. Deletes each one via `Git.delete_branch/2`

This ensures stale branches from previous interrupted runs don't accumulate.

### Task ID Tracking

Each top-level `run_agent/2` call is assigned a monotonically increasing `task_id` (from `state.next_task_id`). All subagents spawned within that run inherit the same `task_id` via `SchedMeta.task_id`. This groups related agents for observability and lifecycle management without coupling to parent-child hierarchy alone.

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
7. **Slot-Based Concurrency:** LLM calls and tool executions are independently throttled via slot pools managed by the scheduler. LLM slots include a global backoff mechanism for rate-limit errors.
8. **Three-Level Configuration**: Defaults → User Config (TOML) → Runtime Overrides. No hardcoded model or username defaults.

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
- **LLM slot discipline:** All LLM calls must go through `request_llm_slot` / `release_llm_slot`. Rate-limit errors must be reported via `report_llm_error` to trigger global backoff.
- **Tool slot discipline:** Tool executions must go through `request_tool_slot` / `release_tool_slot` to respect `max_tool_concurrency`.
- **No hardcoded model/username defaults**: The `config/config.exs` only contains infrastructure settings. Model and user preferences must be configured via `~/.config/evogit/config.toml`.
- **User config directory**: Follows XDG conventions — `$XDG_CONFIG_HOME/evogit` on Linux, `~/Library/Application Support/evogit` on macOS, `%APPDATA%/evogit` on Windows.

## Development Notes

- Run `mix precommit` to format code and run tests before committing.
- Use `mix test` to execute the test suite.
- Use `mix deps.get` to fetch dependencies.
- Use `mix compile` to compile the project and check for compilation errors.
