# `apps/evo_dash/assets/` — Frontend Assets for EvoDash

## Intent

This directory holds all frontend source assets (JavaScript, CSS, vendor libraries, and editor config) for the EvoDash Phoenix web application. It is the single source of truth for client-side code, compiled by **esbuild** (JS) and **Tailwind CSS 4** (styles) via Mix aliases (`assets.build`, `assets.deploy`).

## API Surface

### Directories & Files

| Path | Role |
|---|---|
| `js/app.js` | Main JS entry point. Imports `phoenix_html`, establishes a `LiveSocket` with colocated hooks from `phoenix-colocated/evo_dash`, wires the topbar progress indicator on LiveView navigation, and enables live-reload dev features (server log streaming, click-to-editor). |
| `css/app.css` | Main CSS entry point. Configures Tailwind CSS 4 with source scanning across `css/`, `js/`, and `lib/evo_dash_web/`. Loads Heroicons, DaisyUI (themes disabled), and two custom DaisyUI themes ("dark" with purple tones, "light" default with warm orange primary). Defines LiveView-specific custom variants (`phx-click-loading`, `phx-submit-loading`, `phx-change-loading`) and a `dark` variant based on `data-theme` attribute. |
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

## Routing Table

This directory has no child subdirectories — all work is handled by the individual files within this directory (`js/app.js`, `css/app.css`, `vendor/` libraries, `tsconfig.json`). For any changes to frontend JavaScript, CSS styling, vendor libraries, or TypeScript config, work directly on the relevant file in this node; no subagent delegation to child paths is needed.

## Constraints

- **Build tooling**: JS is bundled by esbuild; CSS is processed by Tailwind CSS 4. No Node.js toolchain is required — vendor libs are committed directly.
- **Tailwind source scanning** is explicitly configured via `@source` directives in `app.css` covering `css/`, `js/`, and `lib/evo_dash_web/`. Any new directories with Tailwind classes must be added as `@source` entries.
- **Theme system**: DaisyUI's built-in themes are disabled (`themes: false`). Only the two custom themes ("dark" and "light") are available. Dark mode is driven by the `data-theme="dark"` attribute, not `prefers-color-scheme` alone.
- **Phoenix LiveView hooks** are sourced from `phoenix-colocated/evo_dash` (generated hooks from colocated `.exh` hook files in the LiveView templates). Do not register hooks manually in `app.js` for hooks that are already colocated.
- **Live reload features** (server logs, click-to-editor) are gated behind `process.env.NODE_ENV === "development"` and must not be relied upon in production.
- **No `node_modules/`**: Dependencies are either in `vendor/` or resolved via esbuild's path aliasing to `../deps/`. Do not run `npm install` unless a `package.json` is introduced.
