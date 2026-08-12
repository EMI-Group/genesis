# Nix — NixOS Build Support

## Intent

Nix build support for Genesis. The primary entry points are the flake at the repository root (`flake.nix`) and the two derivations it calls. Users can build the CLI app or the Tauri desktop app directly with `nix build`/`nix run`.

## Routing Table

- None — leaf directory (single script: `bundle-vendor.sh`).

## API Surface

| File | Purpose |
|------|---------|
| `bundle-vendor.sh` | Downloads ripgrep and copies system git into `apps/evo_git/priv/vendor/<platform>/`, replicating the "Bundle vendor binaries" step from `.github/workflows/build-desktop.yml`. Auto-detects x86_64/aarch64 Linux targets. |

## Constraints

- The Nix expressions (`flake.nix`, `genesis.nix`, `genesis-desktop.nix`) live at the repository ROOT, not here.

- **No `cargoHash` maintenance**: `genesis-desktop.nix` vendors Rust deps via `cargoLock.lockFile = ./desktop/src-tauri/Cargo.lock` — the vendor store path derives from the lock file, so updating Cargo.lock never requires a hash edit. Only git deps would need `cargoLock.outputHashes`. Both derivations read `version` from the repo-root `VERSION` file (`lib.fileContents ./VERSION`) — never hardcode it. The only flake hash that still needs manual updates is `mixFodDeps.hash` in `genesis.nix` (when `mix.lock` changes).
- Scripts in this directory are designed to run inside the `nix develop` shell where `curl`, `git`, and `rg` are available.
- `bundle-vendor.sh` is only needed for the manual `nix develop` → `mix release` workflow. The `nix build` path handles vendor binaries via the derivation's `postInstall` hook.

## See Also

- `../flake.nix` — Flake entry point: `nix run` (CLI), `nix run .#desktop` (Tauri), `nix develop` (dev shell)
- `../genesis.nix` — Nix derivation for the CLI Mix release (`genesis`). Parameterized with `mixReleaseName`; call with `mixReleaseName = "genesis_desktop"` for the desktop variant.
- `../genesis-desktop.nix` — Nix derivation for the Tauri desktop app. Builds the `genesis_desktop` Mix release, builds the Tauri Rust binary via `rustPlatform.buildRustPackage`, and wraps them together with `makeWrapper`.
