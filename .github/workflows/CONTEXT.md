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
Triggered by **tag pushes** (`push: tags: ['v*']`, e.g. `git push origin v1.2.3`) and manual `workflow_dispatch`. The `release` event is deliberately NOT listened to — releases are created by pushing a tag. Builds native desktop installers + the headless remote daemon tarball.

**Trigger semantics**: a tag push `v*` builds all platforms and runs the full release path (draft → published); `workflow_dispatch` defaults to `target: macos-arm64` build-only (no release), while `publish_release: true` requires the `tag` input and runs the full draft→publish release path for the selected target's artifacts.

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
10. Build `genesis_remote` release (`MIX_ENV=prod mix release genesis_remote`) — headless daemon tarball (Linux desktop job excepted; the Linux remote tarballs come from the dedicated `build-linux-remote` job)
11. Copy release to `desktop/src-tauri/resources/genesis-backend/`
12. Build Tauri app (`tauri build`) → native installers

**Platform matrix** (5 jobs, each on native runners):

| Platform | Runner | Installer Formats |
|----------|--------|-------------------|
| macOS ARM64 | `macos-14` | `.dmg`, `.app` |
| Linux x86_64 | `ubuntu-24.04` | `.deb`, `.rpm`, AppImage, `.tar.gz` |
| Linux ARM64 | `ubuntu-24.04-arm` | `.deb`, `.rpm`, `.tar.gz` (NO AppImage — `appimagetool`/`linuxdeploy` are x86_64-only) |
| Linux Remote (glibc) | `ubuntu-22.04` (x64) / `ubuntu-22.04-arm` (arm64) | `genesis_remote_linux_x64.tar.xz` / `genesis_remote_linux_arm64.tar.xz` (both glibc, unsuffixed) — no desktop installers |
| Windows x86_64 | `windows-2022` | `.msi`, `.exe` (NSIS) |

**Platform-specific quirks**:
- **ARM64 ImageOS fix**: GitHub ARM partner runners report unrecognized `ImageOS` values; the workflow sets `ImageOS` via `$GITHUB_ENV` before `erlef/setup-beam` (`ubuntu24` on `build-linux`, `ubuntu22` on `build-linux-remote`).
- **`build-linux-remote` runs on ubuntu-22.04** (x64 + arm64) — the dedicated `genesis_remote` glibc build — for a wider glibc (2.35) compatibility range than the desktop build's ubuntu-24.04. The pinned `.github/actions/setup-mix` (setup-beam) supports ubuntu-22.04 with OTP 29 / Elixir 1.20.3: the pinned setup-beam's README support matrix lists `ubuntu-22.04 | 24.2 - 29 | x86_64, arm64`, builds.hex.pm ships precompiled OTP-29.0.5 builds for both amd64 and arm64 ubuntu-22.04 (the floating `"29"` resolves to OTP-29.0.5), and Elixir precompiled zips are platform-independent — no `compile: true` fallback is needed.
- **Desktop stays on ubuntu-24.04**: `build-linux` uses ubuntu-24.04 (x64/arm64) because the AppImage bundling requires the wxWidgets 3.2 runtime, which only noble's default repos ship.
- **Windows**: Uses `robocopy` (not `cp -a`) for release copy; `pwsh` for shell steps.
- **Linux x86_64**: Downloads musl-linked ripgrep (static binary). AppImage bundling requires the wxWidgets 3.2 runtime because the desktop release's wx NIFs link against wxWidgets 3.2 sonames — linuxdeploy fails with the generic "failed to run linuxdeploy" without it (see desktop/src-tauri/CONTEXT.md → Known Issues). On ubuntu-24.04 the wx 3.2 runtime is plain-apt-installed from Ubuntu's default repos (`libwxbase3.2-1t64`, `libwxgtk3.2-1t64`, `libwxgtk-gl3.2-1t64`, `libwxgtk-webview3.2-1t64` + `libglu1-mesa`) in the "Install wxWidgets 3.2 runtime (AppImage bundling)" step, gated to x64 — no PPA needed.
- **Nix environment variable** (`NIX_PATH`): passed through to release build steps.

**Cache layers**: Mix deps (`deps/`), Mix build (`_build/`), Rust target (`Swatinem/rust-cache@v2`), Tauri CLI. The CLI is installed from npm `@tauri-apps/cli` (prebuilt binaries for all platforms, including linux-arm64-gnu) and cached in `~/tauri-cli` (POSIX) / `%APPDATA%\npm` (Windows); the `tauri` bin dir is appended to PATH unconditionally so a cache hit still yields a working CLI.

