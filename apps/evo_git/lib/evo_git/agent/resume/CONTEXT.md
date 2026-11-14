# EvoGit Agent Resume — `agent/resume/`

## Intent

A run that dies in the middle of a tool batch is crash-retried by the scheduler, which restores its durable transcript; this node makes that restored transcript provider-valid and tells the agent what happened, so the retried run continues instead of failing on an unpaired `tool_call_id`.
The entry point is `EvoGit.Agent.Resume.apply/1`, called ONCE at the very top of `EvoGit.Agent.Exchange.run/2` before the loop, so the FIRST provider call of a resumed run already sees the repaired transcript plus the ONE `[RESUME]` notice.
It runs ONLY for a genuine CRASH RETRY: `state.resume_info` says the dispatch ctx carried `restore_agent_state: true` AND `persistent_state` is enabled — a fresh agent, an interactive session's `start_input/3` resume, a merge/resume follow-up and `persistent_state: false` pass through untouched.
The in-flight marker (`state.pending_tool_batch`) supplies PROVENANCE (which turn, which calls, which class); the transcript supplies the TRUTH (is the final assistant message's `tool_calls` actually unanswered).

## API Surface

| Module | Function | Role |
|---|---|---|
| `EvoGit.Agent.Resume` | `apply(%State{})`, `apply(%State{}, opts)` | Repairs + annotates a crash-resumed state → `%State{}`; TOTAL, so a malformed state/context/option returns the input unchanged. |
| `EvoGit.Agent.Resume` | `crash_retry?(%State{})` | `true` only when `persistent_state` is on AND `resume_info[:restore_agent_state] == true`; an absent/malformed `resume_info` or an opt-out answers `false`. |
| `EvoGit.Agent.Resume` | `clear_marker(%State{})` | The total field write that clears the in-flight marker; used by every path that stops executing a batch. |
| `EvoGit.Agent.Resume` | `dangling(%State{})` | `{:ok, turn, calls}` for the unanswered calls of the FINAL assistant message, in the assistant's call order, else `:none` (only a dangling TAIL is repairable). |
| `EvoGit.Agent.Resume` | `notice_present?(context)` | The exactly-once guard: `true` when the transcript already carries a `[RESUME]` notice (`metadata[:resume_notice]`). |
| `EvoGit.Agent.Resume.Notice` | `text(%State{}, batch)`, `facts(%State{}, batch)` | The ONE `[RESUME]` notice text and the facts it is built from; every absent fact (retries, retry reason, salvaged commit, restore outcome) DROPS its sentence instead of asserting a guess. |
| `EvoGit.Agent.Resume.ToolBatch` | `impact(class, call)` | The honest synthetic tool-result TEXT for one interrupted call (`:subagent` answers the re-attach FALLBACK text); never fabricates success and never invents output. |
| `EvoGit.Agent.Resume.Reattach` | `resolve(%State{}, slots, opts \\ [])` | ONE batch-level subagent re-attach → `%{texts: %{model_call_index => text}, merge_note: String.t() \| nil}`. |
| `EvoGit.Agent.Resume.Reattach` | `empty/0`, `default_reattach_fun/0` | The empty answer (every call falls back) and the DEFAULT injection, `&EvoGit.AgentScheduler.reattach_sub_agents/2` (the `agent_id, expected_count` subset of `/3`). |

`apply/2`'s ONLY option is `:reattach_fun` (`fn agent_id, expected_count -> reply`) — an explicit option, never an app-env seam.

## Constraints

- **Repair appends, never rewrites**: ONE synthetic `:tool` result per unanswered call, in the assistant's call order, built with the SAME `EvoGit.Agent.ToolDispatch.assemble_tool_result/3` and turn-tagged with `ContextBuilder.tag_message_turn/2` exactly like a real result (the assistant message's own `metadata[:turn]`, else `state.turn`).
- **The prompt-cache prefix is untouchable**: neither repair nor notice ever modifies the system message or the first user message, so `[system, first_user]` stays byte-identical across a resume.
- **The notice is harness text**: exactly ONE `[RESUME]`-framed `:user` message from `ContextBuilder.build_injected_message/2`, never `EvoGit.Agent.MessageMarker`-flagged as user-authored, and `metadata[:resume_notice]` makes a second resumed exchange append nothing.
- **Totality**: no raises, no LLM call; every re-attach, formatting, node-path and merge failure degrades to the honest fallback text with a `Logger.warning` — a repair can never crash the exchange.
- **The class is provenance-first**: the marker entry for the same provider `id` wins, then the entry at the same `index`, and only an absent marker re-derives it from the call name via `EvoGit.Agent.ToolBatch.class/2`.
- **ONE re-attach call per interrupted batch**: `expected_count` is the number of `:subagent` calls of the interrupted turn, the answered batch maps onto those calls BY POSITION (sub-agent index ↔ subagent-call order), and a malformed/`{:error, _}` reply answers the WHOLE batch with fallback text — never a partial guess.
- **A real result's text is UNCHANGED**: `SubagentProcessing.format_subagent_result/1` output is passed through verbatim; only an unavailable slot, a raising/blank formatting, or an un-runnable merge replaces it with the fallback.
- **A same-repo child MUST be merged**: the resumed worktree is based on the SALVAGED commit while the child's commits live on its own branch, so every real same-repo child is merged through `SubagentProcessing.perform_merge/3` + `delete_merged_branches/2` and reported with the ordinary `build_merge_message/4` note appended as ONE turn-tagged `:user` message; a merge that cannot RUN degrades those calls to fallback text (reporting work that is not in the tree would be a lie), while a merge that runs keeps the real text and the ordinary report.
- **Cross-repo children are never merged**: a `result.repo_id` that is non-nil and differs from the parent's is a foreign-repo child, exactly as on the spawn path; `nil` or the parent's own id is same-repo.
- **The merge-child map is shaped in ONE place**: `SubagentProcessing.merge_child/5`, shared with the spawn path; an absent `node_path` is re-derived best-effort from the interrupted call and degrades to root ownership (the most permissive), never a lost commit.
- **The marker is always cleared** by the time `apply/2` returns — repair exists to close it — and `persistent_state: false` writes no marker, no repair and no notice.
- **Bounded, deliberate blocking**: the re-attach wait inside `EvoGit.AgentScheduler.reattach_sub_agents/3` (`opts[:timeout]` → `:agent_resume_reattach_timeout_ms` → 1_800_000 ms) is the ONLY non-total step, and it is fully guarded here.
- **The batch is in-memory**: the scheduler keeps it on the parent's `%SchedMeta{}` row, so a scheduler/BEAM restart reports every unresolved slot as `{:error, :subagent_result_lost}` and those calls take the fallback text.

## Routing Table

- `../CONTEXT.md` → the exchange engine, `%EvoGit.Agent.State{}`, the pre-batch checkpoint and the marker invariant (§ Durable Per-Agent State).
- `../session/CONTEXT.md` → the session's checkpoint adoption rule, `resume_info` provenance and the crashed-worker retry path.
- `../tool_batch.ex` → `EvoGit.Agent.ToolBatch`, the marker model, its classes and `normalize/1`.
- `../../agent_state/CONTEXT.md` → the durable store, `Record`'s column mapping and the `agent_states.pending_tool_batch` JSON column.
- `../../../agent_scheduler/CONTEXT.md` → `reattach_sub_agents/3`, `SubagentReattach`, `Salvage`/`WorktreeManager.salvage_for_retry/2`, `Lifecycle.retry_agent/4` and `Dispatch.apply_crash_base/5`.
- `../subagent_processing.ex` → `format_subagent_result/1`, `perform_merge/3`, `delete_merged_branches/2`, `build_merge_message/4`, `merge_child/5`, `resolve_subagent_path/4`.
