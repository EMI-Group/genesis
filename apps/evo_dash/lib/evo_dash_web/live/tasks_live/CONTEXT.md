# TasksLive — Tasks Page

## Intent

Support documentation for `EvoDashWeb.TasksLive` (`tasks_live.ex`), the
cross-project task list page (`GET /tasks`): filtering by status, project, and
review state, search, server-side pagination, expandable task cards, and task
actions (graceful cancel, force kill, delete, clear history). Node-aware — reads
task history via `EvoDash.NodeContext` for both the local BEAM node and a remote
`genesis_remote` daemon.

## Routing Table

- (leaf) `tasks_live.ex` — the TasksLive LiveView; no support modules.

## Push-based change detection (no polling)

TasksLive is FULLY push-based — there is no remote poll and no dirty tracker.
`:evo_git` emits task events on the `EvoGit.PubSub` `"tasks"` topic in the
node-identity contract:

- `{:task_updated, task_id, status, node}` — `status` is the task status atom
  (`:pending|:running|:finalizing|:cancelling|:completed|:failed|:cancelled`) or
  `nil` for review-only mutations
- `{:task_deleted, task_id, node}`

`node` is the BEAM node atom of the publisher. TasksLive forwards these messages
VERBATIM to `EvoDashWeb.LiveHooks.NodeAware.handle_task_info/2` (returns
`{:noreply, socket}` — call sites return its value directly, never re-wrap),
which:

1. applies the **node filter** (`event_from_current_node?/2` — event node vs
   `socket.assigns[:current_node]`; local viewing → `node()`, remote → the
   remote daemon's BEAM atom). Foreign-node events are dropped BEFORE the
   debounce is scheduled, so they can never trigger a UI update.
2. schedules a **trailing-edge 300ms debounce** (`:node_aware_reload_tasks`
   message + `:tasks_reload_pending` flag) coalescing broadcast bursts into one
   reload.

The `:node_aware_reload_tasks` handler (`:579-598`) then goes entirely through
**off-process paths — it never touches the store**:

- the page refresh is handed to `start_async_page_load(socket,
  socket.assigns.current_page, false)` (the async path, `show_loading? false`
  keeps the stale rows visible until the fresh page arrives);
- the sidebar running/pending reload is `NodeAware.reload_tasks/1` (itself
  async);
- then `NodeAware.clear_task_reload_pending/1` clears the debounce flag, so the
  flag is cleared the moment the reload is DISPATCHED — a later broadcast burst
  re-schedules as usual.

This single debounced reload serves BOTH local and remote nodes. Unexpected
messages fall through to the catch-all `handle_info(_msg, socket)` clause.

**Coalescing**: the debounce flag gates bursts, and the page-load stale-guard
gates overlapping loads — a burst arriving while a page load is still in flight
spawns a new load (bumping the counter) whose result wins, and the superseded
result is dropped. Both loads this handler spawns (page + sidebar) are
independent, see "Two independent load counters" below.

## Async page load (the only page-load path)

- `start_async_page_load/3` (`:1059-1072`) bumps the monotonic `:page_load_seq`,
  optionally sets `:tasks_loading`, and hands the work to `spawn_page_load/1` →
  `run_page_load/6` (`:1087-1117`), which runs the fetch in a supervised
  `EvoDash.TaskSupervisor` task. The LiveView process NEVER blocks on the store.
  The result arrives as `{:tasks_page_loaded, seq, node, result}` with
  `result = {:ok, %{tasks:, current_page:, total_count:, total_pages:, project_paths:}} | {:error, :load_failed}`
  and is stale-guarded by `:page_load_seq` + the node identity (stale seq or
  wrong node → dropped). `show_loading?` controls the "Loading tasks..."
  placeholder (user-initiated loads only). A dropped result leaves
  `tasks_loading` true until the newest in-flight load applies (every spawned
  task sends exactly one result, so the loading state can never wedge).
- **Kickoff is connected-mount-gated** (`handle_params/3`, `:526-538`):
  `handle_params/3` runs on BOTH the disconnected (static HTTP) render and the
  connected mount, and a disconnected render's async result is discarded, so
  the load is spawned ONLY when `connected?(socket)`. The else branch just
  assigns `:tasks_loading, true` so the static HTML paints the same loading
  placeholder the connected render replaces. Exactly ONE page load per
  navigation; connected `push_patch` (pagination) and every filter event still
  load normally (the guard is `connected?/1`, not a first-only flag).
- **Two independent load counters**: `:page_load_seq` belongs to the page load
  (`start_async_page_load/3` is its only writer); `:tasks_load_seq` belongs to
  `NodeAware`'s sidebar "Active Tasks" fetch (`request_tasks_load/1` is its only
  writer, and `handle_tasks_result/2` requires an exact match). The debounced
  reload spawns BOTH loads, so a shared counter would make each load's bump
  invalidate the other's in-flight result. Never merge them; never bump
  `:tasks_load_seq` from this file.
