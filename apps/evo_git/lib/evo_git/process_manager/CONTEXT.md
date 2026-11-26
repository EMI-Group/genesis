# ProcessManager — live OS-execution registry

## Intent

`EvoGit.ProcessManager` is THE single source of truth for the live OS executions an agent or task holds on this node.
It records ONE `Execution` per tool call (builtin or OS-backed) and per detached background job, keeps the normalized OS `Handle` that addresses an external one, samples real resource usage on a timer, and exposes operator control (pause / resume / signal / kill).
It records and observes; starting processes stays with `EvoGit.BackgroundJobs`, `EvoGit.Sandbox.*` and the tool-dispatch layer, which register into it.
The public facade (`EvoGit.ProcessManager`) is a FROZEN contract consumed by `EvoGit.BackgroundJobs`, `EvoGit.Sandbox.*`, `EvoGit.ToolRuntime` and the dashboard.
The registry is completely NODE-LOCAL and in-memory: records are never written to the task store, never archived with a task and never aggregated across nodes, and a remote caller reaches them only by RPC to the node that owns them.
Retention makes the roster a recent-actions list, not a full history: terminal records age out and are capped, live ones are never pruned, and a LIVE owner's terminal `:background_job` records are bounded per owner instead of by age (see Retention).

## Origin vs Backend (`Execution`)

`:runtime` is the call's ORIGIN, never what runs it: `:foreground` (the agent is blocked on the call) or `:background` (the call outlives the agent's turn, i.e. an `EvoGit.BackgroundJobs` job).
`:backend` is what runs it: `:builtin` (the call ran INSIDE the BEAM — `read`/`write`/`edit`/`rg`/`search_*`/`elixir_eval`/`job_output`, anything that is not the platform shell) or `:systemd | :bwrap | :sandbox_exec | :none` (an EXTERNAL OS process anchored by that sandbox backend, `:none` being external but unsandboxed).
A `:builtin` execution has NO OS process: `:os_pid` and `:unit` stay nil, `:stats` stays `Stats.empty/0`, and `sample/2`, `signal/3` (hence `pause/2` and `resume/2`) and `kill/2` answer `{:error, :no_os_process}` — `kill/2` never finishes such a record.
`Execution.builtin?/1`, `external?/1` and `sampleable?/1` are TOTAL derived predicates; `builtin?/1` is true only for `%Execution{backend: :builtin}` and false for anything else, `external?/1` is its negation, and `sampleable?/1` is `live?/1 and external?/1`.
Sampling keys on `Execution.sampleable?/1`, so a live builtin record never arms the sampling timer, is never probed by `sample_all/1` and is never listed by `Registry.live/1`.
`attach/3` never downgrades a `:builtin` backend to a handle-derived one.

## Terminal Facts

`:exit_code` is an integer `0..255` when an external execution's OS process actually exited, and nil for timeouts, kills, builtin calls and never-started calls.
`:reason` is the ONE terminal cause and stays nil while the execution is live: `:exited` (the process ended on its own — consult `:exit_code`), `:timeout`, `:invalid_arguments` (never started: unparseable/malformed tool arguments), `:owner_died`, `{:killed_by, actor}`, `{:crashed, detail}`, `:no_os_process` (a builtin call finished; nothing ran) or the additive `{:tool_error, reason}` (a tool-returned `{:error, reason}`, not a raise/exit).
`Execution.status_for_reason/1` is the uniform mapping: `:exited` and `:no_os_process` → `:completed`, `:timeout` and `{:killed_by, _}` → `:killed`, and `:invalid_arguments`, `{:crashed, _}`, `:owner_died`, `{:tool_error, _}` or any other term → `:failed`.
`:completed` also covers a NON-ZERO `:exit_code`: the tool call itself succeeded and the model receives a normal result (the dashboard colors the code).
`do_finish/4` is idempotent by contract: the sandbox layer settles a shell call with `:exited` plus its real `exit_code`, and the later tool-runtime finish (`:completed` / `:no_os_process`) is a no-op that never overwrites that exit code.

