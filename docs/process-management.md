# Managed Process & Tool-Execution Platform

Design record. Scope: how Genesis executes and then *owns* the work an agent holds — foreground tool
calls (built-in and shell), detached background jobs and the sandbox trees behind them — and how operators
inspect and control that work. This describes the current implementation; it is not a change log.

| Concern | Owner |
|---|---|
| Platform mechanics (argv, spawn, timeout, partial output, real OS identity) | `EvoGit.Sandbox` + `sandbox/*` |
| Detached spawn/kill/status per backend | `EvoGit.Sandbox.Background` |
| Background-job output bookkeeping and agent-visible job status | `EvoGit.BackgroundJobs` |
| One batch of model tool calls | `EvoGit.ToolRuntime` |
| The node-wide execution registry, sampling and control | `EvoGit.ProcessManager` |
| Node RPC | `EvoGit.AgentScheduler.RemoteAPI` / `EvoGit.RemoteNode` / `EvoDash.NodeContext` |
| The inspector | `EvoDashWeb.ProcessesLive` (`/processes`) |

---

## 1. Problem & motivation

Before this platform existed, the agent loop owned every part of tool-call execution itself: it partitioned
the batch, resolved each timeout, acquired scheduler slots, called into the sandbox backends, and (for
`run_in_background`) created and reaped background jobs. Everything it spawned was a private detail of an
agent process.

That is workable while the only consumer is the agent, and blocks every cross-cutting feature the moment
there is another consumer:

- **No node-wide answer to "what is running right now".** Execution state lived in per-agent process
  dictionaries, so nothing could list what this node holds, for which agent and task.
- **Invisible children.** Sandboxed commands were spawned as plain ports and executed through
  `System.cmd`-shaped helpers, so the OS pid of the real child was not retained. Without an address there
  is nothing to sample, signal or kill.
- **No resource visibility.** CPU time and memory of a runaway `mix test` or a compiler were simply not
  observable from the dashboard.
- **No control.** Terminating a misbehaving foreground command meant killing the whole agent, and killing
  a background job was the only per-process action that existed.
- **No audit.** A kill had no record of who asked, for what reason, or when.

The fix is a platform, not a bigger agent: sandbox mechanics stay with the sandbox, batch mechanics move to
a runtime module, and the registry/observability/control plane moves to one supervised process that
everything else registers into.

## 2. Layering

### Sandbox — platform mechanics

`EvoGit.Sandbox` dispatches `run/4`, `run_with_partial/6` and the OPTIONAL `run_with_partial/7` to the
active backend (`Linux` systemd, `Bwrap`, `MacOS` `sandbox-exec`, `None` passthrough). The 7-arity form adds
ONE observability option, `:execution_id` (`"proc-<n>"`). Each backend attaches its real OS identity at the
single point where that identity is known:

| Backend path | Attached handle |
|---|---|
| `Linux` sandboxed | `%Handle{kind: :systemd_unit, unit: …}`, right after `SandboxProcessRegistry.register/0` |
| `Linux` non-sandbox, `Bwrap` disabled, `None` Unix | `:posix` pid of the bash child, inside `Helpers.run_task_with_partial/9` |
| `Bwrap` enabled | `:posix` pid of bwrap itself (bwrap is the session leader; `--die-with-parent` tears down the tree) |
| `MacOS` (both paths) | `:posix` pid — the `sandbox-exec` child via `Helpers.run_tracked_command/7`, or the bash child |
| `None` Windows | `%Handle{kind: :windows, os_pid: …}` right after `Helpers.wait_for_os_pid/2` |

The attach itself is `Helpers.attach_execution/3`, which is best-effort and never raises: a missing or
restarting registry cannot fail, slow or alter a command. Callers that pass no `:execution_id` (internal
`rg`/git/skill invocations) get no tracking at all.
The same option drives the terminal fact: `Helpers.record_exit/2` settles the record `:completed` with
`reason: :exited` and the run's REAL exit code, `Helpers.record_timeout/1` settles it `:killed` with
`reason: :timeout` AFTER the tree kill, and `:record_exit_status: false` suppresses the record for a command
the caller will re-run (the macOS process-limit retry), so only the final attempt's status becomes the
execution's outcome.

### ToolRuntime — one batch

`EvoGit.ToolRuntime.execute_batch/2` takes the model's indexed tool calls plus one
`%EvoGit.ToolRuntime.Request{}` and returns `{index, tool_call_id, name, output}` tuples sorted by index.
It owns the serial/parallel partition, per-call timeout resolution, tool-slot acquisition, the spawned tool
task and its process-dictionary installation, failure containment, tracking and output sanitization.

### ProcessManager — registry, observability, control

