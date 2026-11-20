# EvoGit.AgentState — Durable Per-Run Agent State

## Intent

Persist each agent run's in-memory state (conversation messages + scalar fields) in a SEPARATE SQLite database so a crashed run is recoverable.
There is ONE row per RUNNING agent, keyed `(task_id, agent_id)` with an `agent_id` that stays STABLE across restarts, plus `parent_id`/`depth` so a task's whole agent tree is readable through `roster/2`.
The database is `<data_dir>/agent_state.sqlite` — deliberately NOT the task store (`tasks.sqlite`), because checkpoints are a high-churn write stream that must never contend with task persistence or dashboard reads.
Writes are serialized through ONE writer process that COALESCES queued checkpoints per run, bounds its own mailbox and caps a payload; reads run in the caller against the same unnamed dynamic `EvoGit.Repo` instance.

## API Surface

| Function | Shape | Contract |
|---|---|---|
| `start_link/1` | `{:ok, pid} \| {:error, term}` | starts the `EvoGit.AgentState.Supervisor` (the writer is its child); opts `:database`, `:data_dir`, `:name` (writer name, default `EvoGit.AgentState.Server`; `nil` = unnamed), `:retention_days`, `:prune_interval`, `:boot_retry_base`, `:boot_retry_max`, `:max_backlog`, `:max_payload_bytes` |
| `child_spec/1` | supervisor spec | `id: EvoGit.AgentState`, `type: :supervisor`; `EvoGit.Application` therefore supervises the whole subsystem, and `start_supervised!/2` returns the SUPERVISOR pid |
| `server/0` | `pid \| nil` | process-dictionary `:evogit_agent_state_server` wins, else the named default when alive |
| `repo/1` | `pid \| nil` | writer (or supervisor pid, resolved) → dynamic `EvoGit.Repo` pid via `:persistent_term`; `nil` when absent/dead/degraded |
| `checkpoint/4` | `:ok` always | CAST; opts `:store`; the writer drains every checkpoint still queued for that SAME run and persists them as ONE folded transaction |
| `flush/1` | `:ok \| {:error, :timeout}` | HONEST SYNCHRONOUS durability barrier (`GenServer.call` `:sync`, never a cast, 30 s DB `busy_timeout` + 10 s statement budget = 40 s): `:ok` means every earlier checkpoint cast — for every agent — is committed; `{:error, :timeout}` means the target is dead/absent, the writer is degraded, or its backlog exceeds the writer's cap (`:max_backlog` start option, else app env `:agent_state_max_backlog`, default 200); `nil` target is `:ok`; takes `store:` opts, a server/supervisor pid, a registered name or an agent id |
| `put_pause_commit/3,4` | `:ok \| {:error, :not_found \| :not_persistent_state_disabled \| term}` | serialized scalar write of the paused worktree checkpoint sha (`nil` clears it); `{:error, :not_found}` when the run has no row |
| `pause_commit/2,3` | `String.t() \| nil` | one run's persisted pause sha; caller-side read, TOTAL (`nil` on a missing row/store/error) |
| `roster/2` | `[%Record{}]` | the task's WHOLE agent tree in ONE `SELECT`, ordered `depth ASC, agent_id ASC`, with `messages: nil` and the full scalar `fields` (identity, parentage, spawn position, git facts, `status`, `result`, `redispatch`); TOTAL (`[]`) |
| `max_agent_id/1` | `non_neg_integer()` | the highest `agent_id` the store has ever held (`0` when empty) — the scheduler's boot seed; TOTAL (`0`) |
| `load/3` | `{:ok, %Record{}} \| {:error, :not_found \| :corrupt_state \| :store_unavailable}` | caller-side read |
| `mark_done/5` | `:ok` | CAST: `status='done'` + `completed_at` + the JSON `result` and `current_commit` (each left alone when `nil`); `{:error, :not_found}` inside the store when no row matched; observable after `flush/1` |
| `delete_done_children/4` | `:ok` | CAST: deletes the `status='done'` children of ONE parent's batch, matched by `(parent_id, spawn_turn)`; a non-integer `spawn_turn` deletes nothing |
| `delete/3` | `:ok` | CAST: one run's row + chunks |
| `delete_task/2` | `:ok` | CAST: every run of one task |
| `delete_tasks/2` | `:ok` | CAST: every run of MANY tasks in ONE writer message and ONE transaction (bulk cleanup); non-list input is ignored |
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
- `fields` keys: `:agent_module`, `:depth`, `:parent_id`, `:node_path`, `:repo_id`, `:repo_less`, `:repo_root`, `:custom_agent_id`, `:mode`, `:archive`, `:objective`, `:model_spec`, `:provider_profile_id`, `:model_id`, `:model_id_locked`, `:prompt_cache_key`, `:llm_model`, `:llm_context_window`, `:turn`, `:usage`, `:total_tokens`, `:compression_count`, `:current_commit`, `:phase`, `:pending_inputs`, `:pending_tool_batch`, `:status`, `:pause_commit`, `:spawn_turn`, `:spawn_index`, `:branch`, `:base_commit`, `:anchor_ref`, `:redispatch`, `:result`.
- Only SUPPLIED keys are written (an UPSERT never clobbers an earlier value with a default); unknown keys are ignored.
- `:status` is the run's liveness, `running` or `done` (never `completed`); a checkpointing session always writes `running`, so a resumed run RE-OPENS a previously `done` row, and `mark_done/5` alone writes the terminal value.
- `:spawn_turn`/`:spawn_index` are the child's position in the parent's tool batch (`nil` for a ROOT), `:branch`/`:base_commit` its own git facts, `:anchor_ref` the ref that keeps `:current_commit` reachable and `:result` the finished run's JSON result (`text`, `commit`, repo id).
- `:redispatch` is the `EvoGit.AgentState.Redispatch` blob a restart rebuilds an `%EvoGit.AgentSpec{}` from; it carries no pids, funs, credentials or request/generation options.
- `:pause_commit` is written ONLY by `put_pause_commit/3,4` (`Store.put_pause_commit/4`), a scalar `UPDATE` of that ONE column: chunks, `message_count`/`chunk_count` and every other scalar stay untouched, so the append/rewrite continuity rule never sees a pause as a conversation write.
- `put_pause_commit/3,4` routes through the SAME single serialized writer (one `GenServer.call`, so it can neither race nor reorder against a checkpoint) and never creates a row: no row for `(task_id, agent_id)` → `{:error, :not_found}`, absent/dead store → `{:error, :not_persistent_state_disabled}`.
- Entry VALIDATION and the fold rules live in the pure `EvoGit.AgentState.Entry` (`normalize/1`, `fold/1`); the writer never validates by hand.

