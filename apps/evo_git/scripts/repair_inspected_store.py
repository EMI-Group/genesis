#!/usr/bin/env python3
"""Development-only, one-time physical repair of ONE inspected store fingerprint."""

import argparse
from contextlib import closing
import os
from pathlib import Path
import pickle
import re
import sqlite3
import sys
import tempfile


class Refusal(RuntimeError):
    """A safety precondition or preservation check failed (no payload in message)."""


VERSIONS = list(range(20260815000001, 20260815000010))
COUNTS = {"tasks": 1037, "task_agent_archives": 10539, "projects": 10,
          "schema_migrations": 9}
TASK_NAMES = ("id type status opts started_at finished_at logs result review_status usage "
              "agent_count base_sha commit_sha lease_expires_at model_id project_path "
              "branch_name error updated_at").split()
ARCHIVE_NAMES = ("task_id agent_id parent_id depth agent_type context_node_path objective result "
                 "base_commit final_commit branch_name archive_ref_start archive_ref_final "
                 "repo_id repo_root repo_path usage llm_settings agent_settings foreign_repos "
                 "compression_count started_at completed_at").split()
VCT_DDL = """CREATE TABLE vct_mounts (
    point TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL, kind TEXT NOT NULL, last_opened_at TEXT)"""


def require(condition, message):
    if not condition:
        raise Refusal(message)


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def connect(path, writable=False):
    # mode=rw never creates a missing source; never use immutable with a WAL.
    uri = Path(path).resolve().as_uri() + ("?mode=rw" if writable else "?mode=ro")
    db = sqlite3.connect(uri, uri=True, timeout=0, isolation_level=None)
    db.execute("PRAGMA trusted_schema=OFF")
    if not writable:
        db.execute("PRAGMA query_only=ON")
    return db


def columns(db, table):
    return [tuple(r[1:]) for r in db.execute("PRAGMA table_info(" + quote(table) + ")")]


def task_specs():
    return [(n, "INTEGER" if n in ("agent_count", "lease_expires_at") else "TEXT",
             int(n == "status"), None, int(n == "id")) for n in TASK_NAMES]


def archive_specs():
    integers = {"agent_id", "parent_id", "depth", "compression_count"}
    required = {"task_id", "agent_id", "depth", "compression_count"}
    return [(n, "INTEGER" if n in integers else "TEXT", int(n in required),
             "0" if n in ("depth", "compression_count") else None,
             {"task_id": 1, "agent_id": 2}.get(n, 0)) for n in ARCHIVE_NAMES]


def integrity(db):
    require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)],
            "Integrity check failed")


def fingerprint(db):
    objects = db.execute("SELECT type, name FROM sqlite_master").fetchall()
    require(not any("__genesis_" in n for _, n in objects),
            "Interrupted preservation objects present")
    tables = {n for t, n in objects if t == "table" and not n.startswith("sqlite_")}
    require(tables == set(COUNTS), "Unexpected table inventory (or already repaired)")
    require(not any(t in ("trigger", "view") for t, _ in objects),
            "Unexpected triggers or views")
    actual_tasks = columns(db, "tasks")
    require(not any("__genesis_" in c[0] for c in actual_tasks),
            "Interrupted preservation column present")
    require(sorted(actual_tasks) == sorted(task_specs()), "Unexpected tasks schema")
    require(columns(db, "task_agent_archives") == archive_specs(),
            "Unexpected archive schema")
    require(columns(db, "projects") == [("path", "TEXT", 0, None, 1),
            ("name", "TEXT", 0, None, 0), ("last_opened_at", "TEXT", 0, None, 0)],
            "Unexpected projects schema")
    ledger = columns(db, "schema_migrations")
    require(ledger in [[("version", kind, required, None, 1),
                       ("inserted_at", "TEXT", 0, None, 0)]
                      for kind in ("BIGINT", "INTEGER") for required in (0, 1)],
            "Unexpected migration ledger schema")
    require([r[0] for r in db.execute("SELECT version FROM schema_migrations ORDER BY version")]
            == VERSIONS, "Unexpected migration ledger versions")
    for table, count in COUNTS.items():
        require(db.execute("SELECT count(*) FROM " + quote(table)).fetchone()[0] == count,
                "Unexpected row count: " + table)
    integrity(db)
    return project_import(db)


def project_import(db):
    used, result = set(), []
    rows = db.execute("SELECT path,name,last_opened_at FROM projects "
                      "ORDER BY (last_opened_at IS NULL), last_opened_at DESC, path ASC")
    for path, name, timestamp in rows:
        require(isinstance(path, str) and bool(re.match(r"^(?:/|\\\\|[A-Za-z]:[/\\])", path))
                and "\x00" not in path, "Project path is not an absolute usable path")
        require(name is None or isinstance(name, str), "Unexpected project name type")
        require(timestamp is None or isinstance(timestamp, str), "Unexpected timestamp type")
        base = path.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1]
        segment = re.sub(r"[\x00-\x1f\x7f]", "", base).strip()
        if segment in ("", ".", ".."):
            segment = "project"
        root = "vct:///projects/" + segment
        point, suffix = root, 2
        while point in used:
            point = root + "-" + str(suffix)
            suffix += 1
        used.add(point)
        result.append((point, path, name if name and name.strip() else base, "git", timestamp))
    require(len({r[1] for r in result}) == len(result), "Duplicate project paths")
    return result


