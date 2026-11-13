# Agent State Repo

## Intent
Holds the Ecto migrations for the separate `agent_state.sqlite` database (`<data_dir>/agent_state.sqlite`) used for persistent per-agent state.

## API Surface
- `./migrations/` → the versioned Ecto migrations for this database.

## Constraints
- Untracked by the task store: this database has its own unnamed dynamic `EvoGit.Repo` instance, its own WAL and its own boot migrator.
- Never add non-migration files here.

## Routing Table
- `./migrations/` → agent-state schema migrations.
