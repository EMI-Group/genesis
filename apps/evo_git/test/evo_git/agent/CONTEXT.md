# evo_git/agent — Agent Test Tree

## Intent

ExUnit suites for the `:evo_git` agent layer (`EvoGit.Agent.*`): the Runner loop
(cancel-grace, turn limits/warnings), context building/compression, subagent
processing, tool dispatch, and usage/delegation/result/output helpers.
Each file mirrors its source module under `apps/evo_git/lib/evo_git/agent/`.

## Routing Table

- `./tools/` → Per-tool tests (`Tools.execute/5`, individual tool modules, the command shell) — own node

## Async-Safety Policy (this directory)

A module is `async: true` ONLY if it mutates no BEAM-global state observable by a
concurrently running module. Every `async: false` file names its exact forcing
global in its `@moduledoc`. When in doubt, keep `async: false`.

Genuinely `async: true` (pure functions / per-test `:tmp_dir` / process-local state):
`coder_test`, `coder_2_test`, `context_builder_test`, `context_compression_test`,
`delegation_hints_test`, `output_sanitizer_test`, `result_test`, `turn_limit_test`,
`turn_warning_test`, `truncation_feedback_test`, `usage_test`.

`async: false` and why:

- `tools_test` — mutates BEAM-global `XDG_CONFIG_HOME` (via `with_isolated_config/1`) and the `:req_llm` app env.
- `cancel_grace_test` — `:ets.delete_all_objects/1` on the global `:evogit_agent_state` / `:evogit_sched_meta` / `:evogit_archive_records` tables, plus a fixed `agent_id = 1`.
- `subagent_processing_test` — inserts/deletes rows in the app-owned global `:evogit_agent_state` ETS table (fixed agent ids 99_998/99_999).
- `tool_dispatch_test` / `tool_dispatch_retry_slot_test` — see their `@moduledoc`; the latter drives the global `AgentScheduler` GenServer.

## Notes for Agents

- No fake-LLM harness exists — agent runs to completion are exercised only through
  error paths (`without_model_profiles/1`, connection-refused model specs). Details
  in `../CONTEXT.md` ("Known Issues & Test Env Notes").
- Same-named `test` cases across different `describe` blocks (e.g. in
  `context_builder_test`, `delegation_hints_test`, `turn_warning_test`) cover
  DIFFERENT functions — they are not duplicates.
- Full-suite parallel-run flakiness is pre-existing and documented in `../CONTEXT.md`.
