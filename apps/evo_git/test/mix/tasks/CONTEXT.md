# Mix-Task Test Suites (`test/mix/tasks/`)

## Intent
ExUnit suites for the release-time Mix tasks `mix changelog` (`Mix.Tasks.Changelog`) and `mix bump.version` (`Mix.Tasks.Bump.Version`).
Both tasks are interactive and run git/file operations; the suites exercise their full flows against real temp git repos.

## Files
| File | Module | Tests | async |
|---|---|---|---|
| `changelog_test.exs` | `Mix.Tasks.ChangelogTest` | 14 | `true` |
| `bump_version_test.exs` | `Mix.Tasks.Bump.VersionTest` | 5 | `true` |

## Why `async: true` (the seam)
Both suites flip to `async: true` because the production tasks resolve every process-/VM-global at CALL time from per-call `opts` (the merged testability seam in `lib/mix/tasks/{changelog,bump.version}.ex`), so the tests mutate no global state.
`root:` anchors every git invocation (`cd: root`) and every relative path resolution — no VM-wide `File.cd!/2`.
`shell:` is the `Mix.Shell` used for all `info`/`error`/`yes?` — no VM-global `Mix.shell/1` swap; assertions drain the `{:mix_shell, ...}` messages the injected shell posts to the test-process mailbox.
The three summarizer seams (`:changelog_summarizer`, `:changelog_pr_summarizer`, `:changelog_aggregator`) are passed per call — the `{:evo_git, ...}` application env is never mutated.
`Mix.Tasks.Bump.Version` forwards `root`, `shell`, and any summarizer keys from its own opts into its nested `Mix.Tasks.Changelog.run/1` call, so a bump test can inject the changelog seam too.

## Call shapes these suites use
```elixir
Changelog.run([@version, root: tmp_dir, shell: Mix.Shell.Process] ++ seam_opts)
Changelog.run(root: tmp_dir, shell: Mix.Shell.Process)              # missing-version usage-error path
Bump.Version.run([@version, root: tmp_dir, shell: Mix.Shell.Process])
Bump.Version.run([@version, root: tmp_dir, shell: Mix.Shell.Process, changelog_summarizer: fun])
```
Seam helpers (`with_summarizer/1`, `with_pr_summarizer/1`, `with_aggregator/1`, `install_stage_seams/0`) RETURN the keyword seam opts; they install nothing.
`base_opts/1` builds `[@new_version, root: tmp_dir, shell: Mix.Shell.Process]` reused across the changelog tests.
The `send(self(), {:mix_shell_input, :yes?, value})` pattern queues shell answers for `Mix.Shell.Process`; keep it.

## Constraints
No mocking libraries (no Mox/Meck) — real `git` on per-test temp repos only; the LLM stages are stubbed through the production summarizer seams.
Never assert tight wall-clock bounds; the `receive ... after 0` collectors are non-blocking mailbox drains.
Keep the exact test counts (14 changelog / 5 bump) and every assertion; the seam change is mechanical.
`mix format --check-formatted` and `mix compile --warnings-as-errors` must stay clean.
Do NOT edit `lib/` — the seam lives in production and is owned by the `lib/mix/tasks/` workstream.

## Routing Table
- Production tasks + the seam contract → `apps/evo_git/lib/mix/tasks/CONTEXT.md`.
- `Mix.Tasks.Migrate.Store` (a third mix task, tested elsewhere) → same seam is NOT applied there.
- Parent test-suite context → `apps/evo_git/test/CONTEXT.md`.
