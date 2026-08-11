# EvoGit — Root

## Intent

EvoGit is an evolutionary software development framework built in Elixir. It models a codebase as a hierarchical **Context Tree** (Spatial Dimension) and evolves it through a DAG of Git commits (Temporal Dimension). AI agents recursively build and optimize software, guided by spatial contracts in per-directory CONTEXT.md files.

This is an **Elixir umbrella project** with two child applications:

| App | Directory | Purpose |
|-----|-----------|---------|
| `:evo_git` | `./apps/evo_git/` | Core runtime — agent execution, Git interactions, CLI |
| `:evo_dash` | `./apps/evo_dash/` | Phoenix LiveView dashboard — real-time visualization and task management |

The full design specification is documented across the CONTEXT.md tree.

## Routing Table

- `./apps/evo_git/` → Core runtime (agents, scheduler, git adapter, runtime phases)
- `./apps/evo_dash/` → Web dashboard (LiveView pages, components, task registry)
- `./config/` → Environment-based Elixir configuration
- `./rel/` → Mix release overlays (`rel/genesis/`, `rel/genesis_remote/` — vm.args + env scripts per release; distribution config for SSH remote dev)
- `./desktop/` → Tauri desktop shell (native WebView wrapper, sidecar lifecycle management)
- `./nix/` → NixOS build support (vendor bundling helper for local desktop builds)
- `./.github/workflows/` → CI/CD pipelines (desktop app build on release)

## API Surface

### Top-Level Files

| File | Purpose |
|------|---------|
| `mix.exs` | Umbrella Mix project — apps_path, three releases: `genesis` (both apps), `genesis_desktop` (standard mix release with `include_erts`, bundled as Tauri resource), `genesis_remote` (headless evo_git-only daemon tarball for SSH remote dev). Version is read dynamically from `VERSION` (single source of truth). |
| `VERSION` | Single source of truth for the project version (e.g. `0.1.0`). All umbrella `mix.exs` files read this; the desktop manifests are synced by `mix bump.version`. |
| `flake.nix` | Nix flake — `devShells.default` provides a complete NixOS toolchain (Erlang/OTP 29, Elixir 1.20, Rust, Tauri v2 native deps) for local desktop app builds. `packages.default` builds the app via `genesis.nix` (`nix build`). `apps.default` runs the app (`nix run`). |
| `genesis.nix` | Nix derivation — builds the Genesis Mix release using `beamPackages.mixRelease`, with pre-fetched Rustler NIFs and vendored system binaries (ripgrep, git). Called from `flake.nix`. |
| `genesis-desktop.nix` | Nix derivation — builds the Tauri desktop app: first builds the `genesis_desktop` Mix release, then builds the Tauri Rust binary with `rustPlatform.buildRustPackage`, and wraps them together. Called from `flake.nix` as `packages.desktop`. |
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

Flags: `-c` / `--concurrency` for LLM slots, `--tool-concurrency` for tool slots, `-R <id:>path` for foreign repos (repeatable).

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

## Architecture Summary

EvoGit has two OTP applications under an umbrella:

- **`:evo_git`** (Core Runtime): AgentScheduler GenServer managing worktree pools, LLM/tool slot management with global backoff, agent implementations (Manager, Executor, Investigator, etc.), Git adapter, and two-phase execution (Genesis → Evolution). Uses a 3-level configuration system: built-in defaults → user TOML config → session-level runtime overrides.
- **`:evo_dash`** (Web Dashboard): Phoenix LiveView interface with project-based task management, agent tree inspector, runtime settings panel, and in-browser config editor. Uses Bandit adapter, Tailwind CSS 4 + DaisyUI, SQLite-based persistence (xqlite).

Key design: spatial context tree for routing, phylogenetic graph for temporal evolution, transient agents in isolated worktrees, multi-repo support via absolute path resolution, slot-based concurrency with LLM rate-limit backoff, multi-platform sandboxing (systemd-run on Linux, sandbox-exec on macOS), and a dynamic skills system.

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

This updates `VERSION`, `tauri.conf.json`, `Cargo.toml`, `Cargo.lock`, and `README.md` (shields.io badge) in one command, then prints next-step guidance (compile, commit, tag). The CLI also supports `--version` / `-v` to print the version at runtime.

### Runtime Data Directory (`tasks.sqlite`)

