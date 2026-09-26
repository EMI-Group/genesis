//! Sidecar lifecycle management.
//!
//! This module spawns the standard Elixir release launcher script
//! (`bin/genesis_desktop start`) as a child process, surfaces its output to the
//! console, and polls its HTTP endpoint until it is ready to serve requests.

use std::io::{BufRead, BufReader, Read};
use std::thread;
use std::time::{Duration, Instant};

use tauri::{App, Manager};

/// The local secret key base used by the desktop Phoenix backend.
///
/// This is safe for local, single-user desktop usage only and must NEVER be
/// used for a real, internet-facing deployment.
const SECRET_KEY_BASE: &str =
    "GenesisDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890";

/// Interval between readiness polls.
const POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Per-request timeout for a single health probe.
const POLL_REQUEST_TIMEOUT: Duration = Duration::from_millis(500);

/// Delay before retrying a lifetime-pipe read after a non-EOF outcome, so a
/// persistently-erroring read cannot busy-loop the hold thread.
const LIFETIME_ERROR_RETRY_DELAY: Duration = Duration::from_millis(100);

/// Minimum interval between transient-error log lines from a lifetime-pipe
/// hold thread (rate-limiting — no unbounded log spam).
const LIFETIME_ERROR_LOG_INTERVAL: Duration = Duration::from_secs(5);

/// The OS-specific launcher script name inside the bundled release directory.
///
/// On Unix this is the POSIX shell script `genesis_desktop`; on Windows it is
/// the batch-file variant `genesis_desktop.bat`.
#[cfg(windows)]
const LAUNCHER_NAME: &str = "genesis_desktop.bat";
#[cfg(not(windows))]
const LAUNCHER_NAME: &str = "genesis_desktop";

/// `CREATE_NO_WINDOW` creation flag for `CreateProcess` (Windows only).
///
/// Instructs Windows not to create a new console window for the spawned
/// process. Without it, a console-subsystem child (like `cmd.exe` running a
/// `.bat`) whose parent has no console gets a brand-new, visible console
/// window.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Builds the [`std::process::Command`] that launches the Elixir release
/// launcher script.
///
/// On Windows the launcher is a `.bat` file, which [`std::process::Command`]
/// cannot execute directly via `CreateProcess` and therefore retries through
/// `cmd.exe /c <bat>`. `cmd.exe` is a console-subsystem process: spawned from
/// the GUI-subsystem Tauri app (which has no console), it gets a brand-new,
/// **visible** console window that persists for the backend's lifetime — and
/// closing that window kills `cmd.exe`, the batch script, and the BEAM
/// backend. The `CREATE_NO_WINDOW` creation flag suppresses the new console
/// window. The flag is a no-op on other platforms (the attribute-gated call is
/// compiled out entirely).
pub fn launcher_command(launcher: &std::path::Path) -> std::process::Command {
    let cmd = std::process::Command::new(launcher);

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Shadow as mutable: `creation_flags` needs `&mut self`, but on
        // non-Windows builds the whole block (and the `mut`) is compiled out.
        let mut cmd = cmd;
        cmd.creation_flags(CREATE_NO_WINDOW);
        cmd
    }

    #[cfg(not(windows))]
    {
        cmd
    }
}

