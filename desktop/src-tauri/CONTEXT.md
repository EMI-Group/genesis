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
| `src/main.rs` | Rust entry point — initializes Tauri, builds system tray (Show Window / Quit menu), spawns the Elixir release, opens window, intercepts close-to-tray, starts the backend watchdog |
| `src/sidecar.rs` | Sidecar lifecycle: env config (PHX_IP bind address, PORT), shared `spawn(launcher, env)` (the ONLY GUI launcher spawn path, always via `launcher_command`), one-shot `probe_http`, readiness polling, shutdown |
| `src/backend_watchdog.rs` | Backend crash watchdog: monitors the child process, restarts it with backoff on unexpected exit, shows an error page in the WebView while down, reloads the dashboard on recovery (`RestartPolicy`, `classify_exit`, `tcp_accepting`, `percent_encode`/`error_page_data_url`, `BackendManager`) |
| `src/sidecar_path.rs` | Shared launcher-path resolution (`resolve_launcher/2`) — first existing candidate wins, descriptive error listing all candidates when none exist; used by both GUI (`sidecar.rs`) and headless (`main.rs`) modes; contains the unit tests |
| `Cargo.toml` | Rust dependencies (tauri v2 with `devtools` + `tray-icon` features, tauri-plugin-shell, tauri-plugin-single-instance, reqwest) |
| `tauri.conf.json` | Tauri config: window settings, trayIcon config, release resource reference, bundle metadata |
| `capabilities/default.json` | Tauri v2 permissions: shell (release launcher). No tray permission needed — tray managed from Rust. |
| `icons/icon.png` | 512x512 RGBA EVOX-brand icon (transparent background) — derived from `apps/evo_dash/priv/static/images/logo.svg`; kept as the standard source icon, not referenced by `bundle.icon` (which lists only `32x32.png`, `128x128.png`, `icon.icns`, `icon.ico`) |

## Constraints

- Tauri v2 — API differs significantly from v1 (tray builder, menu, window events all changed).
- The `tray-icon` Cargo feature must be enabled for system tray support.
- `capabilities/default.json` does NOT need a tray permission — tray icons are managed from Rust, not the frontend JS API.
- The Elixir release directory (`resources/genesis-backend/`) — a standard `mix release` tree — must be placed in `src-tauri/resources/genesis-backend/` before `cargo tauri build`. Tauri bundles it as a resource.
- **Launcher path resolution is shared between GUI and headless modes**: `src/sidecar_path.rs` `resolve_launcher/2` is a pure function that takes candidate base dirs + launcher name, returns the first candidate that `exists()`, or a descriptive error listing all candidates. GUI mode (`src/sidecar.rs` `launcher_path`) passes `[exe_dir, resource_dir, manifest_dir]`; headless mode (`src/main.rs` `resolve_sidecar_path`) passes `[exe_dir, manifest_dir]`. Never add a divergent resolution strategy in one mode without updating the shared module — keep both callers on `resolve_launcher`.
- The desktop shell contains NO Elixir code — only Rust.
- The release is launched via its `bin/genesis_desktop` launcher script (`bin/genesis_desktop.bat` on Windows) with the `start` command, which is a **foreground** process (blocks until the BEAM VM exits). This gives the Rust parent clean ownership/kill semantics.

## Backend Crash Watchdog

**Design (commit `fd3e5871`):** the GUI mode (`run_gui`) wraps the backend child in a `BackendManager` (managed via `app.manage` as `Arc<BackendManager>`, shared with a dedicated `std::thread` watchdog started in the Tauri setup — the manager is Arc-wrapped so the `'static` thread can own it; the design note "watchdog takes an AppHandle clone" is satisfied too). The watchdog:

1. **Monitors** the current child via `try_wait` (reaps zombies) until it exits; a missing child (failed initial spawn) counts as a failure.
2. **On unexpected exit**: `RestartPolicy::record_failure` + `next_backoff` (sequence 1s, 2s, 4s, 8s, 16s, 30s, capped at 30s; after `MAX_CONSECUTIVE_FAILURES = 8` consecutive failures it keeps retrying every 30s **indefinitely** — deliberately no give-up state; `record_success` resets counter + index), navigate the WebView to a `data:` error page ("Genesis backend unavailable — it will be restarted automatically" + a "Retry now" button whose inline JS does `window.location.href = '<backend_url>'` — top-level navigation, no Tauri IPC, degrades to static text without JS; built with the pure `percent_encode` helper, unit-tested), interruptible sleep, respawn via the shared `sidecar::spawn`, re-check the quit flag (kill fresh child + stop if quit raced the spawn).
3. **Recovery gating**: `wait_until_ready` requires ALL of — child still alive, `tcp_accepting(port)` (std `TcpStream::connect_timeout`, polled), and `sidecar::probe_http` success (one-shot HTTP probe) — within 30s; then `record_success` + `window.navigate(backend_url)` (a full reload — never `eval("location.reload()")`). Ready-timeout (child alive but never serving) → kill child → next failure cycle. `show_backend` retries the navigation until the window accepts it (the window only exists after Tauri's setup completes), so a recovery during the initial 30s boot poll still reloads the dashboard once the window appears.
4. **Crash-vs-intentional**: the ONLY intentional kill path is the tray Quit → `BackendManager::kill_for_quit()` which sets the `intentional_shutdown` `AtomicBool` BEFORE taking+killing the child; the watchdog checks the flag at every stage (monitor, sleep, pre/post-spawn, readiness loop) and returns without ever restarting after a quit began (double-kill guard: killing an already-exited/taken child is a no-op, restarting after quit is not). `classify_exit(intentional, status)` is the pure unit-tested classifier (`Unexpected(Option<i32>)` | `Intentional`).

**Boot flow**: setup resolves the launcher path once (missing launcher stays FATAL — broken install), builds env via `sidecar::sidecar_env()` (now honors `PORT` env like headless mode so backend/WebView/watchdog agree), creates the manager, spawns the initial child (spawn error NON-fatal — watchdog treats the missing child as a failure), starts the watchdog thread, keeps the existing blocking 30s readiness poll, then if the boot never became ready kills the child (final `probe_http` check avoids killing a backend that became ready right at the timeout) so the watchdog takes over with the error page + restart cycle. `--headless` mode is UNCHANGED (no watchdog; exits when the sidecar exits).

**Spawn-path invariant**: GUI initial boot AND every watchdog restart go through `sidecar::spawn` → `launcher_command` (Windows `CREATE_NO_WINDOW`); headless keeps its own `launcher_command` call. Never introduce a plain `Command::new` launcher spawn. No new Cargo deps were added (std net/thread + `tauri::Url` re-export only).

## System Tray Behavior

- **Close window** → `WindowEvent::CloseRequested` is intercepted (`api.prevent_close()` + `window.hide()`); the window is hidden to the tray and the backend keeps running.
- **Tray menu "Show Window"** → `window.show()` + `window.set_focus()`
- **Tray menu "Quit"** → `BackendManager::kill_for_quit()` (sets the `intentional_shutdown` flag BEFORE taking and killing the child, so the backend watchdog never restarts after a quit began — double-kill guard), then `app.exit(0)`
- **Left-click tray icon** → shows and focuses the main window via `.on_tray_icon_event` (matches `Click { Left, Up }`) combined with `.show_menu_on_left_click(false)`. The flag is required on macOS: with a menu attached, the default left-click opens the menu on mouse-down and swallows the `Click(Left, Up)` event, so the window never pops; with the flag set, left-click emits the event (menu stays on right-click).

## Native Directory Picker — REMOVED (moved to the Elixir backend)

The Tauri-based native directory picker has been **removed** from the desktop shell. The dashboard's Browse buttons now use a native picker implemented **on the Elixir backend with Erlang's `:wx`**: the JS `DirectoryPicker` hook pushes a `"directory_pick"` LiveView event → `ProjectsLive` (local node only) → `EvoDash.DirectoryPicker` (a GenServer in `apps/evo_dash` that serializes wx dialog usage) runs `wxDirDialog` → the result is pushed back to the client as `picker_result:<picker_id>`. See root `CONTEXT.md` → "Native Directory Picker (wx backend)" for the full flow.

**Removed in this change:**

- `src/commands.rs` — the `pick_directory` command, including the macOS `NSOpenPanel` objc2 module (which itself replaced the earlier rfd-based attempt from commit `4f0f6ee8`).
- `tauri-plugin-dialog` — Cargo dependency, plugin init + `invoke_handler` registration in `src/main.rs`, and the `dialog:allow-open` / `dialog:default` permissions in `capabilities/default.json`.
- macOS-only direct deps `objc2` + `objc2-app-kit` in `Cargo.toml` (were used only by `commands.rs`; they remain in `Cargo.lock` only as transitive deps of other crates).

**Why:** the Tauri dialog path was unstable — the Windows invoke failed after picking, and on macOS the NSOpenPanel (both the plugin's sheet and rfd's app-modal fallback) never presented when the app was inactive / the window hidden to the tray. The wx-based backend picker supersedes it. The detailed macOS/Windows picker diagnosis previously documented here is preserved in git history.

**Build gotcha:** tauri-build validates `bundle.resources` paths at compile time — `resources/genesis-backend/` must exist before `cargo check`/`cargo tauri build` (error: `resource path 'resources/genesis-backend' doesn't exist`). Create it locally with `mkdir -p resources/genesis-backend`; it is deliberately untracked in git (the Nix flake derivation symlinks a built release there in a preBuild hook — see root CONTEXT.md Known Issue).

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

## Known Issues

### AppImage bundling on Linux CI — wxWidgets deps missing on the ubuntu-22.04 runner (v0.9.5, run 31345884332)

The v0.9.5 Linux x64 CI AppImage bundle failed with tauri-bundler's generic `failed to run linuxdeploy` (deb/rpm/tarball passed; v0.9.4 passed end-to-end with the same workflow/CLI/tauri.conf.json). Root cause, reproduced locally:

- The `genesis_desktop` release gained OTP's `wx` app (`wx: :load` in root `mix.exs`, commit f4ab8077 — wx-based directory picker). Its NIFs under `resources/genesis-backend/lib/wx-*/priv/`:
  - `wxe_driver.so` — NEEDED `libwx_gtk3u_stc-3.2.so.0`, `libwx_gtk3u_xrc-3.2.so.0`, `libwx_gtk3u_html-3.2.so.0`, `libwx_gtk3u_core-3.2.so.0`, `libwx_baseu-3.2.so.0`, `libwx_gtk3u_gl-3.2.so.0`, `libwx_gtk3u_aui-3.2.so.0`, `libwx_gtk3u_webview-3.2.so.0` (+ stdc++/gcc_s/c)
  - `erl_gl.so` — NEEDED `libGLU.so.1` (+ stdc++/gcc_s/c)
- The Linux x64 CI runner is **ubuntu-22.04** (deliberate: commit 788273c7 "Use ubuntu22.04 to lower glibc requirement" — do NOT bump the runner without revisiting that decision). **This decision WAS revisited on 2026-08-10 (per the user's explicit decision) and the runners were bumped to ubuntu-24.04; the glibc concern is deferred to a planned future musl build.** jammy official repos have only wxWidgets 3.0 (soname-incompatible, not installed anyway); `libwx_gtk3u_core-3.2.so.0` resolves to **no package** in jammy (verified via packages.ubuntu.com content search; noble provides it as `libwxgtk3.2-1t64`).
- linuxdeploy (1-alpha 659c9db, the pinned build) resolves every NEEDED entry of every ELF in the AppDir during dependency deployment. The first unresolvable soname aborts the run:
  ```
  ERROR: Could not find dependency: libwx_gtk3u_stc-3.2.so.0
  ERROR: Failed to deploy dependencies for existing files
  ```
  Exact text reproduced locally by running the real linuxdeploy on a minimal AppDir with a copy of `wxe_driver.so` whose RUNPATH was nuked (simulating the runner). With wxWidgets resolvable (the local NixOS store happens to have it), linuxdeploy deploys the full closure fine — which is why local runs pass the wx phase. Quick triage for any future wx-related bundle failure: `readelf -d _build/prod/rel/genesis_desktop/lib/wx-*/priv/*.so | grep NEEDED`.
- **Fix (workflow — root scope, NOT this subtree)**: install wxWidgets 3.2 (`ppa:wxformbuilder/wxwidgets3.2` on jammy) + `libglu1-mesa` on the Linux **x64** runner before `tauri build` (arm64 job bundles no AppImage). This both fixes the build and makes the AppImage self-contained for the wx picker (linuxdeploy bundles the wxWidgets closure into `usr/lib/`). The exact snippet is recorded in the root agent's final report for the v0.9.5 AppImage incident; verify the PPA package name (`-t64` vs not) with `apt-cache search libwxgtk3.2` on the runner. **SUPERSEDED (2026-08-10)**: the `ppa:wxformbuilder/wxwidgets3.2` PPA no longer exists — `sudo add-apt-repository -y ppa:wxformbuilder/wxwidgets3.2` fails in CI with `ERROR: ppa 'wxformbuilder/wxwidgets3.2' not found` (launchpad 404; that PPA only ever hosted ancient precise/quantal/raring/saucy builds, no jammy). As of 2026-08-10 the Linux CI runners are **ubuntu-24.04**, where wxWidgets 3.2 (3.2.4) ships in the **default Ubuntu repos** (`libwxbase3.2-1t64`, `libwxgtk3.2-1t64`, `libwxgtk-gl3.2-1t64`, `libwxgtk-webview3.2-1t64`) — the CI step now does a plain `apt-get install` of those `-t64` runtime packages (+ `libglu1-mesa`), **no PPA**. The `-t64` vs non-`-t64` package-name check remains valid for verifying package availability on a given Ubuntu release.
- **Resolution (2026-08-10)**: the Linux CI runners were migrated from ubuntu-22.04 → **ubuntu-24.04** (x64 and arm64, in `.github/workflows/build-desktop.yml`), and the CI wxWidgets step now plain-apt-installs the wx 3.2 runtime from **Ubuntu's default repos** (noble ships `libwxbase3.2-1t64`, `libwxgtk3.2-1t64`, `libwxgtk-gl3.2-1t64`, `libwxgtk-webview3.2-1t64` — 3.2.4 — plus `libglu1-mesa`); **no PPA**. The broken `ppa:wxformbuilder/wxwidgets3.2` reference was removed from the workflow. The glibc-motivated runner pin (commit 788273c7) was revisited per the user's explicit decision, with the glibc concern deferred to a planned future musl build. The historical incident record above remains accurate triage knowledge for wx-related AppImage failures.

### linuxdeploy / AppImage debugging gotchas (agents)

- **tauri-bundler suppresses linuxdeploy's stderr** (source: `.../tauri-bundler-2.9.4/src/bundle/linux/appimage/linuxdeploy.rs:206-216`, `cmd.output_ok()?`) — CI surfaces only `failed to run linuxdeploy`. Invocation (linuxdeploy.rs:187-204): `linuxdeploy-x86_64.AppImage --appimage-extract-and-run --verbosity <3=Error|2=Warn|1=Info|0=Debug> --appdir "<target>/<triple>/release/bundle/appimage/EvoX Genesis.AppDir" --plugin gtk [--plugin gstreamer] --output appimage`, env `OUTPUT`, `ARCH`, `APPIMAGE_EXTRACT_AND_RUN=1`. The AppDir survives failed runs — re-run the command manually on it to see the real error. **`bundleMediaFramework` defaults to false** (`AppImageSettings` derives `Default`), so `--plugin gstreamer` is NOT passed by default (the gstreamer script is still downloaded).
- **Tools & pinning**: downloaded to `~/.cache/tauri/` (download skipped if file exists): `AppRun-<arch>` (tauri-apps/binary-releases "apprun-old"), `linuxdeploy-<arch>.AppImage` (tauri-apps/binary-releases "linuxdeploy"), `linuxdeploy-plugin-gtk.sh` + `linuxdeploy-plugin-gstreamer.sh` (raw.githubusercontent.com/tauri-apps/... master), `linuxdeploy-plugin-appimage-<arch>.AppImage` (linuxdeploy "continuous"). All unpinned. Pre-seeding `~/.cache/tauri/` pins them — but note tauri-bundler runs `dd if=/dev/zero bs=1 count=3 seek=8 conv=notrunc` on the cached linuxdeploy AppImage on **every** run (zeroes the type-2 magic at bytes 8-10, "to prevent appimage integration tools" from detecting it), so the cached copy is corrupted in place; keep a pristine copy elsewhere if you need one. Assessment: the tools were NOT the drift source for the v0.9.5 failure (all verified unchanged vs v0.9.4); pinning via pre-seed is optional.
- **Local AppImage exec quirk (this dev machine)**: the NixOS binfmt_misc `appimage_type_2` handler wraps AppImage exec in bubblewrap, which fails in this container (`bwrap: Failed to make / slave`) — you cannot exec any `.AppImage` here. Workaround: type-2 AppImages store the squashfs offset in bytes 8-11 (little-endian): `dd if=F bs=1 skip=8 count=4 | od -An -tu4`, then `nix shell nixpkgs#squashfs-tools -c unsquashfs -o <offset> F <dest>`, and run the extracted payload (`usr/bin/linuxdeploy`). The extracted binary rejects the runtime-only `--appimage-extract-and-run` flag — drop it. Plugins are discovered via PATH under names `linuxdeploy-plugin-<name>` (symlink the `.sh`/extracted payloads accordingly).
- **NixOS-specific bundling quirks (local only — never root-cause candidates)**: no `/bin/bash` (patch plugin shebangs); pkg-config emits multi-`-L` strings that break tauri-cli's library-path parsing (sanitizing wrapper needed); gtk plugin needs writable glib schemas/immodules paths. The gtk plugin is identical between v0.9.4 (passed) and v0.9.5 (failed) in CI.
