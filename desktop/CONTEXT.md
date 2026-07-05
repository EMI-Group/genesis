# Desktop Shell (Tauri)

## Intent

The Tauri desktop shell provides a native OS WebView window for the EvoGit Phoenix dashboard. It launches the Burrito-wrapped Elixir backend as a **sidecar process**, waits for it to be ready, then opens a WebView pointing to `http://localhost:9999`.

This is the native application layer — it contains NO Elixir code. The actual application logic lives in `./apps/evo_dash/` (Phoenix backend) and `./apps/evo_git/` (core runtime).

## Routing Table

- `./src-tauri/` → Tauri project (Rust source, Cargo.toml, tauri.conf.json)

## API Surface

| File | Purpose |
|------|---------|
| `src-tauri/src/main.rs` | Rust entry point — initializes Tauri, builds system tray (Show Window / Quit menu), spawns sidecar, opens window, intercepts close-to-tray |
| `src-tauri/src/sidecar.rs` | Sidecar lifecycle: env config (PHX_IP bind address, PORT), spawn backend process, health-check polling, shutdown |
| `src-tauri/Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-dialog, reqwest) |
| `src-tauri/tauri.conf.json` | Tauri config: window settings, trayIcon config, sidecar reference, bundle metadata |
| `src-tauri/capabilities/default.json` | Tauri v2 permissions: shell (sidecar), dialog (directory picker) |

## Architecture

```
┌─────────────────────┐
│ Tauri Window        │ Native window (Rust/WebView2/WebKit)
│ ┌───────────────┐   │
│ │ Phoenix UI    │   │ Your LiveView app rendered in WebView
│ └───────────────┘   │
└─────────┬───────────┘
          │ HTTP — serves Phoenix UI to the WebView
          │
┌─────────┴───────────┐
│ Phoenix Server      │ Your Elixir app (Burrito-wrapped sidecar)
│ (Sidecar Process)   │
└─────────────────────┘
```

Tauri launches the Phoenix app as a sidecar process. The WebView connects to Phoenix over HTTP to render the LiveView UI. Closing the window hides it to the system tray — the backend keeps running. The user fully exits via the tray's "Quit" menu item.

## Sidecar Lifecycle

1. Tauri spawns the Burrito-wrapped Elixir binary (`genesis-backend`) with env vars: `PORT=9999`, `PHX_IP=127.0.0.1`, `PHX_SERVER=true`, `SECRET_KEY_BASE=<local>`, `RELEASE_DISTRIBUTION=none`, `EVOGIT_DESKTOP=1`
2. Tauri polls `http://localhost:9999` until the backend responds (up to 30s)
3. The WebView window opens, pointing to `http://localhost:9999`
4. Closing the window hides it to the system tray (backend keeps running); the "Quit" tray menu item kills the sidecar and exits

## Build Process

```bash
# Build the Burrito-wrapped Elixir release (produces the sidecar binary)
MIX_ENV=prod mix release genesis_desktop

# Build the Tauri app (bundles the sidecar + produces native installers)
cd src-tauri && cargo tauri build
```

The Tauri config references the sidecar at `externalBin: ["sidecars/genesis-backend"]`. Tauri appends the platform triple automatically (e.g., `genesis-backend-aarch64-apple-darwin`).

## Constraints

- Tauri v2 (not v1) — API and config schema differ significantly. Pinned in `Cargo.lock`: `tauri` 2.11.3, `tauri-build` 2.x. The `"tray-icon"` Cargo feature **is** enabled alongside `"devtools"`.
- **System tray support**: closing the window hides it to the tray (via `WindowEvent::CloseRequested` → `api.prevent_close()` + `window.hide()`). The tray icon has "Show Window" and "Quit" menu items; left-clicking the tray icon also shows the window. "Quit" kills the sidecar and exits.
- **Configurable binding address**: the backend binds to `127.0.0.1` (localhost) by default. Set `EVOGIT_BIND=0.0.0.0` before launching for remote access. The `PORT` env var (default 9999) controls the backend port. The WebView always connects via `localhost` regardless of bind address.
- The desktop shell contains NO Elixir code — only Rust
- `withGlobalTauri: true` — the webview gets `window.__TAURI__` API without npm imports
- Requires Rust toolchain + Zig (for Burrito cross-compilation) to build
- The sidecar binary must be placed at `src-tauri/sidecars/genesis-backend-{target-triple}` before `cargo tauri build`
