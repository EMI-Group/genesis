# Frontend JavaScript Source

## Intent

Client-side JavaScript for the EvoDash dashboard: `app.js` (a thin entry — the `LiveSocket` + `hooks:` map, the hooks declared inline, topbar wiring, live-reload dev tooling), the highlight.js global-exposer (`highlight_setup.js`, a module side effect, NOT a hook), the hook modules under `./hooks/`, and the Node-run unit tests for both (`*.test.cjs` and `hooks/*.test.cjs`). Bundled by esbuild via `mix assets.build`. See `../assets/CONTEXT.md` for build tooling and `./hooks/CONTEXT.md` for the hook registration table + behavior notes.

## Routing Table

- `./hooks/` → LiveView hook modules (`sidebar_collapse.js`, `node_switch_fade.js`, `adaptive_input.js`, `legend_tooltip.js`, `diff_viewer.js`, `commit_graph.js`, `capsule_panel.js`, `inspector_messages.js`, `directory_picker.js`, `file_picker.js`, `state_persistence.js`, `agent_history_scroll.js`, `desktop_quit.js`, `update_status.js`, `guide.js`, `list_enter.js`, the assistant pair in `assistant_disclosure.js`/`assistant_composer.js`, the workbench trio in `workbench.js` + `workbench_project_preview.js` + the pure `workbench_panel.js`, and the shared `disclosure_motion.js` motion foundation) + `hooks/CONTEXT.md`
- `./hooks/workbench.js` → `Workbench` (the `#app-layout` workbench: tabs, project windows, sidebars, the animated right panel, Git pane, create menu, settings window), `WorkbenchSection` and `WorkbenchWindow`; its right-panel decisions are the pure `./hooks/workbench_panel.js` module.
- `./hooks/workbench_panel.js` → PURE right-panel state machine (`closed | open | closing`) consumed by `workbench.js` and sliced by `./hooks/workbench_panel.test.cjs`.
- `./hooks/directory_picker.js` → `DirectoryPicker` — thin LiveView client for the server-side native dialogs: a click pushes `directory_pick`, and one handler per `picker_result:<id>` fills the input (auto-submitting where the pick is a project) or reveals the manual fallback.
- `./hooks/file_picker.js` → `FilePicker` — the objective editor's "+" attach dropdown: kind-aware `file_pick`/`file_pick_manual` pushes, append-not-clobber textarea writes, and a teardown that removes its handlers from both the hook element and the `#objective-file-manual` sibling that outlives a `<details>` teardown.
- `./hooks/state_persistence.js` → `StatePersistence` — the scoped `sessionStorage` draft save/restore plus the debounced form watcher; storage-key contract below.
- `./hooks/agent_history_scroll.js` → `AgentHistoryAutoScroll` plus the named pure exports `shouldFollowLatest` and `STICK_TO_BOTTOM_THRESHOLD_PX`.
- `./hooks/desktop_quit.js` → `DesktopQuit` + `DesktopQuitConfirm` (the Tauri quit bridge).
- `./hooks/update_status.js` → `UpdateStatus` — the once-bound module-level listener/timer pattern and its `invokeUpdate*` helpers.
- `./hooks/guide.js` → `Guide` plus the named export `guideClientId` (the stable per-tab id `app.js` passes in the connect params).
- `./hooks/list_enter.js` → `ListEnter` plus the named pure exports `planListEnter`/`LIST_ENTER_CLASS` — the shared list entry animation.
- `./*.test.cjs` and `./hooks/*.test.cjs` → Node-run tests, one file per covered module — `node --test apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`, never part of `mix test` (see "JS Unit Tests")
- `app.js` → Main entry — the `LiveSocket` + `hooks:` map, the `longestCommonPrefix` helper, the hooks declared inline (`TauriDetect`, `PathAutocomplete`, `ClipboardCopy`, `AutoClearFlash`, `PlatformDetect`, `FocusInput`, `PaletteList`), topbar wiring and live-reload dev tooling
- `dialog_modal.js` → Imported `DialogModal` review-only dialog hook with safe initial focus, focus restoration, native modal opening and visible nonmodal fallback.
- `dialog_modal.test.cjs` → Focused Node/VM tests of the real dialog hook with DOM/native-dialog seams.
- `browser_notifications.js` → Imported `BrowserNotifications` hook for advisory document notifications, explicit permission enablement, scoped approval review and notification lifecycle cleanup.
- `browser_notifications.test.cjs` → Focused Node/VM tests of the actual notification hook with browser/host seams.
- `highlight_setup.js` → Exposes the vendored highlight.js instance as `window.hljs` (module side effect — must evaluate BEFORE the cdnjs language-pack IIFE imports in `app.js`; load-order contract + pack list in `../assets/CONTEXT.md`)

