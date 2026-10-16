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
- Refreshing `mixFodDeps.hash` after a `mix deps.update --all` does NOT require a full `nix build`: set `hash = lib.fakeHash;`, then locate and realize only the dependency FOD — `nix eval --raw .#default.drvPath` → `nix-store -q --references <drv> | grep -i mix-deps` → `nix-store --realise <fod.drv>` — whose hash-mismatch error prints the correct `sha256-...` value, and whose exit 0 after pasting it in verifies the new hash.
- `precompiled_nifs` holds one entry per Rustler NIF package — a `prefix` (`libmdex_native_nif-v0.2.11-nif-2.15`), a `urlPrefix` (the GitHub release download URL) and `hashes`, a map keyed by Rust target triple (`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `x86_64-apple-darwin`, `aarch64-apple-darwin`). `nifAssets` resolves each entry for `stdenv.hostPlatform` into the `{ name, file }` pairs that the `preConfigure` hook copies into `$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH`: `name` must reproduce the real release asset filename or `rustler_precompiled` misses the cache and tries to download inside the (network-less) build sandbox. A `rustTarget` with no pinned hash fails evaluation with an explicit `throw` instead of silently fetching a foreign asset.
- Every NIF asset hash is **platform-specific** — the same version+ABI ships different bytes per target triple — so refreshing `precompiled_nifs` is a per-release-asset job, not a per-version one: download each target's asset (e.g. `https://github.com/leandrocp/mdex_native/releases/download/v<version>/<prefix>-<rustTarget>.so.tar.gz`) and hash it with `nix hash file --sri <file>` (flat SHA-256, which is what `fetchurl` verifies). Reuse the same realize-the-FOD check for each entry: `nix eval --raw .#default.drvPath` → `nix-store -q --references <drv> | grep '\.so\.tar\.gz'` → `nix-store --realise <fod.drv>` per FOD (exit 0 proves the pin).
- Never guess a `precompiled_nifs` asset name or its ABI suffix: both the library prefix (`libmdex_native_nif` vs `libxqlitenif`) and the ABI suffix (`nif-2.15` for mdex_native, `nif-2.17` for xqlite, tracking the OTP ABI each package was built against) are per-package, and the version comes from `mix.lock`. Read the real asset names off the GitHub release listing for that version (the hex package's unpacked `priv/native/*.so`, or its `checksum-Erlang-*.exs`, shows the same name) and update `prefix` + `urlPrefix` + `hashes` together on a bump.
- `mixFodDeps` covers Hex deps only, so a NIF bump needs BOTH the `mixFodDeps.hash` refresh AND the `precompiled_nifs` entry update; verify each separately with `nix-store --realise <fod.drv>` on the drv referenced by `nix eval --raw .#default.drvPath`.
- Scripts in this directory are designed to run inside the `nix develop` shell where `curl`, `git`, and `rg` are available.
- `bundle-vendor.sh` is only needed for the manual `nix develop` → `mix release` workflow. The `nix build` path handles vendor binaries via the derivation's `postInstall` hook.

## See Also

- `../flake.nix` — Flake entry point: `nix run` (CLI), `nix run .#desktop` (Tauri), `nix develop` (dev shell)
- `../genesis.nix` — Nix derivation for the CLI Mix release (`genesis`). Parameterized with `mixReleaseName`; call with `mixReleaseName = "genesis_desktop"` for the desktop variant.
- `../genesis-desktop.nix` — Nix derivation for the Tauri desktop app. Builds the `genesis_desktop` Mix release, builds the Tauri Rust binary via `rustPlatform.buildRustPackage`, and wraps them together with `makeWrapper`.
