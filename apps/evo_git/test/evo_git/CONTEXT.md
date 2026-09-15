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
