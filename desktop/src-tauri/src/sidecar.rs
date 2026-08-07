//! Sidecar lifecycle management.
//!
//! This module spawns the standard Elixir release launcher script
//! (`bin/genesis_desktop start`) as a child process, surfaces its output to the
//! console, and polls its HTTP endpoint until it is ready to serve requests.

use std::io::{BufRead, BufReader};
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

/// The OS-specific launcher script name inside the bundled release directory.
///
/// On Unix this is the POSIX shell script `genesis_desktop`; on Windows it is
/// the batch-file variant `genesis_desktop.bat`.
#[cfg(windows)]
const LAUNCHER_NAME: &str = "genesis_desktop.bat";
#[cfg(not(windows))]
const LAUNCHER_NAME: &str = "genesis_desktop";

/// Environment variables passed to the sidecar process.
///
/// These configure the Phoenix backend to run as a local, single-user
/// server (no distributed Erlang, fixed port, server mode enabled).
///
/// The bind address defaults to `127.0.0.1` (localhost only) for security.
/// Users can override it by setting the `EVOGIT_BIND` environment variable
/// before launching the desktop app (e.g. `EVOGIT_BIND=0.0.0.0` for remote
/// access). The value is passed to Phoenix as `PHX_IP`.
fn sidecar_env() -> Vec<(String, String)> {
    let phx_ip = std::env::var("EVOGIT_BIND").unwrap_or_else(|_| "127.0.0.1".to_string());

    vec![
        ("PORT".to_string(), "9999".to_string()),
        ("PHX_IP".to_string(), phx_ip),
        ("PHX_SERVER".to_string(), "true".to_string()),
        ("SECRET_KEY_BASE".to_string(), SECRET_KEY_BASE.to_string()),
        ("RELEASE_DISTRIBUTION".to_string(), "none".to_string()),
        ("EVOGIT_DESKTOP".to_string(), "1".to_string()),
    ]
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
fn launcher_path(app: &App) -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
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
pub fn start(app: &App) -> Result<std::process::Child, Box<dyn std::error::Error>> {
    let launcher = launcher_path(app)?;

    let mut child = std::process::Command::new(&launcher)
        .arg("start")
        .envs(sidecar_env())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    println!(
        "[desktop] spawned genesis-backend sidecar (pid {})",
        child.id()
    );

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

/// Polls `url` until it responds with an HTTP status or `timeout_secs` elapses.
///
/// Uses a blocking [`reqwest`] client. Returns as soon as the backend answers
/// (regardless of the status code) and logs a clear error if it never comes up.
pub fn wait_for_ready(url: &str, timeout_secs: u64) {
    let deadline = Instant::now() + Duration::from_secs(timeout_secs);

    let client = match reqwest::blocking::Client::builder()
        .timeout(POLL_REQUEST_TIMEOUT)
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            eprintln!("[desktop] failed to build HTTP client for readiness probe: {err}");
            return;
        }
    };

    while Instant::now() < deadline {
        match client.get(url).send() {
            Ok(resp) => {
                println!(
                    "[desktop] backend is ready at {url} (HTTP {})",
                    resp.status()
                );
                return;
            }
            Err(_) => thread::sleep(POLL_INTERVAL),
        }
    }

    eprintln!(
        "[desktop] backend at {url} did not become ready within {timeout_secs}s"
    );
}
