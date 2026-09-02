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

## RPC payload audit (transferred vs consumed)

All data access goes through `EvoDash.NodeContext` → `EvoGit.RemoteNode` (local
direct call or `:erpc`) → `EvoGit.AgentScheduler.RemoteAPI` → `EvoGit.TaskRegistry` → `EvoGit.Store`:

- **`list_tasks_paginated/2`** — page data; opts `[limit: 25, offset: (page-1)*25, filters: [status:, project_path:, review_status:, search:]]` (`build_filters_from_assigns`; `"all"`/`""` passthrough handled in `EvoGit.Store.Queries.build_where`). Returns FULL `%TaskInfo{}` structs + total_count.
  - **Search surface**: the `search:` filter (the page's search box) is executed in `EvoGit.Store.Queries.build_where/1` (evo_git-owned, sibling app) as a case-insensitive raw-JSON SQL LIKE over the `id`, `opts`, `project_path`, and `result` columns — so the search box also matches the agent response message (the result's `"result"` data key). Fields consumed by `task_card_components.ex`: `type`, `opts`, `id`, `review_status`, `status`, `started_at`, `finished_at`, `agent_count`, `result`, `usage`, `model_id`, `logs`, `archive_metadata`. NOT consumed: `project_path`, `base_sha`, `commit_sha`, `lease_expires_at`, `updated_at`. Heavy fields are transferred for all 25 rows even when every card is collapsed (known future optimization: summary projection + `get_task` on expand — not implemented).
- **Multi-repo `repos` result key** — task results may carry a top-level `repos` map (STRING keys): `%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}` — `"primary"` ALWAYS present (branch_name nil when the primary produced no changes), each writable foreign repo that produced commits present, read-only repos ABSENT. Top-level `commit_sha`/`branch_name` remain the PRIMARY repo's. Legacy tasks have NO `repos` key — rendered unchanged. TasksLive does not touch `repos` itself: it loads the full `result` via `list_tasks_paginated/2` (Codec round trip keeps the top-level `"repos"` key STRING-keyed — unknown result keys are never atomized) and `task_card_components.ex` renders it (`result_repos/1` + `result_repos_badges/1`).
- **`get_unique_paths/1`** — re-fetched inside every page apply (second RPC per load beyond the paginated query; not cached across reloads). Fully consumed as `@project_paths` → filter-dropdown labels + active-filter badge.
- **`cancel_task/2` / `force_kill_task/2` / `delete_task/2` / `clear_finished_tasks/1`** — phx-event triggered; return `:ok | {:error, reason}` — only the status consumed (`:ok` → collapse card + sync reload; error → gettext flash with `inspect(reason)`); delete/clear ignore the return.
- **`list_task_ids/2`** (id/status/updated_at projection) — NOT called from tasks_live.ex; the only dashboard consumer is SystemLive's update card.
- **`list_tasks_changed_since/2`** — not called anywhere in the dashboard (change detection is broadcast-driven).

**Store projections (3 shapes)** — `EvoGit.Store` summary queries never decode the result blob:
- *Summary* (15 keys, no result): `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at` — consumed by the NodeAware sidebar loader and `show_review_button?/1` (column-based on `branch_name`).
- *Id-only*: `list_task_ids/2` — id+status+updated_at, no result/opts decode.
- *Full*: `list_tasks_paginated/2` / `get_task/1` — `Codec.decode_result` (rebuilds `%Usage{}` + archive_records) runs per row.

## Task cancellation UX (graceful cancel + force kill)

Two two-step server-side confirmation-modal flows (SystemLive warning-modal pattern; NO custom JS — assigns drive visibility):

- **Graceful cancel** (card's inline Cancel button, visible `[:pending, :running]`): `open_cancel_modal` → assign `:confirm_cancel_task_id`; `confirm_cancel_task` → `EvoDash.NodeContext.cancel_task(current_node, task_id)` (GRACEFUL — agents save + exit, result preserved; `:pending` → immediate `:cancelled`); `:ok` → collapse expanded card + `reload_current_page/1`; error → flash `gettext("Failed to cancel task: %{reason}", reason: inspect(reason))`. Modal: title `gettext("Cancel Task?")`, confirm `gettext("Cancel Task")` (`btn-warning`), dismiss `gettext("Keep Running")`.
- **Force kill** (card's three-dot dropdown, visible `[:running, :cancelling]`, "Danger zone" divider): `open_force_kill_modal` → assign `:confirm_force_kill_task_id`; `confirm_force_kill_task` → `EvoDash.NodeContext.force_kill_task(current_node, task_id)` (BRUTAL — kills all agents, result nil'd; escalation from `:cancelling`); same `:ok` collapse+reload / error-flash handling. Modal: title `gettext("Force Kill Task?")`, confirm `gettext("Force Kill")` (`btn-error`).
- **Modal-state lifecycle**: both assigns seeded `nil` in `mount/3`, MUTUALLY EXCLUSIVE (opening one clears the other), cleared on node switch in `handle_params/3`. Nil-guarded confirms are no-ops.
- **Status filter**: includes `gettext("Cancelling")` (`value="cancelling"`); pure SQL string comparison (`EvoGit.Store.Queries.build_where`), so `:cancelling` round-trips — no evo_dash-side atom whitelist.
- **`:cancelled` reviewability**: gracefully-cancelled tasks ARE reviewable (`show_review_button?/1` matches `:cancelled` with a preserved branch/no_changes result; `:cancelled` without a branch renders as no-changes).

## ModalHelpers

`EvoDashWeb.ModalHelpers` (`live/modal_helpers.ex`) — a `__using__` macro injecting shared modal event handlers (`view_full_result/2`, `close_result_modal/1`, `view_full_options/2`, `close_options_modal/1`) into a host LiveView. **Only TasksLive uses it** (ProjectsLive does not). The injected helpers read `socket.assigns.tasks` (the full TaskInfo page list). The two zoom modals (Full Result `gettext("Task Result")`, Full Objective `gettext("Full Objective")`) each carry a ClipboardCopy button in the `<:actions>` slot (`id="full-result-copy"` → `TaskCardComponents.result_copy_text(@selected_result)`; `id="full-options-copy"` → `@selected_options`), and TasksLive implements the required `handle_event("copied", ...)` → "Copied to clipboard" flash handler.

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
