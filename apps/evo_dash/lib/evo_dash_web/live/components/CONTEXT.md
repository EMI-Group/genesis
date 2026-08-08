# LiveComponents

## Intent

LiveComponents (`use EvoDashWeb, :live_component`) rendered within parent LiveViews. Currently contains the `NodeSelectorComponent` for the SSH Remote Development feature — **currently UNRENDERED**: it lived in the retired `Layouts.app` sidebar, and the pad chrome (`PadComponents.pad_top_bar/1`) has no node selector. Kept for a future re-integration; remote connections are still managed under Settings → Remote Connections.

## Routing Table

None — leaf directory (single file: `node_selector_component.ex`).

## API Surface

### `EvoDashWeb.NodeSelectorComponent` (`node_selector_component.ex`)

A LiveComponent that renders a compact dropdown for switching between local and remote BEAM nodes. Previously rendered **inside the sidebar** via `Layouts.app/1` (deleted with the classic dashboard shell) — currently not mounted by any page.

- **Display**: Shows the current node name with a colored status dot (green = local, amber = connected remote, red = disconnected, slate = unknown).
- **Dropdown**: Lists Local node, saved remote targets with connection status dots, and a "Manage Connections..." link to the Settings page's Remote Connections category.
- **Delegation**: All domain operations delegate to `EvoDash.NodeContext` (`list_targets/0`, `connection_status/0`).
- **Events**: Sends `{:node_selected, node_id}` to the parent LiveView; the parent calls `NodeAware.handle_node_selected/2` to build a `push_patch` updating the URL.
- **Lifecycle**: `update/2` (assigns), `render/1` (HEEx markup), `handle_event/3` (node selection dropdown toggle).

## Constraints

- Uses `use EvoDashWeb, :live_component` — LiveComponent lifecycle, not LiveView.
- Styling: Tailwind CSS + DaisyUI.
- All domain logic stays in `EvoDash.NodeContext`; component is pure presentation + event routing.
- Uses Gettext for i18n.
- Connection management (add/edit/connect/disconnect/delete) is handled on the Settings page — this component only selects nodes and links to Settings.