**Release publishing & auto-update readiness** (current state, verified Aug 2026):
- **Publish step (draft → public)**: `publish-release` job (build-desktop.yml:745-801) uses `softprops/action-gh-release@c12583777ecdfd3be55c69cf75464299dc01057e # v3` — that SHA is the **annotated-tag object of v3.0.2** (the REST API cannot resolve it as a commit; `git cat-file` on a clone resolves it to `3d0d988 release 3.0.2 (#818)`). The job creates/updates a **draft** release (`draft: true`, `name: Genesis <release_version>`, `prerelease` derived from the tag containing a hyphen, `fail_on_unmatched_files: true`) and uploads ALL artifacts, then flips it public with `gh release edit --draft=false` as the FINAL step — so `releases/latest` never resolves to a release lacking assets. Re-runs are idempotent: v3.0.2's `overwrite_files: true` default overwrites same-named assets on an existing release, the `draft`/`prerelease` inputs only apply at creation (they do not flip an existing release's state), and the gh edit is a no-op on an already-published release. If the tag's release doesn't exist (e.g. manual dispatch with a new tag), softprops creates tag+draft via the API — API-created tags/releases never fire `push`/`release` workflow events (GITHUB_TOKEN actions never re-trigger workflows), so there is no loop. Version = tag with the leading `v` stripped (prepare outputs `release_version` + `is_prerelease`; a future `latest.json` manifest step would use `release_version`). `concurrency.cancel-in-progress: true` (lines 30-35) means re-publishing the same tag cancels the previous run mid-flight — a partially-updated release is possible until the new run completes (end state converges; no stale-asset cleanup: removed asset names stay attached).
- **No update machinery exists**: no tauri-plugin-updater (Cargo.toml tauri features are only `devtools, tray-icon`), no updater config in tauri.conf.json, no Sparkle appcast / minisign / `latest.json` / checksum files (`.sha256`/`.sig`/`.asc`) anywhere in the repo or workflows. The only "latest" mechanism is GitHub's `releases/latest/download/` redirect over unversioned asset names (README.md:164-177 documents the permanent links). No release-asset checksums are generated (sha256 checks in the workflow verify only vendored ripgrep/MinGit downloads).
- **Signing status by platform**: macOS fully signed+notarized (Developer ID keychain import → `desktop/scripts/sign-macos-nested.sh` for nested ERTS Mach-Os → tauri codesign → `notarize-macos-dmg.sh` + `verify-macos-artifacts.sh`; secrets APPLE_CERTIFICATE, APPLE_CERTIFICATE_PASSWORD, APPLE_SIGNING_IDENTITY, APPLE_API_ISSUER, APPLE_API_KEY, APPLE_API_KEY_P8_BASE64). Note: only the DMG is notarized+stapled; the staged `genesis_desktop_darwin_arm64.app.zip` is a `ditto -c -k --keepParent` of the signed app and relies on online ticket validation. **Windows is NOT Authenticode-signed** (no signtool, no cert secret, no `certificateThumbprint` — tauri.conf.json has no `bundle.windows` section). **Linux is NOT GPG/minisign-signed**, and no deb/rpm repo (aptly/createrepo) exists.
- **VERSION never enters the workflows**: build-desktop.yml has zero references to the root `VERSION` file; versions are baked at build time from tauri.conf.json (synced by `mix bump.version`, `apps/evo_git/lib/mix/tasks/bump.version.ex`) and the mix releases. The release tag enters only via the prepare job's `release_tag`/`release_version` outputs (derived from the pushed tag name — the `release` event is not listened to, so no release-event context is available). An updater manifest would need a new step reading the prepare job's `release_version` output (already exposed for that purpose).

