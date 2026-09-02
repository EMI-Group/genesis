# Tauri Shell — Rust Source

## Intent

Rust source for the Genesis Tauri v2 desktop shell: `main.rs` (entry point, tray, window, update commands, headless mode), `sidecar.rs` (backend sidecar lifecycle + env), `backend_watchdog.rs` (crash watchdog + update install), `sidecar_path.rs` (shared launcher-path resolution). No Elixir code lives here.

## API Surface

| File | Purpose |
|------|---------|
| `main.rs` | Entry point — `run_gui` / `run_headless`, `resolve_backend_port` (dynamic port, `PORT` honored only when free), `headless_sidecar_env(port, lifetime_port)`, tray + single-instance + update commands (`begin_quit` / `check_update` / `download_update` / `begin_update`) |
| `sidecar.rs` | `launcher_command` (Windows `CREATE_NO_WINDOW` — the ONLY GUI spawn path), `spawn`, `probe_http`, `wait_for_ready`, `sidecar_env(port, lifetime_port)`, `start_lifetime_listener` |
| `backend_watchdog.rs` | `BackendManager` — monitors/restarts the backend child, error page, quit/update intent flags |
| `sidecar_path.rs` | `resolve_launcher` — shared candidate-dir launcher resolution (GUI + headless) |

## Lifetime Pipe (TCP hold)

Contract with the Elixir backend (fixed on the Elixir side — do not change):
- Env var **`EVOGIT_LIFETIME_PORT`** = the lifetime listener's port (bound on 127.0.0.1). The backend connects to `127.0.0.1:<port>` and blocks on recv; any close/error = shell dead → backend `System.stop(0)`.
- **`EVOGIT_PARENT_PID` is not used** — do not reintroduce it in either env builder.
- The shell **never writes** on the lifetime connection — it is a pure hold.

Rust side:
- `sidecar::start_lifetime_listener() -> io::Result<u16>`: binds `127.0.0.1:0`, spawns a **detached accept thread** looping `listener.incoming()` forever, spawning a per-stream hold thread per accepted connection (blocking read loop until EOF/error, then the stream drops). Accept errors are logged and the loop continues — every watchdog respawn / backend reconnect gets its own held connection. Never writes.
- `sidecar_env(port, lifetime_port: Option<u16>)` / `headless_sidecar_env(port, lifetime_port: Option<u16>)` emit `EVOGIT_LIFETIME_PORT` **only when `Some`**. `None` = listener bind failure → the var is omitted so the backend's monitor stays off (emitting a bad port would make the backend treat a failed connect as shell-death and stop — wrong). Bind failure is non-fatal by design (defense-in-depth; the dynamic backend port already prevents the orphan crash).
- `run_gui` (setup closure) and `run_headless` resolve the listener before building the env. The env is built **once** and reused by the watchdog for all respawns — the lifetime port stays constant for the shell's lifetime; the accept thread handles each respawn's new connection.

## Constraints

- **Spawn-path invariant**: the backend launcher is spawned only via `sidecar::spawn` → `launcher_command` (GUI initial boot AND every watchdog restart) or the equivalent `launcher_command` call in `run_headless` — never a plain `Command::new` (Windows console-window bug + CREATE_NO_WINDOW).
- **Per-worktree gotcha — `resources/genesis-backend/` is gitignored** (root `.gitignore`), so it does NOT exist in fresh worktrees. tauri-build hard-fails at compile time without it (`resource path 'resources/genesis-backend' doesn't exist`). Create it locally before `cargo test`/`cargo check`: `mkdir -p desktop/src-tauri/resources/genesis-backend` (untracked, invisible to git, never committed; the Nix flake derivation symlinks a built release there in a preBuild hook).
- `cargo check`/tests require the nix devShell toolchain on NixOS hosts (`nix develop` at repo root or crate dir).
- Update commands' JSON contracts are pinned with the dashboard workstream — do not rename keys/statuses.

## Known Issues

### Windows NSIS auto-update race — installer spawns before the old process tree is gone (backend_watchdog.rs)

"Restart & Update" can fail with NSIS "file in use"/"file can't be written" on the first attempt; an immediate retry succeeds. Two distinct mechanisms:

1. **Async exit after spawning the installer** (`install_and_relaunch` `Ok(())` arm, backend_watchdog.rs L480-494): after `install_windows_nsis` (L861-900) spawns the installer, the code calls `app.exit(0)` — which is ASYNC (tauri `AppHandle::exit` → `runtime_handle.request_exit` → event-loop `ControlFlow::Exit`; only on error does it fall back to `std::process::exit`). The old `genesis-desktop.exe` and its WebView2 children can still be alive when NSIS starts replacing files. tauri-plugin-updater 2.10.1's `install_inner` instead does `ShellExecuteW(...)` then immediately `std::process::exit(0)` — a hard synchronous exit, process gone within microseconds of the installer starting. The NSIS template (tauri-bundler 2.9.4) only mitigates, not guarantees: `Section Install`'s first action is `CheckIfAppIsRunning "${MAINBINARYNAME}.exe"` (installer.nsi L645) → `nsis_tauri_utils::KillProcess`/`KillProcessCurrentUser` = image-name `TerminateProcess` per PID + a bare `Sleep 500` (utils.nsh L21-71) — NOT a wait-for-exit and NOT a tree kill. Update mode (`/UPDATE`) skips uninstall entirely (`PageLeaveReinstall` → `reinst_done`, installer.nsi L319-320). Fix direction: mirror the plugin — on Windows hard-exit (`std::process::exit(0)`) immediately after the installer spawn succeeds (cfg-split the `Ok(())` arm; keep the Unix `spawn_detached` + `app.exit(0)` arm unchanged).

2. **Force-kill paths orphan the BEAM** (`kill_current_child` L379-385): the tracked child on Windows is **cmd.exe** (std retries the `.bat` launcher via `cmd.exe /c` — sidecar.rs L44-73), and `child.kill()`/`TerminateProcess` on cmd.exe does NOT kill the BEAM grandchild (erl.exe/beam.smp). The orphaned BEAM only self-exits when the EVOGIT_LIFETIME_PORT pipe closes — which happens only when the Rust shell dies. On `finish_shutdown`'s 15s fallback (L428-434) and the post-spawn race (L584-592) the watchdog can therefore spawn NSIS while an orphan BEAM still holds `resources/genesis-backend/` files open; NSIS kills the shell by name (pipe closes → BEAM starts a *graceful* `System.stop(0)`, not instant) and its 500 ms sleep can expire before the BEAM is truly gone → file-in-use. Fix direction: on Windows, tree-kill via `taskkill /PID <pid> /T /F` (std `Command`, no new crate; must run while cmd.exe is still alive, i.e. BEFORE `child.kill()`) in `kill_current_child` — covers `finish_shutdown`, the post-spawn race, `kill_for_quit` and the ready-timeout kill. Job objects are the wrong tool: children were spawned without a job, so retroactive assignment can't cover the already-spawned erl.exe tree. Do NOT touch the Linux/macOS paths or the JSON command contracts. This entry documents current state only — DELETE it once the fix lands.
