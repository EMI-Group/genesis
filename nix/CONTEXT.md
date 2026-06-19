# `nix/` — NixOS Build Support

## Intent

Helper scripts for building the EvoGit desktop app on NixOS. The primary entry point is the flake at the repository root (`flake.nix`), which provides a complete development shell. The scripts in this directory replicate CI build steps that need adaptation for local NixOS use.

## API Surface

| File | Purpose |
|------|---------|
| `bundle-vendor.sh` | Downloads ripgrep and copies system git into `apps/evo_git/priv/vendor/<platform>/`, replicating the "Bundle vendor binaries" step from `.github/workflows/build-desktop.yml`. Auto-detects x86_64/aarch64 Linux targets. |

## Constraints

- This directory contains no Nix expressions — the flake lives at the repository root (`flake.nix`).
- Scripts are designed to run inside the `nix develop` shell where `curl`, `git`, and `rg` are available.
