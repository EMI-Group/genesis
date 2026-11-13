# Exchange Support Modules

## Intent
This directory holds turn-top input injection, adaptive warnings, grace entry and the injectable dependencies for `EvoGit.Agent.Exchange.run/2` in the parent directory.
These helpers return updated `%EvoGit.Agent.State{}` values but never checkpoint, publish stream activity or write conversation state into ETS themselves.

## API Surface
- `Seams.from_opts/1` resolves `llm_call`, `tool_batch`, `scheduler` and `checkpoint` from an explicit opts key, including explicit nil, before the corresponding call-time `:agent_exchange_*` app-env default.
- `Seams.default_llm_call/0` delegates to the entire `LLMPrompting.prompt_until_tools_or_limit/5` operation, not an individual request or retry attempt.
- The scheduler seam handles only `:drain_inputs`, `:cancel_requested?` and `:clear_cancel`, so it cannot replace LLM slot acquisition, model lookup or the ReqLLM transport.
- `Pending.drain_and_inject_user_messages/2` appends binary or attachment-carrying inputs with the user-authored marker, except the exact scheduler cancellation text, which stays unmarked.
- `Pending.inject_background_job_notices/2` claims finished notices directly from BackgroundJobs for `current_owner_pid() || self()`, appends one neutral notice and skips claiming when the incoming state is already in grace.
- `Warnings.check_limit_warnings/1` checks positional warnings before middle warnings, reads the process-local ConflictState snapshot and appends at most one neutral turn-tagged message.
- `Grace.enter_grace/3` attempts recovery auto-commit before appending the optional message and assigning the grace budget, with both production budgets set to three turns.
- `Grace.maybe_enter_cancel_grace/2` checks and clears the cancel flag before calling `enter_grace/3` with no message because cancellation text is expected to have arrived through Pending.

## Constraints and Test Gotchas
The four seams do not isolate every external effect in these helpers: background notice claims and recovery Git operations remain direct calls.
No lower-level real retry or empty-response-nudge injection seam exists in this directory; replacing `llm_call` bypasses those prompting behaviors entirely.
A scheduler stub must return a list for `:drain_inputs` and false for absent `:cancel_requested?`; the example catch-all `:ok` in Seams documentation is not a safe runnable stub because Pending enumerates the former and Grace treats the latter as truthy.
Warnings are not purely a function of the state struct because conflict suppression reads process-local ConflictState and timestamp tagging uses Agent.Clock.
Recovery Git errors propagate rather than being contained, including a status error with no matching case arm or a failed add/commit match.
Pending drains and background-notice claims have destructive control-plane effects before the next parent-engine checkpoint, and cancel grace clears its flag before a recovery commit can raise, so those effects are not rolled back if the exchange fails before a boundary.
The optional `:now` pin is opts-only and process-local, not one of the four seams and not an app-env setting.
Checkpoint placement and terminal-error behavior belong to the parent `exchange.ex`; these helpers have no independent checkpoint hook.

## Routing Table
This directory has no child subdirectories.
