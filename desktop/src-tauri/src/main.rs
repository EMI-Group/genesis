// Prevents an additional console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Arc;

use serde_json::json;
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager, WindowEvent,
};
use tauri_plugin_updater::UpdaterExt;

mod backend_watchdog;
mod sidecar;
mod sidecar_path;

use backend_watchdog::BackendManager;

/// How long (in seconds) to wait for the backend to become ready.
const BACKEND_READY_TIMEOUT_SECS: u64 = 30;

/// How many times the GUI setup retries navigating the webview to the
/// dashboard after the initial readiness poll (step 8). The webview's first
/// load races the backend boot, so the re-navigation must tolerate a webview
/// that is still initializing; the budget is bounded (~20 × 250ms = ~5s).
const INITIAL_NAVIGATE_ATTEMPTS: u32 = 20;
/// Delay between the post-readiness navigation retries.
const INITIAL_NAVIGATE_RETRY_MS: u64 = 250;

/// Delays (ms) between the `quit-requested` re-emits after the synchronous
/// first emit (see the tray "quit" arm). 5 re-emits + the sync emit = 6
/// emits over ~8s, covering a slow page load while the dashboard mounts and
/// its LiveSocket reconnects.
const QUIT_REEMIT_DELAYS_MS: [u64; 5] = [500, 1000, 2000, 4000, 8000];

/// Keeper thread poll interval (ms).
const KEEPER_POLL_INTERVAL_MS: u64 = 2000;

/// A dashboard heartbeat younger than this (ms) means the dashboard is live —
/// the keeper must NOT re-navigate a live dashboard (that would reload it
/// before its socket joins and prevent it from ever mounting).
const DASHBOARD_HEARTBEAT_FRESH_MS: i64 = 10_000;

/// Minimum gap (ms) between keeper navigations — prevents hammering a page
/// that is still loading (a reload would restart the load before the socket
/// joins and never let it mount).
const KEEPER_NAVIGATE_COOLDOWN_MS: i64 = 15_000;

/// The OS-specific launcher script name inside the bundled release directory.
///
/// On Unix this is the POSIX shell script `genesis_desktop`; on Windows it is
/// the batch-file variant `genesis_desktop.bat`.
#[cfg(windows)]
const LAUNCHER_NAME: &str = "genesis_desktop.bat";
#[cfg(not(windows))]
const LAUNCHER_NAME: &str = "genesis_desktop";

/// Managed handle to the [`BackendManager`], shared between the tray-quit
/// handler, the watchdog thread, and the `begin_quit` command.
type BackendHandle = Arc<BackendManager>;

/// Tauri command invoked by the dashboard's JavaScript after the user
/// confirms the web-page quit dialog.
///
/// Marks the shutdown as intentional WITHOUT killing anything, so the backend
/// watchdog never restarts the child process; the backend then stops itself
/// gracefully (dashboard `System.stop()`).
#[tauri::command]
fn begin_quit(manager: tauri::State<'_, BackendHandle>) {
    manager.begin_quit();
}

/// Tauri command invoked fire-and-forget by the dashboard's JavaScript
/// (`DesktopQuit` hook) at hook mount, on every socket reconnect, on every
/// `quit-requested` reception, and periodically (every ~5s) while the hook
/// is mounted, so a live dashboard always carries a fresh heartbeat and the
/// keeper never re-navigates a healthy page.
///
/// Records the dashboard's liveness in the [`BackendManager`] heartbeat (a
/// wall-clock timestamp) so the keeper thread stops re-navigating a live
/// dashboard. Must not panic when the state is missing — it is only managed
/// in `run_gui`, and headless never registers the command (same pattern as
/// `begin_quit`).
#[tauri::command]
fn dashboard_ready(manager: tauri::State<'_, BackendHandle>) {
    manager.mark_dashboard_ready();
}

// ---------------------------------------------------------------------------
// Auto-update commands (JSON contracts pinned with the dashboard workstream —
// do not rename keys or statuses)
// ---------------------------------------------------------------------------

/// The placeholder public key shipped in `tauri.conf.json` →
/// `plugins > updater > pubkey`. The user must replace it with the output of
/// `tauri signer generate` (and add the `TAURI_SIGNING_PRIVATE_KEY` /
/// `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` CI secrets) before any real check or
/// download can work. Until then the commands report `not_configured` instead
/// of surfacing raw minisign parse errors.
const PLACEHOLDER_UPDATER_PUBKEY: &str = "REPLACE_WITH_TAURI_SIGNER_GENERATED_PUBLIC_KEY";

/// Message returned by the update commands while the signing key is not set up.
const NOT_CONFIGURED_MESSAGE: &str = "Auto-update is not configured yet: the updater public key \
in tauri.conf.json (plugins > updater > pubkey) is still the placeholder. Run `tauri signer \
generate` to create a minisign keypair, paste the generated public key over the placeholder in \
desktop/src-tauri/tauri.conf.json, and add the TAURI_SIGNING_PRIVATE_KEY and \
TAURI_SIGNING_PRIVATE_KEY_PASSWORD secrets to CI. Until then update checks are disabled.";

/// True when the configured updater pubkey is missing, empty, or still the
/// placeholder string — i.e. the signing setup has not been completed.
fn updater_pubkey_is_placeholder(pubkey: Option<&str>) -> bool {
    match pubkey {
        None => true,
        Some(key) => {
            let trimmed = key.trim();
            trimmed.is_empty() || trimmed == PLACEHOLDER_UPDATER_PUBKEY
        }
    }
}

/// Reads `plugins > updater > pubkey` from the tauri config
/// (`app.config().plugins` is a name → JSON-value map).
fn configured_updater_pubkey(app: &tauri::AppHandle) -> Option<String> {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|v| v.get("pubkey"))
        .and_then(|v| v.as_str())
        .map(str::to_string)
}

/// True when the updater error means the remote manifest (`latest.json`) has no
/// payload for the current platform — e.g. its `platforms` object lacks the
/// `linux-x86_64` key. In that case the commands report `not_available` instead
/// of a generic error.
fn is_missing_platform_error(err: &tauri_plugin_updater::Error) -> bool {
    matches!(
        err,
        tauri_plugin_updater::Error::TargetNotFound(_)
            | tauri_plugin_updater::Error::TargetsNotFound(_)
    )
}

