# JS Hooks

## Intent

Phoenix LiveView JavaScript hooks for the EvoDash dashboard. A LiveView JS hook is a plain
JS object with lifecycle callbacks (`mounted`, `updated`, `destroyed`) registered with the
`LiveSocket` and attached to a DOM element via the `phx-hook="<Name>"` attribute.

## API Surface

### Hook Registration

All hooks are registered in `../app.js` in the `LiveSocket` constructor's `hooks:` map
(line ~485):

```js
import {hooks as colocatedHooks} from "phoenix-colocated/evo_dash"
import SidebarCollapse from "./hooks/sidebar_collapse.js"
// ...
hooks: {...colocatedHooks, TauriDetect, PlatformDetect, PathAutocomplete,
        DirectoryPicker, StatePersistence, BrowserNotifications, AutoClearFlash,
        ScrollToFile, ClipboardCopy, AgentHistoryAutoScroll, DialogModal, SidebarCollapse}
```

### Where each hook is defined

| Hook | Defined in | Attached to (HEEx) |
|------|-----------|--------------------|
| `SidebarCollapse` | `./sidebar_collapse.js` (own file, ES module default export) | `layouts.ex` `<aside id="sidebar" phx-hook="SidebarCollapse">` |
| `PathAutocomplete` | `../app.js` (inline, line ~43) | `project_components.ex` path inputs (`phx-hook="PathAutocomplete"`) |
| `DirectoryPicker` | `../app.js` (inline, line ~107) | `project_components.ex` browse buttons (`phx-hook="DirectoryPicker"`) |
| `StatePersistence` | `../app.js` (inline, line ~170) | `dashboard_live.ex` dashboard root (`phx-hook="StatePersistence"`) |
| `BrowserNotifications` | `../app.js` (inline, line ~244) | `dashboard_live.ex` (`phx-hook="BrowserNotifications"`) |
| `TauriDetect` | `../app.js` (inline, line ~435) | `dashboard_live.ex` (`phx-hook="TauriDetect"`) |
| `PlatformDetect` | `../app.js` (inline, line ~442) | `dashboard_live.ex` (`phx-hook="PlatformDetect"`) |
| `ClipboardCopy` | `../app.js` (inline, line ~259) | `settings_live.ex`, `review_components/header.ex` |
| `AutoClearFlash` | `../app.js` (inline, line ~283) | `core_components.ex` flash component |
| `ScrollToFile` | `../app.js` (inline, line ~300) | `review_components/diff_viewer.ex` (`phx-hook="ScrollToFile"`) |
| `AgentHistoryAutoScroll` | `../app.js` (inline, line ~348) | `agents_live.html.heex` (`phx-hook="AgentHistoryAutoScroll"`) |
| `DialogModal` | `../app.js` (inline, line ~463) | (native `<dialog class="modal">` elements) |

### SidebarCollapse — selector contract

The only hook in its own file. It manages desktop sidebar collapse with `localStorage`
persistence (`"sidebar-collapsed"`, `"true"`/`"false"`). It toggles these selectors on the
`<aside id="sidebar">` element (from `layouts.ex`):

- `.sidebar-label` — text spans hidden when collapsed (brand text, section headers, task labels)
- `.sidebar-collapsed-only` — compact elements shown only when collapsed (task status dots + 6-char IDs)
- `[data-sidebar-bottom-bar]` — bottom container: switches between `flex justify-between` (expanded) and `flex-col items-center` (collapsed)
- `[data-sidebar-bottom-group]` — button group inside the bottom bar (same flex-dir toggle)
- `#sidebar-collapse-toggle` — the chevron button; swaps `hero-chevron-double-left` ↔ `hero-chevron-double-right` via innerHTML regex replacement and updates its `title`
- width: toggles `w-60` (expanded, 240px) ↔ `w-16` (collapsed, 64px). Overflow stays `overflow-visible` in BOTH states — dropdown menus (SSH node selector `w-72` = 288px, language, theme) extend beyond the expanded sidebar's `w-60` = 240px edge without being clipped. Do NOT re-add `overflow-hidden` on expand (that was the root cause of the clipped node-selector dropdown).

**Critical**: the `updated()` callback re-applies state on every LiveView update because
LiveView's morphdom resets server-rendered classes after navigation, which would otherwise
undo the collapse state. This is why collapse state survives route changes.

## Constraints

- **NOT colocated**: the parent `CONTEXT.md` (at `../assets/CONTEXT.md`) mentions hooks are
  "sourced from `phoenix-colocated/evo_dash` (generated hooks from colocated `.exh` hook files)".
  This is OUTDATED — there are **zero `.exh` files** in the project. The `colocatedHooks`
  import resolves to an empty object; ALL hooks are hand-written (one in this directory, the
  rest inline in `app.js`). Do not rely on `.exh` colocated hook generation.
- `SidebarCollapse` is the only hook exported as a proper ES module (`export default`); the
  rest are `const` objects declared inline in `app.js`.
- **Mobile sidebar toggle**: The `#sidebar-mobile-toggle` hamburger button and
`#sidebar-overlay` (lines 50-62 of `layouts.ex`) are wired up by the
`SidebarCollapse` hook. On mobile (< lg breakpoint, checked via
`window.matchMedia('(max-width: 1023.98px)')`):
- Hamburger click **opens** the sidebar (removes `-translate-x-full` from
  `#sidebar`, shows overlay by removing `opacity-0`/`pointer-events-none`,
  locks body scroll via `overflow-hidden`).
- Overlay click **closes** the sidebar (reverses the above).
- Nav link clicks inside the sidebar close it (event delegation on the
  sidebar element, survives morphdom re-renders).
- `updated()` re-applies the mobile open/close state after LiveView
  navigation patches reset the sidebar's classes.
Mobile state is tracked independently from desktop collapse state via
`this.mobileOpen`. On desktop, the mobile handlers are no-ops (guarded by
`isMobile()`).
- **`SetLocale` is NOT a JS hook** — it is a server-side Elixir LiveView on-mount hook
  (`EvoDashWeb.LiveHooks.SetLocale` in `lib/evo_dash_web/live_hooks/set_locale.ex`).
  Do not look for it in JS assets.
