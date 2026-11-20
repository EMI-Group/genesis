# agent_state — Test Tree

## Intent
ExUnit coverage for the durable per-run agent-state storage subsystem (`EvoGit.AgentState` + `AgentState.{Supervisor,Server,Entry,Store,Record,Retention,Boot,Anchor,Redispatch}`), which persists each agent run's conversation + scalar run facts in its OWN SQLite DB so a crashed run is recoverable.
Production contract (API, storage model, field list, corruption/retention rules): `../../../lib/evo_git/agent_state/CONTEXT.md`.

## Routing Table

| File | Module | Tests | Coverage |
|---|---|---|---|
| `agent_state_test.exs` | `EvoGit.AgentStateTest` | 8 | core data plane: append/rewrite round-trip exactness, write amplification, compression rewrite, resync gaps, empty tails, field mapping |
| `agent_state_faults_test.exs` | `EvoGit.AgentStateFaultsTest` | 10 | fault paths: `:not_found`, four corruption shapes, stopped server, `server/0` seam, absent target, malformed entries |
| `agent_state_retention_test.exs` | `EvoGit.AgentStateRetentionTest` | 7 | `mark_done/5`, `prune/1` expiry rules, prune idempotence, `delete/3`, `delete_task/2`, the bulk `delete_tasks/2` |
| `retention_test.exs` | `EvoGit.AgentState.RetentionTest` | 13 | pure `EvoGit.AgentState.Retention` math — no DB, no clock read, no app-env mutation |
| `agent_state_migration_test.exs` | `EvoGit.AgentState.MigrationTest` | 6 | the REAL migration chain on a fresh temp dir: applied versions `[1, 2, 3, 4, 5]`, exactly one nullable `TEXT` `pending_tool_batch` column plus exactly one nullable `TEXT` `pause_commit` column, the two `000005` indexes (`agent_states_agent_id_index`, `agent_states_task_depth_agent_index`) present EXACTLY once, a checkpointed `EvoGit.Agent.ToolBatch` marker as non-null JSON (direct `SELECT`) that `load/3` + `normalize/1` round-trips, `nil` clearing it, and a second boot / forced version-2-3-4-and-5 re-run staying idempotent (`Boot.run_migrations/1` answering `{:ok, [2, 3, 4, 5]}`) with the indexes unmoved and the data intact |
| `agent_state_run_facts_test.exs` | `EvoGit.AgentState.RunFactsTest` | 11 | the v2 run-fact surface: `roster/2` (whole tree of ONE task, `depth ASC, agent_id ASC`, `messages: nil`), `max_agent_id/1` (`0` empty/degraded), `mark_done/5` (done + `completed_at` + `current_commit` + JSON `result`, `nil` facts preserved, `{:error, :not_found}` at the Store), `Record.status/1`/`result/1`, and `delete_done_children/4` (only the `done` children of one `(parent_id, spawn_turn)` batch) |
| `agent_state_run_facts_migration_test.exs` | `EvoGit.AgentState.RunFactsMigrationTest` | 4 | migration `000004_add_run_facts` on real files with the chain asserted as `[1, 2, 3, 4, 5]`: a fresh boot ends with all seven run-fact columns plus EVERY index family (retention, `(task_id, parent_id)` and the two `000005` indexes), a version-3 database upgrades in place (`status = 'completed'` → `'done'`, every pre-existing value intact), a re-run of `up/0` is a no-op, and `down/0` removes only what the migration added |
| `anchor_test.exs` | `EvoGit.AgentState.AnchorTest` | 6 | `Anchor.ref/2` (per-run namespace, total for any identifier) and `Anchor.anchor/4` on a real `:tmp_dir` repo: creates the ref, dedupes an unchanged sha and moves it for a newer one, is a no-op for a blank path/sha, and the anchored commit survives branch deletion, reclamation and `git gc` |
| `redispatch_test.exs` | `EvoGit.AgentState.RedispatchTest` | 9 | the pure re-dispatch blob: exactly the documented key list, spec-vs-facts precedence, foreign repos as plain maps and back to structs, a `Jason` round-trip that preserves meaning, no pids/funs/credentials, and total degradation for a non-map or a partial blob |
| `entry_test.exs` | `EvoGit.AgentState.EntryTest` | 13 | pure `EvoGit.AgentState.Entry`: `normalize/1` acceptance/rejection and every `fold/1` rule (rewrite supersede, append chaining, gaps, last-wins fields, owner, empty queue) — no store, no `:tmp_dir` |
| `agent_state_coalescing_test.exs` | `EvoGit.AgentState.CoalescingTest` | 9 | the bounded, coalescing writer: suspend/enqueue/resume folding to ONE chunk, selective draining per run, `:max_backlog` drops with ONE owner resync and ONE warning, the 20-checkpoint flood staying at one warning line, the fold-level `:max_payload_bytes` skip with NO resync, and `Store.checkpoint_batch/4` committing a fold in one transaction (whole-fold rollback on a resync) |
| `agent_state_pause_test.exs` | `EvoGit.AgentState.PauseTest` | 8 | task-level pause/resume facts: `put_pause_commit/3,4` round-trip/replace/clear (direct `SELECT`), `{:error, :not_found}` with no row created, the write touching ONLY `pause_commit` (counts, chunks and append continuity untouched), `pause_commit/2,3`, the inert no-store shapes, and `flush/1` as a synchronous durability barrier (explicit `:sync` call plus read-back with no sleeping) |

