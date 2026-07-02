// Prevents an additional console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::sync::Mutex;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, WindowEvent,
};
use tauri_plugin_shell::process::CommandChild;

mod sidecar;

/// Default port the Phoenix dashboard backend listens on.
const DEFAULT_PORT: u16 = 9999;
/// How long (in seconds) to wait for the backend to become ready.
const BACKEND_READY_TIMEOUT_SECS: u64 = 30;

/// Wraps the sidecar process handle so the window-event handler can take
/// ownership of it (and thereby call the consuming `CommandChild::kill`) when
/// the user quits via the tray. `None` once the sidecar has been terminated.
type SidecarHandle = Mutex<Option<CommandChild>>;

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

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // 1. Launch the Burrito-wrapped Phoenix backend as a sidecar process.
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
                                if let Some(child) = guard.take() {
                                    let _ = child.kill();
                                    println!("[desktop] evogit-backend sidecar terminated");
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