/// Latest-version info parsed from the raw update feed (`latest.json`).
///
/// Read directly by the shell when the updater plugin cannot resolve a payload
/// for the current platform (or failed outright), so the dashboard can still
/// show the latest release version from the feed.
struct FeedInfo {
    version: String,
    body: Option<String>,
    date: Option<String>,
}

/// Reads `plugins > updater > endpoints` (the ordered list of feed URLs) from
/// the tauri config — the same source the updater plugin itself uses. Empty
/// when the config carries no endpoints.
fn configured_updater_endpoints(app: &tauri::AppHandle) -> Vec<String> {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|v| v.get("endpoints"))
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// True when `s` is a semver-shaped version (`major.minor.patch`, with
/// optional `-prerelease` / `+build` suffixes). A deliberate loose check: its
/// only job is gating garbage from a malformed feed, not full semver parsing.
fn is_version_shaped(s: &str) -> bool {
    let core = s.split(['+', '-']).next().unwrap_or(s);
    let mut parts = core.split('.');
    match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(a), Some(b), Some(c), None) => [a, b, c]
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())),
        _ => false,
    }
}

/// Parses the update-feed JSON (`{"version", "notes", "pub_date",
/// "platforms", ...}`) and returns the latest-version info. Returns `None`
/// when the text is not a parseable feed: malformed JSON, a missing or
/// non-string `version`, or a version that fails the shape check. A leading
/// `v` is trimmed first (mirroring the plugin); `notes`/`pub_date` are
/// optional and map to `None` when absent.
fn parse_feed_info(json_text: &str) -> Option<FeedInfo> {
    let parsed: serde_json::Value = serde_json::from_str(json_text).ok()?;
    let version = parsed
        .get("version")?
        .as_str()?
        .trim()
        .trim_start_matches('v');
    if !is_version_shaped(version) {
        return None;
    }
    Some(FeedInfo {
        version: version.to_string(),
        body: parsed
            .get("notes")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        date: parsed
            .get("pub_date")
            .and_then(|v| v.as_str())
            .map(str::to_string),
    })
}

/// Fetches the update feed directly (bypassing the updater plugin) and parses
/// out the latest-version info. Tries each configured endpoint in order
/// (mirroring the plugin's own fallback); every request is bounded by a 30s
/// timeout and follows redirects (reqwest's default). `None` when no endpoint
/// yields a parseable feed.
async fn fetch_feed_info(app: &tauri::AppHandle) -> Option<FeedInfo> {
    let endpoints = configured_updater_endpoints(app);
    if endpoints.is_empty() {
        return None;
    }
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .ok()?;
    for endpoint in endpoints {
        let text = match client.get(endpoint).send().await {
            Ok(resp) => match resp.error_for_status() {
                Ok(resp) => match resp.text().await {
                    Ok(text) => text,
                    Err(_) => continue,
                },
                Err(_) => continue,
            },
            Err(_) => continue,
        };
        if let Some(info) = parse_feed_info(&text) {
            return Some(info);
        }
    }
    None
}

/// `check_update` — asks the updater plugin whether a new version is available.
///
/// JSON contract (all keys always present):
/// `{"status", "current_version", "version", "body", "date", "error"}` where
/// status ∈ `"up_to_date" | "available" | "not_configured" | "not_available" | "error"`.
///
/// When the plugin check fails because the feed has no payload for the current
/// platform (`not_available`), and also on any other plugin failure (`error`),
/// the feed is fetched directly ([`fetch_feed_info`]) so `version`/`body`/
/// `date` still report the latest release from the feed instead of nulls.
#[tauri::command]
async fn check_update(app: tauri::AppHandle) -> serde_json::Value {
    if updater_pubkey_is_placeholder(configured_updater_pubkey(&app).as_deref()) {
        return json!({
            "status": "not_configured",
            "current_version": app.package_info().version.to_string(),
            "version": null,
            "body": null,
            "date": null,
            "error": NOT_CONFIGURED_MESSAGE,
        });
    }

    // A bounded timeout keeps the dashboard invoke from hanging on a dead
    // endpoint (the plugin applies no timeout by default).
    let updater = match app
        .updater_builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
    {
        Ok(updater) => updater,
        Err(err) => {
            // Config-level plugin failure — still try the direct feed fetch so
            // the response carries the latest version from the feed.
            let feed = fetch_feed_info(&app).await;
            return json!({
                "status": "error",
                "current_version": app.package_info().version.to_string(),
                "version": feed.as_ref().map(|f| f.version.clone()),
                "body": feed.as_ref().and_then(|f| f.body.clone()),
                "date": feed.as_ref().and_then(|f| f.date.clone()),
                "error": format!("Update check failed: {err}"),
            });
        }
    };

    match updater.check().await {
        Err(err) => {
            // The plugin check failed. Fetch the feed directly so the response
            // can still carry the latest version (and notes/date) from the
            // feed — both when the platform simply has no payload
            // (`not_available`) and when the plugin client itself failed
            // (`error`, e.g. proxy/TLS quirks).
            let feed = fetch_feed_info(&app).await;
            if is_missing_platform_error(&err) {
                json!({
                    "status": "not_available",
                    "current_version": app.package_info().version.to_string(),
                    "version": feed.as_ref().map(|f| f.version.clone()),
                    "body": feed.as_ref().and_then(|f| f.body.clone()),
                    "date": feed.as_ref().and_then(|f| f.date.clone()),
                    "error": "No auto-update is available for this platform.",
                })
            } else {
                json!({
                    "status": "error",
                    "current_version": app.package_info().version.to_string(),
                    "version": feed.as_ref().map(|f| f.version.clone()),
                    "body": feed.as_ref().and_then(|f| f.body.clone()),
                    "date": feed.as_ref().and_then(|f| f.date.clone()),
                    "error": format!("Update check failed: {err}"),
                })
            }
        }
        Ok(None) => json!({
            "status": "up_to_date",
            "current_version": app.package_info().version.to_string(),
            "version": null,
            "body": null,
            "date": null,
            "error": null,
        }),
        Ok(Some(update)) => {
            let date = update.date.and_then(|d| {
                d.format(&time::format_description::well_known::Rfc3339)
                    .ok()
            });
            json!({
                "status": "available",
                "current_version": app.package_info().version.to_string(),
                "version": update.version.clone(),
                "body": update.body.clone(),
                "date": date,
                "error": null,
            })
        }
    }
}

