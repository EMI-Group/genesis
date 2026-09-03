//! Backend crash watchdog for the desktop shell.
//!
//! The Elixir backend (the `genesis_desktop` release launcher child process
//! spawned by the sidecar) can crash or exit unexpectedly at any time. When
//! that happens the WebView would be left on a blank or dead page with no
//! feedback, and once the backend comes back the WebView never auto-reloads.
//!
//! This module watches the child process and:
//!
//! 1. detects an unexpected exit (reaping the zombie via `try_wait`),
//! 2. shows a compact error page in the WebView ("backend unavailable — will
//!    be restarted automatically"),
//! 3. restarts the backend with exponential backoff ([`BACKOFF_SECS`], capped
//!    at 30s; after [`MAX_CONSECUTIVE_FAILURES`] consecutive failures it keeps
//!    retrying every 30s indefinitely — there is deliberately no terminal
//!    give-up state),
//! 4. once the backend serves requests again (TCP accepting + HTTP probe),
//!    navigates the WebView back to the dashboard (a full reload).
//!
//! A tray "Quit" no longer kills the child directly: it shows the window and
//! emits a `quit-requested` event so the dashboard can ask for confirmation in
//! the WebView. On confirmation the `begin_quit` Tauri command sets the
//! `intentional_shutdown` flag (no kill), the backend stops itself gracefully
//! (dashboard `System.stop()`), and the watchdog's shutdown path waits for the
//! child to exit (force-killing it if it hangs) before exiting the app. The
//! watchdog checks the flag at every stage and never restarts the backend
//! after a quit has begun. A clean `Some(0)` child exit is also treated as
//! intentional (the release backend only exits with code 0 on a deliberate
//! stop).
//!
//! Auto-update: the `begin_update` Tauri command sets a separate
//! `update_intent` flag (flag only, kills nothing, like `begin_quit`). When
//! the watchdog then observes an intentional child exit with the update flag
//! set, it does NOT exit the app: it runs the installer for the payload
//! stashed by the `download_update` command (a process-global slot, see
//! [`set_downloaded_update`]) and relaunches the new bundle. The update flag
//! suppresses the crash-restart loop at every stage, exactly like
//! `shutdown_requested()`, and the install only runs after the backend child
//! is confirmed dead (the same wait-then-kill used by the quit path).

use std::net::{SocketAddr, TcpStream};
#[cfg(not(windows))]
use std::path::Path;
use std::path::PathBuf;
use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager};

/// How often the monitor polls the child process for exit.
const MONITOR_INTERVAL: Duration = Duration::from_millis(100);
/// How often the readiness poll re-checks the backend.
const READY_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// How long a respawned backend has to come up before the attempt is
/// considered a failure.
const READY_TIMEOUT: Duration = Duration::from_secs(30);

/// How long the shutdown path waits for the child to exit on its own after a
/// graceful stop before force-killing it as a fallback.
const SHUTDOWN_CHILD_WAIT: Duration = Duration::from_secs(15);

/// Maximum consecutive failures before entering the slow-retry regime.
const MAX_CONSECUTIVE_FAILURES: u32 = 8;

/// Backoff delays in seconds, in order. Capped at 30s.
const BACKOFF_SECS: &[u64] = &[1, 2, 4, 8, 16, 30];

// ---------------------------------------------------------------------------
// Restart policy (pure state machine)
// ---------------------------------------------------------------------------

/// Pure restart-policy state machine.
///
/// Delays follow [`BACKOFF_SECS`], capped at 30s. After
/// [`MAX_CONSECUTIVE_FAILURES`] consecutive failures the policy keeps
/// retrying at the capped delay **indefinitely** — a desktop app with a broken
/// backend is more useful retrying in the background than showing a dead
/// window forever.
#[derive(Debug)]
pub struct RestartPolicy {
    consecutive_failures: u32,
    backoff_index: usize,
}

impl RestartPolicy {
    pub fn new() -> Self {
        Self {
            consecutive_failures: 0,
            backoff_index: 0,
        }
    }

    /// Records a failed restart attempt: advances the failure counter and
    /// points the backoff index at the delay for this failure (1st failure →
    /// 1s, 2nd → 2s, ... capped at 30s).
    pub fn record_failure(&mut self) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let idx = (self.consecutive_failures as usize)
            .saturating_sub(1)
            .min(BACKOFF_SECS.len() - 1);
        self.backoff_index = idx;
    }

    /// Records a successful recovery: resets both the failure counter and the
    /// backoff index, so the next crash starts the sequence over at 1s.
    pub fn record_success(&mut self) {
        self.consecutive_failures = 0;
        self.backoff_index = 0;
    }

    /// The delay to wait before the next restart attempt.
    pub fn next_backoff(&self) -> Duration {
        Duration::from_secs(BACKOFF_SECS[self.backoff_index])
    }

    /// Number of consecutive failures so far.
    pub fn consecutive_failures(&self) -> u32 {
        self.consecutive_failures
    }

    /// True once [`MAX_CONSECUTIVE_FAILURES`] failures have accumulated — the
    /// slow-retry regime: keep retrying every 30s forever.
    pub fn in_slow_retry(&self) -> bool {
        self.consecutive_failures >= MAX_CONSECUTIVE_FAILURES
    }
}

// ---------------------------------------------------------------------------
// Exit classification (pure)
// ---------------------------------------------------------------------------

/// How a backend process exited.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitKind {
    /// The process crashed or exited non-zero without a shutdown being
    /// requested. Carries the exit code (`None` = killed by a signal / no
    /// code).
    Unexpected(Option<i32>),
    /// The exit was deliberate: a shutdown was requested (tray Quit confirm /
    /// app shutdown) or the process exited cleanly with code 0.
    Intentional,
}

/// Classifies a process exit as intentional or unexpected.
///
/// An exit is intentional when a shutdown was requested OR the process exited
/// cleanly with code 0. The release backend only exits with code 0 on a
/// deliberate stop (dashboard graceful `System.stop/0` — the new quit flow or
/// the System page's Stop button); crashes produce non-zero codes or signal
/// death (`None`). Treating `Some(0)` as intentional makes the System-page
/// "Stop" button coherent in desktop mode (previously the watchdog would
/// restart the backend) and is belt-and-braces for the IPC race where the
/// child exits cleanly right before/around `begin_quit` arrives.
pub fn classify_exit(intentional: bool, status: Option<i32>) -> ExitKind {
    if intentional || status == Some(0) {
        ExitKind::Intentional
    } else {
        ExitKind::Unexpected(status)
    }
}

