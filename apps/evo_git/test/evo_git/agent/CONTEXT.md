# evo_git/agent — Agent Test Tree

## Intent

ExUnit suites for the `:evo_git` agent layer (`EvoGit.Agent.*`): the Runner loop (cancel-grace, turn limits/warnings), context building/compression, subagent processing, tool dispatch, and usage/delegation/result/output helpers.
Each file mirrors its source module under `apps/evo_git/lib/evo_git/agent/`.

## Routing Table

- `./tools/` → Per-tool tests (`Tools.execute/5`, individual tool modules, the command shell) — own node.

## Async-Safety Policy (this directory)

A module is `async: true` ONLY if it mutates no BEAM-global state observable by a concurrently running module.
Every `async: false` file names its exact forcing global in its `@moduledoc`; when in doubt, keep `async: false`.

Genuinely `async: true` (pure functions / per-test `:tmp_dir` / process-local state):
`coder_test`, `coder_2_test`, `context_builder_test`, `context_compression_test`, `delegation_hints_test`, `output_sanitizer_test`, `result_test`, `turn_limit_test`, `turn_warning_test`, `truncation_feedback_test`, `usage_test`, `tool_dispatch_test`.

`async: false` and its forcing state:
- `tools_test` — mutates BEAM-global `XDG_CONFIG_HOME` (via `with_isolated_config/1`) and the `:req_llm` app env.
- `cancel_grace_test` — `:ets.delete_all_objects/1` on the global `:evogit_agent_state` / `:evogit_sched_meta` / `:evogit_archive_records` tables, plus a fixed `agent_id = 1`.
- `subagent_processing_test` — inserts/deletes rows in the app-owned global `:evogit_agent_state` ETS table (fixed agent ids 99_998/99_999).
- `tool_dispatch_retry_slot_test` — drives the global `AgentScheduler` GenServer (`update_config`, `pause`/`resume`) and the shared scheduler ETS tables.

## Notes for Agents

- Test-env seam for retry-backoff timing: `Application.put_env(:evo_git, :llm_retry_backoff_base_ms, ms)` is read at call time by `EvoGit.Agent.ToolDispatch.retry_backoff_base_ms/0`.
  `tool_dispatch_retry_slot_test` shrinks it to 250ms instead of sleeping through the real 1s/2s/4s backoff.
- That file stays state-anchored: it synchronizes on `AgentScheduler.get_llm_slot_status/0` (per-model `used`/`waiting`/`capacity`) rather than fixed sleeps.
- `tool_dispatch_test`'s parallel-shell test (`batch_execute_tools/4 parallel execution`, `tool_dispatch_test.exs:444`) asserts NO wall-clock bound; it proves concurrency purely via marker interleaving (`:465`).
  It is flaky in full-suite runs under CPU load: the `markers.txt` read at `:463` sometimes contains only a subset of `start1/start2/end1/end2`.
  Contributing mechanics (verified in source): the parent-level per-tool budget is `min(args["timeout"] || [:scheduler, :default_tool_timeout] = 10s, max_tool_timeout)` (`tool_dispatch.ex:1017-1034`) while the shell tool's own default is 180s (`shell_tool.ex:23`) — on `Task.yield/2` expiry `Task.shutdown/1` kills the shell mid-command, so `endN` lines can be lost while both results still pass the index/tool-name asserts at `:460-461`.
  The interleaving assert (`:465`) additionally REQUIRES ≥2 concurrent tool slots for one agent id (the slot pool is a `MapSet` of agent ids checked against `max_tool_concurrency`, default = CPU thread count) — with capacity 1 the two calls serialize and the assert fails.
  The module is declared `async: true` yet writes a row into the global `:evogit_agent_state` ETS table and takes real slots from the global scheduler.
- No fake-LLM harness exists — agent runs to completion are exercised only through error paths (`without_model_profiles/1`, connection-refused model specs).
  Details in `../CONTEXT.md` ("Known Issues & Test Env Notes").
- Same-named `test` cases across different `describe` blocks cover DIFFERENT functions (e.g. in `context_builder_test`, `delegation_hints_test`, `turn_warning_test`) — not duplicates.
- Full-suite parallel-run flakiness is pre-existing and documented in `../CONTEXT.md`.
