# JS Hooks

## Intent

Phoenix LiveView JavaScript hooks for the EvoDash dashboard. A LiveView JS hook is a plain
JS object with lifecycle callbacks (`mounted`, `updated`, `destroyed`) registered with the
`LiveSocket` and attached to a DOM element via the `phx-hook="<Name>"` attribute.

## API Surface

### Hook Registration

All hooks are registered in `../app.js` in the `LiveSocket` constructor's `hooks:` map
(lines 987-991 — `liveSocket` constructed at 987, `hooks:` map at 990):

```js
import {hooks as colocatedHooks} from "phoenix-colocated/evo_dash"
import SidebarCollapse from "./hooks/sidebar_collapse.js"
import NodeSwitchFade from "./hooks/node_switch_fade.js"
import AdaptiveInput from "./hooks/adaptive_input.js"
import LegendTooltip from "./hooks/legend_tooltip.js"
import DiffViewer from "./hooks/diff_viewer.js"
// ...
hooks: {...colocatedHooks, TauriDetect, DesktopQuit, DesktopQuitConfirm, UpdateStatus,
        PlatformDetect, PathAutocomplete, DirectoryPicker, FilePicker, StatePersistence,
        BrowserNotifications, AutoClearFlash, ClipboardCopy, AgentHistoryAutoScroll,
        DialogModal, SidebarCollapse, NodeSwitchFade, AdaptiveInput, LegendTooltip,
        FocusInput, PaletteList, DiffViewer}
```

### Where each hook is defined

