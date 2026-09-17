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
- `subagent_processing_test` — inserts/deletes rows in the app-owned global `:evogit_agent_state` ETS table (fixed agent ids 99_998/99_999) and in `:evogit_sched_meta` (parent ids 99_001/99_002 for the `store_sub_result/4` round-trip).
- `tool_dispatch_retry_slot_test` — drives the global `AgentScheduler` GenServer (`update_config`, `pause`/`resume`) and the shared scheduler ETS tables; its model-exhaustion (402) tests also read/clear the live per-model LLM backoff through `:sys.get_state/1` + `:sys.replace_state/2` (`purge_llm_pool/1`, `clear_model_backoff/0`).
- `llm_retry_policy_test` — mutates the app-env model-exhaustion seams `:llm_model_exhaustion_backoff_base_ms` / `:llm_model_exhaustion_backoff_cap_ms` (restored via `on_exit`); the sibling `async: false` `tool_dispatch_retry_slot_test` reads those same keys, so the two must not run concurrently.
- `tool_dispatch_test` — its parallel-execution test registers agent state in the app-global `:evogit_agent_state` ETS table and acquires slots from the global `EvoGit.AgentScheduler` tool-slot pool.

## Writable Foreign-Repo Coverage in This Node (file:line)

- Authority text — `context_builder_test.exs` `describe "build_authority_section/1"` (lines 219-287), 4 pure `async: true` tests: repo_less yields `""` even with a writable non-primary foreign repo (220); `""` for an empty list AND for a primary-only list (230); ROOT block for `parent_id: nil` + a non-primary repo (246 — asserts `"ROOT agent"`, `"You MAY spawn write-capable"`, `"one at a time"`, refutes `"NESTED"`); NESTED block for an integer `parent_id` (267 — asserts `"NESTED agent"`, `"NOT the root agent"`, `"may NOT spawn write-capable"`, `"report the need back up to your parent agent"`).
- Spawn-gate rejection shapes — `subagent_processing_test.exs` `describe "format_subagent_result/1"`: `{:foreign_repo_read_only, msg}` at 197 and 205, `{:foreign_repo_write_not_root, msg}` at 213, `{:foreign_repo_write_serialized, msg}` at 223 — all assert the `"Error: #{msg}"` pass-through, with HAND-WRITTEN messages (not the production wording).
- Foreign-repo phylo starting commit — `subagent_processing_test.exs` `describe "build_subagent_specs/3 — foreign repo phylo nodes"` (496-919, needs real git repos + the global `:evogit_agent_state` ETS table): missing root → `{:error, {call, 0, msg =~ "does not exist or is not a git repository"}}` (624); `base_sha` honored as `base_commit`/`current_commit` (647); `base_sha` beats the tracked `foreign_repo_commits` map (677, passes `%{"orig" => sha2}`); invalid `base_sha` → error (714).
- Roll-up authority coupled to the REAL builder — same `subagent_processing_test.exs` describe (746, 776, 810, 854): every spec is derived from the production `SubagentProcessing.build_subagent_specs/3` (never hand-built) and fed to `EvoGit.AgentScheduler.Subagents.writable_foreign_repo_agent?/1`. Positive: an ABSOLUTE spawn into a writable `%ForeignRepo{}` (parent module = `ForeignWriteDummyAgentModule` listing `EvoGit.Agents.Executor`, call `"subagent_executor"`) → `repo_id == "orig"` + predicate `true` (746). Relative delegation from a foreign-repo PARENT (parent's `Process.put(:repo_path, foreign_root)` + its `AgentState.repo_id` set to `"orig"` in the global `:evogit_agent_state` ETS row) → the child INHERITS `repo_id == "orig"` + predicate `true` (776); the resolution test (810) additionally proves `Dispatch.resolve_agent_repo_root(spec, nil) == foreign_root`, `phylo_node.base_commit == current_commit == "abc123"` (the parent's live commit via the same-repo clause, NOT the foreign `base_sha`/HEAD), and `:ok == Subagents.validate_spatial_contract_for_spec/4` (a same-repo spawn inside the foreign repo is UNRESTRICTED by the spawn gate). Round-trip: `Subagents.store_sub_result/4` fed that real-builder spec + `{:ok, %Result{commit_sha: sha, repo_id: "orig"}}` advances `EvoGit.AgentScheduler.get_foreign_repo_commits/1` to `%{"orig" => sha}`, while a relative spec from a `"primary"`-repo parent fed the same payload records nothing (`%{}`) (854).
- `Result.foreign_repo_commits` — `result_test.exs` only: default `%{}` (32) and option round-trip (37, 79-105). Pure struct construction; no runtime path.
- Tool-layer write gating — `tools_test.exs` `describe "execute/5 - read-only foreign repo write gate"` (885-961): 7 write tools incl. `run_git`/`curl` blocked in a read-only foreign repo (886), JSON-encoded args form blocked (906), writes ALLOWED in a writable foreign repo (921) / the primary (934) / with no foreign repos (949).
- Archive record — `tools/complete_task_test.exs:687,733-738` asserts `record.foreign_repos` carries the repo struct's `id`/`root`/`description` only (NOT `writable`/`base_sha`).

