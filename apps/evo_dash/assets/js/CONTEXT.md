# Frontend JavaScript Source

## Intent

Client-side JavaScript for the EvoDash dashboard: the main entry (`app.js`, LiveSocket setup + all inline hooks), the highlight.js global-exposer (`highlight_setup.js`), and the five standalone hook modules under `./hooks/`. Bundled by esbuild via `mix assets.build`. See `../assets/CONTEXT.md` for build tooling and `./hooks/CONTEXT.md` for the hook registration table + behavior notes.

## Routing Table

- `./hooks/` → Standalone LiveView hook files (`sidebar_collapse.js`, `node_switch_fade.js`, `adaptive_input.js`, `legend_tooltip.js`, `diff_viewer.js`) + `hooks/CONTEXT.md`
- `app.js` → Main entry — LiveSocket, inline hooks (`TauriDetect`, `DesktopQuit`, `DesktopQuitConfirm`, `UpdateStatus`, `PlatformDetect`, `PathAutocomplete`, `DirectoryPicker`, `FilePicker`, `Guide`, `StatePersistence`, `BrowserNotifications`, `AutoClearFlash`, `ClipboardCopy`, `AgentHistoryAutoScroll`, `DialogModal`, `FocusInput`, `PaletteList`), topbar wiring, guide-client-id sessionStorage
- `highlight_setup.js` → Exposes the vendored highlight.js instance as `window.hljs` (module side effect — must evaluate BEFORE the cdnjs language-pack IIFE imports; load-order contract in `../assets/CONTEXT.md`)

## Constraints

- **Theme safety (GNOME/libadwaita restyle — AUDITED, holds as of the audit)**: JS in this tree must NEVER introduce color literals (hex/rgb/hsl/named), never write theme colors via `element.style.*`/`setAttribute("style", ...)`/canvas fills, and never add theme-specific Tailwind color classes from JS. Theme tokens (`--color-*`) are CSS custom properties that CANNOT be read from JS (canvas contexts excluded). All visuals must flow through CSS classes/tokens in `../css/app.css`. The ONE documented exception: the canvas-bound topbar progress colors (`app.js:1136`, `barColors: {0: "#29d"}` + `rgba(0,0,0,.3)` shadow — vendor/topbar.js paints a `<canvas>`, where color strings cannot resolve CSS vars) — carries the `// Adwaita:` comment at `app.js:1131-1135`; do not remove it, do not add siblings.
- **Theme switching is NOT JS's job**: no JS here toggles a `dark`/`light` class, reads `data-theme`, or matches `prefers-color-scheme` — the inline script in `root.html.heex` (server subtree) owns `data-theme` on `<html>` (localStorage `phx:theme`, tri-state). JS must never assume a theme or read `getComputedStyle` for colors (layout metrics like maxHeight/lineHeight are fine — `adaptive_input.js:220`).
- **Body-appended elements** (e.g. LegendTooltip's fixed tip): theme tokens still resolve (inherited from `:root` via `html[data-theme]`), but they sit OUTSIDE `#app-layout`'s `data-accent-color` scope — keep base blue/neutral; use `--color-neutral*` (as `.agents-legend-tip` does) or explicit tokens, never accent-dependent assumptions.
- **JS-added classes are structural or token-based only**: verified examples — SidebarCollapse width/translate/opacity layout classes, NodeSwitchFade `.node-switch-fade` (CSS opacity keyframes), Guide `.guide-highlight` (CSS `var(--color-primary)` outline), ClipboardCopy's 2s `text-success` icon tint (`app.js:539`; `--color-success` defined per theme in `css/app.css`, dark L46 / light L94; class round-tripped from `origClass`), AdaptiveInput `--app-vh` var sync on `documentElement` (`adaptive_input.js:87`).
- DiffViewer injects ONLY highlight.js `<span class="hljs-*">` token markup (`diff_viewer.js:83`) — `.hljs-*` colors live in CSS for both themes; never add inline colors to the hook.

## Known Issues

- `js/CONTEXT.md` routing note: the parent `assets/CONTEXT.md` routes `./js/` → `js/hooks/CONTEXT.md` for behavior detail; this file exists only since the theme audit — keep it lean (per-file detail belongs in code comments / hooks/CONTEXT.md).
