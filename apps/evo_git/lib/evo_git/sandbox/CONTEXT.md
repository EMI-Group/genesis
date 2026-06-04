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

## Constraints
- All backends implement the same behaviour: `enabled?/0`, `ensure_initialized/0`, `run/4`
- `EvoGit.Sandbox.Linux` depends on `EvoGit.SandboxSlice` for systemd slice management
- `EvoGit.Sandbox.MacOS` uses inline SBPL profile generation (no external template files)
- `EvoGit.Sandbox.None` is the fallback for Windows and unsupported platforms
- Callers use `EvoGit.sandbox_run/4` (delegates to `EvoGit.Sandbox.run/4`) — tool modules do not need to know about backends
