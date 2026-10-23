# Agent Context Compression — stages and trigger

## Intent

Pure leaf modules of the multi-stage context-compression design.
Two cheap, model-free stages run BEFORE any summarising LLM call, so an LLM checkpoint is only paid for when mechanical shrinking was not enough:

1. `ToolResultPruner` — shrinks raw tool output in the OLD part of the transcript (no LLM call).
2. `Threshold` — decides WHEN compression should run at all, relative to the model's own context window.

`Recency` is the single source of truth both stages share for "which messages are recent", so no two stages can disagree about what recent work means.
The orchestration that calls these modules lives one level up in `../context_compression.ex` — this directory contains no I/O, no processes, no configuration writes and no `try/rescue`.

## API Surface

| Module | File | Public API |
|---|---|---|
| `EvoGit.Agent.Compression.Recency` | `recency.ex` | `default_keep_recent_turns/0` (4), `turn_of/1` (integer \| nil from `metadata[:turn]`), `boundary(messages, keep \\ 4)` (index of the FIRST message in the protected suffix; protects MORE, never less — turn cutoff combined with a positional floor of the last `2 * keep`) |
| `EvoGit.Agent.Compression.ToolResultPruner` | `tool_result_pruner.ex` | `prune(messages, opts \\ [])` → `%{messages:, pruned:, chars_before:, chars_after:}`; `char_count(messages)` |
| `EvoGit.Agent.Compression.Threshold` | `threshold.ex` | `for_model(llm_model)` → `%{threshold:, window:, source: :window \| :config}`; `exceeded?(total_tokens, info)`; `project(total_tokens, chars_before, chars_after)` |

## Constraints

- **Candidates are only `:tool` messages strictly below `Recency.boundary/2`.** The system prompt, the objective/first user message, every `:user`/`:assistant` message and everything in the recent window are byte-identical after a prune.
- **The message list is never shortened or reordered** and `tool_call_id`/`tool_calls` are never touched, so assistant `tool_calls` ↔ tool-result pairing cannot break.
- **Pruning never grows a message:** `chars_after <= chars_before` holds unconditionally (a pathological `:head_chars`/`:tail_chars` override leaves the part alone).
- **No raw media payload survives** in the old region: media parts (`:image`, `:image_url`, `:video_url`, `:file`) collapse into ONE text placeholder per message, emitted where the first media part was. `:thinking`/`:provider_block` parts are preserved verbatim.
- `prune/2` opts: `:keep_recent_turns`, `:threshold_chars` (8192), `:head_chars` (4096), `:tail_chars` (1024). Unusable overrides fall back to the defaults instead of raising — this runs on every turn.
- **`Threshold` derives from the window, never from a fixed number:** `reserved = clamp(output || 8192, 1024, 32768)`, `raw = min(0.8·W, W - reserved - 65_536)`, `floor = min(32_000, 0.9·W)`, `threshold = raw |> max(floor) |> min(0.9·W)`. Unknown window → `[:llm, :compression_threshold_tokens]` with `source: :config` (no new config keys).
- `Threshold` reads the window through `EvoGit.Config.Schema.LLM.model_metadata/1` (tolerant atom/string keys, itself raise-free) — use `case`/`with`, never `try/rescue`.
- `exceeded?/2` is strictly greater-than and total (an unusable info map never fires).
- `project/3` keeps TOKENS as the unit: `state.total_tokens` is the last turn's provider-reported `input + output + reasoning`, so a character ratio is a sound approximation of the saving; it is clamped to never exceed the input and returns the input unchanged when `chars_before == 0` or nothing shrank.

## Notes for Agents

- **Recency math must never be re-implemented** in a caller — call `Recency.boundary/2`.
- Both stages are TOTAL rather than raising on unexpected shapes (non-list messages, binary legacy `content`, non-integer opts) because they run in the per-turn path.
- Tests for these modules belong at `apps/evo_git/test/evo_git/agent/compression/` (`threshold_test.exs` must be `async: false` — it swaps the global `:llm_model_metadata_fun` seam).
