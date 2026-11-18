# EvoGit.AgentState — Durable Per-Run Agent State

## Intent

Persist each agent run's in-memory state (conversation messages + scalar fields) in a SEPARATE SQLite database so a crashed run is recoverable.
The database is `<data_dir>/agent_state.sqlite` — deliberately NOT the task store (`tasks.sqlite`), because checkpoints are a high-churn write stream that must never contend with task persistence or dashboard reads.
Writes are serialized through ONE writer process; reads run in the caller against the same unnamed dynamic `EvoGit.Repo` instance.

## API Surface

| Function | Shape | Contract |
|---|---|---|
| `start_link/1` | `{:ok, pid} \| {:error, term}` | opts `:database`, `:data_dir`, `:name` (default `EvoGit.AgentState.Server`; `nil` = unnamed), `:retention_days`, `:prune_interval` |
| `server/0` | `pid \| nil` | process-dictionary `:evogit_agent_state_server` wins, else the named default when alive |
| `repo/1` | `pid \| nil` | server → dynamic `EvoGit.Repo` pid via `:persistent_term`; `nil` when absent/dead |
| `checkpoint/4` | `:ok` always | CAST; opts `:store` |
| `flush/1` | `:ok` always | SYNCHRONOUS durability barrier (`GenServer.call` `:sync`, never a cast): returns after every earlier checkpoint cast — for every agent — is committed; takes `store:` opts, a server pid or an agent id |
| `put_pause_commit/3,4` | `:ok \| {:error, :not_found \| :not_persistent_state_disabled \| term}` | serialized scalar write of the paused worktree checkpoint sha (`nil` clears it); `{:error, :not_found}` when the run has no row |
| `pause_commit/2,3` | `String.t() \| nil` | one run's persisted pause sha; caller-side read, TOTAL (`nil` on a missing row/store/error) |
| `resumable?/1,2` | `boolean()` | cheap `SELECT 1 … WHERE task_id = ? LIMIT 1`: does ANY durable run row exist for the task; TOTAL (`false`) |
| `root_agent_ids/1,2` | `[integer()]` | the task's rows with `parent_id IS NULL`, ascending; TOTAL (`[]`) |
| `load/3` | `{:ok, %Record{}} \| {:error, :not_found \| :corrupt_state \| :store_unavailable}` | caller-side read |
| `mark_completed/3` | `:ok` | sets `status='completed'` + `completed_at`; row kept |
| `delete/3` | `:ok` | one run's row + chunks |
| `delete_task/2` | `:ok` | every run of one task |
| `prune/1` | `{:ok, deleted_count}` | completion-based retention |

`checkpoint/4` entry (built by the session — SMALL, never a whole `%EvoGit.Agent.State{}`):

```elixir
%{kind: :append | :rewrite,
  base_seq: non_neg_integer() | nil,
  messages: [ReqLLM.Message.t()],
  fields: %{atom => term()},
  owner: pid()}
```

- `:append` stores ONLY the tail and succeeds only when `base_seq` (nil = `0`) equals the stored `message_count`.
- A mismatch (or a missing row while `base_seq > 0`) writes NOTHING and sends `{:agent_state_resync, task_id, agent_id}` to `owner` (a dead pid is a silent no-op).
- `:rewrite` (post-compression) deletes the run's chunks and stores the whole list as ONE chunk at `seq = 0`.
- Append chunk `seq` = the row's current `chunk_count`; an empty append tail inserts no chunk but still UPSERTs `fields` (and creates the row when absent).
- `fields` keys: `:agent_module`, `:depth`, `:parent_id`, `:node_path`, `:repo_id`, `:repo_less`, `:repo_root`, `:custom_agent_id`, `:mode`, `:archive`, `:objective`, `:model_spec`, `:provider_profile_id`, `:model_id`, `:model_id_locked`, `:prompt_cache_key`, `:llm_model`, `:llm_context_window`, `:turn`, `:usage`, `:total_tokens`, `:compression_count`, `:current_commit`, `:phase`, `:pending_inputs`, `:pending_tool_batch`, `:status`, `:pause_commit`.
- Only SUPPLIED keys are written (an UPSERT never clobbers an earlier value with a default); unknown keys are ignored.
- `:pause_commit` is written ONLY by `put_pause_commit/3,4` (`Store.put_pause_commit/4`), a scalar `UPDATE` of that ONE column: chunks, `message_count`/`chunk_count` and every other scalar stay untouched, so the append/rewrite continuity rule never sees a pause as a conversation write.
- `put_pause_commit/3,4` routes through the SAME single serialized writer (one `GenServer.call`, so it can neither race nor reorder against a checkpoint) and never creates a row: no row for `(task_id, agent_id)` → `{:error, :not_found}`, absent/dead store → `{:error, :not_persistent_state_disabled}`.

