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
- `server/0` is `Process.get(:evogit_process_manager_server) || __MODULE__` read at CALL time, and every function takes `:server`, so a suite starts isolated named instances.
- Started unconditionally by `EvoGit.Application` AFTER `Phoenix.PubSub` and BEFORE `EvoGit.BackgroundJobs` (which registers its detached jobs here).
- Foreground executions carry a REAL OS identity on every backend path: `EvoGit.Sandbox.Helpers.run_task_with_partial/9` and `run_tracked_command/7` spawn the child through a directly owned port and attach its pid (`:posix`) as soon as `wait_for_os_pid/2` observes it, so the non-sandboxed Linux/bwrap/macOS paths, the macOS `sandbox-exec` path and the `None` Unix path are observable and controllable instead of pid-less; the systemd path attaches the transient unit instead.

## Known Issues

- The systemd control backend (`control/systemd.ex`: `systemctl --user show` / `kill` against the execution's unit) has NO automated test coverage, because exercising it would act on the real `evogit.slice` and could signal the host BEAM; it is validated by code review only, and the suite pins just `Handle` normalization of a legacy `%{kind: :unit, …}` map.
- Windows (`control/windows.ex`) supports kill only (`taskkill /PID <pid> /T /F`): `pause/2`, `resume/2` and every `signal/2` answer `{:error, :unsupported}`, because Windows has no portable POSIX-signal equivalent and suspending a process would need `NtSuspendProcess`/`DebugActiveProcess` (out of scope: OS probes via `System.cmd` only, no new dependencies); memory comes from localized `tasklist` CSV and CPU is best-effort via PowerShell `(Get-Process -Id <pid>).CPU`, so an unparseable answer yields `nil` fields.
- An execution whose handle exposes no OS identity cannot be probed or signalled by pid: `Control.Posix` and `Control.Windows` answer `{:error, :no_pid}` (so `sample/2` returns that error and `sample_all/1` omits the execution) while the record itself is still tracked, listed and retained; `:systemd_unit` is the exception, because control addresses the UNIT and needs no pid, and its `stats/1` reports cgroup CPU/memory with `pids: []`.
- `stats` are best-effort point-in-time samples read from `/proc`, one `ps` table, `tasklist` or `systemctl show` at the call-time-configurable sampling interval, not exact accounting; on a backend that reports cumulative CPU only (Linux `/proc`, Windows PowerShell) the value the backend returns carries `cpu_percent: nil` — the sampling TIMER derives it from the delta against the previous sample of the same tree, so the FIRST sample of an execution has no percentage and an on-demand `sample/2` / `sample_all/1` read never derives one (macOS `ps` supplies `%CPU` per sample and needs no delta).
- Retention deletes terminal records outright once the retention window (Constraints) passes, so a pruned id answers `{:error, :not_found}` from `get/2` and is absent from `list/1` and `sample_all/1`: `kill/2` marks a record `:killed` even when the OS call FAILED, so a still-running process can age out of the registry and become unobservable and uncontrollable through the manager. `:unknown` is declared in `Execution.status` for that degraded case, but NO current code path produces it (only `:starting | :running | :paused | :completed | :failed | :killed` are ever assigned).

## Routing Table

No child directories — all modules live directly in this directory.
Cross-node contracts: `../agent/` and `../agent_scheduler/` (later rounds register tool calls and background jobs), `../sandbox/` (the legacy `%{kind: :unit | :port}` handle shapes normalized by `Handle.normalize/1`).