- `spawn_page_load/1` (`:1080-1083`) wraps the spawn in the
  `:tasks_page_load_hook` app-env seam (1-arity, default identity), resolved at
  spawn time like EvoDash's other runner seams (`:github_runner`,
  `:update_check_runner`). It exists so tests can count page-load spawns.

## Load-cost profile (no blocking store work in the LiveView)

- **`mount/3`** (`:457-506`) runs NO store query. `project_paths` is seeded `[]`
  and filled by the async load's `get_unique_paths/1` result — a mount-time
  `get_unique_paths/1` would be both redundant (the async load re-fetches it)
  and wrong (at mount the node context is still local, before `handle_params/3`
  resolves `?node=`). `mount/3` does call `Helpers.config_status/0` →
  `EvoGit.Config.config_status/0` synchronously (local; persistent_term-cached
  file read).
- **`handle_params/3`** issues at most ONE async page load per navigation, and
  none on the disconnected render.
- **The debounced PubSub reload** routes through `start_async_page_load/3`, so a
  `{:task_updated, ...}` burst never puts a query on the LiveView process.
- The ONLY remaining synchronous store reads are the user-initiated mutating
  events (cancel / force-kill / delete / clear-history) via
  `reload_current_page/1` → `sync_apply_page/2` (`:1020-1046`) — low-volume
  one-shot actions where the inline round-trip buys immediate feedback.
  `sync_apply_page/2` deliberately does not touch `:tasks_loading` or
  `:page_load_seq` (the async path owns those).
- The rendered list is a plain assign (`@filtered_tasks`) re-rendered with
  `Enum.with_index` + `for` (`:245`) — NOT a LiveView stream.
- Per-load SQL cost, the single `pool_size: 1` DBConnection, and the inline-Store
  `get_unique_paths` scan: `apps/evo_git/lib/evo_git/store/CONTEXT.md`.

## Measured load profile (isolated harness, copy of the live DB: 854 rows / 29.7 MB)

Medians from a read-only `mix run` harness (`Phoenix.LiveViewTest.live/2`)
against a COPY of the live `tasks.sqlite`, exercising the real async /
`TaskSupervisor` path:
- `live(conn, "/tasks")` (connected mount + first render in the loading state)
  ≈ 8 ms; user-visible first paint ≈ **24 ms**. Pure `render(view)` of 24 cards
  ≈ 2 ms; one collapsed `TaskCardComponents.task_card` ≈ 0.03–0.07 ms — per-card
  render is NOT a bottleneck (cost/usage/cache/archive/diff are gated behind the
  expanded state).
- Default (unfiltered) page query `list_tasks_paginated` ≈ **1.6 ms**;
  `get_unique_paths/1` ≈ 0.14 ms; `config_status/0` ≈ 0.25 ms.
