# evo_git — Test Tree

## Intent

ExUnit suites for the `:evo_git` core runtime.
Each file mirrors its source module path under `apps/evo_git/lib/evo_git/`.
Full per-file inventory lives one level up in `../CONTEXT.md` — do not duplicate it here.

## Routing Table

- `./adapters/` → Git / GitHub / CoW-worktree / GitEnv adapter tests
- `./agent/` → Agent loop, tools, context builder/compression, subagent processing (`./agent/tools/` for per-tool tests)
- `./agent_scheduler/` → Scheduler: dispatch, slots, lifecycle, worktrees, store, subagents, RemoteAPI
- `./agents/` → Agent implementation tests (Manager, Custom, …)
- `./config/` → Config schema / LLM catalog / version-state tests
- `./core/` → `ContextNode`, `PhyloGraphNode`, `ForeignRepo`
- `./custom_agents/` → Custom-agents store + model-selection script tests
- `./runtime/` → Genesis / Evolution / Helpers / Prompts / SelfReflective runtimes
- `./sandbox/` → Sandbox backends (systemd-run, bwrap, sandbox-exec, none)
- `./skills/` → Skills subsystem
- `./store/` → SQLite store queries / errors
- `./task_registry/` → TaskRegistry lifecycle, runtime-opts, merge/resume context
- Top-level `*_test.exs` → module-level suites (CLI, RemoteNode/RemoteConnection, Review, SystemSampler, Platform, PeakHours, …)

## Notes for Agents

- **`EvoGit.PeakHourEngine` asynchronously rewrites the global scheduler's `model_concurrency`.**
  The app-supervised engine subscribes to the `"scheduler_config"` PubSub topic and, on every
  `{:scheduler_config_updated, node}`, recomputes an effective map from the LIVE `model_profiles`
  and re-applies it via `AgentScheduler.update_config(model_concurrency: …)` — possibly landing
  after a test's own `update_config`. A pending engine check (e.g. issued during another file's
  `RemoteAPI.reload_config/0`, which pushes the REAL user config) can therefore clobber
  `model_concurrency` back to the developer's real profiles mid-test.
  Consequence: do NOT assert exact equality against live scheduler-derived values
  (`AgentScheduler.get_llm_slot_status/0`, `model_concurrency`) after mutating global config.
  Either inject the value through a per-call seam, or compare against a FRESH live read.
  `agent_scheduler_test.exs` instead suspends `PeakHourEngine` per test.
- **`EvoGit.SystemSampler` has per-call test seams** `:system_sampler_llm_slots_fun` and
  `:system_sampler_config_fun` (0-arity funs read from app env PER CALL; defaults are the real
  bounded scheduler reads). `system_sampler_test.exs` uses them via `put_seam/2`, which deletes the
  env key in `on_exit`; the module `setup` also defensively deletes both keys.
- **The test SQLite DB is shared across runs AND across umbrella apps**
  (`System.tmp_dir!()/evogit_test_data/genesis`, set in `config/test.exs`). Rows left by an
  `evo_dash` test run persist and can break `:evo_git` tests — e.g. `EvoGit.RemoteNodeTest`
  "list_tasks_paginated/2" fails when a leftover `export_test_*` row (seeded by
  `apps/evo_dash/test/evo_dash_web/controllers/task_export_controller_test.exs`) is present.
  Re-run the suspect file in isolation before treating such a failure as a regression.
- **Full-suite parallel-run flakiness** is documented (pre-existing, timing-sensitive, passes in
  isolation) one level up in `../CONTEXT.md` → "Known Issues & Test Env Notes". Confirmed by
  re-running the suspect file in isolation.
- **The test SQLite DB is shared across worktrees** (`config/test.exs` pins `:data_dir` to
  `System.tmp_dir!()/evogit_test_data/genesis`, and `System.tmp_dir!()` reads `TMPDIR`).
  Two parallel `mix test` runs therefore contend on the same DB file. Run with a private dir
  (`TMPDIR=$(mktemp -d) mix test ...`) to isolate a run.

## Top-Level `.exs` Modules — Async-Safety Map

The modules directly in THIS directory are owned by this node.
Every `async: false` module carries an in-file comment/`@moduledoc` naming the exact BEAM-global that forces serialization — keep it accurate when the forcing state changes.
Do NOT flip these to `async: true`:
- **XDG / OS-env redirectors** (`System.put_env` `XDG_CONFIG_HOME`, or `PATH` for `EvoGit.FakeGh`): `config_test`, `custom_agents_test`, `custom_agents_rpc_test`, `remote_connections_test`, `remote_connection_test`, `platform_test`, `distribution_test`, `git_env_test`, `remote_node_github_test`.
- **Shared app singletons / global ETS**: `system_sampler_test` + `peak_hour_engine_test` (`AgentScheduler` config + `:evogit_*` ETS), `worktree_main_head_safety_test`, `application_test` (ETS ownership + `AgentScheduler` child), `sandbox_slice_test` + `sandbox_process_registry_test` (app-level slice/registry GenServers), `self_reflective_source_test` (`:self_reflective_source_*` app env + `GENESIS_SOURCE_ROOT`), `system_check_test` (global supervisor/sandbox/nix state).
- **`EvoGit.TaskRegistryCase`** (terminates/restarts the app-level `EvoGit.Store` + `EvoGit.TaskRegistry`): `command_shell_test`, `command_approval_test`, `cli_task_routing_test`, `cli_agent_flag_test`, `store_disk_full_test`. ANY module `use`ing that case MUST stay `async: false`.
- **`store_test` / `store_summary_test`** also terminate/restart the app-level `EvoGit.Store` + `EvoGit.TaskRegistry` and register an isolated Store under the canonical name.

Genuinely `async: true` (verified to mutate no shared global): `attachments_test`, `cli_test`, `epmd_dist_test`, `executable_test`, `path_suggestions_test`, `peak_hours_test`, `powershell_test`, `project_config_test`, `prompt_file_test`, `remote_bootstrap_test`, `remote_node_test`, `review_test`, `skills_test`, `skills_hierarchical_test`, `utf8_test`, `req_llm_pool_test` (drives a private standalone Finch, never the production `ReqLLM.Finch`), `store_schema_migration_test` + `migrate_store_test` (raw Xqlite on private temp DBs only).

### store_test / store_summary_test — schema template
Both build a schema-complete SQLite file ONCE in `setup_all` (a real `Store.init` + `GenServer.stop`) and `File.cp!/2` it per test, instead of re-running the DDL per test (~24ms → ~2ms each).
The production `Store`/`TaskRegistry` are terminated for the whole module and restored once.
Do NOT switch these to a single shared DB truncated between tests — several tests mutate the schema (e.g. the projects skip-and-log test re-creates `projects` with INTEGER columns) and inject malformed rows, which would corrupt later tests.

## Notes for Agents — `remote_connection_test.exs` runtime

`bootstrap/1` tests that start the daemon each burn ~1.0s of real time.
The cause is PRODUCTION code, not the test helper: `EvoGit.RemoteConnection.verify_daemon_healthy/3` calls `wait_daemon_active(ssh_target, os, 3, 1000, target)`, whose first act is `Process.sleep(1000)` BEFORE the initial `daemon_running?` check (`apps/evo_git/lib/evo_git/remote_connection.ex`, ~lines 1738-1759).
The test-side `collect_stages/1` helper drains with `after 0` and does NOT wait for anything — do not look there for the cost.
Removing it needs a lib change (check `daemon_running?` first and sleep only between retries, or make the initial delay injectable) — outside this node's write scope; escalate.
