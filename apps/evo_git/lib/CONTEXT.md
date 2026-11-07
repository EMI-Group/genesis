# EvoGit Application Library — `lib/`

## Intent
Top-level source directory for the `:evo_git` OTP application. Contains the application entry point and delegates to subdirectories for core modules, agent implementations, adapters, and runtime phases.

## Routing Table
- `./evo_git/` → All application source modules: Agent behaviour, AgentSpec, AgentScheduler, Task orchestration, Core types, Git adapter, Runtime, ProjectConfig, plus agent/ and tools/ subdirectories.
- `./evo_git/config/` → Canonical LLM provider accounts, model inventories, reasoning defaults, legacy migration, validation and selection resolution.
- `./evo_git/agent_scheduler/` → Provider-account capacity/backoff and full model-selection inheritance.
- `./evo_git/task_registry/` + `./evo_git/runtime/` → Explicit task selection admission, persistence and runtime threading.
- `./evo_git/cli/` → Provider-profile setup and selection parsing, integrated by the parent `evo_git/cli.ex` entry point.
- `./mix/tasks/` → Release-time Mix tasks (`Mix.Tasks.Changelog`, `Mix.Tasks.Bump.Version`, `Mix.Tasks.Migrate.Store`) — detail in `./mix/tasks/CONTEXT.md`
- `./evo_git/` → Repo-less Genesis assistant with one tiered `elixir_eval` tool (`agent/tools/elixir_eval/`), SelfReflective persona (`agents/`), runtime targeting (`runtime/`) and exact-code approval (`command_approval.ex`).
- `./evo_git/` → Direct CLI fixed-command compatibility remains in `command_shell.ex`; the assistant exposes read/write Dune evaluation and explicitly approved native sudo rather than `run_command`.
- `./evo_git/agent/tools/elixir_eval/CONTEXT.md` → Dune dependency/API, capability whitelist, authorization, resource limits and parent-owned evaluator test contracts.

## API Surface
| File | Module | Description |
|---|---|---|
| `evo_git.ex` | `EvoGit` | Sandboxing utilities, safe shell command execution |
| `application.ex` | `EvoGit.Application` | OTP application callback — starts AgentScheduler and TaskSupervisor |
| `cli.ex` | `EvoGit.CLI` | CLI entry point for `mix run` commands |

## Constraints
- This is the standard Elixir `lib/` directory for the `:evo_git` child app.
- All source modules live under `./evo_git/` subdirectory following Elixir convention.
