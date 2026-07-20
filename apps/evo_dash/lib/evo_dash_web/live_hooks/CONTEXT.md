# LiveHooks — On-Mount Hooks

## Intent

Phoenix LiveView on-mount hooks registered globally via the `live_view/0` macro in `evo_dash_web.ex`. Both hooks apply to ALL LiveViews automatically — no per-LiveView opt-in required.

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
- Sets initial node-context assigns: `@current_node`, `@current_node_name`, `@current_node_id`, `@remote_targets`, `@connection_statuses` (all with safe local defaults via `assign_new/3`).
- Subscribes to `EvoGit.PubSub` topic `"remote_connections"` when the socket is connected.

**Helper functions** (called by LiveViews):

| Function | Purpose |
|----------|---------|
| `assign_node/2` | Reads `?node=` query param in `handle_params/3`, resolving it to a saved+connected target or falling back to `:local`. |
| `current_node_display_name/1` | Returns display name for the current node. |
| `node_query_param/1` | Returns `%{node: id}` for appending to navigation URLs (threads node through all links). |
| `handle_connection_status/2` | Handles `{:remote_connection_status, id, status}` PubSub broadcasts, refreshing connection statuses. |
| `handle_node_selected/2` | Builds a `push_patch` to update the URL when a different node is selected. |

## Constraints

- Both hooks use `assign_new/3` (safe assigns — first-write-wins).
- Domain logic is delegated to `EvoDash.NodeContext` — hooks are thin wrappers.
- Safe fallbacks everywhere: locale defaults to `"en"`, node resolution falls back to `:local` on all failure paths.
- Node name fallback: "Local" when no remote node is active.

## Routing Table

None — leaf directory.
