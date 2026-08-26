# Desktop Shell (Tauri)

## Intent

The Tauri desktop shell provides a native OS WebView window for the Genesis Phoenix dashboard. It launches the standard Elixir release backend (`genesis_desktop`) as a child process, waits for it to be ready, then opens a WebView pointing to the backend's dynamically-picked free local port (an explicitly-set `PORT` env var is honored only when that port is free).

This is the native application layer — it contains NO Elixir code. The actual application logic lives in `./apps/evo_dash/` (Phoenix backend) and `./apps/evo_git/` (core runtime).

## Routing Table

- `./src-tauri/` → Tauri project (Rust source, Cargo.toml, tauri.conf.json)
- `./scripts/docker-dev/` → Dev/test-only Docker image from umbrella source (`mix release genesis` + `bin/genesis start`); see `scripts/docker-dev/README.md`

## API Surface

| File | Purpose |
|------|---------|
| `src-tauri/src/main.rs` | Rust entry point — initializes Tauri, builds system tray (Show Window · separator · Quit Genesis menu), spawns backend, opens window, intercepts close-to-tray; registers the `begin_quit` command; tray Quit shows+focuses the window and emits `quit-requested` to the webview for the web-page confirm flow |
| `src-tauri/src/sidecar.rs` | Backend lifecycle: env config (PHX_IP bind address, PORT), spawn release launcher process, health-check polling, shutdown |
| `src-tauri/Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-single-instance, reqwest) |
| `src-tauri/tauri.conf.json` | Tauri config: productName/mainBinaryName, updater plugin (endpoints, pubkey), resource bundle reference, bundle metadata (no config-declared window — the window is Rust-built) |
| `src-tauri/capabilities/default.json` | Tauri v2 permissions: shell (release launcher) |
| `src-tauri/resources/genesis-backend/` | Placeholder directory where the built Elixir release (`_build/prod/rel/genesis_desktop/`) is placed before `cargo tauri build` |

## Constraints

- **No log files — console only**: Neither the Rust shell nor the sidecar writes any log file. The Elixir backend's stdout/stderr are drained and re-printed by `sidecar.rs` to the desktop process's own stdout/stderr with a `[backend] ` prefix (piped → `println!`/`eprintln!`); in `--headless` mode they are inherited directly (`Stdio::inherit`). So logs are only visible when the app is launched from a terminal. No `--log` flags, no app-data log dir, no logging env vars are passed to the backend (sidecar env is only PORT/PHX_IP/PHX_SERVER/SECRET_KEY_BASE/RELEASE_DISTRIBUTION/EVOGIT_DESKTOP/EVOGIT_LIFETIME_PORT).
- Tauri v2 (not v1) — API and config schema differ significantly. Pinned in `Cargo.lock`: `tauri` 2.11.3, `tauri-build` 2.x. The `"tray-icon"` Cargo feature **is** enabled alongside `"devtools"`.
- **System tray support**: closing the window hides it to the tray (via `WindowEvent::CloseRequested` → `api.prevent_close()` + `window.hide()`). The tray menu is "Show Window", a separator, then "Quit Genesis" — the separator visually isolates the destructive Quit action to reduce accidental misclicks. Left-clicking the tray icon shows the window on Windows + macOS (no menu navigation needed). On Linux this left-click handler is a no-op (libappindicator limitation — `TrayIconEvent::Click` is never emitted, so left-click only opens the menu); the separator + topmost "Show Window" item mitigates this. "Quit Genesis" kills the backend process and exits.
- **Configurable binding address**: the backend binds to `127.0.0.1` (localhost) by default. Set `EVOGIT_BIND=0.0.0.0` before launching for remote access. The backend port is chosen by the shell at startup: an explicitly-set `PORT` env var is honored only when that port is free; otherwise a random free ephemeral port is picked (`TcpListener::bind("127.0.0.1:0")`). The chosen port is passed to the backend via `PORT`, and the WebView always connects to the same port via `localhost` regardless of bind address.
- The desktop shell contains NO Elixir code — only Rust
- **No native directory picker in Tauri**: the dashboard's Browse buttons use a picker implemented on the Elixir backend via Erlang `:wx` (`EvoDash.DirectoryPicker`, LiveView `directory_pick` event → `picker_result:<picker_id>` push — see root `CONTEXT.md` → "Native Directory Picker (wx backend)"). There is NO Tauri `pick_directory` command (`src-tauri/src/commands.rs` does not exist) and no `tauri-plugin-dialog` dependency — the Tauri dialog path is unreliable (the Windows invoke fails after picking; the macOS NSOpenPanel does not present when the app is inactive/hidden to tray).
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

Tauri launches the Phoenix app as a child process via the mix release launcher script (`bin/genesis_desktop start`). The WebView connects to Phoenix over HTTP to render the LiveView UI. Closing the window hides it to the system tray — the backend keeps running. The user fully exits via the tray's "Quit Genesis" menu item.

## Sidecar Lifecycle

1. Tauri spawns the Elixir release launcher (`bin/genesis_desktop start`) with env vars: `PORT=<shell-chosen dynamic port>`, `PHX_IP=127.0.0.1`, `PHX_SERVER=true`, `SECRET_KEY_BASE=<local>`, `RELEASE_DISTRIBUTION=none`, `EVOGIT_DESKTOP=1`, `EVOGIT_LIFETIME_PORT=<lifetime-pipe listener port>` — always via `sidecar::spawn` → `launcher_command` (Windows `CREATE_NO_WINDOW`), the only GUI spawn path (initial boot AND every watchdog restart)
2. Tauri polls `http://localhost:<PORT>` until the backend responds (up to 30s)
3. The WebView window opens, pointing to `http://localhost:<PORT>` (the window is created in Rust with `WebviewUrl::External`; there is no config-declared window). The window's initial load races the backend boot and typically fails with connection refused; once the readiness poll (step 2) succeeds, the setup re-navigates the webview to the dashboard via a bounded retry (~20 × 250ms, breaking early on quit/update intent — `navigate_after_ready` in `src-tauri/src/main.rs`). This re-navigation is required for a healthy boot: without it the webview would sit on the failed-load page for the whole session and the dashboard's `quit-requested` listener would never load, wedging the tray Quit flow (the watchdog only navigates on the crash-recovery path)
4. Closing the window hides it to the system tray (backend keeps running); the "Quit Genesis" tray menu item (below a separator) shows+focuses the window and emits `quit-requested` so the dashboard renders a web-page confirm dialog (backend-down fallback: immediate `kill_for_quit()` + exit — see "Quit Flow (Web Confirmation)")
5. **A backend crash watchdog runs for the app's lifetime** (`src-tauri/src/backend_watchdog.rs`): it monitors the child process, and on an unexpected exit shows a `data:`-URL error page in the WebView ("backend unavailable — will be restarted automatically" + Retry button), restarts the backend with capped exponential backoff (1s→30s; after 8 consecutive failures it retries every 30s indefinitely — no dead state; success resets the sequence), and once the backend serves again (TCP accepting + HTTP probe) navigates the WebView back to the dashboard (full reload). Tray Quit is the intentional shutdown path — the dashboard invokes the `begin_quit` command (sets the `intentional_shutdown` flag WITHOUT killing), the backend stops itself gracefully, and the watchdog waits up to 15s for the child exit (force-kill fallback) before `app.exit(0)`; a clean `Some(0)` child exit is also classified as intentional (deliberate `System.stop/0`), so the System-page "Stop" button exits the app instead of triggering a restart. `kill_for_quit()` (flag + kill) survives only as the backend-down fallback. Full design in `src-tauri/CONTEXT.md` → "Backend Crash Watchdog".

