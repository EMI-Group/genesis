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
| `js/app.js` | Main JS entry point. Imports `phoenix_html`, establishes a `LiveSocket` with a hand-written `hooks:` map (see `js/hooks/CONTEXT.md`), wires the topbar progress indicator on LiveView navigation, and enables live-reload dev features (server log streaming, click-to-editor). |
| `css/app.css` | Main CSS entry point. Configures Tailwind CSS 4 with source scanning across `css/`, `js/`, and `lib/evo_dash_web/`. Loads Heroicons, DaisyUI (themes disabled), and two custom DaisyUI themes ("dark" with purple tones, "light" default with warm orange primary). Defines LiveView-specific custom variants (`phx-click-loading`, `phx-submit-loading`, `phx-change-loading`) and a `dark` variant based on `data-theme` attribute. |
| `vendor/` | Third-party libraries loaded as esbuild/Tailwind plugin dependencies. |
| `vendor/daisyui.js` | DaisyUI Tailwind plugin (core). |
| `vendor/daisyui-theme.js` | DaisyUI theme plugin (used twice in `app.css` for dark & light themes). |
| `vendor/heroicons.js` | Heroicons icon set exposed as Tailwind plugin (`hero-*` classes). |
| `vendor/topbar.js` | Topbar progress bar library for navigation feedback. |
| `tsconfig.json` | TypeScript configuration for editor autocompletion of Phoenix/LiveView JS APIs. Maps `*` to `../deps/*` to resolve Phoenix packages. |

### How to use

- **Add a new JS module**: place it under `js/` and import from `app.js` (or add a new hook module under `js/hooks/` and register it in the `LiveSocket` `hooks:` map in `app.js`).
- **Add custom CSS**: extend `css/app.css` or create additional files under `css/` (they are auto-scanned by Tailwind).
- **Add a vendor library**: drop a `.js` file in `vendor/` and import via relative path (e.g., `import "../vendor/my-lib"`).
- **Update DaisyUI/Heroicons**: replace the corresponding `.js` file in `vendor/` with the latest release.

## Constraints

- **Build tooling**: JS is bundled by esbuild; CSS is processed by Tailwind CSS 4. No Node.js toolchain is required — vendor libs are committed directly.
- **Tailwind source scanning** is explicitly configured via `@source` directives in `app.css` covering `css/`, `js/`, and `lib/evo_dash_web/`. Any new directories with Tailwind classes must be added as `@source` entries.
- **Theme system**: DaisyUI's built-in themes are disabled (`themes: false`). Only the two custom themes ("dark" and "light") are available. Dark mode is driven by the `data-theme="dark"` attribute, not `prefers-color-scheme` alone.
- **Phoenix LiveView hooks** are hand-written — there are zero colocated `.exh` hook files in the project, so the `phoenix-colocated/evo_dash` import in `app.js` resolves to an empty object. All hooks live in `js/hooks/` (own files) or inline in `app.js`; see `js/hooks/CONTEXT.md` for the full registration table.
- **Live reload features** (server logs, click-to-editor) are gated behind `process.env.NODE_ENV === "development"` and must not be relied upon in production.
- **No `node_modules/`**: Dependencies are either in `vendor/` or resolved via esbuild's path aliasing to `../deps/`. Do not run `npm install` unless a `package.json` is introduced.

## Notes for Agents