## Pending Kill vs an Observed Exit

`EvoGit.ProcessManager.kill/2` stops the OS process BEFORE it finishes the record, and the sandbox layer observes that same exit and settles the record itself.
The registry therefore holds a per-id kill INTENT (the requesting `:actor`) while the stop is in flight: `Registry.put_kill_intent/3` declares it, and `Registry.clear_kill_intent/2` drops it after an accepted or failed stop.
While an intent is pending, the FIRST non-killed terminal finish settles the record `:killed` with `reason: {:killed_by, actor}` and `exit_code: nil`, because the observed exit is the kill's consequence rather than a terminal fact of its own.
An incoming `:killed` finish and an `:owner_died` finish are never translated, and the intent is consumed by its ONE translation, so `do_finish/4` stays idempotent for every later finish.
An intent is dropped together with its record during retention, and a FAILED stop clears it so a later natural exit keeps its own terminal facts.

## Error Vocabulary

A control callback answers its OWN failure, so a caller never has to guess.
A backend that raises is contained by `Control.guarded/2` and tagged by the operation that failed: `{:error, {:probe_failed, detail}}` (`stats`), `{:error, {:kill_failed, detail}}` (`kill`), `{:error, {:signal_failed, detail}}` (`signal`) — an unusable/unknown handle is `{:error, :no_handle}` and `alive?/1` answers `false`.
`Control.kill_outcome/3` is the ONE kill verdict shared by the escalating backends: a gone handle is `:ok`, otherwise the first REAL backend failure wins (KILL, then TERM), and `{:error, :still_alive}` means only that both signals were delivered and the handle is still there — an EPERM kill, an unavailable `kill`/`systemctl` or `{:error, :no_pid}` is reported as itself.
`Control.signal/2` normalizes the signal exactly ONCE and backends receive the NAME as authoritative; a backend never re-validates it.
A registry request has THREE possible outcomes and they are never conflated: a dead/unregistered registry keeps each call site's documented degraded value (`get/2`/`lookup/2` → `{:error, :not_found}`, `list/1`/`live/1` → `[]`, `prune/1` → `{:ok, 0}`, `track/3` → `{:error, :process_manager_unavailable}`), a WEDGED registry (the call timed out) answers `{:error, :timeout}`, and one that crashed while answering answers `{:error, {:registry_exit, reason}}`, each with ONE `Logger.warning`.
`Registry.classify_exit/1` is that decision (pure, `@doc false`, unit-tested without waiting out a call); `list/1`, `live/1` and `sample_all/1` stay empty-shaped for both failure kinds because an empty roster IS the dashboard read's contract.
`Registry.record_stats/3` drops a non-map probe answer (`:ok`) rather than crashing the calling agent, an unknown `handle_call` answers `{:error, {:unknown_call, request}}` (never `:ok`), and `Registry.cast/2` is a bare `GenServer.cast/2` — it cannot fail, so it carries no guard.

## API Surface