| `agent_state_barrier_test.exs` | `EvoGit.AgentState.BarrierTest` | 8 | the HONEST barrier and the cast bookkeeping around it: `flush/1` answers `:ok` on a healthy writer and for a `nil` target, `{:error, :timeout}` for an over-cap backlog and for a target that dies while the call is parked, and `mark_done/5` / `delete/3` / `delete_task/2` / the ONE batched `delete_tasks/2` are total casts for live and dead targets, durable after `flush/1` |
| `agent_state_supervision_test.exs` | `EvoGit.AgentState.SupervisionTest` | 4 | containment: a database under a path whose parent is a regular FILE boots DEGRADED (supervisor and writer alive, `repo/1` nil, every API total, `flush/1` `{:error, :timeout}`), proves the failed attempt re-armed its retry (`retry_scheduled?` read through `:sys.get_state/2`) and then RECOVERS once the dir is writable; the subsystem's own supervisor absorbs repeated writer kills inside its 10/60 s budget; a killed repo is absorbed — the degraded contract is asserted while the reboot sits on a 30 s ladder, then triggered explicitly with the message the retry timer delivers; the facade resolves a supervisor pid to its writer |
| `pause_durability_test.exs` | `EvoGit.AgentState.PauseDurabilityTest` | 2 | the pause verdict without a database or any global: `Pause.info/3` defaults `durable: false` (the paths that never flush), `info/4` reports `true` only for a literal `true` — the value derived from `flush/1`'s `:ok` |
| `durable_row_lifecycle_test.exs` | `EvoGit.AgentState.DurableRowLifecycleTest` | 2 | the durable ROW LIFECYCLE, async on an isolated unnamed `EvoGit.AgentState` server: a ROOT's completion drops ONLY its own row and leaves a `done` CHILD row readable through `roster/2` with its stored result, and `persistent_state: false` is inert even when a row already exists for the identity |
| `durable_row_lifecycle_resume_test.exs` | `EvoGit.AgentState.DurableRowLifecycleResumeTest` | 1 | force kill × the durable row, `async: false` for the app-global `EvoGit.PubSub` `"tasks"` topic its real `force_kill_task/1` broadcasts on: `force_kill_task/1` persists `:failed` with `result: nil`/`pause_kind: nil` and leaves the durable ROOT row surviving as a plain `status: "running"` row with no result and no `completed_at`, and `resume_task/1` answers `{:error, :not_paused}` |
Sixteen of the seventeen modules are `async: true` (all through `use ExUnit.Case`); the one serialized module is `durable_row_lifecycle_resume_test.exs` (`EvoGit.TaskRegistryCase`, `async: false`) because the real registry's persist-then-broadcast paths publish `{:task_updated, …}` on the app-global `EvoGit.PubSub` `"tasks"` topic with no injectable `:pubsub` option.
The pure `entry_test.exs`, `retention_test.exs` and `redispatch_test.exs`, plus `pause_durability_test.exs`, `durable_row_lifecycle_test.exs` and `durable_row_lifecycle_resume_test.exs`, are the only ones without `@moduletag :tmp_dir`.