`%EvoGit.AgentState.Record{}` fields: `:task_id`, `:agent_id`, `:fields`, `:messages`, `:message_count`, `:chunk_count`, `:format_version`, `:inserted_at`, `:updated_at`, `:completed_at`.
`fields` is ATOM-keyed; text columns decode to strings, booleans to `true | false`, `:agent_module` to the module atom when loaded (else the stored string), and JSON columns (`:model_spec`, `:usage`, `:pending_inputs`, `:pending_tool_batch`) to Jason's native STRING-keyed shape.
`fields[:pending_tool_batch]` is the in-flight tool-batch marker (`EvoGit.Agent.ToolBatch`): plain JSON text in a nullable column, `nil` unless a batch is executing, and `EvoGit.Agent.ToolBatch.normalize/1` is the ONE place that turns a restored value back into the atom-keyed shape.
Timestamps are `%DateTime{}` (ISO8601 second precision, UTC) or `nil`.

## Routing Table

- `agent_state.ex` → public facade (`EvoGit.AgentState`), no SQL.
- `agent_state/server.ex` → `EvoGit.AgentState.Server`, the single serialized writer GenServer, repository publishing and the prune timer.
- `agent_state/boot.ex` → `EvoGit.AgentState.Boot`, dynamic repo + migrator for `priv/agent_state_repo/migrations/`.
- `agent_state/store.ex` → `EvoGit.AgentState.Store`, every SQL operation.
- `agent_state/record.ex` → `EvoGit.AgentState.Record`, field/column mapping + message blob codec.
- `agent_state/retention.ex` → `EvoGit.AgentState.Retention`, pure cutoff/interval math.
- Migrations: `apps/evo_git/priv/agent_state_repo/migrations/`.

## Storage Model

- ONE unnamed dynamic `EvoGit.Repo` instance per server, started via `EvoGit.AgentState.Boot.start_dynamic/2` with `pool_size: 2`, `journal_mode: :wal`, `synchronous: :normal` plus `EvoGit.Repo.start_opts/0` tuning — never the canonical named repo, and `EvoGit.Repo.start_opts/0`/`defaults/0` are unchanged.
- Migrations run on a single-connection boot repo which is then stopped and reopened at the final pool size (SQLite schema-laziness: pool connections must open an already-migrated file).
- Migration chain: `000001_create_agent_state` is the ONE schema-creating step, `000002_add_pending_tool_batch` adds `agent_states.pending_tool_batch` and `000003_add_pause_commit` adds `agent_states.pause_commit`, each behind a `PRAGMA table_info` probe, so a fresh boot and an existing data dir converge on the same schema.
- Because that chain runs BEFORE the first read or write, the store writes `Record.encode_fields/1`'s columns and reads `Record.all_columns/0` directly: there is NO runtime schema probe, no per-checkpoint `PRAGMA` and no "missing column" warning path.
- `EvoGit.AgentState.Boot` has its OWN `:global` lock id (`{:evo_git_agent_state_migrations, self()}`) and its OWN memoized `:persistent_term` migration source; it never calls `EvoGit.Store.Boot`.
- Boot is FATAL on a broken/unwritable DB (`File.mkdir_p!`, `{:ok, repo} = ...` propagate out of `init/1`) — never a silent non-persisting server.
- One checkpoint = one transaction: scalar-row UPSERT + (optional) single chunk INSERT. Message payloads are `:erlang.term_to_binary(messages, compressed: 6)`; JSON fields are Jason TEXT; booleans are 0/1.
- Tables: `agent_states` (PK `(task_id, agent_id)`) and `agent_state_chunks` (PK `(task_id, agent_id, seq)`).

## Status & Unfinished-Run Queries