def snapshot(db, specs=None):
    # Exact typed cell preservation, not SQL equality (which coerces types).
    specs = specs or {t: [c[0] for c in columns(db, t)] for t in COUNTS}
    cells = {}
    for table, names in specs.items():
        sql = "SELECT " + ",".join(map(quote, names)) + " FROM " + quote(table) + " ORDER BY rowid"
        cells[table] = pickle.dumps(db.execute(sql).fetchall(), protocol=4)
    schema = db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name").fetchall()
    return specs, cells, schema


def verify_original(db, before, schema=False):
    after = snapshot(db, before[0])
    require(after[1] == before[1], "Original cells or row counts changed")
    if schema:
        require(after[2] == before[2], "Source schema changed since backup")


def repair(db, before, mounts):
    db.execute("BEGIN IMMEDIATE")
    try:
        fingerprint(db)
        verify_original(db, before, schema=True)
        db.execute("ALTER TABLE tasks ADD COLUMN session_mode TEXT")
        db.execute("ALTER TABLE tasks ADD COLUMN pause_kind TEXT")
        db.execute(VCT_DDL)
        db.executemany("INSERT INTO vct_mounts VALUES (?,?,?,?,?)", mounts)
        verify_original(db, before)
        require(columns(db, "tasks")[-2:] == [
            ("session_mode", "TEXT", 0, None, 0), ("pause_kind", "TEXT", 0, None, 0)],
            "Added columns have unexpected schema")
        require(db.execute("SELECT count(*) FROM tasks WHERE session_mode IS NOT NULL "
                           "OR pause_kind IS NOT NULL").fetchone() == (0,), "Unexpected backfill")
        require(db.execute("SELECT * FROM vct_mounts ORDER BY point").fetchall() == sorted(mounts),
                "Mount import verification failed")
        # All pre-existing indexes/table DDL except the intended tasks extension survive.
        after_schema = snapshot(db, before[0])[2]
        for obj in before[2]:
            if obj[0:2] != ("table", "tasks"):
                require(obj in after_schema, "Original schema object changed")
        integrity(db)
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise


def offline_scan(path, proc=Path("/proc")):
    """Inspect every visible process, including our own; any uncertainty refuses."""
    require(sys.platform.startswith("linux"), "Offline verification requires Linux /proc")
    targets = {str(path) + suffix for suffix in ("", "-wal", "-shm")}
    identities = set()
    try:
        # hidepid can silently omit other users' processes, so reject such mounts.
        mounts = (proc / "mounts").read_text()
        require(any(parts[1:3] == [str(proc), "proc"] and
                    not any(opt.startswith("hidepid=") and opt != "hidepid=0"
                            for opt in parts[3].split(","))
                    for parts in (line.split() for line in mounts.splitlines()) if len(parts) >= 4),
                "Cannot establish complete /proc visibility")
        for target in targets:
            try:
                st = os.stat(target)
                identities.add((st.st_dev, st.st_ino))
            except FileNotFoundError:
                pass  # WAL/SHM need not exist.
        pids = [p for p in proc.iterdir() if p.name.isdecimal()]
        require(bool(pids), "No processes visible in /proc")
        for pid in pids:
            # Keep the enumeration fd alive: our own /proc entry includes it.
            with os.scandir(pid / "fd") as entries:
                for fd in entries:
                    link = os.readlink(fd.path)
                    st = os.stat(fd.path)
                    require(link.removesuffix(" (deleted)") not in targets and
                            (st.st_dev, st.st_ino) not in identities,
                            "Database or WAL/SHM is open; shut down its owner manually")
    except OSError:
        raise Refusal("Incomplete /proc fd inspection; no repair permitted") from None


def backup_to(source, destination, before):
    # Exclusive creation and private permissions; keep even failed backups for inspection.
    fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    with closing(sqlite3.connect(destination, isolation_level=None)) as backup:
        source.backup(backup)
        integrity(backup)
        verify_original(backup, before, schema=True)
        fingerprint(backup)
    fd = os.open(destination, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    fd = os.open(Path(destination).parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def run(path, apply=False):
    path = Path(path).expanduser().resolve(strict=True)
    require(path.is_file(), "Database must be an existing regular file")
    offline_scan(path)
    with closing(connect(path)) as source:
        mounts = fingerprint(source)
        before = snapshot(source)
        if not apply:
            return "Dry-run passed: 1037 tasks, 10539 archives, 10 projects; no repair written."
        # Backup stored beside DB, unique private name, never overwrite a prior backup.
        backup_dir = Path(tempfile.mkdtemp(prefix="store-repair-backup-", dir=path.parent))
        backup = backup_dir / "original.sqlite"
        backup_to(source, backup, before)
    with tempfile.TemporaryDirectory(prefix="store-repair-rehearsal-", dir=path.parent) as temp:
        rehearsal = Path(temp) / "rehearsal.sqlite"
        with closing(connect(backup)) as original:
            backup_to(original, rehearsal, before)
        with closing(connect(rehearsal, writable=True)) as trial:
            repair(trial, before, mounts)
    offline_scan(path)
    with closing(connect(path, writable=True)) as live:
        repair(live, before, mounts)
    return "Repair committed and verified; private backup retained in " + str(backup_dir)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="Explicit path to the offline inspected SQLite DB")
    parser.add_argument("--apply", action="store_true", help="Back up, rehearse, then apply (default: dry-run)")
    args = parser.parse_args(argv)
    try:
        print(run(args.db, args.apply))
    except (Refusal, OSError, sqlite3.Error):
        # Never print SQLite exceptions, SQL, paths or cell values from private stores.
        print("REFUSED: safety/precondition/verification failure; no successful repair. "
              "Keep any backup; consult the development runbook.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