**Known issues**:
- **tauri-cli has no prebuilt aarch64-linux-gnu binary**: `tauri-cli` GitHub Releases ship prebuilt binaries for x86_64-linux, macOS, and Windows only — not linux-arm64. `cargo-binstall` therefore falls back to `cargo install` (full source compile) on the `ubuntu-24.04-arm` job, which is slow and flaky. The action instead installs the npm package `@tauri-apps/cli`, which ships prebuilt binaries for all platforms including `linux-arm64-gnu`. Never fall back to `cargo install` for the CLI: transitive dep `zune-jpeg 0.5.15` (`image 0.25.10` → `tauri-bundler 2.9.4`) has a known compile bug ("macro expansion ends with an incomplete expression" at `src/mcu_prog.rs:463`; upstream `zune-image` issue #424) that makes source compiles flaky and slow, and deps can't be pinned via `cargo install`. Because the npm wrapper passes args through verbatim while `cargo` prepends `tauri` as argv[1], builds must invoke `tauri build` — `cargo tauri build` does NOT work with the npm-installed CLI (`error: unrecognized subcommand 'tauri'`).
- **`mix release` hangs on cached `_build`**: the Mix build cache (`_build/`) is keyed by OTP/Elixir/mix.lock, not the project version. A restored cache contains an already-built release for the current version, and `mix release` blocks on the interactive `Release X already exists. Overwrite? [Yn]` prompt — which hangs forever in non-TTY CI. All release jobs therefore pass `--overwrite` to `mix release` (both `genesis_desktop` and `genesis_remote`). Never remove `--overwrite`, and keep it in sync across all jobs.
- **Remote daemon package is `.tar.xz`**: the headless `genesis_remote` tarball is compressed with xz (`tar -cJf`) for a smaller remote-bootstrap download, while the desktop portable archive stays `.tar.gz` (the `.tar.gz` entries in the platform matrix above refer to that desktop archive). All runner OSes support xz natively (ubuntu-22.04/24.04 and their arm variants ship xz-utils, macOS bsdtar has bundled liblzma, Windows bsdtar.exe supports `-J`) — future platform additions should keep xz rather than falling back to gzip.
- **Musl build (disabled, how to revive)**: musl `genesis_remote` tarballs are currently NOT published — the Linux remote tarballs are glibc, built by `build-linux-remote` on ubuntu-22.04. The old musl job ran in an Alpine Docker container (image `hexpm/elixir:1.20.3-erlang-29.0.5-alpine-3.22.5`, hardcoded directly in the `container.image` field — GitHub Actions does not allow the `env` context in `container.image`, so it cannot be a workflow-level env var). It `apk add`-ed nodejs FIRST (before checkout) because the runner's bundled Node.js is glibc-linked and won't run in the musl container — all JavaScript Actions (checkout, cache, upload-artifact) need it — and downloaded the `x86_64-unknown-linux-musl` ripgrep 15.1.0 prebuilt. It also bundled `libgcc_s.so.1` into the release's `lib/runtime/` directory (the precompiled Rust NIF `.so` files, e.g. xqlite's SQLite NIF, dynamically link it for stack unwinding; minimal Alpine/musl systems may not have the libgcc package) with `rel/env.sh.eex` setting `LD_LIBRARY_PATH` to include it. Musl builds were x64-only: GitHub Actions JavaScript actions are not supported inside Alpine containers on ARM64 runners ("JavaScript Actions in Alpine containers are only supported on x64 Linux runners. Detected Linux Arm64"). Reviving arm64 musl would require restructuring the job so checkout/cache/upload-artifact run on the host runner with only the build steps wrapped in explicit `docker run` invocations of the Alpine image (a job-level `container:` cannot work on arm64).
## Constraints

- Triggered by tag pushes (`v*`) and manual dispatch only — no branch-push triggers (those are CI).
- **Gotcha — workflow runs from the pushed tag's commit**: GitHub executes the workflow file from the commit the tag points at, so a tag must point at a commit that already contains the current workflow (push the tag only after the workflow change is committed); otherwise the old release-triggered workflow runs — or none at all.
- Each platform builds natively — no cross-compilation.
- The `genesis_remote` tarball is uploaded alongside desktop installers as a release asset.
- The workflow file is the single source of truth for the release build process.
- Release assets are **unversioned** with permanent `releases/latest/download/<name>` links (e.g. `genesis_desktop_darwin_arm64.dmg`); the version comes from the release tag and is baked into the app at build time, never into the filename.
- **`genesis_remote` Linux naming convention**: glibc is the default with NO suffix — `genesis_remote_linux_x64.tar.xz` and `genesis_remote_linux_arm64.tar.xz` (both glibc, built by `build-linux-remote` on ubuntu-22.04). No musl tarballs are published at this stage. Non-linux remote tarballs (darwin, windows) are unchanged (`genesis_remote_darwin_arm64.tar.xz`, `genesis_remote_windows_x64.tar.xz`). `EvoGit.RemoteBootstrap` (apps/evo_git/lib/evo_git/remote_bootstrap.ex) depends on the unsuffixed `genesis_remote_<platform>.tar.xz` naming for its default download and is being updated in parallel.