| Module | Role |
|---|---|
| `EvoGit.ProcessManager` | Public facade: `track/3`, `attach/3`, `finish/3`, `list/1`, `get/2`, `sample/2`, `sample_all/1`, `signal/3`, `pause/2`, `resume/2`, `kill/2`, `subscribe/0`, `unsubscribe/0`, `server/0`, `start_link/1`, `child_spec/1`, plus the extra `prune/1` retention entry point |
| `EvoGit.ProcessManager.Registry` | The GenServer: executions + handles + kill-intent maps, owner monitors, ONE sampling timer, `"proc-<n>"` counter, monotonic sample seq, and the retention state surgery (`prune/1`, `max_terminal_records/0`, `finished_retention_ms/0`, `max_background_records_per_owner/0`) |
| `EvoGit.ProcessManager.Retention` | The PURE retention policy: `doomed_ids/2` (aged-out + global-capped + per-owner overflow, never a live record), `protected?/2`, `owner_alive?/1`, and the call-time seams `finished_retention_ms/0`, `max_terminal_records/0`, `background_max_per_owner/0` |
| `EvoGit.ProcessManager.Execution` | FROZEN defstruct + `terminal?/1`, `live?/1`, `builtin?/1`, `external?/1`, `sampleable?/1`, `status_for_reason/1`, `sort_key/1` (the ONE `{inserted_at, numeric id}` ordering), `control_entry/1` |
| `EvoGit.ProcessManager.Handle` | Normalized OS handle (`:systemd_unit | :posix | :windows`) and `normalize/1` for legacy `%{kind: :unit | :port}` sandbox handles |
| `EvoGit.ProcessManager.Control` | Behaviour (`stats/1`, `signal/2`, `kill/1`, `alive?/1`) + dispatcher on `Handle.kind`, the ONE signal normalization (backends receive the NAME), `kill_grace_ms/0`, the shared `kill_outcome/3` kill verdict and the `guarded/2` crash boundary |
| `Control.Systemd` / `Control.Posix` / `Control.Windows` | Backend implementations (`systemctl --user`, `/proc` or one `ps` table, `tasklist`/`taskkill`); Systemd and Posix decide an escalating kill with the shared `Control.kill_outcome/3` |
| `EvoGit.ProcessManager.Stats` | Pure parsers (`parse_proc_stat/1`, `parse_proc_status/1`, `parse_ps_output/1`, `parse_ps_time/1`, `parse_systemctl_show/1`, `from_systemd/1`) plus `empty/0`, `summarize/1`, `cpu_percent/4`, `changed?/2`, `sample_timeout_ms/0`; every parser is a 2-tuple (`{:ok, value}` / `{:error, :malformed}`), so a `{:ok, stats}` payload is always a map |

## Constraints

- NO OS call ever runs inside the registry: `sample/2`, `sample_all/1`, `signal/3`, `pause/2`, `resume/2` and `kill/2` do the OS work in the CALLER; the sampling tick probes in a monitored throwaway worker and skips ticks while one is in flight.
- `kill/2` on a `:builtin` execution answers `{:error, :no_os_process}` FIRST and never finishes the record; an accepted kill appends `%{action: :kill, reason: <human text>, actor: actor}` to `control_log` and finishes with `:killed`, `reason: {:killed_by, actor}` by default (overridable through the `:terminal_reason` option) and `exit_code: nil`, so a kill never fabricates an exit code and the human `:reason` text survives in `control_log` only; the operator outcome is authoritative over the sandbox layer's own observation of the exit it caused.
- `kill/2`'s `:actor` defaults to `:operator` and is never nil; the default terminal reason `{:killed_by, actor}` therefore follows a supplied actor.
- The `stats` field is ALWAYS the six-key map from `Stats.empty/0` (`cpu_time_ms`, `cpu_percent`, `memory_bytes`, `rss_bytes`, `pids`, `sampled_at`) — never `nil`, never a partial map.
- `pgid` lives on the `Handle`, not on `Execution` (the frozen `Execution` schema models identity, not OS addressing).
- PubSub topic `"processes"` with the emitting node LAST: `{:process_started, execution, node}`, `{:process_updated, id, changes, node}`, `{:process_exited, execution, node}`, `{:process_sample, node, seq, entries}`, `{:process_control, id, entry, node}`; lifecycle changes only, never a no-op.
- All handlers and all control callbacks are TOTAL: an unknown id answers `{:error, :not_found}` for the reads and `:ok` for the idempotent writes, a failed probe is `{:error, reason}` data, an unrecognized handle is a no-op, and only a WEDGED/crashed registry answers `{:error, :timeout}` / `{:error, {:registry_exit, reason}}` — never `:not_found`; nothing here raises for any registry state, and `EvoGit.ProcessManager`'s on-demand sample holds NO second rescue layer because `Control.stats/1` is already total.
- `kill/2`'s failure text is the backend's OWN reason (see Error Vocabulary), so an operator log distinguishes an EPERM/unavailable-signal failure from a process that survived both signals.
- Owner lifetime is ONE `Process.monitor/1` per owner pid; the owner's death marks every non-terminal execution it owned `:failed` with `reason: :owner_died` and best-effort kills the handle in a throwaway process.
- Call-time app-env seams only (no TOML keys, so the suite stays async-safe): `:process_manager_sample_interval_ms` (3_000), `:process_stats_enabled` (true), `:process_finished_retention_ms` (300_000), `:process_finished_max_records` (200), `:process_background_max_per_owner` (20), `:process_stats_probe_timeout_ms` (2_000), `:process_kill_grace_ms` (1_500).
- `:process_kill_grace_ms` has a SECOND, per-process form: the CALLING process's `:process_kill_grace_ms` dictionary entry wins over the app-env key (read at call time by `Control.kill_grace_ms/0`), because the OS kill runs in the caller — that is what lets an `async: true` suite shrink the TERM→KILL window without touching BEAM-global state; nothing in production writes the entry, and an unusable value falls through to the app env, then 1_500.
- Non-protected terminal records are retained for the retention window and capped at the newest `:process_finished_max_records` (default 200) GLOBALLY, while a live owner's terminal `:background_job` records are exempt from that age and global cap and bounded at the newest `:process_background_max_per_owner` (default 20) per owner; live records are never pruned, and an owner's monitor is dropped once it has no retained record (re-installed by the next `track/4`); `owner_refs`/`handles` therefore stay bounded by the retained roster.
- POSIX signals are delivered to the process GROUP only when the handle's `pgid` is known and differs from this BEAM's own group (a raw port child inherits it — an unguarded group signal would kill Genesis).
- `server/0` is `Process.get(:evogit_process_manager_server) || __MODULE__` read at CALL time, and every function takes `:server`, so a suite starts isolated named instances.
- Started unconditionally by `EvoGit.Application` AFTER `Phoenix.PubSub` and BEFORE `EvoGit.BackgroundJobs` (which registers its detached jobs here).
- Every EXTERNAL execution carries a REAL OS identity on its backend path: `EvoGit.Sandbox.Helpers.run_task_with_partial/9` and `run_tracked_command/7` spawn the child through a directly owned port and attach its pid (`:posix`) as soon as `wait_for_os_pid/2` observes it, so the non-sandboxed Linux/bwrap/macOS paths, the macOS `sandbox-exec` path and the `None` Unix path are observable and controllable instead of pid-less; the systemd path attaches the transient unit instead.