| Hook | Defined in | Attached to (HEEx) |
|------|-----------|--------------------|
| `SidebarCollapse` | `./sidebar_collapse.js` (own file, ES module default export) | `layouts.ex` `<aside id="sidebar" phx-hook="SidebarCollapse">` |
| `AdaptiveInput` | `./adaptive_input.js` (own file, ES module default export) | `task_form_components.ex` prompt `<textarea phx-hook="AdaptiveInput">` (class `.input-prompt`) — does **BOTH autogrow AND the client-side layout switch**: (1) **autogrow** — measures `scrollHeight` and sets the textarea's `height` so it grows smoothly with its content; in compact mode the hook flips the layout to expanded the INSTANT the natural content height would exceed the compact max-height cap, so the compact box NEVER shows an internal scrollbar while growing (`overflow-y: auto` is a safety net only — the box flips to expanded at the 8-line cap instead). In expanded mode the card is naturally constrained to its flex-allocated height by CSS overflow containment (`overflow: hidden` on `.input-card`); the textarea fills the remaining card space (`flex: 1`) with NO max-height cap and scrolls INTERNALLY, so the in-flow `.input-controls` launch panel always stays pinned at the bottom of the card regardless of prompt length or viewport height: the hook writes the full natural content height inline and the rendered layout overrides it at render time — compact mode's CSS max-height wins over the inline height, while expanded mode's flex layout (flex-basis 0% + grow) fills the card with no cap (the measurement itself is never capped — `measureAndApply` neutralizes `max-height: "none"` while measuring; the compact-cap cache is layout-gated — cached only while `data-layout="compact"` — and in expanded mode max-height computes to `"none"` → NaN, which the hook skips, so nothing from expanded mode can leak into `applyLayout`'s flip decisions); (2) **layout** — computes `data-layout` on the closest `.input-layout` ancestor from the textarea value AND its measured natural content height: the value thresholds mirror `EvoDashWeb.TaskFormComponents.layout_for/1` (>600 code points or >16 lines → `"expanded"`) for SSR-seed convergence; the height threshold is client-only (natural height exceeds the compact 8-line cap → `"expanded"` — the server has no knowledge of rendered text metrics). The flip back to compact uses ~1 line-height of **hysteresis**: the height must drop below the cap by a full line AND the char/line thresholds must be under before leaving `"expanded"`, so the layout does not flicker at the boundary while deleting (`"compact"` = Layout A unified objective box with the controls row as the card's last line, `"expanded"` = Layout B with a large objective area and an in-flow launch panel below the textarea). The server only **SEEDS** the initial `data-layout` at render (SSR first paint + after restore/submit); from then on the client is authoritative — no per-keystroke server event. A **MutationObserver on `.input-layout`** (`attributeFilter: ['data-layout']`) re-asserts the client-computed layout whenever the server re-seeds the attribute from its (possibly stale) `@task_prompt` — e.g. toggling the mode/model `<select>` triggers a server re-render that would otherwise snap the layout back to compact while a long prompt remains in the box (the textarea is inside `phx-update="ignore"`, so `updated()` never fires on those re-renders). `applyLayout` only writes the attribute when the computed value differs, so the observer converges immediately with no loop and NO network events. Also handles the server's `"clear_prompt"` push event (sent after a successful `task_submit`): empties the textarea value, re-runs `_apply()` (autogrow + layout re-assertion, converging in one step), and clears the `task_prompt` field in the `dashboard_state` sessionStorage blob so the submitted draft can't be restored on reload. The controls row `.input-controls` is the last in-flow element of `.input-card` — no `position: fixed`, no `--input-layout-center` |
| `NodeSwitchFade` | `./node_switch_fade.js` (own file, ES module default export) | `layouts.ex` `<main id="main-content" phx-hook="NodeSwitchFade" data-node-id=...>` — plays a 0.25s opacity fade when `data-node-id` changes |
| `LegendTooltip` | `./legend_tooltip.js` (own file, ES module default export) | `agents_live.html.heex` legend chips (`phx-hook="LegendTooltip"` + `data-tip` + unique id) — renders the tip as a `position: fixed` element appended to `document.body` (DaisyUI `.tooltip` is clipped; see `live/CONTEXT.md`) |
| `DiffViewer` | `./diff_viewer.js` (own file, ES module default export) | `review_components/diff_viewer.ex` `#diff-viewer` (`phx-hook="DiffViewer"`) — TWO merged responsibilities (LiveView 1.2 `phx-hook` accepts exactly ONE hook name; see Known Issues): (a) **client-side syntax highlighting** of diff cells with vendored highlight.js (see `../assets/CONTEXT.md` "Client-side syntax highlighting") — runs its pass in `mounted()` AND `updated()` (morphdom in-place patches don't re-init hooks, so `updated()` re-highlights new/changed rows). Per `.diff-file-section` reads `data-language` (lumis→hljs map: `c_sharp`→`csharp`, `text`→`plaintext`, else passthrough) and skips sections with unknown languages (`hljs.getLanguage` undefined); per `.diff-split-cell` skips `dataset.hl === "1"`-marked and empty/whitespace-only cells, runs `hljs.highlight(code, {language})` in try/catch (a throw leaves the cell as plain text — never breaks the page), assigns `innerHTML`, and marks `dataset.hl = "1"`. No-ops gracefully if hljs failed to load. (b) **scroll-to-file** — the `scroll_to_file` event handler registered in `mounted()` scrolls the `#main-scroll` container to the selected file section (50ms `setTimeout` to wait for the DOM patch; `scrollIntoView` fallback when the container is absent) |
| `UpdateStatus` | `../app.js` (inline, line 826) | `layouts.ex` `<div id="update-status-hook" phx-hook="UpdateStatus" />` (line 242) — Tauri-updater bridge: module-level once-bound window listeners + once-started timers (see section below); no-op outside the Tauri shell |
| `PathAutocomplete` | `../app.js` (inline, line 56) | `project_components.ex` path inputs (`phx-hook="PathAutocomplete"`) — Tab-completion to longest common prefix + real-time single-match autofill from datalist |
| `DirectoryPicker` | `../app.js` (inline, line 150) | `project_components.ex` browse buttons (`phx-hook="DirectoryPicker"`) — click pushes `directory_pick` to the server; listens for `picker_result:<id>` (protocol in `../assets/CONTEXT.md` Notes for Agents) |
| `FilePicker` | `../app.js` (inline, line 277) | objective editor "+" attach-file button (`phx-hook="FilePicker"`, `data-picker-id="objective_file"`) — pushes `file_pick`/`file_pick_manual`, listens for `picker_result:<id>`; append-not-clobber textarea write (protocol in `../assets/CONTEXT.md` Notes for Agents) |
| `StatePersistence` | `../app.js` (inline, line 432) | `projects_live.ex` dashboard root (`phx-hook="StatePersistence"`) — sessionStorage save/restore of dashboard state + client-side debounced form watching |
| `BrowserNotifications` | `../app.js` (inline, line 505) | `projects_live.ex` (`phx-hook="BrowserNotifications"`) — HTML5 notifications on `task_notification` events |
| `ClipboardCopy` | `../app.js` (inline, line 520) | `settings_live.ex`, `welcome_complete_live.ex`, `projects_live.ex`, `review_components/header.ex` — copies `data-content` to clipboard on click (`navigator.clipboard` with hidden-textarea `execCommand` fallback; pushes `"copied"` on success — see the "ClipboardCopy hook — copy strategy & fallback" section below) |
| `AutoClearFlash` | `../app.js` (inline, line 546) | `core_components.ex` flash component — auto-dismisses flash messages after 4s (except `client-error`/`server-error`) |
| `AgentHistoryAutoScroll` | `../app.js` (inline, line 575) | `agents_live.html.heex` (`phx-hook="AgentHistoryAutoScroll"`) — rAF-based ease-out auto-scroll when at the bottom |
| `TauriDetect` | `../app.js` (inline, line 662) | `projects_live.ex` `#tauri-detect` (`phx-hook="TauriDetect"`, line 102) — pushes `tauri_detected` |
| `DesktopQuit` | `../app.js` (inline, line 689) | `layouts.ex` wrapper around `<main id="main-content">` (`#desktop-quit-hook`, line 231) — listens for Tauri `quit-requested`, pushes `desktop_quit_requested` |
| `DesktopQuitConfirm` | `../app.js` (inline, line 791) | desktop quit dialog's red Quit button — invokes Tauri `begin_quit` then pushes `desktop_quit_confirmed` |
| `PlatformDetect` | `../app.js` (inline, line 914) | `projects_live.ex` `#platform-detect` (`phx-hook="PlatformDetect"`, line 103) — pushes `platform_info` |
| `DialogModal` | `../app.js` (inline, line 935) | (native `<dialog class="modal">` elements) — shows the dialog in the top layer, pushes `dialog_closed` on ESC/backdrop close |
| `FocusInput` | `../app.js` (inline, line 957) | `project_components.ex` command palette search input — focus on mount + re-focus on update |
| `PaletteList` | `../app.js` (inline, line 971) | `project_components.ex` command palette list — scrolls `[data-selected="true"]` into view on re-render |

### ClipboardCopy hook — copy strategy & fallback

`ClipboardCopy` (`app.js:519`) is the SINGLE copy mechanism for ALL copy buttons
(Tasks page, Code Review page, Projects, Settings, Welcome). Reads `data-content`
from the element (`phx-hook="ClipboardCopy"` + `data-content`); a falsy/empty
`data-content` is a no-op. Copy strategy, in order:

1. **`navigator.clipboard.writeText(content)`** — used when available (secure
   contexts only: https, `localhost`/`127.0.0.1`, `file:`). On REJECTION the error
   is `console.warn`ed and execution falls through to the execCommand fallback
   (the rejection is never swallowed silently).
2. **Legacy fallback — hidden textarea + `document.execCommand("copy")`** — used
   when `navigator.clipboard` is unavailable (plain HTTP served at a LAN IP /
   non-localhost hostname — the documented prod and `PHX_IP` remote-access
   configurations) or after a `writeText` rejection. Creates a temporary
   `<textarea>` (`position: absolute; left: -9999px; readonly`), sets its value,
   `select()`s it + `setSelectionRange(0, value.length)`, calls
   `document.execCommand("copy")`, removes the textarea, and restores the user's
   prior selection/range (`getSelection()` saved before, `removeAllRanges()` +
   `addRange()` after). Works in non-secure contexts and most webviews because it
   runs inside the user-gesture click handler.

On ANY successful copy the hook pushes `"copied"` (the server flashes
`gettext("Copied to clipboard")` — handlers exist in `tasks_live.ex:739`,
`review_live.ex:338`, `projects_live.ex:1037`, `welcome_complete_live.ex:88`;
SettingsLive has no handler, so its copy works but shows no flash) and briefly
tints the button's first `<svg>` with a 2s `text-success` class. Success handling
is shared via the hook's `markCopied()` method — every success path (writeText
resolve, execCommand true) goes through it. If BOTH paths fail (execCommand
returns false or throws), NO fake `"copied"` event is pushed; a clear
`console.warn` surfaces the failure so it is never invisible.

### UpdateStatus hook — module-level once-bound listener/timer pattern

`UpdateStatus` (`app.js:822-911`) is the **reference pattern for a global push-based
hook**: module-level `let updateListenersBound = false; let updateTimersStarted = false;
let updateCurrentHook = null;` (app.js:822-824). `mounted()` (app.js:827-850) guards on
the Tauri detection `const isTauri = !!(window.__TAURI__ || window.__TAURI_OS_INTERNALS__)`
(app.js:829) and returns early outside the shell; sets `updateCurrentHook = this`; binds
the three window listeners ONCE (app.js:835-840):

```js
if (!updateListenersBound) {
  updateListenersBound = true;
  window.addEventListener("phx:update_check_requested", () => invokeUpdateCheck());
  window.addEventListener("phx:update_download_requested", () => invokeUpdateDownload());
  window.addEventListener("phx:update_apply_requested", () => invokeUpdateApply());
}
```

and starts the timers once (app.js:842-849): `setTimeout(() => invokeUpdateCheck(), 30000)`
+ `setInterval(() => invokeUpdateCheck(), 6 * 60 * 60 * 1000)`. `destroyed()` (app.js:851-858)
only clears `updateCurrentHook` if it still points at this instance (another mount may have
taken over). The `invoke*` functions (app.js:877-911) `window.__TAURI__.core.invoke(...)`
the Rust commands and push results back via `pushUpdateEvent` (app.js:864-874 — guards the
ref and try/catches `hook.pushEvent`). Server side: `EvoDashWeb.LiveHooks.UpdateStatus`
(`lib/evo_dash_web/live_hooks/update_status.ex`) attaches `handle_info`+`handle_event`
interceptors on EVERY page and is the reference pattern for a **server-side global push
hook** (`live_hooks/CONTEXT.md:68-91`). This whole module is the model for any one-time
global listener hook (e.g. a future `Guide` hook listening for `phx:guide_*` events).

### Server→client push_event patterns

Server `push_event(socket, "name", payload)` reaches the client two ways:

1. **`this.handleEvent("name", cb)`** inside a hook (hook-level; listener lives until the
   hook is destroyed, survives reconnects): `scroll_to_file` (diff_viewer.js:27-47),
   `picker_result:<id>` (app.js:164, 319), `persist_state` (app.js:450),
   `task_notification` (app.js:511), `desktop_quit_closed` (app.js:738). Callback receives
   the payload as its argument (LiveSocket destructures the CustomEvent detail).
2. **`window.addEventListener("phx:name", ...)`** — LiveSocket dispatches every server
   push as a `CustomEvent("phx:" + event, {detail: payload})` on `window`
   (`deps/phoenix_live_view/priv/static/phoenix_live_view.js:7645-7647` `dispatchEvent`),
   so `e.detail` is the payload map. Examples: `phx:update_check_requested` (app.js:837),
   `phx:page-loading-start/stop` (app.js:995-996, detail ignored), `phx:live_reload:attached`
   (app.js:1014 — `({detail: reloader})` destructures the detail).

## Constraints

- **NOT colocated**: there are **zero `.exh` files** in the project, so the `colocatedHooks`
  import from `phoenix-colocated/evo_dash` (see `../app.js`) resolves to an empty object; ALL
  hooks are hand-written (five in this directory — `sidebar_collapse.js`,
  `node_switch_fade.js`, `adaptive_input.js`, `legend_tooltip.js`, `diff_viewer.js` — the rest inline in
  `app.js`). Do not rely on `.exh` colocated hook generation.
- The five file-based hooks are exported as proper ES modules (`export default`); the
  inline hooks are `const` objects declared in `app.js`.
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

## Known Issues

- **LiveView 1.2 `phx-hook` accepts exactly ONE hook name per element.** The ENTIRE attribute value is looked up as a single hook name (no whitespace splitting) — space-separated multi-hook lists were pre-1.2 behavior and now silently attach NOTHING, logging `unknown hook found for "..."` in the browser console. Never use space-separated hook lists on an element; merge the behaviors into a single hook instead (which is why the diff-viewer hook combines syntax highlighting AND scroll-to-file in one `DiffViewer` hook).
- **`AdaptiveInput.measureAndApply` height write must be UNCONDITIONAL — never "skip when unchanged".** The data-layout equality guard in `applyLayout` is load-bearing (it terminates the observer cycle), but the height write in `measureAndApply` is NOT observed by any observer, so it must always write `ta.style.height = scrollHeight + "px"`. A `prevHeight` skip-guard is a regression: whenever the measured `scrollHeight` equals the previous inline height (e.g. typing on the same line), the write is skipped and the inline style stays at `"auto"` (the value set for measurement) — the CSS `min-height: 120px` then collapses the box, content overflows (scrollbar), and the next keystroke measures from the collapsed state and restores the taller height. The box oscillates between the two heights on every keystroke in compact layout. An unconditional write cannot loop (only `data-layout` is observed) and writing a value identical to the current inline value is a rendering no-op. Do NOT reintroduce a guard on the height write.
- **MutationObserver fires on same-value attribute sets — the `AdaptiveInput` equality guard is MANDATORY.** Chrome fires `MutationObserver` callbacks even when an attribute is set to the value it already holds (e.g. `el.dataset.layout = 'compact'` when it is already `'compact'`). `AdaptiveInput` has a MutationObserver on `.input-layout` (`attributeFilter: ['data-layout']`) whose callback runs `_apply()`. If `applyLayout()` writes `data-layout` unconditionally, every write re-triggers the observer → `observer → write → observer` **infinite synchronous microtask loop** that pegs the CPU and blocks the page. The equality guard (`if (layoutEl.dataset.layout !== layout) layoutEl.dataset.layout = layout;`) is what makes the observer→write cycle terminate in ≤2 firings. NEVER "simplify" it away; it is load-bearing. Same rule applies to any future observer+write pattern: never mutate an observed property inside its own observer without an equality guard.

