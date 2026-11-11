# EvoGit Application Library — `lib/`

## Intent
Top-level source directory for the `:evo_git` OTP application. Contains the application entry point and delegates to subdirectories for core modules, agent implementations, adapters, and runtime phases.

## Routing Table
- `./evo_git/` → All application source modules: Agent behaviour, AgentSpec, AgentScheduler, Task orchestration, Core types, Git adapter, Runtime, ProjectConfig, plus agent/ and tools/ subdirectories.
- `./evo_git/config/` → Canonical LLM provider accounts, model inventories, reasoning defaults, legacy migration, validation and selection resolution.
- `./evo_git/agent_scheduler/` → Provider-account capacity/backoff and full model-selection inheritance.
- `./evo_git/task_registry/` + `./evo_git/runtime/` → Explicit task selection admission, persistence and runtime threading.
- `./evo_git/process_manager.ex` + `./evo_git/process_manager/` → `EvoGit.ProcessManager` — the single source of truth for the live OS executions an agent/task holds (one `Execution` + normalized `Handle` per foreground tool call / detached background job), with timer sampling, owner-pid lifetime, retention and pause/resume/signal/kill over `systemctl --user`, `/proc`/`ps` and `tasklist`; PubSub topic `"processes"` — detail in `./evo_git/process_manager/CONTEXT.md`
- `./mix/tasks/` → Release-time Mix tasks (`Mix.Tasks.Changelog`, `Mix.Tasks.Bump.Version`, `Mix.Tasks.Migrate.Store`) — detail in `./mix/tasks/CONTEXT.md`
- `./evo_git/` → Repo-less Genesis assistant with one tiered `elixir_eval` tool (`agent/tools/elixir_eval/`), SelfReflective persona (`agents/`), runtime targeting (`runtime/`) and exact-code approval (`command_approval.ex`).
- `./evo_git/` → The literal-command registry behind the `run_command` agent tool remains in `command_shell.ex`; the assistant exposes read/write Dune evaluation and explicitly approved native sudo rather than `run_command`.
- `./evo_git/agent/tools/elixir_eval/CONTEXT.md` → Dune dependency/API, capability whitelist, authorization, resource limits and parent-owned evaluator test contracts.

## API Surface
| File | Module | Description |
|---|---|---|
| `evo_git.ex` | `EvoGit` | Sandboxing utilities, safe shell command execution |
| `application.ex` | `EvoGit.Application` | OTP application callback — starts AgentScheduler and TaskSupervisor |

## Constraints
- This is the standard Elixir `lib/` directory for the `:evo_git` child app.
- All source modules live under `./evo_git/` subdirectory following Elixir convention.
