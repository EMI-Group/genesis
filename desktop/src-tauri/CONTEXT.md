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
| `src/commands.rs` | Custom Tauri commands exposed to the dashboard frontend — currently `pick_directory` (native folder picker that avoids the macOS sheet hang, see "Native Folder Picker" below) |
| `Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-dialog, reqwest) |
| `tauri.conf.json` | Tauri config: window settings, trayIcon config, release resource reference, bundle metadata |
| `capabilities/default.json` | Tauri v2 permissions: shell (release launcher), dialog (directory picker). No tray permission needed — tray managed from Rust. |
| `icons/icon.png` | 512x512 RGBA EVOX-brand icon (transparent background) — derived from `apps/evo_dash/priv/static/images/logo.svg`; kept as the standard source icon, not referenced by `bundle.icon` (which lists only `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`) |

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
- **Left-click tray icon** → shows and focuses the main window via `.on_tray_icon_event` (matches `Click { Left, Up }`) combined with `.show_menu_on_left_click(false)`. The flag is required on macOS: with a menu attached, the default left-click opens the menu on mouse-down and swallows the `Click(Left, Up)` event, so the window never pops; with the flag set, left-click emits the event (menu stays on right-click).

## Native Folder Picker — macOS Sheet Hang

**Root cause:** the dashboard's directory picker originally invoked the tauri-plugin-dialog `plugin:dialog|open` command. On macOS the plugin calls `set_parent(&window)` and rfd presents NSOpenPanel as a **sheet** (`beginSheetModalForWindow:completionHandler:`). When the parent window isn't visible / the app isn't active — aggravated by the close-to-tray behavior above (window hidden to tray, app demoted to inactive accessory) — the sheet never appears and the invoke **hangs forever** (or rfd panics resolving the parent window handle → invoke rejects). Linux/Windows were unaffected (rfd gtk3/win32 path).

**Fix (commit `4f0f6ee8`):** custom Rust command `pick_directory` in `src/commands.rs`, registered via `.invoke_handler(tauri::generate_handler![commands::pick_directory])` on the Builder:

1. macOS only (`#[cfg(target_os = "macos")]`): `app.set_activation_policy(tauri::ActivationPolicy::Regular)` then `window.show()` + `window.set_focus()` — re-activates the app after close-to-tray so the dialog can present.
2. Blocking dialog API `app.dialog().file().blocking_pick_folder()` inside `tauri::async_runtime::spawn_blocking` (blocking dialogs must NOT run on the main/async thread) — deliberately **without** `set_parent`, so rfd falls back to an **app-modal** panel that always presents instead of a window-attached sheet.
3. Returns `Result<Option<String>, String>` — the selected path, `null` on cancel, or an error string.

**ACL note:** app-defined commands registered via `generate_handler!` are NOT gated by the Tauri v2 capability system (the ACL covers core/plugin commands) — no capability entry was needed (confirmed against the generated `gen/schemas/` after build). Keep `capabilities/default.json` unchanged for this command.

**Frontend coupling (coordinated separately):** the dashboard JS (`apps/evo_dash/assets/js/app.js`) invokes `pick_directory` for the folder picker, falling back to `plugin:dialog|open` for builds without the command (browser mode / older desktop builds). Keep the command name and `Result<Option<String>, String>` contract stable.

**Build gotcha:** tauri-build validates `bundle.resources` paths at compile time — `resources/genesis-backend/` must exist before `cargo check`/`cargo tauri build` (error: `resource path 'resources/genesis-backend' doesn't exist`). Create it locally with `mkdir -p resources/genesis-backend`; it is deliberately untracked in git (the Nix flake derivation symlinks a built release there in a preBuild hook — see root CONTEXT.md Known Issue).

## Regenerating Icons

The icon set in `./icons/` (5 files: `icon.png`, `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`) is generated from the EVOX brand logo — NOT from the placeholder logo. Source SVGs live in the sibling app (read-only): `apps/evo_dash/priv/static/images/logo.svg` (dark gray `#373435` + red `#C8383C`, light-background variant — the one used for the icons) and `logo-alt.svg` (white `#FEFEFE` + red, dark-background variant). Icons use a transparent background (the old placeholder set was dark-gray + violet on transparent, so the new set keeps the same style).

**Gotcha — huge viewBox**: both SVGs declare `viewBox="0 0 98668.67 73192.18"`. Rendering that raw produces a tiny logo on a vast canvas (the artwork fills the entire viewBox edge-to-edge, so plain `-trim` finds nothing to cut). The working recipe — render high-res, then trim-and-fit to ~86% of a 1024x1024 transparent canvas:

```bash
TMP=$TMPDIR/evox_icons; mkdir -p "$TMP"
# 1. render the SVG at high resolution (rsvg-convert via nixpkgs#librsvg)
nix shell nixpkgs#librsvg -c rsvg-convert -w 4096 \
  apps/evo_dash/priv/static/images/logo.svg -o "$TMP/raw.png"     # 4096x3039
# 2. trim uniform/transparent margins (no-op here), fit long edge to ~880px
nix shell nixpkgs#imagemagick -c bash -c '
  magick '"$TMP"'/raw.png -fuzz 0% -trim +repage '"$TMP"'/trimmed.png
  magick '"$TMP"'/trimmed.png -resize 880x880 '"$TMP"'/fit.png
  # 3. center onto a 1024x1024 transparent RGBA canvas
  magick -size 1024x1024 xc:none '"$TMP"'/fit.png -gravity center -composite '"$TMP"'/evox_1024.png'
# 4. generate the icon set (default output dir: ./icons)
cd desktop/src-tauri && npx --yes @tauri-apps/cli@^2 icon "$TMP/evox_1024.png"
# or: cargo tauri icon "$TMP/evox_1024.png"  (tauri-cli must be installed; NOT in nixpkgs)
```

**Extra files**: `tauri icon` also emits `64x64.png`, `128x128@2x.png`, `Square*.png`, `StoreLogo.png`, and `android/` + `ios/` trees. Nothing references them — `tauri.conf.json` `bundle.icon` lists only `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`, and the tray icon comes from `app.default_window_icon()` (derived from `bundle.icon`). Delete the extras to keep the exact 5-file set.

**Tray tradeoff**: the tray icon is the dark-gray + red EVOX logo — the dark-gray parts can be hard to see on dark system trays. Accepted for now (single simple icon set); a white/red variant from `logo-alt.svg` could be used later if tray visibility matters.

## Configurable Binding Address

- The backend binds to `127.0.0.1` (localhost only) by default for security.
- Set `EVOGIT_BIND=0.0.0.0` before launching to allow remote access.
- The bind address is passed to Phoenix as `PHX_IP`.
- The `PORT` env var (default 9999) controls the backend port.
- The WebView always connects via `localhost` (same machine), regardless of bind address.
