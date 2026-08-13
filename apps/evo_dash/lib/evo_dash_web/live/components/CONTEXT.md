# LiveComponents

## Intent

LiveComponents (`use EvoDashWeb, :live_component`) rendered within parent LiveViews. Currently contains the `NodeSelectorComponent` for the SSH Remote Development feature — rendered in the navbar next to the brand logo via `Layouts.app/1`.

## Routing Table

None — leaf directory (single file: `node_selector_component.ex`).

## API Surface

### `EvoDashWeb.NodeSelectorComponent` (`node_selector_component.ex`)

A LiveComponent that renders a compact dropdown for switching between local and remote BEAM nodes. It is rendered **inside the sidebar** (not a top navbar) via `Layouts.app/1`, in the node selector slot below the brand header.

- **Display**: Shows the current node name with a colored status dot (green = local, blue = connected remote, amber+pulse = connecting/disconnecting, rose = error, slate = disconnected).
- **Dropdown**: Lists Local node, saved remote targets with connection status dots, and a "Manage Connections..." link to the Settings page's Remote Connections category.
- **Unified dot helper**: the trigger `<summary>` dot AND all dropdown items (Local item + per-target items) render through the SAME private `dot_color_class/2`, which always returns the FULL shape+color class string (`w-2 h-2 rounded-full shrink-0` + phase color) — the remote trigger dot is therefore visible and consistent with the dropdown (do not hand-compose shape classes or call `target_dot_color/2` directly from the template). `target_dot_color/2` is the single source of truth for the phase→color mapping (blue `:connected`, amber+pulse `:connecting`/`:disconnecting`, rose `:error`, slate `:disconnected`/unknown).
- **Manage-Connections link node param**: the link's `navigate` builds the URL as `~p"/settings?category=remote_connections" <> (if @current_node_id, do: "&node=#{@current_node_id}", else: "")` — the `&node=` suffix is a RAW string append AFTER the `~p` sigil. Interpolating the suffix INSIDE the `~p` sigil percent-encodes it (`%26node%3D...`) and the node param never survives; `EvoDashWeb.Helpers.with_node_param/2` would append with `?` and is also wrong for URLs that already have a query string.
- **Delegation**: All domain operations delegate to `EvoDash.NodeContext` (`list_targets/0`, `connection_status/0`).
- **Events**: Sends `{:node_selected, node_id}` to the parent LiveView; the parent calls `NodeAware.handle_node_selected/2` to build a `push_patch` updating the URL.
- **Lifecycle**: `update/2` (assigns, also self-loads `@remote_targets`/`@connection_statuses`), `render/1` (HEEx markup), `handle_event/3` (node selection dropdown toggle).

## Constraints

- Uses `use EvoDashWeb, :live_component` — LiveComponent lifecycle, not LiveView.
- Styling: Tailwind CSS + DaisyUI.
- All domain logic stays in `EvoDash.NodeContext`; component is pure presentation + event routing.
- Uses Gettext for i18n.
- Connection management (add/edit/connect/disconnect/delete) is handled on the Settings page — this component only selects nodes and links to Settings.
