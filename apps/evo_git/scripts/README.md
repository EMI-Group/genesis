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
3. Run directly on the **genuine Linux host in its initial PID/mount namespaces**, with visibility of all consumers of the database; do not use a sandbox, container, or namespace-local `/proc` against a host database.
   The supported environment has PID 1 named `systemd` or `init`, one complete proc mount, and no proc submounts or aliases; other setups are conservatively refused, even if an operator considers them safe.
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
   A refusal reports an operational stage and an audited reason, never raw exceptions or private data; follow the diagnostics below.

### Diagnosing a refusal safely

The CLI distinguishes path validation, the initial offline scan, source fingerprint/backup, backup rehearsal, the final offline scan, and the source repair transaction.
A refusal in the **initial offline scan (SQLite not opened)** means no source SQLite connection, backup, rehearsal, or repair was attempted.
A later failure can leave a private backup; retain it even when no success was reported.
Diagnostics include only authored checks, numeric counts, kernel PID/fd identifiers, and symbolic errno values; they never include fd targets, arbitrary schema names, SQL, cell contents, raw OS/SQLite exceptions, or failing filesystem paths.
Use PID identifiers only to investigate ownership manually; do not kill an unidentified process or assume the PID has not been reused.

| Diagnostic | Action |
|---|---|
| `Ambiguous proc mounts (count=N)` | The environment exposes zero or multiple proc filesystem mounts. Move the maintenance operation to the genuine host environment with one complete `/proc`; do **not** unmount restrictions or change the guard to force a pass. |
| Restricted proc mount, proc submounts, unsupported PID 1, missing/nested namespace evidence | Establish genuine host namespace provenance independently; sandbox/container views are unsuitable. Passing checks alone never proves host-wide visibility. |
| Incomplete proc inspection, `EACCES` / `EPERM` | Arrange authorized host-wide fd inspection permissions. Elevated access alone does not fix namespace restrictions. |
| Incomplete proc inspection, `ENOENT` | A process/fd or visibility file may have vanished. Retry only with all consumers still stopped; do not skip missing entries or disable fail-closed checks. |
| Database or WAL/SHM open at PID | Identify and manually shut down the consumer, including its restart mechanism; retry the entire dry-run. |
| Path validation with `ENOENT` / `EACCES` | Confirm the explicit DB path and authorized access, without creating a replacement database. |
| Unexpected inventory/schema/ledger/count | Stop. This tool accepts one historical fingerprint, not arbitrary or already repaired stores. Obtain a new read-only inspection and review; do not relax the count/schema checks. |
| SQLite operation failed, backup/rehearsal/transaction failure | Keep any backup, check offline access, integrity and storage capacity through a separately reviewed offline procedure. Raw exceptions are intentionally suppressed. |

For the reported real-store refusal, a metadata-only diagnosis on 2026-11-17 found the file present but **11 proc filesystem mounts** in the agent execution environment (two complete-root mounts at `/proc` and nine proc submounts).
The first failing check was therefore `Ambiguous proc mounts`, before any SQLite open or fingerprint check.
This is an environment-specific observation, not evidence that the database is valid, invalid, offline, or repairable on the host.
No real database was opened or repaired during that diagnosis, and no schema-precondition defect was established; the strict mount prerequisite remains intact.
The operator must rerun the dry-run in a suitable host maintenance window to learn whether any further precondition fails.

Dry-run opens SQLite read-only and performs no repair or backup.
Normal SQLite WAL readers can interact with shared-memory bookkeeping; this is not a promise of byte-for-byte filesystem immutability.
The fd scan covers DB/WAL/SHM paths, deleted-open path targets, and existing inode aliases (hardlinks).
Unreadable, missing-during-inspection, or otherwise uninspectable fds/process directories fail closed.
The guard reads `self/mountinfo`, requires exactly one proc filesystem mounted at `/proc` with filesystem root `/`, rejects restrictive `hidepid`/`subset` options, and rejects every submount beneath `/proc` (including non-proc overlays).
An unrestricted-looking entry never cancels out a restricted entry elsewhere in the mount table.
It also requires a supported PID 1 name, single-valued `NSpid` evidence for self and PID 1, and matching self/PID-1 PID namespace links; missing evidence or detectable nesting is refused before fd inspection.
A racing process exit may therefore require retrying the scan.
**These checks do not authenticate host visibility.** A container can run `systemd`/`init` as PID 1, and a proc filesystem mounted inside a nested PID namespace can report only one `NSpid` value with matching namespace links.
Names and namespace-local metadata cannot prove this is the initial host namespace; passing the guard means only that the supported checks found no restriction or open consumer in the visible view, not that the database is globally offline.
The operator must establish genuine host provenance independently and keep all consumers stopped throughout; `/proc` cannot prevent a future opener, and SQLite locks do not exclude all readers.
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
