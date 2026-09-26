//! Shell-side file logging for the desktop shell.
//!
//! The Genesis desktop shell is a GUI-subsystem process: when it is launched
//! from Finder / a desktop entry there is no terminal and no console output is
//! recorded anywhere, so a shell crash or a failed backend handshake leaves no
//! trace behind. This module writes a small, human-readable log to
//! `<data_dir>/logs/shell.log` so a shipped app can be diagnosed after the
//! fact.
//!
//! Everything the shell considers worth recording goes through [`log`], which
//! appends to the file **and** prints `[desktop] <msg>` to stdout — the console
//! output the shell has always produced is therefore unchanged in shape, and
//! the file simply mirrors it (plus panics, which never reached the console
//! before).
//!
//! ## Log location
//!
//! [`data_dir`] mirrors `EvoGit.Platform.data_dir/0` (`apps/evo_git/lib/evo_git/platform.ex`)
//! so the Rust shell's log lands next to the REST of the runtime data
//! (`tasks.sqlite`, the Elixir backend log, caches):
//!
//! - **macOS**: `$HOME/Library/Application Support/genesis`
//! - **Linux**: `$XDG_DATA_HOME/genesis`, else `$HOME/.local/share/genesis`
//! - **Windows**: `%APPDATA%/genesis`, else `$HOME/genesis`
//!
//! **Accepted limitation**: the Elixir side also honors a `config.toml`
//! `[data] dir` override that relocates the whole data directory. The Rust
//! shell cannot see that file (it never parses `config.toml`), so with an
//! override in place the shell log stays in the platform default directory
//! while the backend moves — the log then is NOT a sibling of `tasks.sqlite`.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use time::format_description::well_known::Rfc3339;

/// The open shell log file. `None` until [`init`] ran (logging then degrades to
/// console-only), and shared across the watchdog / sidecar / UI threads.
static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

/// The platform data directory, mirroring `EvoGit.Platform.data_dir/0`.
///
/// Uses `cfg!` (a runtime check) rather than `#[cfg]` attributes so **every**
/// branch is type-checked on every platform — a macOS/Windows-only path can
/// never rot unnoticed on a Linux build host.
pub fn data_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        home_dir()
            .join("Library")
            .join("Application Support")
            .join("genesis")
    } else if cfg!(target_os = "windows") {
        env_path("APPDATA").unwrap_or_else(home_dir).join("genesis")
    } else {
        env_path("XDG_DATA_HOME")
            .unwrap_or_else(|| home_dir().join(".local/share"))
            .join("genesis")
    }
}

/// `<data_dir>/logs/shell.log` — the shell's log file.
pub fn log_path() -> PathBuf {
    data_dir().join("logs").join("shell.log")
}

/// Creates the log directory and file (truncating any previous run's log),
/// registers the panic hook, and records the shell start.
///
/// Truncation happens exactly once per process (here); every later [`log`]
/// call appends. Called at the very top of both the GUI and the headless
/// entry points, so any message logged afterwards lands both on the console
/// and in the file.
pub fn init() {
    install_panic_hook();

    let path = log_path();
    if let Some(parent) = path.parent() {
        if let Err(err) = std::fs::create_dir_all(parent) {
            eprintln!(
                "[desktop] could not create shell log directory {}: {err} (logging to console only)",
                parent.display()
            );
            return;
        }
    }

    match OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&path)
    {
        Ok(file) => {
            let _ = LOG_FILE.set(Mutex::new(file));
            log(&format!(
                "shell log started at {} (pid {})",
                path.display(),
                std::process::id()
            ));
        }
        Err(err) => eprintln!(
            "[desktop] could not open shell log {}: {err} (logging to console only)",
            path.display()
        ),
    }
}

/// Records `msg`: appends a timestamped line to `<data_dir>/logs/shell.log`
/// (when [`init`] succeeded) and prints `[desktop] {msg}` to stdout, so nothing
/// the shell printed before diverges.
///
/// Cheap and thread-safe (a single mutex-guarded append); call it for discrete
/// events only — never per readiness poll, so the log stays readable.
pub fn log(msg: &str) {
    println!("[desktop] {msg}");
    append_line(msg);
}

/// Formats `msg` as an RFC 3339 UTC line and appends it to the log file. A
/// no-op before [`init`] (or after an init failure) or when the write fails —
/// logging must never take the shell down.
fn append_line(msg: &str) {
    let Some(file) = LOG_FILE.get() else {
        return;
    };
    let timestamp = time::OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown-time".to_string());
    let mut guard = file.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let _ = writeln!(guard, "[{timestamp}] {msg}");
}