/// Environment variables passed to the sidecar process.
///
/// These configure the Phoenix backend to run as a local, single-user
/// server (no distributed Erlang, dynamic port resolved once at startup,
/// server mode enabled).
///
/// The bind address defaults to `127.0.0.1` (IPv4 loopback only) for
/// security.
/// Users can override it by setting the `EVOGIT_BIND` environment variable
/// before launching the desktop app (e.g. `EVOGIT_BIND=0.0.0.0` for remote
/// access). The value is passed to Phoenix as `PHX_IP`.
///
/// `port` is the backend port resolved once at startup (`PORT` honored when
/// set and free, otherwise a random free ephemeral port — never a fixed
/// default; see `crate::resolve_backend_port`). The same port drives the
/// WebView URL and the watchdog's readiness probe, so all three agree.
///
/// `lifetime_port` is the port of the TCP "lifetime pipe" listener (see
/// [`start_lifetime_listener`]): the Elixir backend
/// (`EvoDash.DesktopLifetime`) connects to `127.0.0.1:<lifetime_port>`
/// and blocks on recv; the shell never writes, so any close/error means the
/// shell is dead and the backend stops itself — an orphaned backend (e.g.
/// after an abnormal shell death) can no longer keep its port bound and
/// block a relaunch. `None` means the lifetime pipe is unavailable (listener
/// bind failed) and the variable is omitted so the backend's monitor stays
/// off — emitting a bad port would make the backend treat a failed connect
/// as shell-death and stop, which is wrong.
pub(crate) fn sidecar_env(port: u16, lifetime_port: Option<u16>) -> Vec<(String, String)> {
    let phx_ip = std::env::var("EVOGIT_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());

    let mut env = vec![
        ("PORT".to_string(), port.to_string()),
        ("PHX_IP".to_string(), phx_ip),
        ("PHX_SERVER".to_string(), "true".to_string()),
        ("SECRET_KEY_BASE".to_string(), SECRET_KEY_BASE.to_string()),
        ("RELEASE_DISTRIBUTION".to_string(), "none".to_string()),
        ("EVOGIT_DESKTOP".to_string(), "1".to_string()),
    ];

    if let Some(lifetime_port) = lifetime_port {
        env.push((
            "EVOGIT_LIFETIME_PORT".to_string(),
            lifetime_port.to_string(),
        ));
    }

    env
}

/// The classification of a single read on a lifetime-pipe connection.
///
/// Only a genuine peer EOF may end the hold: the Elixir backend
/// (`EvoDash.DesktopLifetime`) treats ANY socket close as "the Tauri shell is
/// gone" and self-stops with exit code 0 — which the shell's watchdog
/// classifies as an INTENTIONAL shutdown (`classify_exit`: `Some(0)`), so a
/// spurious drop of the hold stream silently exits the whole desktop app while
/// the shell was healthy. Every non-EOF outcome therefore keeps holding.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum LifetimeReadOutcome {
    /// Keep holding the connection (data arrived, or a transient error).
    Hold,
    /// The peer closed the connection (genuine EOF) — end the hold.
    Eof,
}

/// Classifies a single `read` result from a lifetime-pipe hold thread.
///
/// - `Ok(0)` → [`LifetimeReadOutcome::Eof`] — genuine peer EOF, the only
///   outcome that ends the hold.
/// - `Ok(n)` with `n > 0` → [`LifetimeReadOutcome::Hold`] — the shell never
///   writes, but keep holding if the peer ever does.
/// - `Err(_)` → [`LifetimeReadOutcome::Hold`] — a transient error
///   (`Interrupted`, `WouldBlock`, `ConnectionReset`, `TimedOut`, …).
///   Treating an error as EOF is the false-positive channel described on
///   [`LifetimeReadOutcome`], so errors must never end the hold.
///
/// Pure so the classification is unit-testable (a raw socket read is not).
pub(crate) fn classify_lifetime_read(result: &std::io::Result<usize>) -> LifetimeReadOutcome {
    match result {
        Ok(0) => LifetimeReadOutcome::Eof,
        Ok(_) => LifetimeReadOutcome::Hold,
        Err(_) => LifetimeReadOutcome::Hold,
    }
}