## Per-File Coverage

### agent_state_test.exs — core data plane
- A `:rewrite` plus an `:append` round-trips every `%ReqLLM.Message{}` struct EXACTLY (asserted by struct equality), including a `system` message, a `user` message, an `assistant` message carrying `tool_calls`, a `:tool` result message, and a multimodal `user` message whose `ContentPart.image` bytes/`media_type` and `ContentPart.file` audio bytes/`media_type` survive the blob codec.
- Write amplification: one initial rewrite plus 5 appends produce exactly 6 chunk rows with contiguous `seq 0..5`, and `chunk_count` grows by exactly 1 per checkpoint.
- Each append chunk's `message_count` equals its TAIL length (never the accumulated count), its payload decodes to exactly that tail, and `byte_size(payload) == byte_size(Record.encode_messages(tail))`.
- The sum of append payload bytes stays `≤ 2 × N × max_tail_size`, proving payload bytes are O(delta) and never O(N²).
- A compression-time `:rewrite` replaces every chunk with ONE chunk at `seq 0`, restarts `message_count`/`chunk_count` from the new baseline, leaves no stale tail, and a subsequent `:append` at the new `base_seq` succeeds.
- Resync gap: a divergent `base_seq` writes nothing and the `owner` receives `{:agent_state_resync, task_id, agent_id}`; `base_seq > 0` against a missing row also notifies and creates no row or chunk; a later `:rewrite` heals the run and `refute_received` proves no second notification.
- Empty append tail: on a fresh store it creates the row with `fields` and no chunk (`[[0, 0]]` counts); on an existing row it inserts no chunk but still upserts `fields`.
- Field mapping: `agent_module` round-trips as the module atom (stored as its string form), booleans are stored `0/1`, JSON columns (`model_spec`, `usage`, `pending_inputs`) read back STRING-keyed, unknown keys are ignored, omitted keys are PRESERVED across an upsert, and never-written nullable columns read `nil` while NOT NULL columns answer their migration defaults.

### agent_state_faults_test.exs — fault paths
- `load/3` on a run with no row answers `{:error, :not_found}`.
- A corrupt payload blob, a chunk `message_count` that disagrees with its payload, a row `message_count` that disagrees with the chunks, and a row `chunk_count` that disagrees with the chunk rows all answer `{:error, :corrupt_state}` while the server stays alive.
- A stopped server (`GenServer.stop/1` on a `restart: :temporary` child, so the test supervisor never restarts it) answers `repo/1 == nil` and `{:error, :store_unavailable}`, while `checkpoint`, `flush`, `mark_done`, `delete` and `delete_task` stay `:ok` and `prune/1` answers `{:ok, 0}`.
- `server/0` honours the `:evogit_agent_state_server` process-dictionary seam, `[]` opts resolve through it, and `store: nil` means "resolve `server/0`" (NOT "no store").
- With no seam, `server/0` falls back to the live named default `EvoGit.AgentState.Server`.
- An ABSENT target (an unregistered name) keeps every function total: `repo/1 == nil`, `load/3` → `{:error, :store_unavailable}`, every mutation `:ok`, `prune/1` → `{:ok, 0}`.
- Malformed checkpoint entries (unknown kind, a non-message list element, a negative `base_seq`, a non-map `fields`) are dropped with one warning each inside a `capture_log/2` window, leaving the valid run unchanged and creating no row for a run that only saw malformed entries.