- Sidebar `list_tasks_summary` (752 rows incl. `:completed`) ≈ **20–24 ms**, run
  async but holding the single Store GenServer for its whole duration; the page's
  DB query measures ~1.8 ms alone vs ~12 ms while the summary is in flight.
- A **filtered** page load is DB-bound, not render-bound: `status = "completed"`
  → **~140–180 ms** LiveView round trip (vs `status = "failed"` ~1.5 ms). Root
  cause lives in the core (evo_git) read path — see
  `apps/evo_git/lib/evo_git/store/CONTEXT.md` → "Measured Performance Profile".

## `:reflect` tasks hidden by default (reveal toggle)

The Tasks page hides `:reflect` tasks (repo-less Home-chat / self-reflective
agent chat tasks) by default so they don't pollute the cross-project task
list. Page-local filter state `@show_reflect_tasks` (default `false`, seeded in
`mount/3` with the other filters) drives it; the filter-bar checkbox
(`name="show_reflect_tasks"`, `value="true"`, `phx-change="toggle_reflect_tasks"`,
gettext label "Show chat tasks") reveals them when checked. The handler parses
`params["show_reflect_tasks"] not in [nil, "false"]` (a checked box sends
`"true"`, an unchecked box is absent from FormData) and reloads via
`start_async_page_load(1, true)`.

The exclusion is applied **client-side post-load** by `visible_tasks/2`
(`Enum.reject(tasks, &(&1.type == :reflect))` when hiding) at the two choke
points where loaded page rows become the displayed list: the async
`{:tasks_page_loaded, ...}` handler and `sync_apply_page/2` (both `:tasks` and
`:filtered_tasks` get the post-load filtered list). This is because the SQL
`filters` keyword (`build_filters_from_assigns/1`) cannot express "exclude
type" — the WHERE builder lives in the read-only sibling app `evo_git`. Rows
are full `%TaskInfo{}` structs so `type` is already a decoded atom (no atom
conversion). `@total_count`/`@total_pages`/pagination stay SQL-truthful and
untouched — a page may show slightly fewer cards when reflect rows are
dropped (accepted by design).