`EvoGit.ProcessManager` (a `GenServer` behind a facade, started unconditionally by `EvoGit.Application`
after `Phoenix.PubSub` and *before* `EvoGit.BackgroundJobs`) keeps ONE `%Execution{}` per live execution — a
built-in call that ran in the BEAM as well as an external OS process — at most ONE `%Handle{}` per external
execution, one sampling timer and one PubSub topic. It records and observes; it does not start processes.
Two rules follow from that:

- **No OS call ever runs inside the registry.** `sample/2`, `sample_all/1`, `signal/3`, `pause/2`,
  `resume/2` and `kill/2` resolve the record in the registry and do the OS work in the **caller**; the
  sampling tick probes in a monitored throwaway worker. A hung `ps` or `systemctl` can therefore never
  freeze the node's execution view.
- **Everything is total.** An unknown id is `{:error, :not_found}` (or `:ok` for the mutating calls), a
  failed probe is `{:error, reason}`, an unrecognized handle is a no-op. Nothing here raises on bad input.

### BackgroundJobs — job bookkeeping stays authoritative

Every detached job is *also* registered as a `:background_job` execution with `runtime: :background`: the
start path tracks it with the agent-visible identity — `agent_id` and `task_id` in their NATIVE terms (agent
ids are integers; an earlier normalization nil'ed them, which broke `list(agent_id: …)` and the dashboard's
agent filter) — attaches the normalized handle (`EvoGit.Sandbox.Background.normalize_handle/1`) and stores
the returned `execution_id` on the job record. ONE terminal funnel in `put_job/2` finishes that execution
when the job reaches `:completed`/`:failed`/`:killed`, carrying the job's own `exit_code` and reason, so a
background job records the same terminal facts as a foreground shell call. Killing a job through either door
stops the process and settles both records, because `ProcessManager.kill/2` routes a `:background_job` with a
`job_id` back to `EvoGit.BackgroundJobs.kill/2` and only falls back to raw handle control when that job is
unknown.

### Agent boundary

`EvoGit.Agent.ToolDispatch.batch_execute_tools/4,5` remains the public contract and is now a thin
delegator: it resolves the agent-side identity ONCE per batch (agent id, task id, `self()` as the owner pid,
repo path/root, node path, per-task tmpdir, max timeout, delegation level, role guards) into a `%Request{}`
and hands it to the runtime. Delegation hints and the redundant-`cd` warning stay agent-side, applied after
the batch in the parent process.

## 3. Execution lifecycle

### The record

`%EvoGit.ProcessManager.Execution{}` models the AGENT-visible identity of one execution:

| Group | Fields |
|---|---|
| Identity | `id` (`"proc-<n>"`), `kind` (`:tool_call \| :background_job`), `tool`, `command`, `label` |
| Ownership | `agent_id`, `task_id`, `owner_pid` |
| Context | `cwd`, `repo_root`, `backend` (`:builtin \| :systemd \| :bwrap \| :sandbox_exec \| :none`), `runtime` (`:foreground \| :background`) |
| OS addressing | `os_pid`, `unit`, `job_id` (all nil for a built-in call) |
| Outcome | `status`, `exit_code`, `reason`, `inserted_at`, `started_at`, `ended_at` |
| Observation | `stats` (always a map — see §5), `control_log` (oldest first) |

`pgid` deliberately lives on the `%Handle{}`, not on the execution: the record models identity, the handle
models OS addressing.

### Origin (`runtime`) vs backend

The two questions are separate, and the record answers both without conflating them:

- **`runtime` is the call's ORIGIN, never what runs it.** `:foreground` means the agent is blocked on the
  call; `:background` means the call outlives the agent's turn — an `EvoGit.BackgroundJobs` job (the OS spawn
  mode behind it is still `EvoGit.Sandbox.spawn_detached/…`). There is no `:detached` runtime value.
- **`backend` is what runs the call.** `:builtin` means the call ran **inside the BEAM** — a built-in tool
  such as `read`/`write`/`edit`/`rg`/`search_*`/`elixir_eval`/`job_output`, anything that is not the platform
  shell. It therefore has no OS process: no `os_pid`, no `unit`, no uptime and no CPU/memory stats (`stats`
  stays `Stats.empty/0`), it is never sampled, and every control call answers `{:error, :no_os_process}`.
  `:systemd | :bwrap | :sandbox_exec | :none` describe an **external** OS process anchored by that sandbox
  backend, `:none` being external but unsandboxed.

`Execution.builtin?/1`, `external?/1` and `sampleable?/1` are the total predicates the rest of the platform
keys on: `builtin?/1` is true only for a `%Execution{backend: :builtin}` (any other term, including `nil`, is
false), `external?/1` is its negation, and `sampleable?/1` is `live?/1 and external?/1` — so a live built-in
record never arms the sampling timer, is never probed by `sample_all/1` and never contributes a stats row.
`attach/3` never downgrades a `:builtin` backend to a handle-derived one.

### Terminal facts

Both foreground tool calls and background jobs settle through the same vocabulary:

