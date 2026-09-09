# LiveComponents

## Intent

LiveComponents (`use EvoDashWeb, :live_component`) rendered within parent LiveViews. Currently contains the `NodeSelectorComponent` for the SSH Remote Development feature — rendered via `Layouts.app/1` in the sidebar's BOTTOM bar (leftmost; invoked with `drop_up={true}` at `components/layouts.ex` ~L239) — NOT a top navbar.

## Routing Table

None — leaf directory (single file: `node_selector_component.ex`).

## API Surface

### `EvoDashWeb.NodeSelectorComponent` (`node_selector_component.ex`)

A LiveComponent that renders a compact dropdown for switching between local and remote BEAM nodes. It is rendered **inside the sidebar** (not a top navbar) via `Layouts.app/1`, in the node selector slot of the sidebar bottom bar (leftmost of the bottom group; its dropdown opens UPWARD over the main content).

- **Display**: Shows the current node name with a colored status dot (blue `bg-info` = local, green `bg-success` = connected remote, amber+pulse = connecting/disconnecting, rose `bg-error` = error, slate `bg-base-content/40` = disconnected — mapping owned by `EvoDashWeb.Helpers.connection_status_dot_class/1`).
- **Dropdown**: Lists Local node, saved remote targets with connection status dots, and a "Manage Connections..." link to the Settings page's Remote Connections category.
- **Unified dot renderer**: the trigger `<summary>` dot AND all dropdown items (Local item + per-target items) render through the SAME private `dot_color_class/2` → `dot_shape/1`, which always returns the FULL shape+color class string (`w-2 h-2 rounded-full shrink-0` + phase color + pulse) — the remote trigger dot is therefore visible and consistent with the dropdown (do not hand-compose shape classes or call `EvoDashWeb.Helpers.connection_status_dot_class/1` directly from the template). `connection_status_dot_class/1` is the single source of truth for the phase→color mapping (blue `bg-info` `:local`, green `bg-success` `:connected`, amber `bg-warning` `:connecting`/`:disconnecting`, rose `bg-error` `:error`, slate `bg-base-content/40` `:disconnected`/`:unknown`); the private `remote_phase/2` reads `%{phase: ...}` from the `@connection_statuses` map.
- **Manage-Connections link node param**: the link's `navigate` builds the URL as `~p"/settings?category=remote_connections" <> (if @current_node_id, do: "&node=#{@current_node_id}", else: "")` — the `&node=` suffix is a RAW string append AFTER the `~p` sigil. Interpolating the suffix INSIDE the `~p` sigil percent-encodes it (`%26node%3D...`) and the node param never survives; `EvoDashWeb.Helpers.with_node_param/2` would append with `?` and is also wrong for URLs that already have a query string.
- **Delegation**: All domain operations delegate to `EvoDash.NodeContext` (`list_targets/0`, `connection_status/0`).
- **Events**: Sends `{:node_selected, node_id}` to the parent LiveView; the parent calls `NodeAware.handle_node_selected/2` to build a `push_patch` updating the URL.
- ⚠️ **`select_node` auto-connect is SYNCHRONOUS, not async** (`node_selector_component.ex:117-131`): when a remote target is picked and `connected?/1` is false, `handle_event("select_node", ...)` calls `EvoDash.NodeContext.connect(node_id)` INLINE in the parent LiveView process and DISCARDS the return value, then `send(self(), {:node_selected, node_id})`. The in-code comment ("The GenServer handles it in the background") is misleading — `EvoGit.RemoteConnection.connect/1` is a synchronous `GenServer.call` (25 s timeout) that runs the whole SSH-tunnel + `Node.connect` handshake inline in its `handle_call`, so the LiveView process BLOCKS until connect finishes (up to 25 s worst case). `connect` is never wrapped in a Task anywhere in the web layer (only Settings' `bootstrap` is, via `Task.start`). If the server exceeds the 25 s call timeout, NodeContext's `with_remote_connection` `catch :exit` returns `{:error, :remote_connection_unavailable}` (no crash, but a ~25 s freeze and a misleading error value; the remote may still connect and the later `{:remote_connection_status, target_id, %{phase: :connected}}` broadcast on `"remote_connections"` reconciles the UI — note the core does NOT broadcast `:connecting` or connect-failure transitions). An async-connect fix would reuse the `TaskSupervisor` + self-message + stale-guard pattern from the node-aware data loads.
- **Lifecycle**: `update/2` (assigns, also self-loads `@remote_targets`/`@connection_statuses`), `render/1` (HEEx markup), `handle_event/3` (node selection dropdown toggle).

## Constraints

- Uses `use EvoDashWeb, :live_component` — LiveComponent lifecycle, not LiveView.
- Styling: Tailwind CSS + DaisyUI.
- All domain logic stays in `EvoDash.NodeContext`; component is pure presentation + event routing.
- Uses Gettext for i18n.
- Connection management (add/edit/connect/disconnect/delete) is handled on the Settings page — this component only selects nodes and links to Settings.

## Notes for Agents — theme grammar (Adwaita)

- Floating panels/dividers on content surfaces use `border-base-300` (base-200 is the "chrome/hover" tone). The ghost trigger's hover on the `bg-base-200` sidebar is `hover:bg-base-300`; dropdown item rows (on the `bg-base-100/95` panel) keep `hover:bg-base-200` (visible there).
- Alpha floor: meta/labels ≥ `text-base-content/60`; small/primary content ≥ `/70`. Resting row/trigger text here is `/70` — acceptable; the app's primary-label grammar is `/80` (nav links), so `/70` resting is a slight inconsistency, not a bug.

## Known Issues

- **`select_node` on an unconnected remote target blocks the whole page**: `handle_event("select_node", ...)` (node_selector_component.ex:117-131) calls `EvoDash.NodeContext.connected?/1` then `EvoDash.NodeContext.connect/1` SYNCHRONOUSLY in the parent LiveView process and discards the result — the code comment at :118-120 ("initiate the connection asynchronously… the GenServer handles it in the background") is wrong. `NodeContext.connect/1` is a blocking `:gen_server.call` with a 25s timeout (`@connect_call_timeout_ms` = 10s tunnel wait budget + 15s, `apps/evo_git/lib/evo_git/remote_connection.ex:111, 218-223`); `handle_call(:connect)` runs the whole connect flow inside the manager (spawn `ssh -L` port → `wait_for_tunnel/4` poll up to 10s → `Node.connect/1`, remote_connection.ex:350-557). The page freezes ~1.5-2s on success, up to ~10s (25s worst case) on failure; `{:node_selected, ...}` navigation fires only after the call returns. Fix direction: fire-and-forget the connect (unlinked `Task.start` like the settings bootstrap at `live/settings_live.ex:1809-1812`, or a `EvoDash.TaskSupervisor` spawn), return `{:noreply, socket}` immediately, send `{:node_selected, ...}` right away, and let the success broadcast on `EvoGit.PubSub` `"remote_connections"` (`{:remote_connection_status, ...}`) drive `NodeAware.handle_connection_status/2`. Caveat: connect FAILURES never broadcast in the core connect path (only the success path broadcasts, remote_connection.ex:530; error states at :542-555 just return `{:error, ...}`), so a failure must be surfaced via a status refresh or a task-result message.

## Known Issues

- **`select_node` on an unconnected remote target blocks the whole page**: `handle_event("select_node", ...)` (node_selector_component.ex:117-131) calls `EvoDash.NodeContext.connected?/1` then `EvoDash.NodeContext.connect/1` SYNCHRONOUSLY in the parent LiveView process and discards the result — the code comment at :118-120 ("initiate the connection asynchronously… the GenServer handles it in the background") is wrong. `NodeContext.connect/1` is a blocking `:gen_server.call` with a 25s timeout (`@connect_call_timeout_ms` = 10s tunnel wait budget + 15s, `apps/evo_git/lib/evo_git/remote_connection.ex:111, 218-223`); `handle_call(:connect)` runs the whole connect flow inside the manager (spawn `ssh -L` port → `wait_for_tunnel/4` poll up to 10s → `Node.connect/1`, remote_connection.ex:350-557). The page freezes ~1.5-2s on success, up to ~10s (25s worst case) on failure; `{:node_selected, ...}` navigation fires only after the call returns. Fix direction: fire-and-forget the connect (unlinked `Task.start` like the settings bootstrap at `live/settings_live.ex:1809-1812`, or a `EvoDash.TaskSupervisor` spawn), return `{:noreply, socket}` immediately, send `{:node_selected, ...}` right away, and let the success broadcast on `EvoGit.PubSub` `"remote_connections"` (`{:remote_connection_status, ...}`) drive `NodeAware.handle_connection_status/2`. Caveat: connect FAILURES never broadcast in the core connect path (only the success path broadcasts, remote_connection.ex:530; error states at :542-555 just return `{:error, ...}`), so a failure must be surfaced via a status refresh or a task-result message.
