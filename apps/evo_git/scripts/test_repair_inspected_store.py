"""Synthetic fixtures only: never discovers or opens a user's database."""
import contextlib
import io
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import repair_inspected_store as repair


def ddl(table, specs):
    parts = []
    keys = []
    for name, kind, required, default, pk in specs:
        parts.append(repair.quote(name) + " " + kind + (" NOT NULL" if required else "") +
                     (" DEFAULT " + default if default else ""))
        if pk:
            keys.append((pk, name))
    if keys:
        parts.append("PRIMARY KEY (" + ",".join(repair.quote(n) for _, n in sorted(keys)) + ")")
    return "CREATE TABLE " + table + " (" + ",".join(parts) + ")"


def fixture(path):
    db = sqlite3.connect(path, isolation_level=None)
    db.execute(ddl("tasks", repair.task_specs()))
    db.execute(ddl("task_agent_archives", repair.archive_specs()))
    db.execute("CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at TEXT)")
    db.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, inserted_at TEXT)")
    db.execute("CREATE INDEX task_agent_archives_task_depth_idx "
               "ON task_agent_archives(task_id,depth,agent_id)")
    db.execute("BEGIN")
    db.executemany("INSERT INTO tasks(id,status,result,opts,error) VALUES (?,?,?,?,?)",
                   [(str(i), "completed", ' {"private": "payload"} ', bytes([i % 256]), "")
                    for i in range(1037)])
    db.executemany("INSERT INTO task_agent_archives(task_id,agent_id,result) VALUES (?,?,?)",
                   [(str(i % 1037), i, "opaque\x00result " + str(i)) for i in range(10539)])
    db.executemany("INSERT INTO schema_migrations VALUES (?,?)",
                   [(v, "unchanged timestamp") for v in repair.VERSIONS])
    rows = [('/a/same', '  Original name  ', '2026-03'),
            ('/b/same', None, '2026-02'), ('/c/same-2', '', '2026-01'),
            ('C:\\work\\same\\', 'Windows', None),
            ('/x/\x01 \x7f', '\t', None), ('/x/.', None, None),
            ('/x/..', None, None), ('/z/ project ', None, None),
            ('/trailing/demo///', None, '  timestamp  '),
            ('\\\\server\\share\\other', 'UNC', None)]
    db.executemany("INSERT INTO projects VALUES (?,?,?)", rows)
    db.execute("COMMIT")
    return db


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "synthetic.sqlite"
        self.db = fixture(self.path)
        self.addCleanup(self.db.close)

    def test_fingerprint_and_exact_transaction_preservation(self):
        mounts = repair.fingerprint(self.db)
        before = repair.snapshot(self.db)
        repair.repair(self.db, before, mounts)
        repair.verify_original(self.db, before)
        self.assertEqual(len(repair.columns(self.db, "tasks")), 21)
        self.assertEqual(self.db.execute("SELECT count(*) FROM vct_mounts").fetchone(), (10,))
        self.assertEqual(self.db.execute("SELECT max(version) FROM schema_migrations").fetchone(),
                         (20260815000009,))
        with self.assertRaises(repair.Refusal):
            repair.fingerprint(self.db)  # one-time, not an idempotent migrator

    def test_collision_order_and_verbatim_values(self):
        mounts = repair.project_import(self.db)
        by_path = {r[1]: r for r in mounts}
        self.assertEqual(by_path['/a/same'][0], 'vct:///projects/same')
        self.assertEqual(by_path['/b/same'][0], 'vct:///projects/same-2')
        self.assertEqual(by_path['/c/same-2'][0], 'vct:///projects/same-2-2')
        self.assertEqual(by_path['/a/same'][2], '  Original name  ')
        self.assertEqual(by_path['/trailing/demo///'][2:], ('demo', 'git', '  timestamp  '))
        self.assertEqual(by_path['C:\\work\\same\\'][0], 'vct:///projects/same-3')
        self.assertEqual(len({r[0] for r in mounts}), 10)
        for path in ('/x/.', '/x/..', '/x/\x01 \x7f'):
            self.assertTrue(by_path[path][0].startswith('vct:///projects/project'))

    def test_import_has_no_cap_or_skip(self):
        self.db.executemany("INSERT INTO projects VALUES (?,NULL,NULL)",
                            [('/many/' + str(i),) for i in range(150)])
        self.assertEqual(len(repair.project_import(self.db)), 160)

    def test_precondition_refusals(self):
        mutations = ["DELETE FROM tasks WHERE id='0'",
                     "DELETE FROM task_agent_archives WHERE agent_id=0",
                     "DELETE FROM projects WHERE path='/a/same'",
                     "UPDATE schema_migrations SET version=20260815000010 WHERE version=20260815000009",
                     "ALTER TABLE tasks ADD COLUMN session_mode TEXT",
                     "CREATE TABLE vct_mounts (point TEXT)",
                     "CREATE TABLE __genesis_historical_sources (stage TEXT)",
                     "CREATE TABLE __genesis_preserved_projects (path TEXT)",
                     "ALTER TABLE tasks ADD COLUMN __genesis_preserved_archive_metadata TEXT",
                     "CREATE TRIGGER unexpected AFTER INSERT ON tasks BEGIN SELECT 1; END",
                     "UPDATE projects SET path='relative' WHERE path='/a/same'",
                     "ALTER TABLE task_agent_archives ADD COLUMN unexpected TEXT"]
        for sql in mutations:
            with self.subTest(sql=sql):
                self.db.execute("SAVEPOINT fixture_change")
                self.db.execute(sql)
                with self.assertRaises(repair.Refusal):
                    repair.fingerprint(self.db)
                self.db.execute("ROLLBACK TO fixture_change")
                self.db.execute("RELEASE fixture_change")

    def test_failure_rolls_back_ddl_and_cells(self):
        before = repair.snapshot(self.db)
        mounts = repair.fingerprint(self.db)
        real_verify = repair.verify_original

        def corrupt_then_verify(db, original, schema=False):
            if not schema:
                db.execute("UPDATE task_agent_archives SET result='changed' WHERE agent_id=1")
            real_verify(db, original, schema)

        with patch.object(repair, 'verify_original', side_effect=corrupt_then_verify):
            with self.assertRaises(repair.Refusal):
                repair.repair(self.db, before, mounts)
        self.assertEqual(repair.snapshot(self.db), before)

    def test_backup_includes_uncheckpointed_wal_and_remains_original(self):
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA wal_autocheckpoint=0")
        self.db.execute("UPDATE tasks SET result='WAL-only value' WHERE id='0'")
        self.assertGreater(Path(str(self.path) + '-wal').stat().st_size, 0)
        before = repair.snapshot(self.db)
        backup_path = self.path.parent / 'backup.sqlite'
        repair.backup_to(self.db, backup_path, before)
        with contextlib.closing(repair.connect(backup_path, writable=True)) as backup:
            self.assertEqual(backup.execute("SELECT result FROM tasks WHERE id='0'").fetchone(),
                             ('WAL-only value',))
            repair.repair(backup, before, repair.fingerprint(backup))
        repair.verify_original(self.db, before, schema=True)
        self.assertEqual(os.stat(backup_path).st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            repair.backup_to(self.db, backup_path, before)

    def test_dry_run_and_apply_orchestration(self):
        self.db.close()
        with patch.object(repair, 'offline_scan') as scan:
            self.assertIn('Dry-run', repair.run(self.path))
            self.assertEqual(scan.call_count, 1)
            self.assertEqual(list(self.path.parent.glob('store-repair-backup-*')), [])
            self.assertIn('committed', repair.run(self.path, apply=True))
            self.assertEqual(scan.call_count, 3)
        backup = next(self.path.parent.glob('store-repair-backup-*/original.sqlite'))
        with contextlib.closing(repair.connect(backup)) as original:
            repair.fingerprint(original)
        with contextlib.closing(repair.connect(self.path)) as live:
            self.assertEqual(len(repair.columns(live, 'tasks')), 21)

    def test_rehearsal_or_recheck_failure_never_applies(self):
        before = repair.snapshot(self.db)
        self.db.close()
        for failure in ('backup', 'rehearsal', 'recheck'):
            with self.subTest(failure=failure):
                with contextlib.ExitStack() as stack:
                    scan = stack.enter_context(patch.object(repair, 'offline_scan'))
                    if failure == 'recheck':
                        scan.side_effect = [None, repair.Refusal('offline recheck failed')]
                    else:
                        target = 'backup_to' if failure == 'backup' else 'repair'
                        stack.enter_context(patch.object(repair, target,
                                                        side_effect=repair.Refusal('injected')))
                    with self.assertRaises(repair.Refusal):
                        repair.run(self.path, apply=True)
                with contextlib.closing(repair.connect(self.path)) as db:
                    self.assertEqual(repair.snapshot(db), before)

    def test_cli_requires_explicit_db_and_suppresses_private_errors(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                repair.main([])
        error = io.StringIO()
        with patch.object(repair, 'run', side_effect=sqlite3.Error('PRIVATE payload')):
            with contextlib.redirect_stderr(error):
                self.assertEqual(repair.main(['--db', str(self.path)]), 1)
        self.assertNotIn('PRIVATE', error.getvalue())


class OfflineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.proc = self.root / 'proc'
        (self.proc / '123' / 'fd').mkdir(parents=True)
        (self.proc / 'mounts').write_text('proc ' + str(self.proc) + ' proc rw 0 0\n')
        self.db = self.root / 'synthetic.sqlite'
        self.db.write_bytes(b'fixture')

    def test_offline_clean_and_db_wal_shm_or_hardlink_refused(self):
        repair.offline_scan(self.db, self.proc)
        fd = self.proc / '123' / 'fd' / '3'
        for suffix in ('', '-wal', '-shm'):
            target = Path(str(self.db) + suffix)
            target.touch(exist_ok=True)
            fd.symlink_to(target)
            with self.assertRaises(repair.Refusal):
                repair.offline_scan(self.db, self.proc)
            fd.unlink()
        alias = self.root / 'alias'
        os.link(self.db, alias)
        fd.symlink_to(alias)
        with self.assertRaises(repair.Refusal):
            repair.offline_scan(self.db, self.proc)

    def test_incomplete_inspection_refuses(self):
        for target in ('readlink', 'scandir'):
            with patch.object(os, target, side_effect=PermissionError()):
                # Ensure readlink is reached.
                fd = self.proc / '123' / 'fd' / '3'
                if not fd.exists():
                    fd.symlink_to(self.proc / 'mounts')
                with self.assertRaises(repair.Refusal):
                    repair.offline_scan(self.db, self.proc)
        (self.proc / 'mounts').write_text('proc ' + str(self.proc) + ' proc rw,hidepid=2 0 0\n')
        with self.assertRaises(repair.Refusal):
            repair.offline_scan(self.db, self.proc)

    def test_vanished_or_unreadable_fd_refuses(self):
        (self.proc / '123' / 'fd' / '4').symlink_to(self.root / 'gone')
        with self.assertRaises(repair.Refusal):
            repair.offline_scan(self.db, self.proc)


if __name__ == '__main__':
    unittest.main()