`agent_states.status` is `TEXT NOT NULL DEFAULT 'running'` (migration `000001_create_agent_state.exs:37`) and surfaces ONLY as `Record.fields[:status]`; `mark_completed/3` is the one writer that sets it (`store.ex:288`), while every other value is whatever the checkpointing session supplied — a crashed run keeps the last supplied value (or the `'running'` default).
There is NO query that selects rows by `status`, and NO unfinished/"recoverable run" listing API: the only non-terminal-row scan is `prune/1`'s retention `SELECT` (`store.ex:457`), which deletes and returns nothing to callers.
The only per-TASK roster read is `root_agent_ids/1,2` — a `WHERE task_id = ? AND parent_id IS NULL ORDER BY agent_id ASC` projection of ids (no row decode, no chunk read, no status filter), which a task-level resume reads ONLY as an existence gate (`Pause.ensure_durable_runs/1`) and then discards; restoring a CHILD run still needs its id from the caller (`parent_id` is persisted on every row), and `resumable?/1,2` (`SELECT 1 … LIMIT 1`) is the cheap existence gate in front of it.
Identity is the CALLER's `agent_id`, never a lookup by task: every read (`load/3`, `pause_commit/2,3`) is keyed `(task_id, agent_id)`, so a task-level resume that re-registers its root under a FRESH scheduler id (`Dispatch.register_agent/7` → `state.next_agent_id`, reset to `1` per BEAM) answers `:not_found` / `nil` and silently starts that run from scratch.
`load/3` never filters on `status`/`completed_at`, so a completed or abandoned run loads exactly like a live one.
A never-completed record is retained until `updated_at` is older than `2 × retention_days` (default 14 days) — the binding constraint of `prune/1`'s two windows — and is then deleted by the hourly prune pass.
The primary key is `(task_id, agent_id)` with NO retry/attempt column, so a retry of the same agent id upserts the same row; `:turn` and `:compression_count` are the only progress counters.

## Constraints

- `checkpoint/4` is a CAST, always `:ok`, and total: a malformed entry, a store fault or a dead server is logged/dropped and never propagates into an agent run.
- `flush/1` is the ONE synchronous durability barrier (`GenServer.call` `:sync` with a 15 s timeout, NOT a cast) and is total (`:ok` when nothing is pending, the server is absent/dead, or the target is an unregistered name).
- `put_pause_commit/3,4` is total and never creates a row; `pause_commit/2,3`, `resumable?/1,2` and `root_agent_ids/1,2` are TOTAL reads that answer `nil` / `false` / `[]` on a missing row, an absent/dead store or any store fault.
- `load/3` is total: missing row → `:not_found`; corrupt blob / chunk-count or message-count mismatch → `:corrupt_state`; absent/dead server or store fault → `:store_unavailable`.
- Reads never queue behind checkpoint casts: `load/3`, `pause_commit/2,3`, `resumable?/1,2` and `root_agent_ids/1,2` resolve the repo pid from `:persistent_term` and read in the calling process via `EvoGit.Store.RepoScope.with_repo/2`.
- `:erlang.binary_to_term/1` has exactly ONE justified `try/rescue` in `Record.decode_messages/1`; the payload must decode to a list of `%ReqLLM.Message{}` or the result is `:error`.
- Retention: a completed row is pruned once `completed_at` is older than `retention_days` (default 7, app env `:agent_state_retention_days`); a never-completed row once `updated_at` is older than `retention_days * 2`; a row whose `updated_at` is inside the retention window is never pruned. The server runs an hourly `Process.send_after` prune; a prune error is `Logger.warning`-ed and never crashes the server.
- Timestamps are stored ISO8601 UTC at second precision so string comparison implements retention ordering.
- Column names come ONLY from `Record`'s constant lists; SQL uses positional `?` placeholders.
- The task flag is `:persistent_state` (admitted by `RuntimeOpts.admit_persistent_state/1`, threaded through task opts → `AgentSpec.opts`).

## Notes for Agents

