# EvoGit — Root

## Intent

EvoGit is an evolutionary software development framework built in Elixir. It models a codebase as a hierarchical **Context Tree** (Spatial Dimension) and evolves it through a DAG of Git commits (Temporal Dimension). AI agents recursively build and optimize software, guided by spatial contracts in per-directory CONTEXT.md files.

This is an **Elixir umbrella project** with two child applications:

| App | Directory | Purpose |
|-----|-----------|---------|
| `:evo_git` | `./apps/evo_git/` | Core runtime — agent execution, Git interactions, CLI |
| `:evo_dash` | `./apps/evo_dash/` | Phoenix LiveView dashboard — real-time visualization and task management |

The full design specification is in `AGENTS.md`.

## Routing Table

- `./apps/evo_git/` → Core runtime (agents, scheduler, git adapter, runtime phases)
- `./apps/evo_dash/` → Web dashboard (LiveView pages, components, task registry)
- `./config/` → Environment-based Elixir configuration
- `./rel/` → Mix release overlays (`rel/genesis/`, `rel/remote/` — vm.args + env scripts per release; distribution config for SSH remote dev)
- `./desktop/` → Tauri desktop shell (native WebView wrapper, sidecar lifecycle management)
- `./nix/` → NixOS build support (vendor bundling helper for local desktop builds)
- `./.github/workflows/` → CI/CD pipelines (desktop app build on release)

## API Surface

### Top-Level Files

| File | Purpose |
|------|---------|
| `mix.exs` | Umbrella Mix project — apps_path, three releases: `genesis` (both apps), `genesis_desktop` (standard mix release with `include_erts`, bundled as Tauri resource), `genesis_remote` (headless evo_git-only daemon tarball for SSH remote dev). Version is read dynamically from `VERSION` (single source of truth). |
| `VERSION` | Single source of truth for the project version (e.g. `0.1.0`). All umbrella `mix.exs` files read this; the desktop manifests are synced by `mix bump.version`. |
| `flake.nix` | Nix flake — `devShells.default` provides a complete NixOS toolchain (Erlang/OTP 29, Elixir 1.20, Rust, Tauri v2 native deps) for local desktop app builds |
| `AGENTS.md` | Full EvoGit design specification (dual-dimension architecture, agent model, runtime phases) |
| `README.md` | User-facing documentation: installation, CLI usage, architecture overview |
| `.formatter.exs` | Code format configuration |
| `.tool-versions` | Pinned Erlang/OTP 29 and Elixir 1.20.1 (for asdf/mise/CI) |
| `LICENSE` | Project license |

### CLI Interface

```bash
# Setup — guided LLM configuration wizard
mix run -e 'EvoGit.CLI.main(System.argv())' -- setup

# Genesis — create a codebase from a prompt
mix run -e 'EvoGit.CLI.main(System.argv())' -- genesis "<prompt>" [-f file] [-c concurrency] [-p path] [-R <id:>path]

# Evolution — modify an existing codebase
mix run -e 'EvoGit.CLI.main(System.argv())' -- evolve "<objective>" [-p path] [-R <id:>path]
```

Flags: `-c` / `--concurrency` for LLM slots, `--tool-concurrency` for tool slots, `-R <id:>path` for foreign repos (repeatable), `-C` / `--concepts` for concept expansion seeding (repeatable, complex mode only).

## Architecture Summary

EvoGit has two OTP applications under an umbrella:

- **`:evo_git`** (Core Runtime): AgentScheduler GenServer managing worktree pools, LLM/tool slot management with global backoff, agent implementations (Manager, Executor, Investigator, etc.), Git adapter, and two-phase execution (Genesis → Evolution). Uses a 3-level configuration system: built-in defaults → user TOML config → session-level runtime overrides.
- **`:evo_dash`** (Web Dashboard): Phoenix LiveView interface with project-based task management, agent tree inspector, runtime settings panel, and in-browser config editor. Uses Bandit adapter, Tailwind CSS 4 + DaisyUI, SQLite-based persistence (xqlite).

Key design: spatial context tree for routing, phylogenetic graph for temporal evolution, transient agents in isolated worktrees, multi-repo support via absolute path resolution, slot-based concurrency with LLM rate-limit backoff, multi-platform sandboxing (systemd-run on Linux, sandbox-exec on macOS), and a dynamic skills system.

