# `.github/workflows/` — CI/CD Pipelines

## Intent

CI/CD workflow definitions for the Genesis project. Two pipelines: a lightweight CI gate on PRs/pushes to `main` and a comprehensive desktop-app release build triggered by GitHub releases.

## API Surface

### `ci.yml` — Continuous Integration
Triggered on PRs and pushes to `main`. Three parallel jobs on `ubuntu-latest`:
- **test** — Runs `mix test` for both apps. Uses the Erlang/OTP + Elixir setup action (pinned via `.tool-versions`), caches `deps/` and `_build/`, and fetches deps before testing.
- **format** — Runs `mix format --check-formatted` to enforce code style.
- **compile** — Runs `mix compile --warnings-as-errors` to catch warnings.

No Rust/C toolchain is required — NIF dependencies use precompiled binaries.

### `build-desktop.yml` — Desktop App Release Build
Triggered on **GitHub releases** (published, including pre-releases) and manual `workflow_dispatch`. Builds native desktop installers + the headless remote daemon tarball.

**Build process** (12 steps per platform):
1. Checkout code
2. Set up Erlang/OTP + Elixir (`.tool-versions` pins OTP 29, Elixir 1.20.1)
3. Set up Rust toolchain (stable)
4. Install system dependencies (Linux: webkit2gtk, libayatana, libdbus; macOS: none; Windows: none)
5. Cache Mix deps (`deps/`), Mix build (`_build/`), Rust target, Tauri CLI
6. Fetch Mix deps + compile
7. Bundle assets (`assets.setup` + `assets.deploy`)
8. Bundle vendor binaries (ripgrep, git)
9. Build `genesis_desktop` release (`MIX_ENV=prod mix release genesis_desktop`)
10. Build `genesis_remote` release (`MIX_ENV=prod mix release genesis_remote`) — headless daemon tarball
11. Copy release to `desktop/src-tauri/resources/genesis-backend/`
12. Build Tauri app (`cargo tauri build`) → native installers

**Platform matrix** (4 parallel jobs, each on native runners):

| Platform | Runner | Installer Formats |
|----------|--------|-------------------|
| macOS ARM64 | `macos-14` | `.dmg`, `.app` |
| Linux x86_64 | `ubuntu-24.04` | `.deb`, `.rpm`, AppImage, `.tar.gz` |
| Linux ARM64 | `ubuntu-24.04-arm` | `.deb`, `.rpm`, `.tar.gz` (NO AppImage — `appimagetool`/`linuxdeploy` are x86_64-only) |
| Windows x86_64 | `windows-2022` | `.msi`, `.exe` (NSIS) |

**Platform-specific quirks**:
- **ARM64 ImageOS fix**: GitHub ARM partner runners report unrecognized `ImageOS` values; the workflow sets `ImageOS=ubuntu24` via `$GITHUB_ENV` before `erlef/setup-beam`.
- **Windows**: Uses `robocopy` (not `cp -a`) for release copy; `pwsh` for shell steps.
- **Linux x86_64**: Downloads musl-linked ripgrep (static binary).
- **Nix environment variable** (`NIX_PATH`): passed through to release build steps.

**Cache layers**: Mix deps (`deps/`), Mix build (`_build/`), Rust target (`Swatinem/rust-cache@v2`), Tauri CLI binary.

## Constraints

- Triggered by release events and manual dispatch only — no branch-push triggers (those are CI).
- Each platform builds natively — no cross-compilation.
- The `genesis_remote` tarball is uploaded alongside desktop installers as a release asset.
- The workflow file is the single source of truth for the release build process.
- Version is read from the root `VERSION` file.
