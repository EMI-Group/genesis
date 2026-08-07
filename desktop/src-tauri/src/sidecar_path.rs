//! Shared resolution of the Elixir release launcher path.
//!
//! Both the GUI mode ([`crate::sidecar`]) and the headless mode (crate root)
//! need to locate the mix release launcher script inside the bundled
//! `resources/genesis-backend/` directory. The exact layout depends on how the
//! app is packaged:
//!
//! - Nix store / Windows: `<exe_dir>/resources/genesis-backend/bin/<launcher>`
//! - macOS bundle: `<resource_dir>/resources/genesis-backend/bin/<launcher>`
//!   (`Contents/Resources`)
//! - Linux deb / AppImage: `<resource_dir>/resources/genesis-backend/bin/<launcher>`
//!   (`/usr/lib/<name>`)
//! - Source tree (development): `$CARGO_MANIFEST_DIR/resources/genesis-backend/bin/<launcher>`
//!
//! [`resolve_launcher`] picks the first candidate that exists on disk, so each
//! caller can pass the base directories it knows about without duplicating the
//! fallback logic. Keeping this in one place prevents the GUI and headless
//! resolvers from drifting apart.

use std::path::{Path, PathBuf};

/// Path, relative to a candidate base directory, of the launcher script.
const LAUNCHER_REL: &str = "resources/genesis-backend/bin";

/// Picks the first launcher path that exists, in candidate order.
///
/// For each base directory in `candidate_dirs` the candidate
/// `<dir>/resources/genesis-backend/bin/<launcher_name>` is tested with
/// [`Path::exists`]. The first existing one is returned. If none exist, an
/// error listing every candidate tried is returned — resolution never silently
/// continues past a missing launcher.
pub fn resolve_launcher(
    candidate_dirs: &[PathBuf],
    launcher_name: &str,
) -> Result<PathBuf, String> {
    let candidates: Vec<PathBuf> = candidate_dirs
        .iter()
        .map(|dir| dir.join(LAUNCHER_REL).join(launcher_name))
        .collect();

    for candidate in &candidates {
        if candidate.exists() {
            return Ok(candidate.clone());
        }
    }

    Err(format!(
        "release launcher '{launcher_name}' not found — looked in {}",
        candidates
            .iter()
            .map(|c| format!("{:?}", c))
            .collect::<Vec<_>>()
            .join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Create a unique, empty temporary directory for a test.
    fn unique_temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "genesis-desktop-path-test-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock before unix epoch")
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    /// Write a placeholder launcher file under a candidate base dir.
    fn write_launcher(base: &Path, launcher_name: &str) -> PathBuf {
        let path = base.join(LAUNCHER_REL).join(launcher_name);
        std::fs::create_dir_all(path.parent().expect("launcher has parent"))
            .expect("create launcher dirs");
        std::fs::write(&path, "#!/bin/sh\n").expect("write launcher");
        path
    }

    #[test]
    fn prefers_earlier_candidates_over_later_ones() {
        let root = unique_temp_dir("order");
        let exe_dir = root.join("exe");
        let resource_dir = root.join("resource");
        let manifest_dir = root.join("manifest");

        // The launcher exists under every candidate base — the first one in
        // the list (exe_dir) must win.
        write_launcher(&exe_dir, "genesis_desktop");
        write_launcher(&resource_dir, "genesis_desktop");
        write_launcher(&manifest_dir, "genesis_desktop");

        let result = resolve_launcher(
            &[exe_dir.clone(), resource_dir.clone(), manifest_dir.clone()],
            "genesis_desktop",
        );

        assert_eq!(result, Ok(exe_dir.join(LAUNCHER_REL).join("genesis_desktop")));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn returns_first_existing_candidate() {
        let root = unique_temp_dir("fallback");
        let exe_dir = root.join("exe");
        let resource_dir = root.join("resource");

        // Only the resource_dir candidate exists on disk.
        write_launcher(&resource_dir, "genesis_desktop");

        let result = resolve_launcher(&[exe_dir.clone(), resource_dir.clone()], "genesis_desktop");

        assert_eq!(
            result,
            Ok(resource_dir.join(LAUNCHER_REL).join("genesis_desktop"))
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn returns_descriptive_error_when_no_candidate_exists() {
        let root = unique_temp_dir("missing");
        let exe_dir = root.join("exe");
        let resource_dir = root.join("resource");

        let err = resolve_launcher(&[exe_dir.clone(), resource_dir.clone()], "genesis_desktop")
            .expect_err("no candidate exists, must error");

        assert!(
            err.contains("genesis_desktop"),
            "error should name the launcher: {err}"
        );
        assert!(
            err.contains(&format!(
                "{:?}",
                exe_dir.join(LAUNCHER_REL).join("genesis_desktop")
            )),
            "error should list the exe_dir candidate: {err}"
        );
        assert!(
            err.contains(&format!(
                "{:?}",
                resource_dir.join(LAUNCHER_REL).join("genesis_desktop")
            )),
            "error should list the resource_dir candidate: {err}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn empty_candidate_list_still_errors_descriptively() {
        let err = resolve_launcher(&[], "genesis_desktop").expect_err("no candidates, must error");
        assert!(err.contains("genesis_desktop"), "error should name the launcher: {err}");
    }
}