## Constraints

- Umbrella structure: all deps, build artifacts, lockfile at root (`./deps/`, `./_build/`, `mix.lock`)
- Elixir ~> 1.18 required
- Git CLI only — no libgit2 bindings
- No source code at root — all code under `./apps/`
- Agents commit before delegating subagents (auto-commit fallback enforced)
- Genesis stores its runtime artifacts (agent worktrees, state) under a `.genesis/` directory at each repo root — not `.evogit/` (the project was renamed from EvoGit to Genesis). This directory must be git-ignored everywhere (root `.gitignore` and the `.gitignore` that Genesis auto-writes into new repos).
- LLM-generated code runs under platform-appropriate sandboxing (systemd-run on Linux, sandbox-exec on macOS, direct on Windows)
- No hardcoded model or username — users configure via `~/.config/genesis/config.toml`
- User config follows XDG conventions

## Development Notes

- `mix precommit` — format code and run tests before committing
- `mix test` — execute the test suite
- `mix deps.get` — fetch dependencies
- `mix compile` — compile and check for errors
- `mix bump.version <new-version>` — bump the project version from the single source of truth (`VERSION`) and sync it to the Tauri/Cargo desktop manifests in one step

### Versioning

The project version has a **single source of truth**: the root `VERSION` file. The three umbrella `mix.exs` files (`./mix.exs`, `apps/evo_git/mix.exs`, `apps/evo_dash/mix.exs`) all read the version dynamically from `VERSION` via a shared `version/0` helper. The desktop manifests (`desktop/src-tauri/tauri.conf.json` and `Cargo.toml`) carry a literal copy that must stay in sync.

To bump the version, run:

```bash
mix bump.version 0.2.0
```

This updates `VERSION`, `tauri.conf.json`, `Cargo.toml`, and `Cargo.lock` in one command, then prints next-step guidance (compile, commit, tag). The CLI also supports `--version` / `-v` to print the version at runtime.

### SSH Remote Development

Genesis supports a VSCode Remote-SSH-like workflow: a lightweight headless daemon runs on a remote server, and the local Phoenix dashboard controls it over an SSH tunnel via Erlang distribution.

**Architecture:**
- **Remote daemon** (`genesis_remote` release): a standard `mix release` `evo_git`-only build (no Phoenix/Tauri), bundled with `include_erts`. Distributed as a tarball that is SCP'd to the remote host and extracted. Launched via `systemd-run --user` (Linux) or `launchctl` with a launchd plist (macOS) as an independent daemon — survives dashboard disconnection. Enables EPMD-less distribution on a pinned port (default 9000) via `rel/remote/vm.args.eex`.
- **Local dashboard**: connects to the remote daemon by (1) establishing an SSH port-forwarding tunnel (`ssh -L <dist_port>:127.0.0.1:<dist_port> -N`), then (2) `Node.connect/1` over the tunnel. The `EvoGit.RemoteConnection` GenServer manages this lifecycle.
- **Data access**: the dashboard reads remote agent state/config via `:erpc.call/5` to `EvoGit.AgentScheduler.RemoteAPI` on the remote node (`:erpc` transfers native BEAM terms — atoms, structs, maps — directly, so the API returns native structs like `%ReqLLM.Message{}`, `%Usage{}`, `%AgentState{}` without any serialization). PubSub uses the existing PG2 adapter backed by `:pg`, which is cluster-aware — broadcasts on the remote node's `EvoGit.PubSub` propagate to the local dashboard.
- **Bootstrap vs Connect**: deliberately separate. **Bootstrap** (`EvoGit.RemoteConnection.bootstrap/1`) SCPs the local release tarball to the remote host via CLI `scp`, extracts it via `ssh tar -xzf`, sets the launcher executable via `ssh chmod +x`, detects the remote OS, and launches it as a daemon (`systemd-run --user` on Linux, `launchctl` + launchd plist on macOS) — first-time setup. **Connect** (`EvoGit.RemoteConnection.connect/1`) assumes the daemon is already running and only establishes the tunnel + distribution link. All SSH operations use CLI `ssh`/`scp` via `Port.open` — no Erlang `:ssh`/`:ssh_sftp` modules. SSH port, identity file, and other options are handled by the user's `~/.ssh/config`; the target stores only an `ssh_target` string (e.g. `gpu-server` or `user@host`).