- **`exit_code`** is an integer `0..255` only when an external OS process genuinely exited; it is `nil` for
  timeouts, kills, built-in calls and never-started calls.
- **`reason`** is the ONE terminal cause, `nil` while the execution is live: `:exited` (the process ended on
  its own — consult `exit_code`), `:timeout`, `:invalid_arguments` (never started: unparseable/malformed tool
  arguments), `:owner_died`, `{:killed_by, actor}`, `{:crashed, detail}`, `:no_os_process` (a built-in call
  finished; nothing ran) or the additive `{:tool_error, reason}` (a tool answered `{:error, reason}`, which is
  not a raise or an exit).

`Execution.status_for_reason/1` is the uniform status mapping: `:exited` and `:no_os_process` → `:completed`,
`:timeout` and `{:killed_by, _}` → `:killed`, and `:invalid_arguments`, `{:crashed, _}`, `:owner_died`,
`{:tool_error, _}` or any other term → `:failed`. `:completed` deliberately ALSO covers a NON-ZERO
`exit_code`: the tool call itself succeeded and the model receives a normal result (the dashboard colors the
code). The SANDBOX layer records a foreground shell's exit status at the one place that observes it
(`Helpers.record_exit/2`, `Helpers.record_timeout/1`), while the tool runtime settles the built-in, malformed-
argument, crash, timeout and tool-error outcomes.

**An operator kill outranks a racing natural exit.** `kill/2` stops the OS process BEFORE it finishes the
record, and the sandbox layer observes that same exit and tries to settle the record itself; the registry
therefore holds a per-id kill INTENT (the requesting actor) while the stop is in flight. The FIRST non-killed
terminal finish then lands as `:killed` with `reason: {:killed_by, actor}` and `exit_code: nil`, because the
observed exit is the kill's consequence rather than a terminal fact of its own — one exit broadcast, never
two. An incoming `:killed` or `:owner_died` finish is never translated, a failed stop clears the intent so a
later natural exit keeps its own facts, and the human-supplied kill reason text lives in `control_log` only.

### Statuses

```
:starting ──attach/3──▶ :running ──pause/2 (SIGSTOP)──▶ :paused
                          ▲   │                            │
                          └───┴──── resume/2 (SIGCONT) ◀─────┘
                          │
                          ├── finish/3 ──▶ :completed | :failed | :killed
                          └── signal/3 (:term/:kill) ──▶ the OS ends it; the caller records the outcome
```

`:completed`, `:failed` and `:killed` are terminal (`Execution.terminal?/1`) — a record in one of them never
changes again, and which one a finish lands on follows `Execution.status_for_reason/1` (§ Terminal facts).
`:running` and `:paused` are the live statuses (`Execution.live?/1`); only a live AND external record
(`Execution.sampleable?/1`) is probed, so a live built-in call is listed but never sampled. `:unknown` exists
for the degraded case where the OS state can no longer be observed; a successful probe never produces it.

### The three calls

- `track(kind, meta, opts) :: {:ok, id}` — records a new execution. Meta keys are `:tool`, `:command`,
  `:label`, `:agent_id`, `:task_id`, `:owner_pid`, `:cwd`, `:repo_root`, `:backend`, `:runtime`, `:job_id`;
  documented string keys are accepted and unknown keys ignored (no atom is ever created from input), and
  identities are kept as the caller supplied them (agent ids stay integers). A pid `:owner_pid` is monitored.
- `attach(id, handle, opts) :: :ok` — records the OS handle, promotes `:starting → :running`, stamps
  `started_at` only if still nil (a re-attach does not move it) and broadcasts `:process_started` exactly on
  that transition. An unknown/terminal execution or an unrecognized handle is a silent `:ok` — never a ghost
  `:running` record. Built-in calls never attach, so they are finished straight from `:starting`.
- `finish(id, status, opts) :: :ok` — records a TERMINAL status with `:exit_code` and `:reason`, stamps
  `ended_at`, broadcasts `:process_exited` once. A second `finish` is a no-op: the FIRST terminal fact wins,
  which is why the tool runtime's unconditional `:completed` + `:no_os_process` never overwrites a shell
  call's `:exited` verdict.

### A foreground call, end to end

1. The agent loop hands the batch to `ToolDispatch.batch_execute_tools/5`, which builds the `%Request{}` and
   calls `EvoGit.ToolRuntime.execute_batch/2`.
2. The runtime partitions the batch (§7), acquires a tool slot, and spawns one linked task per parallel call.
3. `Tracking.track/4` records a `:tool_call` execution with `runtime: :foreground` and the PER-CALL backend —
   the resolved sandbox backend for the platform shell tool, `:builtin` for every other tool. `owner_pid` is
   the AGENT pid, never the tool task's (the tool task is shut down the instant the call returns; anything
   monitoring it would see an immediate exit).
