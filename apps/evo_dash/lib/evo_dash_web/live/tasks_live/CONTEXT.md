# TasksLive — Tasks Page

## Intent

Support documentation for `EvoDashWeb.TasksLive` (`tasks_live.ex`), the cross-project task list page (`GET /tasks`): filtering by status, project, and review state, search, server-side pagination, expandable task cards, and task actions (graceful cancel, force kill, delete, clear history).
Node-aware — reads task history via `EvoDash.NodeContext` for both the local BEAM node and a remote `genesis_remote` daemon.
ONE page load transfers one page of the 16-key task SUMMARY projection; the heavy per-card payloads (`result`, `usage`, `logs`, `archive_metadata`) are fetched lazily, per card, when the user expands it.

## Routing Table

- `tasks_live.ex` — the TasksLive LiveView: filters, pagination, task cards, modals, and the user-initiated mutating events.
- `page_load.ex` — `EvoDashWeb.TasksLive.PageLoad`, the ONE async, exit-safe page-load path (spawn seams, loader task, pure helpers) over the summary projection.
- `task_detail.ex` — `EvoDashWeb.TasksLive.TaskDetail`, the lazy per-card DETAIL + ARCHIVE cache (async fetches, cache/in-flight guards, invalidation, seq/node stale guards, one-page prune).

## Push-based change detection (no polling)

TasksLive is FULLY push-based — there is no remote poll and no dirty tracker.
`:evo_git` emits task events on the `EvoGit.PubSub` `"tasks"` topic in the node-identity contract:

- `{:task_updated, task_id, status, node}` — `status` is the task status atom (`:pending|:running|:finalizing|:cancelling|:completed|:failed|:cancelled`) or `nil` for review-only mutations
- `{:task_deleted, task_id, node}`

