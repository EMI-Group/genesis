# ProcessManager — live OS-execution registry

## Intent

`EvoGit.ProcessManager` is THE single source of truth for the live OS executions an agent or task holds on this node.
It records ONE `Execution` per foreground tool call and per detached background job, keeps the normalized OS `Handle` that addresses it, samples real resource usage on a timer, and exposes operator control (pause / resume / signal / kill).
It records and observes; starting processes stays with `EvoGit.BackgroundJobs`, `EvoGit.Sandbox.*` and the tool-dispatch layer, which register into it.
The public facade (`EvoGit.ProcessManager`) is a FROZEN contract: later rounds wire BackgroundJobs/Sandbox/tool-dispatch onto it and phase 2's dashboard consumes it.

## API Surface

| Module | Role |
|---|---|
| `EvoGit.ProcessManager` | Public facade: `track/3`, `attach/3`, `finish/3`, `list/1`, `get/2`, `sample/2`, `sample_all/1`, `signal/3`, `pause/2`, `resume/2`, `kill/2`, `subscribe/0`, `unsubscribe/0`, `server/0`, `start_link/1`, `child_spec/1`, plus the extra `prune/1` retention entry point |
| `EvoGit.ProcessManager.Registry` | The GenServer: executions + handles maps, owner monitors, ONE sampling timer, `"proc-<n>"` counter, monotonic sample seq, retention |
| `EvoGit.ProcessManager.Execution` | FROZEN defstruct + `terminal?/1`, `live?/1`, `control_entry/1` |
| `EvoGit.ProcessManager.Handle` | Normalized OS handle (`:systemd_unit | :posix | :windows`) and `normalize/1` for legacy `%{kind: :unit | :port}` sandbox handles |
| `EvoGit.ProcessManager.Control` | Behaviour (`stats/1`, `signal/2`, `kill/1`, `alive?/1`) + dispatcher on `Handle.kind`, signal normalization, `kill_grace_ms/0` |
| `Control.Systemd` / `Control.Posix` / `Control.Windows` | Backend implementations (`systemctl --user`, `/proc` or one `ps` table, `tasklist`/`taskkill`) |
| `EvoGit.ProcessManager.Stats` | Pure parsers (`parse_proc_stat/1`, `parse_proc_status/1`, `parse_ps_output/1`, `parse_ps_time/1`, `parse_systemctl_show/1`) plus `empty/0`, `summarize/1`, `cpu_percent/4`, `changed?/2`, `sample_timeout_ms/0` |

## Constraints

- NO OS call ever runs inside the registry: `sample/2`, `sample_all/1`, `signal/3`, `pause/2`, `resume/2` and `kill/2` do the OS work in the CALLER; the sampling tick probes in a monitored throwaway worker and skips ticks while one is in flight.
- The `stats` field is ALWAYS the six-key map from `Stats.empty/0` (`cpu_time_ms`, `cpu_percent`, `memory_bytes`, `rss_bytes`, `pids`, `sampled_at`) — never `nil`, never a partial map.
- `pgid` lives on the `Handle`, not on `Execution` (the frozen `Execution` schema models identity, not OS addressing).
- PubSub topic `"processes"` with the emitting node LAST: `{:process_started, execution, node}`, `{:process_updated, id, changes, node}`, `{:process_exited, execution, node}`, `{:process_sample, node, seq, entries}`, `{:process_control, id, entry, node}`; lifecycle changes only, never a no-op.
- All handlers and all control callbacks are TOTAL: unknown id → `{:error, :not_found}` / `:ok`, failed probe → `{:error, reason}`, unrecognized handle → no-op.
- Owner lifetime is ONE `Process.monitor/1` per owner pid; the owner's death marks every non-terminal execution it owned `:failed` with `reason: :owner_died` and best-effort kills the handle in a throwaway process.
- Call-time app-env seams only (no TOML keys, so the suite stays async-safe): `:process_manager_sample_interval_ms` (3_000), `:process_stats_enabled` (true), `:process_finished_retention_ms` (300_000), `:process_stats_probe_timeout_ms` (2_000), `:process_kill_grace_ms` (1_500).
- Terminal records are retained for the retention window and capped at the newest 200; live records are never pruned.
- POSIX signals are delivered to the process GROUP only when the handle's `pgid` is known and differs from this BEAM's own group (a raw port child inherits it — an unguarded group signal would kill Genesis).
- Windows has no POSIX signals: `signal/2`, `pause/2` and `resume/2` answer `{:error, :unsupported}` there; stats memory comes from `tasklist` and CPU is best-effort via PowerShell.
- `server/0` is `Process.get(:evogit_process_manager_server) || __MODULE__` read at CALL time, and every function takes `:server`, so a suite starts isolated named instances.
- Started unconditionally by `EvoGit.Application` AFTER `Phoenix.PubSub` and BEFORE `EvoGit.BackgroundJobs` (which registers its detached jobs here).

## Routing Table

No child directories — all modules live directly in this directory.
Cross-node contracts: `../agent/` and `../agent_scheduler/` (later rounds register tool calls and background jobs), `../sandbox/` (the legacy `%{kind: :unit | :port}` handle shapes normalized by `Handle.normalize/1`).
