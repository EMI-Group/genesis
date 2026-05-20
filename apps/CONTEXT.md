# Apps — Umbrella Child Applications

## Intent

Contains the two child applications of the EvoGit umbrella project. The core runtime (`./evo_git/`) handles agent execution, git interactions, and evolutionary workflows. The web dashboard (`./evo_dash/`) provides a real-time Phoenix LiveView interface for monitoring and managing EvoGit tasks.

## Routing Table

- `./evo_git/` → Core runtime — agent execution, Git interactions, dual-dimension architecture, CLI
- `./evo_dash/` → Phoenix LiveView dashboard — real-time visualization of Context Tree, agent activity, task management

## Constraints

- Part of an **umbrella project** — build artifacts, deps, and lockfile live at the repository root.
- Each child app is an independent Mix project with its own `mix.exs` and `def application`.
- The `:evo_dash` app depends on `:evo_git` at compile and runtime.