4. For a shell call the task's process dictionary is seeded with `:evogit_execution_id`; the shell tool reads
   it and passes it as `execution_id:` through `EvoGit.Sandbox.run_with_partial/7`.
5. The backend attaches its real OS identity (`Helpers.attach_execution/3`), so the record becomes
   `:running` with an `os_pid` or a `unit` and is immediately samplable and controllable. It later records
   the run's terminal fact there too (`Helpers.record_exit/2` with the real status, or
   `Helpers.record_timeout/1` after the tree kill).
6. A built-in call never reaches step 4 or 5: it has no pid, no unit, no uptime and no CPU/memory figures,
   is never sampled, and finishes `:completed` with `reason: :no_os_process` when the tool returns.
7. Per-call settlement lives in the RUNTIME process: malformed arguments finish `:failed` +
   `:invalid_arguments`; `{:tool_crashed, _}`/`{:exit, _}` finish `:failed` + `{:crashed, …}`; a tool that
   answers `{:error, reason}` finishes `:failed` + `{:tool_error, reason}`; on a `Task.yield` timeout the
   runtime calls `Tracking.kill(id, :timeout)` (which kills the OS handle via `ProcessManager.kill/2` with
   actor `:tool_runtime`) and the record ends `:killed` with `reason: :timeout`.

### Retention and pruning

Process records are node-local, in-memory operational state: nothing is written to the task store, archived or aggregated across nodes.
Retention is a recent-actions list, not a history — terminal records are kept for `:process_finished_retention_ms` (default `300_000`) and capped at the newest `:process_finished_max_records` (default `200`); live records are never pruned.
Retention runs on every `finish/3`, every owner-death sweep, every sampling tick, and `prune/1` is the explicit operator/test entry point.
A record's `control_log` is capped at 50 entries so a pause/resume hammer cannot grow it without bound,
and owner monitors are dropped once an owner has no retained record.

### Owner death

`track/4` installs ONE `Process.monitor/1` per distinct owner pid. When that process dies, every
non-terminal execution it owned is best-effort killed (the OS call happens in a throwaway process, never in
the registry) and marked `:failed` with `reason: :owner_died`, so a ghost handle is never left `:running`.
This covers agent completion, crash, graceful cancel and force-kill, since all four end the agent pid.

## 4. Handles and control backends

`%EvoGit.ProcessManager.Handle{}` is the normalized addressing mode, so control never branches on
backend-shaped sandbox maps. `Handle.normalize/1` accepts a `%Handle{}` as-is or converts the legacy
`%{kind: :unit, unit: …}` / `%{kind: :port, port: …}` shapes `EvoGit.Sandbox.Background.spawn/1` returns
(`:port` becomes `:windows` on Windows, `:posix` elsewhere); anything else is `{:error, :invalid_handle}`.
Only EXTERNAL executions ever hold a handle — a `:builtin` record has none, so `sample/2`, `signal/3`
(hence `pause/2` and `resume/2`) and `kill/2` answer `{:error, :no_os_process}` instead of reaching this
layer, and a built-in record is never finished by control.

| `kind` | Backend module | Stats | Signal | Kill |
|---|---|---|---|---|
| `:systemd_unit` | `Control.Systemd` | `systemctl --user show <unit> -p CPUUsageNSec,MemoryCurrent,ActiveState` | `systemctl --user kill --signal=<SIG> <unit>` | TERM → grace → KILL, then `alive?/1` |
| `:posix` | `Control.Posix` | `/proc` walk on Linux; one `ps -eo pid,ppid,pgid,pcpu,rss,time,stat` on macOS/BSD | `kill -<SIG> -- -<pgid>` when the group is known and differs from the BEAM's; else the bare pid | TERM → grace → KILL, then `alive?/1` |
| `:windows` | `Control.Windows` | `tasklist` (memory, required) + PowerShell `(Get-Process -Id …).CPU` (best-effort) | `{:error, :unsupported}` | `taskkill /PID <pid> /T /F`, verified with `alive?/1` |

Notes that matter:

- **Signals** are normalized by `Control.normalize_signal/1` from the small atom vocabulary
  (`:term | :kill | :int | :hup | :stop | :cont | :usr1 | :usr2`) or a binary name (`"TERM"`, `"SIGKILL"`).
  `Control.status_after_signal/1` is the ONE rule saying `SIGSTOP` implies `:paused` and `SIGCONT` implies
  `:running`, so pause/resume and the record cannot disagree.
- **Kill escalation** is TERM → `:process_kill_grace_ms` (default `1_500`) → KILL → a final `alive?/1`
  check, so `:ok` means the handle is really gone. `ProcessManager.kill/2` therefore marks the record
  `:killed` ONLY when the backend reports success; a failed or refused kill leaves the status untouched, so
  the execution stays observable and controllable, logs the attempt and returns the error (§10).
