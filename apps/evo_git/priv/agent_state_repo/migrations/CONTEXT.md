# Agent State Store Migrations

## Intent
Ecto migrations for the SEPARATE `agent_state.sqlite` database that persists per-agent conversation/scalar state for crash recovery, owned by `EvoGit.AgentState` — entirely distinct from the task store's `priv/repo/migrations/` (which this directory must never reuse).
The chain is four contiguous versions (1, 2, 3, 4): version 1 is the ONE schema-creating step, and every later version is a probe-guarded no-op on a database that already has the shape it adds; a shipped version number is an IMMUTABLE identity and is never reused or renumbered.

## API Surface
- `000001_create_agent_state.exs` — `EvoGit.AgentStateRepo.Migrations.CreateAgentState`: the ONLY create site of `agent_states` (one row per RUNNING `(task_id, agent_id)` run) and the append-only `agent_state_chunks` table plus their indexes; `down/0` drops both. It deliberately does NOT carry `pending_tool_batch`, `pause_commit` or the v2 run-fact columns (those belong to later versions, so an upgrade path and a fresh boot converge on the same schema).
- `000002_add_pending_tool_batch.exs` — `EvoGit.AgentStateRepo.Migrations.AddPendingToolBatch`: adds `agent_states.pending_tool_batch` (nullable `TEXT` holding the in-flight tool-batch marker as plain JSON text; `NULL` = no batch executing). `up/0` probes `PRAGMA table_info(agent_states)` and issues ONE `ALTER TABLE … ADD COLUMN` only when the column is ABSENT; `down/0` drops it only when it is PRESENT, so either direction is safe to re-run. No `DEFAULT`, no backfill, no index (the column is read with its row, never filtered on).
- `000003_add_pause_commit.exs` — `EvoGit.AgentStateRepo.Migrations.AddPauseCommit`: adds `agent_states.pause_commit` (nullable `TEXT` holding the git commit sha of the worktree checkpoint an agent made when it paused at a turn boundary; `NULL` = no paused checkpoint), written ONLY by `EvoGit.AgentState.Store.put_pause_commit/4` as a scalar `UPDATE` of that one column. Same probe-guarded `up/0`/`down/0` shape as version 2 — one guarded `ALTER TABLE … ADD COLUMN`, a shape post-condition, no `DEFAULT`, no backfill, no index.
- `000004_add_run_facts.exs` — `EvoGit.AgentStateRepo.Migrations.AddRunFacts`: the v2 run-fact step, ADDITIVE only (it never re-creates or reshapes `agent_states`). `up/0` appends seven NULLABLE columns with no `DEFAULT` and no backfill — `spawn_turn`/`spawn_index` (where in the parent's tool batch a child was started), `branch`, `base_commit`, `anchor_ref`, `redispatch` (JSON: the rebuildable `%AgentSpec{}` facts) and `result` (JSON: the finished run's text/commit/repo id) — NORMALIZES the pre-v2 finished-run spelling with `UPDATE agent_states SET status = 'done' WHERE status = 'completed'` (a value normalization, not a schema change), and adds the roster index `agent_states_task_parent_index` on `(task_id, parent_id)`.
  The two pre-existing retention indexes (`agent_states_status_completed_at_index`, `agent_states_updated_at_index`) are deliberately left UNTOUCHED — `prune/1` still uses them.
  `up/0` is IDEMPOTENT (each column behind its own `PRAGMA table_info` probe, the index behind `CREATE INDEX IF NOT EXISTS`, both followed by shape post-conditions) and so is `down/0`, which drops only what this version added — the index and the seven columns in reverse append order — and deliberately does NOT rewrite `'done'` back to `'completed'`, because a status value is stored DATA and relabelling rows that were never legacy would be wrong.

## Constraints
- Version numbers are identities: never renumber a shipped migration; add a new file instead (next free version is 5).
- Migrations are loaded as a PRE-LOADED `[{version, module}]` source by `EvoGit.AgentState.Boot` (mirroring `EvoGit.Store.Boot`), so the `.exs` files are compiled at most once per BEAM.
- Every statement runs through `repo().query/3`/`repo().query!/3` in body order — never `Ecto.Migration.execute/1`, whose string commands queue until `flush/0`, which would make an in-body `PRAGMA` probe observe the pre-migration schema.
- Idempotency is per migration: `IF NOT EXISTS` for every create (version 1) and a column/index-existence probe plus a shape post-condition that raises `Ecto.MigrationError` (boot-fatal) for versions 2, 3 and 4, so a re-run is a no-op and a silent shape drift is impossible.
- A probe that cannot run RAISES: an unreadable schema must never be reported as "the column is missing".
- The column set mirrors `EvoGit.AgentState`'s scalar `fields` map; changing it requires a new migration file.
- `Boot.start_dynamic/2` runs this chain BEFORE the first read or write, so `EvoGit.AgentState.Store` binds the declared columns directly and performs NO runtime schema probing.

## Routing Table
- `../../../lib/evo_git/agent_state/` → the store implementation that owns this schema.
