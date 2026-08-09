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
| `src/commands.rs` | Custom Tauri commands exposed to the dashboard frontend — currently `pick_directory` (native folder picker; on macOS it bypasses rfd and drives `NSOpenPanel` directly via objc2 — see "Native Folder Picker" below) |
| `Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-dialog, reqwest; macOS-only direct deps `objc2` + `objc2-app-kit` for the folder picker) |
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

## Native Folder Picker — macOS

### Root cause (two layers)

The dashboard's directory picker originally invoked the tauri-plugin-dialog `plugin:dialog|open` command. On macOS the plugin calls `set_parent(&window)` and rfd presents NSOpenPanel as a **sheet** (`beginSheetModalForWindow:completionHandler:`). When the parent window isn't visible / the app isn't active — aggravated by the close-to-tray behavior above (window hidden to tray, app demoted to inactive accessory) — the sheet never appears and the invoke **hangs forever** (or rfd panics resolving the parent window handle → invoke rejects). Linux/Windows were unaffected (rfd gtk3/win32 path).

**First fix (commit `4f0f6ee8`):** custom Rust command `pick_directory` in `src/commands.rs`, registered via `.invoke_handler(tauri::generate_handler![commands::pick_directory])` on the Builder:

1. macOS only (`#[cfg(target_os = "macos")]`): `app.set_activation_policy(tauri::ActivationPolicy::Regular)` then `window.show()` + `window.set_focus()`.
2. Blocking dialog API `app.dialog().file().blocking_pick_folder()` inside `tauri::async_runtime::spawn_blocking` (blocking dialogs must NOT run on the main/async thread) — deliberately **without** `set_parent`, so rfd falls back to an **app-modal** panel instead of a window-attached sheet.
3. Returns `Result<Option<String>, String>` — the selected path, `null` on cancel, or an error string.

**Why that fix still failed on macOS (the real root cause):** `set_activation_policy` only changes the app's activation *policy* (dock-icon visibility); it does **not activate** the app (make it frontmost). rfd's macOS backend never activates the app either — its `PolicyManager` (`rfd-0.16.0/src/backend/macos/utils/policy_manager.rs`) merely flips a `Prohibited` policy to `Accessory`, and the panel is raised to `CGShieldingWindowLevel`. AppKit will not present a `runModal` panel as the key window of an **inactive** app — so the panel never appears (or never takes key status) and `runModal` blocks the main thread forever. The blocking-pool thread then blocks forever too, waiting on rfd's `dispatch2::run_on_main` (a `dispatch_sync` onto the main queue, `dispatch2-0.3.1/src/main_thread_bound.rs`), and the JS-side 15s timeout fires → fallback to `plugin:dialog|open` → which hangs on the sheet → manual-path fallback. Both JS paths failed for the same underlying reason: the app was never activated. (The async plugin path is additionally a dead end: `ModalFuture` (`rfd-0.16.0/src/backend/macos/modal_future.rs`) picks `app.windows().firstObject()` — the hidden window — and presents a sheet on it, which never appears when the window is hidden or the app inactive.)

### Fix (current)

`pick_directory` on macOS bypasses rfd entirely and drives `NSOpenPanel` directly via objc2 (declared as macOS-only direct deps in `Cargo.toml`: `objc2` 0.6 + `objc2-app-kit` 0.3, features `NSApplication`/`NSOpenPanel`/`NSPanel`/`NSResponder`/`NSRunningApplication`/`NSSavePanel`/`NSWindow` — already in Cargo.lock via rfd, so no new versions):

1. `window.show()` + `window.set_focus()` (queued on the event loop proxy, processed FIFO before the panel task).
2. `app.run_on_main_thread(...)` runs the whole interaction on the main thread: `NSApplication.setActivationPolicy(Regular)` → **`activateIgnoringOtherApps(true)`** (deprecated in macOS 14 but functional on all supported versions; this is the piece that was always missing) → build the panel (`setCanChooseDirectories(true)`, `setCanChooseFiles(false)`, `setAllowsMultipleSelection(false)`, `setCanCreateDirectories(true)`) → `runModal()` (app-modal, NOT a sheet).
3. The result travels back over an `std::sync::mpsc` channel; the async command waits on it via `tauri::async_runtime::spawn_blocking` (never block a tokio worker or the main thread).
4. Contract unchanged: `Ok(Some(path))` on pick, `Ok(None)` on user-cancel (quiet in JS), `Err(String)` on real failure. No panic paths. Linux/Windows keep the rfd blocking path unchanged (works there).

