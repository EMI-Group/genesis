# Frontend JavaScript Source

## Intent

Client-side JavaScript for the EvoDash dashboard: the main entry (`app.js`, LiveSocket setup + all inline hooks), the highlight.js global-exposer (`highlight_setup.js`, a module side effect, NOT a hook), the standalone hook modules under `./hooks/`, and the Node-run unit tests for inline and standalone hooks (`*.test.cjs` and `hooks/*.test.cjs`). Bundled by esbuild via `mix assets.build`. See `../assets/CONTEXT.md` for build tooling and `./hooks/CONTEXT.md` for the hook registration table + behavior notes.

## Routing Table

- `./hooks/` → Standalone LiveView hook files (`sidebar_collapse.js`, `node_switch_fade.js`, `adaptive_input.js`, `legend_tooltip.js`, `diff_viewer.js`, `commit_graph.js`, `capsule_panel.js`, `inspector_messages.js`) + `hooks/CONTEXT.md`
- `./*.test.cjs` and `./hooks/*.test.cjs` → Node-run inline-hook and standalone-hook tests — `node --test apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`, never part of `mix test` (see "JS Unit Tests")
- `app.js` → Main entry — LiveSocket, inline hooks (`TauriDetect`, `DesktopQuit`, `DesktopQuitConfirm`, `UpdateStatus`, `PlatformDetect`, `PathAutocomplete`, `DirectoryPicker`, `FilePicker`, `Guide`, `StatePersistence`, `AutoClearFlash`, `ClipboardCopy`, `AgentHistoryAutoScroll`, `DialogModal`, `FocusInput`, `PaletteList`), topbar wiring, guide-client-id sessionStorage
- `browser_notifications.js` → Imported `BrowserNotifications` hook for advisory document notifications, explicit permission enablement, scoped approval review and notification lifecycle cleanup.
- `browser_notifications.test.cjs` → Focused Node/VM tests of the actual notification hook with browser/host seams.
- `highlight_setup.js` → Exposes the vendored highlight.js instance as `window.hljs` (module side effect — must evaluate BEFORE the cdnjs language-pack IIFE imports in `app.js`; load-order contract + pack list in `../assets/CONTEXT.md`)

## Constraints