## Quit Flow (Web Confirmation)

The tray-quit confirmation is a **web-page dialog** rendered by the dashboard. **Design decision:** the confirmation lives in the web page rather than a native OS dialog because native dialogs are unreliable on Linux (the dialog never shows there); no dialog crate is used at all (no `rfd`, no `tauri-plugin-dialog`). Fixed protocol between Rust and the dashboard:

1. **Tray "Quit Genesis"** → Rust shows+focuses the main window (unminimize → show → set_focus, same as the "Show Window" arm and the single-instance callback), then probes backend health (`sidecar::probe_http`).
   - **Backend healthy** → Rust emits the Tauri event `quit-requested` (payload `()`) and does NOTHING else — no kill, no exit. The dashboard's `event.listen("quit-requested")` (plugin command `plugin:event|listen`) is permitted by the `remote` capability context in `capabilities/default.json` (urls `http://localhost:*` / `http://127.0.0.1:*`), which allows ACL calls from the webview's Remote origin (`http://127.0.0.1:<port>`) — see `desktop/src-tauri/CONTEXT.md` → Remote-origin design decision. There is **NO timeout-based force-quit**: with a healthy backend, tray Quit waits for the user's confirmation **indefinitely**. This is a deliberate design choice — Genesis runs long tasks and must never quit without user confirmation; if the dashboard were ever genuinely dead, the user quits via the OS/task manager instead of the app force-killing the backend.
   - **Backend already down** (webview shows the watchdog error page, so no dashboard dialog could appear) → immediate fallback: `kill_for_quit()` (sets the intentional-shutdown flag BEFORE killing) + `app.exit(0)`.