- **The pgid guard is load-bearing.** A raw port child normally inherits the BEAM's own process group, so an
  unguarded `kill -- -pgid` would kill Genesis itself; group signalling therefore requires a known `pgid`
  that differs from our own, and falls back to the bare pid.
- **Pause is a POSIX concept** (`{:error, :unsupported}` on Windows), and a transient systemd unit that
  exited is unloaded immediately (`CollectMode=inactive`), so "unit not found" is a normal answer:
  `alive?/1` is false, nothing raises.

Every accepted action is appended to the record's `control_log` as
`%{action:, signal:, reason:, actor:, at:}` and broadcast as `:process_control`. `pause/2`/`resume/2` are
`signal/3` with `:stop`/`:cont`, so they are logged uniformly.

## 5. Stats and sampling

The stats map is FROZEN and always complete:

```elixir
%{
  cpu_time_ms: non_neg_integer() | nil,
  cpu_percent: float() | nil,
  memory_bytes: non_neg_integer() | nil,
  rss_bytes: non_neg_integer() | nil,
  pids: [integer()],
  sampled_at: DateTime.t() | nil
}
```

A figure the backend cannot observe stays `nil` — never a fake `0`.

- **CPU percent** is derived, not read: `Stats.cpu_percent/4` takes two CUMULATIVE CPU-time samples and
  their timestamps and returns `Float.round(max(cur - prev, 0) / elapsed_ms * 100, 2)` — i.e. percent of one
  core. It returns `nil` when a value or timestamp is missing or time did not advance, and clamps a shrinking
  cumulative value (a tree that lost a member) to 0.
- **Aggregation is over the subtree**, bounded: the Linux probe walks `/proc/<pid>/task/*/children`
  breadth-first (max 256 nodes, depth 16) and sums `utime`+`stime` (converted with `USER_HZ = 100`) and
  `VmRSS`; the macOS probe aggregates the `ppid` subtree of one `ps` table. `/proc`-wide process-group
  scanning is deliberately NOT done — it would attribute the BEAM's own siblings to the execution.
  `memory_bytes` mirrors `rss_bytes`: for a tree, resident set is the figure a human wants.
- **Pure parsing.** Every OS text format (`/proc/<pid>/stat`, `/proc/<pid>/status`, `ps`,
  `systemctl show`, `tasklist`) is parsed by a total function in `EvoGit.ProcessManager.Stats`, so backends
  stay thin and the suite pins exact formats with fixture strings without spawning anything.

Two read paths:

- `sample(id, opts)` — on demand, ONE execution, OS work in the caller. Answers `{:ok, stats}`,
  `{:error, :not_found}`, `{:error, :not_running}` (terminal, or no handle), `{:error, :no_os_process}` (a
  built-in call) or a backend error. It stores the observation on the record but does NOT broadcast (a read
  must not churn the topic).
- `sample_all(opts)` — every `:running`/`:paused` execution, bounded concurrency (4 at a time, one
  `:process_stats_probe_timeout_ms` budget per probe, timed-out probes killed). Failed probes are OMITTED
  from the returned map rather than reported — one dead handle must not hide the other executions.

The **sampling timer** is the third path: while at least one live execution exists and
`:process_stats_enabled` is true, ONE self-timer fires every `:process_manager_sample_interval_ms` (default
`3_000`), spawns a monitored probe worker, stores each result and then broadcasts ONE `:process_sample`.
Sampling keys on `Execution.sampleable?/1` (live AND external), so a live built-in call never arms the timer,
never appears in a `sample_all/1` result and never yields a stats figure.
Ticks that arrive while a worker is in flight are dropped (sampling is incremental, never queued) and the
timer is disarmed when nothing live remains, so an idle Genesis burns no OS calls. A
`{:process_updated, id, %{stats: …}, node}` is broadcast only when `Stats.changed?/2` says the numbers moved
meaningfully — the three counters or the pid set; `cpu_percent`/`sampled_at` move on every tick by
construction and never count as a change.

All tuning is call-time app env (no TOML keys, so the suite stays async-safe):
`:process_manager_sample_interval_ms`, `:process_stats_enabled`, `:process_finished_retention_ms`,
`:process_finished_max_records`, `:process_stats_probe_timeout_ms`, `:process_kill_grace_ms`.

## 6. PubSub contract

Topic `"processes"` on `EvoGit.PubSub`, five message shapes, emitting node LAST so a multi-node dashboard can
filter:

| Event | Payload | Emitted |
|---|---|---|
| `:process_started` | `{:process_started, execution, node}` | on `:starting → :running` (the first `attach/3`) |
| `:process_updated` | `{:process_updated, id, changes, node}` | only the changed fields (`%{status: :paused}`, `%{stats: stats}`) |
| `:process_exited` | `{:process_exited, execution, node}` | on the ONE terminal `finish/3` |
| `:process_sample` | `{:process_sample, node, seq, entries}` | once per sampling tick; `entries` is `[%{id:, status:, stats:}]`, `seq` monotonic |
| `:process_control` | `{:process_control, id, entry, node}` | per accepted signal/pause/resume/kill, carrying the control-log entry |

