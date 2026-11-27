//! Window chrome for the Genesis dashboard.
//!
//! **Ownership rule — native OS chrome is the DEFAULT.** The shell builds the
//! window with `.decorations(true)` and must NEVER remove the decorations on
//! its own initiative. Frameless (app-drawn) chrome is ONLY ever entered on an
//! EXPLICIT, dashboard-requested state: the dashboard's JavaScript invokes the
//! `set_custom_titlebar` command with `active: true` after verifying its own
//! `#desktop-titlebar` strip exists in the DOM and its window controls are
//! bound, and the shell then applies [`ChromeState::Dashboard`]. Native chrome
//! is restored on every navigation START (`PageLoadEvent::Started` — reloads,
//! shell-rendered `data:` pages, crash recovery) and on an explicit
//! `set_custom_titlebar(active: false)`.
//!
//! **The failure mode of this rule is SAFE:** an older or broken dashboard that
//! never asks for frameless chrome simply keeps the native OS title bar, so the
//! window stays movable / minimizable / closable. The shell must never create
//! the frameless state on its own initiative precisely because the dashboard
//! strip is then the ONLY title bar.
//!
//! Platform matrix — two different mechanisms, because the two platforms let us
//! draw our own title bar in fundamentally different ways:
//!
//! - **Windows / Linux**: the window toggles [`tauri::WebviewWindow::set_decorations`]
//!   at RUNTIME. It is frameless only while the dashboard has explicitly asked
//!   for it (the dashboard renders its own `#desktop-titlebar` strip, carrying
//!   `data-tauri-drag-region` on the strip root and on its drag spacer — that
//!   markup is owned by the dashboard app and only rendered in desktop mode)
//!   and native again while a shell-rendered `data:` page (loading / error /
//!   startup) or any just-started navigation is showing, because those pages
//!   cannot host a drag region at all (a `data:` origin classifies as
//!   `Origin::Remote` and matches no `remote.urls` pattern, so
//!   `plugin:window|start_dragging` is ACL-rejected; keeping the OS title bar on
//!   those pages also keeps them movable on every platform).
//! - **macOS**: decorations are NEVER toggled. The window is built once with a
//!   permanent overlay title bar (`TitleBarStyle::Overlay` + `hidden_title(true)`
//!   + a traffic-light inset — see the builder chain in `main.rs`), which keeps
//!   the native traffic lights floating over the dashboard's own `#desktop-titlebar`
//!   strip, so [`apply`] is a no-op there.
//!
//! The shell never injects a drag region into the dashboard: the dashboard
//! renders its own `#desktop-titlebar` strip in desktop mode, carrying
//! `data-tauri-drag-region` on the strip root and on its drag spacer. The shell
//! only toggles decorations and grants the `core:window:allow-*` permissions
//! (`capabilities/default.json`) that make that strip work.
//!
//! The chrome still follows the CONTENT, never a timer: a navigation START
//! restores native chrome, and framing comes back only when the freshly loaded
//! dashboard asks for it. That rule is self-healing — after a backend crash the
//! error page (and the recovery reload's navigation start) leaves the OS title
//! bar in place until the reloaded dashboard requests frameless chrome again.

/// Which chrome the shell wants for the page it is showing.
///
/// [`ChromeState::Shell`] = native, OS-drawn chrome (the DEFAULT — shell-rendered
/// `data:` pages, every navigation start, and any dashboard that did not request
/// frameless chrome). [`ChromeState::Dashboard`] = app-drawn, frameless chrome —
/// reached ONLY through an explicit `set_custom_titlebar(active: true)` request
/// from the dashboard.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ChromeState {
    Shell,
    Dashboard,
}

impl ChromeState {
    /// The window decorations this state wants: `true` = native OS title bar.
    pub const fn decorations(self) -> bool {
        desired_decorations(matches!(self, ChromeState::Dashboard))
    }

    /// The value recorded in [`LAST`].
    pub const fn code(self) -> u8 {
        match self {
            ChromeState::Shell => 0,
            ChromeState::Dashboard => 1,
        }
    }
}

/// The window decorations the shell wants for the dashboard-requested frameless
/// flag: native by DEFAULT, frameless only when the dashboard explicitly asked.
///
/// Pure and platform-agnostic so the ownership rule is pinned by tests on every
/// platform (including macOS, where the toggle is a no-op).
pub const fn desired_decorations(active: bool) -> bool {
    !active
}