**Key modules:**
| Module | App | Purpose |
|--------|-----|---------|
| `EvoGit.RemoteConnections` | evo_git | TOML-based SSH target persistence (`~/.config/genesis/remote_connections.toml`). Schema: `ssh_target` (SSH host string), `local_binary_path` (path to local binary), `dist_port`, `remote_path`, `name`, `id`, `last_connected`. No SSH config parsing — port/keys handled by `~/.ssh/config`. |
| `EvoGit.RemoteConnection` | evo_git | GenServer — bootstrap (CLI `scp` + `ssh`) + connection lifecycle (CLI `ssh -L` tunnel), heartbeat |
| `EvoGit.AgentScheduler.RemoteAPI` | evo_git | Read-only RPC API over scheduler ETS (list_agents, get_agent_history, get_config, etc.) |
| `EvoDash.NodeContext` | evo_dash | Thin client — wraps RemoteConnections + RemoteConnection + cross-node RPC helpers |
| `EvoDashWeb.LiveHooks.NodeAware` | evo_dash | On-mount hook — resolves `?node=` param to remote BEAM node name for RPC routing |
| `EvoDashWeb.NodeSelectorComponent` | evo_dash | Navbar node indicator/selector dropdown (links to Settings page for full connection management) |

**Dashboard UX:**
- Node indicator/selector next to the brand logo in the navbar — shows green dot "Local" or blue dot + target name when remote.
- All navigation links carry `?node=<target_id>` when viewing a remote node.
- Connection management on Settings page (`/settings?category=remote_connections`): add/edit/delete SSH targets (ssh_target, local_binary_path, dist_port, remote_path), bootstrap remote daemon, connect/disconnect.
- When viewing a remote node: Agents page shows remote agents via RPC, Settings is read-only, System controls are disabled (restart/stop), config banner shows remote config status.
- SSH targets are persisted and remembered across sessions.

**Design constraint — single active remote connection:** The current architecture uses a fixed distribution node name (`genesis_remote@127.0.0.1`) and a single SSH tunnel binding a fixed local port (default 9000). This means only one remote connection is active at a time — `Node.connect` to the same fixed name cannot address two hosts. This is the intended product behavior for the initial implementation.

### Desktop App Build Pipeline

The project includes a GitHub Actions workflow (`.github/workflows/build-desktop.yml`) that automatically builds native desktop app installers on every GitHub release. The build process uses a **Tauri + Burrito** architecture:

