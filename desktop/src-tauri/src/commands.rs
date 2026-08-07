//! Custom Tauri commands exposed to the dashboard frontend.

use tauri_plugin_dialog::{DialogExt, FilePath};

/// Pick a folder via the native dialog, returning the selected path — or
/// `None` if the user cancelled.
///
/// This deliberately bypasses the macOS sheet hang: the plugin's non-blocking
/// API calls `set_parent`, which makes rfd present NSOpenPanel as a *sheet*
/// attached to the window. When the parent window isn't visible / the app
/// isn't active (aggravated by the desktop shell's close-to-tray behaviour),
/// the sheet never appears and the invoke hangs forever. Instead we use the
/// blocking API *without* a parent, so rfd falls back to an app-modal panel
/// that always presents.
#[tauri::command]
#[cfg_attr(not(target_os = "macos"), allow(unused_variables))]
pub async fn pick_directory(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
) -> Result<Option<String>, String> {
    // When the app was hidden to the system tray, macOS treats it as an
    // inactive accessory app. Force regular activation and bring the window
    // forward so the app-modal panel can present.
    #[cfg(target_os = "macos")]
    {
        app.set_activation_policy(tauri::ActivationPolicy::Regular)
            .map_err(|e| e.to_string())?;
        let _ = window.show();
        let _ = window.set_focus();
    }

    // The blocking dialog must not run on the main/async thread. Only the app
    // handle is moved into the closure — the window is handled above.
    let picked = tauri::async_runtime::spawn_blocking(move || {
        match app.dialog().file().blocking_pick_folder() {
            Some(FilePath::Path(p)) => Some(p.to_string_lossy().into_owned()),
            // Folders always come back as paths; treat an unexpected URL
            // result like a cancel.
            Some(FilePath::Url(_)) => None,
            None => None,
        }
    })
    .await
    .map_err(|e| e.to_string())?;

    Ok(picked)
}
