# Desktop Shell (Tauri)

## Intent

The Tauri desktop shell provides a native OS WebView window for the Genesis Phoenix dashboard. It launches the standard Elixir release backend (`genesis_desktop`) as a child process, waits for it to be ready, then opens a WebView pointing to `http://localhost:9999`.

This is the native application layer — it contains NO Elixir code. The actual application logic lives in `./apps/evo_dash/` (Phoenix backend) and `./apps/evo_git/` (core runtime).

## Routing Table

- `./src-tauri/` → Tauri project (Rust source, Cargo.toml, tauri.conf.json)
- `./scripts/docker-dev/` → Dev/test-only Docker image from umbrella source (`mix release genesis` + `bin/genesis start`); see `scripts/docker-dev/README.md`

## API Surface

| File | Purpose |
|------|---------|
| `src-tauri/src/main.rs` | Rust entry point — initializes Tauri, builds system tray (Show Window / Quit menu), spawns backend, opens window, intercepts close-to-tray |
| `src-tauri/src/sidecar.rs` | Backend lifecycle: env config (PHX_IP bind address, PORT), spawn release launcher process, health-check polling, shutdown |
| `src-tauri/Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-single-instance, reqwest) |
| `src-tauri/tauri.conf.json` | Tauri config: window settings, trayIcon config, resource bundle reference, bundle metadata |
| `src-tauri/capabilities/default.json` | Tauri v2 permissions: shell (release launcher) |
| `src-tauri/resources/genesis-backend/` | Placeholder directory where the built Elixir release (`_build/prod/rel/genesis_desktop/`) is placed before `cargo tauri build` |

## Constraints

- **No log files — console only**: Neither the Rust shell nor the sidecar writes any log file. The Elixir backend's stdout/stderr are drained and re-printed by `sidecar.rs` to the desktop process's own stdout/stderr with a `[backend] ` prefix (piped → `println!`/`eprintln!`); in `--headless` mode they are inherited directly (`Stdio::inherit`). So logs are only visible when the app is launched from a terminal. No `--log` flags, no app-data log dir, no logging env vars are passed to the backend (sidecar env is only PORT/PHX_IP/PHX_SERVER/SECRET_KEY_BASE/RELEASE_DISTRIBUTION/EVOGIT_DESKTOP).
- Tauri v2 (not v1) — API and config schema differ significantly. Pinned in `Cargo.lock`: `tauri` 2.11.3, `tauri-build` 2.x. The `"tray-icon"` Cargo feature **is** enabled alongside `"devtools"`.
- **System tray support**: closing the window hides it to the tray (via `WindowEvent::CloseRequested` → `api.prevent_close()` + `window.hide()`). The tray icon has "Show Window" and "Quit" menu items; left-clicking the tray icon also shows the window. "Quit" kills the backend process and exits.
- **Configurable binding address**: the backend binds to `127.0.0.1` (localhost) by default. Set `EVOGIT_BIND=0.0.0.0` before launching for remote access. The `PORT` env var (default 9999) controls the backend port. The WebView always connects via `localhost` regardless of bind address.
- The desktop shell contains NO Elixir code — only Rust
- **No native directory picker in Tauri**: the dashboard's Browse buttons use a picker implemented on the Elixir backend via Erlang `:wx` (`EvoDash.DirectoryPicker`, LiveView `directory_pick` event → `picker_result:<picker_id>` push — see root `CONTEXT.md` → "Native Directory Picker (wx backend)"). The former Tauri `pick_directory` command (`src-tauri/src/commands.rs`) and the `tauri-plugin-dialog` dependency were **removed** — they were unstable (Windows invoke failed after picking; macOS NSOpenPanel never presented when the app was inactive/hidden to tray).
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

## Single-Instance Detection

**Design decision:** The GUI app prevents multiple concurrent instances via the **`tauri-plugin-single-instance` crate v2.4.3** (resolved from `"2"` in `src-tauri/Cargo.toml`; requires tauri ≥ 2.10 and Rust ≥ 1.77.2 — we use tauri 2.11.3 / Rust 1.97). Implemented in `src-tauri/src/main.rs::run_gui()`, commit `5d3e5368`.

**Mechanism:** The plugin is registered as the **FIRST** plugin in the builder — this ordering is load-bearing. Plugins run their `setup` hooks in registration order, and the plugin's setup is what detects an existing instance and terminates the new one. On a second launch:

1. The second process's plugin setup detects the existing instance (see per-platform mechanisms below), **notifies** it (which fires the callback below on the FIRST instance), then calls `std::process::exit(0)` — the second instance never creates a window and **never reaches our `setup` closure, so it never spawns a second backend sidecar**. No extra sidecar guard is needed; do not add one (a guard would be dead code and the plugin ordering is the canonical design).
2. On the first instance, the callback runs: `app.get_webview_window("main")` → `unminimize()` → `show()` → `set_focus()`, restoring/focusing the existing window (including from the system tray, since close-to-tray just hides the window).

**Per-platform mechanisms (handled internally by the plugin):**
- **Linux**: session-bus D-Bus name ownership — `<identifier>.SingleInstance` (`com.genesis.desktop.SingleInstance`), via `zbus`. The second instance calls the first's `ExecuteCallback` D-Bus method, then exits. Requires a session bus (standard on desktop Linux). Flatpak/Snap caveat: if the Tauri identifier doesn't match the package id, use the plugin builder's `dbus_id()`; we do NOT set it (regular packaging).
- **macOS**: a Unix domain socket in `/tmp` (path derived from the bundle identifier); the second instance connects, notifies the first, and exits; the first instance listens via tokio.
- **Windows**: a named mutex (`CreateMutexW`) plus a hidden window receiving `WM_COPYDATA` (message `1542`); the second instance signals the first's hidden window, then exits.

**Caveats / known limits:**
- **Simultaneous-launch race**: two instances launched at (nearly) the same instant can both pass the check on macOS (socket not yet bound) and, in theory, Linux (D-Bus name acquisition is atomic so Linux is safe; Windows mutex is atomic too). The macOS race window is small and pre-existing plugin behavior — not mitigated.
- **macOS focus nuance**: `set_focus()` makes the window key but may not bring the app to the foreground if the app is inactive (no `activate` API in tauri 2.11.3). In practice the second launch typically activates the app via LaunchServices first, so restore+focus works; if focus regressions are reported, evaluate `NSApplication activate` via objc2 in the callback.
- **`--headless` mode is NOT covered**: `run_headless()` bypasses the Tauri builder entirely (no plugin, no window). Two headless instances would collide on backend port 9999; this is a dev/debug utility and is deliberately out of scope.
- The callback may fire while the first instance's `setup` is still blocked polling the backend (up to 30s) — the callback runs off the main thread (D-Bus thread / message-loop thread / tokio task), so it is queued and applied once the window exists; window calls are thread-safe in Tauri.

**Build note:** `cargo check` in `src-tauri` requires `resources/genesis-backend/` to exist (tauri-build validates `bundle.resources` paths at compile time). The dir is gitignored (root `.gitignore` line 51, placeholder removed from git in `c8b6195c` for the nix build) — create it locally with `mkdir -p desktop/src-tauri/resources/genesis-backend` before building/checking. Also note the host shell may lack glib/gtk dev files (pkg-config `glib-2.0` not found); use the repo's `nix develop` devShell for desktop Rust builds.

**Verification status:** `cargo check` passes (in `nix develop`, zero errors). Runtime single-instance behavior (second launch focuses existing window + exits without second backend) requires manual per-platform verification on Linux/macOS/Windows — not covered by CI.

## Regenerating Icons

The Tauri icon set (`src-tauri/icons/`: `icon.png`, `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`) is generated from the EVOX brand logo. Source SVGs (sibling app, read-only): `apps/evo_dash/priv/static/images/logo.svg` (dark gray `#373435` + red `#C8383C`, light variant — the one used) and `logo-alt.svg` (white + red, dark variant — reserved for a possible dark-tray icon). Transparent background, matching the old placeholder set's style.

