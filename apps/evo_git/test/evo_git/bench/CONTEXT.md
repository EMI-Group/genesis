# Bench Test Suite (`test/evo_git/bench/`)

## Intent
ExUnit coverage for the boot-free I/O benchmark (`EvoGit.Bench` + `EvoGit.Bench.Stats` / `EvoGit.Bench.Report` / `EvoGit.Bench.SystemInfo`), whose production detail lives in `apps/evo_git/lib/evo_git/bench/CONTEXT.md`.
Three suites: `stats_test.exs` and `report_test.exs` are pure (no git, no I/O), `bench_test.exs` is a real-git integration suite against a per-test unique temp dir.

## API Surface
| File | Module | Focus |
|---|---|---|
| `stats_test.exs` | `EvoGit.Bench.StatsTest` | `percentile/2` nearest rank + clamping, `summarize/1` odd/even median + empty input, `ops_per_sec/2` zero total, `duration_ms/1`, `format_duration_us/1` µs/ms/s arms |
| `report_test.exs` | `EvoGit.Bench.ReportTest` | `render_text/1` from a synthetic result map (all eight phase labels, overall + throughput lines, settings/notes lines, tmpfs warning on vs off, degenerate maps render), `render_json/1` round-trip with exactly ten top-level keys |
| `bench_test.exs` | `EvoGit.BenchTest` | `run/1` end-to-end with tiny settings (`iterations: 2, warmup: 0, files: 8, writes: 2, reads: 2, file_size: 64`): all eight phases `n == 2`, `cycle.total_us` == its sample sum, `setup` files/bytes, throughput totals, root removed unless `keep: true`, no leftover worktree/branch artifacts, `:validation` error, pure `picker/1` cycling |

## Constraints
All three modules are `async: true`: they mutate no BEAM-global state — no `Application.put_env`, no `System.put_env`, no `:persistent_term`, no app-booted singleton, and no shared PubSub topic.
Benchmark runs use a per-test unique dir under `System.tmp_dir!()` (`bench-test-<unique_integer>`) created by the test and removed in `on_exit`; `--dir` never points at an existing repository.
Never assert absolute timings — only structural and numeric invariants (counts, sizes, `cycle.total_us == Enum.sum(samples_us)`, `cycles_per_sec > 0`).
No `Process.sleep` and no polling: `EvoGit.Bench.run/1` is synchronous.
Do not soften assertions to buy speed; the suites finish in well under a second.

## Routing Table
- Production engine, result-map contract, phase list and report layout → `apps/evo_git/lib/evo_git/bench/CONTEXT.md`.
- `mix bench.io` argument-parser suite → `apps/evo_git/test/mix/tasks/CONTEXT.md`.
- Parent suite policy (async rules, cost profile) → `apps/evo_git/test/CONTEXT.md`.