2. The dashboard's JS listens for `quit-requested` and renders a confirm modal.
3. On confirmation the dashboard JS invokes the Tauri command **`begin_quit`** (`window.__TAURI__.core.invoke("begin_quit")`) BEFORE triggering the server-side graceful `System.stop()`, so the flag is guaranteed set before the child exits. `begin_quit` is a `#[tauri::command]` (`tauri::State<'_, BackendHandle>` → `BackendManager::begin_quit()`) — sets the `intentional_shutdown` flag, kills NOTHING. Registered via `invoke_handler(tauri::generate_handler![begin_quit])`; like all app commands, it is granted through the app ACL manifest declared in `build.rs` (`tauri_build::AppManifest::commands`) plus the matching `allow-begin-quit` permission in `capabilities/default.json` — app commands invoked from a remote origin ARE ACL-checked in Tauri 2.11+, so both are required (see `src-tauri/CONTEXT.md` → Remote-origin ACL for app commands). The webview's `event.listen` is permitted by `core:default` (which includes `core:event:default`) resolved under the remote capability context — without the `remote` entry the listen is rejected (see the Remote-origin design decision).
4. The backend stops itself gracefully. The watchdog observes the intentional shutdown, waits up to 15s for the child to actually exit (force-kill fallback if the BEAM stop hangs), then `app.exit(0)` — every post-shutdown exit path of the watchdog ends with `app.exit(0)`, so the app can never linger windowed with a dead watchdog.
5. **Belt-and-braces for the IPC race**: a monitored child exit with status `Some(0)` is classified as intentional (deliberate `System.stop/0` — the only way the release backend exits code 0; crashes produce non-zero codes or signal death) → `app.exit(0)`, no restart. This also makes the System-page "Stop" button coherent in desktop mode.

Full details: `src-tauri/CONTEXT.md` → "Quit Flow (Web Confirmation)" + "Backend Crash Watchdog" point 4.

## Single-Instance Detection

**Design decision:** The GUI app prevents multiple concurrent instances via the **`tauri-plugin-single-instance` crate v2.4.3** (resolved from `"2"` in `src-tauri/Cargo.toml`; requires tauri ≥ 2.10 and Rust ≥ 1.77.2 — we use tauri 2.11.3 / Rust 1.97). Implemented in `src-tauri/src/main.rs::run_gui()`.

**Mechanism:** The plugin is registered as the **FIRST** plugin in the builder — this ordering is load-bearing. Plugins run their `setup` hooks in registration order, and the plugin's setup is what detects an existing instance and terminates the new one. On a second launch:

1. The second process's plugin setup detects the existing instance (see per-platform mechanisms below), **notifies** it (which fires the callback below on the FIRST instance), then calls `std::process::exit(0)` — the second instance never creates a window and **never reaches our `setup` closure, so it never spawns a second backend sidecar**. No extra sidecar guard is needed; do not add one (a guard would be dead code and the plugin ordering is the canonical design).
2. On the first instance, the callback runs: `app.get_webview_window("main")` → `unminimize()` → `show()` → `set_focus()`, restoring/focusing the existing window (including from the system tray, since close-to-tray just hides the window).

**Per-platform mechanisms (handled internally by the plugin):**
- **Linux**: session-bus D-Bus name ownership — `<identifier>.SingleInstance` (`com.genesis.desktop.SingleInstance`), via `zbus`. The second instance calls the first's `ExecuteCallback` D-Bus method, then exits. Requires a session bus (standard on desktop Linux). Flatpak/Snap caveat: if the Tauri identifier doesn't match the package id, use the plugin builder's `dbus_id()`; we do NOT set it (regular packaging).
- **macOS**: a Unix domain socket in `/tmp` (path derived from the bundle identifier); the second instance connects, notifies the first, and exits; the first instance listens via tokio.
- **Windows**: a named mutex (`CreateMutexW`) plus a hidden window receiving `WM_COPYDATA` (message `1542`); the second instance signals the first's hidden window, then exits.

