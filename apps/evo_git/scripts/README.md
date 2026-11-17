# Development-only inspected-store repair

`repair_inspected_store.py` is a standalone Python 3.9+ **development recovery tool**, not a runtime migration, installer hook, or general database upgrader.
It has no external dependencies and is never invoked by Genesis.
It repairs only the inspected historical mismatch below; other databases, including an already repaired database, are refused.
Do not broaden its fingerprint to make a refusal disappear without a new inspection and review.

## Accepted preconditions

- SQLite integrity check returns exactly `ok`.
- The only application tables are `tasks`, `task_agent_archives`, `projects`, and `schema_migrations`; no triggers/views or reserved `__genesis_` preservation objects/columns are permitted.
- The ledger contains exactly versions **20260815000001 through 20260815000009**, nine rows, with its original timestamps untouched.
- `tasks` contains **1037 rows**, the canonical **19** legacy columns, and neither `session_mode` nor `pause_kind` (no `archive_metadata`).
- `task_agent_archives` contains **10539 rows** with the canonical 23-column schema, types, nullability, defaults, and composite key.
- Legacy `projects` contains **10 rows**, with `path TEXT PRIMARY KEY`, `name TEXT`, and `last_opened_at TEXT`.
- `vct_mounts` is absent.
- Every project has a non-NUL absolute path: POSIX `/...`, Windows drive-rooted `C:\...` / `C:/...`, or UNC `\\...`; names/timestamps must be TEXT or NULL.

Task physical column order is not significant; existing order is preserved.
Ledger declarations emitted by the historical SQLite adapters (`INTEGER`/`BIGINT` keys, with or without explicit NOT NULL) are accepted.
The script checks these facts; it does not read application configuration, locate a database automatically, deserialize JSON, or print task/archive/project contents.

## Operator procedure

1. Inspect the proposed repair in development and arrange an uninterrupted maintenance window.
2. **Manually** shut down every Genesis/BEAM instance and every other database consumer (including SQLite browsers, test runners, and backup tools).
   Disable anything that could restart them for the whole operation.
   This script never stops, kills, or signals a process.
3. Run on the **Linux host and PID/mount namespace that can see all consumers** of the database; do not use a container's restricted `/proc` against a host database.
   You need permission to inspect every visible process's fd directory (often an administrator-run Python process).
   No elevated access is requested automatically.
4. Supply the database explicitly, first without `--apply`:

   ```sh
   python3 apps/evo_git/scripts/repair_inspected_store.py --db /absolute/development/tasks.sqlite
   ```

5. Only after reviewing this runbook and the dry-run result, request application:

   ```sh
   python3 apps/evo_git/scripts/repair_inspected_store.py --db /absolute/development/tasks.sqlite --apply
   ```

6. Retain the private `store-repair-backup-*/original.sqlite` directory reported on success, inspect the repaired schema offline, and only then restart the intended application.
   Exit status 0 means a dry-run passed or an apply committed; status 1 is a refusal/failure, and argparse uses status 2 for invalid arguments.
   A refusal deliberately prints no raw exception or private data; investigate permissions, process ownership, preconditions, and disk space manually.

Dry-run opens SQLite read-only and performs no repair or backup.
Normal SQLite WAL readers can interact with shared-memory bookkeeping; this is not a promise of byte-for-byte filesystem immutability.
The fd scan covers DB/WAL/SHM paths, deleted-open path targets, and existing inode aliases (hardlinks).
Unreadable, missing-during-inspection, or otherwise uninspectable fds/process directories fail closed, as do missing `/proc` and `hidepid` mounts.
A racing process exit may therefore require retrying the scan.
`/proc` cannot prove visibility outside its PID namespace or prevent a future opener, and SQLite locks do not exclude all readers: **the operator must keep all consumers stopped throughout**.
There is deliberately no unsafe override of the offline guard.

## Apply protocol and guarantees

1. Scan offline before opening the source; validate the complete fingerprint and integrity.
2. Use SQLite's **backup API**, not a filesystem copy: committed WAL data is included.
   Exclusively create a backup in a new mode-0700 directory beside the DB; the backup file is mode 0600.
   Check backup integrity, fingerprint, schema, and every original typed cell against the source; fsync the backup file.
3. Create a separate rehearsal database from that verified backup using the same backup API.
   Run the complete repair and its transaction checks on the rehearsal first; remove the rehearsal afterward.
   Retain the original backup even if rehearsal/application fails.
4. Close source/rehearsal connections, scan offline again, open the existing source in `mode=rw`, and acquire `BEGIN IMMEDIATE`.
   Revalidate the fingerprint, original schema and all original cells against the backup snapshot to catch intervening changes.
5. Add **nullable TEXT, no-default** `tasks.session_mode` and `tasks.pause_kind`, without backfill.
   Create exactly:

   ```sql
   CREATE TABLE vct_mounts (
     point TEXT PRIMARY KEY NOT NULL,
     path TEXT NOT NULL UNIQUE,
     name TEXT NOT NULL,
     kind TEXT NOT NULL,
     last_opened_at TEXT
   );
   ```

6. Import **every** project, with no cap, skip, `OR IGNORE`, deletion or drop.
   Process `last_opened_at DESC` (NULL last), then `path ASC`.
   Derive the basename after normalizing backslashes and trimming trailing slashes; strip ASCII controls and trim surrounding whitespace for the point segment.
   Empty, `.` and `..` segments become `project`; assign `vct:///projects/<segment>` and resolve collisions with `-2`, `-3`, etc., including collisions with already suffixed basenames.
   Preserve path and timestamp values exactly, and preserve a nonblank display name **verbatim**; otherwise use the original derived basename.
   Every imported kind is `git`.
7. **Before COMMIT**, compare every original task/archive/project/ledger cell and row count (including SQLite/Python value types), check original schema objects except the intended tasks extension, verify the entire mount import and NULL new columns, and rerun integrity check.
   Any failure rolls the transaction back, including its DDL.

`projects` remains untouched as recovery evidence.
The migration ledger is never rewritten, deleted, or supplemented: **no version 10 is inserted**.
This script intentionally does not replay old migrations, normalize payloads/timestamps, rebuild indexes, prune archives, or change production code.
This is not a power-loss recovery or atomic filesystem-backup framework; keep the backup and normal operational backups.
Do not copy an old backup over an active WAL database: any manual restoration needs its own offline, reviewed recovery procedure for the DB and its sidecars.

## Synthetic tests only

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s apps/evo_git/scripts -p 'test_*.py' -v
```

Tests create only temporary synthetic databases and fake `/proc` trees.
They exercise WAL-only committed data in verified backups, exact fingerprint refusals, private CLI errors, incomplete fd inspection, deterministic collision-safe full imports (including more than 100 projects), unchanged cells/ledger/projects, transaction rollback, and backup/rehearsal/offline-recheck failure gates.
No real user database is accessed by the suite.
