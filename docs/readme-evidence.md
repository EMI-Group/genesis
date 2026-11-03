# Maintaining README evidence

The README shows exactly three curated projects, one latest-record link, and the
complete archive link. New Evidence records do not add rows or images to the README.

## Curate the selection

Edit `docs/readme-evidence.json`. Each entry contains a record slug, a short
description of what emerged, and the exact `verification_results[].name` to show.
Keep descriptions to one short sentence and choose projects that demonstrate
different capabilities. Titles, links, dates and result values come from the
published website; do not copy numbers into the selection config.

The latest record is selected by its `date`, then its stable record ID for ties.
That date describes the record, not the website deployment. A metrics-only edit
does not make an older record the latest. Latest can also appear among the three
selected projects. All other records remain accessible through the archive.

## Refresh and review

```sh
python scripts/sync-readme-evidence.py --refresh
python scripts/sync-readme-evidence.py --check
python scripts/test-readme-evidence.py
```

Python 3.11+ is sufficient, with no packages to install. Refresh reads
`https://genesis.evox.group/evidence/evidence.json`, saves only the fields needed
for the README in `docs/readme-evidence.snapshot.json`, and replaces only the block
between `evidence:start` and `evidence:end`. The snapshot allows offline review
and reproducible checks. Running without `--refresh` regenerates from the snapshot;
`--check` only verifies and never writes files.

Review the three rows, the date on the latest link, and the linked result scopes.
The table heading says "Reported result" to match the website's source-reported
records. Full methods, limitations, artifacts and experimental detail live on the
linked Evidence pages and in `docs/experiments.md`.

Missing selections, renamed verification keys, duplicate records, malformed dates
or invalid website URLs fail before writing the README. Review such changes in
the website and update the selection deliberately; no silent fallback is used.

## Automatic update PRs

`.github/workflows/readme-evidence.yml` refreshes every Monday at 03:00 UTC
(11:00 Asia/Shanghai), or via **Actions → README evidence → Run workflow**.
When data changes it creates or updates one PR from the dedicated
`automation/readme-evidence` branch. It never merges the PR automatically.
No timestamp is added, so unchanged data produces no update.

The repository must allow GitHub Actions to create pull requests under
**Settings → Actions → General → Workflow permissions**. No personal access token
is needed. The workflow checks the generated block before opening a PR; PRs
created with `GITHUB_TOKEN` may not trigger additional workflows automatically.
Reviewers can run the offline command above locally. The automation branch is
reserved for generated updates; make manual edits on another branch.

When the website publishes a new case, run the workflow for an immediate refresh,
or let the next weekly run pick it up. To feature the new case, change one of the
three config entries in a normal reviewed PR.