## Routing Table

No child directories — all modules live directly in this directory.
Cross-node contracts: `../tool_runtime/`, `../background_jobs` and `../sandbox/` register executions here; `../agent_scheduler/` exposes the node-local RPC reads/controls (`RemoteAPI.list_processes/get_process/process_stats/process_control`) that a remote dashboard calls into this node's manager.

<!-- genesis:local -->

## Retention

`EvoGit.ProcessManager.Retention` owns the ONE retention decision (`doomed_ids/2`) and `Registry.prune_state/1` only does the state surgery — the record, its `Handle` and its kill intent go together, then any owner monitor nobody needs is dropped.
It runs on every `finish/3`, on `prune/1`, on an owner death and on every sampling tick; a live record is never doomed, and `prune/1`'s `{:ok, removed_count}` counts the DISTINCT records that pass dropped.
A terminal `:background_job` whose `owner_pid` is STILL ALIVE is PROTECTED (`Retention.protected?/2`): a running agent may still ask `/processes` or an audit about a job it started minutes ago, so such a record is NEVER age-pruned — its lifetime follows its own owner, not other agents' churn.
Protected records are bounded PER OWNER instead: the newest `:process_background_max_per_owner` (default 20) of that owner survive regardless of age, and only that owner's own overflow is dropped, oldest of that owner first.
Every other terminal record — a DEAD owner's `:background_job` and EVERY `:tool_call` — keeps the unchanged historical rule: dropped once it is older than `:process_finished_retention_ms` (default 300_000) and the survivors capped at the newest `:process_finished_max_records` (default 200) GLOBALLY, so protected records never consume the global budget.
`owner_pid` comes from execution meta (`"owner_pid"`/`:owner_pid`, coerced to a pid by `pid_or_nil/1`), and `Retention.owner_alive?/1` reads it defensively: a nil or non-pid owner (or a pid whose process has ended) counts as DEAD, so the record falls back to the ordinary age/global path.
`get/2`/`lookup/2` answering `{:error, :not_found}` at THIS layer means only "not retained here" — the id was never tracked or its terminal record has already aged out.
It is never a claim that the work did not happen: the agent-facing answer for an aged-out `:background_job` is the `EvoGit.BackgroundJobs` tombstone, which outlives this node-local roster.

