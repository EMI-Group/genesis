# Tauri Project (Rust Source)

## Intent

The Rust source for the Genesis Tauri v2 desktop shell. It launches the standard Elixir release (via its launcher script) as a child process, manages a native WebView window, and provides a **system tray** for background operation. The backend binds to `127.0.0.1` by default (configurable via `EVOGIT_BIND`).

## Routing Table

- `./src/` → Rust source code (main entry point, sidecar lifecycle management)
- `./capabilities/` → Tauri v2 permission configurations
- `./icons/` → Application and tray icons
- `./resources/` → Bundled resources (genesis-backend release directory)

## API Surface

| File | Purpose |
|------|---------|
| `src/main.rs` | Rust entry point — initializes Tauri, builds system tray (Show Window / Quit menu), spawns the Elixir release, opens window, intercepts close-to-tray |
| `src/sidecar.rs` | Sidecar lifecycle: env config (PHX_IP bind address, PORT), spawn release launcher process, health-check polling, shutdown |
| `Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-dialog, reqwest) |
| `tauri.conf.json` | Tauri config: window settings, trayIcon config, release resource reference, bundle metadata |
| `capabilities/default.json` | Tauri v2 permissions: shell (release launcher), dialog (directory picker). No tray permission needed — tray managed from Rust. |
| `icons/icon.png` | Tray icon (also used for window icon) |

## Constraints

- Tauri v2 — API differs significantly from v1 (tray builder, menu, window events all changed).
- The `tray-icon` Cargo feature must be enabled for system tray support.
- `capabilities/default.json` does NOT need a tray permission — tray icons are managed from Rust, not the frontend JS API.
- The Elixir release directory (`resources/genesis-backend/`) — a standard `mix release` tree — must be placed in `src-tauri/resources/genesis-backend/` before `cargo tauri build`. Tauri bundles it as a resource.
- **Two different launcher resolution strategies exist and must be kept consistent**: GUI mode (`src/sidecar.rs` `launcher_path`, lines 63-70) resolves ONLY via `app.path().resource_dir()` + `resources/genesis-backend/bin/<launcher>`; headless mode (`src/main.rs` `resolve_sidecar_path`, lines 91-118) checks `<exe_dir>/resources/...` first, then `$CARGO_MANIFEST_DIR`. The Nix package layout (`<store>/lib/genesis-desktop/...`) only satisfies the headless strategy — see Known Issues.
- The desktop shell contains NO Elixir code — only Rust.
- The release is launched via its `bin/genesis_desktop` launcher script (`bin/genesis_desktop.bat` on Windows) with the `start` command, which is a **foreground** process (blocks until the BEAM VM exits). This gives the Rust parent clean ownership/kill semantics.

## System Tray Behavior

- **Close window** → `WindowEvent::CloseRequested` is intercepted (`api.prevent_close()` + `window.hide()`); the window is hidden to the tray and the backend keeps running.
- **Tray menu "Show Window"** → `window.show()` + `window.set_focus()`
- **Tray menu "Quit"** → takes ownership of the `SidecarHandle`, calls `child.kill()`, then `app.exit(0)`
- **Left-click tray icon** → shows and focuses the main window (via `.on_tray_icon_event`)

## Known Issues

- **Nix-built binary panics at startup in GUI mode** (`nix build .#desktop` → `Failed to setup app: error encountered during setup hook: No such file or directory (os error 2)`, panic at tauri-2.11.3 crates/tauri/src/app.rs:1425, `Error::Setup` = "error encountered during setup hook: {0}").
  **Root cause**: `sidecar::launcher_path` (src/sidecar.rs:63-70) resolves the launcher ONLY via `app.path().resource_dir()`. On Linux, tauri-utils `resource_dir_from` (tauri-utils/src/platform.rs, `resource_dir()` docs in src/path/desktop.rs) returns, in order: (1) `<exe_dir>/../lib/<productName>` if it canonicalizes (cargo/dev layout), (2) `$APPDIR/usr/lib/<productName>` (AppImage only), (3) **hardcoded `/usr/lib/<productName>`** fallback. The Nix derivation (`genesis-desktop.nix` at repo root) installs the binary at `<store>/lib/genesis-desktop/genesis-desktop` with the release symlinked at `<store>/lib/genesis-desktop/resources/genesis-backend` (exe_dir-relative layout), so `resource_dir()` resolves to `/usr/lib/genesis-desktop` — which does not exist on NixOS → `Command::new(launcher).spawn()` (sidecar.rs:90) fails with ENOENT → setup hook error → panic. CI works because the Tauri bundler puts resources exactly at `/usr/lib/<name>/resources/...` (deb), `$APPDIR/usr/lib/<name>/resources/...` (AppImage), `Contents/Resources/resources/...` (macOS), or `<exe_dir>/resources/...` (Windows) — all matching `resource_dir()`. `--headless` works with the Nix layout because `main.rs:91-118` checks `<exe_dir>/resources/...` first.
  **Fix (recommended)**: make `launcher_path` existence-aware with an exe_dir fallback mirroring `main.rs::resolve_sidecar_path` — check `<exe_dir>/resources/genesis-backend/bin/<launcher>` first (covers Nix, and also AppImage/deb/Windows where exe_dir == resource_dir), then `resource_dir()/resources/...` (covers macOS `Contents/MacOS` vs `Contents/Resources`); return a descriptive error if neither exists. Alternatively, restructure `genesis-desktop.nix` to satisfy tauri's layout heuristic (e.g. binary at `$out/lib/genesis-desktop/bin/` + release at `$out/lib/genesis-desktop/lib/genesis-desktop/resources/genesis-backend`), but that is fragile and relies on undocumented tauri internals.
  Note: the Nix release bundles its own ERTS (nixpkgs `mixRelease` keeps `erts-*` and rewrites `${erlang}/lib/erlang` refs into the release), so once the launcher path resolves, the backend should start without extra `erl` on PATH.

- The backend binds to `127.0.0.1` (localhost only) by default for security.
- Set `EVOGIT_BIND=0.0.0.0` before launching to allow remote access.
- The bind address is passed to Phoenix as `PHX_IP`.
- The `PORT` env var (default 9999) controls the backend port.
- The WebView always connects via `localhost` (same machine), regardless of bind address.