/// Decides whether the watchdog should run the update install path instead of
/// exiting the app: the backend exit must have been intentional AND the user
/// must have armed the update intent via the `begin_update` command.
pub fn should_install_update(intentional: bool, update_requested: bool) -> bool {
    intentional && update_requested
}

// ---------------------------------------------------------------------------
// Downloaded-update storage (process-global)
// ---------------------------------------------------------------------------

/// A fully downloaded (and minisign-verified) update payload, stashed by the
/// `download_update` Tauri command and consumed by the watchdog's
/// update-intent flow once the backend child is confirmed dead.
pub struct DownloadedUpdate {
    /// Version of the downloaded bundle.
    pub version: String,
    /// Raw updater payload bytes (the same bytes `Update::download` verified):
    /// an NSIS `.exe` on Windows, a `.AppImage.tar.gz` on Linux, an
    /// `.app.tar.gz` on macOS.
    pub bytes: Vec<u8>,
}

/// Process-global slot for the downloaded payload. The `download_update`
/// command runs in Tauri's async command context while the watchdog consumes
/// it from a plain `std::thread`, so the slot is a `OnceLock<Mutex<Option<_>>>`
/// shared across both. A process-global (rather than a field on
/// [`BackendManager`]) keeps the manager's constructor unchanged and makes the
/// payload independent of the manager's lifecycle.
static DOWNLOADED_UPDATE: OnceLock<Mutex<Option<DownloadedUpdate>>> = OnceLock::new();

fn downloaded_update_slot() -> &'static Mutex<Option<DownloadedUpdate>> {
    DOWNLOADED_UPDATE.get_or_init(|| Mutex::new(None))
}

/// Stores the verified update payload for the watchdog's install step.
pub fn set_downloaded_update(version: String, bytes: Vec<u8>) {
    let byte_len = bytes.len();
    let mut slot = downloaded_update_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *slot = Some(DownloadedUpdate { version, bytes });
    println!(
        "[desktop] update payload staged in memory ({byte_len} bytes) — it will be installed after the backend stops"
    );
}

/// Takes the stored payload, leaving the slot empty (one install per cycle).
pub fn take_downloaded_update() -> Option<DownloadedUpdate> {
    downloaded_update_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take()
}

// ---------------------------------------------------------------------------
// TCP readiness probe (pure-ish, std only)
// ---------------------------------------------------------------------------

