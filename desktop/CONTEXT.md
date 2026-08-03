# Desktop Shell (Tauri)

## Intent

The Tauri desktop shell provides a native OS WebView window for the Genesis Phoenix dashboard. It launches the standard Elixir release backend (`genesis_desktop`) as a child process, waits for it to be ready, then opens a WebView pointing to `http://localhost:9999`.

This is the native application layer — it contains NO Elixir code. The actual application logic lives in `./apps/evo_dash/` (Phoenix backend) and `./apps/evo_git/` (core runtime).

## Routing Table

- `./src-tauri/` → Tauri project (Rust source, Cargo.toml, tauri.conf.json)

## API Surface

| File | Purpose |
|------|---------|
| `src-tauri/src/main.rs` | Rust entry point — initializes Tauri, builds system tray (Show Window / Quit menu), spawns backend, opens window, intercepts close-to-tray |
| `src-tauri/src/sidecar.rs` | Backend lifecycle: env config (PHX_IP bind address, PORT), spawn release launcher process, health-check polling, shutdown |
| `src-tauri/Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-dialog, reqwest) |
| `src-tauri/tauri.conf.json` | Tauri config: window settings, trayIcon config, resource bundle reference, bundle metadata |
| `src-tauri/capabilities/default.json` | Tauri v2 permissions: dialog (directory picker) |
| `src-tauri/resources/genesis-backend/` | Placeholder directory where the built Elixir release (`_build/prod/rel/genesis_desktop/`) is placed before `cargo tauri build` |

## Constraints

- **No log files — console only**: Neither the Rust shell nor the sidecar writes any log file. The Elixir backend's stdout/stderr are drained and re-printed by `sidecar.rs` to the desktop process's own stdout/stderr with a `[backend] ` prefix (piped → `println!`/`eprintln!`); in `--headless` mode they are inherited directly (`Stdio::inherit`). So logs are only visible when the app is launched from a terminal. No `--log` flags, no app-data log dir, no logging env vars are passed to the backend (sidecar env is only PORT/PHX_IP/PHX_SERVER/SECRET_KEY_BASE/RELEASE_DISTRIBUTION/EVOGIT_DESKTOP).
- Tauri v2 (not v1) — API and config schema differ significantly. Pinned in `Cargo.lock`: `tauri` 2.11.3, `tauri-build` 2.x. The `"tray-icon"` Cargo feature **is** enabled alongside `"devtools"`.
- **System tray support**: closing the window hides it to the tray (via `WindowEvent::CloseRequested` → `api.prevent_close()` + `window.hide()`). The tray icon has "Show Window" and "Quit" menu items; left-clicking the tray icon also shows the window. "Quit" kills the backend process and exits.
- **Configurable binding address**: the backend binds to `127.0.0.1` (localhost) by default. Set `EVOGIT_BIND=0.0.0.0` before launching for remote access. The `PORT` env var (default 9999) controls the backend port. The WebView always connects via `localhost` regardless of bind address.
- The desktop shell contains NO Elixir code — only Rust
- `withGlobalTauri: true` — the webview gets `window.__TAURI__` API without npm imports
- Requires Rust toolchain to build
- The Elixir release directory must be placed at `src-tauri/resources/genesis-backend/` before `cargo tauri build`

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
│ Phoenix Server      │ Your Elixir app (standard mix release)
│ (Child Process)     │
└─────────────────────┘
```

Tauri launches the Phoenix app as a child process via the mix release launcher script (`bin/genesis_desktop start`). The WebView connects to Phoenix over HTTP to render the LiveView UI. Closing the window hides it to the system tray — the backend keeps running. The user fully exits via the tray's "Quit" menu item.

## Sidecar Lifecycle

1. Tauri spawns the Elixir release launcher (`bin/genesis_desktop start`) with env vars: `PORT=9999`, `PHX_IP=127.0.0.1`, `PHX_SERVER=true`, `SECRET_KEY_BASE=<local>`, `RELEASE_DISTRIBUTION=none`, `EVOGIT_DESKTOP=1`
2. Tauri polls `http://localhost:9999` until the backend responds (up to 30s)
3. The WebView window opens, pointing to `http://localhost:9999`
4. Closing the window hides it to the system tray (backend keeps running); the "Quit" tray menu item kills the backend process and exits

## Build Process

```bash
# Build the Elixir release (produces the release directory tree)
MIX_ENV=prod mix release genesis_desktop

# Place the release directory where Tauri expects it as a bundled resource
rm -rf desktop/src-tauri/resources/genesis-backend
cp -a _build/prod/rel/genesis_desktop desktop/src-tauri/resources/genesis-backend

# Build the Tauri app (bundles the release + produces native installers)
cd desktop/src-tauri && cargo tauri build
```

The Tauri config references the release directory at `resources: ["resources/genesis-backend"]`. Tauri bundles the entire directory tree as an application resource, accessible at runtime via `app.path().resource_dir()`.
