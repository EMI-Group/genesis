# EvoGit Agent Behaviour & Tools

## Intent
Contains the `EvoGit.Agent` behaviour module, its LLM tool definitions, data structs for agent state and results, and extracted helper modules for context compression and subagent processing. Each agent is a transient Elixir module that `use EvoGit.Agent` and provides a system prompt, optional tool overrides, and subagent delegation configuration. The `use` macro injects thin defaults and overridable callbacks; the actual agent loop logic lives in the shared `EvoGit.Agent.Runner` module (extracted from the macro to avoid duplicating ~400 lines across 9 agent modules).

**Note:** Agent type implementations (Manager, Executor, etc.) have been moved to `../agents/`. This directory retains the behaviour module, tool library, data structs, and extracted helper modules.

## Routing Table
- `./tools/` → LLM tool modules (17+ tools for file I/O, context, search, shell, etc.)
- `./runner.ex` → `EvoGit.Agent.Runner` — shared agent loop runner extracted from the `__using__` macro (run/3, do_run/2, loop/1, do_turn/1, effective_tools/1, trigger_recovery/2, enter_grace/3, maybe_enter_cancel_grace/1, etc.)
- `./subagent_schemas.ex` → `EvoGit.Agent.SubagentSchemas` — shared subagent tool/schema generation (tools/1, schemas/1), parameterized by agent_module
- `./context_compression.ex` → Context compression helper (compresses chat history when token threshold exceeded)
- `./subagent_processing.ex` → Subagent call processing (builds specs, spawns subagents, merges results)
- `./loop_state.ex` → `LoopState` struct — agent loop state threaded through every turn
- `./result.ex` → `Result` struct — structured output of a completed agent run
- `./output_sanitizer.ex` → Tool output sanitization (UTF-8 repair, ANSI stripping, progress bar removal, configurable truncation)

## API Surface

### Data Structs
| Struct | Purpose |
|---|---|
| `EvoGit.Agent.LoopState` | Agent loop state (enforced keys: `agent_id`, `agent_module`, `depth`, `node_path`, `context`; remaining fields have defaults). Threaded through every turn. |
| `EvoGit.Agent.Result` | Structured result of a completed run (`result`, `commit_sha`; optional `tag`, `branch`, `base_commit`, `repo_id`). The `repo_id` field identifies which repo the result belongs to (`"primary"` or a foreign repo string), automatically populated from the process dictionary. Produced by `CompleteTask`. |

### Helper Modules
| Module | Purpose |
|---|---|
| `EvoGit.Agent.ContextCompression` | Compresses chat history when `total_tokens` exceeds threshold |
| `EvoGit.Agent.SubagentProcessing` | Spawns subagents, resolves cross-repo paths, merges results via octopus merge, formats results for LLM context |
| `EvoGit.Agent.TurnWarning` | Adaptive turn-budget warning system — 3 positional categories (beginning/end/critical) that scale with max_turns, plus a periodic middle reminder based on turns since last subagent delegation. The `:beginning` delegation-strategy warning fires at ~25% of budget (min turn 6); the `:middle` reminder fires every 15 turns (`:high`) / 45 turns (`:low`). Low-level agents (Executor, TaskScheduler, etc.) skip the `:beginning` warning entirely and have a 3x longer middle reminder interval |

### Tool Library (`EvoGit.Agent.Tools`)
| Component | Role |
|---|---|
| `tools.ex` | Central dispatch: `schemas/0` returns tool schemas, `execute/5` dispatches by name |
| Standard tools | `read_file`, `create_files`, `write_file`, `edit_file`, `make_dir`, `read_context`, `write_context`, `edit_context`, `run_bash`, `rg`, `glob`, `list_dir`, `search_web`, `search_context`, `search_history` |
| `CompleteTask` | Special completion tool injected by `use` macro; returns `%Result{}` |

### Delegation Hinting

The framework tracks TWO independent hinting mechanisms, both following the same per-child-directory counter + fire-once architecture:

**Write-tool hint** — When an agent repeatedly *edits* files in a child directory (below its assigned `node_path`), the framework tracks the write-tool call count per child directory. After the count exceeds `delegation_hint_threshold` (default: 5, configurable via `[:scheduler, :delegation_hint_threshold]`), a friendly nudge is appended to the tool output suggesting the agent spawn a subagent for that child directory.