Lifecycle changes only: a second `finish/3`, an unchanged status or a no-op attach never broadcasts. A
built-in execution never attaches, so it announces itself through its ONE `:process_exited` (the dashboard
prepends an unknown-id exit row). The dashboard consumes the topic with no polling at all — `ProcessesLive`
is its only consumer and merges each node-matching event into its in-memory row list (find-or-nil; an event
for an unknown id is a no-op).

## 7. Tool runtime responsibilities

`%EvoGit.ToolRuntime.Request{}` is the whole batch context, resolved once by the agent and re-installed in
every tool task:

| Field | Meaning |
|---|---|
| `agent_id` / `task_id` | scheduler identity the tool slot and tracking are acquired under |
| `agent_pid` | the AGENT's pid (owner of jobs and of the execution record) |
| `repo_path` / `repo_root` | the worktree (tool `cwd`) and the repo's main working copy |
| `node_path` | the agent's context-tree node |
| `taskdir` | per-task tmpdir (`EvoGit.TaskTmpdir`) |
| `max_timeout` | configured per-call ceiling (default `DelegationHints.max_tool_timeout/0`) |
| `delegation_level` / `agent_module` | the receiving role |
| `role` | role-guard inputs `%{repo_less:, foreign_repos:, repo_id:}` |

`Request.new/1` takes a map or keyword list, ignores unknown keys, and defaults `delegation_level` to
`:high` and `role` to the empty guards.

**Serial vs parallel.** The batch is split by `EvoGit.Agent.Tools.serial_tool?/1` — the single
classification source of truth for read-modify-write tools (`write`/`edit`-style calls, which each read the
original bytes so overlapping them silently discards all but the last write).

| Phase | Runs | Why |
|---|---|---|
| Serial | sequentially, in the PARENT agent process, in request order, FIRST | a file mutation always lands before any read or shell command of the same batch that could observe it |
| Parallel | one linked task per call, `max_concurrency` = batch size, `timeout: :infinity` | the scheduler's tool-slot pool, not a local cap, is the binding constraint |

**Slots.** Every call acquires a tool slot through `AgentScheduler.with_tool_slot(request.agent_id, fun)`
inside `execute_tool_with_timeout/4`, so `max_tool_concurrency` applies to both phases.

**Timeouts.** `EvoGit.Agent.ToolInvocation.resolve_timeout/4` resolves the per-call budget (an explicit
`timeout` argument, clamped by `[:scheduler, :max_tool_timeout]`); a tool's own advertised default
(`EvoGit.Agent.Tools.default_timeout_ms/1`) is then applied as a pure MAX and clamped by the same ceiling,
except for tools whose `timeout` argument is an internal wait budget (`Tools.timeout_arg_is_wait_budget?/1`,
today `job_output` with `wait: true`). The approval window plus a 30 s execution buffer is a floor for
approval-gated calls. `Task.yield(task, tool_timeout) || Task.shutdown(task)` bounds each call.

**Containment and output.** The tool task is spawned on `EvoGit.ToolRuntime.TaskSupervisor` when registered
(fallback `Task.async/1`), deliberately LINKED, and keeps the `try/rescue/catch` that turns a crashing tool
into `{:tool_crashed, …}`. A spawned task has an EMPTY process dictionary, so the runtime re-installs the
tmpdir, the owner identity (`:evogit_agent_id`/`:evogit_task_id`/`:evogit_agent_pid`),
`:repo_path`/`:genesis_repo_root`, the role guards and `:evogit_execution_id`. Output goes through
`EvoGit.ToolRuntime.Output.sanitize/3` (wrap → `OutputSanitizer.sanitize_and_truncate/3` → truncation
feedback → re-wrap; an all-text output collapses back to a plain binary).

Tracking is OBSERVABILITY: `Tracking.track/4`, `.finish/2` and `.kill/2` are all failure-isolated (debug log
plus a documented fallback), nil ids are tolerated, and a dead or restarting registry can never change a
tool result. The `batch_execute_tools/4,5` contract — same arguments, same result shape — is unchanged.

## 8. Dashboard inspector

`/processes` (`EvoDashWeb.ProcessesLive`) is the node-aware inspector. Each execution renders as two table
rows: a summary row (status badge, agent link, task link, tool badge + command, runtime, backend, OS target,
uptime, CPU%, memory, exit code) and a detail row with the full command, cwd, repo root, reason, timestamps
and the complete control log (`ProcessComponents.execution_row/1`).

