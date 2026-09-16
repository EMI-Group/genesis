# evo_git — Test Tree

## Intent
ExUnit suites mirroring the source tree under `apps/evo_git/lib/evo_git/`.
The top-level `*.exs` files in THIS directory cover whole subsystems (CLI, remote, review, store, config, peak hours, system sampler, …); subdirectory files mirror lib paths and are documented by the child CONTEXT.md files below — do not duplicate that per-file detail here.
All suites use real git operations on temp dirs; none use mocks.

## Routing Table
- `./adapters/` → Git / GitHub / CoW-worktree / GitEnv adapter tests → `./adapters/CONTEXT.md`
- `./agent/` → agent loop, context builder/compression, tool dispatch, subagent processing → `./agent/CONTEXT.md`
- `./agent/tools/` → per-tool tests → `./agent/tools/CONTEXT.md`
- `./agent_scheduler/` → scheduler dispatch, slots, lifecycle, worktrees, store, subagents, RemoteAPI → `./agent_scheduler/CONTEXT.md`
- `./agents/` → agent implementation tests (`EvoGit.Agents.Custom`) — no own CONTEXT.md
- `./config/` → config schema / LLM catalog / version-state / ecto validation — no own CONTEXT.md
- `./core/` → `ContextNode`, `PhyloGraphNode`, `ForeignRepo` → `./core/CONTEXT.md`
- `./custom_agents/` → custom-agents store + model-selection script → `./custom_agents/CONTEXT.md`
- `./runtime/` → Genesis / Evolution / Helpers / Prompts / SelfReflective runtimes → `./runtime/CONTEXT.md`
- `./sandbox/` → sandbox backends (systemd-run, bwrap, sandbox-exec, none) → `./sandbox/CONTEXT.md`
- `./skills/` → skills subsystem → `./skills/CONTEXT.md`
- `./store/` → SQLite store queries / errors → `./store/CONTEXT.md`
- `./task_registry/` → TaskRegistry lifecycle, runtime-opts, merge/resume context, `:reflect` executor → `./task_registry/CONTEXT.md`
- Top-level `*.exs` in THIS directory → the async-safety map + notes below.

## Top-Level Modules — Async-Safety Map
Applies the policy in `../CONTEXT.md` → "Async-Safety Policy".
Do NOT flip these to `async: true`:
- XDG / OS-env redirectors (`System.put_env` on `XDG_CONFIG_HOME`, or `PATH` for `EvoGit.FakeGh`): `config_test`, `custom_agents_test`, `custom_agents_rpc_test`, `remote_connections_test`, `remote_connection_test`, `platform_test`, `distribution_test`, `git_env_test`, `remote_node_github_test`, `cli_agent_flag_test` (also rewrites the live scheduler `:model_profiles`).
- Shared app singletons / global ETS / global scheduler config: `system_sampler_test`, `peak_hour_engine_test`, `worktree_main_head_safety_test`, `application_test`, `sandbox_slice_test`, `sandbox_process_registry_test`, `self_reflective_source_test`, `system_check_test`. Each of those files' `@moduledoc` names its exact forcing global (`sandbox_slice_test` → the app-level `EvoGit.SandboxSlice` singleton; `sandbox_process_registry_test` → the globally named `EvoGit.SandboxProcessRegistry`; `system_check_test` → the `:evogit_nix_dev_env_state` `:persistent_term` written by `EvoGit.Nix.reset_state/0`).
- `EvoGit.TaskRegistryCase` (terminates/restarts the app-level `EvoGit.Store` + `EvoGit.TaskRegistry`): `command_shell_test`, `command_approval_test`, `cli_task_routing_test`, `store_disk_full_test`. ANY module `use`ing that case MUST stay `async: false`.
- `store_test` / `store_summary_test` also terminate/restart the app-level `EvoGit.Store` + `EvoGit.TaskRegistry` and register an isolated Store under the canonical name.
- `evo_git_test.exs` (repo-root file) is stated explicitly as `async: false`, and its `@moduledoc` names its forcing globals: `XDG_CONFIG_HOME` via `System.put_env/2` + the `:nix_enabled` app-env key.
Genuinely `async: true` (verified to mutate no shared global): `attachments_test`, `cli_test`, `epmd_dist_test`, `executable_test`, `migrate_store_test`, `path_suggestions_test`, `peak_hours_test`, `powershell_test`, `project_config_test`, `prompt_file_test`, `remote_bootstrap_test`, `remote_node_test`, `req_llm_pool_test` (drives a private standalone Finch, never the production `ReqLLM.Finch`), `review_test`, `skills_hierarchical_test`, `skills_test`, `store_schema_migration_test` (raw Xqlite on private temp DBs), `utf8_test`.

### store_test / store_summary_test — schema template
Both build a schema-complete SQLite file ONCE in `setup_all` (a real `Store.init` + `GenServer.stop`) and `File.cp!/2` it per test, instead of re-running the DDL per test (~24ms → ~2ms each).
The production `Store`/`TaskRegistry` are terminated for the whole module and restored once.
Do NOT switch these to a single shared DB truncated between tests — several tests mutate the schema (e.g. the projects skip-and-log test re-creates `projects` with INTEGER columns) and inject malformed rows, which would corrupt later tests.

## Notes for Agents
- `EvoGit.PeakHourEngine` asynchronously rewrites the global scheduler's `model_concurrency`: it subscribes to the `"scheduler_config"` PubSub topic and re-applies an effective map from the LIVE `model_profiles`, possibly after a test's own `AgentScheduler.update_config/1`. So do NOT assert exact equality against live scheduler-derived values (`get_llm_slot_status/0`, `model_concurrency`) after mutating global config — inject a per-call seam or compare against a FRESH live read. `agent_scheduler_test.exs` instead suspends `PeakHourEngine` per test.
- `EvoGit.SystemSampler` exposes per-call app-env seams `:system_sampler_llm_slots_fun` and `:system_sampler_config_fun` (0-arity funs read PER CALL; defaults are the real bounded scheduler reads). `system_sampler_test.exs` injects them via `put_seam/2` and deletes the keys in `on_exit`; its `setup` also defensively deletes both.
- LLM retry-backoff timing is injectable via the app-env seam `:llm_retry_backoff_base_ms` (read per call by `EvoGit.Agent.ToolDispatch.retry_backoff_base_ms/0`); `agent/tool_dispatch_retry_slot_test.exs` sets it to shrink waits.
- Remote daemon-health polling delay is injectable via the app-env seam `:remote_daemon_health_delay_ms` (default 1000ms, read per call by `EvoGit.RemoteConnection.daemon_health_delay_ms/0`); `remote_connection_test.exs` sets it to 20ms so each bootstrap test no longer burns a mandatory second.