/// `download_update` — downloads (and minisign-verifies) the new bundle.
///
/// The download is INERT: nothing the running app depends on is written. The
/// verified payload is stashed in the process-global
/// [`backend_watchdog::set_downloaded_update`] slot, where the watchdog's
/// update-intent flow consumes it after the backend has stopped.
///
/// JSON contract: `{"status": <"ready"|"error">, "version": <string|null>,
/// "error": <string|null>}`.
#[tauri::command]
async fn download_update(app: tauri::AppHandle) -> serde_json::Value {
    if updater_pubkey_is_placeholder(configured_updater_pubkey(&app).as_deref()) {
        return json!({
            "status": "error",
            "version": null,
            "error": NOT_CONFIGURED_MESSAGE,
        });
    }

    let updater = match app.updater() {
        Ok(updater) => updater,
        Err(err) => {
            return json!({
                "status": "error",
                "version": null,
                "error": format!("Update download failed: {err}"),
            });
        }
    };

    let update = match updater.check().await {
        Ok(Some(update)) => update,
        Ok(None) => {
            return json!({
                "status": "error",
                "version": null,
                "error": "No update is available to download.",
            });
        }
        Err(err) => {
            if is_missing_platform_error(&err) {
                return json!({
                    "status": "error",
                    "version": null,
                    "error": "No auto-update is available for this platform.",
                });
            }
            return json!({
                "status": "error",
                "version": null,
                "error": format!("Update download failed: {err}"),
            });
        }
    };

    let version = update.version.clone();
    match update.download(|_chunk_len, _total| {}, || {}).await {
        Ok(bytes) => {
            backend_watchdog::set_downloaded_update(version.clone(), bytes);
            json!({
                "status": "ready",
                "version": version,
                "error": null,
            })
        }
        Err(err) => json!({
            "status": "error",
            "version": null,
            "error": format!("Update download failed: {err}"),
        }),
    }
}

/// `begin_update` — arms the watchdog's update-intent flow.
///
/// The dashboard invokes this BEFORE the backend calls `System.stop/0` from
/// inside the BEAM. It only sets the update-intent flag (kills nothing, exactly
/// like `begin_quit`); when the backend child then exits (code 0), the watchdog
/// runs the installer for the downloaded payload and relaunches the new bundle
/// instead of exiting the app.
///
/// JSON contract: `{"ok": true}`.
#[tauri::command]
fn begin_update(manager: tauri::State<'_, BackendHandle>) -> serde_json::Value {
    manager.begin_update();
    json!({"ok": true})
}

/// Asks the OS for a currently-free ephemeral port on 127.0.0.1.
///
/// Binds `127.0.0.1:0` (the OS assigns a free ephemeral port), reads the
/// assigned port, and drops the listener again. There is a tiny race between
/// the drop and the backend's own bind — the watchdog's restart cycle absorbs
/// a failed bind — but on a desktop the window is negligible. A failure to
/// bind ANY loopback ephemeral port is a system-level failure from which the
/// backend could not recover either, so it surfaces loudly.
fn pick_free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|listener| listener.local_addr().map(|addr| addr.port()))
        .expect("failed to pick a free port: cannot bind an ephemeral port on 127.0.0.1")
}

/// True when nothing currently listens on `port` on 127.0.0.1.
///
/// A bind probe — if the bind succeeds the port is free, and the listener is
/// dropped immediately.
fn port_is_bindable(port: u16) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// Resolves the backend port from a candidate `PORT` environment value.
///
/// Pure logic (no environment access) so it is directly testable:
/// - `None` or an unparseable value → a fresh free ephemeral port;
/// - a parseable value whose port is currently free → that exact port;
/// - a parseable value whose port is OCCUPIED → a warning and a fresh free
///   port. This is the anti-crash guarantee: even a stale `PORT=9999` left
///   over from a zombie backend can no longer wedge the app.
fn resolve_backend_port_from(env_port: Option<&str>) -> u16 {
    match env_port.and_then(|p| p.parse::<u16>().ok()) {
        // PORT=0 is not a real port ("OS-assigned ephemeral") — it would
        // break the WebView URL, so treat it like an unset value.
        Some(port) if port > 0 && port_is_bindable(port) => port,
        Some(port) if port > 0 => {
            eprintln!(
                "[desktop] PORT={port} is already in use — picking a free ephemeral port instead"
            );
            pick_free_port()
        }
        _ => pick_free_port(),
    }
}

/// Resolves the port the Phoenix backend will listen on.
///
/// The `PORT` environment variable is honored when it is set, parses as a
/// port, and is currently free; otherwise a random free ephemeral port is
/// picked at startup (never a fixed default). The WebView always connects via
/// `localhost` since it runs on the same machine, using the same port.
fn resolve_backend_port() -> u16 {
    resolve_backend_port_from(std::env::var("PORT").ok().as_deref())
}

// ---------------------------------------------------------------------------
// --headless mode
// ---------------------------------------------------------------------------

/// Signal-safe shutdown flag set by the SIGINT / SIGTERM handler.
static SHUTDOWN_FLAG: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(unix)]
mod signal_handler {
    use std::sync::atomic::Ordering;

    extern "C" {
        fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
    }

    const SIGINT: i32 = 2;
    const SIGTERM: i32 = 15;

    extern "C" fn handle(_sig: i32) {
        super::SHUTDOWN_FLAG.store(true, Ordering::SeqCst);
    }

    /// Register signal handlers so that SIGINT / SIGTERM set the shutdown
    /// flag rather than immediately killing the process.
    pub fn setup() {
        unsafe {
            signal(SIGINT, handle);
            signal(SIGTERM, handle);
        }
    }
}

/// Resolve the path to the mix release launcher script.
///
/// Looks next to the running executable first (production / bundled layout),
/// and falls back to the source-tree `resources/` directory (development).
/// The candidate-selection logic is shared with the GUI mode in
/// [`sidecar_path`].
fn resolve_sidecar_path() -> Result<std::path::PathBuf, String> {
    // 1. Production: <exe_dir>/resources/genesis-backend/bin/<launcher>
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_default();

    // 2. Development: <manifest_dir>/resources/genesis-backend/bin/<launcher>
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    sidecar_path::resolve_launcher(&[exe_dir, manifest_dir], LAUNCHER_NAME)
}