- **DirectoryPicker auto-confirm (project picker)**: server-side wx picks (via `EvoDash.DirectoryPicker` → `wxDirDialog`) return a full absolute path, so after filling the input the `data-picker-id="project"` browse button submits the enclosing `open_project` form directly via `form.requestSubmit()` — the project opens immediately with no extra "Open" click. (See the "DirectoryPicker — server-side wx protocol" bullet below.) The other two pickers (`data-picker-id="new-project"` and `"foreign-repo"`) also only fill their input: new-project still needs a name and foreign-repo is a settings form field. The server-side `open_project` handler (`ProjectFlow.open_project/2`) validates the path (`Path.expand` + `File.dir?`), so auto-submitting is safe even for a stale/bad selection.
- **Brand icon sizing (`.brand-icon svg`)**: `brand-*` icons (`EvoDashWeb.CoreComponents.icon/1` — `git.svg`, `nix.svg` under `vendor/brand/`) are raw inline SVGs with NO `width`/`height` attributes, rendered inside a `size-*` wrapper span. Without explicit sizing the SVG's rendered size is browser-dependent and does NOT match the hero mask icons (which are exactly sized by the `size-*` utility via `vendor/heroicons.js`). The rule `.brand-icon svg { display: block; width: 100%; height: 100%; }` in `css/app.css` makes the SVG fill its wrapper span, so the span's `size-*` class (e.g. `size-4` = 16px) controls the rendered size. The `brand-icon` class is added in `core_components.ex`. Any NEW brand SVG added to `brand_svg_content/1` gets correct sizing automatically (keep the SVG square — `viewBox` must match the `width/height` ratio to avoid distortion). Regression symptom if removed: System page self-check git logo renders larger than the ripgrep badge check-circle.
- **DirectoryPicker — server-side wx protocol**: The hook (in `js/app.js`, ~line 113) is a thin LiveView client — no Tauri, no File System Access API. Click → `this.pushEvent("directory_pick", {picker_id})` → `ProjectsLive` (local node only) → `EvoDash.DirectoryPicker` GenServer runs the native `wxDirDialog` in a Task → the server pushes `picker_result:<picker_id>` with `{path, cancelled, unavailable}`. The hook handles: `path` → absolute-path regex guard → `fillInput` → auto-submit for `project`/`new-project` (`form.requestSubmit()`; server validates via `Path.expand` + `File.dir?`) / fill-only for `foreign-repo`; `cancelled` → no-op; `unavailable` → `markManualFallback` (`data-picker-error="manual"`, styled in `css/app.css` — `[data-picker-error="manual"] .picker-container::after` hint text + warning-tinted input border via `color-mix` + `--color-warning`/`--color-base-100` per Known Issue (i); cleared by `fillInput` on success). `handleEvent` is registered in `mounted()` (survives reconnects); NO JS-side timeout — the native dialog may legitimately stay open minutes. wx degrades to `unavailable` when: remote/headless node, picker disabled (`config :evo_dash, :directory_picker, enabled: false`), wx not compiled (`:code.which(:wx) == :non_existing` — dev/test `mix` runs prune wx from the code path since it is NOT an umbrella app dep; only the `genesis`/`genesis_desktop` releases load it via `wx: :load` in the root `mix.exs`), picker busy, or GenServer not running. Re-entrancy guard `this._picking` prevents stacked dialogs (re-armed by `picker_result` and `reconnected()`). **Remote nodes additionally hide the Browse buttons entirely** (component gating `@tauri_detected and !@remote` in `project_components.ex` — the wx dialog is local-machine-only, so a remote pick would be meaningless): the manual path inputs remain the fallback, and the hook's `unavailable` path only triggers for local-but-unavailable cases (picker disabled / wx missing / busy).

## Known Issues — Custom CSS Variables (`css/app.css`)

- **(i) No old DaisyUI `--b1/--b2/--b3/--bc/--p` namespace.** Because DaisyUI is loaded with `themes: false`, only the new `--color-base-100/-200/-300`, `--color-base-content`, `--color-primary` (etc.) variables exist — they are defined by the two `@plugin "../vendor/daisyui-theme"` blocks at the top of `app.css`. Custom rules MUST use the `--color-base-*` namespace. For alpha, use `color-mix(in oklab, var(--color-base-100) 98%, transparent)` (or `in oklch` for accent colors) — never `oklch(var(--x) / a)` nesting: `oklch()` cannot take a variable that is already an `oklch()` color, so the declaration is silently dropped. Grep `--b1|--b2|--b3|--bc|var(--p)` after any CSS work to confirm no regressions.
- **(ii) `.dashboard-topbar` must NOT have `backdrop-filter`.** `backdrop-filter` creates a containing block, which traps the fixed-position command-palette backdrop/overlay (`.project-palette-backdrop`, `.project-palette-overlay` — both descendants of the topbar) so they only cover the ~50px topbar strip instead of the viewport. The topbar's translucency comes from `background: color-mix(in oklab, var(--color-base-100) 80%, transparent)` alone. Other elements keep their `backdrop-filter` (`.glass-card`, `.input-card`, the palette backdrop/overlay themselves).
- **(iii) Input ring + layered glow are UNIFIED on the base `.input-card` rule** (`app.css`, Adaptive Input Layout section): the accent-tinted border, the layered glow `box-shadow` (the base card elevation shadow, plus a FAINT 2px accent ring at low alpha — `0 0 0 2px color-mix(in oklch, var(--project-accent) 15%, transparent)` — a subtle hint, not a prominent ring — and a two-layer background glow: a mid glow with negative spread (`0 0 90px -18px color-mix(in oklch, var(--project-accent) 25%, transparent)`) and a wide, very-low-alpha bloom with positive spread (`0 0 160px 20px color-mix(in oklch, var(--project-accent) 12%, transparent)`) so the accent reads as depth BEHIND the card rather than a ring hugging it), and the 2px accent top-edge gradient (`.input-card::before`) live on the BASE rules and apply to BOTH layouts (compact and expanded render identically). Do NOT add layout-specific shadows to `.input-layout[data-layout=...] .input-card` rules — only sizing/centering (compact) and flex (expanded) belong there.