**Verification note:** the macOS module is `#[cfg(target_os = "macos")]`-guarded and cannot be compiled on Linux. It was type-checked for `x86_64-apple-darwin` against the real objc2-app-kit 0.3.2 API using a scratch harness with a `tauri` stub (the stub caught a nested-`Result` type error in the channel plumbing before shipping). Re-verify on a real macOS host (`cargo check --target x86_64-apple-darwin` or CI) after any change to `commands.rs`.

**ACL note:** app-defined commands registered via `generate_handler!` are NOT gated by the Tauri v2 capability system (the ACL covers core/plugin commands) — no capability entry was needed (confirmed against the generated `gen/schemas/` after build). Keep `capabilities/default.json` unchanged for this command.

**Frontend coupling (coordinated separately):** the dashboard JS (`apps/evo_dash/assets/js/app.js`) invokes `pick_directory` for the folder picker, falling back to `plugin:dialog|open` for builds without the command (browser mode / older desktop builds). Keep the command name and `Result<Option<String>, String>` contract stable. No JS changes are required for this fix (same contract, same timing envelope).

**Build gotcha:** tauri-build validates `bundle.resources` paths at compile time — `resources/genesis-backend/` must exist before `cargo check`/`cargo tauri build` (error: `resource path 'resources/genesis-backend' doesn't exist`). Create it locally with `mkdir -p resources/genesis-backend`; it is deliberately untracked in git (the Nix flake derivation symlinks a built release there in a preBuild hook — see root CONTEXT.md Known Issue).

## Windows / Linux picker behavior (in contrast to macOS)

- **No default directory is ever set.** The non-macOS branch (`commands.rs:38-45`) calls `app.dialog().file().blocking_pick_folder()` with a bare `FileDialogBuilder` — no `set_directory`, no title, no filters, no parent. Verified in pinned crate sources: tauri-plugin-dialog 2.7.1 `src/desktop.rs:82-108` only forwards *set* fields; rfd 0.16.0 `src/backend/win_cid/file_dialog/dialog_ffi.rs:223-252,312-323` calls `SetFolder` only when `starting_directory` is `Some` and otherwise sets just `FOS_PICKFOLDERS`. So the Windows IFileDialog opens at the shell's own default (Documents, or the per-exe last-visited PIDL MRU under `HKCU\...\ComDlg32\LastVisitedPidlMRU` — user/registry driven, NOT the app). The dialog may *open* inside `%LOCALAPPDATA%\genesis-desktop` if the user browsed there before, but the returned path is always the user's selection.
- **Returned path is always absolute, verbatim, native format.** Result comes from `GetDisplayName(SIGDN_FILESYSPATH)` (rfd 0.16.0 `src/backend/win_cid/file_dialog/com.rs:92-110`) → absolute backslash path like `D:\Test`, passed through `p.to_string_lossy()` unchanged (`commands.rs:40`). The picker can NEVER return a relative or name-only value on Windows; only cancel (`Ok(None)`). Any mangled prefix observed downstream (e.g. dashboard errors like `Directory does not exist: c:/Users/...`) is caused by downstream code, not this command.
- **Backend cwd on Windows is inherited — never set.** `launcher_command` (`sidecar.rs:56-73`), `sidecar::start` (`sidecar.rs:144-152`) and `run_headless` (`main.rs:143-148`) set no `.current_dir()`, so `cmd.exe /c genesis_desktop.bat start` → BEAM inherits the Tauri app's cwd (Explorer double-click → exe dir; Start Menu → shortcut "Start in"; portable exe → wherever it was extracted). Elixir's `Path.expand/1` in the dashboard/runtime resolves bare names against that cwd — this is how a name-only value can become `<app-cwd>/<name>`.
- **`%LOCALAPPDATA%\genesis-desktop` is a user-side folder, not created by the app.** It matches none of the app's own directories: Tauri `app_local_data_dir` = `%LOCALAPPDATA%\com.genesis.desktop` (bundle identifier), NSIS install dir = `%LOCALAPPDATA%\EvoX Genesis` (productName, per-user) or `%PROGRAMFILES64%\EvoX Genesis` (per-machine; tauri-bundler 2.9.4 installer.nsi:501-514), WebView2 default user-data folder = `<exe-dir>\genesis-desktop.exe.WebView2`, backend `EvoGit.Platform.data_dir` = `%APPDATA%\genesis`. A folder literally named `genesis-desktop` under LocalAppData is consistent with a manually extracted portable build (the CI `.tar.gz`), whose exe dir then becomes the app AND backend cwd.

