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

The `:node_aware_reload_tasks` handler performs a **synchronous full-page
reload** (`reload_current_page/1` → `sync_apply_page/2`: task page, pagination
counters, project paths, filtered view) plus the sidebar running/pending reload
(`NodeAware.reload_tasks/1`), then clears `:tasks_reload_pending`. This single
debounced reload serves BOTH local and remote nodes. Unexpected messages fall
through to the catch-all `handle_info(_msg, socket)` clause.

## Async page load

- `start_async_page_load/3` spawns a supervised `EvoDash.TaskSupervisor` task
  (the LiveView never blocks on cross-node RPCs); the result arrives as
  `{:tasks_page_loaded, seq, node, result}` with
  `result = {:ok, %{tasks:, current_page:, total_count:, total_pages:, project_paths:}} | {:error, :load_failed}`
  and is stale-guarded by the monotonic `tasks_load_seq` (stale seq or wrong
  node → dropped). `show_loading?` controls the "Loading tasks..." placeholder
  (user-initiated loads only). A dropped result leaves `tasks_loading` true
  until the newest in-flight load applies (every spawned task sends a result,
  so the loading state can never wedge).
- Mutating events (cancel / force-kill / delete / clear-history) and the
  debounced PubSub reload use the synchronous `reload_current_page/1` /
  `sync_apply_page/2` path (no loading state, no seq bump) — documented
  decision: immediate feedback.

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
- **`get_unique_paths/1`** — re-fetched inside every page apply (second RPC per load beyond the paginated query; not cached across reloads). Fully consumed as `@project_paths` → filter-dropdown labels + active-filter badge.
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
  placeholder disappears.
- New-shape events are injected manually —
  `Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, status, node()})`
  (the `:evo_git` emitters are tested in their own workstream).
- Debounce assertions use the two-phase `wait_until` helper: first
  `assigns[:tasks_reload_pending] == true` (event processed + node filter
  matched + debounce scheduled), then `== false` (debounce fired + reload
  completed); content assertions confirm the reload took effect. Foreign-node
  events: sample `tasks_reload_pending == false` across the whole debounce
  window + assert content unchanged.
- Store fixtures: `insert_fixture!/1` writes `%EvoGit.TaskInfo{}` rows directly
  via `EvoGit.Store.put_task` (bypasses the async task spawn); deletions via
  `EvoGit.Store.delete_task/2`.

## Constraints

- Do NOT reintroduce polling (`:remote_poll` / `Process.send_after` self-ticks)
  or the DirtyTracker module — push events are the single change-detection
  mechanism.
- The node filter lives in `NodeAware.handle_task_info/2` (shared by every
  consumer of the `"tasks"` topic) — TasksLive only forwards and reloads.
- Task cards need FULL TaskInfo structs (logs/usage/archive_metadata), so the
  page loads `list_tasks_paginated/2` — never degraded summaries.
- Modal state assigns are server-side (no custom JS); follow the warning-modal
  pattern for any new destructive action.
