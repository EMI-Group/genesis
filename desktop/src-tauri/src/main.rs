// Prevents an additional console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::Child;
use std::sync::Mutex;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, WindowEvent,
};

mod sidecar;

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

/// Wraps the sidecar process handle so the window-event handler can take
/// ownership of it (and thereby call the consuming `Child::kill`) when
/// the user quits via the tray. `None` once the sidecar has been terminated.
type SidecarHandle = Mutex<Option<Child>>;

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
static SHUTDOWN_FLAG: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

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
fn resolve_sidecar_path() -> Result<std::path::PathBuf, String> {
    let launcher_rel = std::path::Path::new("resources")
        .join("genesis-backend")
        .join("bin")
        .join(LAUNCHER_NAME);

    // 1. Production: <exe_dir>/resources/genesis-backend/bin/<launcher>
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_default();
    let prod_path = exe_dir.join(&launcher_rel);
    if prod_path.exists() {
        return Ok(prod_path);
    }

    // 2. Development: <manifest_dir>/resources/genesis-backend/bin/<launcher>
    let dev_path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(&launcher_rel);
    if dev_path.exists() {
        return Ok(dev_path);
    }

    Err(format!(
        "release launcher '{LAUNCHER_NAME}' not found — looked in {:?} and {:?}",
        prod_path.parent().unwrap(),
        dev_path.parent().unwrap()
    ))
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
            "GenesisDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890"
                .to_string(),
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

    let mut child = std::process::Command::new(&sidecar_path)
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
// GUI mode (existing behaviour — unchanged)
// ---------------------------------------------------------------------------

fn run_gui() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // 1. Launch the Phoenix backend via the Elixir release launcher
            //    script (`bin/genesis_desktop start`).
            let child = sidecar::start(app)?;

            // 2. Keep the process handle in managed state so we can terminate the
            //    backend when the user quits via the tray menu.
            app.manage(SidecarHandle::new(Some(child)));

            // 3. Build the system tray menu with "Show Window" and "Quit" items.
            let show_item = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_item, &quit_item])?;

            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .tooltip("Genesis")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "quit" => {
                        if let Some(handle) = app.try_state::<SidecarHandle>() {
                            if let Ok(mut guard) = handle.lock() {
                                if let Some(mut child) = guard.take() {
                                    let _ = child.kill();
                                    println!("[desktop] genesis-backend sidecar terminated");
                                }
                            }
                        }
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
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

            // 4. Block until the Phoenix backend responds. The poll runs on a
            //    dedicated OS thread because reqwest's blocking client must not be
            //    driven from inside an async runtime context (which is live here).
            let url = backend_url();
            let poll = std::thread::spawn(move || {
                sidecar::wait_for_ready(&url, BACKEND_READY_TIMEOUT_SECS);
            });
            let _ = poll.join();

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