The SQLite task database (`tasks.sqlite`) lives in the platform data directory, resolved at runtime by `EvoGit.Platform.data_dir/0` (`apps/evo_git/lib/evo_git/platform.ex:106-132`) — NOT via Tauri's `path_resolver`/`app_data_dir`. The Tauri sidecar passes no data-dir env vars (only `PORT`, `PHX_IP`, `PHX_SERVER`, `SECRET_KEY_BASE`, `RELEASE_DISTRIBUTION`, `EVOGIT_DESKTOP`; `desktop/src-tauri/src/sidecar.rs:44-55`) — the Elixir backend decides the path itself:

- **macOS**: `~/Library/Application Support/genesis/tasks.sqlite`
- **Linux**: `$XDG_DATA_HOME/genesis/tasks.sqlite` (default `~/.local/share/genesis/tasks.sqlite`)
- **Windows**: `%APPDATA%\genesis\tasks.sqlite` (default `~\genesis\tasks.sqlite` if APPDATA unset)

Path is computed in `EvoGit.Application.start/2` (`apps/evo_git/lib/evo_git/application.ex:36-38`): `Path.join(Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()), "tasks.sqlite")`, passed to `EvoGit.Store`, which `mkdir_p!`s the parent dir and opens with SQLite WAL mode (`store.ex:328-332`; WAL sidecars `tasks.sqlite-wal`/`-shm` sit beside it). `EvoGit.TaskRegistry.init/1` mirrors the same resolution (`task_registry.ex:151-161`). **Override**: set the application env `config :evo_git, :data_dir` (only `config/test.exs:29` does this today); there is NO dedicated env var and NO TOML config key (`EvoGit.Config` schema has no data-dir option). Indirect env influence only: `HOME` (macOS), `XDG_DATA_HOME` (Linux), `APPDATA` (Windows). The desktop log file uses the same dir (`<data_dir>/logs/backend.log`, `config/runtime.exs:121`), and the `genesis_remote` daemon uses the same resolution on its host (macOS remote: `~/Library/Application Support/genesis/tasks.sqlite`).

### Native Directory Picker (wx backend)

The dashboard's directory picker (Browse buttons on the project/new-project/foreign-repo pickers) is implemented **on the Elixir backend with Erlang's `:wx` module** (`wxDirDialog`), NOT via Tauri. Flow: the JS `DirectoryPicker` hook pushes `"directory_pick"` → `ProjectsLive` (the renamed dashboard LiveView, formerly `DashboardLive`) checks the current node is local → `EvoDash.DirectoryPicker` (a GenServer in `apps/evo_dash`, serializes wx dialog usage) runs the modal dialog → result pushed back to the client as `"picker_result:<picker_id>"`. wx picks are absolute paths and auto-submit the project/new-project forms; the old Tauri `pick_directory` Rust command + `tauri-plugin-dialog` were **removed** (unstable: Windows invoke failed after picking, macOS NSOpenPanel never presented). When wx is unavailable (headless server, remote node, OTP built without wx) the hook shows the manual-entry fallback. Because `wx` is not a dependency of any umbrella app, it must be listed explicitly in the `applications:` list of the `genesis` and `genesis_desktop` releases in `./mix.exs` (`wx: :load`) — `genesis_remote` intentionally stays wx-free. The `directory_picked` LiveView event (predecessor of the `picker_result` push) is dead code since this change. **CI note (v0.9.5+)**: the desktop release's wx NIFs link against wxWidgets 3.2 sonames, which broke the Linux x64 AppImage bundle (`failed to run linuxdeploy`) on the ubuntu-22.04 runner (jammy ships only wx 3.0). An initial fix installed wx 3.2 from the `wxformbuilder/wxwidgets3.2` PPA, but that PPA is dead (`add-apt-repository` fails with "ppa not found" / launchpad 404). As of 2026-08-10 the Linux runners are **ubuntu-24.04** (x64) / **ubuntu-24.04-arm**, where wxWidgets 3.2.4 ships in the default Ubuntu repos — the x64-gated CI step plain-apt-installs `libwxbase3.2-1t64 libwxgtk3.2-1t64 libwxgtk-gl3.2-1t64 libwxgtk-webview3.2-1t64 libglu1-mesa` (no PPA). See `desktop/src-tauri/CONTEXT.md` → Known Issues for the full diagnosis.

### ReqLLM Finch Connection Pool (LLM HTTP concurrency)