- **Built-in executions** (`backend: :builtin`) render as first-class rows but show `—` in Target, Uptime,
  CPU and Memory — there is no OS process to measure — and render NO pause/resume/terminate/kill cluster at
  all (the whole actions cell is gated on `Format.external?/1`), so the page never offers a control that
  would answer `{:error, :no_os_process}`. The Exit column uses the shared exit/reason label (the code, else
  a reason label, else `—`), and the expanded detail block adds Target, Exit Code, Reason, Runtime and
  Backend. The Backend column reads "In-process" for `:builtin` and "Unsandboxed" for an external `:none`
  process. External rows keep the status-gated controls.
- **Loading** is asynchronous and exit-safe: `ProcessesLive.Load.start/1` bumps a monotonic sequence, paints
  the loading state and runs the fetch on `EvoDash.TaskSupervisor` inside `EvoDash.SafeCall.run/1`, so a dead
  RPC target becomes an error value and the loading flag can never stick. The self-message tag is
  `{:processes_loaded, seq, node, result}` and is dropped unless BOTH `seq` and `node` still match — a
  superseded load, or one for a node the operator already left, is discarded. Failures keep the page usable
  and offer Retry.
- **Live updates** come from the topic only (§6); there is no polling. The list is newest-first, and a
  genuinely NEW row animates in on join: `upsert_execution/3` checks the id is absent BEFORE inserting (the
  same guard that suppresses a duplicate prepend), marks it in an `:entering` set, and clears that mark after
  `:processes_entering_ttl_ms` (default `1_500`) through ONE scheduled self-message, so a later sample or
  update of an already-cleared row never restarts the animation. Both a `:process_started` prepend and an
  unknown-id `:process_exited` prepend qualify; the initial load, a Retry and a node/filter switch never
  animate. The class is `process-row-enter` (fade in + slight downward slide + fading tint, disabled under
  `prefers-reduced-motion: reduce`), and row DOM identity stays `id={"process-row-<id>"}` so LiveView
  patching never restarts it.
- **Filters**: `?status=live|finished|all` (default `live`), `?kind=tool_call|background_job`, `?q=<text>`,
  `?agent_id=`, `?task_id=`, plus the node param. Status tabs and the text query are applied at render time
  over the already-loaded rows; `agent_id`/`task_id` are passed to the core as list filters (which works
  because a background job carries its agent id natively). Tab badges count exactly what the tab would show.
- **Controls**: pause/resume run immediately with a canned reason. Terminate (`TERM`) and kill (`TERM` →
  KILL, labelled "Danger zone") open a confirmation modal and REQUIRE a NON-EMPTY reason — a blank reason
  performs no call at all. `:ok` closes the modal; an error keeps it open so the operator can retry. Control
  actions are attributed to actor `:remote`, rendered as "Dashboard". Precise core answers get their own
  message, including `:no_os_process` for a built-in execution — the UI hides its controls, so that is only
  the race/remote fallback.
- **Per-agent filtering**: `/processes` is the only dashboard surface for managed processes. `?agent_id=`
  restricts the core-side list query — the initial snapshot and every reload after a filter change — through
  `NodeContext.list_processes/2`'s `:agent_id` opt, and the active filter renders as a removable "Agent"
  chip in the filter bar beside the optional `?task_id=` chip. Each row also links its agent id to the
  node-aware `/agents` page, which carries no process data of its own.

The RPC surface mirrors one-for-one across the three layers: `EvoGit.AgentScheduler.RemoteAPI`
(`list_processes/1`, `get_process/1`, `process_stats/1`, `process_control/3`) ← `EvoGit.RemoteNode`
(`node`-taking wrappers) ← `EvoDash.NodeContext` (`list_processes/2`, `process_control/4`). `process_control`
normalizes `:pause | :resume | :kill | {:signal, sig}` and never forwards an unrecognized action; the list
returns native `%Execution{}` structs, which `:erpc.call/5` transfers intact. Test seams:
`:processes_page_load_runner` and `:processes_control_runner` (`:evo_dash`).

## 9. Extension guide

The point of the layering is that each kind of extension touches a small, known set of seams.

**A new tool-call kind** (something an agent holds that is not a foreground tool call or a background job):
1. add it to `Execution.kind` / `ProcessManager.normalize_kind/1` and to `Format.kind_label/1` + the `/processes`
   kind filter;
2. `track/3` it where it starts, choosing its `backend` honestly — `:builtin` when the call runs inside the
   BEAM (it must then never attach, never be sampled and answer `{:error, :no_os_process}` to control), a
   sandbox backend when an external process is involved — and `attach/3` the handle as soon as the OS
   identity exists;
3. `finish/3` it in ONE terminal funnel (mirror `BackgroundJobs.put_job/2`) with a `:reason` from the shared
   vocabulary, so the status comes from `Execution.status_for_reason/1` and the record cannot stay `:running`;
4. if it can be killed through an owning registry, add that branch to `ProcessManager.stop_execution/3`.

**A new control backend** (another OS or supervisor):
1. implement the `EvoGit.ProcessManager.Control` behaviour (`stats/1`, `signal/2`, `kill/1`, `alive?/1`,
   every callback total);