- **Trigger**: Release published (including pre-releases) or manual `workflow_dispatch`
- **Build process**: Burrito-wrapped Elixir release (`mix release genesis_desktop`) → placed as a Tauri sidecar binary (`desktop/src-tauri/sidecars/`) → `cargo tauri build` produces native installers. A second Burrito release (`mix release genesis_remote`) — a headless `evo_git`-only daemon for SSH remote development, no Phoenix/Tauri — is built alongside and uploaded as a standalone binary directly to the GitHub release (not packaged into Tauri).
- **Release configuration**: Three Burrito-wrapped releases are defined in `mix.exs`: `genesis_desktop` (full, for the Tauri sidecar), `genesis_remote` (headless `evo_git`-only, bakes `config: [evo_git: [remote_release: true]]` so the runtime detects remote-daemon mode and enables EPMD-less distribution via `rel/remote/vm.args.eex`), and the base `genesis`. The remote release excludes `evo_dash` entirely.
- **Job structure**: Two jobs — `build-unix` (matrix: macOS arm64/x64 + Linux x64/arm64) and `build-windows` (matrix: x86_64 + ARM64). macOS and Linux share a common Unix step sequence; Windows is separate (bash shell, MinGit).
- **macOS**: Builds ARM64 (`macos-14`) → `.dmg` / `.app` bundles
- **Linux**: Builds x86_64 (`ubuntu-24.04`) and ARM64 (`ubuntu-24.04-arm`) → `.deb` / `.rpm` / AppImage / `.tar.gz` portable archive (AppImage excluded on ARM64 — `appimagetool`/`linuxdeploy` are x86_64-only). Flatpak is not built — Tauri v2 has no native Flatpak bundle target (documented in the workflow).
- **Windows**: Builds x86_64 (`windows-2022`) and ARM64 (`windows-11-arm`) → `.msi` / `.exe` (NSIS) installers. Both use the x64 Burrito/ERTS release (no native ARM64 Erlang/OTP build exists; x64 ERTS runs via Windows' emulation layer on ARM), while the Tauri shell compiles natively (`aarch64-pc-windows-msvc`).
- **Caching**: Mix deps (`deps/`), Mix build (`_build/`), and Rust target (`Swatinem/rust-cache@v2`) are cached per platform/target to speed up CI. The Burrito release step uses `--overwrite` to ensure the `Burrito.wrap/1` step always re-runs even when `_build/` is cache-restored (otherwise the wrapped binary in `burrito_out/` is skipped and missing).
- **ARM runner ImageOS fix**: GitHub-hosted ARM partner runners (`ubuntu-24.04-arm`, `windows-11-arm`) report `ImageOS` values (`ubuntu24-arm64`, `win11-arm64`) that `erlef/setup-beam` does not recognize. The workflow sets `ImageOS` to the base value (`ubuntu24` / `win22`) via `$GITHUB_ENV` before the setup-beam step for ARM targets only.
- **Toolchains**: CI requires Elixir/OTP, Rust (Tauri), and Zig (Burrito wrapper compilation) on all platforms; Linux also needs system packages (webkit2gtk, libayatana-appindicator3-dev for system tray, libdbus-1-dev for tray-icon crate, etc.)
- **Vendor binaries**: ripgrep and git (or MinGit on Windows) are bundled into `apps/evo_git/priv/vendor/{platform}/` for each target
- **Linux NIF musl cross-compilation**: Burrito's Linux targets use a statically-linked musl Erlang/OTP runtime, but `mix release` runs on a glibc host (Ubuntu CI). By default `rustler_precompiled` downloads glibc-linked NIF binaries that fail to load inside the musl Burrito binary. The workflow force-recompiles the NIF deps (xqlite, html5ever, lumis, mdex_native) with `TARGET_ABI=musl` (and `TARGET_ARCH=aarch64` for ARM64) before each Linux release, then restores host-default NIFs before the Windows step. Burrito's built-in `RecompileNIFs` step only handles `:elixir_make` NIFs, not `rustler_precompiled` ones, so this manual step is required.
- **Burrito targets**: `darwin_arm64`, `darwin_amd64`, `windows_x64`, `linux_x64`, `linux_arm64` (defined in `mix.exs`). Both `genesis_desktop` and `genesis_remote` use the same 5 targets; the remote binary is named `genesis_remote_<target>` (e.g. `genesis_remote_linux_x64`) and uploaded straight to the release assets.
- **Version pinning**: `.tool-versions` pins OTP 29 / Elixir 1.20.1

The legacy launcher scripts and manual `.app`/zip packaging have been removed — Tauri generates native bundles and the Rust sidecar (`desktop/src-tauri/src/sidecar.rs`) handles backend lifecycle with the correct env vars.

### NixOS Local Build

For building and testing the desktop app on NixOS, a `flake.nix` is provided at the repository root:

```bash
# Enter the development shell with all native dependencies (Erlang/OTP 29,
# Elixir 1.20, Rust, Zig 0.15.2, webkitgtk-4.1, etc.)
nix develop

# Then follow the build steps printed by the shell hook:
#   1. mix deps.get && mix assets.setup && mix assets.deploy
#   2. cargo install tauri-cli --version "^2.0"   (first time only)
#   3. ./nix/bundle-vendor.sh                      (vendor binaries)
#   4. MIX_ENV=prod mix release genesis_desktop      (Burrito release)
#   5. cp burrito_out/genesis_desktop_* desktop/src-tauri/sidecars/genesis-backend-<rust-target>
#   6. cd desktop/src-tauri && cargo tauri build    (native desktop app)
```

**Key constraint:** Burrito 1.5.0 (pinned in `mix.lock`) hard-requires exactly Zig 0.15.2 — it calls `exit(1)` on any other version. Since nixpkgs does not yet ship Zig 0.15.x, the flake uses `mitchellh/zig-overlay` to provide the exact version. The flake locks this in `flake.lock`.
