# Sandbox — Multi-Platform Sandbox Backend

## Intent
Provides platform-specific sandboxing for agent-executed commands. Dispatches to the appropriate backend based on `EvoGit.Platform.sandbox_backend/0`.

## API Surface
| Module | Description |
|---|---|
| `EvoGit.Sandbox` | Dispatch module — routes to the active backend |
| `EvoGit.Sandbox.Linux` | Linux/systemd-run backend (full sandboxing) |
| `EvoGit.Sandbox.MacOS` | macOS/sandbox-exec backend (filesystem isolation) |
| `EvoGit.Sandbox.None` | Passthrough backend (no sandboxing) |
| `EvoGit.Nix` | Shared helper for running commands inside a cached Nix dev environment — builds the dev env ONCE via `nix print-dev-env`, caches the bash script to `<data_dir>/nix-dev-env.sh`, and sources it per call via `bash -c "source <path>; exec <cmd>"`. Gate: `active?/0` (enabled + dev-env build not failed); `enabled?/0` is the static capability check |

## Constraints
- All backends implement the same behaviour: `enabled?/0`, `ensure_initialized/0`, `run/4`
- `EvoGit.Sandbox.Linux` depends on `EvoGit.SandboxSlice` for systemd slice management
- `EvoGit.Sandbox.MacOS` uses inline SBPL profile generation (no external template files)
- `EvoGit.Sandbox.None` is the fallback for Windows and unsupported platforms
- Callers use `EvoGit.sandbox_run/4` (delegates to `EvoGit.Sandbox.run/4`) — tool modules do not need to know about backends
- `EvoGit.Nix` is a standalone helper module (not a sandbox backend) — backends consult it to optionally wrap commands when Nix is enabled. It depends on `EvoGit.Config` (for the `[nix]` table and config dir) and `EvoGit.Platform` (`nix_available?/0`)
- When nix is active, Linux backend forwards all `NIX*` + `SSL_CERT_FILE` env vars via `--setenv` and grants read-write access to `/nix/store` and `/nix/var`. macOS backend adds `/nix/store` and `/nix/var` to its SBPL profile. None backend wraps directly (inherits parent env). All three backends source the cached dev-env script (`nix print-dev-env` output) via `bash -c` rather than per-call `nix develop`. The `nix_paths`/`nix_env_vars` gating uses `Nix.enabled?/0` (static capability); the wrap decision uses `Nix.active?/0` (enabled + build not failed).
