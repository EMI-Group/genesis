# LiveHooks — On-Mount Hooks

## Intent

Phoenix LiveView on-mount hooks registered globally via the `live_view/0` macro in `evo_dash_web.ex`. Both hooks apply to ALL LiveViews automatically — no per-LiveView opt-in required.

## Routing Table

None — leaf directory (two module files: `set_locale.ex`, `node_aware.ex`).

## API Surface

### `EvoDashWeb.LiveHooks.SetLocale` (`set_locale.ex`)

Restores the Gettext locale from the HTTP session into each LiveView process.

- **Problem**: The `Locale` Plug sets `Gettext.put_locale/2` during HTTP requests, but LiveViews run in separate BEAM processes where the process dictionary is empty.
- **Solution**: Reads `session["locale"]` on mount and calls `Gettext.put_locale(EvoDashWeb.Gettext, locale)`.
- **Default**: Falls back to `"en"` when no locale is in the session.
- **Fifteen languages** are supported: ar, de, en, es, fr, id, it, ja, ko, pt, ru, th, vi, zh_CN, zh_HK.

### `EvoDashWeb.LiveHooks.NodeAware` (`node_aware.ex`)

The "spatial glue" for SSH Remote Development node-aware navigation. Provides on-mount setup and helper functions used by LiveViews and the shared layout.