- **Boot-time sizing** (`config/runtime.exs:38-60`): `stream_pool_count = max(total_concurrency + 2, 8)` where `total_concurrency` = sum of per-profile `concurrency` from `EvoGit.Config.resolve()` (each defaults to 3); falls back to `scheduler.default_llm_max_concurrency` when no `[[llm.models]]` profiles exist. Also sets `stream_pool_size: 1`, `stream_pool_protocols: [:http1]`, `stream_pool_timeout: 120_000`. Evaluated before `:req_llm` starts, in ALL releases (genesis, genesis_desktop, genesis_remote — releases run runtime.exs at boot; the desktop/remote flags in runtime.exs never touch the pool; NO desktop-specific pool override exists anywhere in `desktop/`, `rel/`, `config/`, or app code).
- **Semantics**: ReqLLM starts ONE Finch named `ReqLLM.Finch` (`deps/req_llm/lib/req_llm/application.ex:43,83`) with a single `:default` pool config (`application.ex:101-109`) applied to every origin (provider host). Per origin: `count` pool processes (NimblePool) × `size` connections each (deps/finch/lib/finch/pool/supervisor.ex:4,22; http1/pool.ex:32-39) — so pool capacity = `count` concurrent HTTP/1 streams per provider host (size=1 ⇒ each stream holds its connection for the whole stream). `count`/`size`/`protocols` are read ONCE at app startup (`application.ex:111-127`); `stream_pool_timeout` is read at CALL time (`finch_client.ex:299-305`) and becomes Finch's `pool_timeout` (checkout/queue wait). On checkout timeout, HTTP/1 pool raises the RuntimeError "Finch was unable to provide a connection within the timeout due to excess queuing" (deps/finch/lib/finch/http1/pool.ex:81-90). ReqLLM classifies `:pool_not_available` as retryable (250ms backoff, retry.ex:199-201); EvoGit's `call_llm_with_retry` adds exponential backoff + logs "LLM request failed, retrying..." (`apps/evo_git/lib/evo_git/agent/tool_dispatch.ex:187-224`).
- **Runtime reconciliation — IMPLEMENTED (`EvoGit.ReqLLMPool`, `apps/evo_git/lib/evo_git/req_llm_pool.ex`)**: pool is sized once at boot, but runtime concurrency changes AFTER boot (dashboard model-profile save → `AgentScheduler.update_config(:model_profiles)`; `RemoteAPI.reload_config`; per-task `-m` model ids) now resize the Finch pool dynamically, **grow-only**. Two triggers: (1) **config change** — `AgentScheduler.handle_call({:update_config, opts}, ...)` (`agent_scheduler.ex:641-654`, helper `reconcile_pool_after_update/1`) reconciles to `desired_count(total)` = `max(sum(model_concurrency) + 2, 8)` after any successful config update; boot `init/1` also reconciles as a no-op safety (pools are lazy). (2) **excess-queuing error** — `ToolDispatch.call_llm_with_retry/5` (`tool_dispatch.ex:204-218`) detects Finch's "excess queuing" RuntimeError between retries via `EvoGit.ReqLLMPool.excess_queuing_error?/1` and calls `bump_for_excess_queuing/3` to grow pools to `max(ceil(total * 1.5), 8)`. Grow-only: `Finch.set_pool_count/3` (deps/finch/lib/finch.ex:1202; pool/supervisor.ex:29-55) grows by `start_child`-ing new pools (safe) but shrinks by `terminate_child` (kills in-flight streams) — the module NEVER shrinks (`max(current, desired)`). Pools are keyed per origin and materialized LAZILY on first request, so `set_pool_count` returns `{:error, :not_found}` until an origin is used; `reconcile`/`bump` no-op gracefully on `{:error, :not_found}` and never raise. CLI `-c`/`--concurrency` only sets `state.default_llm_max_concurrency` (the fallback, effectively inert — see `apps/evo_git/CONTEXT.md`). Non-slot-gated `stream_text` calls exist at `system_check.ex:344` and `runtime/pull_request.ex:153` only (the "+2 buffer" comment naming "context compression, evolution synthesis" is stale — context compression IS slot-gated; no synthesis module exists).
- **⚠️ CRITICAL REQUIREMENT (pending — parent-scope fix)**: enumeration uses `Finch.get_pool_status(ReqLLM.Finch, :default)`, which only reports pools whose config has `start_pool_metrics?: true` (deps/finch finch.ex:98-102; pool/manager.ex:216 — `track_default?`); the flag defaults to `false`. ReqLLM.Finch's pool config does NOT set it yet: `config/runtime.exs`'s `config :req_llm` block still uses the `stream_pool_*` keys, and ReqLLM's `get_default_pools/0` (deps/req_llm/lib/req_llm/application.ex:101-108) hardcodes `protocols/size/count` only. **Until `start_pool_metrics?: true` is added to the pool config, the reconciliation on `ReqLLM.Finch` is a silent no-op** (tests use their own Finch with the flag set, so they pass). The fix (root-scope, `config/runtime.exs` only): switch the `config :req_llm` block to the `finch: [name: ReqLLM.Finch, pools: %{default: [protocols: [:http1], size: 1, count: stream_pool_count, start_pool_metrics?: true]}]` form, keeping `stream_pool_timeout: 120_000` top-level (it is read at CALL time via `Application.fetch_env(:req_llm, :stream_pool_timeout)`, streaming/finch_client.ex:300 — not part of the pool config). Do NOT change the sizing formula `max(total_concurrency + 2, 8)`. Also update `config/CONTEXT.md`'s `stream_pool_*` bullet list (lines 36-39) once the keys are replaced.