### agent_state_retention_test.exs — retention + deletes
- Every case starts its server with an EXPLICIT `retention_days: 7` start option (never an app-env mutation, so the module stays `async: true`) and produces expiry by BACKDATING the stored ISO8601 timestamps through the store's own dynamic repo — no clock seam, no sleeping.
- `mark_done/5` stamps `status == "done"` plus a `completed_at` `%DateTime{}` set at completion time and KEEPS the row, messages and counts for later recovery.
- `prune/1` deletes exactly the expired runs plus their chunks: completed 10 days ago expires, a never-completed run whose `updated_at` is 20 days old expires, while a recently-completed run and a recently-touched run survive; the deleted count is returned and chunk rows are removed per `(task_id, agent_id)`.
- A row touched inside the window is never pruned even when `completed_at` is 10 days old, because the prune additionally requires `updated_at < completed_before`.
- A second `prune/1` answers `{:ok, 0}` (idempotent).
- `delete/3` removes one run's row and chunks and leaves its siblings alone, and deleting an absent run is still `:ok`.
- `delete_task/2` removes every run of one task and all its chunks while another task's runs survive, and deleting an absent task is still `:ok`.

### agent_state_pause_test.exs — task-level pause/resume facts
- `put_pause_commit/3,4` round-trips a sha, a second put replaces it and `nil` clears it — asserted through the API AND a direct `SELECT pause_commit`.
- A run with no row answers `{:error, :not_found}` and reads `nil`, and NO row is created (a pause marker never fabricates an empty conversation).
- The write touches ONLY `pause_commit`: `message_count`/`chunk_count` and the chunk rows are unchanged, the loaded record still holds its message + earlier scalars, the marker is visible as `record.fields[:pause_commit]`, and an `:append` at the PRE-pause `base_seq` is still accepted — so the continuity rule never sees a pause as a conversation write.
- `flush/1` is proven a SYNCHRONOUS barrier: the server answers `:sync` to an explicit `GenServer.call`, and a cast checkpoint plus a queued `put_pause_commit` are readable from a fresh `load/3` immediately after `flush/1` (or `flush(agent_id)` through the process-dictionary seam) returns — no `Process.sleep`, no retry.
- The barrier test ALSO pins coalescing: five appends still queued when the barrier arrives are durable as ONE folded chunk (`chunk_count == 2`, every message present), so the guarantee is "every message is durable", not "one row per checkpoint".
- With no store (an UNREGISTERED name — i.e. a DEGRADED store, not a `persistent_state: false` task, whose flag tag has no producer) every new function stays inert: `{:error, :store_unavailable}`, `nil`, `false`, `[]`, `:ok` — and the same calls succeed against a live store, so the inert shape is pinned rather than an unusable API.

### retention_test.exs — pure retention math
- `default_days/0` is 7 and `default_prune_interval/0` is 3_600_000 ms.
- `normalize_days/1` passes non-negative integers through (including `0`) and falls back to the default for negatives, floats, strings, `nil`, atoms, maps and lists.
- `configured_days/1` lets an explicit `retention_days` opt win (including `0` and `365`), falls back to the default for an invalid opt, and falls back for an absent/`nil` opt.
- The `:agent_state_retention_days` app env is deliberately NOT exercised (and no suite sets it), so this module stays `async: true`.
- `prune_interval/1` passes a positive integer through and falls back to the default for `0`, negatives, non-integers and an absent opt.
- `cutoffs/2` is asserted at a frozen `@now` (`~U[2024-05-05 05:05:05Z]`): `completed_before` is `days` back, `stale_before` is `2 * days` back, a 0-day window makes both exactly `now`, an invalid day count is normalized first, and both strings are second-precision ISO8601 (`microsecond == {0, 0}`) so string order equals time order.