**Caveats / known limits:**
- **Simultaneous-launch race**: two instances launched at (nearly) the same instant can both pass the check on macOS (socket not yet bound) and, in theory, Linux (D-Bus name acquisition is atomic so Linux is safe; Windows mutex is atomic too). The macOS race window is small and inherent to the plugin — not mitigated, but harmless: with dynamic ports each instance's backend gets a different port, so there is no port-conflict crash (both windows simply appear).
- **macOS focus nuance**: `set_focus()` makes the window key but may not bring the app to the foreground if the app is inactive (no `activate` API in tauri 2.11.3). In practice the second launch typically activates the app via LaunchServices first, so restore+focus works; if focus regressions are reported, evaluate `NSApplication activate` via objc2 in the callback.
- **`--headless` mode is NOT covered**: `run_headless()` bypasses the Tauri builder entirely (no plugin, no window, no watchdog). Each headless instance picks its own free port, so concurrent instances never collide; shell-death detection does apply: `headless_sidecar_env` sets `EVOGIT_DESKTOP=1` + `EVOGIT_LIFETIME_PORT`, so a headless backend self-exits instantly (lifetime-pipe recv error) when its parent shell dies (including SIGKILL orphans). This is a dev/debug utility and remains deliberately out of scope.
- The callback may fire while the first instance's `setup` is still blocked polling the backend (up to 30s) — the callback runs off the main thread (D-Bus thread / message-loop thread / tokio task), so it is queued and applied once the window exists; window calls are thread-safe in Tauri.

**Build note:** `cargo check` in `src-tauri` requires `resources/genesis-backend/` to exist (tauri-build validates `bundle.resources` paths at compile time). The dir is gitignored (root `.gitignore`) — create it locally with `mkdir -p desktop/src-tauri/resources/genesis-backend` before building/checking. Also note the host shell may lack glib/gtk dev files (pkg-config `glib-2.0` not found); use the repo's `nix develop` devShell for desktop Rust builds.

**Verification status:** `cargo check` passes (in `nix develop`, zero errors). Runtime single-instance behavior (second launch focuses existing window + exits without second backend) requires manual per-platform verification on Linux/macOS/Windows — not covered by CI.

## Regenerating Icons

The Tauri icon set (`src-tauri/icons/`: `icon.png`, `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`) is generated from the EVOX brand logo. Source SVGs (sibling app, read-only): `apps/evo_dash/priv/static/images/logo.svg` (dark gray `#373435` + red `#C8383C`, light variant — the one used) and `logo-alt.svg` (white + red, dark variant — reserved for a possible dark-tray icon). Transparent background.

**Gotcha**: both SVGs have a large viewBox (`16002.59 x 12975.69`) with the artwork filling it edge-to-edge — render high-res, then trim/fit to ~86% of a square 1024x1024 transparent canvas, then run `npx --yes @tauri-apps/cli@^2 icon <square-1024.png>` (or `cargo tauri icon <square-1024.png>`).

tauri-cli is NOT in nixpkgs (npm route used; `cargo install tauri-cli --version "^2.0"` also works). Delete the generator's extra outputs (`64x64.png`, `128x128@2x.png`, `Square*.png`, `StoreLogo.png`, `android/`, `ios/`) — nothing references them; `bundle.icon` lists only the 4 files above and the tray uses `app.default_window_icon()`. Full recipe (incl. render commands): `src-tauri/CONTEXT.md` → Regenerating Icons.

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

## Known Issues