- Never add a second writer: the server's single process is what guarantees strict checkpoint ordering (a later `:append` must see the earlier `message_count`).
- `checkpoint/4` is asynchronous; a caller or test that reads immediately after it must first call `flush/1` (e.g. `EvoGit.AgentState.flush(store: server)`) — a plain `load/3` does not queue behind the writer by design.
- The PAUSE path calls `flush/1` immediately before it delivers a paused outcome: `flush/1` is a synchronous writer round-trip, so "it returned" means the paused run's whole conversation AND its `pause_commit` marker are durable. Passing an agent id is the shape that path holds (the writer is shared, so it is the same barrier).
- `repo/1` deliberately uses `:persistent_term` instead of a `GenServer.call` — a call would queue behind pending cast checkpoints and defeat the off-write-path read design.
- A binary SQLite parameter is stored as TEXT when its bytes are valid UTF-8 and as BLOB otherwise; both round-trip unchanged, so `term_to_binary` payloads can be bound directly (verified end-to-end).
- The server is started by `EvoGit.Application` immediately after `{EvoGit.Store, …}` and before `EvoGit.TaskRegistry`.
- `EvoGit.TaskRegistry` is the one production caller of `delete_task/2`: the `delete_task/1` cast and `clear_finished_tasks/0` cascade to it after a successful task-row delete (best-effort, logged at `:warning` on failure; retention pruning is the backstop).

## Test Strategy

The suite (`apps/evo_git/test/**`, owned by a higher-scope agent) must cover, with an isolated instance per test:
`EvoGit.AgentState.start_link(database: <tmp path>, name: nil)` + `store: <pid>` on every call, calling `flush(store: pid)` before every read-backed assertion:

1. `:append` + `load` round-trips `%ReqLLM.Message{}` EXACTLY, including tool calls, tool results and image + audio `ReqLLM.Message.ContentPart`s.
2. N sequential `:append` checkpoints produce N chunk rows whose payloads hold only their tail; `load` rebuilds the same list in `seq` order.
3. `:rewrite` after a compression replaces all chunks with exactly one and updates `message_count`/`chunk_count`; rewriting to an empty list leaves zero chunks and zero counts.
4. Continuity gap: after a divergent `base_seq` (and a missing row with `base_seq > 0`) the owner receives `{:agent_state_resync, task_id, agent_id}` and NOTHING is written.
5. Empty append tail creates/keeps the row without a chunk and still applies `fields`.
6. Field mapping: unknown keys ignored, omitted keys preserved across checkpoints, booleans as 0/1, JSON fields round-tripping (STRING-keyed on read), `:agent_module` back to a module atom.
7. `load` on a missing row → `{:error, :not_found}`; on a corrupted payload blob → `{:error, :corrupt_state}`; against a dead/absent server → `{:error, :store_unavailable}`.
8. `mark_completed` sets `status`/`completed_at` and keeps the row; `prune` with a tiny `:retention_days` deletes only expired runs (and their chunks) while a recent `updated_at` is never pruned; prune returns the deleted count.
9. `delete` removes one run; `delete_task` removes every run of a task (chunks cascade explicitly).
10. `server/0` honours the process-dictionary seam; `repo/1` returns `nil` after the server stops; a checkpoint with no server is a no-op `:ok`.
11. Migration durability (`test/evo_git/agent_state/agent_state_migration_test.exs`): a server started on a fresh temp dir through the REAL boot/migration path has applied versions `[1, 2, 3]`, exactly one nullable `TEXT` `pending_tool_batch` column and exactly one nullable `TEXT` `pause_commit` column; a checkpointed in-flight `EvoGit.Agent.ToolBatch` marker is non-null JSON in that column (asserted by a direct `SELECT`) and `ToolBatch.normalize/1` of the loaded value equals the input; a later checkpoint with `nil` clears the column; and a SECOND boot over the same data dir (plus a forced re-run of versions 2 and 3) keeps the columns, the applied versions and the stored marker intact.
12. Pause/resume facts (`test/evo_git/agent_state/agent_state_pause_test.exs`): `put_pause_commit/3,4` round-trips, replaces and (`nil`) clears a row's `pause_commit` (asserted through a direct `SELECT`), answers `{:error, :not_found}` and creates no row for a run that never checkpointed, and touches NOTHING else (counts, chunk rows and an append at the pre-pause baseline are untouched — the marker even survives a later append); `pause_commit/2,3` reads `nil` on a missing row; `resumable?/1,2` is `true` for any task with a durable run (a message-less scalar-only row included) and `false` for an unknown task and after `delete_task`; `root_agent_ids/1,2` returns only `parent_id IS NULL` rows, ascending, task-scoped and `[]` for an unknown task; and `flush/1` is proven a synchronous barrier (the server answers `:sync` as a `GenServer.call`, and a just-cast checkpoint plus a queued `put_pause_commit` are readable right after it returns, with no sleeping). With no store every new function stays inert (`{:error, :not_persistent_state_disabled}`, `nil`, `false`, `[]`).
