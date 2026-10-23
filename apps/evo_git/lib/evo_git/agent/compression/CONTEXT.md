# Agent Context Compression — two-stage pipeline

## Intent

Context compression relieves a conversation that outgrew its model's window, cheapest stage first: a model-free tool-result pruner always runs, and a summarising LLM checkpoint is paid for only when pruning could not bring the projected token count back under the trigger.
The single entry point is `EvoGit.Agent.ContextCompression.compress_if_needed/2` (called at the top of every `EvoGit.Agent.Runner.loop/1` iteration), which orchestrates both stages; this directory holds the pure sub-modules it composes.
No module here owns a process, writes configuration or uses `try`/`rescue` — the one LLM call lives in `LlmRetry`, and its only scheduler interaction is the LLM slot request.

## Pipeline

`compress_if_needed/2` takes `agent_id:`, `llm_model:` and `llm_generation_params:` and returns the `%LoopState{}` (compressed or untouched) or the terminal `{:error, {:llm_request_rejected, message}}`.
Its work only starts for a conversation shaped `[_system, _first_user | _rest]`; any other shape is returned unchanged.

1. **Gate** — `Threshold.for_model/1` resolves the trigger for that model and `Threshold.exceeded?/2` compares it with `state.total_tokens` (the LAST turn's provider-reported `input + output + reasoning`).
   Below the trigger nothing is logged and no LLM slot is acquired.
2. **Stage 1 — `ToolResultPruner.prune/1`** rewrites the text of `:tool` results OLDER than the recency boundary (head + marker + tail) and collapses their media parts into one placeholder.
   `Threshold.project/3` scales the reported token count by the pruning ratio; when results were pruned and the projection is at or under the trigger, this IS the whole compression and no LLM call happens (the main cost win).
3. **Stage 2 — `Checkpoint.split/2`** splits the PRUNED transcript into `head` (`[system, first_user]`, byte-identical), `old` (to be replaced) and `recent` (the last K turns, verbatim).
   An empty `old` skips stage 2 with a log line — an LLM call would have nothing to replace.
4. **Summary request** — `SummaryPrompt.instruction(Checkpoint.prior_summary(messages))` is appended as ONE `:user` message to the pruned transcript and handed to `LlmRetry.summarise/4`, which owns the slot-per-attempt discipline and the failure classification.
5. **Rebuild** — `Checkpoint.build(messages, summary, turn: state.turn)` yields `head ++ [checkpoint] ++ recent`, and the runtime-context refresh message (`EvoGit.Agent.ContextBuilder.build_context_refresh_message/2`) is appended as the LAST message.

Every compression event — prune-only, nothing-to-replace, blank summary, real checkpoint — increments the agent's compression count and resets `state.total_tokens` to 0, so the stale count cannot retrigger compression before the next LLM call reports a fresh one.
Usage is charged wherever the request was billed: the prune-only paths leave `state.usage` untouched, the blank-summary path adds the spent usage while keeping the PRUNED context (a blank summary must never fabricate a checkpoint that drops the transcript).

## API Surface

| Module | File | Public API |
|---|---|---|
| `EvoGit.Agent.Compression.Recency` | `recency.ex` | `default_keep_recent_turns/0` (4), `turn_of/1` (integer \| nil from `metadata[:turn]`), `boundary(messages, keep \\ 4)` (index of the FIRST message of the protected suffix) |
| `EvoGit.Agent.Compression.ToolResultPruner` | `tool_result_pruner.ex` | `prune(messages, opts \\ [])` → `%{messages:, pruned:, chars_before:, chars_after:}`; `char_count(messages)` |
| `EvoGit.Agent.Compression.Threshold` | `threshold.ex` | `for_model(llm_model)` → `%{threshold:, window:, source: :window \| :config}`; `exceeded?(total_tokens, info)`; `project(total_tokens, chars_before, chars_after)` |
| `EvoGit.Agent.Compression.SummaryPrompt` | `summary_prompt.ex` | `instruction(prior_summary \\ nil)` (the summarising user-message text), `sections/0` (the eight fixed headers), `open_tag/0` / `close_tag/0` (`<compacted-summary>` delimiters) |
| `EvoGit.Agent.Compression.Checkpoint` | `checkpoint.ex` | `split(messages, opts \\ [])` → `%{head:, old:, recent:}`; `build(messages, summary, opts \\ [])` → `%{messages:, replaced:, kept:}`; `checkpoint_message(summary, turn \\ nil)`; `checkpoint?/1`; `prior_summary/1` |
| `EvoGit.Agent.Compression.LlmRetry` | `llm_retry.ex` | `summarise(agent_id, llm_model, context, gen_opts)` → `{:ok, response} \| {:error, {:llm_request_rejected, message}}`; `max_attempts/0` |

## Constraints

- **`[system, first_user]` stays BYTE-IDENTICAL** and the last K turns stay VERBATIM (metadata, turn tags, `tool_call_id`/`tool_calls` pairing intact) — the provider's cached prefix survives every compression.
- **Recency is ONE rule shared by both stages** (`Recency.boundary/2`): the last `keep` distinct turns (turn tags from `metadata[:turn]`, stamped by `ContextBuilder.tag_message_turn/2`) combined with a positional floor of the last `2 * keep` messages, always taking the SMALLER (earlier) index — it protects MORE, never less, and the protected region is one contiguous suffix so neither stage can punch a hole in the middle of the conversation.
- **Pruner candidates are only `:tool` messages strictly below the boundary.** The system prompt, the first user message, every `:user`/`:assistant` message and everything in the recent window are untouched.
- **The pruner never shortens or reorders the message list** and never touches `tool_call_id`/`tool_calls`, so assistant `tool_calls` ↔ tool-result pairing cannot break.
- **Pruning never grows a message:** `chars_after <= chars_before` holds unconditionally (a pathological `:head_chars`/`:tail_chars` override leaves the part alone). A no-op call returns the same list with `pruned: 0`.
- **No raw media payload survives in the old region:** media parts (`:image`, `:image_url`, `:video_url`, `:file`) collapse into ONE text placeholder per message, emitted where the first media part was; `:thinking`/`:provider_block` parts are preserved verbatim.
- `prune/2` opts: `:keep_recent_turns`, `:threshold_chars` (8192), `:head_chars` (4096), `:tail_chars` (1024). Unusable overrides fall back to the defaults instead of raising — this runs on every turn.
- **`Threshold` derives from the model's window, never from a fixed number:** `reserved = clamp(output || 8192, 1024, 32768)`, `raw = min(0.8·W, W - reserved - 65_536)`, `floor = min(32_000, 0.9·W)`, `threshold = raw |> max(floor) |> min(0.9·W)` — so `W = 1_000_000 → 800_000`, `131_072 → 57_344`, `32_768 → 29_491`. Unknown window → `[:llm, :compression_threshold_tokens]` with `source: :config` (no new config keys).
- `Threshold` reads the window through `EvoGit.Config.Schema.LLM.model_metadata/1` (`limits.context` / `limits.output`, tolerant atom/string keys, itself raise-free) — use `case`/`with`, never `try/rescue`.
- `exceeded?/2` is strictly greater-than and total (an unusable info map never fires); `project/3` keeps TOKENS as the unit, is clamped to never exceed the input, and returns the input unchanged when `chars_before == 0` or nothing shrank.
- **The checkpoint is ONE `:user` message** (never `:system`/`:assistant`) carrying the pinned "automatically generated checkpoint … do NOT acknowledge this checkpoint" preamble plus the summary inside `<compacted-summary>`; the retained suffix never starts with an orphaned `:tool` message (the split index rewinds to the assistant message that produced it, never below the head).
- **The summary uses the eight fixed sections in order** (`## Primary Request and Intent`, `## Key Technical Concepts`, `## Files and Code`, `## Errors and Fixes`, `## Pending Jobs`, `## Current Work`, `## Next Step`, `## Critical Context`), preserves exact paths/commands/error strings verbatim, must not mention the summarisation request, and must not reproduce the objective (the first user message is retained).
- **Repeated compactions accumulate:** `SummaryPrompt.instruction/1` merges the previous checkpoint's summary (under `<prior-checkpoint-summary>`, deliberately NOT the checkpoint tags) and `Checkpoint.prior_summary/1` reads it back from the last checkpoint message.
- **`build/3` returns `replaced: 0` with the input list unchanged** when there is nothing old to replace or the summary is blank/non-binary — the caller's signal that nothing was compacted.
- **`LlmRetry.summarise/4` acquires and releases the LLM slot PER ATTEMPT** (`AgentScheduler.with_llm_slot/2` wraps exactly one `stream_text` + `process_stream`), so a backoff sleep happens with the slot FREE and a retrying agent still blocks on slot re-acquisition while the scheduler is paused.
- **`LlmRetry` classification mirrors `ToolDispatch.call_llm_with_retry/5`:** a non-retryable provider rejection (`EvoGit.Agent.LlmError.non_retryable?/1`) returns `{:error, {:llm_request_rejected, message}}` immediately (ONE request, no sleep, no scheduler backoff, message built with the caller's own `gen_opts`/`llm_model` so no scheduler lookup can raise); model exhaustion (`TruncationFeedback.classify_model_exhaustion/1`) reports `AgentScheduler.report_llm_error(..., LlmRetryPolicy.model_exhaustion_delay(15))` once and raises (the long wait belongs to the scheduler backoff + crash-retry, and this loop must stay cancel-safe); an ordinary transient error with attempts left sleeps a short exponential backoff (`:llm_retry_backoff_base_ms`, `Retry.DelayStreams` exponential/randomize/cap 60 s) and retries; attempts exhausted raises.
- **Raising is deliberate — there is no "fall back to the pruned context" degradation.** The retained last-K-turns tail may itself exceed the window, so a silent fallback would only defer the overflow to the very next LLM request (a hard provider error) with no operator-visible signal. Raises are `raise MatchError, term: {:error, reason}`, preserving the pre-existing crash-retry / scheduler-backoff semantics.
- **Runtime-context freshness is APPENDED, never a rewrite of message #1** (`ContextBuilder.build_context_refresh_message/2`, appended as the LAST message whenever a non-blank `<context>` block renders): a CONTEXT.md edit made in the worktree mid-run is visible again while the cacheable prefix stays byte-identical.

## Notes for Agents

- **Recency math must never be re-implemented** in a caller — call `Recency.boundary/2`.
- The sub-modules are TOTAL about unexpected MESSAGE shapes (binary legacy `content`, atom- or string-keyed maps/parts, non-integer opts falling back to defaults) because they run in the per-turn path; passing a non-list message list is out of contract and raises a `FunctionClauseError`.
- The stage-2 attempt budget is the call-time app-env seam `:compression_llm_max_attempts` (default 3) — an operational knob, not a `config.toml` key.
- `EvoGit.Agent.ContextBuilder.refresh_first_user_message/2` still exists and is tested, but compression does not use it: rewriting message #1 would break the provider's cached prefix.

## Test Strategy

- Pure-module tests live in `apps/evo_git/test/evo_git/agent/compression/` (`threshold`, `tool_result_pruner`, `checkpoint`, `summary_prompt`); `Recency`'s boundary rule is exercised through the pruner and checkpoint suites and `LlmRetry` through the orchestrator suites below, so neither has a file of its own. `threshold_test.exs` must be `async: false` because it swaps the global `:llm_model_metadata_fun` seam.
- Orchestration is covered by `test/evo_git/agent/context_compression_test.exs` (gate + usage accumulation, in-memory), `context_compression_stages_test.exs` (a raw-TCP SSE stub driving real `ReqLLM.Response` values) and `context_compression_fail_fast_test.exs` (non-retryable rejection, transient retry, model exhaustion, against `EvoGit.TestLlmServer`).
