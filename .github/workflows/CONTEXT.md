# `.github/workflows/` — CI/CD Pipelines

## Intent

CI/CD workflow definitions for the Genesis project. Two pipelines: a lightweight CI gate on PRs/pushes to `main` and a comprehensive desktop-app release build triggered by GitHub releases.

## Routing Table

None — leaf directory (two workflow files: `ci.yml`, `build-desktop.yml`).

## API Surface

### `ci.yml` — Continuous Integration
Triggered on PRs and pushes to `main`. Three parallel jobs on `ubuntu-latest`:
- **test** — Runs `mix test` for both apps. Uses the Erlang/OTP + Elixir setup action (versions from the `OTP_VERSION`/`ELIXIR_VERSION` env vars), caches `deps/` and `_build/`, and fetches deps before testing.
- **format** — Runs `mix format --check-formatted` to enforce code style.
- **compile** — Runs `mix compile --warnings-as-errors` to catch warnings.

No Rust/C toolchain is required — NIF dependencies use precompiled binaries.

### `build-desktop.yml` — Desktop App Release Build
Triggered on **GitHub releases** (published, including pre-releases) and manual `workflow_dispatch`. Builds native desktop installers + the headless remote daemon tarball.

**Build process** (12 steps per platform):
1. Checkout code
2. Set up Erlang/OTP + Elixir (`ELIXIR_VERSION` env var pins Elixir 1.20.3; `OTP_VERSION` pins OTP 29)
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

**Platform matrix** (5 jobs, each on native runners):

| Platform | Runner | Installer Formats |
|----------|--------|-------------------|
| macOS ARM64 | `macos-14` | `.dmg`, `.app` |
| Linux x86_64 | `ubuntu-24.04` | `.deb`, `.rpm`, AppImage, `.tar.gz` |
| Linux ARM64 | `ubuntu-24.04-arm` | `.deb`, `.rpm`, `.tar.gz` (NO AppImage — `appimagetool`/`linuxdeploy` are x86_64-only) |
| Linux Remote musl (x64 only) | `ubuntu-24.04` (Alpine container) | `genesis_remote` musl `.tar.xz` only (no desktop installers) |
| Windows x86_64 | `windows-2022` | `.msi`, `.exe` (NSIS) |

**Platform-specific quirks**:
- **ARM64 ImageOS fix**: GitHub ARM partner runners report unrecognized `ImageOS` values; the workflow sets `ImageOS=ubuntu24` via `$GITHUB_ENV` before `erlef/setup-beam`.
- **Windows**: Uses `robocopy` (not `cp -a`) for release copy; `pwsh` for shell steps.
- **Linux x86_64**: Downloads musl-linked ripgrep (static binary). AppImage bundling requires the wxWidgets 3.2 runtime because the desktop release's wx NIFs link against wxWidgets 3.2 sonames — linuxdeploy fails with the generic "failed to run linuxdeploy" without it (see desktop/src-tauri/CONTEXT.md → Known Issues). On ubuntu-24.04 the wx 3.2 runtime is plain-apt-installed from Ubuntu's default repos (`libwxbase3.2-1t64`, `libwxgtk3.2-1t64`, `libwxgtk-gl3.2-1t64`, `libwxgtk-webview3.2-1t64` + `libglu1-mesa`) in the "Install wxWidgets 3.2 runtime (AppImage bundling)" step, gated to x64 — no PPA needed.
- **Nix environment variable** (`NIX_PATH`): passed through to release build steps.

**Cache layers**: Mix deps (`deps/`), Mix build (`_build/`), Rust target (`Swatinem/rust-cache@v2`), Tauri CLI. The CLI is installed from npm `@tauri-apps/cli` (prebuilt binaries for all platforms, including linux-arm64-gnu) and cached in `~/tauri-cli` (POSIX) / `%APPDATA%\npm` (Windows); the `tauri` bin dir is appended to PATH unconditionally so a cache hit still yields a working CLI.