`%EvoGit.AgentState.Record{}` fields: `:task_id`, `:agent_id`, `:fields`, `:messages`, `:message_count`, `:chunk_count`, `:format_version`, `:inserted_at`, `:updated_at`, `:completed_at`.
`fields` is ATOM-keyed; text columns decode to strings, booleans to `true | false`, `:agent_module` to the module atom when loaded (else the stored string), and JSON columns (`:model_spec`, `:usage`, `:pending_inputs`, `:pending_tool_batch`) to Jason's native STRING-keyed shape.
`fields[:pending_tool_batch]` is the in-flight tool-batch marker (`EvoGit.Agent.ToolBatch`): plain JSON text in a nullable column, `nil` unless a batch is executing, and `EvoGit.Agent.ToolBatch.normalize/1` is the ONE place that turns a restored value back into the atom-keyed shape.
`Record.status/1` (`"running" | "done" | nil`) and `Record.result/1` (the stored JSON result map or `nil`) are the ONE readers of those two facts; both are total for any input.
Timestamps are `%DateTime{}` (ISO8601 second precision, UTC) or `nil`.

## Routing Table

- `agent_state.ex` → public facade (`EvoGit.AgentState`), no SQL; resolves a supervisor pid to the writer through `:persistent_term` before any call/cast.
- `agent_state/supervisor.ex` → `EvoGit.AgentState.Supervisor`, the subsystem's ONE supervisor (`one_for_one`, 10 restarts / 60 s) whose only child is the writer; it passes its own pid as the `:supervisor` start option.
- `agent_state/server.ex` → `EvoGit.AgentState.Server`, the single serialized writer GenServer, non-fatal/degraded boot with bounded retry, explicit repo-death handling, repository publishing, the prune timer, checkpoint COALESCING (selective drain + fold) and the bounded mailbox (backlog and payload caps).
- `agent_state/entry.ex` → `EvoGit.AgentState.Entry`, the PURE checkpoint-entry layer: `normalize/1` (the one validation gate) and `fold/1` (one run's queued entries → the minimal ordered list of store operations; no processes, DB or logging).
- `agent_state/boot.ex` → `EvoGit.AgentState.Boot`, dynamic repo + migrator for `priv/agent_state_repo/migrations/`.
- `agent_state/store.ex` → `EvoGit.AgentState.Store`, every SQL operation (`checkpoint_batch/4` = a whole fold in ONE transaction; `checkpoint/4` = its one-operation form).
- `agent_state/record.ex` → `EvoGit.AgentState.Record`, field/column mapping + message blob codec, plus the `status/1` and `result/1` readers.
- `agent_state/redispatch.ex` → `EvoGit.AgentState.Redispatch`, the ONE owner of the re-dispatch blob: `build/2` projects a `%EvoGit.AgentSpec{}` plus the run/spawn facts into ONE STRING-keyed, JSON-clean map over an explicit closed key list, and `to_spec_opts/1` is its inverse (an `AgentSpec` option list, foreign repos rebuilt as `%EvoGit.Core.ForeignRepo{}`).
- `agent_state/anchor.ex` → `EvoGit.AgentState.Anchor`, the git-durability anchor: `ref/2` (`refs/genesis/agent-state/<task_id>/<agent_id>`) and `anchor/4` (fire-and-forget, deduped per caller through the process dictionary).
- `agent_state/retention.ex` → `EvoGit.AgentState.Retention`, pure cutoff/interval math.
- Migrations: `apps/evo_git/priv/agent_state_repo/migrations/`.

## Storage Model

- ONE unnamed dynamic `EvoGit.Repo` instance per server, started via `EvoGit.AgentState.Boot.start_dynamic/2` with `pool_size: 2`, `journal_mode: :wal`, `synchronous: :normal` plus `EvoGit.Repo.start_opts/0` tuning — never the canonical named repo, and `EvoGit.Repo.start_opts/0`/`defaults/0` are unchanged.
- Migrations run on a single-connection boot repo which is then stopped and reopened at the final pool size (SQLite schema-laziness: pool connections must open an already-migrated file).
- Migration chain: `000001_create_agent_state` is the ONE schema-creating step, `000002_add_pending_tool_batch` adds `agent_states.pending_tool_batch`, `000003_add_pause_commit` adds `agent_states.pause_commit` and `000004_add_run_facts` adds the seven v2 run-fact columns (`spawn_turn`, `spawn_index`, `branch`, `base_commit`, `anchor_ref`, `redispatch`, `result`), each behind a `PRAGMA table_info` probe, so a fresh boot and an existing data dir converge on the same schema.
- Because that chain runs BEFORE the first read or write, the store writes `Record.encode_fields/1`'s columns and reads `Record.all_columns/0` directly: there is NO runtime schema probe, no per-checkpoint `PRAGMA` and no "missing column" warning path.
- `EvoGit.AgentState.Boot` has its OWN `:global` lock id (`{:evo_git_agent_state_migrations, self()}`) and its OWN memoized `:persistent_term` migration source; it never calls `EvoGit.Store.Boot`.
- Boot is NON-FATAL: `Boot.start_dynamic/2` contains `File.mkdir_p`, the repo start and the migrations in one rescue/catch (stopping any partially started boot repo) and answers `{:ok, pid} | {:error, reason}`. The writer starts DEGRADED (`repo: nil`) with ONE warning and retries on a bounded exponential backoff (1 s doubling to a 60 s cap; `:boot_retry_base`/`:boot_retry_max` override it), so a broken/unwritable/locked file can never take down `EvoGit.Supervisor`, the application or the BEAM.
- One checkpoint = one transaction: scalar-row UPSERT + (optional) single chunk INSERT. Message payloads are `:erlang.term_to_binary(messages, compressed: 6)`; JSON fields are Jason TEXT; booleans are 0/1.
- Tables: `agent_states` (PK `(task_id, agent_id)`) and `agent_state_chunks` (PK `(task_id, agent_id, seq)`).

## Writer Coalescing & Bounds

The ONE writer serializes SQLite, so it also owns how much work a queued backlog may cost.

- **Coalescing** — when a checkpoint cast is handled, every checkpoint cast already queued for that SAME `(task_id, agent_id)` is drained with a selective `receive … after 0`; another run's checkpoint, a `:sync` call and every other message stay in the mailbox, untouched and in order. The drained batch plus the arriving entry fold through `Entry.fold/1` and are persisted by ONE `Store.checkpoint_batch/4` transaction (sequential operations inside one `EvoGit.Repo.transaction/1`), so a stalled disk costs one commit per batch instead of one per message.
- **Fold rules** (`EvoGit.AgentState.Entry`): a later `:rewrite` SUPERSEDES everything queued before it; consecutive `:append`s CHAIN when `next.base_seq == base_seq + length(messages)` of the accumulated append (a `nil` base_seq is `0`) and fold into ONE append with the FIRST `base_seq` and concatenated messages (a rewrite of N messages accepts an append at N and stays ONE rewrite); a GAP keeps entries as separate operations that still run in ONE transaction and in order; `fields` merge last-wins (a superseded entry's keys are still carried, because an UPSERT only touches the keys it supplies); `owner` is the last non-nil owner; an empty queue folds to `[]`.
- **`Store.checkpoint_batch/4`** answers exactly like `checkpoint/4`: `:ok`, `:resync` (an operation's `:base_seq` did not match the stored message count — the WHOLE fold is rolled back, nothing partial survives), `{:error, reason}`, and a no-op `:ok` for an empty fold (`{:error, :invalid_operations}` for a non-list). `checkpoint/4` is its one-operation form.
- **Back-pressure** — the arriving checkpoint is compared against the writer's mailbox cap (`:max_backlog` start option, else app env `:agent_state_max_backlog`, default 200; `0` is a real cap). OVER the cap it is DROPPED and NOT drained (the writer never grows its own queue), its `owner` receives `{:agent_state_resync, task_id, agent_id}` (the session answers by rewriting its full transcript, so the loss self-heals) and ONE warning is logged. `flush/1`'s `:sync` honesty test uses the same cap.
- **Payload cap** — a fold whose measured payload exceeds `:max_payload_bytes` (else app env `:agent_state_max_payload_bytes`, default 8 MiB) is SKIPPED with ONE warning and NO resync (a resync would only re-send the same oversized transcript). The measurement is `:erlang.external_size/1` of each operation's messages — the uncompressed external term size of the term the store hands to `Record.encode_messages/1`, a cheap deterministic upper bound; an unmeasurable term is treated as within the cap and then fails, totally, inside the store.
- **Rate limiting** — both skip paths log at most ONE warning per run per failure streak: the server keeps `warnings: %{ {task_id, agent_id} => {detail, count} }`, increments the count for further skips with the same detail, logs again only when the detail changes, and DELETES the entry when a checkpoint for that run is accepted (one `:info` "resumed after N skipped" line). The map is therefore bounded by the runs currently skipping writes and never grows with traffic.
- **Degraded writer** — `repo: nil` drops checkpoints with `:ok` and NO per-checkpoint log (the boot warning already told the operator).
- Both caps are per-instance start options with the app env as their default, so tests exercise them without mutating a BEAM-global.

## Cost Profile — what one checkpoint costs, and in WHICH process

- The CALLER (the session `gen_statem`, the process an exchange worker awaits) does no encoding: it compares its adopted and new message lists, then `GenServer.cast`s the entry.
- The cast COPIES the term into the writer's heap — the tail on `:append` (a tool-output turn can carry ~100 KB–1 MB), the WHOLE transcript on `:rewrite`; that copy is the only per-checkpoint cost the turn loop pays.
- The WRITER (`Server`) runs `Entry.normalize/1` + `:erlang.external_size/1` (the payload cap: an uncompressed traversal) + `Entry.fold/1`, then ONE `Store.checkpoint_batch/4`.
- `Record.encode_messages/1` is `:erlang.term_to_binary(messages, compressed: 6)` (zlib level 6) of the TAIL on `:append` and of the FULL transcript on `:rewrite`.
- `Record.encode_fields/1` Jason-encodes every JSON column supplied on EVERY checkpoint — `:redispatch` (which carries the objective text), `:usage`, `:pending_inputs`, `:pending_tool_batch` — not only on the first one.
- One checkpoint = one `BEGIN IMMEDIATE` transaction: `SELECT message_count, chunk_count`, one chunk INSERT, one ~37-column UPSERT (the dynamic SQL is rebuilt per write).
- WAL + `synchronous: normal` does NOT fsync per commit (SQLite syncs the WAL at an auto-checkpoint, ~1000 pages, and the database file after it), so the occasional slow commit is a checkpoint fsync on slow/network storage and it stalls the WRITER only.
- A small append is single-digit milliseconds; a multi-MB `:rewrite` (post-compression, first snapshot, or a resync) is tens of milliseconds.
- The writer is SHARED by every agent in the BEAM, so N concurrent agents serialize their commits there — a backlog delays durability, never a turn.

## Status, Row Lifecycle & Roster Queries

`agent_states.status` is `TEXT NOT NULL DEFAULT 'running'` and has exactly two values, `running` and `done`; it surfaces as `Record.fields[:status]` / `Record.status/1`.
A checkpointing session always writes `running`, `mark_done/5` (through `Session.Persistence`'s `complete/1,2`) is the ONE writer of `done`, and `000004_add_run_facts` normalized the pre-v2 `'completed'` spelling of existing rows to `'done'`.
There is NO query that selects rows by `status`, and NO unfinished/"recoverable run" listing API: the only `status`-filtered statement is `delete_done_children/4` (the done children of one parent's batch) and the only retention scan is `prune/1`'s `SELECT`, which deletes and returns nothing to callers.
The row exists from the MOMENT A RUN STARTS, not from its first turn: the session writes ONE full `:rewrite` snapshot at start (identity, run facts, `redispatch`, `status: "running"`), and every turn boundary after that appends the tail.
A completed ROOT deletes its own row (nothing consumes a root's result); a completed CHILD keeps its `done` row — the parent and the resume path read it as proof that the child finished — until the parent's checkpoint that CLEARS `pending_tool_batch` deletes the `done` children of that turn (`delete_done_children/4`, the turn taken from `EvoGit.Agent.ToolBatch.normalize/1`).
`prune/1` (retention, default 7 days) is the backstop for rows a crash left behind.
`roster/2` is the per-TASK tree read — ONE `SELECT` over every row of the task, ordered `depth ASC, agent_id ASC`, with `messages: nil` — so identity, parentage, spawn position, git anchoring, `status` and `result` are all available without a chunk read, and a resume admission resolves the ROOT row it must restore from it.
Identity is STABLE and is the CALLER's `agent_id`, never a lookup by task: every read (`load/3`, `pause_commit/2,3`) is keyed `(task_id, agent_id)`, the scheduler seeds its id counter from `max_agent_id/1` at boot, and a registration adopts a persisted `opts[:agent_id]` (see `agent_scheduler/CONTEXT.md`), so a restore of an id can only ever address the run that persisted it.
`load/3` never filters on `status`/`completed_at`, so a done or abandoned run loads exactly like a live one.
A never-completed record is retained until `updated_at` is older than `2 × retention_days` (default 14 days) — the binding constraint of `prune/1`'s two windows — and is then deleted by the hourly prune pass.
The primary key is `(task_id, agent_id)` with NO retry/attempt column, so a retry of the same agent id upserts the same row; `:turn` and `:compression_count` are the only progress counters.

## Git Anchoring

A branch inside `.genesis/workers/` is NOT durability: the first worktree create after a BEAM restart wipes that directory and every `evogit-agent-*` branch, and an unanchored commit is then gc-eligible.
Every checkpoint that ADVANCES `current_commit` therefore anchors that sha at `refs/genesis/agent-state/<task_id>/<agent_id>` (`Anchor.ref/2`) and records it as `fields[:anchor_ref]`.
`refs/genesis/agent-state/*` is a plain ref in the repository's git dir, not a branch: `WorktreeManager.clean_orphaned_branches/1` lists `refs/heads` only, `Worktrees.delete_branch_tolerant/2` deletes the agent's branch only, and nothing in this codebase runs `git gc`/`git prune`, so the anchor is what keeps the run's commits reachable past worktree reclamation.
`Anchor.anchor/4` never runs a `git` subprocess on the caller's path and never raises or exits into it: it records the sha in the CALLER's process dictionary and hands ONE `EvoGit.Adapters.Git.update_ref/3` to a supervised, unlinked `EvoGit.TaskSupervisor` child, so an unchanged commit costs one map lookup (the dedupe) and a failed write is logged at debug only — a lost anchor degrades durability instead of breaking the run.
A repo-less run (no repository) and a `persistent_state: false` task never anchor.

## Constraints

- `checkpoint/4` is a CAST, always `:ok`, and total: a malformed entry, a store fault, a dead server, a dropped backlog overflow or a skipped oversized payload is logged/dropped and never propagates into an agent run.
- `flush/1` is the ONE synchronous durability barrier (`GenServer.call` `:sync` with a 40 s timeout — `EvoGit.Repo.start_opts/0`'s 30 s `busy_timeout` plus a 10 s statement budget — NOT a cast) and is total: `:ok` when the writer committed everything queued before it (and for a `nil` target), `{:error, :timeout}` when the target is dead/absent, the writer is degraded, or the writer's own `message_queue_len` backlog is above its cap (`:max_backlog` start option, else app env `:agent_state_max_backlog`, default 200).
- `put_pause_commit/3,4` is total and never creates a row; `pause_commit/2,3`, `roster/2` and `max_agent_id/1` are TOTAL reads that answer `nil` / `[]` / `0` on a missing row, an absent/dead store or any store fault.
- `load/3` is total: missing row → `:not_found`; corrupt blob / chunk-count or message-count mismatch → `:corrupt_state`; absent/dead server or store fault → `:store_unavailable`.
- Reads never queue behind checkpoint casts: `load/3`, `pause_commit/2,3`, `roster/2` and `max_agent_id/1` resolve the repo pid from `:persistent_term` and read in the calling process via `EvoGit.Store.RepoScope.with_repo/2`.
- `:erlang.binary_to_term/1` has exactly ONE justified `try/rescue` in `Record.decode_messages/1`; the payload must decode to a list of `%ReqLLM.Message{}` or the result is `:error`.
- Retention: a `done` row (its `completed_at` set) is pruned once `completed_at` is older than `retention_days` (default 7, app env `:agent_state_retention_days`); a run that never finished once `updated_at` is older than `retention_days * 2`; a row whose `updated_at` is inside the retention window is never pruned. The server runs an hourly `Process.send_after` prune; a prune error is `Logger.warning`-ed and never crashes the server.
- Timestamps are stored ISO8601 UTC at second precision so string comparison implements retention ordering.
- Column names come ONLY from `Record`'s constant lists; SQL uses positional `?` placeholders.
- The checkpoint path is PURE until the store: `EvoGit.AgentState.Entry` does validation and folding (no processes, no DB, no logging) and `EvoGit.AgentState.Store` is the only SQL boundary.
- Coalescing, the backlog cap and the payload cap are documented above ("Writer Coalescing & Bounds") and must stay per-instance options, never app-env-only.
- The task flag is `:persistent_state` (admitted by `RuntimeOpts.admit_persistent_state/1`, threaded through task opts → `AgentSpec.opts`).

## Known Issues — Global Serialization
- The server runs EVERY write INLINE in its own process (`Store.checkpoint_batch` → `EvoGit.Repo.transaction`), the exact pattern `EvoGit.Store.Writer` was introduced to remove for the task store, so one slow or lock-blocked write blocks the mailbox for every agent (a queued backlog for one run is at least folded into ONE transaction, not one per checkpoint).
- All runs share that ONE writer. Checkpoints and the `mark_done`/`delete`/`delete_task`/`delete_tasks`/`delete_done_children` bookkeeping are CASTS (never a synchronous barrier for the caller), but `put_pause_commit/3,4` and `flush/1` remain calls by design.
- A call the caller abandoned on its own timeout still stays queued and is executed later.
- `with_migration_lock/1` returns `:aborted` when the `:global` lock is not granted and `migrate_synchronized!/0` ignores it, so a contended boot can silently skip migrations.
- The 2-connection pool is shared by the writer and every caller-side read (`load/3` in the session, `pause_commit/2` in the scheduler's dispatch path, `roster/2` in `TaskRegistry`), and those reads run INSIDE those GenServers.

## Known Issues — Query & Write Amplification

- Retention `prune/2` issues two DELETEs per expired row inside ONE writer transaction and has no batch limit (`store.ex:639-660`), so a post-downtime backlog of expired runs holds the single writer (and every checkpoint) for the whole pass.
- `delete_tasks/2` runs two statements per task id inside one transaction (`store.ex:372-384`), so clearing many finished tasks costs 2N statements.
- `max_agent_id/1` is `SELECT MAX(agent_id)` with no index on `agent_id` (the PK leads with `task_id`), i.e. a full scan at scheduler boot behind a 2 s offload budget (`store.ex:486-497`).
- `roster/2` selects every column (including the `redispatch` blob and `objective`) and eagerly JSON-decodes each row (`store.ex:462-477`, `record.ex:146-150`), and no index provides its `depth ASC, agent_id ASC` order; restart classification issues one such read PER orphaned task (`task_registry.ex:2461`).
- Every checkpoint supplies all 34 scalar fields, so `redispatch`/`objective` are Jason-encoded and all columns rewritten each turn although the store only touches supplied keys (`agent/session/persistence.ex:103-144`, `record.ex:132-140`).
- `agent_states_status_completed_at_index` is indexed on a column no query filters (`store.ex:530`), yet every `mark_done` maintains it (migration `000001_create_agent_state.exs:57-60`).
- `delete_done_children/4` reads the ids then builds a per-call IN list (`store.ex:571-614`), so its statement shape varies per batch.

## Notes for Agents

- Never add a second writer: the server's single process is what guarantees strict checkpoint ordering (a later `:append` must see the earlier `message_count`).
- `checkpoint/4` is asynchronous; a caller or test that reads immediately after it must first call `flush/1` (e.g. `EvoGit.AgentState.flush(store: server)`) — a plain `load/3` does not queue behind the writer by design.
- The PAUSE path calls `flush/1` immediately before it delivers a paused outcome: `flush/1` is a synchronous writer round-trip, so an `:ok` reply means the paused run's whole conversation AND its `pause_commit` marker are durable. `EvoGit.Agent.Session.Pause` claims `durable: true` ONLY for that `:ok`; a `{:error, :timeout}` still pauses but reports `durable: false` (and `Pause.info/3`, the belt-and-braces shape that never flushes, always does). Passing an agent id is the shape that path holds (the writer is shared, so it is the same barrier).
- `repo/1` deliberately uses `:persistent_term` instead of a `GenServer.call` — a call would queue behind pending cast checkpoints and defeat the off-write-path read design. The writer publishes `{EvoGit.AgentState, :repo, server_pid}` at every successful (re)boot and `{EvoGit.AgentState, :server_for, supervisor_pid}` at init, erasing both on terminate; a repo `:EXIT`/`:DOWN` erases the repo entry, logs ONE warning and schedules the backoff reboot (the server survives, never a live server on a dead repo).
- A binary SQLite parameter is stored as TEXT when its bytes are valid UTF-8 and as BLOB otherwise; both round-trip unchanged, so `term_to_binary` payloads can be bound directly (verified end-to-end).
- The server is started by `EvoGit.Application` immediately after `{EvoGit.Store, …}` and before `EvoGit.TaskRegistry`.
- `EvoGit.TaskRegistry` is the production caller of the delete casts: the `delete_task/1` cast and `clear_finished_tasks/0` cascade to them after a successful task-row delete (best-effort, logged at `:warning` on failure; retention pruning is the backstop). `delete_tasks/2` is the ONE-message bulk shape for callers clearing many tasks.

## Test Strategy

The suite (`apps/evo_git/test/evo_git/agent_state/**`) covers, with an isolated instance per test:
`EvoGit.AgentState.start_link(database: <tmp path>, name: nil)` + `store: <pid>` on every call, calling `flush(store: pid)` before every read-backed assertion.
Every module is `async: true` (isolation is the per-test supervisor + `store:` pid), and the cast-based bookkeeping writes (`mark_done`/`delete`/`delete_task`/`delete_tasks`) are always observed after `flush/1`:

1. `:append` + `load` round-trips `%ReqLLM.Message{}` EXACTLY, including tool calls, tool results and image + audio `ReqLLM.Message.ContentPart`s.
2. N sequential `:append` checkpoints (each flushed before the next) produce N chunk rows whose payloads hold only their tail; `load` rebuilds the same list in `seq` order.
3. `:rewrite` after a compression replaces all chunks with exactly one and updates `message_count`/`chunk_count`; rewriting to an empty list leaves zero chunks and zero counts.
4. Continuity gap: after a divergent `base_seq` (and a missing row with `base_seq > 0`) the owner receives `{:agent_state_resync, task_id, agent_id}` and NOTHING is written.
5. Empty append tail creates/keeps the row without a chunk and still applies `fields`.
6. Field mapping: unknown keys ignored, omitted keys preserved across checkpoints, booleans as 0/1, JSON fields round-tripping (STRING-keyed on read), `:agent_module` back to a module atom.
7. `load` on a missing row → `{:error, :not_found}`; on a corrupted payload blob → `{:error, :corrupt_state}`; against a dead/absent server → `{:error, :store_unavailable}`.
8. `mark_done` sets `status='done'`/`completed_at` with the JSON `result` and `current_commit` (a `nil` argument leaves that fact alone) and keeps the messages and counts; `prune` with a tiny `:retention_days` deletes only expired runs (and their chunks) while a recent `updated_at` is never pruned; prune returns the deleted count.
9. `delete` removes one run; `delete_task` removes every run of a task (chunks cascade explicitly); `delete_tasks` removes every run of every listed task in ONE cast (untouched siblings kept, `[]`/re-delete/non-list input all `:ok`).
10. `server/0` honours the process-dictionary seam; `repo/1` returns `nil` after the server stops; a checkpoint with no server is a no-op `:ok`.
11. Migration durability (`test/evo_git/agent_state/agent_state_migration_test.exs`): a server started on a fresh temp dir through the REAL boot/migration path has applied versions `[1, 2, 3, 4]`, exactly one nullable `TEXT` `pending_tool_batch` column and exactly one nullable `TEXT` `pause_commit` column; a checkpointed in-flight `EvoGit.Agent.ToolBatch` marker is non-null JSON in that column (asserted by a direct `SELECT`) and `ToolBatch.normalize/1` of the loaded value equals the input; a later checkpoint with `nil` clears the column; and a SECOND boot over the same data dir (plus a forced re-run of versions 2, 3 and 4) keeps the columns, the applied versions and the stored marker intact.
12. Pause/resume facts (`test/evo_git/agent_state/agent_state_pause_test.exs`): `put_pause_commit/3,4` round-trips, replaces and (`nil`) clears a row's `pause_commit` (asserted through a direct `SELECT`), answers `{:error, :not_found}` and creates no row for a run that never checkpointed, and touches NOTHING else (counts, chunk rows and an append at the pre-pause baseline are untouched — the marker even survives a later append); `pause_commit/2,3` reads `nil` on a missing row; and `flush/1` is proven an HONEST synchronous barrier (the writer answers `:sync` as a `GenServer.call`; a just-cast checkpoint plus a queued `put_pause_commit` are readable right after an `:ok` reply with no sleeping, and a burst of five queued appends is durable as ONE folded chunk — 2 chunks, not 6 — because the barrier promises every message, not one row per checkpoint). With no store the pause functions stay inert (`{:error, :not_persistent_state_disabled}`, `nil`).
13. Supervision & containment (`test/evo_git/agent_state/agent_state_supervision_test.exs`): a database under a path whose parent is a regular FILE boots DEGRADED (supervisor and writer alive, `repo/1` nil, every API total, `flush/1` `{:error, :timeout}`), survives several retry ticks, and RECOVERS to a working store once the directory is writable; the subsystem's own supervisor absorbs five writer kills inside a few hundred ms (`Supervisor.count_children/1` shows one worker) — more than the application supervisor's 3/5 s budget; a killed repo pid leaves the writer alive with `repo/1` nil and documented read/barrier answers, then the backoff path boots a FRESH repo that checkpoints and loads again; and every call accepts the supervisor pid as well as the writer pid.
14. Honest barrier & cast bookkeeping (`test/evo_git/agent_state/agent_state_barrier_test.exs`): `flush/1` is `:ok` on a healthy writer and for `nil`, `{:error, :timeout}` for a dead/absent target and when the writer's mailbox backlog is above the cap (the `:sync` call is queued BEFORE the noise casts while the writer is suspended, so its own `message_queue_len` is over the cap when it is handled); a writer killed while the call is parked exits the caller into `{:error, :timeout}`; and `mark_done`/`delete`/`delete_task`/`delete_tasks` are total casts for live and dead targets, durable after `flush/1`.
15. Pause durability verdict (`test/evo_git/agent_state/pause_durability_test.exs`): `EvoGit.Agent.Session.Pause.info/3` always reports `durable: false` (the belt-and-braces paths never flush), while `info/4` reports `true` only for a literal `true` — the value derived from `flush/1`'s `:ok`.
16. Entry folding (`test/evo_git/agent_state/entry_test.exs`, pure — no store, no `:tmp_dir`): `normalize/1` accepts the documented atom-keyed shape (`fields`/`owner` defaulted, `nil` base_seq kept) and rejects unknown kinds, non-list/scalar message lists, negative or float `base_seq`, non-map `fields` and non-map entries; `fold/1` collapses N rewrites to the LAST content, folds chained appends into ONE append with the FIRST `base_seq` and the concatenated tail (a `nil` base_seq counting as `0`), keeps a rewrite-plus-chained-appends as ONE rewrite, KEEPS a continuity gap as separate ordered operations, merges `fields` last-wins across a superseding rewrite, carries the last non-nil `owner`, folds an empty queue (and a non-list) to `[]`, and ignores entries it cannot interpret.
17. Writer coalescing, back-pressure and the payload cap (`test/evo_git/agent_state/agent_state_coalescing_test.exs`, per-instance `:max_backlog`/`:max_payload_bytes` so it stays `async: true`): with the writer suspended, five queued appends for ONE run become ONE new chunk row (2 chunks total, `[[6, 2]]` counts) and four queued rewrites collapse to the LAST one; a checkpoint queued BETWEEN another run's two is never drained (each run keeps its own row and chunk); with `max_backlog: 1` the arriving checkpoint of three queued ones is dropped — ONE `{:agent_state_resync, task_id, agent_id}`, ONE warning, the later two still coalesced and stored, the writer alive and its mailbox drained; a 20-checkpoint flood still logs exactly ONE warning; a dropped checkpoint is not drained, so the folded survivor reports the continuity gap honestly (`:resync` and no row); a payload over the cap is skipped with ONE warning, NO resync and no row, and a later small checkpoint persists and RESETS the streak so the next oversized one logs a second warning; the cap measures the WHOLE fold (two chained tails that each fit but together do not); and `Store.checkpoint_batch/4` commits a whole fold in one transaction while rolling ALL of it back on a resync, with `[]` a no-op and a non-list a documented error.
18. v2 run facts (`test/evo_git/agent_state/agent_state_run_facts_test.exs`): `roster/2` returns the task's whole tree ordered `depth ASC, agent_id ASC` with `messages: nil` and the full scalar fields, scoped to one task and `[]` for an unknown one; `max_agent_id/1` answers the largest stored id (`0` on an empty/dead store) and never goes backwards; `mark_done/5` writes `status='done'` + `completed_at` + the JSON `result` + `current_commit` (each `nil` argument preserving the stored value) and answers `{:error, :not_found}` in the store for a row that never existed; `Record.status/1`/`Record.result/1` read those two columns; and `delete_done_children/4` deletes only the `done` children of ONE `(parent_id, spawn_turn)` batch (a still-`running` child, another turn, the parent and another task all survive), with a non-integer turn a no-op.
19. Run-facts migration (`test/evo_git/agent_state/agent_state_run_facts_migration_test.exs`): a database stamped at version 3 and carrying a legacy `status = 'completed'` row is migrated to version 4 in place — the seven run-fact columns appear nullable/non-key with the pre-existing data intact, the legacy status normalizes to `'done'`, the new `(task_id, parent_id)` index exists beside the two untouched retention indexes, and a re-run of `up/0`/`down/0` is idempotent in both directions.
20. Anchoring (`test/evo_git/agent_state/anchor_test.exs`, real git on a `:tmp_dir` repo): `ref/2` names `refs/genesis/agent-state/<task_id>/<agent_id>` and is total for any identifier; `anchor/4` creates the ref for a real commit (fire-and-forget, observable through `Git.rev_parse` once the supervised task lands), dedupes a repeated sha from the same caller, writes no ref for a blank/non-binary repo path or sha, and survives a branch delete/worktree reclaim because the ref lives outside `refs/heads`.
21. Re-dispatch blob (`test/evo_git/agent_state/redispatch_test.exs`, pure): `build/2` emits EXACTLY the documented key list, carries no pid/fun/credential/request option, and round-trips meaning-preserving through `Jason.encode!/1` + `Jason.decode/1`; `to_spec_opts/1` reconstructs the option list (foreign repos as `%ForeignRepo{}`, role atoms back to atoms, `false` preserved, `nil`s dropped) and is total for a non-map.
