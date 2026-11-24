# BackgroundJobs helpers — transport, notices, retention, status probing

## Intent

Helper modules behind `EvoGit.BackgroundJobs` (the one registry for detached shell jobs an agent starts with `bash`'s `run_in_background`).
The registry module itself owns the job map, the GenServer callbacks, the start path, reconciliation and output reading; these children own the separable concerns: the registry TRANSPORT boundary, the completion-notice machinery, the finished-record RETENTION policy with its tombstones, and the off-process status probe.

## API Surface

| Module | Role |
|---|---|
| `EvoGit.BackgroundJobs.RegistryClient` | The ONE place a `GenServer.call/3` to the registry happens: `call(server, message, timeout) :: {:ok, reply} \| {:error, :registry_unavailable}`, plus `request_tag/1` for the failure log line. One `Logger.warning` per exited call; a request that actually answered (including a semantic `{:error, :not_found}` reply) never logs. |
| `EvoGit.BackgroundJobs.Notice` | Pure notice/announce helpers over the registry state: `terminal?/1`, `live?/1`, `mark_announced/1`, `suppress_notice/1`, `sort_newest_first/1`, `prune_unknown_since/1`, `finished_key/1`. Retention itself lives in `Retention`. |
| `EvoGit.BackgroundJobs.Retention` | The finished-record retention policy and the tombstones: `defaults/0`, `from_opts/1`, `prune/1`, `tombstone?/1`, `fetch_tombstone/2`, `update_tombstone/2`. `prune/1` reads/writes exactly `:jobs`, `:probes`, `:unknown_since`, `:notice_table`, `:tombstones`, `:retention` of the registry state. |
| `EvoGit.BackgroundJobs.NoticeMirror` | The public ETS mirror of terminal-but-unannounced jobs: `put/2` (written only by the registry's `put_job/2`), `delete`, `clear`, `claim/2` (atomic `:ets.take/2`, exactly-once) and the sort helpers. It is a READ path only — the registry map stays authoritative. |
| `EvoGit.BackgroundJobs.StatusProbe` | The total, call-time-seam backend status probe; for a `:unit` handle it runs in an unlinked task and reports `{:probe_result, job_id, result}` back to the registry's per-job probe cache, so no handler ever blocks on `systemctl`. |

## Retention Policy (`EvoGit.BackgroundJobs.Retention`)

`Retention.prune/1` runs at the end of every ACCEPTED start (`arm_tick(Retention.prune(state))`) and again after every `{:notices_claimed, owner_pid, ids}` cast, because observed records accumulate on the claim path, not the start path.
It first applies `Notice.prune_unknown_since/1` (unknown-grace markers of no-longer-live jobs are bookkeeping, not records) and then the four caps, every trim oldest-first by `{Notice.finished_key(job), job.id}`.
Live (`:running`/`:stopping`) records are never touched, and a dead owner is one whose `owner_pid` is not a live pid (`nil` counts as dead).
1. `max_dead_per_owner` (10) — per DEAD owner: records beyond the cap are DELETED (map entry, cached probe and notice-mirror row), since a dead owner can neither read them nor claim a notice; this pass runs FIRST.
2. `max_observed_per_owner` (20) — per LIVE owner, over its announced records only: the oldest excess is DELETED.
3. `max_finished_total` (500) — ONE global safety valve over every remaining finished record: observed and dead-owner records are DELETED oldest-first, and only once those are exhausted is a live owner's UNOBSERVED record converted to a TOMBSTONE, oldest-first.
4. `max_tombstones` (200) — tombstones are capped too, evicting the oldest first by `evicted_at` then `id`.
The observation rule outranks caps 2–3: a finished record with `announced == false` whose owner pid is still ALIVE is never evicted by an ordinary cap, no matter how much other agents churn — it leaves ONLY through the tombstone path.

## Tombstones

A tombstone is a JOB-SHAPED map kept for an evicted-but-unobserved record: `id`, `kind`, `label`, `owner_pid`, `status`, `exit_code`, `terminal_reason`, `detail`, `started_at`, `finished_at`, `output_path`, `cursor`, `lines_read`, `announced: true`, `evicted_reason` (`:retention` today) and `evicted_at`.
`Retention.tombstone?/1` is exactly "the map carries `:evicted_reason`", and it is the predicate every consumer branches on.
The registry keeps tombstones in `state.tombstones` and answers them as follows.
`job/2` — a tombstone id answers `{:ok, tombstone}` verbatim (no reconcile, no `put_job/2`), another owner's tombstone answers `{:error, :not_owner}`, and `{:error, :not_found}` is reserved for an id in neither the job map nor the tombstones.
`read/2` — serves the surviving log tail from the tombstone's `output_path` at its saved `cursor` through the same `read_delta/2`, persists the advanced `cursor`/`lines_read` back into `state.tombstones`, and replies `{:ok, %{text: text, job: tombstone}}` (the live-record shape); when the log is gone it answers ONE honest sentence naming the final status (and the exit code when known), that the record aged out of retention, and the former log path — never "no such job".
`list/1` — includes the owner's tombstones (all tombstones when `owner_pid` is nil) merged into the newest-first result, and never reconciles or re-`put`s one.
`kill/3` — answers `{:error, {:already_finished, tombstone}}` and changes neither state nor the notice mirror.
`generate_id/2` — skips an id held by a tombstone as well as one held by `state.jobs`, so an id is NEVER reused while any answer for it exists.
`fetch_owned_record/3` is the ONE jobs-then-tombstones lookup carrying the ownership fence for all four id-addressed handlers.

## Options

`:retention` is a registry START option: a keyword list or map overlaying `Retention.defaults/0` PER KEY (`:max_observed_per_owner`, `:max_dead_per_owner`, `:max_finished_total`, `:max_tombstones`).
An absent key, a non-integer value and a non-positive value each fall back to that key's default, and unknown keys are ignored, so a malformed overlay can never disable the policy.
It is an opt-in overlay for an ISOLATED registry (the suite's `:name` seam), never an app-env or TOML key — which is what keeps the background-job suites `async: true`.

## Error Vocabulary

An unreachable registry is NEVER reported as a missing record: the transport boundary answers `{:error, :registry_unavailable}`, and each public function maps that single shape to its own documented answer.
`job/2` and `kill/3` return `{:error, :registry_unavailable}` verbatim — "the registry is not running, so nothing is known about this id and the job may still be running".
`read/2` and `start_job/1` keep their `{:error, message}` prose contract, so an availability failure becomes one actionable sentence.
`list/1` and `snapshot/1` answer `[]` and `reap_under/1` answers `:ok` — a list- or admin-shaped API never raises and never blocks on a dead registry.
`{:error, :not_found}` therefore means ONLY "an id in neither the job map nor the tombstones"; `{:error, :not_owner}` is the ownership fence and `{:error, {:already_finished, job}}` the idempotent kill.
A retention-evicted record that a live owner has not observed never degrades into a `:not_found`: it stays answerable as a tombstone, and a missing log becomes retention prose instead.

## Constraints

- A closed observer port answers `nil` from `Port.info/1` and does NOT raise, so the observer probe is an explicit `case` with no `rescue`: an unexpected raise must surface instead of being silently reinterpreted as "observer dead", which would let the unknown-grace floor terminally settle a job whose observer is still alive.
- `port_open?/1` is `@doc false` public purely as a test seam; the GenServer's callbacks, start path, reconcile/probe machinery and output reading stay private in the parent module.
- Every registry request goes through `RegistryClient` — never a direct `GenServer.call/3` — so a dead/absent registry can neither exit a caller nor be misreported as a missing record.
- `claim_finished_notices/1` is a PURE `:ets` read of `NoticeMirror`, never a registry call, which is what makes it exactly-once and immune to a slow registry; the follow-up mark is ONE `GenServer.cast/2`.
- Announcement (`announced`) means "the owner already knows this job's outcome": it starts `false` and is set by that claim, by `read/2` / `list/1` for the terminal jobs they return, and by a successful `kill/3` (including `{:already_finished, job}`).
- All REMAINING call-time seams are app-env only (no TOML keys) so the suite stays async-safe: `:background_wait_default_ms`, `:background_wait_max_ms`, `:background_poll_interval_ms`, `:background_tick_interval_ms`, `:background_probe_min_interval_ms`, `:background_unknown_grace_ms`, `:process_manager`; retention is the `:retention` START option instead, with no app-env seam.
- `Retention.prune/1` is bounded work over in-memory maps (no OS call, no file I/O, no timer) and never touches `state.owners`, so running it inside a handler keeps the registry answering.

## Design Decisions

- Retention is OBSERVATION-AWARE because a finished record a live owner has not seen yet is not garbage: it is what that agent's next `job_output` / `job_list` and its pending completion notice depend on.
- One global oldest-first cap over all owners (the retired policy) deleted exactly that record — and its mirror row — while a long-run agent was mid-turn, so the agent was told "no background job with id … is known to this agent" about a job it had just started.
- Eviction therefore splits by OWNERSHIP AND OBSERVATION instead of by raw age: dead owners are trimmed first (they can never read their records), live owners keep the announced history they might re-read, and unobserved live-owner records are protected outright.
- A tombstone replaces a silent delete on the ONE path that may still hit protected records (the global valve): the id, status, exit code and log path survive, so the answer stays honest and the id can never be reissued to a different job.
- A tombstoned record's notice-mirror row is deliberately LEFT INTACT: the owner has still not observed the outcome, so the normal per-turn notice is exactly the delivery the record was protected for; deleting the row would silently convert a protected record into a lost one.
- `Notice` keeps the record-shape predicates so `terminal?/1` has ONE definition shared with `NoticeMirror`, while `Retention` owns the caps — the parent stays a process/state core rather than a policy bin.

## Routing Table

No child directories — helper modules only.
Cross-node contracts: the parent `EvoGit.BackgroundJobs` (`../background_jobs.ex`), the Job tools that consume these answers (`../../agent/tools/`), and `EvoGit.ProcessManager` (`../process_manager/`), which owns each job's `:background_job` execution and routes a manager-initiated kill back into `EvoGit.BackgroundJobs.kill/3`.
