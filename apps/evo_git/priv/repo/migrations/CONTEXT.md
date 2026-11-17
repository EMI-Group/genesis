# Task-Store Ecto Migrations

## Intent
These up-only Ecto migrations reconcile `tasks.sqlite` before store access through `EvoGit.Store.Boot.run_migrations/1`.
Every migration executes in its own transaction and uses immediate `repo().query!/3` statements rather than queued `execute/1` commands.
Historical versions are identities, not evidence of the physical schema, because an earlier change reused meanings of versions 5 through 9.

## API Surface
The ten files expose distinct migration modules with `up/0`, loaded as ordered `{version, module}` pairs by Store.Boot.
Versions 1 through 9 are frozen and must not be rewritten or renumbered.
Version 1 adopts tasks; 2 normalizes data; 3 and 4 create composite and covering indexes; 5 creates and fans out archives; 6 prunes redundant indexes; 7 creates VCT mounts and imports legacy projects; 8 adds session_mode; 9 adds pause_kind.
Version 10 (`20260815000010_repair_historical_identities.exs`, `RepairHistoricalIdentities`) probes actual tables and columns to reconcile databases with either historical meaning of versions 5 through 9, without changing prior ledger entries.
The earlier meaning of version 5 was covering indexes, 6 unpacked z1 data, 7 created archives, 8 moved archives and 9 normalized archive repo_id affinity.
The repair adds missing nullable TEXT session_mode and pause_kind columns without backfilling or rejecting existing non-NULL values.
It inflates valid `z1:` Base64/zlib JSON in tasks.result, tasks.logs and tasks.archive_metadata one value at a time, preserving all other task fields including updated_at.
It creates missing archives and transactionally copies INTEGER repo_id archives into a TEXT-affinity table with row-count validation, restoring explicitly defined indexes and triggers.
It fans out archive_metadata into relational rows without overwriting existing agent rows and retains the original archive_metadata column and payload as the lossless source.
It creates missing VCT mounts and imports projects with stable basename-derived points and -N collision suffixes without migration-time eviction, keeping projects intact when version 10 encounters it.
Existing mounts, including reserved points, are not overwritten or evicted by version 10.
Version 10 imports projects in last_opened_at DESC, path ASC order, preserves the raw path and timestamp, derives the basename after replacing backslashes and trimming trailing slashes, strips ASCII controls and surrounding whitespace from the point segment, and allocates collision suffixes starting at -2.
Version 10 preserves a nonblank stored display name verbatim rather than trimming it, rejects invalid absolute paths transactionally rather than skipping them, and keeps both projects and all imported mounts without a 100-row cap.
These repair rules differ deliberately from frozen version 7, which trims paths, names and timestamps, skips unusable paths, caps mounts to 100 and drops projects.
A standalone physical-schema repair must leave all existing schema_migrations entries untouched, including versions 20260815000001 through 20260815000009, and must not stamp version 10 unless the actual Ecto migrator applies it.
It reuses the frozen composite, covering and prune index implementations and the frozen VCT implementation only when no legacy projects table exists.

## Constraints
New migrations take the next unused version strictly above 20260815000010 and a unique module name.
Never delete or reset a user's database to repair an upgrade or rewrite schema_migrations to force old DDL to run.
Unknown shapes, malformed compressed JSON, invalid archive records, invalid legacy project paths and SQL failures abort version 10 transactionally with a clear error instead of silently skipping user data.
The repair refuses a pre-existing scratch table instead of dropping potentially valuable recovery data.
Legacy data already lost by a previously applied migration cannot be reconstructed by a later additive repair.
In particular, versions 5 and 7 retain their historical fan-out/drop behavior when they are pending, whereas version 10's own imports retain legacy sources.
Payload statements use a 600-second timeout and avoid loading all heavy task payloads at once.
No application codec or VCT helper is called from the repair, so later runtime refactors cannot change historical conversion behavior.

## Routing Table
This node has no child directories.
Tests live outside this node in `apps/evo_git/test/evo_git/store/` and are owned separately.
Upgrade fixtures must exercise the real migrator from both historical ledger endpoints, fresh boot, existing canonical databases, rollback on corrupt data, source preservation, index restoration and explicit version-10 re-execution with populated session/pause values.