## Isolation Model
Every test starts its OWN unnamed `EvoGit.AgentState` server via `start_supervised!/1` on `<tmp_dir>/agent_state.sqlite` with `name: nil` and a parked `prune_interval: 3_600_000`.
Every call passes `store: pid`, so the app-global `EvoGit.AgentState.Server` booted by `EvoGit.Application` is never read or mutated — that is the whole reason this directory can be `async: true`.
Checkpoints are CASTS, so every read-backed assertion follows `EvoGit.AgentState.flush(store: pid)`, the documented read-your-writes barrier; the flush reply is the ONLY synchronization point.
Raw introspection goes through a per-file `sql!/3` helper built on `EvoGit.Store.RepoScope.with_repo(EvoGit.AgentState.repo(pid), fn -> Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params) end)`.
The `start_store!`/`checkpoint!`/`sql!`/`chunks!`/`counts!` helpers are duplicated per file ON PURPOSE (there is no shared support module for this directory).

## Notes for Agents
- `store: nil` (and an empty `[]` opts list) means "resolve `server/0`", NOT "no store" — so the absent-target path is exercised with an UNREGISTERED NAME, never by stopping the app-global server.
- `Process.put(:evogit_agent_state_server, pid)` is the per-process seam; register it with an `on_exit` that deletes the key.
- In `:test` the application boots a live default server, so a test may assert `server/0` equals `Process.whereis(EvoGit.AgentState.Server)` but may never stop it.
- A test that must STOP its server needs a `restart: :temporary` child spec (with a unique `:id`), otherwise the test supervisor restarts it and the dead-server assertions race.
- Measure payload byte sizes with `byte_size/1` in Elixir, never SQL `length()`.
- `load/3` reads in the CALLING process (repo pid from `:persistent_term` + `RepoScope`), so it does not queue behind pending checkpoint casts.
- The migrations give NOT NULL DEFAULTs (`status "running"`, `depth`/`turn`/`total_tokens`/`compression_count` `0`, `repo_less`/`archive`/`model_id_locked` `false`, `format_version` `1`) while nullable columns read back `nil`.
- An `:append` (and a `:rewrite`) is a CAST, so a malformed-entry test must capture the server's per-entry warning inside `capture_log/2` to keep the suite quiet (`capture_log` is process-scoped, so this is async-safe).
- The writer's caps are PER-INSTANCE start options (`max_backlog:`, `max_payload_bytes:`); never mutate the `:agent_state_max_backlog` / `:agent_state_max_payload_bytes` app env in a test, or the module stops being async-safe.
- `config :logger, level: :warning` in `:test` means the writer's `:info` "checkpoints resumed" line is invisible to tests; assert the streak RESET through behaviour (a second skip logs a second warning) instead of that line.
- Retention ordering is string comparison on second-precision ISO8601 UTC, which is why backdating through SQL is a valid expiry fixture.
- **A boot in this directory is a BEAM-GLOBAL serialized operation.** `EvoGit.AgentState.Boot.start_dynamic/2` runs `Ecto.Migrator.run` inside `:global.trans({:evo_git_agent_state_migrations, self()}, …)` (the same one-time migration-module compile lock `EvoGit.Store.Boot` guards with its own `:evo_git_store_migrations` id), so EVERY agent-state store booted anywhere in the suite queues on that ONE lock, and a boot's latency is set by the boots ahead of it — not by the calling test. Measured on this host: a solo boot ~14 ms; twelve concurrent boots 22-704 ms; thirty concurrent 57-2829 ms; a sustained 32-way cohort (1487-13513 attempts) median 2-22 ms, p95 23-26 ms, p99 56-837 ms, max 19.3 s, with `>5 s` on ~0.2-1% of attempts and `>30 s` in none of 1487-13513 attempts (one 193 s outlier appeared in a run that re-migrated a FRESH database every round).
  This is why `agent_state_supervision_test.exs` waits `@boot_timeout` (30 s) for boot-dependent conditions and carries `@moduletag timeout: 300_000`: its pre-existing 5 s budget was a boot-latency assumption, and a full-suite run under load blew it (`condition not met within 5000 ms` on the post-`mkdir_p!` recovery poll) while the same file passed in isolation.
  Reproduce it deterministically by holding the lock from another test — `:global.trans({:evo_git_agent_state_migrations, self()}, fn -> Process.sleep(8_000) end)` alongside this module with `--seed 0`.
  A wait on a boot is therefore bounded but generous, and the RESIDUAL risk is pathological starvation (a boot stalled past 30 s); the product-level remedy would be narrowing that lock to the shared migration-source compile instead of the per-database `Ecto.Migrator.run`, not a longer test budget.

