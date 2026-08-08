# Frontend Assets

## Intent

This directory holds all frontend source assets (JavaScript, CSS, vendor libraries, and editor config) for the EvoDash Phoenix web application. It is the single source of truth for client-side code, compiled by **esbuild** (JS) and **Tailwind CSS 4** (styles) via Mix aliases (`assets.build`, `assets.deploy`).

## Routing Table

- `./js/` → JavaScript source (LiveSocket setup, hooks, topbar)
- `./css/` → Stylesheets (Tailwind CSS 4 configuration, DaisyUI themes)
- `./vendor/` → Third-party JS libraries (DaisyUI, Heroicons, Topbar)

## API Surface

### Directories & Files

| Path | Role |
|---|---|
| `js/app.js` | Main JS entry point. Imports `phoenix_html`, establishes a `LiveSocket` with colocated hooks from `phoenix-colocated/evo_dash`, wires the topbar progress indicator on LiveView navigation, and enables live-reload dev features (server log streaming, click-to-editor). |
| `css/app.css` | Main CSS entry point. Configures Tailwind CSS 4 with source scanning across `css/`, `js/`, and `lib/evo_dash_web/`. Loads Heroicons, DaisyUI (themes disabled), and two custom DaisyUI themes ("dark" with purple tones, "light" default with warm orange primary). Defines LiveView-specific custom variants (`phx-click-loading`, `phx-submit-loading`, `phx-change-loading`) and a `dark` variant based on `data-theme` attribute. |
| `css/launchpad.css` | Launchpad variants (Flow/Console/Workspaces) — only what Tailwind utilities cannot express: `.lp-path-ellipsis` (full-path START-ellipsis truncation — `direction: rtl` + `unicode-bidi: embed`; `plaintext` would re-derive direction from the first strong char and degrade to an end-ellipsis for Latin-leading paths), the 200ms `.lp-task-card` enter animation, and the `prefers-reduced-motion` guard (kills card enter + status-dot pulse). Imported once from `app.css`. |
| `css/console.css` | Launchpad Variant B (`/console`) — `.lp-console-grid` responsive task grid (`auto-fill, minmax(min(100%, 20rem), 1fr)`), uniform card heights with the action row pinned to the card bottom, the grid-spanning empty state, and the quiet `.lp-console-hint` keyboard-hint chips (`<kbd>` chrome on hairline borders). No additional motion (reduced-motion handled by `launchpad.css`). |
| `css/workspaces.css` | Launchpad Variant C (`/workspaces`) — the `.ws-panel` / `.ws-add-panel` 200ms enter animation (panels keep DOM ids so stream reloads never restart it) + its `prefers-reduced-motion` guard. Everything else is Tailwind utilities in `workspaces_live.ex`. |
| `vendor/` | Third-party libraries loaded as esbuild/Tailwind plugin dependencies. |
| `vendor/daisyui.js` | DaisyUI Tailwind plugin (core). |
| `vendor/daisyui-theme.js` | DaisyUI theme plugin (used twice in `app.css` for dark & light themes). |
| `vendor/heroicons.js` | Heroicons icon set exposed as Tailwind plugin (`hero-*` classes). |
| `vendor/topbar.js` | Topbar progress bar library for navigation feedback. |
| `tsconfig.json` | TypeScript configuration for editor autocompletion of Phoenix/LiveView JS APIs. Maps `*` to `../deps/*` to resolve Phoenix packages. |

### How to use

- **Add a new JS module**: place it under `js/` and import from `app.js` (or import directly in a colocated hook).
- **Add custom CSS**: extend `css/app.css` or create additional files under `css/` (they are auto-scanned by Tailwind).
- **Add a vendor library**: drop a `.js` file in `vendor/` and import via relative path (e.g., `import "../vendor/my-lib"`).
- **Update DaisyUI/Heroicons**: replace the corresponding `.js` file in `vendor/` with the latest release.

## Constraints

- **Build tooling**: JS is bundled by esbuild; CSS is processed by Tailwind CSS 4. No Node.js toolchain is required — vendor libs are committed directly.
- **Tailwind source scanning** is explicitly configured via `@source` directives in `app.css` covering `css/`, `js/`, and `lib/evo_dash_web/`. Any new directories with Tailwind classes must be added as `@source` entries.
- **Theme system**: DaisyUI's built-in themes are disabled (`themes: false`). Only the two custom themes ("dark" and "light") are available. Dark mode is driven by the `data-theme="dark"` attribute, not `prefers-color-scheme` alone.
- **Phoenix LiveView hooks** are sourced from `phoenix-colocated/evo_dash` (generated hooks from colocated `.exh` hook files in the LiveView templates). Do not register hooks manually in `app.js` for hooks that are already colocated.
- **Live reload features** (server logs, click-to-editor) are gated behind `process.env.NODE_ENV === "development"` and must not be relied upon in production.
- **No `node_modules/`**: Dependencies are either in `vendor/` or resolved via esbuild's path aliasing to `../deps/`. Do not run `npm install` unless a `package.json` is introduced.

## Notes for Agents