/// Starts the TCP "lifetime pipe" listener used by the Elixir backend to
/// detect shell death without polling.
///
/// Binds an ephemeral listener on `127.0.0.1` and returns its bound port. A
/// **detached** accept thread runs for the rest of the process: it loops over
/// `listener.incoming()` forever, spawning a per-stream hold thread per
/// accepted connection (the backend connects once per spawn, so every
/// watchdog respawn gets its own held connection). Each hold thread blocks on
/// a read loop and ends ONLY on a genuine peer EOF ([`classify_lifetime_read`]);
/// a transient read error is logged (rate-limited) and retried on the same
/// stream after a short pause instead of dropping it. The shell NEVER writes on
/// the connection; it is a pure hold. The backend connects to
/// `127.0.0.1:<port>` and blocks on recv; a close means the shell is dead and
/// the backend stops itself.
///
/// Accept errors are logged and the loop continues. On bind failure the
/// caller logs a warning and continues WITHOUT the lifetime pipe (non-fatal —
/// the dynamic backend port already prevents the orphan crash; this is
/// defense-in-depth).
pub(crate) fn start_lifetime_listener() -> std::io::Result<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();

    thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    // Per-stream hold thread: block reading until a genuine
                    // peer EOF, then exit (dropping the stream ends the hold).
                    // A transient read error must NOT drop the stream — the
                    // backend would read the close as "shell dead" and
                    // self-stop with code 0, which the watchdog classifies as
                    // an intentional shutdown, silently quitting the app.
                    thread::spawn(move || {
                        let mut stream = stream;
                        let mut buf = [0u8; 1024];
                        let mut last_error_log: Option<Instant> = None;
                        loop {
                            let result = stream.read(&mut buf);
                            match classify_lifetime_read(&result) {
                                LifetimeReadOutcome::Eof => break,
                                LifetimeReadOutcome::Hold => {
                                    // Data (never happens — the shell never
                                    // writes) keeps holding silently; a
                                    // transient error is logged, rate-limited,
                                    // then retried after a short pause so a
                                    // persistently-erroring read can't
                                    // busy-loop.
                                    if let Err(err) = &result {
                                        let due = last_error_log
                                            .map(|t| t.elapsed() >= LIFETIME_ERROR_LOG_INTERVAL)
                                            .unwrap_or(true);
                                        if due {
                                            crate::shell_log::log(&format!(
                                                "lifetime pipe read error (transient — still holding): {err}"
                                            ));
                                            last_error_log = Some(Instant::now());
                                        }
                                        thread::sleep(LIFETIME_ERROR_RETRY_DELAY);
                                    }
                                }
                            }
                        }
                    });
                }
                Err(err) => eprintln!("[desktop] lifetime listener accept error: {err}"),
            }
        }
    });

    Ok(port)
}

/// Resolves the path to the mix release launcher script bundled as a Tauri
/// resource.
///
/// The release directory is bundled under `resources/genesis-backend/` and
/// contains the standard mix release tree. The launcher script lives at
/// `resources/genesis-backend/bin/genesis_desktop` (`.bat` on Windows).
///
/// Candidate locations are tried in order (shared logic in
/// [`crate::sidecar_path::resolve_launcher`]):
/// 1. `<exe_dir>/resources/genesis-backend/bin/<launcher>` — Nix store layout
///    and Windows (`<exe_dir>` = parent of the running executable).
/// 2. `<resource_dir>/resources/genesis-backend/bin/<launcher>` — macOS
///    bundles (`Contents/Resources`) and Linux deb/AppImage (`/usr/lib/<name>`).
/// 3. `$CARGO_MANIFEST_DIR/resources/genesis-backend/bin/<launcher>` — dev mode.
pub(crate) fn launcher_path(app: &App) -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
    // 1. <exe_dir>/resources/... — Nix store layout and Windows.
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()))
        .unwrap_or_default();

    // 2. <resource_dir>/resources/... — macOS bundles and Linux deb/AppImage.
    //    If tauri cannot resolve a resource dir at all, skip this candidate
    //    rather than failing before the other fallbacks are tried.
    let mut candidate_dirs = vec![exe_dir];
    if let Ok(resource_dir) = app.path().resource_dir() {
        candidate_dirs.push(resource_dir);
    }

    // 3. <manifest_dir>/resources/... — development fallback.
    let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidate_dirs.push(manifest_dir);

    crate::sidecar_path::resolve_launcher(&candidate_dirs, LAUNCHER_NAME)
        .map_err(|msg| -> Box<dyn std::error::Error> { msg.into() })
}

