# evo_git/agent — Agent Test Tree

## Intent

ExUnit suites for the `:evo_git` agent layer (`EvoGit.Agent.*`): the Runner loop (cancel-grace, turn limits/warnings), context building/compression, subagent processing, tool dispatch, and usage/delegation/result/output helpers.
Each file mirrors its source module under `apps/evo_git/lib/evo_git/agent/`.

## Routing Table

- `./tools/` → Per-tool tests (`Tools.execute/5`, individual tool modules, the command shell) — own node.

## Async-Safety Policy (this directory)

A module is `async: true` ONLY if it mutates no BEAM-global state observable by a concurrently running module.
Every `async: false` module names its exact forcing global in its `@moduledoc`; when in doubt, keep `async: false`.

Genuinely `async: true` (pure functions / per-test `:tmp_dir` / process-local state):
`coder_test`, `coder_2_test`, `context_builder_test`, `context_compression_test`, `delegation_hints_test`, `output_sanitizer_test`, `result_test`, `turn_limit_test`, `turn_warning_test`, `truncation_feedback_test`, `usage_test`.

`async: false` and its forcing state:
- `tools_test` — mutates BEAM-global `XDG_CONFIG_HOME` (via the private `with_isolated_config/1` helper) and the `:req_llm` app env.
- `cancel_grace_test` — `:ets.delete_all_objects/1` on the global `:evogit_agent_state` / `:evogit_sched_meta` / `:evogit_archive_records` tables, plus a fixed `agent_id = 1`.
- `subagent_processing_test` — inserts/deletes rows in the app-owned global `:evogit_agent_state` ETS table (fixed agent ids 99_998/99_999).
- `tool_dispatch_retry_slot_test` — drives the global `AgentScheduler` GenServer (`update_config`, `pause`/`resume`) and the shared scheduler ETS tables.
- `tool_dispatch_test` — its parallel-execution test registers agent state in the app-global `:evogit_agent_state` ETS table and acquires slots from the global `EvoGit.AgentScheduler` tool-slot pool.

## Notes for Agents

- Test-env seam for retry-backoff timing: `Application.put_env(:evo_git, :llm_retry_backoff_base_ms, ms)` is read at call time by `EvoGit.Agent.ToolDispatch.retry_backoff_base_ms/0`.
  `tool_dispatch_retry_slot_test` pins it to 75ms (`@retry_backoff_base_ms`) instead of sleeping through the real 1s/2s/4s backoff.
  75ms is the lowest value verified robustly deterministic across 10+ seeds and under concurrent `mix test` load.
  The smallest randomized window (75 × 0.9 = 67.5ms) stays ~27× the measured worst-case connection-refused attempt (1.0-2.5ms over 300 samples) and far above a scheduler round trip (≤0.03ms).
- `tool_dispatch_retry_slot_test` stays state-anchored: it synchronizes on `AgentScheduler.get_llm_slot_status/0` (per-model `used`/`waiting`/`capacity`) and `AgentScheduler.paused?/0` rather than fixed sleeps.
- `tool_dispatch_retry_slot_test`'s one-off ~2.5-3.5s cost is `LLMDB.load/1` decoding llm_db's packaged 8.6 MB `priv/llm_db/snapshot.json` (the first ReqLLM call in a fresh BEAM), paid ONCE in `setup_all/1`.
  It is NOT Finch per-origin pool creation (a fresh destination costs ~2-3ms once the catalog is loaded) and is not reducible from `apps/evo_git/test/` — `setup_all` only stops it being charged to whichever test runs first, it does not lower total wall clock.
- `tool_dispatch_test`'s parallel-shell test proves concurrency by an EVENT-DRIVEN rendezvous: each command appends its start marker, then waits (bounded at 400 × 50ms = 20s) for the PEER's start marker before appending its end marker.
  The concurrency proof is the marker interleaving (`start2` before `end1`) — a serialized run exhausts the bound and fails; no wall-clock bound is asserted.
  The POSIX `run_bash` and Windows `run_powershell` command strings differ and are built by the test's `parallel_marker_commands/1`.
- No fake-LLM harness exists — agent runs to completion are exercised only through error paths (`without_model_profiles/1`, connection-refused model specs).
  Details in `../CONTEXT.md` ("Known Issues & Test Env Notes").
- Same-named `test` cases across different `describe` blocks cover DIFFERENT functions (e.g. in `context_builder_test`, `delegation_hints_test`, `turn_warning_test`) — not duplicates.
- Full-suite parallel-run flakiness is pre-existing and documented in `../CONTEXT.md`.
