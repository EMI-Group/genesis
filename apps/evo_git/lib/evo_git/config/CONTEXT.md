# Config — Unified Configuration Resolver

## Intent
Contains `EvoGit.Config`, the single source of truth for non-project configuration. Merges application defaults with user config (`~/.config/evogit/config.toml`), loads API keys from credentials into env vars, and provides write capability for persisting user config changes plus a diagnostic function for configuration completeness.

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Returns merged config map (defaults + user config). Runtime overrides live in `AgentScheduler` state, not here. |
| `resolve/1` | Returns resolved value for a specific key path (atom or list of atoms) |
| `user_config/0` | Reads and returns parsed `config.toml`, or `%{}` if not found |
| `save_user_config/1` | Persists a config map to `config.toml`. Creates config directory if needed. Returns `:ok` or `{:error, reason}`. |
| `config_status/0` | Returns diagnostic map with `:missing`, `:warnings`, and `:ok?`. Checks LLM model, API key presence, and GitHub username. |
| `credentials/0` | Reads `credentials.toml`, sets each key-value pair as an env var, returns parsed map |
| `defaults/0` | Returns built-in application defaults (scheduler concurrency/retry settings, empty llm/user maps, sandbox mode) |
| `config_path/0` | Returns the full path to `config.toml` |

### Configuration Levels (priority: low → high)
1. **Application defaults** — Hardcoded in `defaults/0` (no model, no username)
2. **User config** — `~/.config/evogit/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`
3. **Runtime overrides** — Session-level, stored in `AgentScheduler` GenServer state

## Constraints
- Only `save_user_config/1` writes to disk, and only to `config.toml`. Credentials are never written programmatically.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- Config directory follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads are wrapped in try/rescue-safe patterns with Logger warnings on failure.
- `EvoGit.Defaults` is a backward-compatibility shim that delegates all calls to this module.
- Details (credentials format, defaults structure, API key env vars) live in module documentation.
