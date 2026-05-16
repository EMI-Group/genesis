# EvoGit 1.0 — Root

## Intent

EvoGit is a **decentralized, evolutionary software development framework** built in Elixir. It treats a codebase as a hierarchical tree of "Context Nodes" (Spatial Dimension) and evolves it through a DAG of Git commits (Temporal Dimension). AI agents recursively build and optimize software by leveraging the Context Tree for architectural coherence and the Phylogenetic Graph for code evolution.

This is an **Elixir umbrella project** with two child applications:

| App | Directory | Purpose |
|-----|-----------|---------|
| `:evo_git` | `apps/evo_git/` | Core runtime — agent execution, Git interactions, dual-dimension architecture, CLI |
| `:evo_dash` | `apps/evo_dash/` | Phoenix LiveView dashboard — real-time visualization of Context Tree, agent activity, task management |

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
| `apps/` | Umbrella child applications (`evo_git/`, `evo_dash/`) |
| `config/` | Environment-based configuration (`config.exs` + env overrides) |
| `example_design/` | Example design document (`evoclass.json` — a multi-level course generation design) |

### CLI Interface (via `mix run`)
```bash
# Genesis: Create a new codebase from a prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "<prompt>" [-f file] [-c concurrency] [-p path]

# Evolution: Modify/fix an existing codebase
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<objective>" [-p path]
```

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                     EvoGit Umbrella Root                     │
│                                                              │
│  ┌─────────────────────────┐  ┌───────────────────────────┐ │
│  │     apps/evo_git/       │  │     apps/evo_dash/        │ │
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
│  │     config/             │  │   example_design/          │ │
│  │     Environment config  │  │   Sample design documents  │ │
│  └─────────────────────────┘  └───────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Concepts
1. **Spatial Dimension (Context Tree):** Every directory has a `CONTEXT.md` defining Intent, API Surface, and Constraints. Agents inherit context top-down.
2. **Temporal Dimension (Phylogenetic Graph):** Code evolves via Git commits. Agents work in isolated worktrees; successful branches are merged.
3. **Stateless Agents:** `NewState = Agent(State, Objective)`. All persistent memory lives in the Context Tree or Git history.
4. **Worktree Isolation:** Agents never modify the main checkout. Work happens in `.evogit/workers/` with cooperative multitasking.
5. **Project Configuration:** An optional `evogit.toml` file at the repo root allows project-level customization. Currently supports `worktree.script` for running initialization scripts after worktree creation.

## Constraints
- **Umbrella structure:** All dependencies, build artifacts, and the lockfile live at the root level (`deps/`, `_build/`, `mix.lock`).
- **Elixir ~> 1.18:** Required for the standard `JSON` library.
- **Git CLI:** The sole version control interface (no libgit2 bindings).
- **No source code at root:** All application source code lives under `apps/`.
- **Every directory must have a `CONTEXT.md`:** This is the spatial contract that agents read and maintain.
- **Agents commit before delegating:** Worktrees must be clean before spawning subagents (auto-commit fallback enforced).
- **Sandboxing:** LLM-generated code runs under `systemd-run` with strict filesystem, CPU, memory, and syscall restrictions.

## Development Notes

- Run `mix precommit` to format code and run tests before committing.
- Use `mix test` to execute the test suite.
- Use `mix deps.get` to fetch dependencies.
- Use `mix compile` to compile the project and check for compilation errors.