/// Build the environment-variable list for the sidecar, mirroring
/// [`sidecar::sidecar_env`]. `lifetime_port` (see
/// [`sidecar::start_lifetime_listener`]) is emitted as `EVOGIT_LIFETIME_PORT`
/// only when present; `None` (listener bind failure) omits the variable so
/// the backend's monitor stays off.
fn headless_sidecar_env(port: u16, lifetime_port: Option<u16>) -> Vec<(String, String)> {
    let phx_ip = std::env::var("EVOGIT_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());

    let mut env = vec![
        ("PORT".to_string(), port.to_string()),
        ("PHX_IP".to_string(), phx_ip),
        ("PHX_SERVER".to_string(), "true".to_string()),
        (
            "SECRET_KEY_BASE".to_string(),
            "GenesisDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890".to_string(),
        ),
        ("RELEASE_DISTRIBUTION".to_string(), "none".to_string()),
        ("EVOGIT_DESKTOP".to_string(), "1".to_string()),
    ];

    if let Some(lifetime_port) = lifetime_port {
        env.push((
            "EVOGIT_LIFETIME_PORT".to_string(),
            lifetime_port.to_string(),
        ));
    }

    env
}

/// Run the desktop app as a headless HTTP server (no window, no tray).
///
/// Spawns the Elixir release launcher (`bin/genesis_desktop start`), waits for
/// it to become ready, then blocks until the launcher exits or a SIGTERM /
/// SIGINT is received.  On signal the sidecar is killed gracefully before the
/// process exits.
fn run_headless() {
    #[cfg(unix)]
    signal_handler::setup();

    // Resolve the backend port once; the same port drives the sidecar env and
    // the readiness probe. With the dynamic default, two headless instances
    // can no longer collide on a fixed port.
    let port = resolve_backend_port();

    let sidecar_path = resolve_sidecar_path().unwrap_or_else(|msg| {
        eprintln!("[desktop] {msg}");
        std::process::exit(1);
    });

    // Start the TCP lifetime pipe: the backend connects to this port and
    // blocks; any close = shell dead → backend self-stops. Non-fatal on
    // failure (the dynamic backend port already prevents the orphan crash).
    let lifetime_port = match sidecar::start_lifetime_listener() {
        Ok(p) => Some(p),
        Err(e) => {
            eprintln!("[desktop] failed to start lifetime listener: {e}");
            None
        }
    };

    let mut child = sidecar::launcher_command(&sidecar_path)
        .arg("start")
        .envs(headless_sidecar_env(port, lifetime_port))
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap_or_else(|e| {
            eprintln!("[desktop] failed to spawn sidecar: {e}");
            std::process::exit(1);
        });

    println!(
        "[desktop] spawned genesis-backend sidecar (pid {})",
        child.id()
    );

    // Wait for the backend to become ready (reuses the existing poll logic).
    let url = format!("http://localhost:{port}");
    sidecar::wait_for_ready(&url, BACKEND_READY_TIMEOUT_SECS);

    println!("[desktop] running headless — press Ctrl+C to stop");

    // Block until the sidecar exits or a shutdown signal arrives.
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                println!("[desktop] sidecar exited with: {status:?}");
                std::process::exit(status.code().unwrap_or(0));
            }
            Ok(None) => {
                if SHUTDOWN_FLAG.load(std::sync::atomic::Ordering::SeqCst) {
                    println!("[desktop] received signal, shutting down sidecar...");
                    let _ = child.kill();
                    let _ = child.wait();
                    std::process::exit(0);
                }
            }
            Err(e) => {
                eprintln!("[desktop] error waiting for sidecar: {e}");
                let _ = child.kill();
                std::process::exit(1);
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}

// ---------------------------------------------------------------------------
// GUI mode
// ---------------------------------------------------------------------------

fn run_gui() {
    // Resolve the backend port ONCE at the top of the GUI flow: the same port
    // drives the sidecar env, the watchdog, the initial readiness poll, and
    // the WebView URL (the config window entry was removed — the window is
    // now created in the setup closure with this dynamic URL).
    let port = resolve_backend_port();
    let url = format!("http://localhost:{port}");

    tauri::Builder::default()
        // MUST be the first plugin: plugins run in registration order, and this
        // plugin's setup is what makes a second instance exit. Registering it
        // before our own `setup` closure guarantees the second instance exits
        // before it could spawn its own backend sidecar.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // A second instance was launched. It exits during the plugin's own
            // setup (before this process's `setup` closure runs), so it never
            // spawns its own backend. Restore + focus the existing window.
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            begin_quit,
            dashboard_ready,
            check_update,
            download_update,
            begin_update
        ])
        .setup(move |app| {
            // 1. Resolve the launcher path once and build the backend
            //    environment. A broken install (missing launcher) stays fatal.
            let launcher = sidecar::launcher_path(app)?;

            // Start the TCP lifetime pipe: the backend connects to this port
            // and blocks; any close = shell dead → backend self-stops.
            // Non-fatal on failure (defense-in-depth — the dynamic backend
            // port already prevents the orphan crash). The env is built ONCE
            // and reused by the watchdog for all respawns, so the lifetime
            // port stays constant for the shell's lifetime; the accept thread
            // handles each respawn's new connection.
            let lifetime_port = match sidecar::start_lifetime_listener() {
                Ok(p) => Some(p),
                Err(e) => {
                    eprintln!("[desktop] failed to start lifetime listener: {e}");
                    None
                }
            };
            let env = sidecar::sidecar_env(port, lifetime_port);

            // 2. Create the backend manager and spawn the initial child. A
            //    spawn failure is NOT fatal: the watchdog treats the missing
            //    child as a failure and drives the error page + restart cycle.
            let manager: BackendHandle = Arc::new(BackendManager::new(
                launcher,
                env,
                port,
                url.clone(),
            ));
            if let Err(err) = manager.spawn_child() {
                eprintln!("[desktop] failed to spawn genesis-backend sidecar: {err}");
            }
            app.manage(manager.clone());

            // 3. Start the backend watchdog on a dedicated thread. It monitors
            //    the child process, restarts it with backoff on unexpected
            //    exit, shows the error page while it is down, and reloads the
            //    WebView once the backend serves requests again.
            let app_handle = app.handle().clone();
            let watchdog_manager = manager.clone();
            std::thread::spawn(move || watchdog_manager.run_watchdog(app_handle));

            // 4. Build the system tray menu. "Show Window" is the primary,
            //    benign action (placed first so it's the natural target for a
            //    quick left-click + top-entry press). A separator visually and
            //    spatially isolates the destructive "Quit" item so a misclick
            //    on the benign action can't land on "Quit". Quitting is a
            //    two-step flow: "Quit" shows and focuses the window, probes
            //    the backend, and (if healthy) emits `quit-requested` so the
            //    dashboard renders a web-page confirmation dialog; on
            //    confirmation the dashboard JS invokes the `begin_quit`
            //    command and the backend stops itself gracefully.
            let show_item = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
            let separator = PredefinedMenuItem::separator(app)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit Genesis", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_item, &separator, &quit_item])?;

            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                // On macOS the default left-click opens the menu on mouse-down,
                // which swallows the Click { Left, Up } event below. Disable it
                // so left-click pops the window; the menu stays on right-click.
                .show_menu_on_left_click(false)
                .tooltip("Genesis")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => {
                        // Show + focus the main window first, exactly like the
                        // "show" arm and the single-instance callback, so the
                        // user sees the confirm dialog the dashboard renders.
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.unminimize();
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                        // Backend healthy → hand the quit decision to the web
                        // page: emit `quit-requested`; the dashboard shows its
                        // confirm modal and on confirmation its JS invokes the
                        // `begin_quit` command (sets the
                        // intentional-shutdown flag, no kill) and the backend
                        // stops itself gracefully. The URL is read from the
                        // managed BackendHandle: with a dynamic port the
                        // environment no longer reflects the actual port, so
                        // recomputing it here would probe a stale URL.
                        let manager = app.try_state::<BackendHandle>();
                        if let Some(manager) = manager.as_ref() {
                            if sidecar::probe_http(manager.backend_url()).is_some() {
                                // Synchronous first emit — the dashboard may be
                                // fully connected right now, and waiting +500ms
                                // (the first re-emit) before the event reaches
                                // it is an unnecessary delay.
                                let _ = app.emit("quit-requested", ());

                                // Re-emit on a bounded schedule — while the
                                // window was hidden to tray, phoenix suspends
                                // reconnects (pageHidden) and the dashboard's
                                // pushEvent drops the event when the channel
                                // can't push; a slow page load also needs time
                                // to mount. 6 emits total (~8s window); the
                                // dashboard handler is idempotent (assign set
                                // true; unchanged → no re-render) and the
                                // re-emits stop by themselves once the user
                                // confirms (backend stops, app exits).
                                // `manager.inner()` unwraps the tauri `State`
                                // (which borrows `app`) to the owned
                                // `Arc<BackendManager>` so the detached
                                // thread can own it ('static). Clone both
                                // BEFORE the re-emit closure moves them.
                                let app = app.clone();
                                let manager = manager.inner().clone();
                                std::thread::spawn(move || {
                                    for delay_ms in QUIT_REEMIT_DELAYS_MS {
                                        std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                                        if manager.shutdown_requested()
                                            || manager.update_requested()
                                        {
                                            break; // user confirmed — the app is going away
                                        }
                                        if app.emit("quit-requested", ()).is_err() {
                                            break; // app is shutting down
                                        }
                                    }
                                });
                                return;
                            }
                        }
                        // Backend down — the WebView shows the watchdog error
                        // page, so no dashboard dialog could appear. Keep the
                        // old immediate path: flag an intentional shutdown
                        // BEFORE killing the child, so the watchdog never
                        // restarts the backend after a quit has begun.
                        if let Some(manager) = manager {
                            manager.kill_for_quit();
                        }
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    // On Windows and macOS a left-click on the tray icon emits
                    // a `TrayIconEvent::Click { Left, Up }`, which we use to
                    // show the window directly (one click, no menu navigation).
                    //
                    // Linux limitation: the underlying `tray-icon` crate uses
                    // libappindicator on Linux, which NEVER emits click events
                    // (upstream: tauri-apps/tray-icon#104). So this handler is
                    // a no-op on Linux — a left-click there simply opens the
                    // context menu instead. That is why "Show Window" is kept
                    // as the topmost menu item (with a separator above "Quit"):
                    // on Linux, left-click → top entry is the natural flow, and
                    // the separator guards against misclicking "Quit".
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                })
                .build(app)?;

            // 5. Create the main window. The window used to be declarative in
            //    tauri.conf.json with a hardcoded http://localhost:9999 URL;
            //    with a dynamic port the URL must follow the resolved port, so
            //    the window is created here with `WebviewUrl::External` (the
            //    config window entry and `build.devUrl` were removed — a
            //    duplicate "main" label would conflict with a config-built
            //    window). Properties mirror the removed config entry: title,
            //    1280x800, resizable, centered. The window is created BEFORE
            //    the blocking readiness poll so the watchdog's `show_backend`
            //    retry loop (which waits for the window) behaves as before.
            //    The window's initial load races the backend boot — the
            //    backend is not listening yet, so that first navigation
            //    typically fails; step 8 re-navigates to the dashboard once
            //    the readiness poll succeeds. The builder's result is bound so
            //    the post-readiness re-navigation targets this exact window.
            let window = tauri::WebviewWindowBuilder::new(
                app,
                "main",
                tauri::WebviewUrl::External(url.parse()?),
            )
            .title("Genesis Dashboard")
            .inner_size(1280.0, 800.0)
            .resizable(true)
            .center()
            .build()?;

            // 6. Block until the Phoenix backend responds. The poll runs on a
            //    dedicated OS thread because reqwest's blocking client must not be
            //    driven from inside an async runtime context (which is live here).
            let poll_url = url.clone();
            let poll = std::thread::spawn(move || {
                sidecar::wait_for_ready(&poll_url, BACKEND_READY_TIMEOUT_SECS);
            });
            let _ = poll.join();

            // 7. If the initial boot never became ready, kill the child: the
            //    watchdog sees the unexpected exit and takes over with the
            //    error page + restart cycle (the final probe avoids killing a
            //    backend that became ready just as the poll timed out). The
            //    final probe is the single source of truth for ready-ness.
            if sidecar::probe_http(&url).is_none() {
                eprintln!(
                    "[desktop] initial backend boot did not become ready — handing over to the watchdog"
                );
                manager.kill_current_child();
            } else {
                // 8. Backend is ready — make sure the webview actually shows
                //    the dashboard. Its initial load (step 5) raced the boot
                //    and failed with connection refused; NOTHING re-navigates
                //    on the healthy path (the watchdog only navigates after an
                //    unexpected exit), so without this a healthy boot sat on
                //    the failed-load page forever — and with it the
                //    dashboard's `quit-requested` listener never loaded, which
                //    wedged the tray Quit confirmation flow. Retry the
                //    navigation on a bounded schedule: the webview may still
                //    be initializing right after creation, so navigation can
                //    fail transiently. Stop early on success or when a
                //    quit/update intent is requested (the backend is going
                //    away — don't navigate during shutdown). Never-ready
                //    boots are handled above by the watchdog's recovery path
                //    (`show_backend`).
                match navigate_after_ready(
                    || backend_watchdog::navigate_webview(&window, &url),
                    || manager.shutdown_requested() || manager.update_requested(),
                    INITIAL_NAVIGATE_ATTEMPTS,
                    std::time::Duration::from_millis(INITIAL_NAVIGATE_RETRY_MS),
                ) {
                    InitialNavigateOutcome::Navigated => eprintln!(
                        "[desktop] navigated webview to the dashboard after the readiness poll"
                    ),
                    // Quit/update began — the shutdown machinery takes over.
                    InitialNavigateOutcome::Aborted => {}
                    InitialNavigateOutcome::Failed => eprintln!(
                        "[desktop] webview did not accept the navigation after {INITIAL_NAVIGATE_ATTEMPTS} attempts — the watchdog will retry on the next backend recovery"
                    ),
                }
            }

            // 9. Self-healing dashboard keeper. The step-8 navigation is a
            //    one-shot whose success is reported unconditionally (the
            //    webkitgtk/wkwebview load APIs accept the load without
            //    proving it rendered), so a silently-failed load leaves the
            //    webview on the connection-refused page forever — no
            //    LiveSocket, no `quit-requested` listener, unquittable app.
            //    This thread re-navigates whenever the backend is healthy,
            //    the main window is visible, and the dashboard has NOT
            //    signaled liveness (the `dashboard_ready` command heartbeat —
            //    refreshed at mount, on socket reconnect, on `quit-requested`,
            //    and every ~5s while the hook is mounted, so an idle-but-live
            //    page never goes stale) within DASHBOARD_HEARTBEAT_FRESH_MS,
            //    throttled by a 15s cooldown so a page that is still loading
            //    is not reloaded before its socket joins. It never fights the
            //    watchdog: while the backend is down the probe fails and
            //    nothing is navigated; it stops entirely on quit/update
            //    intent.
            let keeper_app = app.handle().clone();
            let keeper_manager = manager.clone();
            std::thread::spawn(move || {
                let mut last_navigate_ms: i64 = 0;
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(
                        KEEPER_POLL_INTERVAL_MS,
                    ));
                    let quitting = keeper_manager.shutdown_requested()
                        || keeper_manager.update_requested();
                    if quitting {
                        return; // quit/update owns the exit — never navigate during shutdown
                    }
                    let now = now_ms();
                    let backend_up =
                        sidecar::probe_http(keeper_manager.backend_url()).is_some();
                    // Best-effort visibility: an error or a missing window
                    // defaults to visible (navigate) rather than hidden.
                    let visible = keeper_app
                        .get_webview_window("main")
                        .map(|window| window.is_visible().unwrap_or(true))
                        .unwrap_or(true);
                    let heartbeat_fresh = keeper_manager
                        .dashboard_heartbeat_fresh(now, DASHBOARD_HEARTBEAT_FRESH_MS);
                    let cooldown_elapsed =
                        now - last_navigate_ms >= KEEPER_NAVIGATE_COOLDOWN_MS;
                    if keeper_should_navigate(
                        backend_up,
                        visible,
                        heartbeat_fresh,
                        cooldown_elapsed,
                        quitting,
                    ) {
                        // Resolve the window per iteration (the watchdog's
                        // pattern) — do not capture a WebviewWindow across
                        // threads.
                        if let Some(window) = keeper_app.get_webview_window("main") {
                            backend_watchdog::navigate_webview(
                                &window,
                                keeper_manager.backend_url(),
                            );
                            last_navigate_ms = now_ms();
                        }
                    }
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            // When the user closes the window, hide it to the system tray instead
            // of destroying it. The backend keeps running in the background. The
            // user can fully exit via the tray icon's "Quit" menu item.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// ---------------------------------------------------------------------------
// Post-readiness navigation (healthy-boot webview fix)
// ---------------------------------------------------------------------------

/// Outcome of the bounded post-readiness navigation retry
/// ([`navigate_after_ready`]).
#[derive(Debug, PartialEq, Eq)]
enum InitialNavigateOutcome {
    /// The webview accepted the navigation to the dashboard.
    Navigated,
    /// A quit/update intent was requested before the webview accepted it.
    Aborted,
    /// The webview never accepted the navigation within the attempt budget.
    Failed,
}

/// Bounded navigation retry used after the initial readiness poll (step 8 of
/// the GUI setup): calls `navigate` up to `max_attempts` times with
/// `retry_delay` between tries, stopping early once `navigate` succeeds or
/// `abort` (a quit/update intent) becomes true. Pure with injected closures
/// so the retry semantics are unit-testable without a tauri window.
fn navigate_after_ready(
    mut navigate: impl FnMut() -> bool,
    mut abort: impl FnMut() -> bool,
    max_attempts: u32,
    retry_delay: std::time::Duration,
) -> InitialNavigateOutcome {
    for _ in 0..max_attempts {
        if abort() {
            return InitialNavigateOutcome::Aborted;
        }
        if navigate() {
            return InitialNavigateOutcome::Navigated;
        }
        std::thread::sleep(retry_delay);
    }
    InitialNavigateOutcome::Failed
}

/// Current unix-epoch time in milliseconds (wall clock). Used by the keeper
/// thread for the heartbeat-freshness window and the navigation cooldown.
fn now_ms() -> i64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        Err(_) => 0,
    }
}