/// Spawns the Phoenix backend by invoking the Elixir release launcher script
/// (`bin/genesis_desktop start`).
///
/// `start` is a **foreground** command — it blocks until the BEAM VM exits,
/// which is exactly what we need so that the spawned PID is the launcher (and
/// ultimately the BEAM process), giving us clean kill semantics on shutdown.
///
/// Returns a [`std::process::Child`] handle that can later be used to kill the
/// process. The child's stdout/stderr are drained on background threads so the
/// output pipes never block and backend errors are surfaced in the console.
///
/// This is the **only** launcher spawn path in the GUI (initial boot and every
/// watchdog restart go through it); it always uses [`launcher_command`], so
/// the Windows `CREATE_NO_WINDOW` handling can never be bypassed.
pub fn spawn(
    launcher: &std::path::Path,
    env: &[(String, String)],
) -> std::io::Result<std::process::Child> {
    let mut child = launcher_command(launcher)
        .arg("start")
        .envs(env.iter().cloned())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    crate::shell_log::log(&format!(
        "spawned genesis-backend sidecar (pid {})",
        child.id()
    ));

    // Drain stdout on a background thread.
    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(text) => println!("[backend] {}", text),
                    Err(_) => break,
                }
            }
        });
    }

    // Drain stderr on a background thread.
    if let Some(stderr) = child.stderr.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                match line {
                    Ok(text) => eprintln!("[backend] {}", text),
                    Err(_) => break,
                }
            }
        });
    }

    Ok(child)
}

/// One-shot HTTP probe: returns the HTTP status code if `url` responds
/// within [`POLL_REQUEST_TIMEOUT`], `None` otherwise. Used by the watchdog to
/// confirm the backend is actually serving (not merely accepting TCP).
pub fn probe_http(url: &str) -> Option<reqwest::StatusCode> {
    let client = match reqwest::blocking::Client::builder()
        .timeout(POLL_REQUEST_TIMEOUT)
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            eprintln!("[desktop] failed to build HTTP client for readiness probe: {err}");
            return None;
        }
    };

    client.get(url).send().ok().map(|resp| resp.status())
}

/// Polls `url` until it responds with an HTTP status or `timeout_secs` elapses.
///
/// Uses a blocking [`reqwest`] client. Returns as soon as the backend answers
/// (regardless of the status code) and logs a clear error if it never comes up.
pub fn wait_for_ready(url: &str, timeout_secs: u64) {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);

    while Instant::now() < deadline {
        match probe_http(url) {
            Some(status) => {
                crate::shell_log::log(&format!("backend is ready at {url} (HTTP {status})"));
                return;
            }
            None => thread::sleep(POLL_INTERVAL),
        }
    }

    eprintln!("[desktop] backend at {url} did not become ready within {timeout_secs}s");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A genuine peer EOF (`Ok(0)`) is the ONLY outcome that ends the hold.
    #[test]
    fn lifetime_read_eof_is_eof() {
        assert_eq!(classify_lifetime_read(&Ok(0)), LifetimeReadOutcome::Eof);
    }

    /// Unexpected data (`Ok(n>0)`) keeps holding — the shell never writes, but
    /// a read that returned bytes must not be misread as a disconnect.
    #[test]
    fn lifetime_read_data_is_hold() {
        assert_eq!(classify_lifetime_read(&Ok(1)), LifetimeReadOutcome::Hold);
        assert_eq!(classify_lifetime_read(&Ok(1024)), LifetimeReadOutcome::Hold);
    }

    /// Every read error is transient-for-holding-purposes: it must keep the
    /// connection open, never be treated as EOF. Treating an error as EOF is
    /// the false-positive channel that makes the backend self-stop and
    /// silently quit the whole app.
    #[test]
    fn lifetime_read_errors_all_hold() {
        for kind in [
            std::io::ErrorKind::Interrupted,
            std::io::ErrorKind::WouldBlock,
            std::io::ErrorKind::ConnectionReset,
            std::io::ErrorKind::ConnectionAborted,
            std::io::ErrorKind::TimedOut,
            std::io::ErrorKind::Other,
        ] {
            let err: std::io::Result<usize> = Err(std::io::Error::new(kind, "transient"));
            assert_eq!(
                classify_lifetime_read(&err),
                LifetimeReadOutcome::Hold,
                "error kind {kind:?} must keep holding"
            );
        }
    }

    /// The log rate-limit window is short enough to be useful and long enough
    /// not to spam (documents the constant's intent).
    #[test]
    fn lifetime_error_log_interval_is_bounded() {
        assert!(LIFETIME_ERROR_LOG_INTERVAL >= Duration::from_secs(1));
        assert!(LIFETIME_ERROR_LOG_INTERVAL <= Duration::from_secs(60));
        assert!(LIFETIME_ERROR_RETRY_DELAY > Duration::ZERO);
        assert!(LIFETIME_ERROR_RETRY_DELAY < LIFETIME_ERROR_LOG_INTERVAL);
    }
}
