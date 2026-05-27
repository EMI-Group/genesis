# EvoGit Application Library — `lib/`

## Intent
Top-level source directory for the `:evo_git` OTP application. Contains the application entry point and delegates to subdirectories for core modules, agent implementations, adapters, and runtime phases.

## Routing Table
- `./evo_git/` → All application source modules: Agent behaviour, AgentSpec, AgentScheduler, Task orchestration, Core types, Git adapter, Runtime, ProjectConfig, plus agent/ and tools/ subdirectories

## API Surface
| File | Module | Description |
|---|---|---|
| `evo_git.ex` | `EvoGit` | Sandboxing utilities, safe shell command execution |
| `application.ex` | `EvoGit.Application` | OTP application callback — starts AgentScheduler and TaskSupervisor |
| `cli.ex` | `EvoGit.CLI` | CLI entry point for `mix run` commands |

## Constraints
- This is the standard Elixir `lib/` directory for the `:evo_git` child app.
- All source modules live under `./evo_git/` subdirectory following Elixir convention.