### entry_test.exs — pure fold rules
- `normalize/1` accepts the documented atom-keyed entry (defaulting `fields` to `%{}` and `owner` to `nil`, keeping a `nil` base_seq) and answers `:error` for a non-map entry, an unknown kind, a missing/non-list `messages`, a non-message element, a negative or float `base_seq` and a non-map `fields`.
- `fold/1` collapses N rewrites to the LAST content; folds chained appends into ONE append with the FIRST `base_seq` and the concatenated tail (a `nil` base_seq counts as `0`); keeps rewrite-plus-chained-appends as ONE rewrite; keeps a continuity GAP as separate ordered operations; merges `fields` last-wins ACROSS a superseding rewrite (a superseded scalar is never lost); carries the last non-nil `owner`; folds an empty queue and a non-list to `[]`; and IGNORES entries it cannot interpret.

### agent_state_coalescing_test.exs — bounded, coalescing writer
- Determinism: the writer is `:sys.suspend`ed, the test casts a known number of checkpoints, `:sys.resume`d, and then WAITS (bounded `wait_until` poll on the writer's `message_queue_len`) before sending anything else — a barrier call sent into a still-queued mailbox would itself count against the cap and change the drop count. There is no fixed sleep.
- Five queued appends for ONE run become ONE new chunk row (`2` chunks, `[[6, 2]]` counts, the full concatenated transcript) and four queued rewrites collapse to the LAST one.
- Draining is SELECTIVE: a checkpoint queued for ANOTHER run between one run's two checkpoints keeps its own row and chunk.
- `:max_backlog` (a per-instance start option) with three queued checkpoints and a cap of `1`: the first is dropped — exactly ONE `{:agent_state_resync, task_id, agent_id}`, exactly ONE warning line, the later two folded and stored, the writer alive, its mailbox empty.
- A 20-checkpoint flood over the same cap still logs exactly ONE warning (the per-run streak entry), stays alive and drains.
- A DROPPED checkpoint is not drained: the folded survivor then reports the real continuity gap (`:resync`, no row) instead of appending on top of it.
- The payload cap skips with ONE warning, NO resync and no row; a later small checkpoint persists and RESETS the streak, so a following oversized one logs a SECOND warning (proving the bookkeeping is cleared on acceptance). The cap measures the whole FOLD — two chained tails that each fit but together do not are skipped.
- `Store.checkpoint_batch/4` commits every operation of a fold in ONE transaction and rolls the WHOLE fold back on a `:resync`; `[]` is a no-op `:ok` and a non-list is `{:error, :invalid_operations}`.

## Constraints
No module here is `async: false`, and no test waits on a fixed sleep: every wait is a `flush/1` reply, a synchronous call, a mailbox assertion made deterministic by that barrier, or a BOUNDED condition poll whose own tick is the `Process.sleep` (`agent_state_coalescing_test.exs` 1 ms, `agent_state_supervision_test.exs` `@poll_interval` 10 ms), and a condition the WRITER owns (its retry armed, its repo cleared) is observed with `:sys.get_state/2` — a system message ordered behind every earlier cast/call, so it is a real barrier rather than a delay.
`agent_state_supervision_test.exs` splits its budgets by what the wait needs: `@poll_timeout` (5 s) for a boot-independent condition, `@boot_timeout` (30 s) for anything that needs a BOOT, and `@moduletag timeout: 300_000` to cover its five sequential writer restarts (see the migration-lock note below for why a boot's budget cannot be small).
No shared support module: the isolation helpers are intentionally duplicated in each file.
No test uses the app-global `tasks.sqlite` or the app-booted agent-state server.