### SSH Remote Development

Genesis supports a VSCode Remote-SSH-like workflow: a lightweight headless daemon runs on a remote server, and the local Phoenix dashboard controls it over an SSH tunnel via Erlang distribution.

**Architecture:**
- **Remote daemon** (`genesis_remote` release): a standard `mix release` `evo_git`-only build (no Phoenix/Tauri), bundled with `include_erts`. Distributed as a tarball that is SCP'd to the remote host and extracted. Launched via `systemd-run --user` (Linux) or `launchctl` with a launchd plist (macOS) as an independent daemon — survives dashboard disconnection. Uses a custom EPMD module (`EvoGit.EpmdDist`) for EPMD-less distribution on a pinned port (default 9000) via `rel/vm.args.eex` (`-epmd_module Elixir.EvoGit.EpmdDist`).
- **Local dashboard**: connects to the remote daemon by (1) establishing an SSH port-forwarding tunnel (`ssh -L <local_port>:127.0.0.1:<remote_port> -N`), then (2) auto-enabling local distribution on-demand via `EvoGit.Distribution.enable_for_remote/1`, then (3) `Node.connect/1` over the tunnel. The custom `EvoGit.EpmdDist` module resolves the remote node's port from a `:persistent_term` registry populated by `EpmdDist.register_target/2` at connect time — no external `epmd` process needed. The `EvoGit.RemoteConnection` GenServer manages this lifecycle.
- **Data access**: the dashboard reads remote agent state/config via `:erpc.call/5` to `EvoGit.AgentScheduler.RemoteAPI` on the remote node (`:erpc` transfers native BEAM terms — atoms, structs, maps — directly, so the API returns native structs like `%ReqLLM.Message{}`, `%Usage{}`, `%AgentState{}` without any serialization). PubSub uses the existing PG2 adapter backed by `:pg`, which is cluster-aware — broadcasts on the remote node's `EvoGit.PubSub` propagate to the local dashboard.
- **Bootstrap vs Connect**: deliberately separate. **Bootstrap** (`EvoGit.RemoteConnection.bootstrap/1`) SCPs the local release tarball to the remote host via CLI `scp`, extracts it via `ssh tar -xzf`, sets the launcher executable via `ssh chmod +x`, detects the remote OS, and launches it as a daemon (`systemd-run --user` on Linux, `launchctl` + launchd plist on macOS) — first-time setup. **Connect** (`EvoGit.RemoteConnection.connect/1`) assumes the daemon is already running and only establishes the tunnel + distribution link. All SSH operations use CLI `ssh`/`scp` via `Port.open` — no Erlang `:ssh`/`:ssh_sftp` modules. SSH port, identity file, and other options are handled by the user's `~/.ssh/config`; the target stores only an `ssh_target` string (e.g. `gpu-server` or `user@host`).

**Key modules:**
| Module | App | Purpose |
|--------|-----|---------|
| `EvoGit.EpmdDist` | evo_git | Custom EPMD-less distribution module (implements the `erl_epmd` interface). Uses `:persistent_term` as a node→port registry. VM calls `port_please/2` to resolve remote node ports; `register_target/2` populates the registry before `Node.connect/1`. |
| `EvoGit.Distribution` | evo_git | Runtime distribution enablement. `maybe_enable/0` for config-based `[node] enabled` path; `enable_for_remote/1` for on-demand startup when a user initiates an SSH connection. |
| `EvoGit.RemoteConnections` | evo_git | TOML-based SSH target persistence (`~/.config/genesis/remote_connections.toml`). Schema: `ssh_target` (SSH host string), `local_binary_path` (path to local release tarball), `dist_port`, `remote_path`, `name`, `id`, `last_connected`. No SSH config parsing — port/keys handled by `~/.ssh/config`. |
| `EvoGit.RemoteConnection` | evo_git | GenServer — bootstrap (CLI `scp` + `ssh`) + connection lifecycle (CLI `ssh -L` tunnel), heartbeat, auto-enables local distribution on connect |
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

