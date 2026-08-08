# `.github/workflows/` — CI/CD Pipelines

## Intent

CI/CD workflow definitions for the Genesis project. Two pipelines: a lightweight CI gate on PRs/pushes to `main` and a comprehensive desktop-app release build triggered by GitHub releases.

## Routing Table

None — leaf directory (two workflow files: `ci.yml`, `build-desktop.yml`).

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
5. Cache Mix deps (`deps/`), Mix build (`_build/`), Rust target, Tauri CLI (npm `@tauri-apps/cli`, cached in `~/tauri-cli`)
6. Fetch Mix deps + compile
7. Bundle assets (`assets.setup` + `assets.deploy`)
8. Bundle vendor binaries (ripgrep, git)
9. Build `genesis_desktop` release (`MIX_ENV=prod mix release genesis_desktop`)
10. Build `genesis_remote` release (`MIX_ENV=prod mix release genesis_remote`) — headless daemon tarball
11. Copy release to `desktop/src-tauri/resources/genesis-backend/`
12. Build Tauri app (`tauri build`) → native installers

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

**Cache layers**: Mix deps (`deps/`), Mix build (`_build/`), Rust target (`Swatinem/rust-cache@v2`), Tauri CLI. The CLI is installed from npm `@tauri-apps/cli` (prebuilt binaries for all platforms, including linux-arm64-gnu) and cached in `~/tauri-cli` (POSIX) / `%APPDATA%\npm` (Windows); the `tauri` bin dir is appended to PATH unconditionally so a cache hit still yields a working CLI.

**Known issues**:
- **tauri-cli has no prebuilt aarch64-linux-gnu binary**: `tauri-cli` GitHub Releases ship prebuilt binaries for x86_64-linux, macOS, and Windows only — not linux-arm64. `cargo-binstall` therefore falls back to `cargo install` (full source compile) on the `ubuntu-24.04-arm` job, which is slow and flaky. The action instead installs the npm package `@tauri-apps/cli`, which ships prebuilt binaries for all platforms including `linux-arm64-gnu`. Never fall back to `cargo install` for the CLI: transitive dep `zune-jpeg 0.5.15` (`image 0.25.10` → `tauri-bundler 2.9.4`) has a known compile bug ("macro expansion ends with an incomplete expression" at `src/mcu_prog.rs:463`; `zune-core 0.5.2` yanked 2026-08-07, fixed by 0.5.3 the same day; upstream `zune-image` issue #424) that makes source compiles flaky and slow (~3-5 min per cache miss), and deps can't be pinned via `cargo install` (resolution is timing-dependent). Because the npm wrapper passes args through verbatim while `cargo` prepends `tauri` as argv[1], builds must invoke `tauri build` — `cargo tauri build` does NOT work with the npm-installed CLI (`error: unrecognized subcommand 'tauri'`).

## Constraints

- Triggered by release events and manual dispatch only — no branch-push triggers (those are CI).
- Each platform builds natively — no cross-compilation.
- The `genesis_remote` tarball is uploaded alongside desktop installers as a release asset.
- The workflow file is the single source of truth for the release build process.
- Release assets are **unversioned** with permanent `releases/latest/download/<name>` links (e.g. `genesis_desktop_darwin_arm64.dmg`, `genesis_remote_linux_x64.tar.gz`); the version comes from the release tag and is baked into the app at build time, never into the filename. `EvoGit.RemoteBootstrap` (apps/evo_git/lib/evo_git/remote_bootstrap.ex) depends on the `genesis_remote_<platform>.tar.gz` naming.
