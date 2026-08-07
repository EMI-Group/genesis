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
| `src/sidecar_path.rs` | Shared launcher-path resolution (`resolve_launcher/2`) — first existing candidate wins, descriptive error listing all candidates when none exist; used by both GUI (`sidecar.rs`) and headless (`main.rs`) modes; contains the unit tests |
| `Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-dialog, reqwest) |
| `tauri.conf.json` | Tauri config: window settings, trayIcon config, release resource reference, bundle metadata |
| `capabilities/default.json` | Tauri v2 permissions: shell (release launcher), dialog (directory picker). No tray permission needed — tray managed from Rust. |
| `icons/icon.png` | Tray icon (also used for window icon) |

## Constraints

- Tauri v2 — API differs significantly from v1 (tray builder, menu, window events all changed).
- The `tray-icon` Cargo feature must be enabled for system tray support.
- `capabilities/default.json` does NOT need a tray permission — tray icons are managed from Rust, not the frontend JS API.
- The Elixir release directory (`resources/genesis-backend/`) — a standard `mix release` tree — must be placed in `src-tauri/resources/genesis-backend/` before `cargo tauri build`. Tauri bundles it as a resource.
- **Launcher path resolution is shared between GUI and headless modes**: `src/sidecar_path.rs` `resolve_launcher/2` is a pure function that takes candidate base dirs + launcher name, returns the first candidate that `exists()`, or a descriptive error listing all candidates. GUI mode (`src/sidecar.rs` `launcher_path`) passes `[exe_dir, resource_dir, manifest_dir]`; headless mode (`src/main.rs` `resolve_sidecar_path`) passes `[exe_dir, manifest_dir]`. Never add a divergent resolution strategy in one mode without updating the shared module — keep both callers on `resolve_launcher`.
- The desktop shell contains NO Elixir code — only Rust.
- The release is launched via its `bin/genesis_desktop` launcher script (`bin/genesis_desktop.bat` on Windows) with the `start` command, which is a **foreground** process (blocks until the BEAM VM exits). This gives the Rust parent clean ownership/kill semantics.

## System Tray Behavior

- **Close window** → `WindowEvent::CloseRequested` is intercepted (`api.prevent_close()` + `window.hide()`); the window is hidden to the tray and the backend keeps running.
- **Tray menu "Show Window"** → `window.show()` + `window.set_focus()`
- **Tray menu "Quit"** → takes ownership of the `SidecarHandle`, calls `child.kill()`, then `app.exit(0)`
- **Left-click tray icon** → shows and focuses the main window (via `.on_tray_icon_event`)

## Known Issues

- **FIXED — Nix-built binary panic at startup in GUI mode** (`nix build .#desktop` → `Failed to setup app: error encountered during setup hook: No such file or directory (os error 2)`, panic at tauri-2.11.3 crates/tauri/src/app.rs:1425). Fixed by commit "Fix Nix desktop binary startup panic via shared launcher path resolution": `launcher_path` (src/sidecar.rs) now resolves via `crate::sidecar_path::resolve_launcher(&[exe_dir, resource_dir, manifest_dir], LAUNCHER_NAME)` — existence-aware candidates in order:
  1. `<exe_dir>/resources/genesis-backend/bin/<launcher>` — covers the Nix store layout (`<store>/lib/genesis-desktop/resources/...`) and Windows (`<exe_dir>` = parent of the running executable).
  2. `<resource_dir>/resources/genesis-backend/bin/<launcher>` — covers macOS bundles (`Contents/Resources`) and Linux deb/AppImage (`/usr/lib/<name>`).
  3. `$CARGO_MANIFEST_DIR/resources/genesis-backend/bin/<launcher>` — dev mode.
  If none exist, a descriptive error listing ALL candidates is returned (never silently continues). Unit tests for the candidate-selection logic live in `src/sidecar_path.rs`.
  **Why the old code failed**: `launcher_path` resolved ONLY via `app.path().resource_dir()`. On Linux, tauri-utils `resource_dir_from` returns, in order: (1) `<exe_dir>/../lib/<productName>` if it canonicalizes (cargo/dev layout), (2) `$APPDIR/usr/lib/<productName>` (AppImage only), (3) **hardcoded `/usr/lib/<productName>`** fallback. The Nix derivation installs the binary at `<store>/lib/genesis-desktop/genesis-desktop` with the release symlinked at `<store>/lib/genesis-desktop/resources/genesis-backend`, so `resource_dir()` resolved to the nonexistent `/usr/lib/genesis-desktop` → `Command::new(launcher).spawn()` failed ENOENT → setup hook error → panic.
  **Known residual issues (out of scope of that fix)**: (a) GUI mode in containers/headless environments may panic later at `libappindicator-sys` load (`Failed to load ayatana-appindicator3 or appindicator3 dynamic library`) — the tray-icon crate dlopens the appindicator lib, which the final `genesis-desktop.nix` wrapper does not put on `LD_LIBRARY_PATH`; (b) headless mode in the Nix build fails after launch with `cat: .../releases/COOKIE: No such file or directory` — the read-only Nix store prevents the release from creating its cookie; neither affects launcher resolution.

## Configurable Binding Address

- The backend binds to `127.0.0.1` (localhost only) by default for security.
- Set `EVOGIT_BIND=0.0.0.0` before launching to allow remote access.
- The bind address is passed to Phoenix as `PHX_IP`.
- The `PORT` env var (default 9999) controls the backend port.
- The WebView always connects via `localhost` (same machine), regardless of bind address.