/// Whether the window must be switched to `desired`, given its `current`
/// decoration state (`None` = the current state is unknown, e.g. the
/// `is_decorated()` query failed and nothing has been applied yet).
///
/// An unknown state always needs a switch, so the first call sets the
/// decoration; a known matching state never does, so repeated page-load
/// callbacks never relayout.
pub const fn needs_switch(desired: bool, current: Option<bool>) -> bool {
    match current {
        Some(c) => c != desired,
        None => true,
    }
}

/// The last chrome state this module applied. `2` is a "never applied yet"
/// sentinel that matches neither state, so the first call always sets the
/// decoration.
///
/// It backs up [`tauri::WebviewWindow::is_decorated`]: even when that query
/// errors, a repeated call with the same state is still a cheap no-op instead
/// of a redundant relayout.
static LAST: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(2);

/// The [`ChromeState`] recorded in [`LAST`], or `None` before the first apply
/// (the `2` sentinel).
fn last_applied() -> Option<ChromeState> {
    match LAST.load(std::sync::atomic::Ordering::Relaxed) {
        0 => Some(ChromeState::Shell),
        1 => Some(ChromeState::Dashboard),
        _ => None,
    }
}

/// Applies `state` to `window`.
///
/// macOS: a NO-OP — the permanent overlay title bar is configured once in the
/// builder chain (`main.rs`), and the native traffic lights stay visible over
/// the dashboard's own top bar on every page.
///
/// Non-macOS: switches the window decorations to match `state` (native is the
/// default, frameless only on the dashboard's explicit request). Idempotent —
/// the setter is skipped (and nothing is logged) when the window already has
/// the requested chrome, so repeated calls never cause a relayout or a fake
/// "transition" log line. Callable from ANY thread: Tauri dispatches the window
/// operation to the event loop itself, so callers (page-load hooks, the
/// `set_custom_titlebar` command, the watchdog's boot thread) never have to
/// touch the event loop directly.
pub fn apply(window: &tauri::WebviewWindow, state: ChromeState) {
    let decorations = state.decorations();
    let label = if decorations {
        "native window chrome (OS title bar)"
    } else {
        "frameless window chrome (custom title bar)"
    };

    // Idempotence: a finished load can fire for several navigations, and a
    // redundant `set_decorations` re-runs the whole window relayout.
    let current = match window.is_decorated() {
        Ok(current) => Some(current),
        // The query failed — fall back to what we last applied. The `2`
        // sentinel yields `None`, so the first call still sets.
        Err(_) => last_applied().map(ChromeState::decorations),
    };
    let already_applied = !needs_switch(decorations, current);
    if already_applied {
        LAST.store(state.code(), std::sync::atomic::Ordering::Relaxed);
    }

    #[cfg(target_os = "macos")]
    {
        // Permanent overlay title bar: nothing to change at runtime. The
        // decision computed above is deliberately discarded (keeping the pure
        // helpers used and warning-free on macOS too).
        let _ = (decorations, label);
    }

    #[cfg(not(target_os = "macos"))]
    {
        if already_applied {
            return;
        }

        match window.set_decorations(decorations) {
            Ok(()) => {
                LAST.store(state.code(), std::sync::atomic::Ordering::Relaxed);
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
}

#[cfg(test)]
mod tests {
    use super::{desired_decorations, needs_switch, ChromeState};

    #[test]
    fn native_decorations_are_the_default() {
        // No dashboard request (the default) ⇒ native OS chrome.
        assert!(desired_decorations(false));
        assert!(ChromeState::Shell.decorations());
    }

    #[test]
    fn frameless_only_on_an_explicit_dashboard_request() {
        assert!(!desired_decorations(true));
        assert!(!ChromeState::Dashboard.decorations());
    }

    #[test]
    fn unknown_state_always_needs_a_switch() {
        // The first call must always set the decoration.
        assert!(needs_switch(true, None));
        assert!(needs_switch(false, None));
    }

    #[test]
    fn matching_state_never_needs_a_switch() {
        // Idempotent: repeated calls with the same chrome must be no-ops.
        assert!(!needs_switch(true, Some(true)));
        assert!(!needs_switch(false, Some(false)));
        assert!(needs_switch(true, Some(false)));
        assert!(needs_switch(false, Some(true)));
    }
}