**Read-tool hint** — When a *high-level* agent (delegation_level `:high`) repeatedly *reads/investigates* files in a child directory (via `read_file`, `rg`, `glob`, `list_dir`), the framework tracks the read-tool call count per child directory in a separate counter (`read_delegation_hints`). After the count exceeds `read_delegation_hint_threshold` (default: 8, configurable via `[:scheduler, :read_delegation_hint_threshold]`), a nudge is appended suggesting the agent spawn a `subagent_codebase_investigator`. This only applies to `:high` agents — low-level agents are expected to read files directly.

Both hints are shown only once per child directory (tracked via `hint_shown` flag), and both are suppressed during merge conflict resolution (via `filter_child_paths_if_conflicts/2`).

The hinting logic is implemented in `EvoGit.Agent.ToolDispatch` and `EvoGit.Agent.DelegationHints`:
- `batch_execute_tools/4` executes all standard tool calls in a batch **concurrently** (`Task.async_stream` with `max_concurrency` = batch size — Elixir only accepts positive integers for `max_concurrency`, so the batch size makes every call start immediately), bounded only by the scheduler's tool-slot pool (each parallel task acquires a slot via `AgentScheduler.with_tool_slot/2`, respecting `max_tool_concurrency`). Only the raw tool execution runs in the parallel tasks; the delegation hints are threaded **in index order in the parent process** via `Enum.reduce` (`apply_tool_output_tracking/3`), so hint accumulation stays deterministic — the same holds for the once-per-run redundant-cd warning (`:redundant_cd_warned` process-dictionary flag), which is also applied in the parent.
- `extract_child_paths/4` determines the target child directory from write tool arguments
- `maybe_append_delegation_hint/4` increments counts and appends the hint message
- Hints are stored in `LoopState.delegation_hints` and threaded through the process dictionary

## Design Decisions

### Parallel standard tool call execution (bounded by scheduler tool slots)

Standard (non-subagent) tool calls within a single batch now execute **in parallel**, governed by the scheduler's tool-slot pool (`max_tool_concurrency`, default 2; configurable via `--tool-concurrency` CLI flag / `[scheduler] max_tool_concurrency` TOML). Subagent calls were already parallel (`SubagentProcessing.process_subagent_calls`). `batch_execute_tools/4` uses `Task.async_stream` with `max_concurrency` = batch size (so the scheduler — not a local cap — is the binding constraint; Elixir's `max_concurrency` accepts only positive integers, `:infinity` only works for `timeout`), `ordered: true` (results stay in index order), and `timeout: :infinity` (per-tool timeout enforcement stays inside `execute_tool_with_timeout/7`, which wraps its own `Task.yield(task, tool_timeout) || Task.shutdown(task)` — an outer stream timeout would wrongly kill legitimate long-running tools). Tool-slot acquisition (`AgentScheduler.with_tool_slot/2`) still happens per call inside `execute_tool_with_timeout/7`, unchanged.

**Caveat — parallel committing tools:** `write_context`/`edit_context`/`make_dir` with `commit: true` run git add/commit in the same worktree; when multiple such tools execute in parallel they may contend on git's `index.lock`. The scheduler's `max_tool_concurrency` (default 2) bounds this, but users who see commit contention can lower it via `[scheduler] max_tool_concurrency`.

### Grace Period & Graceful Cancellation (runner-side)

The runner supports two grace kinds, both entered via `Runner.enter_grace/3` (`runner.ex`, `@doc false`), which (1) runs `maybe_recovery_auto_commit/1` FIRST (best-effort auto-commit of uncommitted work — shared by both kinds; for cancel this is exactly "save the changes"), (2) optionally appends a recovery message, (3) sets `in_grace_period: true` + the `grace_turns_remaining` budget, then re-enters `loop/1`.

