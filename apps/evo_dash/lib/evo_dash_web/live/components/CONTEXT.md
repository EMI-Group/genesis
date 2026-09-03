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
- **Lifecycle**: `update/2` (assigns, also self-loads `@remote_targets`/`@connection_statuses`), `render/1` (HEEx markup), `handle_event/3` (node selection dropdown toggle).

## Constraints

- Uses `use EvoDashWeb, :live_component` — LiveComponent lifecycle, not LiveView.
- Styling: Tailwind CSS + DaisyUI.
- All domain logic stays in `EvoDash.NodeContext`; component is pure presentation + event routing.
- Uses Gettext for i18n.
- Connection management (add/edit/connect/disconnect/delete) is handled on the Settings page — this component only selects nodes and links to Settings.

## Known Issues — Theme/Markup (Adwaita restyle audit)

Verified against current code + app.css tokens (light/dark). Catalog only — nothing fixed:

- The ghost trigger's `hover:bg-base-200` (node_selector_component.ex:27) is **invisible**: the whole control sits on the `bg-base-200` sidebar, so the hover state equals the resting surface in BOTH themes (hover affordance is dead; the utility also overrides daisyUI's built-in `btn-ghost` base-content/10 hover). Sibling bottom-bar/collapse controls use `hover:bg-base-300`; nav links use `hover:bg-base-300/70`. Fix grammar: `hover:bg-base-300/70` (or `hover:bg-base-content/10`).
- Floating-dropdown boundary issues on the `bg-base-100/95` panel (:35 `border border-base-200`) and the two `border-t border-base-200` dividers (:52, :75): in the DARK theme the border is #242424 on #1e1e1e — effectively invisible; in light it is #f6f5f4 on white. App grammar for floating panels is `border-base-300` (guide panel, palettes). Fix grammar: `border-base-300` (or `border-base-content/10`).
- Per-target ssh meta line `text-xs text-base-content/50` (:68): ≈2.9:1 on the light panel — below the documented `/60` secondary-text floor; also inherits nothing from row hover. Fix grammar: at least `text-base-content/60`.
- Resting row/trigger text is `text-base-content/70` (~5:1 light / ~8:1 dark — acceptable); the app's primary-label grammar is `/80` (nav links), so `/70` resting is a slight inconsistency, not a readability bug.