- **Theme safety (GNOME/libadwaita restyle — AUDITED, holds as of the audit)**: JS in this tree must NEVER introduce color literals (hex/rgb/hsl/named), never write theme colors via `element.style.*`/`setAttribute("style", ...)`/canvas fills, and never add theme-specific Tailwind color classes from JS. Theme tokens (`--color-*`) are CSS custom properties that CANNOT be read from JS (canvas contexts excluded). All visuals must flow through CSS classes/tokens in `../css/app.css`. The ONE documented exception: the canvas-bound topbar progress colors (`app.js:1136`, `barColors: {0: "#29d"}` + `rgba(0,0,0,.3)` shadow — vendor/topbar.js paints a `<canvas>`, where color strings cannot resolve CSS vars) — carries the `// Adwaita:` comment at `app.js:1131-1135`; do not remove it, do not add siblings.
- **Theme switching is NOT JS's job**: no JS here toggles a `dark`/`light` class, reads `data-theme`, or matches `prefers-color-scheme` — the inline script in `root.html.heex` (server subtree) owns `data-theme` on `<html>` (localStorage `phx:theme`, tri-state). JS must never assume a theme or read `getComputedStyle` for colors (layout metrics like maxHeight/lineHeight are fine — `adaptive_input.js:220`).
- **Body-appended elements** (e.g. LegendTooltip's fixed tip): theme tokens still resolve (inherited from `:root` via `html[data-theme]`), but they sit OUTSIDE `#app-layout`'s `data-accent-color` scope — keep base blue/neutral; use `--color-neutral*` (as `.agents-legend-tip` does) or explicit tokens, never accent-dependent assumptions.
- **JS-added classes are structural or token-based only**: verified examples — SidebarCollapse width/translate/opacity layout classes, NodeSwitchFade `.node-switch-fade` (CSS opacity keyframes), Guide `.guide-highlight` (CSS `var(--color-primary)` outline), ClipboardCopy's 2s `text-success` icon tint (`app.js:539`; `--color-success` defined per theme in `css/app.css`, dark L46 / light L94; class round-tripped from `origClass`), AdaptiveInput `--app-vh` var sync on `documentElement` (`adaptive_input.js:87`).
- DiffViewer injects ONLY highlight.js `<span class="hljs-*">` token markup (`diff_viewer.js:83`) — `.hljs-*` colors live in CSS for both themes; never add inline colors to the hook.

## Projects State Persistence

`StatePersistence` in `app.js` stores one JSON object in `sessionStorage` under `dashboard_state` and sends that object back through `restore_state` on mount.
That object is single-project form state: `project` (the ONE active project path, read from the root's `data-project`), `task_mode`, `node`, `task_prompt`, `task_node_path`, `task_seeds`, `task_starting_commit`, optionally `selected_model_id` (legacy) and `model_spec` (`{}` = explicit Auto), plus server-managed keys merged in and preserved (e.g. `foreign_repos`).
There is NO client-side persistence of open project tabs, a project list, a "last opened project" or recent projects — projects are the core's VCT mounts (server-side, in the task store), ProjectsLive owns the `"vct"` PubSub subscription (`{:vct_updated, node}`) and reloads the list server-side, and no JS in this tree handles project data (the `StatePersistence` hook only round-trips `dashboard_state`).
Browser storage keys owned here: `dashboard_state` (sessionStorage), `guide_client_id` (sessionStorage), `sidebar-collapsed` (localStorage); `phx:theme` (localStorage) belongs to the inline script in `root.html.heex`, not this tree.
The `persist_model_selection` server event carries `{node, model_spec}`, where `model_spec` is a string-keyed map containing `provider_profile_id`, `model`, and optional `reasoning_effort`, or the explicit empty map `{}` for Auto.
The handler merges only `node` and `model_spec`, leaving the saved prompt and unrelated fields untouched, and accepts an event only for the root's current `data-node-id` (default `local`) and the saved state's node when storage already exists.
Node-less legacy state belongs to `local`, and a picker-only event must never relabel another node's pending saved state.
The debounced form watcher reads the latest saved object when it runs, preserving canonical selection including `{}`, and writes `selected_model_id` only when a legacy `[name="model_id"]` selector actually exists.
The full `persist_state` event still replaces the saved object while taking `task_prompt` from the DOM to protect unsent typing.
Focused regressions for this hook live in `state_persistence.test.cjs` (see "JS Unit Tests" below).

## JS Unit Tests (Node's built-in test runner)

`./agent_history_scroll.test.cjs` and `./state_persistence.test.cjs` cover the PURE logic of the inline hooks in `app.js`; they are NEVER part of `mix test`.
Run all asset Node tests from the repository root with `node --test apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`, or pass one file path for a focused run.
Both use Node's built-in runner (`node:test` + `node:assert/strict`) and `node:vm` over source sliced out of `app.js`, so no browser bundle or DOM library is loaded.
`agent_history_scroll.test.cjs` slices the block from the `// --- AgentHistoryAutoScroll: pure pinning decision` marker to the `// AgentHistoryAutoScroll hook:` marker and asserts the 56 px inclusive pin boundary, the overscroll/rubber-band answers, unmeasurable geometry, the explicit-threshold override and the default threshold's documented 48–64 px band.
The DOM half of that hook (rAF coalescing, observers, listeners) carries no decision of its own and is deliberately not faked.
`state_persistence.test.cjs` runs the real `StatePersistence` hook object against `sessionStorage`/timer stubs and asserts the saved-state shape, node scoping and the `persist_model_selection` merge.
`hooks/inspector_messages.test.cjs` runs the real `InspectorMessages` hook against a small DOM seam using `node:vm`, covering message-entry animation, scope changes, reduced motion and lifecycle cleanup without browser packages.

## BrowserNotifications Integration Contract

`browser_notifications.js` exports the hook registered as `BrowserNotifications` in `app.js`.
The Assistant host must wrap its in-app approval status bar, including a native `<button type="button" data-enable-notifications>` and a `[data-notification-status]` text node (preferably `role="status"`), so delegated clicks request permission directly from an explicit user gesture.
Projects may retain its existing hidden notification host with no controls or approval metadata.
The host supplies gettext-translated `data-notification-label-unsupported`, `data-notification-label-denied`, `data-notification-label-default`, `data-notification-label-granted`, `data-notification-label-requesting` and `data-notification-label-error` attributes; the hook copies the selected label via `textContent` and exposes the state in `data-notification-status` on the host.
The labels must honestly explain unsupported API/insecure context, browser-denied permission, explicit enablement needed, enabled advisory delivery, pending browser prompt and failed browser operation respectively, without implying approvals are delivered reliably.
The enable button's own text is server-rendered gettext; the hook hides it unless permission is default and requestPermission exists, and disables it while requesting.
No permission prompt runs on mount, patch or focus, permission is read live rather than cached, and focus, visibilitychange, reconnect and updates refresh the status.
The `task_notification` event accepts `{title: string, body?: string, tag?: string, request_id?: string}`; titles must be nonblank, non-string bodies become empty, and callers own sensitive-content minimization.
Notifications show only with granted permission while the document is hidden OR the window is unfocused, preserving the terminal-task gate.
For approval notifications the host must render `data-approval-scope` as a nonblank opaque identity covering the viewed node/target and session, and `data-approval-request-ids` as a JSON array of nonblank string IDs scoped to that host.
Approval identity is validated at creation and again on click against the current DOM attributes and the captured scope; missing/malformed metadata or an invalid/non-pending request_id fails closed.
A valid approval click only focuses the window, closes the notification and pushes `review_approval_notification` with `{request_id}` for server-validated in-app review; it NEVER pushes allow/deny, approval_response or execution authority.
Notifications without request_id only focus and close, even if tagged, so terminal-task producers remain compatible.
LiveView must update pending IDs on resolution and change scope when switching node/session; `updated()` closes resolved notifications and all notifications on a scope change, while click-time validation also protects the pre-update race.
Tags and request IDs deduplicate tracked notifications, native close releases records, and disconnect/destroy close all notifications; destroy removes delegated/global listeners and the LiveView event handler and makes late permission completions inert.
Constructor/prompt failures render the translated error state without throwing or logging sensitive payloads; absent/denied APIs remain fallback states and in-app pending review remains mandatory.
This is advisory document notification delivery only, with no service worker, persistent actions, background push, closed-page delivery, replay or click-to-authorize.
Focused tests run with `node --test apps/evo_dash/assets/js/browser_notifications.test.cjs`.

## Known Issues
`app.js:807–987` AgentHistoryAutoScroll follows instantly with a 56 px inclusive threshold, disconnects observers when unpinned and cleans up frames/listeners/observers, but only its pure geometry predicate has Node coverage.
The scroller and direct children are observed, and missing ResizeObserver means patch-driven following only; frame scheduling, observer lifecycle, reconnect and keyboard/scroll races are untested.
`app.js:1338–1381` DialogModal guards showModal, latches user dismissal and removes its listener before teardown close, but has no fallback when showModal is absent or throws and no explicit focus-return target or dialog labelling.
Consuming markup and browser-level tests must establish native-dialog focus behavior, accessible names and fallback access to pending approvals.
`app.js:1270–1318` Guide and `1399–1414` PaletteList request smooth scrolling without reduced-motion checks; Guide does not catch malformed selector errors or cancel retry/highlight timers on dismissal or destruction.
`app.js:1387–1397` FocusInput focuses on mount and refocuses focus-on-update elements on every patch, so consuming pages must prevent focus theft while another control or dialog owns focus.
No Node tests here cover DialogModal, Guide, PaletteList or FocusInput; standalone animation/accessibility gaps and their tests are documented in `hooks/CONTEXT.md`.