**On-mount setup**:
- Sets initial node-context assigns: `@current_node`, `@current_node_name`, `@current_node_id`, `@remote_targets`, `@connection_statuses` (all with safe local defaults via `assign_new/3`). Also seeds `:tasks_reload_pending` (`false`, debounce flag), `:tasks_load_seq` (`0`, async-load request sequence), and `:tasks_node_loaded` (`{nil, node()}`, dedup guard seed — prevents the mount double-fetch, see below).
- Attaches `attach_hook(:node_aware_active_tasks, :handle_info, &handle_info/2)` on BOTH the dead-render and connected paths (same pattern as `DesktopQuit`'s `:handle_event` hook) — the hook intercepts `{:node_aware_active_tasks, ...}` result messages and routes them through the stale-guard; every other message passes through (`{:cont, socket}`), so LiveViews' own `handle_info` clauses are untouched.
- Subscribes to `EvoGit.PubSub` topic `"remote_connections"` when the socket is connected.

**Statuses-filtered sidebar fetch — ASYNC** (`load_running_and_pending_tasks/1`): The sidebar "Active Tasks" fetch is **statuses-filtered** — only `[:running, :pending, :finalizing, :cancelling, :completed]` are loaded, so the SQL query skips finished tasks that can never appear in the sidebar (the sidebar shows running/pending tasks and derives `pending_tasks` review candidates from `:completed`). Local node: `EvoGit.TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :cancelling, :completed])`; remote node: `EvoDash.NodeContext.list_tasks_summary(node, [:running, :pending, :finalizing, :cancelling, :completed])` (RPC). The Elixir-side filtering logic (running filter + pending-review filter + sort) runs after the SQL statuses fetch.

**The load is ASYNC (never blocks the LiveView process — a remote `:erpc` fetch can take up to 30s)**: `load_running_and_pending_tasks/1`, `assign_active_tasks/1`, and `reload_tasks/1` all delegate to the private `request_tasks_load/1`, which (1) captures the view pid, the node context (`current_node`/`current_node_id` from the assigns), and the next `:tasks_load_seq` value BEFORE spawning, (2) bumps the `:tasks_load_seq` assign, (3) spawns a supervised fetch on `EvoDash.TaskSupervisor` (established pattern — SettingsLive's LLM test / ReviewLive.MergeCheck's check_merge), and (4) returns the socket UNCHANGED — the previous sidebar content stays visible until the fresh result arrives (no loading indicator, no new UI). The spawned fn runs `fetch_active_tasks/2` (context-based, preserving the pending-remote guard `current_node_id != nil and current_node == node()` → `{[], []}`) → `partition_active_tasks/1`, then sends `{:node_aware_active_tasks, seq, node_id, node, {running, pending}}` to the captured view pid. The spawned fn never raises — an unexpected fetch failure is rescued at the async boundary to `{[], []}` (mirrors NodeContext's `[]`-on-RPC-failure defensive mode; commented per the try/rescue policy).

**Stale-guard** (`handle_tasks_result/2` — public pure socket-in/out seam, called by the attached `handle_info/2` hook): drops the result (socket unchanged) when `node_id` != `:current_node_id`, OR `node` != `:current_node` (the user switched nodes while the fetch was in flight), OR `seq` != the current `:tasks_load_seq` (a newer load was spawned — only the latest request's result is ever applied); otherwise assigns `:running_tasks`/`:pending_tasks`. `handle_info/2` returns `{:halt, socket}` for the matched message and `{:cont, socket}` for everything else.

**Debounced task reload** (trailing-edge, 300ms): `handle_task_info/2` routes every task broadcast through `debounce_task_reload/1`, which coalesces broadcast bursts into a single trailing-edge reload instead of reloading synchronously per broadcast:
- `debounce_task_reload/1` — if `Map.get(socket.assigns, :tasks_reload_pending, false)` is truthy, the intermediate broadcast is **dropped** (socket returned unchanged); otherwise it schedules `Process.send_after(self(), :node_aware_reload_tasks, 300)` and sets `:tasks_reload_pending` to `true`.
- `reload_tasks/1` — spawns the async sidebar load (via `load_running_and_pending_tasks/1`) then clears `:tasks_reload_pending` to `false`. **LiveViews** handle the `:node_aware_reload_tasks` message with a `handle_info(:node_aware_reload_tasks, socket)` clause calling `{:noreply, NodeAware.reload_tasks(socket)}`.
- `clear_task_reload_pending/1` — clears `:tasks_reload_pending` without reloading (used by ProjectsLive at the end of its custom reload clause).

**`assign_node/2` dedup guard** (`:tasks_node_loaded`): After the node-context `case` assigns `:current_node`/`:current_node_id`/`:current_node_name`, `assign_node/2` computes `context = {socket.assigns[:current_node_id], socket.assigns[:current_node]}`. If `Map.get(socket.assigns, :tasks_node_loaded) == context`, the socket is returned **without** reloading the sidebar; otherwise it triggers the ASYNC sidebar load (`load_running_and_pending_tasks/1` — socket returned unchanged, result arrives via the attached `:handle_info` hook + stale-guard) AND sets `:tasks_node_loaded` to `context`. Node switches (local↔remote, pending→connected) still reload since the context tuple differs; the stale-guard drops any in-flight result from the previous node context. `on_mount` seeds `:tasks_node_loaded` with `{nil, node()}` (matching the local context that `assign_node/2` computes on first `handle_params`), which prevents the mount double-fetch.

**Statuses API**: The statuses forms of `list_tasks_summary` exist — `EvoGit.TaskRegistry.list_tasks_summary/1` (`task_registry.ex:116`, statuses \\ []), `list_tasks_summary_by_path/2`, `EvoDash.NodeContext.list_tasks_summary/2` and `EvoGit.RemoteNode.list_tasks_summary/2` (`remote_node.ex:358`) — with the statuses filter SQL-pushed-down (`WHERE status IN (...)`) all the way to the Store. Keep using the statuses-filtered form; it is the cheapest sidebar query.

**Helper functions** (called by LiveViews):

| Function | Purpose |
|----------|---------|
| `assign_node/2` | Reads `?node=` query param in `handle_params/3`, resolving it to a saved+connected target or falling back to `:local`. Includes the `:tasks_node_loaded` dedup guard — skips the sidebar reload when the node context tuple `{current_node_id, current_node}` is unchanged (see above). Node-context assigns are set synchronously; the sidebar reload it triggers is async. |
| `current_node_display_name/1` | Returns display name for the current node. |
| `node_query_param/1` | Returns `%{node: id}` for appending to navigation URLs (threads node through all links). |
| `handle_connection_status/2` | Handles `{:remote_connection_status, id, status}` PubSub broadcasts. Refreshes `@connection_statuses` always. When the status change is for the currently selected node AND represents a meaningful local↔remote transition (`:connected` local→remote, or `:disconnected`/`:error` remote→local), it does NOT update `@current_node` inline — instead it `push_patch`es the current path (preserving `?node=`) so `handle_params/3` re-runs and reloads ALL page-specific node data (remote agents, remote config, remote paused state, etc.). Re-running `handle_params` uniformly reloads everything without per-page duplication, since it already contains all node-specific data loading. Non-transition statuses (`:connecting`, `:bootstrapping`, duplicate/non-selected node) only refresh statuses and do NOT reload. |
| `handle_node_selected/2` | Builds a `push_patch` to update the URL when a different node is selected. |
| `handle_task_info/2` | Handles task PubSub messages via the trailing-edge 300ms debounce (`debounce_task_reload/1`, message `:node_aware_reload_tasks`). |
| `debounce_task_reload/1` | Trailing-edge debounce — drops broadcasts while `:tasks_reload_pending` is truthy, otherwise schedules `:node_aware_reload_tasks` after 300ms and sets the flag. |
| `reload_tasks/1` | Executes the debounced reload: spawns the async sidebar load (`load_running_and_pending_tasks/1`) and clears `:tasks_reload_pending`. LiveViews call this from their `handle_info(:node_aware_reload_tasks, socket)` clause. |
| `clear_task_reload_pending/1` | Clears `:tasks_reload_pending` without reloading (ProjectsLive uses it at the end of its custom reload clause). |
| `load_running_and_pending_tasks/1` | Public async sidebar-load entry point (spawns on `EvoDash.TaskSupervisor`, returns the socket unchanged). Used by `on_mount/4`, `assign_node/2`, `reload_tasks/1`, and ProjectsLive's `:node_aware_reload_tasks` handler. |
| `assign_active_tasks/1` | Public async sidebar reload for ProjectsLive's task-mutation event handlers (task_submit, cancel_task, clear_task_history, delete_task, GitHub-issue fix). Same spawner as `load_running_and_pending_tasks/1`. |
| `fetch_active_tasks/2` | Context-based (`current_node`, `current_node_id`) node-aware fetch — callable from the spawned task. `/1` socket wrapper kept for API compatibility. |
| `handle_tasks_result/2` | Stale-guard seam (pure socket in/out): drops mismatched node/seq results, assigns `:running_tasks`/`:pending_tasks` on match. Called by the attached `handle_info/2` hook. |
| `handle_info/2` | Attached `:handle_info` hook — `{:halt, socket}` for `{:node_aware_active_tasks, ...}` (via `handle_tasks_result/2`), `{:cont, socket}` for all other messages. |

## Constraints

- Both hooks use `assign_new/3` (safe assigns — first-write-wins).
- Domain logic is delegated to `EvoDash.NodeContext` — hooks are thin wrappers.
- Safe fallbacks everywhere: locale defaults to `"en"`, node resolution falls back to `:local` on all failure paths.
- Node name fallback: "Local" when no remote node is active.
- **Task reload debounce**: `handle_task_info/2` NEVER reloads synchronously — always go through `debounce_task_reload/1` → `:node_aware_reload_tasks` (300ms trailing-edge) → `reload_tasks/1`. LiveViews that do custom reloads must call `clear_task_reload_pending/1` afterwards so the next broadcast can schedule a fresh reload.
- **Sidebar dedup**: `assign_node/2` skips the sidebar reload when `:tasks_node_loaded == {current_node_id, current_node}`. Do not remove the guard without also handling the mount double-fetch it prevents.
- **Statuses-filtered sidebar fetch**: `load_running_and_pending_tasks/1` uses the statuses-filtered forms `EvoGit.TaskRegistry.list_tasks_summary/1` and `EvoDash.NodeContext.list_tasks_summary/2` (via `EvoGit.RemoteNode.list_tasks_summary/2` → `EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary/1`; SQL-pushed-down statuses IN filter). Do NOT revert to unfiltered `/0`/`/1` calls — the statuses-filtered call is the whole point (skips finished rows in SQL).
- **Sidebar loads are ALWAYS async**: `load_running_and_pending_tasks/1`, `assign_active_tasks/1`, and `reload_tasks/1` MUST go through the private `request_tasks_load/1` spawner (supervised fetch on `EvoDash.TaskSupervisor`, `:tasks_load_seq` bump, socket returned unchanged). Do NOT reintroduce synchronous fetch/assign — a remote `:erpc` fetch can block the LiveView process for up to 30s. The result message is `{:node_aware_active_tasks, seq, node_id, node, {running, pending}}`; never change its shape without updating the attached `handle_info/2` hook and the `handle_tasks_result/2` stale-guard.
- **Stale-guard is mandatory**: results are applied ONLY when `node_id`/`node` match the current node-context assigns AND `seq` matches `:tasks_load_seq` (latest request wins). The `:tasks_load_seq` assign is bumped by every load request; never reset it to a lower value mid-view.
- **Previous sidebar content is kept** until the fresh result arrives (no loading indicator, no clearing on spawn). A dropped/stale result leaves the sidebar untouched.
- **LiveView pages do NOT need to change**: the attached `:handle_info` hook consumes the result message (`{:halt, socket}`); all other messages pass through (`{:cont, socket}`). LiveViews keep calling `load_running_and_pending_tasks/1` / `assign_active_tasks/1` / `reload_tasks/1` exactly as before — the call sites became non-blocking without any LiveView edit.

## Test Strategy (async sidebar load)

`test/evo_dash_web/live_hooks/node_aware_test.exs` is unit-style with bare `%Phoenix.LiveView.Socket{}`s. Because the spawned task's captured `view_pid` IS the test process (the `EvoDash.TaskSupervisor` runs under `mix test`), tests use the **send-pattern**: `assert_receive {:node_aware_active_tasks, seq, node_id, node, {running, pending}}` (1000ms timeout) / `refute_receive` (short timeout) on the message payload — never synchronous `assigns` assertions after a load-triggering call (the socket comes back unchanged). The **stale-guard** is tested directly via the public `handle_tasks_result/2` seam (pure socket in/out: node mismatch dropped, outdated seq dropped, matching case assigns). **Node-switch dedup** is tested by calling `assign_node/2` twice with the same context and `refute_receive`-ing the absence of a second spawn. LiveView integration tests (`projects_live_test.exs` etc.) need no changes — they don't assert sidebar assigns; if a future test does, use `render_async(view)` (or the send-pattern) to flush the async result before asserting.