### Coverage Gaps (this node)

- No integration test for the authority section's call site: `build_authority_section/1` is unit-tested only; `runner.ex:107-123` (the `Process.get(:repo_less)` flag + the blank-filter ordering `[context_tree, authority_section, foreign_repos_section, repo_notes_section]`) is untested.
- Precedence step 2 never proves a WIN: no test passes a foreign repo with `base_sha: nil` PLUS a `foreign_repo_commits` entry and asserts the tracked sha becomes the starting commit; step 3's SUCCESS path is exercised by the roll-up tests' real-builder specs (`base_sha: nil` + empty tracked map + an existing repo) but its resolved foreign-HEAD commit is never asserted — only step 3's error branch is asserted (missing root, 624).
- The rejection-shape tests use hand-written messages on both sides: nothing asserts the production read-only wording (`agent_scheduler/subagents.ex:284-297`) — the test named "…with real message…" (205) uses a fabricated string — and no test feeds a REAL `Subagents.validate_spatial_contract_for_spec/4` rejection tuple into `format_subagent_result/1`.
- The `Result.foreign_repo_commits` per-repo subtree-map FIELD as a runtime carrier is untested here — the `store_sub_result/4` round-trip (854) asserts only the direct `commit_sha`/`repo_id` recording path (its `%Result{}` carries no `foreign_repo_commits`), so nothing proves a result carrying a non-empty `foreign_repo_commits` merges child-wins into the parent's map. The child-wins roll-up lives in the sibling node (`agent_scheduler/subagents_test.exs:587-667`, incl. "updates existing foreign repo commit to latest SHA" at 652-667; `Lifecycle.inject_foreign_repo_commits/2` at `agent_scheduler/lifecycle_test.exs:799-866`) — and even there the `Map.merge(parent.foreign_repo_commits, child_frc)` SUBTREE branch (`agent_scheduler/subagents.ex:401-402`) is uncovered (every `%Result{}` there is built without `foreign_repo_commits`, so `child_frc` is always `%{}`).

## Notes for Agents

- Test-env seam for retry-backoff timing: `Application.put_env(:evo_git, :llm_retry_backoff_base_ms, ms)` is read at call time by `EvoGit.Agent.ToolDispatch.retry_backoff_base_ms/0`.
  `tool_dispatch_retry_slot_test` pins it to 75ms (`@retry_backoff_base_ms`) instead of sleeping through the real 1s/2s/4s backoff.
  75ms is the lowest value verified robustly deterministic across 10+ seeds and under concurrent `mix test` load.
  The smallest randomized window (75 × 0.9 = 67.5ms) stays ~27× the measured worst-case connection-refused attempt (1.0-2.5ms over 300 samples) and far above a scheduler round trip (≤0.03ms).
- Model-exhaustion (HTTP 402 "insufficient balance") retry timing has TWO app-env seams, read at call time by `EvoGit.Agent.LlmRetryPolicy`: `:llm_model_exhaustion_backoff_base_ms` (default 60_000) and `:llm_model_exhaustion_backoff_cap_ms` (default 28_800_000).
  `llm_retry_policy_test` (NEW) shrinks them (10/80 → a 15-entry, 1.03s-total schedule) to pin the schedule math; production keeps the 60s-doubling-to-8h default.
  Tests must NEVER sleep hours: `tool_dispatch_retry_slot_test`'s 402 tests assert the DEFAULT 60s / 8h backoff by reading the scheduler's `llm_backoff_until` and by asserting the retry queues behind it (`AgentScheduler.get_llm_slot_status/0`) — the wait itself is never performed (the blocked task is killed and its pool purged in `on_exit`).
