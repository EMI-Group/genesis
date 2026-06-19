// Prevents an additional console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use tauri::Manager;
use tauri_plugin_shell::process::CommandChild;

mod sidecar;

/// The Phoenix dashboard backend listens here.
const BACKEND_URL: &str = "http://localhost:4100";
/// How long (in seconds) to wait for the backend to become ready.
const BACKEND_READY_TIMEOUT_SECS: u64 = 30;

/// Wraps the sidecar process handle so the window-event handler can take
/// ownership of it (and thereby call the consuming `CommandChild::kill`) when
/// the window closes. `None` once the sidecar has been terminated.
type SidecarHandle = Mutex<Option<CommandChild>>;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // 1. Launch the Burrito-wrapped Phoenix backend as a sidecar process.
            let child = sidecar::start(app)?;

            // 2. Keep the process handle in managed state so we can terminate the
            //    backend when the window closes.
            app.manage(SidecarHandle::new(Some(child)));

            // 3. Block until the Phoenix backend responds. The poll runs on a
            //    dedicated OS thread because reqwest's blocking client must not be
            //    driven from inside an async runtime context (which is live here).
            let poll = std::thread::spawn(|| {
                sidecar::wait_for_ready(BACKEND_URL, BACKEND_READY_TIMEOUT_SECS);
            });
            let _ = poll.join();

            Ok(())
        })
        .on_window_event(|window, event| {
            // When the window is destroyed, kill the sidecar and exit so we don't
            // leave an orphaned Phoenix process running in the background.
            if let tauri::WindowEvent::Destroyed = event {
                if let Some(handle) = window.app_handle().try_state::<SidecarHandle>() {
                    if let Ok(mut guard) = handle.lock() {
                        if let Some(child) = guard.take() {
                            let _ = child.kill();
                            println!("[desktop] evogit-backend sidecar terminated");
                        }
                    }
                }
                std::process::exit(0);
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