/// Returns true if something on `127.0.0.1:port` accepts TCP connections
/// within `timeout`. Polls with short per-attempt connect timeouts until the
/// deadline, so a not-yet-listening port is retried rather than failed
/// immediately.
pub fn tcp_accepting(port: u16, timeout: Duration) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let deadline = Instant::now() + timeout;
    let per_attempt = Duration::from_millis(100).min(timeout.max(Duration::from_millis(10)));
    loop {
        match TcpStream::connect_timeout(&addr, per_attempt) {
            Ok(_) => return true,
            Err(_) => {
                if Instant::now() >= deadline {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Error page (data: URL)
// ---------------------------------------------------------------------------

/// Head of the error page. `backend_url` is spliced between head and tail
/// (the CSS braces make `format!` unusable).
const ERROR_PAGE_HEAD: &str = r#"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Genesis — Backend Unavailable</title><style>
html,body{height:100%;margin:0;background:#1e1e24;color:#e8e8ec;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;display:flex;align-items:center;justify-content:center}
.card{text-align:center;max-width:28rem;padding:2rem}
h1{font-size:1.25rem;margin:0 0 .5rem;color:#fff}
p{font-size:.9rem;line-height:1.5;color:#a9a9b3;margin:0 0 1.5rem}
button{background:#C8383C;color:#fff;border:none;border-radius:6px;padding:.6rem 1.4rem;font-size:.9rem;cursor:pointer}
button:hover{filter:brightness(1.1)}
</style></head><body><div class="card"><h1>Genesis backend unavailable</h1><p>The dashboard backend has stopped responding. It will be restarted automatically.</p><button type="button" onclick="window.location.href='"#;

/// Tail of the error page; completes the retry button's `onclick` handler.
const ERROR_PAGE_TAIL: &str = r#"'">Retry now</button></div></body></html>"#;

/// Percent-encodes a string for use inside a `data:` URL, keeping only RFC
/// 3986 unreserved characters (`A-Z a-z 0-9 - . _ ~`) verbatim. Everything
/// else (spaces, `<`, `>`, `#`, quotes, `%`, ...) becomes `%XX`.
pub fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push_str(&format!("{byte:02X}"));
        }
    }
    out
}

/// Builds the `data:` URL for the backend-unavailable error page.
///
/// The page degrades gracefully: if JavaScript does not run, the static text
/// ("backend unavailable — will be restarted automatically") is still shown;
/// if it does run, the "Retry now" button performs a top-level navigation to
/// `backend_url` (no Tauri IPC, no CORS involved).
pub fn error_page_data_url(backend_url: &str) -> String {
    let html = ERROR_PAGE_HEAD.to_owned() + backend_url + ERROR_PAGE_TAIL;
    format!("data:text/html;charset=utf-8,{}", percent_encode(&html))
}

// ---------------------------------------------------------------------------
// Backend manager (managed state + watchdog loop)
// ---------------------------------------------------------------------------

/// What [`BackendManager::wait_for_exit`] observed.
enum ExitObservation {
    /// The child exited; carries its exit code (`None` = signal / no code).
    Exited(Option<i32>),
    /// No child in state (e.g. the initial spawn failed).
    Missing,
    /// Intentional shutdown OR update intent requested while waiting.
    Shutdown,
}

/// Managed state for the backend child process and the watchdog.
///
/// Registered via `app.manage` (wrapped in an `Arc` shared with the watchdog
/// thread); the tray-quit handler, the `begin_quit` / `begin_update`
/// commands, and the watchdog share it. The current child lives in a [`Mutex`]
/// so the quit handler can take and kill it while the watchdog is polling, and
/// the `intentional_shutdown` flag tells the watchdog to stop restarting. The
/// separate `update_intent` flag arms the auto-update flow: when the backend
/// then exits intentionally, the watchdog installs the staged payload and
/// relaunches the new bundle instead of exiting the app.
pub struct BackendManager {
    child: Mutex<Option<Child>>,
    intentional_shutdown: AtomicBool,
    update_intent: AtomicBool,
    policy: Mutex<RestartPolicy>,
    launcher_path: PathBuf,
    env: Vec<(String, String)>,
    port: u16,
    backend_url: String,
}

impl BackendManager {
    pub fn new(
        launcher_path: PathBuf,
        env: Vec<(String, String)>,
        port: u16,
        backend_url: String,
    ) -> Self {
        Self {
            child: Mutex::new(None),
            intentional_shutdown: AtomicBool::new(false),
            update_intent: AtomicBool::new(false),
            policy: Mutex::new(RestartPolicy::new()),
            launcher_path,
            env,
            port,
            backend_url,
        }
    }

    /// Spawns the backend and stores the child handle. Used for the initial
    /// boot (from the Tauri setup) and for every restart (from the watchdog).
    pub fn spawn_child(&self) -> std::io::Result<()> {
        let child = crate::sidecar::spawn(&self.launcher_path, &self.env)?;
        *self.lock_child() = Some(child);
        Ok(())
    }

    /// Marks shutdown as intentional WITHOUT killing the child.
    ///
    /// Invoked by the dashboard's JavaScript via the `begin_quit` Tauri
    /// command after the user confirms the web-page quit dialog. The backend
    /// then stops itself gracefully (dashboard `System.stop()`); the watchdog
    /// observes the flag, waits up to [`SHUTDOWN_CHILD_WAIT`] for the child
    /// to exit (force-killing it if the graceful stop hangs), and then exits
    /// the app — never restarting the backend after a quit has begun.
    pub fn begin_quit(&self) {
        self.intentional_shutdown.store(true, Ordering::SeqCst);
        println!(
            "[desktop] quit confirmed — backend stopping gracefully; watchdog will not restart it"
        );
    }

    /// Marks shutdown as intentional, then takes and kills the current child.
    /// The watchdog observes the flag at every stage (before, during and
    /// after every spawn/sleep) and therefore never restarts the backend
    /// after a quit has begun.
    pub fn kill_for_quit(&self) {
        self.intentional_shutdown.store(true, Ordering::SeqCst);
        self.kill_current_child();
        println!("[desktop] genesis-backend sidecar terminated");
    }

    /// Takes and kills the current child, if any. A no-op when there is none
    /// (already reaped, or already taken by `kill_for_quit`) — killing an
    /// already-exited child is harmless, restarting after quit is not.
    pub fn kill_current_child(&self) {
        let mut guard = self.lock_child();
        if let Some(mut child) = guard.take() {
            #[cfg(windows)]
            {
                // On Windows the tracked child is `cmd.exe` (std retries the
                // `.bat` launcher via `cmd.exe /c` — sidecar.rs), and the real
                // BEAM (erl.exe/beam.smp) is cmd's CHILD. `child.kill()` on
                // cmd.exe alone orphans the BEAM, which keeps
                // `resources/genesis-backend/` files open until the
                // EVOGIT_LIFETIME_PORT pipe closes (only once this Rust shell
                // dies) — exactly what wedges the NSIS updater with "file in
                // use". Force-kill the WHOLE tree instead:
                // `taskkill /PID <pid> /T /F` — `/T` enumerates the target's
                // CURRENT descendants, so taskkill must run while cmd.exe is
                // still alive: never call `child.kill()` before it. Fall back
                // to the legacy single-process kill only if taskkill itself
                // could not be launched. `taskkill` ships with every Windows
                // install (zero new dependencies). CREATE_NO_WINDOW
                // (0x08000000) keeps taskkill from flashing a console window
                // (this is a GUI-subsystem process — same flag the sidecar's
                // `launcher_command` applies).
                use std::os::windows::process::CommandExt;
                let pid = child.id();
                let mut taskkill = std::process::Command::new("taskkill");
                taskkill
                    .args(["/PID", &pid.to_string(), "/T", "/F"])
                    .creation_flags(0x0800_0000)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null());
                match taskkill.status() {
                    Ok(_) => {
                        // taskkill terminated cmd.exe and its descendants; reap
                        // the direct child so no zombie is left behind.
                        let _ = child.wait();
                    }
                    Err(_) => {
                        // taskkill could not be launched (should not happen) —
                        // fall back to the previous single-process kill.
                        let _ = child.kill();
                        let _ = child.wait();
                    }
                }
            }
            #[cfg(not(windows))]
            {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }

    /// True once the user has requested shutdown (tray Quit confirm).
    pub fn shutdown_requested(&self) -> bool {
        self.intentional_shutdown.load(Ordering::SeqCst)
    }

    /// The backend URL the WebView connects to (resolved once at startup with
    /// the dynamic port). The tray-quit handler probes this URL — with a
    /// dynamic port the environment no longer reflects the actual port, so
    /// recomputing it would probe a stale URL.
    pub fn backend_url(&self) -> &str {
        &self.backend_url
    }

    /// Arms the auto-update flow WITHOUT killing the child.
    ///
    /// Invoked by the dashboard's JavaScript via the `begin_update` Tauri
    /// command right before the backend calls `System.stop/0` from inside the
    /// BEAM. It only sets the `update_intent` flag — exactly like
    /// [`Self::begin_quit`] it kills nothing; the backend stops itself
    /// gracefully. When the watchdog then observes an intentional child exit,
    /// it installs the staged update payload and relaunches the new bundle
    /// instead of exiting the app.
    pub fn begin_update(&self) {
        self.update_intent.store(true, Ordering::SeqCst);
        println!(
            "[desktop] update confirmed — backend stopping gracefully; watchdog will install the staged update and relaunch"
        );
    }

    /// True once the user has armed the auto-update flow (`begin_update`).
    pub fn update_requested(&self) -> bool {
        self.update_intent.load(Ordering::SeqCst)
    }

    /// Waits up to [`SHUTDOWN_CHILD_WAIT`] for the child to actually exit on
    /// its own (the backend was told to stop gracefully and normally exits in
    /// well under a second), then force-kills it as a fallback if the graceful
    /// BEAM stop hung (`kill_current_child` is a no-op when the child was
    /// already reaped). The child is guaranteed dead when this returns, which
    /// is the precondition for the update-install path (no file replacement
    /// may happen while the backend maps files from inside the bundle).
    fn wait_for_child_exit_then_kill(&self) {
        let deadline = Instant::now() + SHUTDOWN_CHILD_WAIT;
        while self.child_alive() && Instant::now() < deadline {
            std::thread::sleep(MONITOR_INTERVAL);
        }
        self.kill_current_child();
    }

    /// Finalizes an intentional exit from the watchdog thread: waits for the
    /// backend child to be confirmed dead (the backend was told to stop
    /// gracefully and normally exits in well under a second; force-kill is the
    /// fallback if the graceful BEAM stop hung — `kill_current_child` is a
    /// no-op when the child was already reaped), then either installs the
    /// staged update and relaunches the new bundle (update intent armed) or
    /// exits the app (plain quit — unchanged pre-update behavior).
    /// `AppHandle::exit` is thread-safe, so calling it from the watchdog
    /// thread is fine. Every exit path ends the process — never returns to
    /// the caller.
    fn finish_shutdown(&self, app: &AppHandle) {
        self.wait_for_child_exit_then_kill();
        if self.update_requested() {
            self.install_and_relaunch(app);
        } else {
            app.exit(0);
        }
    }

    /// Consumes the downloaded payload from the process-global slot and runs
    /// the platform's install step, then relaunches the updated bundle (Unix)
    /// or exits so the spawned NSIS installer's own relaunch takes over
    /// (Windows). Always ends the process.
    ///
    /// Invariants (auto-update plan §4.5): the backend child is confirmed dead
    /// before any file replacement (callers route through
    /// [`Self::finish_shutdown`] or have already reaped/killed it),
    /// and the crash-restart loop is suppressed by the `update_requested`
    /// checks at every watchdog stage.
    fn install_and_relaunch(&self, app: &AppHandle) {
        let Some(payload) = take_downloaded_update() else {
            // No payload: either the download never succeeded or it was
            // already consumed. Never relaunch into nothing — log and exit.
            eprintln!(
                "[desktop] update requested but no downloaded payload is available — exiting without updating"
            );
            app.exit(0);
            return;
        };
        println!(
            "[desktop] installing update {} ({} bytes)",
            payload.version,
            payload.bytes.len()
        );
        match install_payload(&payload, app) {
            Ok(()) => {
                #[cfg(not(windows))]
                {
                    // Unix: the payload is now in place — relaunch the new
                    // bundle detached, then exit.
                    if let Some(exe) = relaunch_executable(app) {
                        println!("[desktop] relaunching updated app: {}", exe.display());
                        spawn_detached(&exe);
                    }
                    app.exit(0);
                }
                #[cfg(windows)]
                {
                    // Mirror tauri-plugin-updater's `install_inner`: after the
                    // NSIS installer is spawned, exit HARD and synchronously so
                    // the old process tree (this shell + its WebView2 children)
                    // is fully gone before the installer replaces files.
                    // `app.exit(0)` is async (event-loop `ControlFlow::Exit`)
                    // and can leave the old exe / install-dir files locked
                    // while NSIS writes → "file in use"; an immediate retry
                    // succeeds because by then the process is dead.
                    //
                    // `std::process::exit` does NOT flush block-buffered stdout
                    // when piped, so flush stdout first so the final NSIS
                    // install log lines ("[desktop] NSIS installer spawned ...",
                    // "[desktop] installing update ...") are not lost.
                    use std::io::Write;
                    let _ = std::io::stdout().flush();
                    std::process::exit(0);
                }
            }
            Err(err) => {
                // The old bundle was restored where the platform's install
                // step supports it (Linux/macOS mirror the plugin's backup
                // dance). The app stays dead — log loudly and exit.
                eprintln!("[desktop] update install failed: {err}; exiting without relaunch");
                app.exit(0);
            }
        }
    }

    /// Runs the watchdog loop until intentional shutdown.
    ///
    /// Spawned on a dedicated [`std::thread`] from the Tauri setup with an
    /// [`AppHandle`] clone for WebView navigation.
    pub fn run_watchdog(&self, app: AppHandle) {
        println!("[desktop] backend watchdog started");
        loop {
            // Covers every path that loops back here (e.g. `wait_until_ready`
            // timing out or `show_backend` bailing early): on shutdown, wait
            // for the child to exit and then either install the staged update
            // and relaunch (update intent) or exit the app (plain quit).
            if self.shutdown_requested() {
                self.finish_shutdown(&app);
                return;
            }

            // Monitor the current child until it exits (reaping the zombie).
            let status = match self.wait_for_exit() {
                ExitObservation::Shutdown => {
                    self.finish_shutdown(&app);
                    return;
                }
                ExitObservation::Missing => None,
                ExitObservation::Exited(status) => status,
            };

            // A clean code-0 exit is a deliberate stop (dashboard graceful
            // `System.stop/0` — the quit flow, the System page's Stop button,
            // or the update flow): exit the app instead of restarting the
            // backend — or, when the update flag is armed, install the staged
            // payload and relaunch the new bundle. The child is already
            // reaped here, so no extra wait is needed before the install.
            let kind = classify_exit(false, status);
            if kind == ExitKind::Intentional {
                println!(
                    "[desktop] backend exited cleanly (code 0) — treating as intentional shutdown"
                );
                if should_install_update(true, self.update_requested()) {
                    self.install_and_relaunch(&app);
                    return;
                }
                self.kill_current_child();
                app.exit(0);
                return;
            }

            // Unexpected exit (or a missing child from a failed boot) —
            // failure path: grow the backoff, show the error page, wait,
            // then respawn.
            let (delay, failures) = {
                let mut policy = self.lock_policy();
                policy.record_failure();
                (policy.next_backoff(), policy.consecutive_failures())
            };
            println!(
                "[desktop] backend exited unexpectedly ({kind:?}); restarting in {delay:?} (consecutive failures: {failures})"
            );
            if self.lock_policy().in_slow_retry() {
                println!(
                    "[desktop] backend restart is in slow-retry mode — retrying every 30s until it recovers"
                );
            }
            self.show_error_page(&app);

            if !self.sleep_interruptible(delay) {
                self.finish_shutdown(&app);
                return;
            }

            if let Err(err) = self.spawn_child() {
                eprintln!("[desktop] failed to respawn backend: {err}");
                continue; // failure path again, with the next backoff delay
            }
            // A quit/update may have raced the respawn: kill the fresh child
            // and stop IMMEDIATELY. Do NOT use `finish_shutdown`'s 15s
            // graceful-stop wait here — the child was just spawned and
            // cannot have completed a graceful stop yet, so waiting would only
            // delay the exit. It IS confirmed dead right after the kill, which
            // is all the update-install path requires.
            if self.shutdown_requested() || self.update_requested() {
                self.kill_current_child();
                if self.update_requested() {
                    self.install_and_relaunch(&app);
                } else {
                    app.exit(0);
                }
                return;
            }

            if self.wait_until_ready(READY_TIMEOUT) {
                self.lock_policy().record_success();
                println!("[desktop] backend recovered — reloading dashboard");
                self.show_backend(&app);
            } else {
                eprintln!(
                    "[desktop] backend did not become ready within {READY_TIMEOUT:?}; retrying"
                );
                self.kill_current_child();
                // Loop back to the failure path (record_failure, next delay).
            }
        }
    }

    /// Blocks until the stored child exits, reaping it via `try_wait`.
    ///
    /// Returns [`ExitObservation::Shutdown`] if an intentional shutdown OR an
    /// update intent is requested while waiting (both stop the restart loop;
    /// the caller distinguishes them via `update_requested()`),
    /// [`ExitObservation::Missing`] if there is no child in state, or
    /// [`ExitObservation::Exited`] with the exit code once the child is gone.
    fn wait_for_exit(&self) -> ExitObservation {
        loop {
            if self.shutdown_requested() || self.update_requested() {
                return ExitObservation::Shutdown;
            }
            let mut guard = self.lock_child();
            match guard.as_mut() {
                None => return ExitObservation::Missing,
                Some(child) => match child.try_wait() {
                    Ok(Some(status)) => {
                        let code = status.code();
                        guard.take();
                        return ExitObservation::Exited(code);
                    }
                    Ok(None) => {
                        drop(guard);
                        std::thread::sleep(MONITOR_INTERVAL);
                    }
                    Err(_) => {
                        guard.take();
                        return ExitObservation::Exited(None);
                    }
                },
            }
        }
    }

    /// Polls until the backend serves requests — child alive AND TCP port
    /// accepting AND an HTTP probe succeeding — or the deadline elapses.
    fn wait_until_ready(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.shutdown_requested() || self.update_requested() {
                return false;
            }
            if !self.child_alive() {
                return false; // died during the wait → another failure
            }
            if tcp_accepting(self.port, Duration::from_millis(200))
                && crate::sidecar::probe_http(&self.backend_url).is_some()
            {
                return true;
            }
            std::thread::sleep(READY_POLL_INTERVAL);
        }
        false
    }

    /// True while the stored child is still running. Reaps the child (and
    /// clears the state) if it exited.
    fn child_alive(&self) -> bool {
        let mut guard = self.lock_child();
        match guard.as_mut() {
            None => false,
            Some(child) => match child.try_wait() {
                Ok(Some(_)) => {
                    guard.take();
                    false
                }
                Ok(None) => true,
                Err(_) => false,
            },
        }
    }

    /// Sleeps for `duration`, returning early with `false` if an intentional
    /// shutdown or an update intent is requested mid-sleep.
    fn sleep_interruptible(&self, duration: Duration) -> bool {
        let deadline = Instant::now() + duration;
        while Instant::now() < deadline {
            if self.shutdown_requested() || self.update_requested() {
                return false;
            }
            std::thread::sleep(MONITOR_INTERVAL);
        }
        true
    }

    /// Navigates the main window to `url`. Returns true when the window
    /// existed and accepted the navigation (an invalid URL also returns true
    /// to avoid hot-looping); false while the window does not exist yet
    /// (early startup), so callers can retry.
    fn navigate(&self, app: &AppHandle, url: &str) -> bool {
        let Some(window) = app.get_webview_window("main") else {
            return false;
        };
        navigate_webview(&window, url)
    }

    /// Shows the backend-unavailable error page (single attempt; the next
    /// failure cycle re-attempts it once the window exists).
    fn show_error_page(&self, app: &AppHandle) {
        self.navigate(app, &error_page_data_url(&self.backend_url));
    }

    /// Reloads the dashboard by navigating to the backend URL. Retries until
    /// the window accepts the navigation (it is created only after Tauri's
    /// setup completes, so an early recovery must wait for it), the backend
    /// dies again, or a quit/update is requested.
    fn show_backend(&self, app: &AppHandle) {
        while !self.navigate(app, &self.backend_url) {
            if self.shutdown_requested() || self.update_requested() {
                return;
            }
            if !self.child_alive() {
                return; // crashed again; the monitor will handle it
            }
            std::thread::sleep(READY_POLL_INTERVAL);
        }
    }

    fn lock_child(&self) -> std::sync::MutexGuard<'_, Option<Child>> {
        self.child
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn lock_policy(&self) -> std::sync::MutexGuard<'_, RestartPolicy> {
        self.policy
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

// ---------------------------------------------------------------------------
// Shared navigation helper
// ---------------------------------------------------------------------------

/// Navigates a webview window to `url`. Returns true when the window existed
/// and accepted the navigation (an invalid URL also returns true to avoid
/// hot-looping); false while the window does not exist yet (early startup),
/// so callers can retry.
///
/// `pub(crate)`: the single navigation implementation, shared by the
/// watchdog ([`BackendManager::navigate`], error-page and recovery paths)
/// and `run_gui`'s setup closure in `main.rs`, which re-navigates the
/// webview to the dashboard after the initial readiness poll (step 8).
pub(crate) fn navigate_webview(window: &tauri::WebviewWindow, url: &str) -> bool {
    match tauri::Url::parse(url) {
        Ok(parsed) => match window.navigate(parsed) {
            Ok(()) => true,
            Err(err) => {
                eprintln!("[desktop] failed to navigate webview to {url}: {err}");
                true
            }
        },
        Err(err) => {
            eprintln!("[desktop] invalid navigation URL {url}: {err}");
            true
        }
    }
}

// ---------------------------------------------------------------------------
// Per-platform install machinery
//
// Mirrors tauri-plugin-updater 2.10.1's `Update::install_inner` semantics per
// platform (the plugin's source was the reference; the watchdog is a plain
// std::thread with no async runtime, so the plugin's spawn/file operations are
// replicated directly rather than calling into it):
//
// - Windows (NSIS): the payload is staged to a temp `.exe` and spawned with
//   the plugin's NSIS args (`/P /R /UPDATE /ARGS`). The NSIS installer
//   relaunches the app itself (its `.onInstSuccess` handler runs
//   `RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" "$R0"` when `/UPDATE /R` are
//   passed), so the watchdog only exits after spawning it.
// - Linux (AppImage): the running AppImage file is renamed to a same-device
//   temp backup, the `.tar.gz` payload is unpacked and its `.AppImage` entry
//   written to the original path, and the backup is restored on any failure.
// - macOS: the `.app.tar.gz` payload is extracted to a temp dir (skipping the
//   archive's top-level component), the current `.app` bundle is renamed to a
//   backup, and the new bundle is moved into place (plus `touch`). The
//   plugin's AppleScript elevation for permission-denied installs is
//   deliberately NOT replicated — the watchdog fails loudly instead.
// ---------------------------------------------------------------------------

/// Runs the install step for the current platform. On success the running
/// bundle has been replaced (Unix) or the NSIS installer has been spawned
/// (Windows); the caller (`BackendManager::install_and_relaunch`) then
/// relaunches/exits.
fn install_payload(payload: &DownloadedUpdate, app: &AppHandle) -> std::io::Result<()> {
    #[cfg(target_os = "windows")]
    {
        let _ = app;
        install_windows_nsis(payload)
    }
    #[cfg(target_os = "linux")]
    {
        install_linux_appimage(payload, app)
    }
    #[cfg(target_os = "macos")]
    {
        install_macos_app(payload, app)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        let _ = (payload, app);
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "auto-update is not supported on this platform",
        ))
    }
}

/// The executable to relaunch after a successful install (Unix).
///
/// On Linux this is the AppImage file (`APPIMAGE` env var) when running from
/// one — `std::env::current_exe()` would point inside the read-only FUSE
/// mount (`/tmp/.mount_*`), NOT at the file that was just replaced — falling
/// back to `current_exe()` in dev builds. On macOS the bundle swap keeps the
/// same exe path inside the new `.app`, so `current_exe()` is correct.
#[cfg(not(windows))]
fn relaunch_executable(app: &AppHandle) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        if let Some(appimage) = app.env().appimage.clone() {
            return Some(PathBuf::from(appimage));
        }
    }
    std::env::current_exe().ok()
}

/// Spawns `exe` detached from the current process — the watchdog exits the
/// app right after, so the child must survive it. On Unix the child is put in
/// its own process group so no parent-side signal delivery can reach it.
#[cfg(not(windows))]
fn spawn_detached(exe: &Path) {
    let mut command = std::process::Command::new(exe);
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    match command.spawn() {
        Ok(_) => println!("[desktop] updated app spawned (pid ready)"),
        Err(err) => eprintln!(
            "[desktop] failed to spawn updated app {}: {err}",
            exe.display()
        ),
    }
}

/// Windows: stage the NSIS installer payload to a temp `.exe` and spawn it
/// with the plugin's exact NSIS args. The spawned installer replaces the app
/// and relaunches it itself; this function returns once the spawn succeeded.
#[cfg(target_os = "windows")]
fn install_windows_nsis(payload: &DownloadedUpdate) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::windows::process::CommandExt;

    // Stage the payload next to the running exe (same volume as the install
    // dir; the installer runs from here).
    let mut installer = tempfile::Builder::new()
        .prefix("genesis-desktop-updater-")
        .suffix(".exe")
        .tempfile()?;
    installer.write_all(&payload.bytes)?;
    // Keep the file after this function returns: the installer must outlive
    // the app process (we exit right after spawning it).
    let installer_path = installer.into_temp_path().keep()?;

    // CREATE_NO_WINDOW (0x08000000) — same flag the sidecar's
    // `launcher_command` applies, so the NSIS installer does not pop a
    // console window (the app is a GUI-subsystem process).
    let spawned = std::process::Command::new(&installer_path)
        .args(["/P", "/R", "/UPDATE", "/ARGS"])
        .creation_flags(0x0800_0000)
        .spawn();
    match spawned {
        Ok(_) => {
            println!(
                "[desktop] NSIS installer spawned ({}); it will relaunch the app itself",
                installer_path.display()
            );
            Ok(())
        }
        Err(err) => {
            let _ = std::fs::remove_file(&installer_path);
            Err(err)
        }
    }
}

/// The path of the running bundle that an update replaces.
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn update_extract_path(app: &AppHandle) -> std::io::Result<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        // The AppImage file itself when running from one; `current_exe()`
        // only in dev builds (no APPIMAGE env var).
        if let Some(appimage) = app.env().appimage.clone() {
            return Ok(PathBuf::from(appimage));
        }
        std::env::current_exe()
    }
    #[cfg(target_os = "macos")]
    {
        // Walk up from `.../<App>.app/Contents/MacOS/<exe>` to the `.app`
        // bundle directory (mirrors the plugin's `extract_path_from_executable`).
        let exe = std::env::current_exe()?;
        let mut dir = exe.parent();
        while let Some(d) = dir {
            if d.extension().is_some_and(|ext| ext == "app") {
                return Ok(d.to_path_buf());
            }
            dir = d.parent();
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "cannot determine the .app bundle path from the current executable",
        ))
    }
}

