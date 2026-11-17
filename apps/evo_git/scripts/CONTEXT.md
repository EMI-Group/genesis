# Core Development Scripts

## Intent
This node contains standalone development-only operational tools, not runtime migration code or release hooks.

## API Surface
`repair_inspected_store.py --db PATH` is a Python 3.9+ one-time offline SQLite fingerprint validator with default dry-run behavior.
Adding `--apply` requires a verified SQLite backup, successful rehearsal, and a second complete Linux `/proc` fd scan before transactional physical repair.
`README.md` documents the exact accepted 1037-task/10539-archive/10-project ledger-versions-1-through-9 fingerprint, operator maintenance procedure, privacy constraints, and recovery limitations.
`test_repair_inspected_store.py` supplies synthetic unittest fixtures and runs via `python3 -m unittest discover -s apps/evo_git/scripts -p 'test_*.py'` from the repository root.

## Constraints
Never discover, inspect, or apply against a real database as part of development tests.
Never stop processes or bypass incomplete offline inspection; the operator owns the maintenance window and full host namespace visibility.
Keep ledger, projects, and every original task/archive cell untouched, add only nullable no-default task columns and the canonical VCT mount table, and import every project without capping or dropping.
Reject interrupted preservation remnants and unexpected fingerprints rather than generalizing this repair into a migration framework.
Never print private database payloads or raw SQLite errors.
All scripts and tests use Python's standard library only and are not called by application startup.

## Routing Table
There are no child directories.
