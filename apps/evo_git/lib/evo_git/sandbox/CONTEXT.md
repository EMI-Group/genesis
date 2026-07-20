# Sandbox — Multi-Platform Sandbox Backend

## Intent
Provides platform-specific sandboxing for agent-executed commands. Dispatches to the appropriate backend based on `EvoGit.Platform.sandbox_backend/0`.

## Routing Table

None — leaf directory (modules: `sandbox.ex`, `behaviour.ex`, `helpers.ex`, `linux.ex`, `macos.ex`, `none.ex`).

## API Surface
| Module | Description |
|---|---|
| `EvoGit.Sandbox` | Dispatch module — routes to the active backend |
| `EvoGit.Sandbox.Behaviour` | Formal `@behaviour` contract that all backends implement (`enabled?/0`, `ensure_initialized/0`, `run/4`, `run_with_partial/6`) |
| `EvoGit.Sandbox.Helpers` | Shared utility functions extracted from the backends and lifecycle modules: `shell_escape/1` (POSIX-safe, security-sensitive), `read_tempfile/2` (temp-file read + delete with optional truncation), `system_cmd/2` (normalized `System.cmd` wrapper) |
| `EvoGit.Sandbox.Linux` | Linux/systemd-run backend (`@behaviour EvoGit.Sandbox.Behaviour`) — full sandboxing |
| `EvoGit.Sandbox.MacOS` | macOS/sandbox-exec backend (`@behaviour EvoGit.Sandbox.Behaviour`) — filesystem isolation |
| `EvoGit.Sandbox.None` | Passthrough backend (`@behaviour EvoGit.Sandbox.Behaviour`) — no sandboxing |
| `EvoGit.Nix` | Shared helper for running commands inside a cached Nix dev environment — builds the dev env ONCE via `nix print-dev-env`, caches the bash script to `<data_dir>/nix-dev-env.sh`, and sources it per call via `bash -c "source <path>; exec <cmd>"`. Gate: `active?/0` (enabled + dev-env build not failed); `enabled?/0` is the static capability check |

## Constraints
- All backends implement `@behaviour EvoGit.Sandbox.Behaviour` — the dispatch module (`EvoGit.Sandbox`) calls the behaviour callbacks uniformly
- Shared helpers live in `EvoGit.Sandbox.Helpers` — `shell_escape/1`, `read_tempfile/2` (with `read_truncated/3`), and `system_cmd/2`. Backends and `EvoGit.Nix` alias `Helpers` and delegate to these functions instead of duplicating them
- `shell_escape/1` is **security-sensitive** (command injection prevention) — it has exactly one definition in `EvoGit.Sandbox.Helpers`
- `EvoGit.Sandbox.Linux` depends on `EvoGit.SandboxProcessRegistry` (caller-process monitoring) and `EvoGit.SandboxSlice` (systemd slice management) — both started in Application supervision tree on Linux only
- `EvoGit.Sandbox.MacOS` uses inline SBPL profile generation (no external template files)
- `EvoGit.Sandbox.None` is the fallback for Windows and unsupported platforms
- Callers use `EvoGit.sandbox_run/4` (delegates to `EvoGit.Sandbox.run/4`) — tool modules do not need to know about backends
- `EvoGit.Nix` is a standalone helper module (not a sandbox backend) — backends consult it to optionally wrap commands when Nix is enabled. It depends on `EvoGit.Config` (for the `[nix]` table and config dir) and `EvoGit.Platform` (`nix_available?/0`)
- When nix is active, Linux backend forwards all `NIX*` + `SSL_CERT_FILE` env vars via `--setenv` and grants read-write access to `/nix/store` and `/nix/var`. macOS backend adds `/nix/store` and `/nix/var` to its SBPL profile. None backend wraps directly (inherits parent env). All three backends source the cached dev-env script (`nix print-dev-env` output) via `bash -c` rather than per-call `nix develop`. The `nix_paths`/`nix_env_vars` gating uses `Nix.enabled?/0` (static capability); the wrap decision uses `Nix.active?/0` (enabled + build not failed).

## Behaviour Contract
All three backends (`Linux`, `MacOS`, `None`) formally implement `@behaviour EvoGit.Sandbox.Behaviour`. The behaviour declares four callbacks:
- `enabled?/0` — whether sandboxing is available for this platform/mode
- `ensure_initialized/0` — lazily initialize backend resources (e.g. systemd slice); no-op when unneeded
- `run/4` — synchronous command execution returning `{output, exit_code}`
- `run_with_partial/6` — command execution with timeout + partial-output recovery returning `{:ok, output, exit_code}` or `{:timeout, partial_output}`
