//! Custom Tauri commands exposed to the dashboard frontend.

#[cfg(not(target_os = "macos"))]
use tauri_plugin_dialog::{DialogExt, FilePath};

/// Pick a folder via the native dialog, returning the selected path — or
/// `None` if the user cancelled.
///
/// Platform behaviour:
/// - **macOS**: the plugin's non-blocking API presents NSOpenPanel as a
///   *sheet* attached to the window (`beginSheetModalForWindow:...`). When the
///   parent window isn't visible / the app isn't active (aggravated by the
///   desktop shell's close-to-tray behaviour), the sheet never appears and the
///   invoke hangs forever. rfd's blocking API (app-modal `runModal`) is the
///   right shape but still fails on macOS: it never *activates* the app, so
///   when the app is not the frontmost app the panel never presents as key and
///   `runModal` blocks forever. The macOS path therefore bypasses rfd entirely
///   and drives an `NSOpenPanel` directly on the main thread — see the
///   [`macos`] module for the full analysis.
/// - **Linux / Windows**: the plugin's blocking dialog works, so it is used
///   unchanged (on the blocking pool — never on the main/async thread).
#[tauri::command]
#[cfg_attr(not(target_os = "macos"), allow(unused_variables))]
pub async fn pick_directory(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
) -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        return macos::pick_directory(&app, &window).await;
    }

    #[cfg(not(target_os = "macos"))]
    {
        // The blocking dialog must not run on the main/async thread. Only the
        // app handle is moved into the closure — the window is handled by the
        // caller.
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
}

/// macOS implementation of [`pick_directory`].
///
/// # Why rfd cannot be used here (root cause)
///
/// The failing state: the window has been hidden to the system tray and/or the
/// app is no longer the frontmost (active) app. In that state:
///
/// 1. **App activation is never requested.** `tauri::AppHandle::set_activation_policy`
///    only changes the app's *policy* (dock visibility); it does **not**
///    activate the app (make it frontmost). rfd's macOS backend never activates
///    the app either — its `PolicyManager` merely flips a `Prohibited` policy
///    to `Accessory`, and the panel is raised to `CGShieldingWindowLevel`.
///    AppKit will not present a `runModal` panel as the key window of an
///    inactive app, so the panel never appears (or never takes key status) and
///    `runModal` blocks the main thread forever. The blocking-pool thread
///    waiting on rfd's `dispatch2::run_on_main` (`dispatch_sync` onto the main
///    queue) then blocks forever too, and the JS-side 15s timeout fires.
///
/// 2. **The plugin's async path is a dead end.** `pick_folder_async` presents
///    the panel via `beginSheetModalForWindow_completionHandler:` — a sheet
///    attached to the (possibly hidden) main window, which never appears in
///    the inactive/hidden state. So both JS fallback paths hang.
///
/// # The fix
///
/// Bypass rfd on macOS. On the main thread (via `AppHandle::run_on_main_thread`):
/// force the activation policy to `Regular`, activate the app
/// (`activateIgnoringOtherApps:YES` — deprecated in macOS 14 but still
/// functional on all supported versions), then present a plain app-modal
/// `NSOpenPanel` with `runModal` (NOT `beginSheetModalForWindow:...`). The
/// result travels back to the command over an `mpsc` channel. This keeps the
/// exact contract the frontend relies on: `Ok(Some(path))` on pick,
/// `Ok(None)` on user-cancel (quiet), `Err(String)` on real failure — and no
/// panic paths.
#[cfg(target_os = "macos")]
mod macos {
    use std::sync::mpsc;

    use objc2::rc::autoreleasepool;
    use objc2::MainThreadMarker;
    use objc2_app_kit::{
        NSApplication, NSApplicationActivationPolicy, NSModalResponseOK, NSOpenPanel,
    };

    pub(super) async fn pick_directory(
        app: &tauri::AppHandle,
        window: &tauri::WebviewWindow,
    ) -> Result<Option<String>, String> {
        // Bring the window forward first. Both calls are queued on the event
        // loop proxy and are processed (FIFO) before the panel task below.
        let _ = window.show();
        let _ = window.set_focus();

        // Activate the app and present the app-modal panel on the main thread.
        // The main thread then blocks inside `runModal` for as long as the
        // user interacts with the panel — the expected app-modal behaviour.
        let (tx, rx) = mpsc::channel::<Result<Option<String>, String>>();
        app.run_on_main_thread(move || {
            let _ = tx.send(present_open_panel());
        })
        .map_err(|e| e.to_string())?;

        // Wait for the panel result on the blocking pool — never block a
        // tokio worker thread. If the user cancels, `present_open_panel`
        // returns `Ok(None)`; the panel has no timeout, matching native UX.
        tauri::async_runtime::spawn_blocking(move || rx.recv().map_err(|e| e.to_string())?)
            .await
            .map_err(|e| e.to_string())?
    }

    /// Present the folder panel. **Must run on the main thread** (guaranteed
    /// by the `run_on_main_thread` caller).
    fn present_open_panel() -> Result<Option<String>, String> {
        autoreleasepool(|_| {
            let mtm = MainThreadMarker::new().ok_or_else(|| {
                "pick_directory: folder panel must run on the main thread".to_string()
            })?;

            // The app may have been demoted to inactive (window hidden to the
            // tray, another app frontmost). A `runModal` panel never presents
            // as key while the app is not the active app, and setting the
            // activation *policy* alone does not activate the app — force
            // activation explicitly.
            let nsapp = NSApplication::sharedApplication(mtm);
            nsapp.setActivationPolicy(NSApplicationActivationPolicy::Regular);
            #[allow(deprecated)] // deprecated in macOS 14, still works on all supported versions
            nsapp.activateIgnoringOtherApps(true);

            let panel = NSOpenPanel::openPanel(mtm);
            panel.setCanChooseDirectories(true);
            panel.setCanChooseFiles(false);
            panel.setAllowsMultipleSelection(false);
            panel.setCanCreateDirectories(true);

            // App-modal (`runModal`), NOT a sheet (`beginSheetModalForWindow:...`):
            // presents independently of any window and blocks until dismissed.
            let response = panel.runModal();
            if response != NSModalResponseOK {
                // User cancelled (or the panel failed to display).
                return Ok(None);
            }

            match panel.URLs().firstObject() {
                Some(url) => match url.path() {
                    Some(path) => Ok(Some(path.to_string())),
                    None => {
                        Err("pick_directory: selected folder has no filesystem path".to_string())
                    }
                },
                None => Ok(None),
            }
        })
    }
}
