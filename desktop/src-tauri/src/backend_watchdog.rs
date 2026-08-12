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
//! A tray "Quit" sets the `intentional_shutdown` flag before killing the
//! child; the watchdog checks the flag at every stage and never restarts the
//! backend after a quit has begun.

use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Manager};

/// How often the monitor polls the child process for exit.
const MONITOR_INTERVAL: Duration = Duration::from_millis(100);
/// How often the readiness poll re-checks the backend.
const READY_POLL_INTERVAL: Duration = Duration::from_millis(250);
/// How long a respawned backend has to come up before the attempt is
/// considered a failure.
const READY_TIMEOUT: Duration = Duration::from_secs(30);

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
    /// The process exited without an intentional shutdown being requested.
    /// Carries the exit code (`None` = killed by a signal / no code).
    Unexpected(Option<i32>),
    /// The exit was requested (tray Quit / app shutdown).
    Intentional,
}

/// Classifies a process exit as intentional or unexpected.
pub fn classify_exit(intentional: bool, status: Option<i32>) -> ExitKind {
    if intentional {
        ExitKind::Intentional
    } else {
        ExitKind::Unexpected(status)
    }
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
    /// Intentional shutdown requested while waiting.
    Shutdown,
}

/// Managed state for the backend child process and the watchdog.
///
/// Registered via `app.manage` (wrapped in an `Arc` shared with the watchdog
/// thread); the tray-quit handler and the watchdog share it. The current
/// child lives in a [`Mutex`] so the quit handler can take and kill it while
/// the watchdog is polling, and the `intentional_shutdown` flag tells the
/// watchdog to stop restarting.
pub struct BackendManager {
    child: Mutex<Option<Child>>,
    intentional_shutdown: AtomicBool,
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
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// True once the user has requested shutdown (tray Quit).
    pub fn shutdown_requested(&self) -> bool {
        self.intentional_shutdown.load(Ordering::SeqCst)
    }

    /// Runs the watchdog loop until intentional shutdown.
    ///
    /// Spawned on a dedicated [`std::thread`] from the Tauri setup with an
    /// [`AppHandle`] clone for WebView navigation.
    pub fn run_watchdog(&self, app: AppHandle) {
        println!("[desktop] backend watchdog started");
        loop {
            if self.shutdown_requested() {
                return;
            }

            // Monitor the current child until it exits (reaping the zombie).
            let status = match self.wait_for_exit() {
                ExitObservation::Shutdown => return,
                ExitObservation::Missing => None,
                ExitObservation::Exited(status) => status,
            };

            // Unexpected exit (or a missing child from a failed boot) —
            // failure path: grow the backoff, show the error page, wait,
            // then respawn.
            let kind = classify_exit(false, status);
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
                return;
            }

            if let Err(err) = self.spawn_child() {
                eprintln!("[desktop] failed to respawn backend: {err}");
                continue; // failure path again, with the next backoff delay
            }
            // A quit may have raced the respawn: kill the fresh child and stop.
            if self.shutdown_requested() {
                self.kill_current_child();
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
    /// Returns [`ExitObservation::Shutdown`] if an intentional shutdown is
    /// requested while waiting, [`ExitObservation::Missing`] if there is no
    /// child in state, or [`ExitObservation::Exited`] with the exit code once
    /// the child is gone.
    fn wait_for_exit(&self) -> ExitObservation {
        loop {
            if self.shutdown_requested() {
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
            if self.shutdown_requested() {
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
    /// shutdown is requested mid-sleep.
    fn sleep_interruptible(&self, duration: Duration) -> bool {
        let deadline = Instant::now() + duration;
        while Instant::now() < deadline {
            if self.shutdown_requested() {
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

    /// Shows the backend-unavailable error page (single attempt; the next
    /// failure cycle re-attempts it once the window exists).
    fn show_error_page(&self, app: &AppHandle) {
        self.navigate(app, &error_page_data_url(&self.backend_url));
    }

    /// Reloads the dashboard by navigating to the backend URL. Retries until
    /// the window accepts the navigation (it is created only after Tauri's
    /// setup completes, so an early recovery must wait for it), the backend
    /// dies again, or a quit is requested.
    fn show_backend(&self, app: &AppHandle) {
        while !self.navigate(app, &self.backend_url) {
            if self.shutdown_requested() {
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