**Gotcha**: both SVGs have a large viewBox (`16002.59 x 12975.69` as of the logo update commit `08ad3110`; was `98668.67 x 73192.18` before) with the artwork filling it edge-to-edge — render high-res, then trim/fit to ~86% of a square 1024x1024 transparent canvas, then:

```bash
npx --yes @tauri-apps/cli@^2 icon <square-1024.png>   # or: cargo tauri icon <square-1024.png>
```

tauri-cli is NOT in nixpkgs (npm route used; `cargo install tauri-cli --version "^2.0"` also works). Delete the generator's extra outputs (`64x64.png`, `128x128@2x.png`, `Square*.png`, `StoreLogo.png`, `android/`, `ios/`) — nothing references them; `bundle.icon` lists only the 4 files above and the tray uses `app.default_window_icon()`. Full recipe (incl. render commands): `src-tauri/CONTEXT.md` → Regenerating Icons. Regenerated from the EVOX logo in commit `bacf702c` (was stale from the placeholder era) and again from the updated logo in commit `4c13ed4b` (was stale from the old logo).

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

- **NSIS installer shortcut name is hardcoded to `productName` — no config option exists (pinned tauri-bundler 2.9.4 / tauri-cli 2.11.4, the latest stable; CI pins `TAURI_CLI_VERSION=2.11.4` in `.github/workflows/build-desktop.yml`).** The Windows NSIS installer names both the Desktop and Start Menu shortcuts `${PRODUCTNAME}.lnk`, e.g. `CreateShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"` and `CreateShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" ...` (tauri-bundler `src/bundle/windows/nsis/installer.nsi` lines ~946-976). `PRODUCTNAME` is `{{product_name}}`, injected from `tauri.conf.json` `productName` (nsis/mod.rs:295). `NsisConfig`/`NsisSettings` expose NO shortcut-name key — only `startMenuFolder` (Start Menu folder), `installMode`, `installerHooks`, `template`, icons, etc. The MSI (WiX) bundle names shortcuts `{{product_name}}` too (main.wxs), and the installer file is `{productName}_{version}_{arch}-setup.exe`. No released tauri version has a shortcut-name option (2.9.4 is latest stable; dev changelog has none; upstream feature request tauri#13999 covers installer *file* names only). To control the shortcut name you must either change `productName` (side effects: app display name, install dir `%ProgramFiles%\EvoX Genesis`, uninstaller DisplayName, MSI+NSIS shortcut names, installer filename) or use a custom NSIS template / `installerHooks` (`NSIS_HOOK_POSTINSTALL`) that creates/renames shortcuts. `mainBinaryName` (defaults to Cargo `[[bin]]` name `genesis-desktop`) only names the .exe — it does NOT influence shortcut names. **Current state:** `productName` is `"EvoX Genesis"` — the user-facing display name — so the NSIS Desktop/Start Menu shortcuts are `EvoX Genesis.lnk` and the installer file is `EvoX Genesis_0.9.3_x64-setup.exe` (Windows x86_64 builds). The built executable is explicitly pinned via `"mainBinaryName": "genesis-desktop"` in `tauri.conf.json` (deliberate, conservative decision): with no `mainBinaryName` set, tauri-cli 2.11.4 keeps the Cargo `[[bin]]` name `genesis-desktop` (verified in tauri-cli `src/interface/mod.rs:64-66` — the binary is only renamed when `config.main_binary_name` is present), but pinning it explicitly guarantees the executable keeps the stable space-free name `genesis-desktop` regardless of productName defaults or future tauri behavior changes — so all binary-derived artifacts (exe name, deb/rpm package names, sidecar launcher resolution) are unaffected. Note: `mix bump.version` syncs only the `version` field of `tauri.conf.json`; `productName` and `mainBinaryName` are static literals.
- **Windows console window on backend launch (fixed — don't regress)**: On Windows the backend launcher is `genesis_desktop.bat`. `CreateProcess` cannot run a `.bat` directly, so Rust std retries through `cmd.exe /c <bat>`. Because the Tauri app is a GUI-subsystem process (`#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]` in `src-tauri/src/main.rs`) with no console, that `cmd.exe` gets a brand-new **visible** console window persisting for the backend's lifetime — closing it kills the backend. Fixed in `src-tauri/src/sidecar.rs` via the shared `launcher_command/1` helper, which applies the `CREATE_NO_WINDOW` creation flag (`0x08000000`) through `std::os::windows::process::CommandExt::creation_flags` under `#[cfg(windows)]`. Both spawn sites use it: GUI mode (`sidecar::start`) and `--headless` mode (`main.rs::run_headless`). **Never spawn the launcher with a plain `Command::new` on Windows** or the console-window bug regresses. git/ripgrep/erl.exe spawned inside the Elixir backend inherit the (now hidden) console — no action needed.
- **Linux x64 AppImage bundling failed at v0.9.5 — wxWidgets 3.2 deps unresolvable on the ubuntu-22.04 runner (fixed in the CI workflow; fix moved to ubuntu-24.04 as of 2026-08-10)**: The v0.9.5 Linux x64 AppImage bundle failed with tauri-bundler's generic `failed to run linuxdeploy` (deb/rpm/tarball succeeded; v0.9.4 passed end-to-end with the same workflow/CLI/tauri.conf.json). Root cause: the `genesis_desktop` release gained OTP's `wx` app (`wx: :load` in root `mix.exs`, commit f4ab8077 — the wx-based directory picker); the release NIFs `lib/wx-*/priv/wxe_driver.so` (NEEDED 8× `libwx_gtk3u_*-3.2.so.0` / `libwx_baseu-3.2.so.0`) and `erl_gl.so` (NEEDED `libGLU.so.1`) are unresolvable on the **ubuntu-22.04** runner — jammy ships only wxWidgets 3.0, and the runner was deliberately pinned to 22.04 (commit 788273c7, lower glibc requirement). That do-not-bump decision WAS revisited on 2026-08-10: the runner is now ubuntu-24.04, with glibc support deferred to a planned musl build. linuxdeploy hard-fails on the first unresolvable NEEDED entry with `ERROR: Could not find dependency: libwx_gtk3u_stc-3.2.so.0` / `ERROR: Failed to deploy dependencies for existing files`, and tauri-bundler 2.9.4 suppresses linuxdeploy's stderr (only the generic "failed to run linuxdeploy" surfaces in CI); deb/rpm pass because those bundlers don't resolve ELF dependencies.
  **Fix (workflow change; PPA prescription SUPERSEDED 2026-08-10)**: the `build-linux` job installs wxWidgets 3.2 + `libglu1-mesa` on the x64 runner before `tauri build` (step "Install wxWidgets 3.2 runtime (AppImage bundling)", gated `matrix.arch == 'x64'`) — linuxdeploy then bundles the wxWidgets closure INTO the AppImage (self-contained picker). The original fix used the `ppa:wxformbuilder/wxwidgets3.2` PPA, but that PPA is DEAD — `sudo add-apt-repository -y ppa:wxformbuilder/wxwidgets3.2` fails with `ERROR: ppa 'wxformbuilder/wxwidgets3.2' not found` (launchpad HTTP 404; the wxformbuilder/wxwidgets PPA only hosts ancient precise/quantal/raring/saucy builds — no jammy). As of 2026-08-10 the runners are ubuntu-24.04 (x64) / ubuntu-24.04-arm, where wxWidgets 3.2.4 ships in the default Ubuntu repos, so the step does a plain `apt-get install` of `libwxbase3.2-1t64 libwxgtk3.2-1t64 libwxgtk-gl3.2-1t64 libwxgtk-webview3.2-1t64 libglu1-mesa` — no PPA. The full diagnostic trail, the exact workflow snippet, and the local repro method (incl. the NixOS binfmt/bwrap AppImage-exec quirk and the hsqs-offset extraction workaround) are in `desktop/src-tauri/CONTEXT.md` → Known Issues — don't re-investigate from scratch. As of 2026-08-10 the workflow uses ubuntu-24.04 / ubuntu-24.04-arm again (root `CONTEXT.md` reflects this) — see `desktop/src-tauri/CONTEXT.md` → Known Issues → Resolution (2026-08-10).