**Design constraint — multiple remote connections:** Each SSH target gets a **unique per-target node name** (`genesis_remote_<id>@127.0.0.1`, derived from the target's slugified `id`) and a per-target systemd unit (`genesis-remote-<id>`) / launchd plist label (`com.genesis.remote.<id>`). This enables **multiple simultaneous remote connections** — each target connects to a distinct BEAM node name, so `Node.connect` can address multiple hosts. The SSH tunnel uses a dynamically-assigned local port (via `find_free_port/0`) that forwards to the remote daemon's fixed port 9000. The custom `EvoGit.EpmdDist` module maps each per-target node name to its tunnel's local port via `:persistent_term` so the VM's `port_please/2` callback resolves it correctly without an external EPMD process. The remote daemon's `RELEASE_NODE` is set per-target at launch time via `--setenv=RELEASE_NODE` (systemd-run) or an `EnvironmentVariables` dict (launchd plist), and `rel/genesis_remote/env.sh.eex` respects an existing `RELEASE_NODE` env var (`export RELEASE_NODE="${RELEASE_NODE:-...}"`).

### Desktop App Build Pipeline

The project includes a GitHub Actions workflow (`.github/workflows/build-desktop.yml`) that automatically builds native desktop app installers on every GitHub release. Each platform builds its own native Elixir release (with `include_erts`) and then packages it with Tauri — no cross-compilation or third-party wrapper is used.

- **Trigger**: Release published (including pre-releases) or manual `workflow_dispatch`
- **Build process**: Each platform job runs `mix release genesis_desktop` (native, `include_erts` bundles the host ERTS into the release directory) → copies the release directory to `desktop/src-tauri/resources/genesis-backend/` → `tauri build` produces native installers (the Tauri CLI is installed from the npm package `@tauri-apps/cli` — prebuilt binaries for all platforms including linux-arm64-gnu; see `.github/workflows/CONTEXT.md` for why npm rather than cargo-binstall). The headless `genesis_remote` release is also built and uploaded as a `.tar.gz` tarball alongside the desktop installers.
- **Release configuration**: Three standard mix releases are defined in `mix.exs`: `genesis_desktop` (full, bundled as Tauri resource), `genesis_remote` (headless `evo_git`-only, bakes `config: [evo_git: [remote_release: true]]` so the runtime detects remote-daemon mode and enables EPMD-less distribution via `rel/genesis_remote/vm.args.eex`), and the base `genesis`. The remote release excludes `evo_dash` entirely.
- **Job structure**: Four parallel jobs, each on a native runner for its target platform.
- **macOS**: Builds ARM64 (`macos-14`) → `.dmg` / `.app` bundles
- **Linux**: Builds x86_64 (`ubuntu-24.04`) and ARM64 (`ubuntu-24.04-arm`) → `.deb` / `.rpm` / AppImage / `.tar.gz` portable archive (AppImage excluded on ARM64 — `appimagetool`/`linuxdeploy` are x86_64-only). Was `ubuntu-22.04` for a lower glibc requirement (commit 788273c7); the "do not bump to 24.04" decision was revisited 2026-08-10 and the runners moved to 24.04 (the wxWidgets-3.2-PPA workaround for jammy's missing wx 3.2 broke — "ppa not found"); the glibc concern is deferred to a planned musl build. Flatpak is not built — Tauri v2 has no native Flatpak bundle target (documented in the workflow).
- **Windows**: Builds x86_64 (`windows-2022`) → `.msi` / `.exe` (NSIS) installers.
- **Caching**: Mix deps (`deps/`), Mix build (`_build/`), and Rust target (`Swatinem/rust-cache@v2`) are cached per platform/target to speed up CI. The Tauri CLI (npm `@tauri-apps/cli`, cached under `~/tauri-cli` on POSIX / `%APPDATA%\npm` on Windows) is also cached.
- **ARM runner ImageOS fix**: GitHub-hosted ARM partner runners (`ubuntu-24.04-arm`) report `ImageOS` values that `erlef/setup-beam` does not recognize. The workflow sets `ImageOS` to the base value (`ubuntu24`) via `$GITHUB_ENV` before the setup-beam step for the ARM64 target.
- **Toolchains**: CI requires Elixir/OTP and Rust (Tauri) on all platforms; Linux also needs system packages (webkit2gtk, libayatana-appindicator3-dev for system tray, libdbus-1-dev for tray-icon crate, etc.)
- **Vendor binaries**: ripgrep and git (or MinGit on Windows) are bundled into `apps/evo_git/priv/vendor/{platform}/` for each target
- **Version pinning**: `.tool-versions` pins OTP 29 / Elixir 1.20.1

The Tauri Rust shell (`desktop/src-tauri/src/sidecar.rs`) spawns the release launcher script (`bin/genesis_desktop start`) as a child process and handles backend lifecycle with the correct env vars.

### NixOS Local Build

For building and testing the desktop app on NixOS, a `flake.nix` is provided at the repository root:

```bash
# Enter the development shell with all native dependencies (Erlang/OTP 29,
# Elixir 1.20, Rust, webkitgtk-4.1, etc.)
nix develop

# Then follow the build steps printed by the shell hook:
#   1. mix deps.get && mix assets.setup && mix assets.deploy
#   2. cargo install tauri-cli --version "^2.0"   (first time only)
#   3. ./nix/bundle-vendor.sh                      (vendor binaries)
#   4. MIX_ENV=prod mix release genesis_desktop      (standard release)
#   5. cp -a _build/prod/rel/genesis_desktop desktop/src-tauri/resources/genesis-backend
#   6. cd desktop/src-tauri && cargo tauri build    (native desktop app)
```

`nix build .#desktop` produces a working store app: the Tauri binary resolves the backend release via `sidecar_path::resolve_launcher` (checks `<exe_dir>/resources/genesis-backend/bin/genesis_desktop` first — `genesis-desktop.nix` symlinks the release there), the wrapper puts the full GTK/WebKit/tray runtime stack on `LD_LIBRARY_PATH`, and `genesis.nix` bakes a deterministic `releases/COOKIE` (`removeCookie = false`, otherwise nixpkgs' mixRelease postFixup deletes it and the launcher dies with `cat: .../COOKIE: No such file or directory`). The GUI needs a writable `XDG_RUNTIME_DIR` for the tray icon. Details in `desktop/CONTEXT.md` → Known Issues.

**Known issue — tauri-build resource check:** tauri-build 2.x validates at compile time (relative to the crate dir) that every path in `tauri.conf.json`'s `bundle.resources` exists — `resources/genesis-backend` must be present when `build.rs` runs or the build fails with `resource path 'resources/genesis-backend' doesn't exist`. The flake source is the bare git tree (the placeholder dir was deleted from git in `c8b6195c`), so `genesis-desktop.nix` symlinks the Mix release into the unpacked crate source in a `preBuild` hook (`ln -s ${genesisRelease} resources/genesis-backend`). Keep this hook when restructuring the derivation; dev flows (`cargo tauri build` with a cargo-installed CLI) and CI (`tauri build` via the npm-installed CLI) must still copy the release into `desktop/src-tauri/resources/genesis-backend` before building, as documented in `desktop/CONTEXT.md`.

**Design decision — no cargoHash, version from VERSION (commit `f7fd953b2`):** The flake avoids all manual hash/version maintenance on code updates:
- `genesis-desktop.nix` uses `cargoLock.lockFile = ./desktop/src-tauri/Cargo.lock` (NOT `cargoHash`) — nixpkgs `buildRustPackage` derives the vendored-deps store path purely from the lock file (each crate fetched by the checksum already in Cargo.lock), so updating Cargo.lock never requires touching the derivation. There are no git deps, so no `cargoLock.outputHashes` is needed; if git deps are ever added, they MUST be declared there. Do NOT reintroduce the old `cargoHash`/`lib.fakeHash` workflow.
- Both `genesis.nix` and `genesis-desktop.nix` derive `version = lib.trim (lib.fileContents ./VERSION)` from the repo-root `VERSION` file instead of a hardcoded string — never bump the version in the Nix files by hand (a stale hardcode previously misaligned `postInstall`'s `evo_git-<version>` vendor path and the baked COOKIE with the actual mix release app dir).
- **Remaining manual hash:** `mixFodDeps.hash` in `genesis.nix` must still be updated when `mix.lock` changes (nixpkgs `fetchMixDeps` has no lock-derived equivalent) — this is the only flake hash that needs manual maintenance.
```
