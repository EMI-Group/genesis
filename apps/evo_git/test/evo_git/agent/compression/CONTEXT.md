# Agent Compression — Test Tree

## Intent

ExUnit suites for `apps/evo_git/lib/evo_git/agent/compression/` — the two-stage context-compression subsystem of the agent loop.
Every file mirrors its source module and works on in-memory `ReqLLM.Message` fixtures (no git, no network, no LLM call).
The compression ORCHESTRATION tests live one node up (`../` — `context_compression_test`, `context_compression_stages_test`, `context_compression_fail_fast_test`).

## API Surface (files)

| File | Covers |
|---|---|
| `recency_test.exs` | `Recency` — `default_*`, `tail_budget/1` (incl. both app-env seams), `char_count/1`, `estimate_tokens/1` (the ONE chars→tokens estimator), `synthetic?/1`, `turn_of/1`, `boundary/3` (turn rule, positional floor, tail budget, tool-result rewind), and `shrink_to_budget/2` |
| `checkpoint_test.exs` | `Checkpoint` — `split/2`, `build/3` (`replaced`/`kept`/`estimated_tokens`/`pre_estimate`/`budget`/`shrunk`), `checkpoint_message/2`, `checkpoint?/1`, `prior_summary/1`, plus the repeated-compaction and oversized-tail regressions |
| `tool_result_pruner_test.exs` | `ToolResultPruner` (stage 1, model-free tool-result pruning + media placeholder) |
| `threshold_test.exs` | `Threshold` window-relative threshold selection (window from the CONFIGURED profile, never catalog metadata) |
| `summary_prompt_test.exs` | `SummaryPrompt` delimiters/instruction text |

## Constraints

`recency_test.exs` is `async: false` because its seam tests mutate the app-env keys `:compression_tail_budget_fraction` / `:compression_tail_budget_tokens`, read at CALL time by `Recency.tail_budget/1` and exercised concurrently by `checkpoint_test` / `tool_result_pruner_test`; `setup` clears both and `on_exit` restores the operator's values.
`threshold_test.exs` is `async: false` because it swaps the `:llm_model_metadata_fun` seam, which `EvoGit.Config.Schema.LLM.model_metadata/1` reads at CALL time on every agent spawn (`profile_generation_params/1` → `LLMConstraints.filter/3`) as well as in `Threshold`; the `[llm]` threshold/pruning overrides have no app-env seam, so its config dir is isolated PER PROCESS via `EvoGit.TestSupport.ConfigDir.isolate!/1` instead of mutating `XDG_CONFIG_HOME`.
The remaining suites are pure and `async: true`.
`shrink_to_budget/2` is the only step that can shrink a protected suffix whose MINIMAL pairing-safe form (assistant call + its results) is itself over budget — `boundary/3` never protects less than that, which is why an over-budget suffix used to survive every rebuild.
Contract of `shrink_to_budget/2`: `%{messages, truncated, estimated_tokens}`; `:budget` (positive integer) wins over `:context_window`/`:tail_budget_fraction`/`:tail_budget_tokens`; empty/non-list input comes back untouched with a zero estimate.
Message truncation only rewrites `:text` parts (head ~75 % / tail ~25 % of `4 * allowance` chars plus `… [truncated N characters] …`) and preserves role, metadata, `tool_calls`, `tool_call_id` and non-text parts.
When truncation cannot fit the budget, whole LEADING messages are dropped (an assistant `tool_calls` message with its `:tool` results), so the result never starts on a `:tool` message, may reach `[]`, and `truncated` counts truncated MESSAGES only.
`Checkpoint.build/3` runs it on the retained tail AFTER the existing progress-guard trimming, sets `shrunk: true` on truncation, and reports `kept` + `estimated_tokens` for the final list.
Oversized-tail fixtures (`checkpoint_test`) deliberately give the OLD span expensive content so `pre_estimate` stays far above the budget — otherwise the progress guard empties the tail and the shrink step is never reached.
Assertions on the truncation marker use the regex `~r/… \[truncated \d+ characters\] …/u` rather than the exact character count.
