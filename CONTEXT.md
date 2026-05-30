# EvoGit — Root

## Intent

EvoGit is an evolutionary software development framework built in Elixir. It models a codebase as a hierarchical **Context Tree** (Spatial Dimension) and evolves it through a DAG of Git commits (Temporal Dimension). AI agents recursively build and optimize software, guided by spatial contracts in per-directory CONTEXT.md files.

This is an **Elixir umbrella project** with two child applications:

| App | Directory | Purpose |
|-----|-----------|---------|
| `:evo_git` | `./apps/evo_git/` | Core runtime — agent execution, Git interactions, CLI |
| `:evo_dash` | `./apps/evo_dash/` | Phoenix LiveView dashboard — real-time visualization and task management |

The full design specification is in `AGENTS.md`.

## Routing Table

- `./apps/evo_git/` → Core runtime (agents, scheduler, git adapter, runtime phases)
- `./apps/evo_dash/` → Web dashboard (LiveView pages, components, task registry)
- `./config/` → Environment-based Elixir configuration

## API Surface

### Top-Level Files

| File | Purpose |
|------|---------|
| `mix.exs` | Umbrella Mix project — apps_path, release config (`:evogit` release with both apps) |
| `AGENTS.md` | Full EvoGit design specification (dual-dimension architecture, agent model, runtime phases) |
| `README.md` | User-facing documentation: installation, CLI usage, architecture overview |
| `.formatter.exs` | Code format configuration |
| `LICENSE` | Project license |

### CLI Interface

```bash
# Genesis — create a codebase from a prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "<prompt>" [-f file] [-c concurrency] [-p path] [-R name:path]

# Evolution — modify an existing codebase
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<objective>" [-p path] [-R name:path]
```

Flags: `-c` / `--concurrency` for LLM slots, `--tool-concurrency` for tool slots, `-R name:/path` for foreign repos (repeatable).

## Architecture Summary

EvoGit has two OTP applications under an umbrella:

- **`:evo_git`** (Core Runtime): AgentScheduler GenServer managing worktree pools, LLM/tool slot management with global backoff, agent implementations (Manager, Executor, Investigator, etc.), Git adapter, and two-phase execution (Genesis → Evolution). Uses a 3-level configuration system: built-in defaults → user TOML config → session-level runtime overrides.
- **`:evo_dash`** (Web Dashboard): Phoenix LiveView interface with project-based task management, agent tree inspector, runtime settings panel, and in-browser config editor. Uses Bandit adapter, Tailwind CSS 4 + DaisyUI, DETS-based persistence.

Key design: spatial context tree for routing, phylogenetic graph for temporal evolution, stateless agents in isolated worktrees, multi-repo support via absolute path resolution, slot-based concurrency with LLM rate-limit backoff, and a dynamic skills system.

## Constraints

- Umbrella structure: all deps, build artifacts, lockfile at root (`./deps/`, `./_build/`, `mix.lock`)
- Elixir ~> 1.18 required
- Git CLI only — no libgit2 bindings
- No source code at root — all code under `./apps/`
- Every directory must have a CONTEXT.md as its spatial contract
- Agents commit before delegating subagents (auto-commit fallback enforced)
- LLM-generated code runs under `systemd-run` sandboxing
- No hardcoded model or username — users configure via `~/.config/evogit/config.toml`
- User config follows XDG conventions

## Development Notes

- `mix precommit` — format code and run tests before committing
- `mix test` — execute the test suite
- `mix deps.get` — fetch dependencies
- `mix compile` — compile and check for errors
