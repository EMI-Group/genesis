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

/// Default port the Phoenix dashboard backend listens on.
const DEFAULT_PORT: u16 = 9999;
/// How long (in seconds) to wait for the backend to become ready.
const BACKEND_READY_TIMEOUT_SECS: u64 = 30;

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

/// `check_update` — asks the updater plugin whether a new version is available.
///
/// JSON contract (all keys always present):
/// `{"status", "current_version", "version", "body", "date", "error"}` where
/// status ∈ `"up_to_date" | "available" | "not_configured" | "error"`.
#[tauri::command]
async fn check_update(app: tauri::AppHandle) -> serde_json::Value {
    if updater_pubkey_is_placeholder(configured_updater_pubkey(&app).as_deref()) {
        return json!({
            "status": "not_configured",
            "current_version": null,
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
            return json!({
                "status": "error",
                "current_version": null,
                "version": null,
                "body": null,
                "date": null,
                "error": format!("Update check failed: {err}"),
            });
        }
    };

    match updater.check().await {
        Err(err) => json!({
            "status": "error",
            "current_version": null,
            "version": null,
            "body": null,
            "date": null,
            "error": format!("Update check failed: {err}"),
        }),
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

/// Returns the port the Phoenix backend listens on.
///
/// Reads the `PORT` environment variable if set, otherwise defaults to
/// [`DEFAULT_PORT`] (9999). The WebView always connects via `localhost` since
/// it runs on the same machine.
fn backend_port() -> u16 {
    std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT)
}

/// Builds the backend URL the WebView will connect to.
///
/// Always uses `localhost` regardless of the bind address, because the
/// WebView is local.
fn backend_url() -> String {
    format!("http://localhost:{}", backend_port())
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
/// [`sidecar::sidecar_env`].
fn headless_sidecar_env() -> Vec<(String, String)> {
    let phx_ip = std::env::var("EVOGIT_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("PORT").unwrap_or_else(|_| DEFAULT_PORT.to_string());

    vec![
        ("PORT".to_string(), port),
        ("PHX_IP".to_string(), phx_ip),
        ("PHX_SERVER".to_string(), "true".to_string()),
        (
            "SECRET_KEY_BASE".to_string(),
            "GenesisDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890".to_string(),
        ),
        ("RELEASE_DISTRIBUTION".to_string(), "none".to_string()),
        ("EVOGIT_DESKTOP".to_string(), "1".to_string()),
    ]
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

    let sidecar_path = resolve_sidecar_path().unwrap_or_else(|msg| {
        eprintln!("[desktop] {msg}");
        std::process::exit(1);
    });

    let mut child = sidecar::launcher_command(&sidecar_path)
        .arg("start")
        .envs(headless_sidecar_env())
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
    let url = format!("http://localhost:{}", backend_port());
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
            check_update,
            download_update,
            begin_update
        ])
        .setup(|app| {
            // 1. Resolve the launcher path once and build the backend
            //    environment. A broken install (missing launcher) stays fatal.
            let launcher = sidecar::launcher_path(app)?;
            let env = sidecar::sidecar_env();
            let port = backend_port();
            let url = backend_url();

            // 2. Create the backend manager and spawn the initial child. A
            //    spawn failure is NOT fatal: the watchdog treats the missing
            //    child as a failure and drives the error page + restart cycle.
            let manager: BackendHandle = Arc::new(BackendManager::new(
                launcher,
                env,
                port,
                url,
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
                        // page: emit `quit-requested` and do NOTHING else. The
                        // dashboard shows its confirm modal; on confirmation
                        // its JS invokes the `begin_quit` command (sets the
                        // intentional-shutdown flag, no kill) and the backend
                        // stops itself gracefully. `backend_url()` is called
                        // inside the handler because `on_menu_event` requires
                        // a `'static` closure, so nothing may be captured.
                        if sidecar::probe_http(&backend_url()).is_some() {
                            let _ = app.emit("quit-requested", ());
                            return;
                        }
                        // Backend down — the WebView shows the watchdog error
                        // page, so no dashboard dialog could appear. Keep the
                        // old immediate path: flag an intentional shutdown
                        // BEFORE killing the child, so the watchdog never
                        // restarts the backend after a quit has begun.
                        if let Some(manager) = app.try_state::<BackendHandle>() {
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

            // 5. Block until the Phoenix backend responds. The poll runs on a
            //    dedicated OS thread because reqwest's blocking client must not be
            //    driven from inside an async runtime context (which is live here).
            let url = backend_url();
            let poll_url = url.clone();
            let poll = std::thread::spawn(move || {
                sidecar::wait_for_ready(&poll_url, BACKEND_READY_TIMEOUT_SECS);
            });
            let _ = poll.join();

            // 6. If the initial boot never became ready, kill the child: the
            //    watchdog sees the unexpected exit and takes over with the
            //    error page + restart cycle (the final probe avoids killing a
            //    backend that became ready just as the poll timed out).
            if sidecar::probe_http(&url).is_none() {
                eprintln!(
                    "[desktop] initial backend boot did not become ready — handing over to the watchdog"
                );
                manager.kill_current_child();
            }

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

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--headless") {
        run_headless();
    } else {
        run_gui();
    }
}