## Constraints

- **Theme safety (GNOME/libadwaita restyle — AUDITED, holds as of the audit)**: JS in this tree must NEVER introduce color literals (hex/rgb/hsl/named), never write theme colors via `element.style.*`/`setAttribute("style", ...)`/canvas fills, and never add theme-specific Tailwind color classes from JS. Theme tokens (`--color-*`) are CSS custom properties that CANNOT be read from JS (canvas contexts excluded). All visuals must flow through CSS classes/tokens in `../css/app.css`. The ONE documented exception: the canvas-bound topbar progress colors (`app.js:346`, `barColors: {0: "#29d"}` + `rgba(0,0,0,.3)` shadow — vendor/topbar.js paints a `<canvas>`, where color strings cannot resolve CSS vars) — carries the `// Adwaita:` comment at `app.js:341-345`; do not remove it, do not add siblings.
- **Theme switching is NOT JS's job**: no JS here toggles a `dark`/`light` class, reads `data-theme`, or matches `prefers-color-scheme` — the inline script in `root.html.heex` (server subtree) owns `data-theme` on `<html>` (localStorage `phx:theme`, tri-state). JS must never assume a theme or read `getComputedStyle` for colors (layout metrics like maxHeight/lineHeight are fine — `adaptive_input.js:220`).
- **Body-appended elements** (e.g. LegendTooltip's fixed tip): theme tokens still resolve (inherited from `:root` via `html[data-theme]`), but they sit OUTSIDE `#app-layout`'s `data-accent-color` scope — keep base blue/neutral; use `--color-neutral*` (as `.agents-legend-tip` does) or explicit tokens, never accent-dependent assumptions.
- **JS-added classes are structural or token-based only**: verified examples — SidebarCollapse width/translate/opacity layout classes, NodeSwitchFade `.node-switch-fade` (CSS opacity keyframes), Guide `.guide-highlight` (CSS `var(--color-primary)` outline), ClipboardCopy's 2s `text-success` icon tint (`app.js:199`; `--color-success` defined per theme in `css/app.css`, dark L46 / light L94; class round-tripped from `origClass`), AdaptiveInput `--app-vh` var sync on `documentElement` (`adaptive_input.js:114`), ListEnter's `motion-list-enter` class (keyframes/tokens from `../css/motion.css`).
- DiffViewer injects ONLY highlight.js `<span class="hljs-*">` token markup (`diff_viewer.js:204`) — `.hljs-*` colors live in CSS for both themes; never add inline colors to the hook.

## Projects State Persistence

`StatePersistence` in `./hooks/state_persistence.js` keeps the single-project browser draft in `sessionStorage` and sends it back through `restore_state` on mount.
The scope is `{node, token}`: the node is the root's `data-node-id` (default `local`) and the token is `data-task-draft-scope` (the selected project's VCT point, e.g. `vct:///projects/foo`) else `data-task-draft-project` (the raw absolute OS path), so a path-only project is its own token.
The scope key is `'dashboard_state:' + JSON.stringify([node, token])`, and a page with no project token at all uses the bare `dashboard_state` key.
The saved object is single-project form state: `project` (the scope's project path, falling back to the root's `data-project`), `task_mode`, `node`, `task_prompt`, `task_node_path`, `task_seeds`, `task_starting_commit`, optionally `selected_model_id` (legacy) and `model_spec` (`{}` = explicit Auto), plus server-managed keys merged in and preserved (e.g. `foreign_repos`, `task_archive`).
Every write is stamped with `scope_token` (the write's scope token), so a later restore can tell a VCT-scoped draft from a legacy path-keyed one.
Adoption order on restore is the scoped key, then the path key the same project used before its VCT point was known, then the un-scoped `dashboard_state` key.
A stamp equal to the state's own `project` is a pre-point stamp — minted while the server had no point yet, e.g. the first frame before the async VCT mount load lands — so it matches by path; a stamp that differs from the project is a real point/workspace identity and must match the scope token exactly.
An unstamped legacy state matches by its `project` path, and a node mismatch never restores or persists.
There is NO client-side persistence of open project tabs, a project list, a "last opened project" or recent projects — projects are the core's VCT mounts (server-side, in the task store), ProjectsLive owns the `"vct"` PubSub subscription (`{:vct_updated, node}`) and reloads the list server-side, and no JS in this tree handles project data (the `StatePersistence` hook only round-trips the scoped draft keys).
Browser storage keys owned here: `dashboard_state` (sessionStorage), `guide_client_id` (sessionStorage), `sidebar-collapsed` (localStorage); `phx:theme` (localStorage) belongs to the inline script in `root.html.heex`, not this tree.
The `persist_model_selection` server event carries `{node, model_spec}`, where `model_spec` is a string-keyed map containing `provider_profile_id`, `model`, and optional `reasoning_effort`, or the explicit empty map `{}` for Auto.
The handler merges only `node` and `model_spec`, leaving the saved prompt and unrelated fields untouched, and accepts an event only for the root's current `data-node-id` (default `local`) and the saved state's node when storage already exists.
Node-less legacy state belongs to `local`, and a picker-only event must never relabel another node's pending saved state.
The debounced form watcher reads the latest saved object when it runs, preserving canonical selection including `{}`, and writes `selected_model_id` only when a legacy `[name="model_id"]` selector actually exists.
The full `persist_state` event replaces the saved object while taking `task_prompt` from the DOM to protect unsent typing.
Focused regressions for this hook live in `state_persistence.test.cjs` (see "JS Unit Tests" below).

## JS Unit Tests (Node's built-in test runner)

The `*.test.cjs` files (top-level for `app.js` behaviour and the imported root modules, `hooks/*.test.cjs` for the hook modules) cover the PURE decisions behind the hooks; they are NEVER part of `mix test`.
Run all asset Node tests from the repository root with `node --test apps/evo_dash/assets/js/*.test.cjs apps/evo_dash/assets/js/hooks/*.test.cjs`, or pass one file path for a focused run.
They use Node's built-in runner (`node:test` + `node:assert/strict`) and `node:vm` over source sliced out of the module under test, so no browser bundle or DOM library is loaded.
`agent_history_scroll.test.cjs` slices the block from the `// --- AgentHistoryAutoScroll: pure pinning decision` marker to the `// AgentHistoryAutoScroll hook:` marker of `hooks/agent_history_scroll.js` and asserts the 56 px inclusive pin boundary, the overscroll/rubber-band answers, unmeasurable geometry, the explicit-threshold override and the default threshold's documented 48–64 px band.
The DOM half of that hook (rAF coalescing, observers, listeners) carries no decision of its own and is deliberately not faked.
`state_persistence.test.cjs` runs the real `StatePersistence` hook object from `hooks/state_persistence.js` against `sessionStorage`/timer stubs and asserts the saved-state shape, node scoping and the `persist_model_selection` merge.
`hooks/inspector_messages.test.cjs`, `hooks/file_picker.test.cjs` and `hooks/adaptive_input.test.cjs` run the real hook objects against small DOM/timer seams, covering entry animation and its lifecycle, the manual-panel teardown contract, and the single coalesced deferred-apply frame.
`hooks/workbench_panel.test.cjs`, `hooks/list_enter.test.cjs`, `hooks/sidebar_collapse.test.cjs` and `hooks/workbench_project_preview.test.cjs` slice the pure block out of their module and pin the right-panel machine, the list insertion plan, the collapse-sync probe and the preview LRU.
`hooks/disclosure_motion.test.cjs`, `dialog_modal.test.cjs` and `browser_notifications.test.cjs` cover the shared motion foundation, the review dialog and the notification hook.

## BrowserNotifications Integration Contract

`browser_notifications.js` exports the hook registered as `BrowserNotifications` in `app.js`.
The Assistant host must wrap its in-app approval status bar, including a native `<button type="button" data-enable-notifications>` and a `[data-notification-status]` text node (preferably `role="status"`), so delegated clicks request permission directly from an explicit user gesture.
Projects may retain its existing hidden notification host with no controls or approval metadata.
The host supplies gettext-translated `data-notification-label-unsupported`, `data-notification-label-denied`, `data-notification-label-default`, `data-notification-label-granted`, `data-notification-label-requesting` and `data-notification-label-error` attributes; the hook copies the selected label via `textContent` and exposes the state in `data-notification-status` on the host.
The labels must honestly explain unsupported API/insecure context, browser-denied permission, explicit enablement needed, enabled advisory delivery, pending browser prompt and failed browser operation respectively, without implying approvals are delivered reliably.
The enable button's own text is server-rendered gettext; the hook hides it unless permission is default and requestPermission exists, and disables it while requesting.
No permission prompt runs on mount, patch or focus, permission is read live rather than cached, and focus, visibilitychange, reconnect and updates refresh the status.
The `task_notification` event accepts `{title: string, body?: string, tag?: string, request_id?: string, scope?: string}`; approval payloads require their captured opaque `scope`, titles must be nonblank, non-string bodies become empty, and callers own sensitive-content minimization.
Notifications show only with granted permission while the document is hidden OR the window is unfocused, preserving the terminal-task gate.
For approval notifications the host must render `data-approval-scope` as a nonblank opaque identity covering the viewed node/target and session, and `data-approval-request-ids` as a JSON array of nonblank string IDs scoped to that host.
Approval identity uses the scope captured in the payload, never the current host scope as a substitute, and is validated at creation and again on click against current DOM scope and pending IDs; missing/malformed metadata, missing/stale payload scope or an invalid/non-pending request_id fails closed even after same-ID reuse.
A valid approval click only focuses the window, closes the notification and pushes `review_approval_notification` with `{request_id, scope}` for server-validated in-app review; it NEVER pushes allow/deny, approval_response or execution authority.
Notifications without request_id only focus and close, even if tagged, so terminal-task producers remain compatible.
LiveView must update pending IDs on resolution and change scope when switching node/session; `updated()` closes resolved notifications and all notifications on a scope change, while click-time validation also protects the pre-update race.
Tags and request IDs deduplicate tracked notifications, native close releases records, and disconnect/destroy close all notifications; destroy removes delegated/global listeners and the LiveView event handler and makes late permission completions inert.
Constructor/prompt failures render the translated error state without throwing or logging sensitive payloads; absent/denied APIs remain fallback states and in-app pending review remains mandatory.
This is advisory document notification delivery only, with no service worker, persistent actions, background push, closed-page delivery, replay or click-to-authorize.
Focused tests run with `node --test apps/evo_dash/assets/js/browser_notifications.test.cjs`.

## DialogModal Integration Contract

`dialog_modal.js` exports the hook registered as `DialogModal` in `app.js`, attached directly to a uniquely identified `<dialog class="modal" phx-hook="DialogModal">` containing `.modal-box`.
This hook opens REVIEW UI only and never emits approval_response, allow, deny or execution events, intercepts decision controls, or interprets returnValue as a decision.
Consumers should provide `aria-labelledby="<stable-title-id>"` on the dialog and a static `<h2 id="<stable-title-id>" data-dialog-title data-dialog-initial-focus tabindex="-1" autofocus>` inside `.modal-box`, with a server-translated review title.
An optional `aria-describedby="<summary-id>"` should reference a concise translated review summary, not the entire code payload or a long warning.
Never mark Allow/Deny controls with autofocus or data-dialog-initial-focus, and do not make a decision form implicitly submit on Enter from review text.
The hook accepts only static heading/paragraph/div content without interactive descendants/ancestors as its initial target, falls back to the dialog container if no usable target exists, and preserves focus within an already open dialog across ordinary patches.
It supports the existing approval markup without LiveView changes by using `.modal-box h2`, assigning a missing title id/aria-labelledby and tabindex, and recognizing `[phx-click="dialog_closed"]` plus `.modal-backdrop button` as dismissal controls.
New markup should use a native `<button type="button" data-dialog-dismiss>` with a translated accessible Close label and no phx-click; dismissal is owned by the hook.
A `form.modal-backdrop[method="dialog"]` with a translated Close button remains supported, including engines without native dialog submission.
Provide `data-dialog-return-focus="<stable-review-button-id>"` on the dialog to return to the in-app Review trigger by ID, not a CSS selector.
Otherwise focus returns to the captured opener, or for the legacy approval-dialog to `[phx-click="open_approval_dialog"]`, skipping disconnected, disabled, hidden or inert targets and never stealing focus already moved outside.
Native showModal is guarded against duplicate opens; cancel, close, explicit Close and backdrop dismissal push exactly one dialog_closed per presentation, never deny, and updated never reopens a dismissed dialog.
The existing dialog_open server event explicitly starts a new presentation, while stale queued native close events cannot dismiss a newly reopened dialog.
When showModal is missing or throws, open plus DaisyUI modal-open keeps the review surface visible and pointer/keyboard accessible with role=dialog, aria-modal=false and data-dialog-mode=fallback, rather than leaving a closed dialog inaccessible.
The fallback is deliberately NON-modal with no invented inert state or focus trap, supports Escape while focus is inside, and retains the in-app pending review path as the authority.
Native mode sets aria-modal=true and data-dialog-mode=native and relies on the browser's modal focus containment.
Teardown removes all DOM and LiveView event handlers before closing, restores focus when appropriate and never emits a dismissal; late dialog_open callbacks are inert.
Focused tests run with `node --test apps/evo_dash/assets/js/dialog_modal.test.cjs` and cover native/fallback opening, safe focus, patch/reopen races, dismissal latching, review-only events and cleanup.
Node seams do not replace browser/WebView checks of native top-layer focus trapping, screen-reader announcements, fallback layout and real keyboard tab order.

## Known Issues
`hooks/agent_history_scroll.js` follows instantly with a 56 px inclusive threshold, disconnects observers when unpinned and cleans up frames/listeners/observers, but only its pure geometry predicate has Node coverage.
The scroller and direct children are observed, and missing ResizeObserver means patch-driven following only; frame scheduling, observer lifecycle, reconnect and keyboard/scroll races are untested.
`hooks/guide.js` and the inline `PaletteList` in `app.js` request smooth scrolling without reduced-motion checks.
The inline `FocusInput` in `app.js` focuses on mount and refocuses focus-on-update elements on every patch, so consuming pages must prevent focus theft while another control or dialog owns focus.
No Node tests here cover Guide, PaletteList or FocusInput; standalone animation/accessibility gaps and their tests are documented in `hooks/CONTEXT.md`.