`node` is the BEAM node atom of the publisher.
TasksLive forwards these messages VERBATIM to `EvoDashWeb.LiveHooks.NodeAware.handle_task_info/2` (returns `{:noreply, socket}` — call sites return its value directly, never re-wrap), which applies the node filter (`event_from_current_node?/2` — event node vs `socket.assigns[:current_node]`; local viewing → `node()`, remote → the remote daemon's BEAM atom) and schedules a trailing-edge 300ms debounce (`:node_aware_reload_tasks` + the `:tasks_reload_pending` flag) that coalesces broadcast bursts into one reload.
Foreign-node events are dropped BEFORE the debounce is scheduled, so they can never trigger a UI update.
BEFORE delegating, a node-matching event drops that task's cached detail entry (`TaskDetail.invalidate/2`), so a stale `result`/`usage` can never be re-rendered from cache.
Every LiveView receives each `"tasks"` broadcast twice (TasksLive subscribes in `mount/3`, NodeAware in `on_mount/4`), so invalidating an already-EXPANDED card may refetch twice; the cache/in-flight guards keep that bounded and the debounce coalesces the page reload.

The `:node_aware_reload_tasks` handler goes entirely through off-process paths — it never touches the store: the page refresh is handed to `PageLoad.start(socket, socket.assigns.current_page, false)` (async; `show_loading? false` keeps the stale rows visible until the fresh page arrives), the sidebar running/pending reload is `NodeAware.reload_tasks/1` (itself async), and `NodeAware.clear_task_reload_pending/1` then clears the debounce flag — so the flag is cleared the moment the reload is DISPATCHED, and a later broadcast burst re-schedules as usual.
This single debounced reload serves BOTH local and remote nodes.
Unexpected messages fall through to the catch-all `handle_info(_msg, socket)` clause.
**Coalescing**: the debounce flag gates bursts while the page-load stale-guard gates overlapping loads — a burst arriving while a page load is still in flight spawns a new load (bumping the counter) whose result wins, and the superseded result is dropped.
Both loads this handler spawns (page + sidebar) are independent, see "Two independent load counters" below.

## Async page load (the only page-load path)

Every page load goes through `EvoDashWeb.TasksLive.PageLoad` (`tasks_live/page_load.ex`); the LiveView never fetches a page inline.

- `PageLoad.start/3` bumps the monotonic `:page_load_seq` (its only writer), optionally sets `:tasks_loading`, and hands the spawn fun to the `:tasks_page_load_hook` seam.
- `PageLoad.load/4` issues ONE `EvoDash.NodeContext.list_tasks_page/2` read (`limit: page_size`, `offset: (requested_page - 1) * page_size`, the current `filters`) plus `get_unique_paths/1`, and returns `%{tasks:, current_page:, total_count:, total_pages:, project_paths:}`.
- The rows are the 16-key summary projection — `id`, `status`, `review_status`, `started_at`, `finished_at`, `type`, `project_path`, `opts`, `branch_name`, `model_id`, `agent_count`, `base_sha`, `commit_sha`, `lease_expires_at`, `updated_at`, `error` — and never `result`/`usage`/`logs`/`archive_metadata`.
- There is NO second fetch: the store CLAMPS an out-of-range offset onto the LAST page of the filtered set and returns THAT page's rows (row total unchanged), so the single returned page already IS the clamped page and only `current_page = min(max(1, requested_page), total_pages(total_count, page_size))` is derived arithmetically (a stale URL, or a filter that shrank the result set, needs no refetch).
- `PageLoad.run/6` runs `PageLoad.load/4` in a supervised `EvoDash.TaskSupervisor` task behind `EvoDash.SafeCall.run/1` and ALWAYS sends exactly one `{:tasks_page_loaded, seq, node, result}` message to the LiveView — even on an exit, a raise, or a remote RPC failure.
- `result` is `{:ok, %{tasks:, current_page:, total_count:, total_pages:, project_paths:}} | {:error, reason}`; `reason` is a VALUE (`{:exit, reason}` / `{:exception, exception}` / a returned remote error), never a crash.
- **Stale guards** in `handle_info({:tasks_page_loaded, seq, node, result}, _)`: a `seq` older than `:page_load_seq`, or a `node` that no longer matches `socket.assigns.current_node`, drops the result (the newest in-flight load applies its own).
- `show_loading?` controls the "Loading tasks..." placeholder: user-initiated loads (mount/navigation, filters, retry) show it, a background refresh does not.
- **Kickoff is connected-mount-gated** (`handle_params/3`): `handle_params/3` runs on BOTH the disconnected (static HTTP) render and the connected mount, and a disconnected render's async result is discarded, so the load is spawned ONLY when `connected?(socket)`; the else branch assigns `:tasks_loading, true` so the static HTML paints the same loading placeholder the connected render replaces.
- Exactly ONE page load per navigation; connected `push_patch` (pagination) and every filter event still load normally (the guard is `connected?/1`, not a first-only flag).
- **Two independent load counters**: `:page_load_seq` belongs to the page load (`PageLoad.start/3` is its only writer); `:tasks_load_seq` belongs to `NodeAware`'s sidebar "Active Tasks" fetch (`request_tasks_load/1` is its only writer, and `handle_tasks_result/2` requires an exact match). The debounced reload spawns BOTH loads, so a shared counter would make each load's bump invalidate the other's in-flight result. Never merge them; never bump `:tasks_load_seq` from this file. `:task_detail_seq` is a THIRD, independent counter owned by `TaskDetail`.
- **`:tasks_page_load_hook`** is a 1-arity app-env seam (default identity) resolved at spawn time like EvoDash's other runner seams (`:github_runner`, `:update_check_runner`); it fires in whichever process drives the LiveView and exists so tests can count page-load spawns.
- **`:tasks_page_load_runner`** is the 4-arity page-load function seam (default `&load/4`), resolved INSIDE `run/6`, so a test can inject an exiting loader and prove the LiveView survives with `:tasks_loading` cleared.
- **`PageLoad.load/4` is the only store-facing function** (the page read + `get_unique_paths/1`); no other module knows the row shape.

## Page-load state & failure handling (`:tasks_loading` / `:tasks_error`)

- `:tasks_loading` (seeded `false`, set by `PageLoad.start/3` when `show_loading?`, cleared by every APPLIED `{:tasks_page_loaded, ...}`) drives the "Loading tasks..." placeholder.
- `:tasks_error` (seeded `nil`) holds the reason of the LAST failed page load; it is NOT interpolated into the DOM, it only selects the error UI.
- A failed load NEVER clears already-loaded rows: `:tasks` / `:filtered_tasks` / `:total_count` / `:total_pages` / `:project_paths` stay untouched.
- With nothing on screen (`@filtered_tasks == []`) the list area renders a centered "Could not load tasks." block (`#tasks-load-error`) with a Retry button — never an endless spinner (the spinner only shows while `:tasks_loading` is true).
- With rows still on screen the list renders normally plus a compact `#tasks-refresh-error` strip above `#tasks-list` ("Could not refresh tasks." + Retry), so a background-refresh failure is visible without blanking the page.
- The `retry_load` event re-runs `PageLoad.start/3` on the CURRENT page and shows the placeholder only when there is nothing to keep (`assigns[:filtered_tasks] == []`).
- A successful load assigns `tasks_error: nil`, so the strip/block disappear.

## Lazy per-card detail & archive

The rendered list holds summary rows only; the heavy data is fetched per card by `EvoDashWeb.TasksLive.TaskDetail` (`tasks_live/task_detail.ex`) — the SINGLE owner of the `:task_details` cache and its `:task_detail_seq` stale-guard.

### Entry shape

`:task_details` maps `task_id => entry` with the shape `%{state: :loading | :ok | :error, task: %EvoGit.TaskInfo{} | nil, error: term() | nil, seq: pos_integer(), archive: nil | %{state: :loading | :ok | :error, records: [map()], error: term() | nil, seq: pos_integer()}}`.
`task` is meaningful only when `state == :ok`, `error` only when `state == :error`.
The detail entry and its nested archive entry carry their OWN seq drawn from the same monotonic `:task_detail_seq`, so a detail refetch never invalidates a landed archive (and vice versa).
The cache never exceeds ONE page: `prune/2` keeps only entries whose id is on the freshly loaded page.
Nothing is fetched at mount or on page load — an entry exists only once the user expands a card.

### Reads and seams

| read | returns | app-env seam (2-arity) | default |
|------|---------|------------------------|---------|
| lite detail | `%EvoGit.TaskInfo{}` with `archive_metadata: nil` and no `:archive_records` in the result | `:tasks_task_detail_runner` | `EvoDash.NodeContext.get_task_lite/2` |
| archive | `[map()]` (the decoded `archive_metadata`) | `:tasks_task_archive_runner` | `EvoDash.NodeContext.get_task_archive/2` |

Both seams are resolved AT SPAWN TIME from app env (the dashboard's runner-seam idiom), so a test can inject an exiting runner and assert the LiveView survives.
Every fetch is ONE supervised `EvoDash.TaskSupervisor` child running `EvoDash.SafeCall.run/1` around the runner call and always reporting back: `{:task_detail_loaded, seq, node, task_id, result}` / `{:task_archive_loaded, seq, node, task_id, result}`.
No polling — results arrive only from those two messages.

### Guards and result folding

`apply_detail/5` and `apply_archive/5` drop a result unless the message's `node` still equals `socket.assigns.current_node`, the entry still exists, AND the entry's seq equals the message's seq (a newer fetch, a pruned entry, or an invalidated entry supersedes the older result).
`{:ok, %EvoGit.TaskInfo{}}` → `:ok`; `{:ok, nil}` (the task vanished between the page load and the expand) → `:error` with `:not_found`; `{:error, reason}` (including a SafeCall-captured exit) → `:error` with that reason; any other shape → `:error`.
For the archive, `{:ok, records}` with a list → `:ok` (the empty list is a valid "this task archived nothing"); `{:error, reason}` and any other shape → `:error`.

### Public API (total — a missing assign reads as an empty cache)

- `ensure/2` — fetch when no entry exists; an entry in ANY state (including `:error`) is a no-op, so this is both the cache guard and the in-flight guard.
- `retry/2` — drop the entry, then `ensure/2` (backs the error strip's Retry).
- `load_archive/2` — no-op unless the detail entry is `:ok`; fetches when `archive` is `nil` or an `:error` archive, and never while `:loading`/`:ok`.
- `invalidate/2` — drop the entry; when the card is still in `:expanded_task_ids` it immediately `ensure/2`s again, so an open card shows the loading state and then the fresh detail instead of blanking (a collapsed card stays uncached until the next expand).
- `prune/2` — keep only the entries for ids present in the landed page rows.
- `ensure_expanded/2` — after `prune/2`, refetch the detail of every still-expanded row on the new page (an open card survives a background refresh / pagination round-trip).
- `apply_detail/5` / `apply_archive/5` — the guarded message folds.

### TasksLive wiring

- `toggle_task_details` calls `TaskDetail.ensure/2` ONLY when OPENING; collapse just drops the id from `:expanded_task_ids` and keeps the cached entry, so a re-expand renders instantly and fetches nothing.
- `retry_task_detail` (`%{"task_id" => id}`) → `TaskDetail.retry/2`; `load_task_archive` (`%{"task_id" => id}`) → `TaskDetail.load_archive/2`.
- `{:task_updated, ...}` / `{:task_deleted, ...}` invalidate that id (only when `NodeAware.event_from_current_node?/2`) BEFORE delegating to `NodeAware.handle_task_info/2`.
- A node-context change in `handle_params/3` resets `:task_details` to `%{}` (cached entries belong to the old node; in-flight results are then rejected by the node + entry guards).
- A landed page load runs `TaskDetail.prune/2` then `TaskDetail.ensure_expanded/2`.

### Card rendering states

The card receives `detail={Map.get(@task_details, task.id)}`.
While the detail is `nil` or `:loading` the expanded body renders the compact `#task-<id>-detail-loading` placeholder ("Loading task details…").
On `:error` it renders the retry-able `#task-<id>-detail-error` strip ("Could not load task details." + Retry → `retry_task_detail`).
The heavy sections — Agent Message, Token & Cost Usage, Execution Logs and the archive — read `detail.task`; the Agents Spawned tile reads the summary's `agent_count`/`model_id` but is reached only once the detail has landed.
The expanded structured-failure block is the exception: it reads the summary's `error` and renders even while the detail is loading.

### Archive disclosure

The archive section appears only when the detail is `:ok` AND (`opts[:archive]` is truthy OR an archive envelope already exists).
The records are NEVER fetched with the detail: the section first shows a "Show archive" button (`load_task_archive`) and the hint "The archive loads on demand."
States: not requested (button + hint) → `:loading` spinner → `:ok` with records rendered through `ArchiveComponents.archive_details` → `:ok` with `[]` → "No archived agents for this task." → `:error` strip ("Could not load the task archive.") whose Retry re-fires the same `load_task_archive` event.

## Load-cost profile (no blocking store work in the LiveView)

- **`mount/3`** runs NO store query; `project_paths` is seeded `[]` and filled by the async load's `get_unique_paths/1` result — a mount-time call would be both redundant and wrong (at mount the node context is still local, before `handle_params/3` resolves `?node=`). `mount/3` does call `Helpers.config_status/0` → `EvoGit.Config.config_status/0` synchronously (local; persistent_term-cached file read).
- **`handle_params/3`** issues at most ONE async page load per navigation, and none on the disconnected render; the debounced PubSub reload routes through `PageLoad.start/3`, so a `{:task_updated, ...}` burst never puts a query on the LiveView process.
- **Per-card detail and archive reads are spawned by `TaskDetail`** (supervised, `SafeCall`-wrapped), so an expand never blocks the LiveView either.
- The ONLY store calls made INSIDE the LiveView process are the user-initiated mutating events (cancel / force-kill / delete / clear-history): a single-row `EvoDash.NodeContext` call wrapped in `EvoDash.SafeCall.run/1` (see "Mutating events"), whose page reload is async.
- The rendered list is a plain assign (`@filtered_tasks`) re-rendered with `Enum.with_index` + `for` — NOT a LiveView stream.
- Per-load SQL cost, the pool-backed reads (`EvoGit.Store.Boot.default_pool_size/0` = 4 connections) with writes serialized through `EvoGit.Store.Writer`, and the `get_unique_paths/1` scan: `apps/evo_git/lib/evo_git/store/CONTEXT.md`.

## Measured payload (summary page vs full row)

Measured in `test/evo_dash_web/live/tasks_live_test.exs` → "lightweight page load (summary rows)" → "a multi-MB result never rides the page load", with one fixture whose `result` is `String.duplicate("multi-mb-payload ", 140_000)` = 2,380,000 B:

| read | bytes |
|------|-------|
| the page load's summary rows for that fixture (one row) | 984 B |
| the same row through the full-row read `EvoDash.NodeContext.list_tasks_paginated(node, limit: 50)` | 2,381,183 B (≈ 2.27 MiB) |

≈ 2420× smaller — the page's cost is independent of how large a task's `result` blob is, because the summary projection never selects it.
The measurement sums `:erts_debug.size/1 * 8` PLUS the payload of every referenced binary (`term_bytes/1`), because `:erts_debug.size/1` alone is misleading here: it reports the summary row as 114 words and the full row as only 141 words, since a 2 MB refc binary costs ~8 heap words.
Test assertions: `page_bytes * 50 <= full_bytes` and `page_bytes < byte_size(big) / 50`.

## Measured load profile (isolated harness, copy of the live DB: 854 rows / 29.7 MB)

Medians from a read-only `mix run` harness (`Phoenix.LiveViewTest.live/2`) against a COPY of the live `tasks.sqlite`, exercising the real async / `TaskSupervisor` path:

- `live(conn, "/tasks")` (connected mount + first render in the loading state) ≈ 8 ms; user-visible first paint ≈ **24 ms**.
- Pure `render(view)` of 24 cards ≈ 2 ms; one collapsed `TaskCardComponents.task_card` ≈ 0.03–0.07 ms — per-card render is NOT a bottleneck (cost/usage/cache/archive/diff are gated behind the expanded state and the lazy detail).
- Sidebar `list_tasks_summary` (752 rows incl. `:completed`) ≈ **20–24 ms**, run async and off the Store GenServer; its read holds one pooled connection for its whole duration, so a concurrent page read shares the small pool with it.
- A **filtered** page load is DB-bound, not render-bound: a `status = "completed"` filter matches most rows and is materially slower than a selective one (`status = "failed"`).
- Payload size of the page read: see "Measured payload" above.

## `:reflect` tasks hidden by default (reveal toggle)

The Tasks page hides `:reflect` tasks (repo-less Home-chat / self-reflective agent chat tasks) by default so they don't pollute the cross-project task list.
Page-local filter state `@show_reflect_tasks` (default `false`, seeded in `mount/3` with the other filters) drives it; the filter-bar checkbox (`name="show_reflect_tasks"`, `value="true"`, `phx-change="toggle_reflect_tasks"`, gettext label "Show chat tasks") reveals them when checked.
The handler parses `params["show_reflect_tasks"] not in [nil, "false"]` (a checked box sends `"true"`, an unchecked box is absent from FormData) and reloads via `PageLoad.start(socket, 1, true)`.

The exclusion is applied **client-side post-load** by `PageLoad.visible_tasks/2` (`Enum.reject(tasks, &(Map.get(&1, :type) == :reflect))` when hiding) at the single choke point where loaded page rows become the displayed list: the `{:tasks_page_loaded, ...}` handler, which assigns the post-load filtered list to BOTH `:tasks` and `:filtered_tasks`.
This is because the SQL `filters` keyword (`PageLoad.filters/1`) cannot express "exclude type" — the WHERE builder lives in the read-only sibling app `evo_git`.
Rows are 16-key summary maps, so `type` is already a decoded atom (no atom conversion) and is read with `Map.get/2` — summary-safe, never a dot access that would raise on a row without the key.
`@total_count`/`@total_pages`/pagination stay SQL-truthful and untouched — a page may show slightly fewer cards when reflect rows are dropped (accepted by design).

The toggle is a **reveal preference, not a narrowing filter**: it survives pagination `push_patch`es and filter reloads (it is a plain socket assign, never cleared by `handle_params/3`), it is NOT reset by `reset_filters`, and it does NOT appear in the active-filters indicator.
When reflect-hiding empties the list with no other filter active, the empty-state shows "Try adjusting your filters or search query." instead of the start-tasks hint (`not @show_reflect_tasks` added to the first branch's condition).

## RPC payload audit (transferred vs consumed)

All data access goes through `EvoDash.NodeContext` → `EvoGit.RemoteNode` (local direct call or `:erpc`) → `EvoGit.AgentScheduler.RemoteAPI` → `EvoGit.TaskRegistry` → `EvoGit.Store`:

- **`list_tasks_page/2`** — the page data; opts `[limit: 25, offset: (page-1)*25, filters: [status:, project_path:, review_status:, search:]]` (`PageLoad.filters/1`; `"all"`/`""` passthrough is handled in the store's WHERE builder). Returns `%{rows: [summary_map], total: total_count}` with the 16-key rows. The card reads `id`, `type`, `opts`, `status`, `review_status`, `started_at`, `finished_at`, `agent_count`, `model_id`, `commit_sha`, `branch_name` and `error` from the summary; `project_path`, `base_sha`, `lease_expires_at` and `updated_at` ride along but are not read by this page.
- **Search surface**: the store applies `search:` as a case-insensitive raw SQL LIKE over `id`, `opts`, `project_path` and `branch_name`. The agent RESPONSE (`result`) is NOT searchable — it is not even loaded until a card is expanded.
- **`get_task_lite/2`** — ONE read per EXPANDED card (through `TaskDetail`): the full `%EvoGit.TaskInfo{}` decoded exactly like `get_task/2` except that `archive_metadata` is `nil` and the result carries no `:archive_records` key. Consumed: `result` (Agent Message, Full Result modal, expanded "Repositories"), `usage`, `logs`, `opts`, and `commit_sha`/`branch_name` for the multi-repo enrichment.
- **`get_task_archive/2`** — ONE read per explicit archive disclosure: only the `archive_metadata` column, decoded leniently, degraded to `[]` on a missing row, an undecodable payload, or a failed remote call.
- **`get_unique_paths/1`** — fetched ONCE per page load, inside the async load task (`PageLoad.load/4`) — `mount/3` does NOT call it. Result assigned as `@project_paths` → filter-dropdown options + active-filter badge.
- **`cancel_task/2` / `force_kill_task/2` / `delete_task/2` / `clear_finished_tasks/1`** — phx-event triggered and wrapped in `EvoDash.SafeCall.run/1` (see "Mutating events"); they return `:ok | {:error, reason}`.
- **Multi-repo `repos` result key** — task results may carry a top-level `repos` map (STRING keys) `%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}`: `"primary"` is ALWAYS present (nil branch_name = the primary produced no changes), each writable foreign repo that produced commits is present, read-only repos are ABSENT, and top-level `commit_sha`/`branch_name` remain the PRIMARY's. The COLLAPSED card derives its per-repo badges from the SUMMARY through the pure `TaskCardComponents.task_repos(task, detail)` (primary from the summary's `commit_sha`/`branch_name`, foreign repos from `opts[:foreign_repos]`, enriched by the detail result's `repos` map once it has landed; `nil` unless the task is genuinely multi-repo). `result_repos/1` + `result_repos_badges/1` still back the expanded `render_result/2` "Repositories" section and the Full Result modal.
- **`list_task_ids/2`** (id/status/updated_at projection) — NOT called from tasks_live.ex; the only dashboard consumer is SystemLive's update card.
- **`list_tasks_changed_since/2`** — not called anywhere in the dashboard (change detection is broadcast-driven).
- **`list_tasks_paginated/2`** (full `%TaskInfo{}` rows) — not issued by this page.

## Store read shapes

- *Summary* (16 keys, no result): `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error` — `error` is the structured failure record map (ATOM-keyed after decode, `nil` unless the task is `:failed`). Consumed by this page's `list_tasks_page/2` and by the NodeAware sidebar loader (`list_tasks_summary`; `show_review_button?/1` reads only `status`/`type`).
- *Id-only*: `list_task_ids/2` — id + status + updated_at, no result/opts decode.
- *Lite detail*: `get_task_lite/2` — a full `%TaskInfo{}` decode WITHOUT the `archive_metadata` column and without the result's `:archive_records`; reached only from an expanded card.
- *Archive*: `get_task_archive/2` — only the `archive_metadata` column; reached only from an explicit archive disclosure.
- *Full* (`list_tasks_paginated/2`, `get_task/1`): `Codec.decode_result` (rebuilds `%Usage{}` + archive_records) runs per row; this page issues neither.

## Task cancellation UX (graceful cancel + force kill)

Two two-step server-side confirmation-modal flows (SystemLive warning-modal pattern; NO custom JS — assigns drive visibility):

- **Graceful cancel** (card's inline Cancel button, visible `[:pending, :running]`): `open_cancel_modal` → assign `:confirm_cancel_task_id`; `confirm_cancel_task` → `EvoDash.NodeContext.cancel_task(current_node, task_id)` (GRACEFUL — agents save + exit, result preserved; `:pending` → immediate `:cancelled`) inside `EvoDash.SafeCall.run/1`; `:ok` → collapse the expanded card + `PageLoad.start(socket, current_page, false)`; error → flash `gettext("Failed to cancel task: %{reason}", reason: inspect(reason))`. Modal: title `gettext("Cancel Task?")`, confirm `gettext("Cancel Task")` (`btn-warning`), dismiss `gettext("Keep Running")`.
- **Force kill** (card's three-dot dropdown, visible `[:running, :cancelling]`, "Danger zone" divider): `open_force_kill_modal` → assign `:confirm_force_kill_task_id`; `confirm_force_kill_task` → `EvoDash.NodeContext.force_kill_task(current_node, task_id)` (BRUTAL — kills all agents, result nil'd; escalation from `:cancelling`) inside `EvoDash.SafeCall.run/1`; same `:ok` collapse + async reload / error-flash handling. Modal: title `gettext("Force Kill Task?")`, confirm `gettext("Force Kill")` (`btn-error`).
- **Modal-state lifecycle**: both assigns seeded `nil` in `mount/3`, MUTUALLY EXCLUSIVE (opening one clears the other), cleared on node switch in `handle_params/3`; nil-guarded confirms are no-ops.
- **Status filter**: includes `gettext("Cancelling")` (`value="cancelling"`); pure SQL string comparison (`EvoGit.Store.Operations.Filters.where_filters/2`), so `:cancelling` round-trips — no evo_dash-side atom whitelist.
- **`:cancelled` reviewability**: gracefully-cancelled tasks ARE reviewable — the card Review button shows for every `:completed`/`:cancelled` task (repo-less `:reflect` excluded); a `:cancelled` task without a branch still opens the review page (no-changes).

## ModalHelpers

`EvoDashWeb.ModalHelpers` (`live/modal_helpers.ex`) — a `__using__` macro injecting shared modal event handlers (`view_full_result/2`, `close_result_modal/1`, `view_full_options/2`, `close_options_modal/1`) into a host LiveView. **Only TasksLive uses it** (ProjectsLive does not).

- `view_full_result/2` reads the CACHED `:task_details` entry (never `socket.assigns.tasks` — those rows carry no `result`). `@selected_result` is a modal STATE: `nil | %{state: :loading} | %{state: :ok, result: result} | %{state: :error, error: reason}`.
- The Full Result modal (`gettext("Task Result")`) renders `TaskCardComponents.render_result_full(result)` and the `#full-result-copy` ClipboardCopy button ONLY in the `:ok` state; `#full-result-error` ("Could not load the task result.") for `:error`, `#full-result-loading` ("Task result is not loaded yet.") otherwise.
- `view_full_options/2` reads the summary `opts` from `socket.assigns.tasks` (always present in the summary projection) → `opts[:prompt] || opts[:objective]`, so it needs no detail fetch. The Full Objective modal (`gettext("Full Objective")`) carries the `#full-options-copy` ClipboardCopy button.
- TasksLive implements the required `handle_event("copied", ...)` → "Copied to clipboard" flash handler.

## Failed-task error rendering (legacy error result + structured failure record)

A `:failed` task can surface its failure through TWO separate records: the legacy `{:error, reason}` / `{:exit, reason}` task RESULT shape and the structured `error` map field on the task row.
Both records may coexist, and a `:failed` task may carry either, both, or neither (legacy failed rows have `error` nil).
`error` (ATOM keys after decode) is `%{kind: atom, source: atom, message: String.t(), stacktrace: [String.t()] | nil}` with `kind` ∈ `:error | :exit | :down | :force_kill | :timeout | :restart | :lease_expired | :recheck` and `source` ∈ `:result_handler | :down_handler | :force_kill_task | :finalizing_watchdog | :startup_reconcile | :lease_sweep | :recheck_resolve`.
It is `nil` on every non-`:failed` row and rides on the SUMMARY projection, so it is available before — and independently of — the lazy detail.

- tasks_live.ex NEVER reads `task.result` / `task.error` itself — every row is delegated whole to `EvoDashWeb.TaskCardComponents.task_card task={task} show_details=... detail={Map.get(@task_details, task.id)} current_node_id=...`; all failure reading/rendering lives in the component.
- COLLAPSED `:failed` card (legacy shape): status badge `Helpers.task_status_badge(:failed)` = `bg-error/10 text-error`; accent bar `task_accent_color/1` → `Helpers.task_status_dot_class(:failed)` = `bg-error`; card tint `task_card_tint/1` → `Helpers.task_status_tint(:failed)` = `bg-error/5 shadow-error/10 border-error/20`; badge text = the raw atom. No error text is visible in the collapsed legacy state.
- COLLAPSED `:failed` card WITH a structured `error` map: additionally renders a compact error-tinted failure line — the truncated `error.message` (`Helpers.truncate_string/2`, ~160 chars). `error` nil/non-map → nothing extra.
- EXPANDED structured failure block: reads the summary `error` — kind + source captions via `Helpers.task_error_kind_label/1` / `Helpers.task_error_source_label/1` (unknown atoms → a safe generic fallback), the full untruncated `error.message`, and the last ≤8 `stacktrace` frames as monospace lines. It renders even while the detail is loading.
- EXPANDED legacy result box: the Agent Message section is gated on `Map.get(detail.task, :result)` — an `{:error, _}` tuple is truthy so the section renders once the detail lands. Body = `render_result/2`, which renders `{:error, reason}` as a red `bg-error/10 border border-error/20` box headed `gettext("Error")` (hero-x-circle icon) with `<pre> inspect(reason, limit: :infinity)` and `{:exit, reason}` as a "Crashed" box. `:failed` with a nil result → no Agent Message section (the legacy force-killed shape).
- Full Result modal: `view_full_result/2` opens on the CACHED detail (see "ModalHelpers"); `result_copy_text/1` for `{:error, reason}` is `inspect(reason, limit: :infinity)`. The only UI entry to the modal is the "Full" button inside an EXPANDED card's Agent Message section.
- Guards are read-only (`status == :failed and is_map(error)` + `Map.get`) and tolerant of nil/non-map/legacy shapes on BOTH the summary projection and full `%TaskInfo{}` rows.
- `show_review_button?/1` matches EVERY `:completed`/`:cancelled` task except repo-less `:reflect` — a `:failed` task NEVER gets a Review link/navigation on this page (test-pinned).
- Legacy result decoded-shape note (evo_git codec contract): `{:error, reason}` persists tagged, and a non-JSON-safe reason (e.g. a tuple `{128, "fatal: ..."}`) is stored as `inspect(reason)` and decoded back as that string, so the dashboard sees `{:error, "{128, \"fatal: ...\"}"}` and displays it verbatim in the Error box.
- Test pin: `tasks_live_test.exs` asserts an `{:error, "explosion happened"}` result renders "Agent Message" + "Error" + the reason text, with the copy payload containing the reason. No test covers tuple-shaped reasons (they render as their inspect-string after the codec round trip).
- `render_result` clause safety: the catch-all `render_result(result, opts)` pretty-inspects any non-tuple/non-map shape, so no stored result shape can crash a task card.

## Test idioms

- `flush_tasks_load/2` (delegates to `EvoDashWeb.TestHelpers.flush_loading/4`) waits for the async page load by polling until the "Loading tasks..." placeholder disappears, then awaits `:tasks_loading == false` and re-renders.
- `drain_async_loads/2` waits out an armed NodeAware debounce (`:tasks_reload_pending` false) and then for every `EvoDash.TaskSupervisor` child this view spawned to exit (matched via the `$callers` dictionary), so no offloaded store read is still in flight at teardown.
- `render_tasks_list/1` (`view |> element("#tasks-list") |> render()`) scopes list-content assertions away from the SIDEBAR, which also lists `:completed` tasks and can show a row before the page reload lands.
- `wait_for_list/3` polls the `#tasks-list` container until a needle appears (each render is a synchronous round-trip that drains the LiveView mailbox) — use it whenever an ASYNC reload's effect is being awaited.
- `install_page_load_hook/0` wraps the `:tasks_page_load_hook` seam so a test receives a `:page_load_spawned` message per page-load spawn, and asserts the counter via `:sys.get_state(view.pid).socket.assigns.page_load_seq`; `install_tasks_page_load_runner/1` injects the 4-arity page-load runner.
- `expand_card/3` toggles a card and WAITS for its lazy detail to leave `:loading` (polling `detail_entry/2`, then draining async work and re-rendering) — no sleeps; use it for every expanded-content assertion.
- `install_task_detail_runner/1` / `install_task_archive_runner/1` inject the 2-arity `:tasks_task_detail_runner` / `:tasks_task_archive_runner` seams (restored in `on_exit`); the detail runner may block on a `:release_detail` message so the in-flight `:loading` state is observable deterministically.
- `detail_entry/2` reads `:task_details[task_id]` through `:sys.get_state/1` (a synchronous round-trip, so already-sent async results are applied); `flush_detail_fetches/1` drains pending `{:detail_fetch, id}` notifications (a bounded 100ms wait) before a "no further fetch" assertion.
- `term_bytes/1` = `:erts_debug.size/1 * 8` + the payload of every referenced binary (structs unwrapped via `Map.from_struct/1`, lists/tuples walked) — the payload measurement behind "Measured payload".
- Test pins for the lazy path: expanding triggers exactly ONE fetch (a second toggle while loading is a guarded no-op, and a re-expand after landing renders from cache); a `nil` detail becomes `:error`/`:not_found` and an EXITING runner becomes `{:exit, :boom}` with the LiveView alive and Retry recovering in place; a node-matching `{:task_updated, ...}` invalidates + refetches an expanded card while a `{:task_deleted, ...}` drops the entry of a collapsed one; the archive fetches ONLY on click and covers records / empty / error+retry.
- The search tests assert a `branch_name` hit (case-insensitive) and pin a regression: text that exists ONLY in a task's `result` no longer matches.
- New-shape events are injected manually — `Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, status, node()})` (the `:evo_git` emitters are tested in their own workstream).
- Debounce assertions use the two-phase `wait_until` helper: first `assigns[:tasks_reload_pending] == true` (event processed + node filter matched + debounce scheduled), then `== false` (debounce fired + the ASYNC reload DISPATCHED — the fresh page arrives later, so follow with `wait_for_list/3`). Foreign-node events: sample `tasks_reload_pending == false` across the whole debounce window + assert content unchanged.
- **Proving the reload is off-process**: `:sys.suspend(EvoGit.TaskRegistry)` freezes the serialized registry so ANY synchronous read blocks there (30s call timeout). The debounced handler must still complete (flag cleared + `page_load_seq` advanced) with the reloaded rows NOT applied, then `:sys.resume(EvoGit.TaskRegistry)` lets the off-process load land. Always pair the suspend with an `on_exit` resume (the `setup/1` isolation teardown runs later, LIFO).
- Store fixtures: `insert_fixture!/1` writes `%EvoGit.TaskInfo{}` rows directly via `EvoGit.Store.put_task` (bypasses the async task spawn, so it emits no broadcast); deletions via `EvoGit.Store.delete_task/2`.
- **Failure state**: a failed load can be injected with `send(view.pid, {:tasks_page_loaded, seq, node(), {:error, :boom}})` (use the current `:page_load_seq`). With no rows on screen that renders `#tasks-load-error` ("Could not load tasks."); with rows already loaded it renders `#tasks-refresh-error` above `#tasks-list` and leaves the rows untouched. Both offer a Retry button wired to `phx-click="retry_load"`, which spawns exactly one more page load and clears `:tasks_error` on success.
- Card assertions that need the flattened headers use `h4_header_texts/1` (scoped to `<h4>`, because HEEx emits the template's HTML comments verbatim); `attribute/3` + `data_content/2` read ClipboardCopy payloads.

## Load path & round-trip inventory (per page render)

Every load goes `EvoDash.NodeContext.<f>` (local direct / remote `:erpc`) → `EvoGit.RemoteNode` → `EvoGit.AgentScheduler.RemoteAPI` → `EvoGit.TaskRegistry` → `EvoGit.Store`.
In the core, reads share a small connection pool (`EvoGit.Store.Boot.default_pool_size/0` = 4) so they run concurrently instead of serializing with one another, while all writes — heartbeat/lease/cleanup included — serialize through the dedicated `EvoGit.Store.Writer` process.
The page read runs off-process on the core side too (the registry offloads `list_tasks_page`, `get_task_lite` and `get_task_archive`), while `get_unique_paths/1` blocks the core TaskRegistry GenServer for the duration of its read (the store side of that read is still offloaded).

- **`list_tasks_page/2`** — `PageLoad.load/4` (opts `[limit: 25, offset: (page-1)*25, filters: PageLoad.filters/1]`) → `TaskRegistry.list_tasks_page/1` → `Store.select_tasks_page/2`. Issues **TWO SQL statements** — `COUNT(*)` over the filtered WHERE plus ONE page `SELECT` of the 16 summary columns `ORDER BY started_at DESC LIMIT/OFFSET` — and decodes NO heavy blob per row. A `search` filter is a leading-wildcard OR-`LIKE` over `id`/`opts`/`project_path`/`branch_name` (full-table scan) executed in BOTH statements. The page is index-served (`idx_tasks_started_at`, or the matching composite when a filter pins a leading equality column).
- **`get_unique_paths/1`** — called ONCE per page load inside the async task (`PageLoad.load/4`) → `TaskRegistry.get_unique_paths/0` → `Store.select_task_paths/1` (`SELECT DISTINCT project_path`) — one more SQL statement, never issued from `mount/3`.
- **`get_task_lite/2`** — ONE read per EXPANDED card: a single-row `SELECT` of every decode-relevant column except `archive_metadata`, decoded through the same `Codec.decode_task/1`.
- **`get_task_archive/2`** — ONE read per explicit archive disclosure: a single-row `SELECT` of the `archive_metadata` column only.

Minimum cost per navigation: 2 core RPCs (page summary + distinct paths) and 2 SQL statements for the page read plus the `DISTINCT project_path` scan, all OUTSIDE the LiveView process.
A mutating event adds ONE single-row call inline plus the same page-read cost in its async reload.
Expanding a card adds ONE lite read; disclosing its archive adds ONE more.

## Synchronous vs async in the LiveView

- **ASYNC (`EvoDash.TaskSupervisor`)**: the connected mount, `push_patch` pagination, every filter/search/toggle event, `retry_load`, the reload after a successful mutation, and the debounced PubSub reload — all via `PageLoad`, landing as `{:tasks_page_loaded, seq, node, result}` stale-guarded by `:page_load_seq` + the node identity.
- **ASYNC (`EvoDash.TaskSupervisor`, via `TaskDetail`)**: the per-card detail fetch (`{:task_detail_loaded, ...}`) and the archive fetch (`{:task_archive_loaded, ...}`), stale-guarded by `:task_detail_seq` + the entry + the node identity.
- **SYNCHRONOUS in the LiveView process** (each wrapped in `EvoDash.SafeCall.run/1`, so an exit becomes a flash, not a crashed page): `mount/3`'s `config_status/0`, and the single-row mutating calls of `confirm_cancel_task` / `confirm_force_kill_task` / `delete_task` / `clear_task_history`.
- **Nothing else blocks**: there is no inline page fetch anywhere in the LiveView.

## Mutating events (SafeCall-wrapped, async reload)

- `clear_task_history` → `SafeCall.run(fn -> NodeContext.clear_finished_tasks(node) end)`. Success clears `:expanded_task_ids` and starts `PageLoad.start(socket, 1, true)`; failure flashes `gettext("Failed to clear task history: %{reason}", reason: inspect(reason))` and does NOT reload.
- `confirm_cancel_task` / `confirm_force_kill_task` / `delete_task` → the same `SafeCall.run/1` wrapping around the single-row `NodeContext` call. Success collapses the row's expansion and starts `PageLoad.start(socket, socket.assigns.current_page, false)` (no spinner — the old row stays visible until the fresh page arrives); failure flashes the existing `gettext("Failed to cancel task: %{reason}", …)` / `gettext("Failed to force kill task: %{reason}", …)` / `gettext("Failed to delete task: %{reason}", …)` message.
- These calls stay in the LiveView process ON PURPOSE: they are user-initiated single-row mutations and the tests assert the store state right after the click; only the resulting page reload is async.
- `mutation_result/1` (private) normalizes SafeCall's output to `:ok | {:error, reason}`: the NodeContext mutating functions return `:ok | {:error, reason}` (so SafeCall yields `{:ok, :ok}` / `{:ok, {:error, reason}}`) and a caught exit/raise yields `{:error, reason}`.

## PubSub refetch behaviour

Every node-matching `{:task_updated, _, _, _}` / `{:task_deleted, _, _}` first invalidates that task's cached detail (see "Lazy per-card detail & archive") and then triggers a page refresh: `NodeAware.handle_task_info/2` node-filters then debounces 300ms (`debounce_task_reload/1`, coalescing bursts), and the `:node_aware_reload_tasks` handler dispatches the ASYNC page reload (`PageLoad.start(socket, current_page, false)`) plus the async sidebar reload (`NodeAware.reload_tasks/1`), then clears the debounce flag.
A source emitting events across ≥300ms windows produces one reload dispatch per window (a burst inside an already-in-flight load still spawns a new load whose result supersedes the older one via `:page_load_seq`).
The page reload also re-runs `TaskDetail.prune/2` + `ensure_expanded/2`, so an open card's detail is refreshed by the same debounced pass.

## No per-task N+1 I/O in the list path

`EvoDashWeb.TaskCardComponents.task_card/1` performs NO git subprocess, `File.stat`/`exists?`, `System.cmd`, or `NodeContext` call at render time — it renders the summary row plus whatever the `detail` attr already holds (verified: no `rev_parse|System.cmd|File.stat|NodeContext|Port.open` in that file).
A detail read exists ONLY for a card the user expanded, and an archive read ONLY for an archive disclosure the user clicked, so the extra round trips are bounded by what the user opened — never by the number of rows on the page.
The per-row cost of the page load is the core-side summary decode, not an extra round trip.

## Constraints

- Do NOT reintroduce polling (`:remote_poll` / `Process.send_after` self-ticks) or the DirtyTracker module — push events are the single change-detection mechanism, and detail/archive results arrive only from their two messages.
- The page loads SUMMARY rows only (`list_tasks_page/2`); heavy data is fetched per card through `TaskDetail` (`get_task_lite/2` / `get_task_archive/2`) and is NEVER transferred with the list or rendered from the summary.
- Keep every load ASYNC and connected-gated: `handle_params/3` must only spawn behind `connected?(socket)`, and every page load — including the debounced reload and the post-mutation reload — must go through `PageLoad.start/3`. Never fetch a page inline in the LiveView.
- Every store/RPC call is exit-safe: page loads via `PageLoad.run/6`'s `EvoDash.SafeCall.run/1`, detail/archive via `TaskDetail`'s spawned runners, mutating events via an explicit `SafeCall.run/1` wrap. Never add a bare `EvoDash.NodeContext` / `EvoGit.TaskRegistry` call to a LiveView event handler.
- A `:loading`, `:error` or `nil` detail must always be a renderable state — the card shows the loading placeholder or the retry-able error strip; never a stuck spinner, never a crash, and never a heavy section rendered without `detail.task`.
- `:task_details` is bounded to ONE page: every landed page load must run `TaskDetail.prune/2` (then `ensure_expanded/2`), and a node-context change must reset it to `%{}`.
- Failure is a VALUE, not a crash: a failed load assigns `:tasks_error` and keeps the already-loaded rows; the UI offers `retry_load`. Never revert to a flash-only failure on the page-load path, and never clear `:tasks` on error.
- `:page_load_seq`, `:tasks_load_seq` and `:task_detail_seq` are INDEPENDENT stale-guards (page load / sidebar / per-card detail + archive). Never merge them and never bump another owner's counter.
- The node filter lives in `NodeAware.handle_task_info/2` (shared by every consumer of the `"tasks"` topic) — TasksLive only forwards and reloads; the detail invalidation applies the same `event_from_current_node?/2` filter itself.
- Modal state assigns are server-side (no custom JS); follow the warning-modal pattern for any new destructive action.