## Design Decisions

- **Folder picker = direct NSOpenPanel on macOS, rfd elsewhere.** rfd's macOS backend cannot present a modal panel for an inactive app (it never activates the app) and its async path requires a visible parent window for the sheet. Building the panel directly on the main thread with objc2 gives deterministic ordering (activate → present), avoids rfd's `dispatch_sync` main-queue hop and its `run_on_main` panic path, and keeps the Linux/Windows rfd path untouched (it works there).
- **`activateIgnoringOtherApps:YES` over `activate` (macOS 14+).** The non-deprecated `NSApp activate` is macOS 14+ only; the deprecated method works on every supported macOS and is still functional on 14/15. No runtime version check needed. The deprecation is `#[allow(deprecated)]`-scoped to the single call site.
- **`runModal` on the main thread is acceptable.** It blocks the main thread in a nested modal event loop for the duration of the user's interaction — the same behaviour rfd's blocking API already had (via `dispatch_sync`), and the correct semantics for an app-modal dialog. The main queue and Tauri's event-loop messages keep being serviced in common run-loop modes.
- **Channel + `spawn_blocking` for the result.** `run_on_main_thread` is fire-and-forget, so the result travels back over an `mpsc` channel; the async command waits via `tauri::async_runtime::spawn_blocking` so no tokio worker thread is blocked for the (potentially long) panel interaction.
- **No Rust-side timeout.** The JS side already races each path against 15s. A Rust-side timeout could abort while the panel is still legitimately open (user deciding slowly); the JS timeout is the designed backstop.
- **Cancel is `Ok(None)`, not an error.** The JS treats `Ok(None)` as a quiet cancel; only genuine failures are `Err(String)`. `runModal`'s non-OK responses (cancel/abort) all map to `Ok(None)`.

## Regenerating Icons

The icon set in `./icons/` (5 files: `icon.png`, `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`) is generated from the EVOX brand logo — NOT from the placeholder logo. Source SVGs live in the sibling app (read-only): `apps/evo_dash/priv/static/images/logo.svg` (dark gray `#373435` + red `#C8383C`, light-background variant — the one used for the icons) and `logo-alt.svg` (white `#FEFEFE` + red, dark-background variant). Icons use a transparent background (the old placeholder set was dark-gray + violet on transparent, so the new set keeps the same style). Regenerated from the updated brand logo in commit `08ad3110` ("Update logo"; the previous set, from `bacf702c`, was stale — see also commit `282a937e` which fixed the earlier RGB/invalid formats to proper RGBA).

**Gotcha — huge viewBox**: both SVGs declare `viewBox="0 0 16002.59 12975.69"` (aspect ratio ≈ 1.2334). Rendering that raw produces a tiny logo on a vast canvas (the artwork fills the entire viewBox edge-to-edge, so plain `-trim` finds nothing to cut). The working recipe — render high-res, then trim-and-fit to ~86% of a 1024x1024 transparent canvas:

```bash
TMP=$TMPDIR/evox_icons; mkdir -p "$TMP"
# 1. render the SVG at high resolution (rsvg-convert via nixpkgs#librsvg)
nix shell nixpkgs#librsvg -c rsvg-convert -w 4096 \
  apps/evo_dash/priv/static/images/logo.svg -o "$TMP/raw.png"     # 4096x3322
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