/// Pure keeper decision: re-navigate the webview only when the backend is
/// healthy, the main window is visible, the dashboard has NOT signaled
/// liveness within the freshness window, the navigation cooldown has
/// elapsed, and no quit/update intent is pending. All inputs are injected
/// so the truth table is unit-testable without a tauri window.
fn keeper_should_navigate(
    backend_up: bool,
    visible: bool,
    heartbeat_fresh: bool,
    cooldown_elapsed: bool,
    quitting: bool,
) -> bool {
    !quitting && backend_up && visible && !heartbeat_fresh && cooldown_elapsed
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--headless") {
        run_headless();
    } else {
        run_gui();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::time::Duration;

    /// `pick_free_port` returns a port > 0 that can be bound again.
    #[test]
    fn pick_free_port_returns_a_bindable_port() {
        let port = pick_free_port();
        assert!(port > 0);
        assert!(
            std::net::TcpListener::bind(("127.0.0.1", port)).is_ok(),
            "returned port {port} must be bindable again"
        );
    }

    /// No PORT value → a fresh free port is picked.
    #[test]
    fn resolve_backend_port_from_none_picks_a_free_port() {
        let port = resolve_backend_port_from(None);
        assert!(port > 0);
        assert!(std::net::TcpListener::bind(("127.0.0.1", port)).is_ok());
    }

    /// An OCCUPIED PORT must never be reused — the anti-crash guarantee.
    #[test]
    fn resolve_backend_port_from_occupied_port_picks_a_different_port() {
        // Hold a listener on a real port; the resolver must not reuse it.
        let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let occupied_port = occupied.local_addr().unwrap().port();
        let port = resolve_backend_port_from(Some(&occupied_port.to_string()));
        assert!(port > 0);
        assert_ne!(port, occupied_port, "occupied port must not be reused");
        assert!(std::net::TcpListener::bind(("127.0.0.1", port)).is_ok());
    }

    /// A valid, free PORT value is honored exactly.
    #[test]
    fn resolve_backend_port_from_free_port_uses_it() {
        let port = pick_free_port();
        let resolved = resolve_backend_port_from(Some(&port.to_string()));
        assert_eq!(resolved, port);
    }

    /// An unparseable PORT value → a fresh free port.
    #[test]
    fn resolve_backend_port_from_garbage_picks_a_free_port() {
        let port = resolve_backend_port_from(Some("not_a_number"));
        assert!(port > 0);
        assert!(std::net::TcpListener::bind(("127.0.0.1", port)).is_ok());
    }

    /// The GUI sidecar env carries the resolved PORT and the lifetime pipe
    /// port, and never carries the parent pid.
    #[test]
    fn sidecar_env_contains_port_and_lifetime_port() {
        let env: std::collections::HashMap<_, _> =
            sidecar::sidecar_env(4242, Some(9999)).into_iter().collect();
        assert_eq!(env.get("PORT").map(String::as_str), Some("4242"));
        assert_eq!(
            env.get("EVOGIT_LIFETIME_PORT").map(String::as_str),
            Some("9999")
        );
        assert!(
            !env.contains_key("EVOGIT_PARENT_PID"),
            "EVOGIT_PARENT_PID must be absent"
        );
    }

    /// With no lifetime pipe available (listener bind failure), the variable
    /// is omitted entirely — the backend's monitor stays off.
    #[test]
    fn sidecar_env_omits_lifetime_port_when_unavailable() {
        let env: std::collections::HashMap<_, _> =
            sidecar::sidecar_env(4242, None).into_iter().collect();
        assert_eq!(env.get("PORT").map(String::as_str), Some("4242"));
        assert!(
            !env.contains_key("EVOGIT_LIFETIME_PORT"),
            "EVOGIT_LIFETIME_PORT must be absent when None"
        );
        assert!(!env.contains_key("EVOGIT_PARENT_PID"));
    }

    /// The headless sidecar env carries the resolved PORT and the lifetime
    /// pipe port, and never carries the parent pid.
    #[test]
    fn headless_sidecar_env_contains_port_and_lifetime_port() {
        let env: std::collections::HashMap<_, _> =
            headless_sidecar_env(8080, Some(7777)).into_iter().collect();
        assert_eq!(env.get("PORT").map(String::as_str), Some("8080"));
        assert_eq!(
            env.get("EVOGIT_LIFETIME_PORT").map(String::as_str),
            Some("7777")
        );
        assert!(
            !env.contains_key("EVOGIT_PARENT_PID"),
            "EVOGIT_PARENT_PID must be absent"
        );
    }

    /// `start_lifetime_listener` returns a connectable port, and a connected
    /// client stays held open (the shell never writes): a read on the client
    /// must block (WouldBlock / TimedOut), NOT hit EOF (Ok(0)) and NOT get a
    /// reset/abort.
    #[test]
    fn start_lifetime_listener_holds_client_connection_open() {
        let port = sidecar::start_lifetime_listener().expect("lifetime listener must bind");
        assert!(port > 0);

        let mut client = std::net::TcpStream::connect(("127.0.0.1", port))
            .expect("client must connect to the lifetime listener");
        client
            .set_read_timeout(Some(Duration::from_millis(200)))
            .expect("read timeout must be settable");

        let mut buf = [0u8; 16];
        match client.read(&mut buf) {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
            other => panic!("expected a blocked read, got {other:?}"),
        }
    }

    /// After the first client disconnects, a SECOND client still gets held —
    /// the accept loop keeps accepting new connections (the watchdog-respawn
    /// property: every backend respawn reconnects and is held).
    #[test]
    fn lifetime_listener_accepts_second_client_after_first_disconnects() {
        let port = sidecar::start_lifetime_listener().expect("lifetime listener must bind");

        let mut first =
            std::net::TcpStream::connect(("127.0.0.1", port)).expect("first client must connect");
        first
            .set_read_timeout(Some(Duration::from_millis(200)))
            .expect("read timeout must be settable");
        let mut buf = [0u8; 16];
        match first.read(&mut buf) {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
            other => panic!("expected a blocked read on first client, got {other:?}"),
        }
        drop(first);

        let mut second = std::net::TcpStream::connect(("127.0.0.1", port))
            .expect("second client must connect after the first dropped");
        second
            .set_read_timeout(Some(Duration::from_millis(200)))
            .expect("read timeout must be settable");
        match second.read(&mut buf) {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
            other => panic!("expected a blocked read on second client, got {other:?}"),
        }
    }

    /// `navigate_after_ready` stops at the first successful navigation.
    #[test]
    fn navigate_after_ready_stops_on_first_success() {
        let calls = std::cell::Cell::new(0u32);
        let outcome = navigate_after_ready(
            || {
                calls.set(calls.get() + 1);
                calls.get() == 2 // the webview accepts on the second attempt
            },
            || false,
            10,
            Duration::from_millis(1),
        );
        assert_eq!(outcome, InitialNavigateOutcome::Navigated);
        assert_eq!(
            calls.get(),
            2,
            "navigation must stop after the first success"
        );
    }

    /// `navigate_after_ready` gives up after the attempt budget when the
    /// webview never accepts the navigation.
    #[test]
    fn navigate_after_ready_gives_up_after_max_attempts() {
        let calls = std::cell::Cell::new(0u32);
        let outcome = navigate_after_ready(
            || {
                calls.set(calls.get() + 1);
                false
            },
            || false,
            5,
            Duration::from_millis(1),
        );
        assert_eq!(outcome, InitialNavigateOutcome::Failed);
        assert_eq!(calls.get(), 5, "must not exceed the attempt budget");
    }

    /// `navigate_after_ready` aborts (without further navigation) as soon as
    /// a quit/update intent is requested.
    #[test]
    fn navigate_after_ready_aborts_on_quit_or_update_intent() {
        let calls = std::cell::Cell::new(0u32);
        let outcome = navigate_after_ready(
            || {
                calls.set(calls.get() + 1);
                false
            },
            || calls.get() >= 1, // intent requested before the second attempt
            10,
            Duration::from_millis(1),
        );
        assert_eq!(outcome, InitialNavigateOutcome::Aborted);
        assert_eq!(calls.get(), 1, "must not navigate once the intent is set");
    }

    /// `keeper_should_navigate` navigates only when ALL five conditions hold:
    /// backend up, window visible, heartbeat stale, cooldown elapsed, not
    /// quitting. Each input alone flips the decision.
    #[test]
    fn keeper_should_navigate_truth_table() {
        // The one navigating combination.
        assert!(keeper_should_navigate(true, true, false, true, false));

        // Every input alone flips the decision.
        assert!(!keeper_should_navigate(false, true, false, true, false)); // backend down
        assert!(!keeper_should_navigate(true, false, false, true, false)); // window hidden
        assert!(!keeper_should_navigate(true, true, true, true, false)); // heartbeat fresh
        assert!(!keeper_should_navigate(true, true, false, false, false)); // cooldown active
        assert!(!keeper_should_navigate(true, true, false, true, true)); // quitting

        // All-negative inputs → no navigation.
        assert!(!keeper_should_navigate(false, false, true, false, true));
    }

    /// `parse_feed_info` extracts version/notes/pub_date from a valid feed.
    #[test]
    fn parse_feed_info_extracts_version_notes_and_date() {
        let info = parse_feed_info(
            r#"{"version":"0.10.10","notes":"Release notes","pub_date":"2026-08-17T12:00:00Z","platforms":{"darwin-aarch64":{"url":"https://example.com/app.tar.gz","signature":"sig"}}}"#,
        )
        .expect("valid feed must parse");
        assert_eq!(info.version, "0.10.10");
        assert_eq!(info.body.as_deref(), Some("Release notes"));
        assert_eq!(info.date.as_deref(), Some("2026-08-17T12:00:00Z"));
    }

    /// A leading `v` in the feed version is trimmed, mirroring the plugin.
    #[test]
    fn parse_feed_info_trims_leading_v() {
        let info = parse_feed_info(r#"{"version":"v0.10.10","platforms":{}}"#)
            .expect("feed with leading-v version must parse");
        assert_eq!(info.version, "0.10.10");
    }

    /// `notes` is optional — it maps to `None` when absent.
    #[test]
    fn parse_feed_info_missing_notes_is_none() {
        let info = parse_feed_info(r#"{"version":"0.10.10","pub_date":"2026-08-17T12:00:00Z"}"#)
            .expect("feed without notes must parse");
        assert_eq!(info.body, None);
        assert_eq!(info.date.as_deref(), Some("2026-08-17T12:00:00Z"));
    }

    /// `pub_date` is optional — it maps to `None` when absent.
    #[test]
    fn parse_feed_info_missing_pub_date_is_none() {
        let info = parse_feed_info(r#"{"version":"0.10.10","notes":"notes"}"#)
            .expect("feed without pub_date must parse");
        assert_eq!(info.date, None);
        assert_eq!(info.body.as_deref(), Some("notes"));
    }

    /// Malformed JSON is not a parseable feed.
    #[test]
    fn parse_feed_info_malformed_json_is_none() {
        assert!(parse_feed_info("not json {").is_none());
    }

    /// A missing `version` key is not a parseable feed.
    #[test]
    fn parse_feed_info_missing_version_is_none() {
        assert!(parse_feed_info(r#"{"notes":"n","platforms":{}}"#).is_none());
    }

    /// A non-string `version` is not a parseable feed.
    #[test]
    fn parse_feed_info_non_string_version_is_none() {
        assert!(parse_feed_info(r#"{"version":123}"#).is_none());
    }

    /// A version that is not semver-shaped (e.g. a free-text tag) is not a
    /// parseable feed.
    #[test]
    fn parse_feed_info_garbage_version_is_none() {
        assert!(parse_feed_info(r#"{"version":"latest"}"#).is_none());
        assert!(parse_feed_info(r#"{"version":"0.10.10.1"}"#).is_none());
        assert!(parse_feed_info(r#"{"version":""}"#).is_none());
    }

    /// `is_version_shaped` truth table: `major.minor.patch` (with optional
    /// `-prerelease` / `+build` suffixes) is accepted; anything else is not.
    #[test]
    fn is_version_shaped_truth_table() {
        assert!(is_version_shaped("0.10.10"));
        assert!(is_version_shaped("1.2.3"));
        assert!(is_version_shaped("0.10.10-rc.1"));
        assert!(is_version_shaped("0.10.10+build5"));
        assert!(!is_version_shaped(""));
        assert!(!is_version_shaped("latest"));
        assert!(!is_version_shaped("1.2"));
        assert!(!is_version_shaped("1.2.3.4"));
        assert!(!is_version_shaped("1..3"));
        assert!(!is_version_shaped("1.2.x"));
    }
}
