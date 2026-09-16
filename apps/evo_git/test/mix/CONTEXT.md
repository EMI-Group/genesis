# `mix/` — Mix-task Test Suites

## Intent
Tests for the release-time Mix tasks in `apps/evo_git/lib/mix/tasks/`.

## Routing Table
- `./tasks/` → `Mix.Tasks.Changelog` + `Mix.Tasks.Bump.Version` suites (both `async: true`) → `./tasks/CONTEXT.md`