/// Linux: replace the running AppImage file with the payload's `.AppImage`
/// entry, mirroring the plugin's `install_appimage` — backup-rename to a
/// same-device temp dir (chmod 0700), unpack the `.tar.gz` payload, write the
/// `.AppImage` entry to the original path, restore the backup on any failure.
/// The plugin's non-gzip direct-write fallback is omitted: updater payloads
/// are always `.tar.gz` archives.
#[cfg(target_os = "linux")]
fn install_linux_appimage(payload: &DownloadedUpdate, app: &AppHandle) -> std::io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let extract_path = update_extract_path(app)?;
    let extract_meta = std::fs::metadata(&extract_path)?;

    // Same-device temp locations, in order of preference (the rename of the
    // running AppImage must not cross a mount boundary).
    let tmp_locations = [
        std::env::temp_dir(),
        extract_path.parent().map(PathBuf::from).unwrap_or_default(),
    ];

    for tmp_location in tmp_locations {
        let Ok(tmp_dir) = tempfile::Builder::new()
            .prefix("tauri_current_app")
            .tempdir_in(&tmp_location)
        else {
            continue;
        };
        let Ok(tmp_meta) = tmp_dir.path().metadata() else {
            continue;
        };
        if extract_meta.dev() != tmp_meta.dev() {
            continue;
        }
        let mut perms = tmp_meta.permissions();
        perms.set_mode(0o700);
        std::fs::set_permissions(tmp_dir.path(), perms)?;

        // Create a backup of the current AppImage.
        let backup = tmp_dir.path().join("current_app.AppImage");
        std::fs::rename(&extract_path, &backup)?;

        // Unpack the payload; the `.AppImage` entry replaces the original
        // file. Restore the backup on any failure (mirrors the plugin's
        // early-return/restore behavior).
        let result = (|| -> std::io::Result<()> {
            let decoder = flate2::read::GzDecoder::new(std::io::Cursor::new(&payload.bytes));
            let mut archive = tar::Archive::new(decoder);
            for mut entry in archive.entries()?.flatten() {
                let Ok(path) = entry.path() else {
                    continue;
                };
                if path.extension() == Some(std::ffi::OsStr::new("AppImage")) {
                    entry.unpack(&extract_path)?;
                    return Ok(());
                }
            }
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "no .AppImage entry found in the update payload",
            ))
        })();

        match result {
            Ok(()) => {
                println!("[desktop] AppImage replaced at {}", extract_path.display());
                return Ok(());
            }
            Err(err) => {
                let _ = std::fs::rename(&backup, &extract_path);
                return Err(err);
            }
        }
    }

    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "no same-device temp directory available for the AppImage swap",
    ))
}

