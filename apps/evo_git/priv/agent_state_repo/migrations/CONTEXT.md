# Agent State Store Migrations

## Intent
Ecto migrations for the SEPARATE `agent_state.sqlite` database that persists per-agent conversation/scalar state for crash recovery, owned by `EvoGit.AgentState` — entirely distinct from the task store's `priv/repo/migrations/` (which this directory must never reuse).

## API Surface
- `000001_create_agent_state.exs` — `EvoGit.AgentStateRepo.Migrations.CreateAgentState`: creates `agent_states` (one row per `(task_id, agent_id)` run) and the append-only `agent_state_chunks` table plus its indexes; `down/0` drops both.

## Constraints
- Version numbers are identities: never renumber a shipped migration; add a new file instead.
- Migrations are loaded as a PRE-LOADED `[{version, module}]` source by `EvoGit.AgentState.Boot` (mirroring `EvoGit.Store.Boot`), so the `.exs` files are compiled at most once per BEAM.
- `IF NOT EXISTS` on every DDL statement keeps a re-run a no-op.
- Column set mirrors `EvoGit.AgentState`'s scalar `fields` map; changing it requires a new migration file.

## Routing Table
- `../../../lib/evo_git/agent_state/` → the store implementation that owns this schema.