- **NSIS installer shortcut name is hardcoded to `productName` — no config option exists (pinned tauri-bundler 2.9.4 / tauri-cli 2.11.4, the latest stable; CI pins `TAURI_CLI_VERSION=2.11.4` in `.github/workflows/build-desktop.yml`).** The Windows NSIS installer names both the Desktop and Start Menu shortcuts `${PRODUCTNAME}.lnk` from `tauri.conf.json` `productName`. `NsisConfig`/`NsisSettings` expose NO shortcut-name key — only `startMenuFolder` (Start Menu folder), `installMode`, `installerHooks`, `template`, icons, etc. The MSI (WiX) bundle names shortcuts `{{product_name}}` too, and the installer file is `{productName}_{version}_{arch}-setup.exe`. No released tauri version has a shortcut-name option (upstream feature request tauri#13999 covers installer *file* names only). To control the shortcut name you must either change `productName` (side effects: app display name, install dir `%ProgramFiles%\EvoX Genesis`, uninstaller DisplayName, MSI+NSIS shortcut names, installer filename) or use a custom NSIS template / `installerHooks` (`NSIS_HOOK_POSTINSTALL`) that creates/renames shortcuts. `mainBinaryName` only names the .exe — it does NOT influence shortcut names. **Current state:** `productName` is `"EvoX Genesis"` — the user-facing display name — so the NSIS Desktop/Start Menu shortcuts are `EvoX Genesis.lnk` and the installer file is `EvoX Genesis_<version>_x64-setup.exe` (Windows x86_64 builds). The built executable is explicitly pinned via `"mainBinaryName": "genesis-desktop"` in `tauri.conf.json` (deliberate, conservative decision): with no `mainBinaryName` set, tauri-cli 2.11.4 keeps the Cargo `[[bin]]` name `genesis-desktop`, but pinning it explicitly guarantees the executable keeps the stable space-free name `genesis-desktop` regardless of productName defaults or future tauri behavior changes — so all binary-derived artifacts (exe name, deb/rpm package names, sidecar launcher resolution) are unaffected. Note: `mix bump.version` syncs only the `version` field of `tauri.conf.json`; `productName` and `mainBinaryName` are static literals.
- **Windows console window on backend launch — don't regress**: On Windows the backend launcher is `genesis_desktop.bat`. `CreateProcess` cannot run a `.bat` directly, so Rust std retries through `cmd.exe /c <bat>`. Because the Tauri app is a GUI-subsystem process (`#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]` in `src-tauri/src/main.rs`) with no console, that `cmd.exe` gets a brand-new **visible** console window persisting for the backend's lifetime — closing it kills the backend. The shared `launcher_command/1` helper in `src-tauri/src/sidecar.rs` prevents this by applying the `CREATE_NO_WINDOW` creation flag (`0x08000000`) through `std::os::windows::process::CommandExt::creation_flags` under `#[cfg(windows)]`. Both spawn sites use it: GUI mode (`sidecar::start`) and `--headless` mode (`main.rs::run_headless`). **Never spawn the launcher with a plain `Command::new` on Windows** or the console-window bug regresses. git/ripgrep/erl.exe spawned inside the Elixir backend inherit the hidden console — no action needed.
- **Linux x64 AppImage bundling requires the wxWidgets 3.2 runtime on the build runner**: the `genesis_desktop` release includes OTP's `wx` app (`wx: :load` in root `mix.exs` — the wx-based directory picker), and its NIFs link against wxWidgets 3.2 sonames that are not installed by default. linuxdeploy hard-fails on the first unresolvable NEEDED entry, and tauri-bundler 2.9.4 suppresses linuxdeploy's stderr (only the generic "failed to run linuxdeploy" surfaces in CI); deb/rpm pass because those bundlers don't resolve ELF dependencies.
  **Mitigation (workflow change in `.github/workflows/build-desktop.yml` — root scope, NOT this subtree)**: the Linux runners are ubuntu-24.04 (x64 / arm64), where wxWidgets 3.2.4 ships in the default Ubuntu repos. The `build-linux` job's x64 target installs the wxWidgets 3.2 runtime + `libglu1-mesa` before `tauri build` (step "Install wxWidgets 3.2 runtime (AppImage bundling)", gated `matrix.arch == 'x64'`; the arm64 job bundles no AppImage — appimagetool/linuxdeploy are x86_64-only) via plain `apt-get install` of `libwxbase3.2-1t64 libwxgtk3.2-1t64 libwxgtk-gl3.2-1t64 libwxgtk-webview3.2-1t64 libglu1-mesa` straight from the default Ubuntu repos. linuxdeploy then bundles the wxWidgets closure INTO the AppImage (self-contained picker). The ubuntu-24.04 glibc requirement is accepted; a musl build is a planned future improvement. The full diagnosis and local repro method are in `desktop/src-tauri/CONTEXT.md` → Known Issues — don't re-investigate from scratch.