**Known issues**:
- **tauri-cli has no prebuilt aarch64-linux-gnu binary**: `tauri-cli` GitHub Releases ship prebuilt binaries for x86_64-linux, macOS, and Windows only — not linux-arm64. `cargo-binstall` therefore falls back to `cargo install` (full source compile) on the `ubuntu-24.04-arm` job, which is slow and flaky. The action instead installs the npm package `@tauri-apps/cli`, which ships prebuilt binaries for all platforms including `linux-arm64-gnu`. Never fall back to `cargo install` for the CLI: transitive dep `zune-jpeg 0.5.15` (`image 0.25.10` → `tauri-bundler 2.9.4`) has a known compile bug ("macro expansion ends with an incomplete expression" at `src/mcu_prog.rs:463`; upstream `zune-image` issue #424) that makes source compiles flaky and slow, and deps can't be pinned via `cargo install`. Because the npm wrapper passes args through verbatim while `cargo` prepends `tauri` as argv[1], builds must invoke `tauri build` — `cargo tauri build` does NOT work with the npm-installed CLI (`error: unrecognized subcommand 'tauri'`).
- **`mix release` hangs on cached `_build`**: the Mix build cache (`_build/`) is keyed by OTP/Elixir/mix.lock, not the project version. A restored cache contains an already-built release for the current version, and `mix release` blocks on the interactive `Release X already exists. Overwrite? [Yn]` prompt — which hangs forever in non-TTY CI. All release jobs therefore pass `--overwrite` to `mix release` (both `genesis_desktop` and `genesis_remote`). Never remove `--overwrite`, and keep it in sync across all jobs.
- **Remote daemon package is `.tar.xz`**: the headless `genesis_remote` tarball is compressed with xz (`tar -cJf`) for a smaller remote-bootstrap download, while the desktop portable archive stays `.tar.gz` (the `.tar.gz` entries in the platform matrix above refer to that desktop archive). All runner OSes support xz natively (ubuntu-24.04/arm ship xz-utils, macOS bsdtar has bundled liblzma, Windows bsdtar.exe supports `-J`) — future platform additions should keep xz rather than falling back to gzip.
- **Linux musl build (`build-linux-remote-musl`, x64-only)**: builds `genesis_remote` only (no `genesis_desktop`, no Tauri, no assets) in an Alpine Docker container (the image `hexpm/elixir:1.20.3-erlang-29.0.5-alpine-3.22.5` is hardcoded directly in the `container.image` field of the `build-linux-remote-musl` job — GitHub Actions does not allow the `env` context in `container.image`, so it cannot be a workflow-level env var). nodejs is `apk add`-ed FIRST (before checkout) because the runner's bundled Node.js is glibc-linked and won't run in the musl container — all JavaScript Actions (checkout, cache, upload-artifact) need it. The x86_64 musl job downloads the `x86_64-unknown-linux-musl` ripgrep 15.1.0 prebuilt. The precompiled Rust NIF `.so` files (xqlite's SQLite NIF) dynamically link `libgcc_s.so.1` for stack unwinding — not present on minimal Alpine systems — so `libgcc_s.so.1` is bundled into the release's `lib/runtime/` directory and `rel/env.sh.eex` sets `LD_LIBRARY_PATH` to include it. Target logic (`linux-x64` / `all`) via the dynamic matrix in the `prepare` job — no separate workflow_dispatch option.
- **Musl ARM64 removed (GitHub limitation)**: the musl arm64 build was removed because GitHub Actions JavaScript actions (checkout, cache, upload-artifact) are not supported inside Alpine containers on ARM64 runners — the arm64 job failed at `actions/checkout` with the exact error "JavaScript Actions in Alpine containers are only supported on x64 Linux runners. Detected Linux Arm64". The glibc arm64 `genesis_remote` tarball from `build-linux` remains the linux arm64 remote asset. A future re-add would require restructuring the job so checkout/cache/upload-artifact run on the host runner with only the build steps wrapped in explicit `docker run` invocations of the Alpine image (a job-level `container:` cannot work on arm64).
## Constraints

- Triggered by release events and manual dispatch only — no branch-push triggers (those are CI).
- Each platform builds natively — no cross-compilation.
- The `genesis_remote` tarball is uploaded alongside desktop installers as a release asset.
- The workflow file is the single source of truth for the release build process.
- Release assets are **unversioned** with permanent `releases/latest/download/<name>` links (e.g. `genesis_desktop_darwin_arm64.dmg`); the version comes from the release tag and is baked into the app at build time, never into the filename.
- **`genesis_remote` Linux naming convention**: the unsuffixed musl-default name exists only for linux x64 — `genesis_remote_linux_x64.tar.xz` (no suffix; built by `build-linux-remote-musl`). The glibc build (built by `build-linux`) carries a `_glibc` suffix — `genesis_remote_linux_x64_glibc.tar.xz` and `genesis_remote_linux_arm64_glibc.tar.xz` — and linux arm64 remote tarballs exist ONLY with the `_glibc` suffix. Non-linux remote tarballs (darwin, windows) are unchanged. `EvoGit.RemoteBootstrap` (apps/evo_git/lib/evo_git/remote_bootstrap.ex) depends on the unsuffixed `genesis_remote_<platform>.tar.xz` naming for its default download (the musl build).