- **DirectoryPicker auto-confirm (project picker)**: Tauri native picks (via `window.__TAURI__.core.invoke('plugin:dialog|open')`) return a full absolute path, so after filling the input the `data-picker-id="project"` browse button submits the enclosing `open_project` form directly via `form.requestSubmit()` — the project opens immediately with no extra "Open" click. Browser File System Access API picks (`showDirectoryPicker`) deliberately do NOT auto-open because they yield only the folder *name* (`handle.name`), not a full path — they just fill the input. The other two pickers (`data-picker-id="new-project"` and `"foreign-repo"`) also only fill their input: new-project still needs a name and foreign-repo is a settings form field. The server-side `open_project` handler (`ProjectFlow.open_project/2`) validates the path (`Path.expand` + `File.dir?`), so auto-submitting is safe even for a stale/bad selection.
- **DirectoryPicker macOS gotcha (hardenings in `js/app.js` + hint CSS in `css/app.css`)**: On macOS the Tauri dialog plugin (pinned `tauri-plugin-dialog` 2.7.1 → `rfd` 0.16.0 in `desktop/src-tauri/Cargo.lock`) presents NSOpenPanel as a *sheet* attached to the parent window (`beginSheetModalForWindow:completionHandler:`), which can silently fail to appear (window hidden / app not active — e.g. after the desktop shell's close-to-tray re-show) or panic inside rfd while resolving the parent window handle. The old `catch (_err) {}` blocks swallowed both the rejection and the never-settling invoke, and WKWebView has no `showDirectoryPicker`, so the Browse button was a silent dead click on macOS (Linux WebKitGTK worked). The hook now: (1) logs genuine errors with `console.error("[DirectoryPicker]", err)` while keeping user-cancel quiet (Tauri cancel returns null/empty, not an exception; FSA cancel throws `AbortError`), (2) races the Tauri invoke against a **15s timeout** (`DIRECTORY_PICK_TIMEOUT_MS` + `DIRECTORY_PICK_TIMEOUT` Symbol) so a hung sheet falls through to the File System Access API and then to manual entry — a very-late panel resolution still fills the input if the user hasn't typed anything (`onlyIfEmpty`), but never auto-submits, (3) on total failure marks the picker row with `data-picker-error="manual"`, focuses the path input, and warns — the attribute is styled in `css/app.css` (`[data-picker-error="manual"] .picker-container::after` hint text + warning-tinted input border, using `color-mix` + `--color-warning`/`--color-base-100` per Known Issue (i)) and is cleared by `fillInput/0` on success. There is also a re-entrancy guard (`this._picking`) so repeated clicks can't stack invokes. Tauri detection in the hook (`tauriInvokeAvailable()`) is consistent with the `TauriDetect` hook (`window.__TAURI__ || window.__TAURI_OS_INTERNALS__`) but additionally requires `window.__TAURI__.core.invoke` and warns when only the internals marker is present (withGlobalTauri injection race). Note the true fix for the macOS panel requires a Rust-side change in `desktop/src-tauri/` (custom `pick_directory` command — see the report that introduced these hardenings).

## Known Issues — Custom CSS Variables (`css/app.css`)

- **(i) No old DaisyUI `--b1/--b2/--b3/--bc/--p` namespace.** Because DaisyUI is loaded with `themes: false`, only the new `--color-base-100/-200/-300`, `--color-base-content`, `--color-primary` (etc.) variables exist — they are defined by the two `@plugin "../vendor/daisyui-theme"` blocks at the top of `app.css`. Custom rules MUST use the `--color-base-*` namespace. For alpha, use `color-mix(in oklab, var(--color-base-100) 98%, transparent)` (or `in oklch` for accent colors) — never `oklch(var(--x) / a)` nesting: `oklch()` cannot take a variable that is already an `oklch()` color, so the declaration is silently dropped. Grep `--b1|--b2|--b3|--bc|var(--p)` after any CSS work to confirm no regressions.
- **(ii) `.dashboard-topbar` must NOT have `backdrop-filter`.** `backdrop-filter` creates a containing block, which traps the fixed-position command-palette backdrop/overlay (`.project-palette-backdrop`, `.project-palette-overlay` — both descendants of the topbar) so they only cover the ~50px topbar strip instead of the viewport. The topbar's translucency comes from `background: color-mix(in oklab, var(--color-base-100) 80%, transparent)` alone. Other elements keep their `backdrop-filter` (`.glass-card`, `.input-card`, the palette backdrop/overlay themselves).
- **(iii) Compact input ring + layered glow lives in `.input-layout[data-layout="compact"] .input-card`** (`app.css`, Adaptive Input Layout section): it REPEATS the base card `box-shadow` (so compact keeps the card's normal elevation), then adds a FAINT 2px accent ring at low alpha (`0 0 0 2px color-mix(in oklch, var(--project-accent) 15%, transparent)` — a subtle hint, not a prominent ring) plus a two-layer background glow: a mid glow with negative spread (`0 0 90px -18px color-mix(in oklch, var(--project-accent) 25%, transparent)`) and a wide, very-low-alpha bloom with positive spread (`0 0 160px 20px color-mix(in oklch, var(--project-accent) 12%, transparent)`) so the accent reads as depth BEHIND the card rather than a ring hugging it. The expanded layout intentionally has NO ring/glow — do not add shadows to the `.input-card` base rule.
