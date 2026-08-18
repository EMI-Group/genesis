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

## Lifetime Pipe (TCP hold — replaces the parent-pid handshake)

Contract with the Elixir backend (fixed on the Elixir side — do not change):
- Env var **`EVOGIT_LIFETIME_PORT`** = the lifetime listener's port (bound on 127.0.0.1). The backend connects to `127.0.0.1:<port>` and blocks on recv; any close/error = shell dead → backend `System.stop(0)`.
- **`EVOGIT_PARENT_PID` no longer exists** — do not reintroduce it in either env builder.
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