/// macOS: swap the running `.app` bundle with the payload's extracted bundle,
/// mirroring the plugin's macOS `install_inner`. The `.app.tar.gz` payload is
/// extracted to a temp dir skipping the archive's first path component (the
/// top-level `.app` directory); the current bundle is renamed to a backup and
/// the new one moved into place, then `touch`ed. Permission-denied installs
/// are NOT escalated via AppleScript (the plugin uses osakit) — the watchdog
/// is a plain std::thread and fails loudly instead.
#[cfg(target_os = "macos")]
fn install_macos_app(payload: &DownloadedUpdate, app: &AppHandle) -> std::io::Result<()> {
    use flate2::read::GzDecoder;

    let extract_path = update_extract_path(app)?;
    let tmp_backup_dir = tempfile::Builder::new()
        .prefix("tauri_current_app")
        .tempdir()?;
    let tmp_extract_dir = tempfile::Builder::new()
        .prefix("tauri_updated_app")
        .tempdir()?;

    // Extract the payload into the temp dir, skipping the first path
    // component (the archive's top-level directory, e.g. "EvoX Genesis.app").
    let decoder = GzDecoder::new(std::io::Cursor::new(&payload.bytes));
    let mut archive = tar::Archive::new(decoder);
    for entry in archive.entries()? {
        let mut entry = entry?;
        let collected: PathBuf = entry.path()?.iter().skip(1).collect();
        let extraction_path = tmp_extract_dir.path().join(collected);
        if let Some(parent) = extraction_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if let Err(err) = entry.unpack(&extraction_path) {
            let _ = std::fs::remove_dir_all(tmp_extract_dir.path());
            return Err(err);
        }
    }

    // Move the current app to the backup location.
    match std::fs::rename(&extract_path, tmp_backup_dir.path().join("current_app")) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => {
            let _ = std::fs::remove_dir_all(tmp_extract_dir.path());
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!(
                    "cannot replace {}: permission denied (the app bundle is not writable by the current user) — grant write permission or reinstall",
                    extract_path.display()
                ),
            ));
        }
        Err(err) => {
            let _ = std::fs::remove_dir_all(tmp_extract_dir.path());
            return Err(err);
        }
    }

    // Move the new app into place.
    if extract_path.exists() {
        std::fs::remove_dir_all(&extract_path)?;
    }
    std::fs::rename(tmp_extract_dir.path(), &extract_path)?;
    let _ = std::process::Command::new("touch")
        .arg(&extract_path)
        .status();

    println!(
        "[desktop] .app bundle replaced at {}",
        extract_path.display()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn backoff_advances_through_sequence_and_caps_at_30s() {
        let mut policy = RestartPolicy::new();
        let mut delays = Vec::new();
        for _ in 0..BACKOFF_SECS.len() {
            policy.record_failure();
            delays.push(policy.next_backoff());
        }
        assert_eq!(delays[0], Duration::from_secs(1));
        assert_eq!(delays[1], Duration::from_secs(2));
        assert_eq!(delays[2], Duration::from_secs(4));
        assert_eq!(delays[3], Duration::from_secs(8));
        assert_eq!(delays[4], Duration::from_secs(16));
        assert_eq!(delays[5], Duration::from_secs(30));
        // Still capped after further failures.
        policy.record_failure();
        assert_eq!(policy.next_backoff(), Duration::from_secs(30));
    }

    #[test]
    fn slow_retry_kicks_in_after_max_consecutive_failures_and_continues() {
        let mut policy = RestartPolicy::new();
        for _ in 0..MAX_CONSECUTIVE_FAILURES - 1 {
            policy.record_failure();
        }
        assert!(!policy.in_slow_retry());
        policy.record_failure();
        assert!(policy.in_slow_retry());
        assert_eq!(policy.next_backoff(), Duration::from_secs(30));
        // Retrying keeps going indefinitely at the capped delay.
        for _ in 0..100 {
            policy.record_failure();
        }
        assert!(policy.in_slow_retry());
        assert_eq!(policy.next_backoff(), Duration::from_secs(30));
        assert_eq!(
            policy.consecutive_failures(),
            MAX_CONSECUTIVE_FAILURES + 100
        );
    }

    #[test]
    fn success_resets_counter_and_backoff() {
        let mut policy = RestartPolicy::new();
        for _ in 0..20 {
            policy.record_failure();
        }
        assert_eq!(policy.next_backoff(), Duration::from_secs(30));
        policy.record_success();
        assert_eq!(policy.consecutive_failures(), 0);
        assert!(!policy.in_slow_retry());
        // The next failure starts the sequence over at 1s.
        policy.record_failure();
        assert_eq!(policy.next_backoff(), Duration::from_secs(1));
        assert_eq!(policy.consecutive_failures(), 1);
    }

    #[test]
    fn classify_exit_distinguishes_intentional_and_unexpected() {
        assert_eq!(classify_exit(true, Some(0)), ExitKind::Intentional);
        assert_eq!(classify_exit(true, None), ExitKind::Intentional);
        assert_eq!(classify_exit(false, Some(1)), ExitKind::Unexpected(Some(1)));
        assert_eq!(classify_exit(false, None), ExitKind::Unexpected(None));
    }

    #[test]
    fn classify_exit_treats_clean_code_zero_as_intentional() {
        // The release backend only exits with code 0 on a deliberate stop
        // (dashboard graceful `System.stop/0`); crashes are non-zero or
        // signal death. So a clean exit, even without the
        // `intentional_shutdown` flag, must not trigger a restart.
        assert_eq!(classify_exit(false, Some(0)), ExitKind::Intentional);
    }

    #[cfg(unix)]
    #[test]
    fn begin_quit_sets_flag_without_killing_child() {
        let manager = BackendManager::new(
            PathBuf::from("/nonexistent"),
            vec![],
            9999,
            "http://localhost:9999".to_string(),
        );
        let child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sleep");
        *manager.child.lock().unwrap() = Some(child);

        manager.begin_quit();

        assert!(manager.shutdown_requested());
        // `begin_quit` only sets the flag — the child must still be running
        // so the backend can finish its graceful stop on its own.
        let mut child = manager
            .child
            .lock()
            .unwrap()
            .take()
            .expect("child still present");
        assert!(
            matches!(child.try_wait(), Ok(None)),
            "begin_quit must not kill the child"
        );
        let _ = child.kill();
        let _ = child.wait();
    }

    #[cfg(unix)]
    #[test]
    fn begin_update_sets_flag_without_killing_child() {
        let manager = BackendManager::new(
            PathBuf::from("/nonexistent"),
            vec![],
            9999,
            "http://localhost:9999".to_string(),
        );
        let child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sleep");
        *manager.child.lock().unwrap() = Some(child);

        manager.begin_update();

        assert!(manager.update_requested());
        // `begin_update` only sets the flag — the child must still be running
        // so the backend can finish its graceful stop on its own.
        let mut child = manager
            .child
            .lock()
            .unwrap()
            .take()
            .expect("child still present");
        assert!(
            matches!(child.try_wait(), Ok(None)),
            "begin_update must not kill the child"
        );
        let _ = child.kill();
        let _ = child.wait();
    }

    #[test]
    fn should_install_update_requires_intentional_exit_and_update_intent() {
        // Both conditions are required: a crash with the update flag armed
        // must NOT trigger the install path (the update flow only runs after
        // the backend stopped itself deliberately), and an intentional exit
        // without the update flag is a plain quit.
        assert!(!should_install_update(false, false));
        assert!(!should_install_update(false, true));
        assert!(!should_install_update(true, false));
        assert!(should_install_update(true, true));
    }

    #[test]
    fn downloaded_update_slot_stores_and_takes_once() {
        assert!(take_downloaded_update().is_none());
        set_downloaded_update("9.9.9".to_string(), vec![1, 2, 3]);
        let taken = take_downloaded_update().expect("payload present");
        assert_eq!(taken.version, "9.9.9");
        assert_eq!(taken.bytes, vec![1, 2, 3]);
        // The slot is single-shot: a second take is empty, so a stale payload
        // can never be installed twice.
        assert!(take_downloaded_update().is_none());
    }

    #[test]
    fn tcp_accepting_true_for_listening_socket() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let port = listener.local_addr().expect("local addr").port();
        assert!(tcp_accepting(port, Duration::from_secs(2)));
    }

    #[test]
    fn tcp_accepting_false_for_closed_port() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let port = listener.local_addr().expect("local addr").port();
        drop(listener); // port is closed now
        assert!(!tcp_accepting(port, Duration::from_millis(400)));
    }

    #[test]
    fn percent_encode_keeps_unreserved_and_encodes_rest() {
        assert_eq!(percent_encode("abc-._~123"), "abc-._~123");
        let encoded = percent_encode("<html># & \"'\n");
        assert!(!encoded.contains('#'));
        assert!(!encoded.contains(' '));
        assert!(!encoded.contains('<'));
        assert!(!encoded.contains('"'));
        assert!(encoded.contains("%3C")); // '<'
        assert!(encoded.contains("%23")); // '#'
        assert!(encoded.contains("%20")); // space
    }

    #[test]
    fn error_page_data_url_is_parseable_and_embeds_backend_url() {
        let url = error_page_data_url("http://localhost:9999");
        assert!(url.starts_with("data:text/html;charset=utf-8,"));
        // No raw '#', space, quote or '<' may survive into the data URL.
        for ch in ['#', ' ', '"', '<'] {
            assert!(!url.contains(ch), "data URL must not contain raw {ch:?}");
        }
        // Must parse as a URL (tauri::Url is the url crate's re-export).
        let parsed = tauri::Url::parse(&url).expect("data URL parses");
        assert_eq!(parsed.scheme(), "data");
        // The decoded HTML must embed the backend URL and the retry button.
        let decoded = percent_decode(&url["data:text/html;charset=utf-8,".len()..]);
        assert!(decoded.contains("http://localhost:9999"));
        assert!(decoded.contains("Retry now"));
        assert!(decoded.contains("restarted automatically"));
    }

    /// Minimal percent-decoder for the test above.
    fn percent_decode(input: &str) -> String {
        let bytes = input.as_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' && i + 2 < bytes.len() {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).expect("valid hex");
                out.push(u8::from_str_radix(hex, 16).expect("hex byte"));
                i += 3;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        String::from_utf8(out).expect("decoded html is utf-8")
    }
}
