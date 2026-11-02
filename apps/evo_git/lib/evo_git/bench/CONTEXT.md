# Bench — Self-Contained I/O Benchmark

## Intent
A measurement-only benchmark of filesystem and git I/O over a throw-away synthetic repository that runs WITHOUT booting the Genesis application (plain function calls; no GenServer start, no Store/TaskRegistry access, no config-cache assumption).
Every run seeds `<dir>/genesis-bench-<os_pid>-<unique>/repo`, measures a fixed per-cycle phase list, and removes the whole root unless `keep: true`; it never touches an existing repository.

## API Surface
`EvoGit.Bench.defaults/0` returns the default option keyword list (`dir`, `iterations` 5, `warmup` 1, `files` 200, `writes` 20, `reads` 20, `file_size` 4096, `seed` 42, `label` hostname, `fsync` false, `keep` false).
`EvoGit.Bench.validate/1` merges over `defaults/0` and returns `{:ok, opts}` or a one-line `{:error, message}` naming the offending option; unknown keys are allowed and ignored.
`EvoGit.Bench.run/1` returns `{:ok, result_map}` or `{:error, {phase, detail}}` — `:validation` for bad options, `:setup` for seeding failures, otherwise the failing counted phase name — and prints nothing.
The result map carries `label`, `dir` (the bench root), `kept`, `settings`, `system`, `setup` (`us`/`files`/`bytes`, excluded from cycle stats), `phases`, `cycle`, `overall` (`cycles`/`wall_us`/`phase_us`/`cycles_per_sec`) and `throughput` (`files_written`/`bytes_written`/`write_mib_per_sec`/`files_read`/`bytes_read`/`read_mib_per_sec`).
The eight measured phases are `worktree_add`, `file_read`, `file_write`, `git_status`, `git_add`, `git_commit`, `worktree_remove` and `worktree_prune`; each phase entry is `EvoGit.Bench.Stats.summarize/1` plus the raw `samples_us` and a `share` of total counted time.
`cycle` is the summary of per-cycle totals (sum of that cycle's eight phase samples) including `samples_us` but no `share`; `overall.phase_us` is the sum of those per-cycle totals, while `overall.wall_us` is the REAL elapsed time measured with `:timer.tc/1` around the counted cycles only (warmup excluded).
`overall.cycles_per_sec` is computed from the real elapsed time, and every phase `share` stays a fraction of `overall.phase_us` so the shares still sum to ~1.0.
`EvoGit.Bench.picker/1` (`@doc false`) builds the cycling pick closure over a pre-shuffled, non-empty seed-file list.
`EvoGit.Bench.Stats` is pure: `summarize/1`, `percentile/2` (nearest-rank), `ops_per_sec/2`, `duration_ms/1` and `format_duration_us/1`; empty inputs yield zeros and never raise.
`EvoGit.Bench.SystemInfo.collect/1` gathers best-effort `os`, `arch`, `cpus`, `elixir`, `otp`, `hostname`, `git_version` and the `df -T`-derived `fs_type`/`fs_device`/`mountpoint` (all `nil` when a probe is unavailable, which covers Windows); `parse_df/1` (`@doc false`) is the pure row parser.
`EvoGit.Bench.Report.to_map/1`, `render_json/1` and `render_text/1` are PURE presentation — a ten-key JSON-safe projection, a pretty `Jason` encoding and the aligned ~30-line human report; no I/O and no printing (the Mix task owns stdout).

## Report Contract
`to_map/1` keeps exactly `label`, `dir`, `kept`, `settings`, `system`, `setup`, `phases`, `cycle`, `overall` and `throughput`, sanitizing every value (atom → string, struct → plain map, tuple → list) so `Jason` can encode it.
`render_json/1` is a pretty `Jason.encode!` of `to_map/1`.
`render_text/1` lists the eight phases in canonical order with human labels, milliseconds via `Stats.duration_ms/1`, `share` as a percentage, and a `mean / median` cycle-total row.
The `Overall` line reports the real wall time, the derived cycles/s and the summed phase time in parentheses (`… wall → N cycles/s (phase time …)`).
A `tmpfs`/`ramfs`/`none` `system.fs_type` appends a `Warning` line right after `Directory`; an unknown or real filesystem prints none.
Both renderers are total over synthetic maps: a missing or unexpected phase entry renders zeros and an unknown phase name degrades to a humanized key.

## Constraints
No application boot: plain function calls only, no GenServer start, no Store/TaskRegistry access and no dependency on the config cache being primed.
No new dependencies — Jason is already available for rendering the result map.
All git operations go through `EvoGit.Adapters.Git`; the only raw spawn is git `--version` in `SystemInfo` via `EvoGit.Executable.resolve("git")`.
Worktree teardown mirrors `WorktreeManager.destroy_worktree/3`: `WorktreeRetry.rm_rf_retry` the directory, then `Git.prune_worktrees`, then `Worktrees.delete_branch_tolerant`.
A failed git call in a counted phase returns `{:error, {phase, detail}}` for the whole run and never raises; cleanup-phase failures (`worktree_remove`, `worktree_prune`) are best-effort and logged at `:debug`, so the run still reports.
The bench root is always removed via `try/after` unless `keep: true`, including on error paths; a genuinely fatal raise may propagate but the root is still removed.
Seeding runs before `:rand.seed(:exsss, {seed, seed + 1, seed + 2})`; the single seeded stream covers only the measurement section, and warmup cycles run the identical cycle and are discarded.
`fsync: true` writes go through `:file.open([:write, :raw, :binary])` + `:file.write` + `:file.sync` + `:file.close` — only file CONTENTS are synced.
`--dir` decides filesystem locality, so measurements are comparable only on the same mount; a tmpfs `dir` reports memory throughput, not disk throughput.

## Known Limitations
Synthetic repository only — no real project file mix, history depth or large object set.
No cold-cache drop: repeated iterations measure the warm page cache, not first-touch disk reads.
No CoW-worktree measurement — worktrees are plain `git worktree add` checkouts, never the copy-on-write path.
`fsync: true` does not sync the containing directory entry or git's own loose objects.
`git_status`/`git_add`/`git_commit` include git's process startup and config reads, not just raw I/O.

No child directories.