- **Turn-limit recovery** (`trigger_recovery/2`, unchanged call site `loop/1`: `"max turns (#{max_turns}) exceeded"`): budget **1** — enter grace, one continue attempt → hard-stop. Appends the hardcoded "exceeded the execution limit" warning (`message: :default`), byte-for-byte identical to the pre-budget behavior.
- **Cancel-grace** (`maybe_enter_cancel_grace/1`, called in `loop/1` immediately AFTER `drain_and_inject_user_messages/1`): when the ETS `cancel_requested` flag is set (scheduler-side graceful cancel), the flag is cleared in ETS and the agent enters grace with budget **3** and `message: nil` — NO extra recovery message is appended because the cancel message was already injected into the context via the `pending_user_messages` drain. The agent gets up to 3 turns to wrap up and call `complete_task`.
- **Budget semantics**: `LoopState.grace_turns_remaining` defaults to `0` (not in grace). Entering grace sets it to the budget. Each turn that ends WITHOUT `complete_task` decrements it via `consume_grace_turn/1` at the three call sites in `tool_dispatch.ex` (`handle_protocol_violation`, the `process_llm_response` `{:error, :protocol_violation}` branch, and `continue_after_tools`). `grace_period_continue_failed?/1` (`agent.ex`) is budget-aware: `in_grace_period: true, grace_turns_remaining: n` → `n <= 1` (and `in_grace_period: false` → `false`; a grace state with counter 0 — the struct default — hard-stops, preserving legacy one-turn behavior). When it returns `true` the call sites return `{:error, :recovery_failed}` (no new error atom).
- **complete_task during grace**: `handle_complete_call`'s dirty-workspace check skip (`not state.in_grace_period and ...`) applies to BOTH grace kinds — completing with a dirty workspace is allowed during any grace period.
- **Turn counts pinned**: cancel-grace budget 3 → first continue 3→2 (allowed), second 2→1 (allowed), third 1 → hard-stop (3 grace turns total). Turn-limit budget 1 → hard-stop on the first continue (1 grace turn), identical to the pre-budget behavior. `trigger_turn_limit_recovery?/1` is unchanged (returns `false` during grace — no re-trigger).

## LLM Request Retry Mechanism (3 layers — investigated 2026-08)

