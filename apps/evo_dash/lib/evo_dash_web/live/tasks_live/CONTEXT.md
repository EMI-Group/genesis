# TasksLive — Tasks Page

## Intent

Support documentation for `EvoDashWeb.TasksLive` (`tasks_live.ex`), the
cross-project task list page (`GET /tasks`): filtering by status, project, and
review state, search, server-side pagination, expandable task cards, and task
actions (graceful cancel, force kill, delete, clear history). Node-aware — reads
task history via `EvoDash.NodeContext` for both the local BEAM node and a remote
`genesis_remote` daemon.

## Push-based change detection (no polling)

TasksLive is FULLY push-based — there is no remote poll and no dirty tracker.
`:evo_git` emits task events on the `EvoGit.PubSub` `"tasks"` topic in the
node-identity contract:

- `{:task_updated, task_id, status, node}` — `status` is the task status atom
  (`:pending|:running|:finalizing|:cancelling|:completed|:failed|:cancelled`) or
  `nil` for review-only mutations
- `{:task_deleted, task_id, node}`

`node` is the BEAM node atom of the publisher. TasksLive forwards these messages
VERBATIM to `EvoDashWeb.LiveHooks.NodeAware.handle_task_info/2`, which:

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
debounced reload serves BOTH local and remote nodes. Old event shapes
(`{:tasks_updated}`, `{:task_status, id, status}`) are GONE; unexpected messages
fall through to the catch-all `handle_info(_msg, socket)` clause.

## Async page load

- `start_async_page_load/3` spawns a supervised `EvoDash.TaskSupervisor` task
  (the LiveView never blocks on cross-node RPCs); the result arrives as
  `{:tasks_page_loaded, seq, node, result}` and is stale-guarded by the
  monotonic `tasks_load_seq` (stale seq or wrong node → dropped). `show_loading?`
  controls the "Loading tasks..." placeholder (user-initiated loads only).
- Mutating events (cancel / force-kill / delete / clear-history) and the
  debounced PubSub reload use the synchronous `reload_current_page/1` /
  `sync_apply_page/2` path (no loading state, no seq bump).

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
