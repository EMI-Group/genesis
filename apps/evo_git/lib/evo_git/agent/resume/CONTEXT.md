# EvoGit Agent Resume — `agent/resume/`

## Intent

A restored run's transcript is made provider-valid and the agent is told what happened, so the run continues instead of failing on an unpaired `tool_call_id`.
The entry point is `EvoGit.Agent.Resume.apply/1,2`, called ONCE at the very top of `EvoGit.Agent.Exchange.run/2` before the loop, so the FIRST provider call of a resumed run already sees the repaired transcript plus the ONE notice.
It runs ONLY for a RESTORED RUN: `state.resume_info` says the dispatch ctx carried `restore_agent_state: true` AND `persistent_state` is enabled — a fresh agent, an interactive session's `start_input/3` resume, a merge/resume follow-up and `persistent_state: false` pass through untouched.
The in-flight marker (`state.pending_tool_batch`) supplies PROVENANCE (which turn, which calls, which class); the transcript supplies the TRUTH (is the final assistant message's `tool_calls` actually unanswered).
A subagent call is answered from the batch that survived in the scheduler, and failing that from the children's DURABLE rows — a post-restart batch is rebuilt, not assumed lost.

## Resume kinds & the narration matrix

`resume_info[:resume_kind]` (built by `EvoGit.Agent.Session.Setup.build_initial_state/3` from the dispatch ctx) selects the narration; `EvoGit.Agent.Resume.resume_kind/1` answers `:clean_pause | :dirty_pause | nil`.

| `resume_kind` | Meaning | Repair | Notice |
|---|---|---|---|
| absent (`nil`) | CRASH RETRY (today's semantics, byte-identical) | synthetic tool results + one batch re-attach (or a durable-roster rebuild when no in-memory batch survived) | ONE `[RESUME]` notice |
| `:dirty_pause` | task-level pause brought back by a host RESTART, so the last batch may be partially executed | the SAME crash repair | ONE `[RESUME]` notice, plus the pause/restart sentence and the subagent sentence |
| `:clean_pause` | the user paused the task at a TURN BOUNDARY and resumed it | NONE — nothing was interrupted, so no `tool_calls` tail is dangling and no marker is set | ONE neutral pause/resume notice (`Notice.pause_text/1`), never `[RESUME]`, never repair/inconsistency wording |

The clean-pause decision is TWO conditions (`Resume.clean_pause?/1` + the transcript being intact): a `:clean_pause` resume whose durable state DOES prove an interruption — a non-empty `pending_tool_batch` marker or a dangling `tool_calls` tail — is logged at `:warning` and takes the REPAIR path (synthetic results + ONE `[RESUME]` notice with the pause sentences), because the transcript, never the pause label, is the truth and an unpaired `tool_call_id` would be rejected by the provider.
The clean-pause notice text is exactly "The user paused this task and has now resumed it. No tool call was interrupted" plus, ONLY when `resume_info[:worktree_resume_from]` is set (the pause finalizer commits the whole worktree with `git add --all`, so the claim is backable), " and the worktree is exactly as it was left: it was recreated from the pause checkpoint commit <sha>, which captured the work as it stood when the task was paused."; with no recorded checkpoint it is instead a second sentence, "No pause checkpoint commit was recorded, so the worktree was recreated from the task's base commit: only the restored conversation remains of the paused run's file changes."; then (only when the durable restore did not happen) the restore-degradation sentence, then the subagent sentence.
A `:dirty_pause` `[RESUME]` notice additionally states "The task was PAUSED when the host restarted…" and, like every pause notice, what a whole-tree resume does with the subagents: "Subagents: a child that already finished contributes its stored result, and a child that was still running is re-spawned and resumes from its own durable checkpoint and worktree base. Only a child with no durable record at all is lost, and that slot says so plainly — no subagent result is invented."
The `[RESUME]` worktree sentence is honest about a hard kill: with `worktree_resume_from` it says `Worktree: restored from commit <sha>, the last checkpointed commit.`, that only that commit is guaranteed, and that uncommitted worktree changes from the interrupted run are NOT preserved (inspect `git status` and the files first); with no such fact it says the worktree was recreated from the task's base commit and only what the durable checkpoints recorded survives.
Either notice is delivered the SAME way: ONE non-user-authored `:user` harness message stamped `metadata[:resume_notice] => true` (the exactly-once guard).

## API Surface

| Module | Function | Role |
|---|---|---|
| `EvoGit.Agent.Resume` | `apply(%State{})`, `apply(%State{}, opts)` | Repairs + annotates a restored state → `%State{}`; TOTAL, so a malformed state/context/option returns the input unchanged. |
| `EvoGit.Agent.Resume` | `clean_pause?(%State{})` | `true` for a `:clean_pause` resume kind; ONE half of the clean-pause decision, which additionally requires an intact transcript. |
| `EvoGit.Agent.Resume` | `resume_kind(%State{})` | `:clean_pause \| :dirty_pause` for a task-level pause resume, `nil` on the crash-retry path and for any malformed value; TOTAL. |
| `EvoGit.Agent.Resume` | `restored_run?(%State{})` | `true` when `persistent_state` is on AND `resume_info[:restore_agent_state] == true` (BOTH a crash retry and a pause resume); an absent/malformed `resume_info` or an opt-out answers `false`. |
| `EvoGit.Agent.Resume` | `clear_marker(%State{})` | The total field write that clears the in-flight marker; used by every path that stops executing a batch. |
| `EvoGit.Agent.Resume` | `dangling(%State{})` | `{:ok, turn, calls}` for the unanswered calls of the FINAL assistant message, in the assistant's call order, else `:none` (only a dangling TAIL is repairable). |
| `EvoGit.Agent.Resume` | `notice_present?(context)` | The exactly-once guard: `true` when the transcript already carries a resume notice (`metadata[:resume_notice]`), either kind. |
| `EvoGit.Agent.Resume.Notice` | `text(%State{}, batch)`, `facts(%State{}, batch)` | The `[RESUME]` notice text (crash retry + `:dirty_pause`) and the facts it is built from; every absent fact (retries, retry reason, salvaged commit, restore outcome) DROPS its sentence instead of asserting a guess. |
| `EvoGit.Agent.Resume.Notice` | `pause_text(%State{})` | The NEUTRAL clean-pause notice text (pause/resume, the pause-checkpoint-or-task-base worktree fact stated only when the resume can back it, the whole-tree subagent fate, restore degradation when applicable). |
| `EvoGit.Agent.Resume.ImpactText` | `impact(class, call)` | The honest synthetic tool-result TEXT for one interrupted call (`:subagent` answers the re-attach FALLBACK text); never fabricates success and never invents output. |
| `EvoGit.Agent.Resume.Reattach` | `resolve(%State{}, slots, opts \\ [])` | ONE batch-level subagent answer → `%{texts: %{model_call_index => text}, merge_note: String.t() \| nil}`: the surviving in-memory batch when there is one, else a batch rebuilt from the durable roster. |
| `EvoGit.Agent.Resume.Reattach` | `empty/0`, `default_reattach_fun/0`, `default_rebuild_fun/0` | The empty answer (every call falls back) and the two DEFAULT injections, `&EvoGit.AgentScheduler.reattach_sub_agents/2` and `&EvoGit.AgentScheduler.rebuild_subagent_batch/3`. |
| `EvoGit.Agent.Resume.RosterBatch` | `plan(%State{}, turn, expected, opts \\ [])` | Worker-side rebuild plan from the durable roster: one slot per expected subagent call, in model call order (`{:ok, plan}` \| `{:error, reason}`); a RAISE answers `{:error, {:plan_failed, message}}` — rescue only, so an exit/throw propagates to the scheduler's crash-retry instead of being reported as a lost child. |

`apply/2`'s options are all explicit injection points, never app env: `:reattach_fun` (`fn agent_id, expected_count -> reply`), `:rebuild_fun` (`fn agent_id, plan, opts -> reply`, defaulting to `&EvoGit.AgentScheduler.rebuild_subagent_batch/3`), `:roster_fun` (the durable roster read, defaulting to `&EvoGit.AgentState.roster/1`) and the scheduler-side `:spawn_fun` the rebuild passes through; `apply/2` supplies `:turn` itself from `dangling/1` so the plan can identify the children that turn spawned.

## Constraints

- **Repair appends, never rewrites**: ONE synthetic `:tool` result per unanswered call, in the assistant's call order, built with the SAME `EvoGit.Agent.ToolDispatch.assemble_tool_result/3` and turn-tagged with `ContextBuilder.tag_message_turn/2` exactly like a real result (the assistant message's own `metadata[:turn]`, else `state.turn`). An INTACT `:clean_pause` resume never reaches this step; a clean pause whose durable state proves an interruption does.
- **The prompt-cache prefix is untouchable**: neither repair nor notice ever modifies the system message or the first user message, so `[system, first_user]` stays byte-identical across a resume; the notice is a NEW trailing harness message and `:attachments` are never re-sent.
- **The notice is harness text**: exactly ONE notice `:user` message from `ContextBuilder.build_injected_message/2`, never `EvoGit.Agent.MessageMarker`-flagged as user-authored, and `metadata[:resume_notice]` makes a second resumed exchange append nothing.
- **Totality**: no raises, no LLM call; every re-attach, formatting, node-path and merge failure degrades to the honest fallback text with a `Logger.warning` — a repair can never crash the exchange.
- **The class is provenance-first**: the marker entry for the same provider `id` wins, then the entry at the same `index`, and only an absent marker re-derives it from the call name via `EvoGit.Agent.ToolBatch.class/2`.
- **ONE re-attach call per interrupted batch**: `expected_count` is the number of `:subagent` calls of the interrupted turn, the answered batch maps onto those calls BY POSITION (sub-agent index ↔ subagent-call order), and a malformed/`{:error, _}` reply answers the WHOLE batch with fallback text — never a partial guess. `{:error, :no_pending_batch}` is not the end of the road: the worker builds a rebuild plan from the durable roster and ONE `rebuild_subagent_batch/3` call installs it, so a batch that merely left ETS is answered with real results.
- **A real result's text is UNCHANGED**: `SubagentProcessing.format_subagent_result/1` output is passed through verbatim; only an unavailable slot, a raising/blank formatting, or an un-runnable merge replaces it with the fallback.
- **A same-repo child MUST be merged**: the resumed worktree is based on the SALVAGED/pause-checkpoint commit while the child's commits live on its own branch, so every real same-repo child is merged through `SubagentProcessing.perform_merge/3` + `delete_merged_branches/2` and reported with the ordinary `build_merge_message/4` note appended as ONE turn-tagged `:user` message; a merge that cannot RUN degrades those calls to fallback text (reporting work that is not in the tree would be a lie), while a merge that runs keeps the real text and the ordinary report.
- **Cross-repo children are never merged**: a `result.repo_id` that is non-nil and differs from the parent's is a foreign-repo child, exactly as on the spawn path; `nil` or the parent's own id is same-repo.
- **A `{:paused, info}` slot is NOT adopted**: `Reattach.adopt/3` matches only `{:ok, %Result{}}`, so a re-attached or rebuilt child that ends PAUSED again lands in `_lost_or_malformed` — its slot gets the crash-worded `:subagent` fallback text and its `info.checkpoint` commit is never merged, whereas the live spawn path merges a paused child's checkpoint and formats it as a neutral sentence (`../subagent_processing.ex` `collect_mergeable_results/3`).
- **The merge-child map is shaped in ONE place**: `SubagentProcessing.merge_child/5`, shared with the spawn path; an absent `node_path` is re-derived best-effort from the interrupted call and degrades to root ownership (the most permissive), never a lost commit.
- **The marker is always cleared** by the time `apply/2` returns — repair exists to close it — and `persistent_state: false` writes no marker, no repair and no notice.
- **Bounded, deliberate blocking**: the re-attach wait inside `EvoGit.AgentScheduler.reattach_sub_agents/2,3` (`opts[:timeout]` → `:agent_resume_reattach_timeout_ms` → 1_800_000 ms) and the equivalent bounded wait of a rebuilt batch are the ONLY non-total steps, and both are fully guarded here.
- **A lost in-memory batch is REBUILT from durable state, not assumed lost**: the scheduler keeps a live batch on the parent's `%SchedMeta{}` row (ETS, wiped by a scheduler/BEAM restart), so when `reattach_sub_agents/2,3` refuses with `{:error, :no_pending_batch}` the worker builds a plan from the children's durable rows (`RosterBatch.plan/4`, ALL durable I/O in the agent process) and hands it to `EvoGit.AgentScheduler.rebuild_subagent_batch/3` (`SubagentRebuild`): a `done` row CONTRIBUTES its stored result with no re-spawn, a `running` row is re-spawned under its persisted `agent_id` with `restore_agent_state: true` and repeats the same steps for ITS OWN children (resume is recursive), and a slot with no usable row answers `{:error, :subagent_result_lost}` — the fallback text is for genuinely unrebuildable slots only.

## Routing Table

- `../CONTEXT.md` → the exchange engine, `%EvoGit.Agent.State{}`, the pre-batch checkpoint and the marker invariant (§ Durable Per-Agent State).
- `../session/CONTEXT.md` → the session's checkpoint adoption rule, `resume_info` provenance (including `:resume_kind`) and the crashed-worker retry path.
- `../tool_batch.ex` → `EvoGit.Agent.ToolBatch`, the marker model, its classes and `normalize/1`.
- `impact_text.ex` → `EvoGit.Agent.Resume.ImpactText`, the honest synthetic-result PROSE for one interrupted call (never to be confused with `EvoGit.Agent.ToolBatch`, the durable in-flight batch MARKER).
- `roster_batch.ex` → `EvoGit.Agent.Resume.RosterBatch`, the worker-side plan that turns the children's durable rows into one slot per expected subagent call (done result / rebuilt spec / `:missing`).
- `../../agent_state/CONTEXT.md` → the durable store, `Record`'s column mapping, the `agent_states.pending_tool_batch` JSON column and the `pause_commit` marker.
- `../../../agent_scheduler/CONTEXT.md` → `reattach_sub_agents/2,3`, `SubagentReattach`, `rebuild_subagent_batch/3`, `SubagentRebuild`, `Salvage`/`WorktreeManager.salvage_for_retry/2`, `Lifecycle.retry_agent/4`, `Dispatch.resume_plan/5` and `Dispatch.apply_crash_base/5`.
- `../../../../docs/task-pause.md` → the task-level pause/resume design record (clean vs dirty, resume protocol).
- `../subagent_processing.ex` → `format_subagent_result/1`, `perform_merge/3`, `delete_merged_branches/2`, `build_merge_message/4`, `merge_child/5`, `resolve_subagent_path/4`.
