# EvoGit.Store — SQLite Persistence Codec

## Intent

Contains `EvoGit.Store.Codec` — pure serialization/deserialization functions for the `EvoGit.Store` SQLite persistence layer. This module has NO GenServer and NO I/O; it is stateless and functional.

The module was migrated from `evo_dash` (formerly `EvoDash.Store.Codec`) to `evo_git` as part of the domain persistence layer migration.

## Routing Table

None — leaf directory (single file: `codec.ex`).

## API Surface

### `EvoGit.Store.Codec` (`codec.ex`)

| Function | Description |
|----------|-------------|
| `task_columns/0` | Returns the ordered list of task table column names |
| `project_columns/0` | Returns the ordered list of project table column names |
| `encode_task/1` | TOTAL encode (never raises) — serializes a `%TaskInfo{}` struct into a list of column values. Complex fields (opts, logs, usage, result, archive_metadata) are JSON-encoded via the non-crashing `Jason.encode/1`. |
| `decode_task/1` | Deserializes a list of column values back into a `%TaskInfo{}` struct. Raises on bad data (quarantine handles recovery). |
| `encode_project/1` | TOTAL encode for `%RecentProject{}` structs. |
| `decode_project/1` | Deserializes column values into `%RecentProject{}`. |
| `validate_task/1` | Validates a task list for structural correctness. |
| `validate_project/1` | Validates a project list for structural correctness. |

### Field-level encoders/decoders
- **Atoms**: `encode_atom/1` (accepts nil/atoms/strings), `decode_atom/1` (uses `String.to_existing_atom/1`)
- **DateTime**: `encode_datetime/1`, `decode_datetime/1`
- **Result tuples**: `encode_result/1`, `decode_result/1` — round-trips `{:ok, map}`, `{:error, reason}`, `{:exit, reason}` via `__result_tag__` JSON discriminator, reconstructing the embedded `%EvoGit.Agent.Usage{}` struct on decode
- **Usage**: `encode_usage/1`, `decode_usage/1` — `%EvoGit.Agent.Usage{}` struct ↔ list
- **Archive metadata**: `encode_archive_metadata/1`, `decode_archive_metadata/1`
- **Opts/Logs**: JSON encode/decode via Jason

### Design Principles

1. **TOTAL encode**: Encode functions never raise. All JSON encoding uses non-crashing `Jason.encode/1` with `case`/`with`.
2. **Decode raises on bad data**: The Store's quarantine logic handles crash recovery by moving undecodable rows to a quarantine table.
3. **Atom safety**: Uses closed whitelists with `Map.get/3` for atom conversion from DB-sourced strings.
4. **Result tuple round-tripping**: `{:ok, %{...}}`, `{:error, _}`, `{:exit, _}` tuples survive JSON encode/decode via the `__result_tag__` discriminator.
5. **One justified `try/rescue`**: `decode_reason/1` — `String.to_existing_atom/1` has no non-crashing variant; unknown reason strings legitimately stay strings.

## Constraints

- Pure functional — no GenServer, no I/O, no process calls.
- Column order matters — `@task_columns` and `@project_columns` define positional encoding/decoding.
- JSON encoding via Jason; complex fields stored as JSON TEXT in SQLite columns.
- Known-atom whitelists must stay in sync with the application's valid status/review_status/type atoms.
