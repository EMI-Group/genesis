# BackgroundJobs helpers — transport, notices, status probing

## Intent

Helper modules behind `EvoGit.BackgroundJobs` (the one registry for detached shell jobs an agent starts with `bash`'s `run_in_background`).
The registry module itself owns the job map, the GenServer callbacks, the start path, reconciliation and output reading; these children own the separable concerns: the registry TRANSPORT boundary, the completion-notice machinery and the off-process status probe.

## API Surface

| Module | Role |
|---|---|
| `EvoGit.BackgroundJobs.RegistryClient` | The ONE place a `GenServer.call/3` to the registry happens: `call(server, message, timeout) :: {:ok, reply} \| {:error, :registry_unavailable}`, plus `request_tag/1` for the failure log line. One `Logger.warning` per exited call; a request that actually answered (including a semantic `{:error, :not_found}` reply) never logs. |
| `EvoGit.BackgroundJobs.Notice` | Pure notice/retention helpers over the registry state: `terminal?/1`, `live?/1`, `mark_announced/1`, `suppress_notice/1`, `sort_newest_first/1`, `prune_finished/1`, `prune_unknown_since/1`, `finished_key/1`, and the finished-record cap constant. `prune_finished/1` reads exactly `:jobs`, `:probes`, `:unknown_since`, `:notice_table` of that state. |
| `EvoGit.BackgroundJobs.NoticeMirror` | The public ETS mirror of terminal-but-unannounced jobs: `put/2` (written only by the registry's `put_job/2`), `delete`, `clear`, `claim/2` (atomic `:ets.take/2`, exactly-once) and the sort helpers. It is a READ path only — the registry map stays authoritative. |
| `EvoGit.BackgroundJobs.StatusProbe` | The total, call-time-seam backend status probe; for a `:unit` handle it runs in an unlinked task and reports `{:probe_result, job_id, result}` back to the registry's per-job probe cache, so no handler ever blocks on `systemctl`. |

## Error Vocabulary

An unreachable registry is NEVER reported as a missing record: the transport boundary answers `{:error, :registry_unavailable}`, and each public function maps that single shape to its own documented answer.
`job/2` and `kill/3` return `{:error, :registry_unavailable}` verbatim — "the registry is not running, so nothing is known about this id and the job may still be running".
`read/2` and `start_job/1` keep their `{:error, message}` prose contract, so an availability failure becomes one actionable sentence.
`list/1` and `snapshot/1` answer `[]` and `reap_under/1` answers `:ok` — a list- or admin-shaped API never raises and never blocks on a dead registry.
`{:error, :not_found}` therefore means ONLY "an id the registry really does not know"; `{:error, :not_owner}` is the ownership fence and `{:error, {:already_finished, job}}` the idempotent kill.

## Constraints

- A closed observer port answers `nil` from `Port.info/1` and does NOT raise, so the observer probe is an explicit `case` with no `rescue`: an unexpected raise must surface instead of being silently reinterpreted as "observer dead", which would let the unknown-grace floor terminally settle a job whose observer is still alive.
- `port_open?/1` is `@doc false` public purely as a test seam; the GenServer's callbacks, start path, reconcile/probe machinery and output reading stay private in the parent module.
- Every registry request goes through `RegistryClient` — never a direct `GenServer.call/3` — so a dead/absent registry can neither exit a caller nor be misreported as a missing record.
- `claim_finished_notices/1` is a PURE `:ets` read of `NoticeMirror`, never a registry call, which is what makes it exactly-once and immune to a slow registry; the follow-up mark is ONE `GenServer.cast/2`.
- Announcement (`announced`) means "the owner already knows this job's outcome": it starts `false` and is set by that claim, by `read/2` / `list/1` for the terminal jobs they return, and by a successful `kill/3` (including `{:already_finished, job}`).
- All call-time seams are app-env only (no TOML keys) so the suite stays async-safe: `:background_wait_default_ms`, `:background_wait_max_ms`, `:background_poll_interval_ms`, `:background_tick_interval_ms`, `:background_probe_min_interval_ms`, `:background_unknown_grace_ms`, `:process_manager`.

## Design Decisions

- The transport failure has its OWN value rather than a per-site fallback decided at the socket: four different collapsed shapes from one layer is how an agent was once told "no such job" while its jobs were still running and unkillable through that path.
- `Notice` exists so the parent stays a process/state core: the record-shape predicates and the retention caps are pure functions over a job map, shared with `NoticeMirror` so `terminal?/1` has ONE definition.

## Routing Table

No child directories — helper modules only.
Cross-node contracts: the parent `EvoGit.BackgroundJobs` (`../background_jobs.ex`), the Job tools that consume these answers (`../../agent/tools/`), and `EvoGit.ProcessManager` (`../process_manager/`), which owns each job's `:background_job` execution and routes a manager-initiated kill back into `EvoGit.BackgroundJobs.kill/3`.