2. register the handle kind in `Control.@backends` and in `Handle` (`@type kind`, `normalize/1`,
   `execution_backend/1`);
3. attach it from the sandbox backend that produces that kind — nothing else needs to know.

**A new stat**:
1. add the key to `Stats.empty/0` (the map is frozen: every record carries every key);
2. fill it in the relevant backend's `stats/1` and parse the raw text in a `Stats.parse_*` function;
3. include it in `Stats.summarize/1` and, only when a change should trigger a broadcast, in
   `Stats.changed?/2`;
4. render it in `ProcessComponents.execution_row/1` + `ProcessesLive.Format` (add a label helper, keep it
   total).

**A new dashboard column**: add the label helper to `ProcessesLive.Format`, the `<th>`/`<td>` to
`ProcessComponents.execution_row/1`, plus a test; no core change is needed — the row already carries the whole
`%Execution{}`.

**A new operator action**: add the clause to `RemoteAPI.process_control/3`'s normalization and to
`ProcessManager` (recording a `control_log` entry with `action`, `signal`, `reason`, `actor`), then wire the
button and its confirm flow in `ProcessesLive`/`ProcessComponents`.

## 10. Known limitations

- **The systemd control path is implemented but not covered by automated tests.** Exercising
  `systemctl --user` would create real units in the host's `evogit.slice` and could signal the test BEAM
  itself, so `apps/evo_git/test/evo_git/process_manager/` pins the parsers and the registry, not
  `Control.Systemd`. Treat a change there as code-review-only and verify manually on a Linux host.
- **Windows cannot pause, resume or signal.** There is no `SIGSTOP`/`SIGCONT`/`SIGTERM`; a suspended process
  would need `NtSuspendProcess`/`DebugActiveProcess` through a native call, which is out of scope (no new
  dependencies, OS probes via `System.cmd` only). Kill and stats are supported.
- **An EXTERNAL record can briefly be pid-less.** A child that exits before `Helpers.wait_for_os_pid/2`
  observes it yields an `:undefined` pid, so the handle has no address and stats degrade to `nil` fields until
  the record is finished. The record is still listed and finishable. A `:builtin` record is pid-less BY
  DESIGN: it has no `os_pid`/`unit`, no uptime, no CPU/memory stats and no controls, and it is never sampled
  — the dashboard renders `—` for those columns rather than a fake figure.
- **`exit_code` is only as good as the backend's observation.** A run whose exit status the backend cannot
  read settles `:completed` with `reason: :exited` and `exit_code: nil`; a non-zero code never means failure
  (the tool call succeeded), so the status stays `:completed` and only the dashboard's Exit column shows the
  colour difference.
- **Stats are best-effort samples, not accounting.** Each figure is whatever the last probe could read; a
  probe that fails leaves the previous values in place, and `cpu_percent` is a two-sample delta rather than a
  kernel-accounted average. `pids` is empty on the systemd path (the unit's cgroup is not enumerated) and on
  Windows.
- **The registry is completely local.** Records live only in this BEAM's memory: they are never persisted to the task store, never archived with a task and never aggregated across nodes. A restart loses all records (they are operational state, not history), and a remote node's executions are visible only by RPC to that node's manager.
- **The registry keeps a recent-actions list, not a history.** Terminal records expire after `:process_finished_retention_ms` and the newest `:process_finished_max_records` (default 200) are kept; `control_log` keeps at most 50 entries. A pruned id answers `{:error, :not_found}` from `get/2` and is absent from `list/1` and `sample_all/1`, so older detail is gone by design.
- **A failed kill is never reported as a kill.** `kill/2` transitions the record to `:killed` only when the
  backend confirms the handle is gone; a failed or refused kill leaves the status untouched (the execution
  stays observable and controllable), appends the audited
  `%{action: :kill, reason: {:kill_failed, reason}, actor: actor}` control-log entry and returns the backend
  error, which the caller and the dashboard surface as a failure.
- **`:unknown` is declared but never produced.** It appears in `Execution.status`, yet no current code path
  assigns it — only `:starting | :running | :paused | :completed | :failed | :killed` are ever written.

## Related reading

- Root `CONTEXT.md` routing bullets for the managed platform and for tool-call execution.
- `apps/evo_git/lib/evo_git/process_manager/CONTEXT.md` — the registry/handle/control/stats contracts.
- `apps/evo_git/lib/evo_git/tool_runtime/CONTEXT.md` — the batch engine and its tracking seam.
- `apps/evo_git/lib/evo_git/sandbox/CONTEXT.md` — per-backend attach points and kill primitives.
- `apps/evo_dash/lib/evo_dash_web/live/processes_live/CONTEXT.md` — page contracts and seams.
- `docs/harness-alignment.md` — how tool schemas/results compare to the harness models are trained on (read
  before changing tool names, result formatting or the shell tool surface).
