//! Sidecar lifecycle management.
//!
//! This module spawns the Burrito-wrapped Elixir release binary
//! (`genesis-backend`) as a child process, surfaces its output to the console,
//! and polls its HTTP endpoint until it is ready to serve requests.

use std::thread;
use std::time::{Duration, Instant};

use tauri::App;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

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

/// Spawns the Burrito-wrapped Phoenix backend as a sidecar process.
///
/// Returns a [`CommandChild`] handle that can later be used to kill the
/// process. The sidecar's stdout/stderr are drained on a background task so
/// the output channel never blocks and backend errors are surfaced in the
/// console.
pub fn start(app: &App) -> Result<CommandChild, Box<dyn std::error::Error>> {
    let (mut rx, child) = app
        .shell()
        .sidecar("genesis-backend")?
        .envs(sidecar_env())
        .spawn()?;

    println!(
        "[desktop] spawned genesis-backend sidecar (pid {})",
        child.pid()
    );

    // Drain sidecar output on a background async task.
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(bytes) => {
                    println!("[backend] {}", String::from_utf8_lossy(&bytes).trim_end());
                }
                CommandEvent::Stderr(bytes) => {
                    eprintln!("[backend] {}", String::from_utf8_lossy(&bytes).trim_end());
                }
                CommandEvent::Terminated(status) => {
                    eprintln!("[backend] process terminated: {:?}", status);
                    break;
                }
                _ => {}
            }
        }
    });

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
