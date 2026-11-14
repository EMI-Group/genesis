# Agent State Store Migrations

## Intent
Ecto migrations for the SEPARATE `agent_state.sqlite` database that persists per-agent conversation/scalar state for crash recovery, owned by `EvoGit.AgentState` — entirely distinct from the task store's `priv/repo/migrations/` (which this directory must never reuse).
The chain is three contiguous versions (1, 2, 3): version 1 is the ONE schema-creating step, and every later version is a probe-guarded no-op on a database that already has the shape it adds.

## API Surface
- `000001_create_agent_state.exs` — `EvoGit.AgentStateRepo.Migrations.CreateAgentState`: the ONLY create site of `agent_states` (one row per `(task_id, agent_id)` run) and the append-only `agent_state_chunks` table plus their indexes; `down/0` drops both. It deliberately does NOT carry `pending_tool_batch` or `pause_commit` (those columns belong to later versions, so an upgrade path and a fresh boot converge on the same schema).
- `000002_add_pending_tool_batch.exs` — `EvoGit.AgentStateRepo.Migrations.AddPendingToolBatch`: adds `agent_states.pending_tool_batch` (nullable `TEXT` holding the in-flight tool-batch marker as plain JSON text; `NULL` = no batch executing). `up/0` probes `PRAGMA table_info(agent_states)` and issues ONE `ALTER TABLE … ADD COLUMN` only when the column is ABSENT; `down/0` drops it only when it is PRESENT, so either direction is safe to re-run. No `DEFAULT`, no backfill, no index (the column is read with its row, never filtered on).
- `000003_add_pause_commit.exs` — `EvoGit.AgentStateRepo.Migrations.AddPauseCommit`: adds `agent_states.pause_commit` (nullable `TEXT` holding the git commit sha of the worktree checkpoint an agent made when it paused at a turn boundary; `NULL` = no paused checkpoint), written ONLY by `EvoGit.AgentState.Store.put_pause_commit/4` as a scalar `UPDATE` of that one column. Same probe-guarded `up/0`/`down/0` shape as version 2 — one guarded `ALTER TABLE … ADD COLUMN`, a shape post-condition, no `DEFAULT`, no backfill, no index.

## Constraints
- Version numbers are identities: never renumber a shipped migration; add a new file instead (next free version is 4).
- Migrations are loaded as a PRE-LOADED `[{version, module}]` source by `EvoGit.AgentState.Boot` (mirroring `EvoGit.Store.Boot`), so the `.exs` files are compiled at most once per BEAM.
- Every statement runs through `repo().query/3`/`repo().query!/3` in body order — never `Ecto.Migration.execute/1`, whose string commands queue until `flush/0`, which would make an in-body `PRAGMA` probe observe the pre-migration schema.
- Idempotency is per migration: `IF NOT EXISTS` for every create (version 1) and a column-existence probe plus a shape post-condition that raises `Ecto.MigrationError` (boot-fatal) for versions 2 and 3, so a re-run is a no-op and a silent shape drift is impossible.
- A probe that cannot run RAISES: an unreadable schema must never be reported as "the column is missing".
- The column set mirrors `EvoGit.AgentState`'s scalar `fields` map; changing it requires a new migration file.
- `Boot.start_dynamic/2` runs this chain BEFORE the first read or write, so `EvoGit.AgentState.Store` binds the declared columns directly and performs NO runtime schema probing.

## Routing Table
- `../../../lib/evo_git/agent_state/` → the store implementation that owns this schema.