**Layer 1 — EvoGit outer loop (`call_llm_with_retry/5`, `tool_dispatch.ex:187-225`):** `retry with: exponential_backoff(1_000) |> randomize() |> cap(60_000) |> Stream.take(max_retries)` (tool_dispatch.ex:189-193) with `AgentScheduler.with_llm_slot(agent_id, fn -> ... end)` **INSIDE the retry block** — each attempt acquires the LLM slot for ONE `ReqLLM.stream_text` + `process_stream` and releases it (via `with_llm_slot`'s `after`) before the backoff sleep runs. Retry-library semantics (`deps/retry`): `delays_from/1` prepends `[0]` to the stream and `Enum.reduce_while` does `:timer.sleep(delay)` then runs the block per element; a block result `{:ok, _, _}` halts, `{:error, _}` continues (default `atoms: [:error]`). Effective delays: 0, ~1s, ~2s, ~4s, ~8s, ~16s, ~32s, then 60s×N — each randomized ±10% (`randomize/1`, delay_streams.ex:101-111). **Total attempts = `max_retries + 1`** (initial + max_retries retries). `max_retries` = `agent_state.max_retries` (tool_dispatch.ex:102), set from scheduler `state.max_retries` at dispatch (`dispatch.ex:79`), config default **15** (`[scheduler] max_retries`, definitions.ex:63-71). **No error-type discrimination at this layer** — every `{:error, reason}` from `ReqLLM.stream_text`/`StreamResponse.process_stream` retries identically (429 == 5xx == timeout == connection error). After the stream is exhausted, `case` at tool_dispatch.ex:213-223 checks `EvoGit.Agent.TruncationFeedback.is_rate_limit_error?(reason)` (string-substring match on `inspect(reason)` for `"rate_limit"`/`"quota"`/`"429"`/`"resource_exhausted"`, truncation_feedback.ex:16-23) → `AgentScheduler.report_llm_error(agent_id, :rate_limit)`; then `{:error, reason}` propagates to `prompt_until_tools_or_limit/5` which **RAISES** `"LLM request failed after N retries"` (tool_dispatch.ex:177) → agent crash → scheduler crash-retry (`agent_max_retries`, default 3, lifecycle.ex:148-186). Retried agents get a fresh worktree + new turn; their next slot request is queued behind the backoff if one is active.

**Layer 2 — ReqLLM inner retries (inside each single `ReqLLM.stream_text/3` call):** chat streaming retries live in `ReqLLM.Streaming.Retry` (`deps/req_llm/lib/req_llm/streaming/retry.ex`, wired at `finch_client.ex:188`). `max_retries` default **3** (retry.ex:31; `finch_client.ex:238` — overridable via `[[llm.models]]` generation params `max_retries`). Only retried: (a) **HTTP 429** — delay = parsed `Retry-After` header (seconds→ms; missing/unparseable/zero → 1000ms; retry.ex:194-196, 211-245); (b) **transport errors before any body data** (`data_received?: false`) — `pool_not_available` → 250ms, `closed`/`timeout`/`econnrefused` → 0ms instant (retry.ex:86-92, 198-209; failure.ex:8). **5xx and other HTTP statuses are NOT retried at this layer** (delivered as `%ReqLLM.Error.API.Request{}` errors; retry.ex:76-108) and no retry once data has started streaming (avoids duplicating partial output). Inner retries use blocking `Process.sleep` (retry.ex:123-125). Non-streaming Req-based paths (e.g. `openai_codex`) use `ReqLLM.Step.Retry` (`step/retry.ex`) — same 429 Retry-After honoring, transient transport reasons → 0ms, `max_retries` default 3 (Req option).

**Layer 3 — scheduler per-model backoff (fires only AFTER the outer loop exhausts):** `AgentScheduler.report_llm_error/2` (agent_scheduler.ex:286-289; handler 880-886) → `Slots.handle_report_llm_error(agent_id, :rate_limit, state)` (slots.ex:162-182): sets per-model `llm_backoff_until[model_id] = now + 60_000`, re-queues ALL waiting agents of that model with the backoff timestamp, schedules `:retry_llm_waiting` in 65s (slots.ex:179 → slots.ex:194-198 → `grant_pending_llm_slots`). New slot requests during backoff are queued (slots.ex:105-109). Non-`:rate_limit` reports are no-ops (slots.ex:184-186). Expired backoffs clear on any grant path (`maybe_clear_model_backoff/2`, slots.ex:492-508). **Scoped per model_id — NOT global** (a rate-limited model doesn't block other models).

**Slot acquired/released PER ATTEMPT — free during backoff sleeps:** `AgentScheduler.with_llm_slot/2` (agent_scheduler.ex:322-332) acquires via blocking `GenServer.call` (`request_llm_slot`, `timeout: :infinity`, agent_scheduler.ex:262-265) and releases via `after` → `release_llm_slot/1` cast (agent_scheduler.ex:277-280). Because the wrapper now sits INSIDE the retry block (per attempt), each attempt holds the slot only for its single `stream_text` + `process_stream`; the outer exponential-backoff sleep (and any inner ReqLLM Retry-After sleep) happens BETWEEN attempts while the slot is FREE. **Pause-scheduler implication:** a retrying agent's next attempt blocks at slot re-acquisition when `AgentScheduler.pause/0` is active (queued `:blocked`, granted on `resume/0`) — pause now takes effect within one backoff delay. (Previously the slot was held for the WHOLE retry stream — worst case ~10 min for a persistently rate-limited model: 16 outer attempts × up to 60s sleeps + inner sleeps ≈ 603s+ — so pause had no effect on a retrying agent until the stream exhausted.) A raise inside the LLM call still propagates immediately: `with_llm_slot`'s `after` releases the slot, and the retry macro only retries `{:error, _}` tuple returns, never raises. `ContextCompression` also uses `with_llm_slot` (context_compression.ex:79-103) but WITHOUT the outer retry loop — single `stream_text` (inner 3-retry only).

## Constraints
- Every agent MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- System prompts MUST NOT contain dynamic state, objectives, or context trees — those are injected as user prompts.
- Read-only agents (`agent_type: :read`) should restrict `available_tools/0` to read-only tools.
- The `complete_task` tool is always injected by the macro; agents need not include it.
- Tool schemas use `ReqLLM.tool/2` format.
- Agents commit before delegating subagents (enforced by auto-commit fallback in scheduler).
- Context compression and subagent processing are extracted to dedicated modules but invoked from the agent loop via callbacks.
- **LoopState discipline**: Agent loop state must always be a `%LoopState{}` struct. Update syntax preserves the struct type.
- **Result discipline**: Agent completion produces `%Result{}` structs. Consumers pattern-match on struct fields rather than using `Map.get/2`.