## Design Decisions

- Locality: the roster is per-BEAM live state, so it is neither persisted, archived nor aggregated — a node restart legitimately starts empty, and cross-node answers come from RPC into each owning node's own registry.
- Retention is a recent-actions list: operators need "what did this node just run", never a full audit trail, so terminal records are both time-bounded and count-bounded while live executions are always kept; a LIVE owner's terminal background jobs are the exception, because its own agent may still need them, so they are bounded per owner instead of by age or by other agents' churn.
- Owner monitors are keyed by owner pid and reaped with the records they protect, so the monitor map can never outgrow the retained roster.

## Known Issues

- The systemd control backend (`control/systemd.ex`: `systemctl --user show` / `kill` against the execution's unit) has NO automated test coverage, because exercising it would act on the real `evogit.slice` and could signal the host BEAM; it is validated by code review only, and the suite pins just `Handle` normalization of a legacy `%{kind: :unit, …}` map.
- Windows (`control/windows.ex`) supports kill only (`taskkill /PID <pid> /T /F`): `pause/2`, `resume/2` and every `signal/2` answer `{:error, :unsupported}`, because Windows has no portable POSIX-signal equivalent and suspending a process would need `NtSuspendProcess`/`DebugActiveProcess` (out of scope: OS probes via `System.cmd` only, no new dependencies); memory comes from localized `tasklist` CSV and CPU is best-effort via PowerShell `(Get-Process -Id <pid>).CPU`, so an unparseable answer yields `nil` fields.
- An execution whose handle exposes no OS identity cannot be probed or signalled by pid: `Control.Posix` and `Control.Windows` answer `{:error, :no_pid}` (so `sample/2` returns that error and `sample_all/1` omits the execution) while the record itself is still tracked, listed and retained; `:systemd_unit` is the exception, because control addresses the UNIT and needs no pid, and its `stats/1` reports cgroup CPU/memory with `pids: []`.
- `stats` are best-effort point-in-time samples read from `/proc`, one `ps` table, `tasklist` or `systemctl show` at the call-time-configurable sampling interval, not exact accounting; on a backend that reports cumulative CPU only (Linux `/proc`, Windows PowerShell) the value the backend returns carries `cpu_percent: nil` — the sampling TIMER derives it from the delta against the previous sample of the same tree, so the FIRST sample of an execution has no percentage and an on-demand `sample/2` / `sample_all/1` read never derives one (macOS `ps` supplies `%CPU` per sample and needs no delta).
- Retention deletes NON-PROTECTED terminal records outright once the retention window (Retention) passes or the global cap pushes them out, so a pruned id answers `{:error, :not_found}` from `get/2` and is absent from `list/1` and `sample_all/1`; a LIVE owner's `:background_job` records survive that window but are lost once that owner dies and its own per-owner cap is exceeded: a FAILED kill never transitions the record (it stays live and controllable, appends `%{action: :kill, reason: {:kill_failed, reason}, actor: actor}` to `control_log` and returns that error), so only successful kills become `:killed`. `:unknown` is declared in `Execution.status` for that degraded case, but NO current code path produces it (only `:starting | :running | :paused | :completed | :failed | :killed` are ever assigned).
- `attach/3` and `finish/3` can answer `{:error, :timeout}` / `{:error, {:registry_exit, reason}}`, while `EvoGit.Sandbox.Helpers.attach_execution/3` (`../sandbox/`) still specs `:: :ok` and returns `attach/3`'s value verbatim; every caller ignores that value, so the drift is documentation-only.
