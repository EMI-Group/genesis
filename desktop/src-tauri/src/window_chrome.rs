//! App-drawn ("frameless") window chrome for the Genesis dashboard.
//!
//! Platform matrix — deliberately two different mechanisms, because the two
//! platforms let us draw our own title bar in fundamentally different ways:
//!
//! - **Windows / Linux**: the window toggles [`tauri::WebviewWindow::set_decorations`]
//!   at RUNTIME. It is frameless while the dashboard is loaded (the dashboard's
//!   own top bar becomes the drag strip — see [`install_drag_strip`]) and native
//!   again while a shell-rendered `data:` page (loading / error / startup) is
//!   showing, because those pages cannot host a drag region at all (a `data:`
//!   origin classifies as `Origin::Remote` and matches no `remote.urls` pattern,
//!   so `plugin:window|start_dragging` is ACL-rejected; keeping the OS title bar
//!   on those pages also keeps them movable on every platform).
//! - **macOS**: decorations are NEVER toggled. The window is built once with a
//!   permanent overlay title bar (`TitleBarStyle::Overlay` + `hidden_title(true)`
//!   + a traffic-light inset — see the builder chain in `main.rs`), which keeps
//!   the native traffic lights floating over the HTML-drawn top bar, so
//!   [`apply`] is a no-op there.
//!
//! The chrome follows the CONTENT, never a timer: a finished dashboard load
//! (the `on_page_load` hook's `PageLoadEvent::Finished` + `url_is_backend`
//! branch) is the only signal that turns the frameless chrome ON, and every
//! navigation to a shell page turns it back OFF. That rule is self-healing —
//! after a backend crash the error page restores the OS title bar, and the
//! recovery reload of the dashboard turns frameless chrome back on.

/// Which chrome the shell wants for the page it is navigating to.
///
/// [`ChromeState::Shell`] = a shell-rendered `data:` page (loading / error /
/// startup) — native, OS-drawn chrome. [`ChromeState::Dashboard`] = the real
/// dashboard — app-drawn, frameless chrome.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ChromeState {
    Shell,
    Dashboard,
}

#[cfg(not(target_os = "macos"))]
impl ChromeState {
    /// The value recorded in [`LAST`].
    fn code(self) -> u8 {
        match self {
            ChromeState::Shell => 0,
            ChromeState::Dashboard => 1,
        }
    }
}

/// The last chrome state this module applied. `2` is a "never applied yet"
/// sentinel that matches neither state, so the first call always sets the
/// decoration.
///
/// It backs up [`tauri::WebviewWindow::is_decorated`]: even when that query
/// errors, a repeated call with the same state is still a cheap no-op instead
/// of a redundant relayout.
#[cfg(not(target_os = "macos"))]
static LAST: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(2);

/// Applies `state` to `window`.
///
/// macOS: a NO-OP — the permanent overlay title bar is configured once in the
/// builder chain (`main.rs`), and the native traffic lights stay visible over
/// the dashboard's own top bar on every page.
///
/// Non-macOS: switches the window decorations to match `state` (native for
/// shell pages, frameless for the dashboard). Idempotent — the setter is
/// skipped (and nothing is logged) when the window already has the requested
/// chrome, so repeated calls never cause a relayout or a fake "transition" log
/// line. Callable from ANY thread: Tauri dispatches the window operation to the
/// event loop itself, so callers (page-load hooks, the watchdog's boot thread)
/// never have to touch the event loop directly.
#[cfg(target_os = "macos")]
pub fn apply(_window: &tauri::WebviewWindow, _state: ChromeState) {
    // Permanent overlay title bar: nothing to change at runtime.
}

#[cfg(not(target_os = "macos"))]
pub fn apply(window: &tauri::WebviewWindow, state: ChromeState) {
    use std::sync::atomic::Ordering;

    // Native chrome for shell pages (they cannot host a drag region);
    // frameless for the dashboard (its own top bar is the drag strip).
    let decorations = state == ChromeState::Shell;
    let label = if decorations {
        "native window chrome (OS title bar)"
    } else {
        "frameless window chrome (custom title bar)"
    };

    // Idempotence: a finished load can fire for several navigations, and a
    // redundant `set_decorations` re-runs the whole window relayout.
    let already_applied = match window.is_decorated() {
        Ok(current) => current == decorations,
        // The query failed — fall back to what we last applied. The `2`
        // sentinel matches neither state, so the first call still sets.
        Err(_) => LAST.load(Ordering::Relaxed) == state.code(),
    };
    if already_applied {
        LAST.store(state.code(), Ordering::Relaxed);
        return;
    }

    match window.set_decorations(decorations) {
        Ok(()) => {
            LAST.store(state.code(), Ordering::Relaxed);
            crate::shell_log::log(&format!("window chrome: switched to {label}"));
        }
        Err(err) => {
            // Keep going: the app stays usable with the chrome it has, and
            // the next navigation retries the switch.
            crate::shell_log::log(&format!(
                "window chrome: failed to switch to {label}: {err}"
            ));
        }
    }
}

/// The drag strip injected into the dashboard: marks its top bar as a Tauri
/// drag region so the frameless window can be moved by dragging that bar.
///
/// `"deep"` (rather than a bare attribute) is the right value here: Tauri's
/// injected document-level `mousedown` handler walks the event's composed path
/// and `"deep"` makes a click ANYWHERE inside the element's subtree start a
/// drag. Clickable descendants still block the drag (BUTTON / INPUT / A /
/// SELECT / TEXTAREA / LABEL / SUMMARY, `contenteditable`, a non-negative
/// `tabindex`, and the interactive ARIA roles: button, link, menuitem, tab,
/// checkbox, radio, switch, option), so the bar's buttons keep working while
/// the empty area around them drags the window.
///
/// The attribute is added AFTER page load on purpose: the handler is attached
/// to `document`, so it works on any element added or annotated at any time.
/// The long-term home for this attribute is the dashboard's own markup
/// (`apps/evo_dash`, a follow-up outside this node); until then the shell
/// injects it here.
const DRAG_STRIP_SCRIPT: &str = r#"
(function () {
  try {
    if (typeof document === 'undefined' || !document.querySelector) return false;
    if (document.querySelector('[data-tauri-drag-region]')) return false;
    var el = document.querySelector('header.workbench-top')
      || document.querySelector('header')
      || document.querySelector('[role="banner"]');
    if (!el) return false;
    el.setAttribute('data-tauri-drag-region', 'deep');
    return true;
  } catch (err) {
    return false;
  }
})()
"#;

/// Installs the dashboard drag strip (see [`DRAG_STRIP_SCRIPT`]) and logs the
/// outcome. Safe to call more than once: the script refuses to override an
/// existing drag region.
pub fn install_drag_strip(window: &tauri::WebviewWindow) {
    let evaluated = window.eval_with_callback(DRAG_STRIP_SCRIPT, |result| {
        if result.trim() == "true" {
            crate::shell_log::log(
                "window chrome: installed the dashboard drag strip \
                 (data-tauri-drag-region on the top bar)",
            );
        }
    });
    if let Err(err) = evaluated {
        crate::shell_log::log(&format!(
            "window chrome: failed to install the dashboard drag strip: {err}"
        ));
    }
}
