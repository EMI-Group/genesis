# agent_state — Test Tree

## Intent
ExUnit coverage for the durable per-run agent-state storage subsystem (`EvoGit.AgentState` + `AgentState.{Server,Store,Record,Retention,Boot}`), which persists each agent run's conversation + scalar fields in its OWN SQLite DB so a crashed run is recoverable.
Production contract (API, storage model, field list, corruption/retention rules): `../../../lib/evo_git/agent_state/CONTEXT.md`.

## Routing Table

| File | Module | Tests | Coverage |
|---|---|---|---|
| `agent_state_test.exs` | `EvoGit.AgentStateTest` | 8 | core data plane: append/rewrite round-trip exactness, write amplification, compression rewrite, resync gaps, empty tails, field mapping |
| `agent_state_faults_test.exs` | `EvoGit.AgentStateFaultsTest` | 10 | fault paths: `:not_found`, four corruption shapes, stopped server, `server/0` seam, absent target, malformed entries |
| `agent_state_retention_test.exs` | `EvoGit.AgentStateRetentionTest` | 6 | `mark_completed/3`, `prune/1` expiry rules, prune idempotence, `delete/3`, `delete_task/2` |
| `retention_test.exs` | `EvoGit.AgentState.RetentionTest` | 13 | pure `EvoGit.AgentState.Retention` math — no DB, no clock read, no app-env mutation |

All four modules are `use ExUnit.Case, async: true` with `@moduletag :tmp_dir`.

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
- A stopped server (`GenServer.stop/1` on a `restart: :temporary` child, so the test supervisor never restarts it) answers `repo/1 == nil` and `{:error, :store_unavailable}`, while `checkpoint`, `flush`, `mark_completed`, `delete` and `delete_task` stay `:ok` and `prune/1` answers `{:ok, 0}`.
- `server/0` honours the `:evogit_agent_state_server` process-dictionary seam, `[]` opts resolve through it, and `store: nil` means "resolve `server/0`" (NOT "no store").
- With no seam, `server/0` falls back to the live named default `EvoGit.AgentState.Server`.
- An ABSENT target (an unregistered name) keeps every function total: `repo/1 == nil`, `load/3` → `{:error, :store_unavailable}`, every mutation `:ok`, `prune/1` → `{:ok, 0}`.
- Malformed checkpoint entries (unknown kind, a non-message list element, a negative `base_seq`, a non-map `fields`) are dropped with one warning each inside a `capture_log/2` window, leaving the valid run unchanged and creating no row for a run that only saw malformed entries.

### agent_state_retention_test.exs — retention + deletes
- Every case starts its server with an EXPLICIT `retention_days: 7` start option (never an app-env mutation, so the module stays `async: true`) and produces expiry by BACKDATING the stored ISO8601 timestamps through the store's own dynamic repo — no clock seam, no sleeping.
- `mark_completed/3` stamps `status == "completed"` plus a `completed_at` `%DateTime{}` set at completion time and KEEPS the row, messages and counts for later recovery.
- `prune/1` deletes exactly the expired runs plus their chunks: completed 10 days ago expires, a never-completed run whose `updated_at` is 20 days old expires, while a recently-completed run and a recently-touched run survive; the deleted count is returned and chunk rows are removed per `(task_id, agent_id)`.
- A row touched inside the window is never pruned even when `completed_at` is 10 days old, because the prune additionally requires `updated_at < completed_before`.
- A second `prune/1` answers `{:ok, 0}` (idempotent).
- `delete/3` removes one run's row and chunks and leaves its siblings alone, and deleting an absent run is still `:ok`.
- `delete_task/2` removes every run of one task and all its chunks while another task's runs survive, and deleting an absent task is still `:ok`.

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
- Retention ordering is string comparison on second-precision ISO8601 UTC, which is why backdating through SQL is a valid expiry fixture.

## Constraints
No module here is `async: false`, and no test calls `Process.sleep` — every wait is a `flush/1` reply, a synchronous call, or a mailbox assertion made deterministic by that barrier.
No shared support module: the isolation helpers are intentionally duplicated in each file.
No test uses the app-global `tasks.sqlite` or the app-booted agent-state server.
