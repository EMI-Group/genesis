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
- Sets initial node-context assigns: `@current_node`, `@current_node_name`, `@current_node_id`, `@remote_targets`, `@connection_statuses` (all with safe local defaults via `assign_new/3`). Also seeds `:tasks_reload_pending` (`false`, debounce flag) and `:tasks_node_loaded` (`{nil, node()}`, dedup guard seed — kills the mount double-fetch, see below).
- Subscribes to `EvoGit.PubSub` topic `"remote_connections"` when the socket is connected.

**Statuses-filtered sidebar fetch** (`load_running_and_pending_tasks/1`): The sidebar "Active Tasks" fetch is **statuses-filtered** — only `[:running, :pending, :finalizing, :completed]` are loaded, so the SQL query skips finished tasks that can never appear in the sidebar (the sidebar shows running/pending tasks and derives `pending_tasks` review candidates from `:completed`). Local node: `EvoGit.TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :completed])`; remote node: `EvoDash.NodeContext.list_tasks_summary(node, [:running, :pending, :finalizing, :completed])` (RPC). The Elixir-side filtering logic (running filter + pending-review filter + sort) is unchanged.

**Debounced task reload** (trailing-edge, 300ms): `handle_task_info/2` no longer reloads synchronously on every broadcast — it calls `debounce_task_reload/1`, which coalesces broadcast bursts into a single reload:
- `debounce_task_reload/1` — if `Map.get(socket.assigns, :tasks_reload_pending, false)` is truthy, the intermediate broadcast is **dropped** (socket returned unchanged); otherwise it schedules `Process.send_after(self(), :node_aware_reload_tasks, 300)` and sets `:tasks_reload_pending` to `true`.
- `reload_tasks/1` — runs `load_running_and_pending_tasks/1` then clears `:tasks_reload_pending` to `false`. **LiveViews** handle the `:node_aware_reload_tasks` message with a `handle_info(:node_aware_reload_tasks, socket)` clause calling `{:noreply, NodeAware.reload_tasks(socket)}`.
- `clear_task_reload_pending/1` — clears `:tasks_reload_pending` without reloading (used by DashboardLive at the end of its custom reload clause).

**`assign_node/2` dedup guard** (`:tasks_node_loaded`): After the node-context `case` assigns `:current_node`/`:current_node_id`/`:current_node_name`, `assign_node/2` computes `context = {socket.assigns[:current_node_id], socket.assigns[:current_node]}`. If `Map.get(socket.assigns, :tasks_node_loaded) == context`, the socket is returned **without** reloading the sidebar; otherwise it reloads (`load_running_and_pending_tasks/1`) AND sets `:tasks_node_loaded` to `context`. Node switches (local↔remote, pending→connected) still reload since the context tuple differs. `on_mount` seeds `:tasks_node_loaded` with `{nil, node()}` (matching the local context that `assign_node/2` computes on first `handle_params`), which kills the previous mount double-fetch.

**Statuses API (RESOLVED — merged)**: The statuses forms of `list_tasks_summary` HAVE MERGED — `EvoGit.TaskRegistry.list_tasks_summary/1` (`task_registry.ex:116`, statuses \\ []), `list_tasks_summary_by_path/2`, `EvoDash.NodeContext.list_tasks_summary/2` and `EvoGit.RemoteNode.list_tasks_summary/2` (`remote_node.ex:358`) all exist, and the statuses filter is SQL-pushed-down (`WHERE status IN (...)`) all the way to the Store. The old "contract-pending / UndefinedFunctionError" notes are STALE — do not re-add them. Keep using the statuses-filtered form; it is the cheapest sidebar query.

**Helper functions** (called by LiveViews):

| Function | Purpose |
|----------|---------|
| `assign_node/2` | Reads `?node=` query param in `handle_params/3`, resolving it to a saved+connected target or falling back to `:local`. Includes the `:tasks_node_loaded` dedup guard — skips the sidebar reload when the node context tuple `{current_node_id, current_node}` is unchanged (see above). |
| `current_node_display_name/1` | Returns display name for the current node. |
| `node_query_param/1` | Returns `%{node: id}` for appending to navigation URLs (threads node through all links). |
| `handle_connection_status/2` | Handles `{:remote_connection_status, id, status}` PubSub broadcasts. Refreshes `@connection_statuses` always. When the status change is for the currently selected node AND represents a meaningful local↔remote transition (`:connected` local→remote, or `:disconnected`/`:error` remote→local), it does NOT update `@current_node` inline — instead it `push_patch`es the current path (preserving `?node=`) so `handle_params/3` re-runs and reloads ALL page-specific node data (remote agents, remote config, remote paused state, etc.). This is the DRYest fix: `handle_params` already contains all node-specific data loading, so re-running it uniformly reloads everything without per-page duplication. Non-transition statuses (`:connecting`, `:bootstrapping`, duplicate/non-selected node) only refresh statuses and do NOT reload. |
| `handle_node_selected/2` | Builds a `push_patch` to update the URL when a different node is selected. |
| `handle_task_info/2` | Handles task PubSub messages via the trailing-edge 300ms debounce (`debounce_task_reload/1`, message `:node_aware_reload_tasks`). |
| `debounce_task_reload/1` | Trailing-edge debounce — drops broadcasts while `:tasks_reload_pending` is truthy, otherwise schedules `:node_aware_reload_tasks` after 300ms and sets the flag. |
| `reload_tasks/1` | Executes the debounced reload (`load_running_and_pending_tasks/1`) and clears `:tasks_reload_pending`. LiveViews call this from their `handle_info(:node_aware_reload_tasks, socket)` clause. |
| `clear_task_reload_pending/1` | Clears `:tasks_reload_pending` without reloading (DashboardLive uses it at the end of its custom reload clause). |

## Constraints

- Both hooks use `assign_new/3` (safe assigns — first-write-wins).
- Domain logic is delegated to `EvoDash.NodeContext` — hooks are thin wrappers.
- Safe fallbacks everywhere: locale defaults to `"en"`, node resolution falls back to `:local` on all failure paths.
- Node name fallback: "Local" when no remote node is active.
- **Task reload debounce**: `handle_task_info/2` NEVER reloads synchronously — always go through `debounce_task_reload/1` → `:node_aware_reload_tasks` (300ms trailing-edge) → `reload_tasks/1`. LiveViews that do custom reloads must call `clear_task_reload_pending/1` afterwards so the next broadcast can schedule a fresh reload.
- **Sidebar dedup**: `assign_node/2` skips the sidebar reload when `:tasks_node_loaded == {current_node_id, current_node}`. Do not remove the guard without also handling the mount double-fetch it prevents.
- **Statuses API is merged (RESOLVED)**: the statuses forms `EvoGit.TaskRegistry.list_tasks_summary/1` and `EvoDash.NodeContext.list_tasks_summary/2` (via `EvoGit.RemoteNode.list_tasks_summary/2` → `EvoGit.AgentScheduler.RemoteAPI.list_tasks_summary/1`) exist in this worktree (SQL-pushed-down statuses IN filter). Do NOT revert `load_running_and_pending_tasks/1` to the unfiltered `/0`/`/1` calls — the statuses-filtered call is the whole point (skips finished rows in SQL).