- `EvoGit.TestLlmServer` (`test/support/llm_server.ex`) is the raw-TCP HTTP/1.1 harness for real LLM HTTP error responses: `start!/2` (status + body) returns a `%{port:, url:}` whose `url` is handed to a fake model spec's `base_url`, so ReqLLM surfaces a genuine `%ReqLLM.Error.API.Request{}` (e.g. 402) to the retry loop.
- `tool_dispatch_retry_slot_test` stays state-anchored: it synchronizes on `AgentScheduler.get_llm_slot_status/0` (per-model `used`/`waiting`/`capacity`) and `AgentScheduler.paused?/0` rather than fixed sleeps.
  Its two slot-re-acquisition tests are built so NO assertion depends on the test process winning a wall-clock race against the retrying agent's backoff windows.
  In "releases the LLM slot between retry attempts", the probe agent's slot request is PRE-QUEUED from a separate `Task` while the owner still holds the only slot (asserted via `await_llm_waiting(2)`), so the SCHEDULER's own release sweep — not a reactive re-acquisition by the test process — grants the probe inside the between-attempts interval; the retrying agent's next attempt then provably re-queues behind the probe's persistently-held slot.
  In "a paused scheduler blocks the retrying agent's next attempt at slot re-acquisition", `AgentScheduler.pause/0` is called BEFORE the owner's slot is released, so the pause is in place before ANY attempt acquires the slot — this relies on the verified fact that the release sweep is not paused-gated (`Slots.handle_release_llm_slot/2` → `grant_pending_llm_slots/1` has no `paused` check), which lets the queued first attempt run while its successor is then blocked by the pause (`used: 0` + `waiting: 1` + `paused: true`).
  Grant order is deterministic: the probe (`@probe_agent_id`) has its `:evogit_sched_meta` row deleted so it sits at the absent-default depth (`Slots.depth_of/1` → 999), and `better_entry/5` prefers the EARLIER queue entry on a full tie, so the first attempt is always granted before the probe.
  Cleanup releases all three agent ids (`@slot_owner_agent_id`, the retrying agent, `@probe_agent_id`) twice from ONE `on_exit` process (ordered casts) so a flunked assertion cannot leave a holder that a later release-sweep would otherwise promote from the waiting queue.
- `tool_dispatch_retry_slot_test`'s one-off ~2.5-3.5s cost is `LLMDB.load/1` decoding llm_db's packaged 8.6 MB `priv/llm_db/snapshot.json` (the first ReqLLM call in a fresh BEAM), paid ONCE in `setup_all/1`.
  It is NOT Finch per-origin pool creation (a fresh destination costs ~2-3ms once the catalog is loaded) and is not reducible from `apps/evo_git/test/` — `setup_all` only stops it being charged to whichever test runs first, it does not lower total wall clock.
- `tool_dispatch_test`'s parallel-shell test proves concurrency by an EVENT-DRIVEN rendezvous: each command appends its start marker, then waits (bounded at 400 × 50ms = 20s) for the PEER's start marker before appending its end marker.
  The concurrency proof is the marker interleaving (`start2` before `end1`) — a serialized run exhausts the bound and fails; no wall-clock bound is asserted.
  The POSIX `run_bash` and Windows `run_powershell` command strings differ and are built by the test's `parallel_marker_commands/1`.
- The only fake-LLM harness is `EvoGit.TestLlmServer` (raw-TCP, answers a fixed status + JSON body); agent runs to COMPLETION are still exercised only through error paths (`without_model_profiles/1`, connection-refused model specs, and the test server's HTTP 402).
  Details in `../CONTEXT.md` ("Known Issues & Test Env Notes").
- Same-named `test` cases across different `describe` blocks cover DIFFERENT functions (e.g. in `context_builder_test`, `delegation_hints_test`, `turn_warning_test`) — not duplicates.
- `subagent_processing_test.exs` runs slightly over the ~1000-line soft cap (~1046 lines) because it is ONE comprehensive suite over the subagent-processing surface (path resolution, phylo-node building, spawn-gate result formatting, real-builder authority coupling, model-id inheritance) sharing the same global-ETS + real-git-repo setup — splitting it would duplicate that setup for no cohesion gain, so it is intentionally NOT split. Prefer adding new subagent-processing tests to an existing `describe` block here.
- Full-suite parallel-run flakiness is pre-existing and documented in `../CONTEXT.md`.