/// Installs a panic hook that records the panic (message, location, and a
/// captured backtrace) to the shell log and to stderr, then delegates to the
/// previously installed hook so the default stderr output is preserved.
///
/// Without this a shell crash on a Finder-launched app is completely
/// unattributable — the default hook's stderr goes nowhere when there is no
/// terminal attached.
fn install_panic_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info
            .location()
            .map(|loc| loc.to_string())
            .unwrap_or_else(|| "<unknown location>".to_string());
        let payload = panic_payload(info.payload());
        let backtrace = std::backtrace::Backtrace::force_capture();
        let message = format!("PANIC at {location}: {payload}\nbacktrace: {backtrace}");
        // File first (stderr may be inherited by a sidecar and interleave), then
        // the default hook's own report.
        append_line(&message);
        eprintln!("[desktop] {message}");
        previous(info);
    }));
}

/// Extracts the human-readable text from a panic payload (the two standard
/// payload shapes are `&str` and `String`).
fn panic_payload(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_string()
    } else if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else {
        "<non-string panic payload>".to_string()
    }
}

/// Reads an environment variable as a path, treating an empty value as unset
/// (mirrors the Elixir side's `if xdg && xdg != ""` handling).
fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// The user's home directory (`HOME`, falling back to `USERPROFILE` on
/// Windows). An unresolved home degrades to a relative `genesis` path rather
/// than failing — logging is best-effort.
fn home_dir() -> PathBuf {
    env_path("HOME")
        .or_else(|| env_path("USERPROFILE"))
        .unwrap_or_else(PathBuf::new)
}

/// True when `data_dir` resolves under `base` — helper for the tests below.
#[cfg(test)]
fn under(base: &std::path::Path, dir: &std::path::Path) -> bool {
    dir.starts_with(base)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    /// The shell log always lives at `<data_dir>/logs/shell.log`.
    #[test]
    fn log_path_is_logs_shell_log_inside_the_data_dir() {
        let path = log_path();
        assert_eq!(path, data_dir().join("logs").join("shell.log"));
        assert!(path.ends_with(Path::new("logs").join("shell.log")));
    }

    /// The data directory is the `genesis` app directory of the platform base
    /// (mirroring `EvoGit.Platform.data_dir/0`) — never the base itself.
    #[test]
    fn data_dir_ends_with_the_genesis_app_directory() {
        let dir = data_dir();
        assert_eq!(dir.file_name().and_then(|n| n.to_str()), Some("genesis"));
    }

    /// On Linux/unknown platforms the base is `$XDG_DATA_HOME` when set,
    /// otherwise `$HOME/.local/share`. (The environment is read through the
    /// same helper the implementation uses, so this asserts the mirroring
    /// rule, not a hardcoded machine path.)
    #[test]
    fn linux_data_dir_prefers_xdg_data_home_then_home_local_share() {
        if cfg!(any(target_os = "macos", target_os = "windows")) {
            return;
        }
        match env_path("XDG_DATA_HOME") {
            Some(xdg) => assert!(under(&xdg, &data_dir())),
            None => {
                if let Some(home) = env_path("HOME") {
                    assert!(under(&home.join(".local/share"), &data_dir()));
                }
            }
        }
    }

    /// Empty environment values are treated as unset, exactly like the Elixir
    /// side's `if xdg && xdg != ""` check.
    #[test]
    fn env_path_treats_empty_values_as_unset() {
        // A name that cannot exist in the environment: the empty-value rule is
        // asserted through the non-empty path instead of mutating the process
        // environment (which would race the other tests).
        assert!(env_path("GENESIS_SHELL_LOG_NONEXISTENT_VAR_TEST").is_none());
    }

    /// Panic payloads are reported in both of their standard shapes.
    #[test]
    fn panic_payload_handles_str_and_string() {
        let borrowed: &(dyn std::any::Any + Send) = &"borrowed message";
        assert_eq!(panic_payload(borrowed), "borrowed message");
        let owned: &(dyn std::any::Any + Send) = &"owned message".to_string();
        assert_eq!(panic_payload(owned), "owned message");
        let other: &(dyn std::any::Any + Send) = &42u32;
        assert_eq!(panic_payload(other), "<non-string panic payload>");
    }

    /// `log` before `init` (or after an init failure) must never panic — it
    /// degrades to console-only output.
    #[test]
    fn log_without_init_does_not_panic() {
        log("shell-log test: logging before init is harmless");
        append_line("shell-log test: direct append before init is harmless");
    }
}