The toggle is a **reveal preference, not a narrowing filter**: it survives
pagination `push_patch`es and filter reloads (it is a plain socket assign,
never cleared by `handle_params/3`), it is NOT reset by `reset_filters`, and
it does NOT appear in the active-filters indicator. When the reflect-hiding
empties the list with no other filter active, the empty-state shows "Try
adjusting your filters or search query." instead of the start-tasks hint
(`not @show_reflect_tasks` added to the first branch's condition).

## RPC payload audit (transferred vs consumed)

All data access goes through `EvoDash.NodeContext` → `EvoGit.RemoteNode` (local
direct call or `:erpc`) → `EvoGit.AgentScheduler.RemoteAPI` → `EvoGit.TaskRegistry` → `EvoGit.Store`:

- **`list_tasks_paginated/2`** — page data; opts `[limit: 25, offset: (page-1)*25, filters: [status:, project_path:, review_status:, search:]]` (`build_filters_from_assigns`; `"all"`/`""` passthrough handled in `EvoGit.Store.Queries.build_where`). Returns FULL `%TaskInfo{}` structs + total_count.
  - **Search surface**: the `search:` filter (the page's search box) is executed in `EvoGit.Store.Queries.build_where/1` (evo_git-owned, sibling app) as a case-insensitive raw-JSON SQL LIKE over the `id`, `opts`, `project_path`, and `result` columns — so the search box also matches the agent response message (the result's `"result"` data key). Fields consumed by `task_card_components.ex`: `type`, `opts`, `id`, `review_status`, `status`, `started_at`, `finished_at`, `agent_count`, `result`, `error`, `usage`, `model_id`, `logs`, `archive_metadata` — `error` is the structured failure record map read for failed-task display (`nil` unless the task is `:failed`). NOT consumed: `project_path`, `base_sha`, `commit_sha`, `lease_expires_at`, `updated_at`. Heavy fields are transferred for all 25 rows even when every card is collapsed (known future optimization: summary projection + `get_task` on expand — not implemented).
- **Multi-repo `repos` result key** — task results may carry a top-level `repos` map (STRING keys): `%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}` — `"primary"` ALWAYS present (branch_name nil when the primary produced no changes), each writable foreign repo that produced commits present, read-only repos ABSENT. Top-level `commit_sha`/`branch_name` remain the PRIMARY repo's. Legacy tasks have NO `repos` key — rendered unchanged. TasksLive does not touch `repos` itself: it loads the full `result` via `list_tasks_paginated/2` (Codec round trip keeps the top-level `"repos"` key STRING-keyed — unknown result keys are never atomized) and `task_card_components.ex` renders it (`result_repos/1` + `result_repos_badges/1`).
- **`get_unique_paths/1`** — fetched ONCE per page load, inside the async load task (`run_page_load/6`, `:1094`) — `mount/3` does NOT call it (see "Load-cost profile"). Result assigned as `@project_paths` → filter-dropdown options + active-filter badge. The synchronous `sync_apply_page/2` path (`:1044`, mutating events only) re-fetches it inline.
- **`cancel_task/2` / `force_kill_task/2` / `delete_task/2` / `clear_finished_tasks/1`** — phx-event triggered; return `:ok | {:error, reason}` — only the status consumed (`:ok` → collapse card + sync reload; error → gettext flash with `inspect(reason)`); delete/clear ignore the return.
- **`list_task_ids/2`** (id/status/updated_at projection) — NOT called from tasks_live.ex; the only dashboard consumer is SystemLive's update card.
- **`list_tasks_changed_since/2`** — not called anywhere in the dashboard (change detection is broadcast-driven).

**Store projections (3 shapes)** — `EvoGit.Store` summary queries never decode the result blob:
- *Summary* (16 keys, no result): `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error` — `error` is the structured failure record map (ATOM-keyed after decode, `nil` unless the task is `:failed`; see "Failed-task error rendering"); consumed by the NodeAware sidebar loader and `show_review_button?/1` (summary-based on `status`/`type`).
- *Id-only*: `list_task_ids/2` — id+status+updated_at, no result/opts decode.
- *Full*: `list_tasks_paginated/2` / `get_task/1` — `Codec.decode_result` (rebuilds `%Usage{}` + archive_records) runs per row.

## Task cancellation UX (graceful cancel + force kill)

Two two-step server-side confirmation-modal flows (SystemLive warning-modal pattern; NO custom JS — assigns drive visibility):

- **Graceful cancel** (card's inline Cancel button, visible `[:pending, :running]`): `open_cancel_modal` → assign `:confirm_cancel_task_id`; `confirm_cancel_task` → `EvoDash.NodeContext.cancel_task(current_node, task_id)` (GRACEFUL — agents save + exit, result preserved; `:pending` → immediate `:cancelled`); `:ok` → collapse expanded card + `reload_current_page/1`; error → flash `gettext("Failed to cancel task: %{reason}", reason: inspect(reason))`. Modal: title `gettext("Cancel Task?")`, confirm `gettext("Cancel Task")` (`btn-warning`), dismiss `gettext("Keep Running")`.
- **Force kill** (card's three-dot dropdown, visible `[:running, :cancelling]`, "Danger zone" divider): `open_force_kill_modal` → assign `:confirm_force_kill_task_id`; `confirm_force_kill_task` → `EvoDash.NodeContext.force_kill_task(current_node, task_id)` (BRUTAL — kills all agents, result nil'd; escalation from `:cancelling`); same `:ok` collapse+reload / error-flash handling. Modal: title `gettext("Force Kill Task?")`, confirm `gettext("Force Kill")` (`btn-error`).
- **Modal-state lifecycle**: both assigns seeded `nil` in `mount/3`, MUTUALLY EXCLUSIVE (opening one clears the other), cleared on node switch in `handle_params/3`. Nil-guarded confirms are no-ops.
- **Status filter**: includes `gettext("Cancelling")` (`value="cancelling"`); pure SQL string comparison (`EvoGit.Store.Queries.build_where`), so `:cancelling` round-trips — no evo_dash-side atom whitelist.
- **`:cancelled` reviewability**: gracefully-cancelled tasks ARE reviewable — the card Review button shows for every `:completed`/`:cancelled` task (repo-less `:reflect` excluded); a `:cancelled` task without a branch still opens the review page (no-changes).

## ModalHelpers

`EvoDashWeb.ModalHelpers` (`live/modal_helpers.ex`) — a `__using__` macro injecting shared modal event handlers (`view_full_result/2`, `close_result_modal/1`, `view_full_options/2`, `close_options_modal/1`) into a host LiveView. **Only TasksLive uses it** (ProjectsLive does not). The injected helpers read `socket.assigns.tasks` (the full TaskInfo page list). The two zoom modals (Full Result `gettext("Task Result")`, Full Objective `gettext("Full Objective")`) each carry a ClipboardCopy button in the `<:actions>` slot (`id="full-result-copy"` → `TaskCardComponents.result_copy_text(@selected_result)`; `id="full-options-copy"` → `@selected_options`), and TasksLive implements the required `handle_event("copied", ...)` → "Copied to clipboard" flash handler.

## Failed-task error rendering (legacy error result + structured failure record)

A `:failed` task can surface its failure through TWO separate records: the legacy
`{:error, reason}` / `{:exit, reason}` task RESULT shape and the structured
`error` map field on the decoded TaskInfo.
Both records may coexist, and a `:failed` task may carry either, both, or neither
(the structured record may be nil on legacy failed rows).
`error` (ATOM keys after decode) is `%{kind: atom, source: atom, message: String.t(), stacktrace: [String.t()] | nil}` —
`kind` ∈ `:error | :exit | :down | :force_kill | :timeout | :restart | :lease_expired | :recheck`,
`source` ∈ `:result_handler | :down_handler | :force_kill_task | :finalizing_watchdog | :startup_reconcile | :lease_sweep | :recheck_resolve`.
It is `nil` on every non-`:failed` row and rides on BOTH read paths: the full
`%TaskInfo{}` decode and the 16-key summary projection.

- tasks_live.ex NEVER reads `task.result` / `task.error` itself — every row is
  delegated whole to `EvoDashWeb.TaskCardComponents.task_card task={task} show_details=... current_node_id=...`
  (`tasks_live.ex:250-254`); all failure reading/rendering lives in the component.
- COLLAPSED `:failed` card (legacy shape): status badge via
  `Helpers.task_status_badge(:failed)` = `bg-error/10 text-error` (helpers.ex:108-109);
  accent bar `task_accent_color/1` → `Helpers.task_status_dot_class(:failed)` = `bg-error`
  (task_card_components.ex:27/489; helpers.ex:134);
  card tint `task_card_tint/1` → `Helpers.task_status_tint(:failed)` = `bg-error/5 shadow-error/10 border-error/20`
  (task_card_components.ex:23/506; helpers.ex:149);
  badge text = raw atom `{@task.status}` → "failed" (task_card_components.ex:77-84).
  For this shape no error text is visible in the collapsed state.
- COLLAPSED `:failed` card WITH a structured `error` map: additionally renders a
  compact error-tinted failure line visible without expanding — the truncated
  `error.message` (`Helpers.truncate_string/2`, ~160 chars), styled consistently
  with the failed-task tint/badge conventions.
  `error` nil/non-map → nothing extra (legacy cards unchanged).
- EXPANDED card (legacy result shape): the "Agent Message" section is gated on
  truthiness `Map.get(@task, :result)` (task_card_components.ex:252) — an
  `{:error, _}` tuple is truthy so the section renders; body =
  `render_result(@task.result)` (task_card_components.ex:281), which dispatches to
  the `render_result({:error, reason}, opts)` clause (task_card_components.ex:688-715):
  a red `bg-error/10 border border-error/20` box headed `gettext("Error")`
  (hero-x-circle icon) with `<pre>` `inspect(reason, limit: :infinity)`.
  `{:exit, reason}` renders a "Crashed" box (task_card_components.ex:717-744).
  `:failed` with nil result (the legacy force-killed shape) → section hidden.
- EXPANDED card WITH a structured `error` map: renders a full-detail error block —
  the kind label + source label caption via `Helpers.task_error_kind_label/1` +
  `Helpers.task_error_source_label/1` (human gettext labels; unknown atoms → safe
  generic fallback), the full untruncated `error.message`, and when `stacktrace`
  is a non-empty list its last ≤8 frames as monospace (`<pre>`-style) lines.
  The container is error-tinted, consistent with the legacy
  `render_result({:error, _}, ...)` "Error" box styling.
- Guards are read-only (`status == :failed and is_map(error)` + `Map.get`) and
  tolerant of nil/non-map/legacy shapes on BOTH the 16-key summary projection
  and full `%TaskInfo{}` rows.
- Full Result modal (legacy result shape): `view_full_result/2` (ModalHelpers —
  finds the task in `socket.assigns.tasks`, assigns `selected_result = Map.get(task, :result)`);
  the modal (gated `if @selected_result`, tasks_live.ex:327-346) renders via
  `TaskCardComponents.render_result_full(@selected_result)` (tasks_live.ex:333 →
  task_card_components.ex:982-984, the `truncate: false` variant);
  the Copy button payload = `result_copy_text/1` — for `{:error, reason}` that is
  `inspect(reason, limit: :infinity)` (task_card_components.ex:995).
  The only UI entry to the modal is the "Full" button inside an EXPANDED card's
  Agent Message section (task_card_components.ex:270-278).
- `show_review_button?/1` (task_card_components.ex, private) matches EVERY
  `:completed`/`:cancelled` task except repo-less `:reflect` (`type: :reflect`)
  — a `:failed` task NEVER gets a Review link/navigation on this page
  (test-pinned in `tasks_live_test.exs`).
  Legacy error text is reachable only via the Details toggle and the modal.
- Legacy result decoded-shape note (evo_git codec contract, codec.ex):
  `{:error, reason}` persists tagged `{"__result_tag__":"error","reason":...}`;
  when `reason` is not JSON-safe (e.g. a tuple `{128, "fatal: ..."}`) the encode
  falls back to storing `inspect(reason)` as the reason string (codec.ex:413-424)
  and `decode_reason/1` keeps unknown strings as-is (codec.ex:532-540) → the
  dashboard sees `{:error, "{128, \"fatal: ...\"}"}` and displays that inspected
  string verbatim in the Error box.
  An improved core error message reaches the user verbatim as long as it ends up
  inside the persisted error reason.
- Test pin: `tasks_live_test.exs:1184-1200` asserts an `{:error, "explosion happened"}`
  result renders "Agent Message" + "Error" + the reason text, with the copy payload
  containing the reason.
  No test covers tuple-shaped reasons (they render as their inspect-string after
  the codec round trip).
- render_result clause safety (legacy result path): the catch-all
  `render_result(result, opts)` (task_card_components.ex:956-976) pretty-inspects
  any non-tuple/non-map shape, so no stored result shape can crash a task card.

## Test idioms

- `flush_tasks_load/2` (delegates to `EvoDashWeb.TestHelpers.flush_loading/4`)
  waits for the async page load by polling until the "Loading tasks..."
  placeholder disappears, then awaits `:tasks_loading == false` and re-renders.
- `render_tasks_list/1` (`view |> element("#tasks-list") |> render()`) scopes
  list-content assertions away from the SIDEBAR, which also lists `:completed`
  tasks and can show a row before the page reload lands.
- `wait_for_list/3` polls the `#tasks-list` container until a needle appears
  (each render is a synchronous round-trip that drains the LiveView mailbox) —
  use it whenever an ASYNC reload's effect is being awaited.
- `install_page_load_hook/0` wraps the `:tasks_page_load_hook` seam so a test
  receives a `:page_load_spawned` message per page-load spawn, and asserts the
  counter via `:sys.get_state(view.pid).socket.assigns.page_load_seq`.
- New-shape events are injected manually —
  `Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, status, node()})`
  (the `:evo_git` emitters are tested in their own workstream).
- Debounce assertions use the two-phase `wait_until` helper: first
  `assigns[:tasks_reload_pending] == true` (event processed + node filter
  matched + debounce scheduled), then `== false` (debounce fired + the ASYNC
  reload DISPATCHED — the fresh page arrives later, so follow with
  `wait_for_list/3`). Foreign-node events: sample
  `tasks_reload_pending == false` across the whole debounce window + assert
  content unchanged.
- **Proving the reload is off-process**: `:sys.suspend(EvoGit.TaskRegistry)`
  freezes the serialized registry so ANY synchronous read blocks there (30s call
  timeout). The debounced handler must still complete (flag cleared +
  `page_load_seq` advanced) with the reloaded rows NOT applied, then
  `:sys.resume(EvoGit.TaskRegistry)` lets the off-process load land. Always pair
  the suspend with an `on_exit` resume (the `setup/1` isolation teardown runs
  later, LIFO).
- Store fixtures: `insert_fixture!/1` writes `%EvoGit.TaskInfo{}` rows directly
  via `EvoGit.Store.put_task` (bypasses the async task spawn, so it emits no
  broadcast); deletions via `EvoGit.Store.delete_task/2`.

## Load path & round-trip inventory (per page render)

Every load goes `EvoDash.NodeContext.<f>` (local direct / remote `:erpc`) →
`EvoGit.RemoteNode` → `EvoGit.AgentScheduler.RemoteAPI` → `EvoGit.TaskRegistry`
→ `EvoGit.Store`. In the core the Store is ONE GenServer over a SINGLE SQLite
connection (`pool_size: 1`), so all of these reads serialize with each other and
with heartbeat/lease/cleanup writes:
- **`list_tasks_paginated/2`** — `load_page/4` (`tasks_live.ex:971-997`; opts
  `[limit: 25, offset: (page-1)*25, filters: build_filters_from_assigns/1]`) →
  `TaskRegistry.list_tasks_paginated/1` → `Store.safe_select_paginated_tasks/2`.
  Issues **TWO SQL statements** (page `SELECT` with `ORDER BY started_at DESC
  LIMIT/OFFSET` **+ a separate `COUNT(*)` re-applying the same filters**) and
  decodes a FULL `%TaskInfo{}` per row (incl. `result`/`usage`/`archive_metadata`
  JSON) for all 25 rows. A `search` filter is a leading-wildcard OR-`LIKE` over
  `id`/`opts`/`project_path`/`result` (full-table scan) executed in BOTH
  statements. On a stale/clamped page (`:983-993`) the whole paginated call runs
  a SECOND time (`COUNT` re-run too).
- **`get_unique_paths/1`** — called ONCE per page load inside the async task
  (`run_page_load/6:1094`) and synchronously in `sync_apply_page/2:1044`
  (mutating events only) → `TaskRegistry.get_unique_paths/0` →
  `Store.select_task_paths/1` (`SELECT DISTINCT project_path`). Handled INLINE
  in BOTH core GenServers (NOT offloaded like the paginated read), so it blocks
  the registry + store while the paginated read may also be in flight — hence
  never issuing it from `mount/3`.
- **`config_status/0`** — `mount/3:462` → `EvoDashWeb.Helpers.config_status/0`
  (`helpers.ex:672`) → `EvoGit.Config.config_status/0`: SYNCHRONOUS in mount,
  re-reads config.toml + credentials.toml.
- **Sidebar load** — `NodeAware.on_mount` spawns
  `TaskRegistry.list_tasks_summary(@active_statuses)` async (its own
  `:tasks_load_seq` counter); `assign_node/2` re-spawns it on a node-context
  change, and the debounced reload re-spawns it via `reload_tasks/1`.

Minimum cost per navigation: 3 SQL statements (page `SELECT` + `COUNT` +
`DISTINCT paths`) across 2 core RPCs, all OUTSIDE the LiveView process; 4
statements when `load_page/4` fetches twice. Mutating events add the same 3
statements inline.

## Synchronous vs async in the LiveView

- **ASYNC (`EvoDash.TaskSupervisor`)**: `start_async_page_load/3` (`:1059-1072`)
  → `run_page_load/6` — the connected mount, `push_patch` pagination, every
  filter/search/toggle event, AND the debounced PubSub reload. Result arrives as
  `{:tasks_page_loaded, seq, node, result}`, stale-guarded by `:page_load_seq`.
- **SYNCHRONOUS in the LiveView process**: `mount/3`'s `config_status/0`; and
  `reload_current_page/1` → `sync_apply_page/2` (`:1020-1046`), which runs the
  full paginated query + `get_unique_paths` inline. Used ONLY by the
  user-initiated mutating events (cancel / force-kill / delete / clear-history).

## PubSub refetch behaviour

Every node-matching `{:task_updated, _, _, _}` / `{:task_deleted, _, _}`
triggers a page refresh: `NodeAware.handle_task_info/2` (`node_aware.ex:733-751`)
node-filters then debounces 300ms (`debounce_task_reload/1`, coalescing bursts),
and the `:node_aware_reload_tasks` handler (`tasks_live.ex:579-598`) dispatches
the ASYNC page reload (`start_async_page_load/3`, `show_loading? false`) plus the
async sidebar reload (`NodeAware.reload_tasks/1`), then clears the debounce flag.
A source emitting events across ≥300ms windows produces one reload dispatch per
window (a burst inside an already-in-flight load still spawns a new load whose
result supersedes the older one via `:page_load_seq`).

## No per-task N+1 I/O in the list path

`EvoDashWeb.TaskCardComponents.task_card/1` (`task_card_components.ex:19`)
performs NO git subprocess, `File.stat`/`exists?`, `System.cmd`, or
`NodeContext` call — cards render the already-loaded `%TaskInfo{}` (verified: no
`rev_parse|System.cmd|File.stat|NodeContext|Port.open` in that file). No
per-visible-task follow-up RPC exists; the per-row cost is the core-side
`Codec.decode_task/1` blob decode, not an extra round trip.

## Constraints

- Do NOT reintroduce polling (`:remote_poll` / `Process.send_after` self-ticks)
  or the DirtyTracker module — push events are the single change-detection
  mechanism.
- Keep the page load ASYNC and connected-gated: `handle_params/3` must only spawn
  behind `connected?(socket)`, and the debounced reload must go through
  `start_async_page_load/3` — never `reload_current_page/1`. The synchronous
  path exists solely for the user-initiated mutating events.
- `:page_load_seq` and `:tasks_load_seq` are INDEPENDENT stale-guards (page load
  vs `NodeAware` sidebar fetch). Never merge them and never bump
  `:tasks_load_seq` from this file.
- The node filter lives in `NodeAware.handle_task_info/2` (shared by every
  consumer of the `"tasks"` topic) — TasksLive only forwards and reloads.
- Task cards need FULL TaskInfo structs (logs/usage/archive_metadata), so the
  page loads `list_tasks_paginated/2` — never degraded summaries.
- Modal state assigns are server-side (no custom JS); follow the warning-modal
  pattern for any new destructive action.
