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
| `EvoGit.Nix` | Shared helper for running commands inside a Nix develop environment — wraps commands in `nix develop <flake-uri> --command <executable> <args>` when enabled via config (`[nix] enabled = true`), the `nix` binary is available, and a `flake.nix` exists in the config directory |

## Constraints
- All backends implement the same behaviour: `enabled?/0`, `ensure_initialized/0`, `run/4`
- `EvoGit.Sandbox.Linux` depends on `EvoGit.SandboxSlice` for systemd slice management
- `EvoGit.Sandbox.MacOS` uses inline SBPL profile generation (no external template files)
- `EvoGit.Sandbox.None` is the fallback for Windows and unsupported platforms
- Callers use `EvoGit.sandbox_run/4` (delegates to `EvoGit.Sandbox.run/4`) — tool modules do not need to know about backends
- `EvoGit.Nix` is a standalone helper module (not a sandbox backend) — backends consult it to optionally wrap commands when Nix is enabled. It depends on `EvoGit.Config` (for the `[nix]` table and config dir) and `EvoGit.Platform` (`nix_available?/0`)
