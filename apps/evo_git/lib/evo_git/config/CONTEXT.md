# Config — Unified Configuration Resolver

## Intent
Contains `EvoGit.Config`, the unified configuration resolver that merges application defaults, user config (`~/.config/evogit/config.toml`), and provides API key lookup from credentials files and environment variables. This module serves as the single source of truth for all non-project configuration.

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Returns fully merged config map (defaults + user config) |
| `resolve/1` | Returns resolved value for a specific key path (atom or list of atoms) |
| `user_config/0` | Reads and returns parsed `config.toml`, or `%{}` if not found |
| `credentials/0` | Reads and returns parsed `credentials.toml`, or `%{}` if not found |
| `api_key/1` | Gets a specific API key (checks credentials file, then env vars) |
| `defaults/0` | Returns the built-in application defaults map |
| `config_dir/0` | Returns the platform config directory path (XDG-compliant) |
| `config_path/0` | Returns the full path to `config.toml` |
| `credentials_path/0` | Returns the full path to `credentials.toml` |
| `validate/0` | Validates resolved config, returns list of issues with severity (`:error`/`:warning`) |
| `read_user_config_toml/0` | Reads raw TOML content of config file (`{:ok, String.t}` or `{:error, reason}`) |
| `write_user_config_toml/1` | Writes TOML string to config file after validation; creates directory if needed |
| `config_status/0` | Returns config status map (paths, existence, validation issues) for dashboard display |

### Configuration Levels (priority: low → high)
1. **Application defaults** — Hardcoded in `defaults/0` (no model, no username)
2. **User config** — `~/.config/evogit/config.toml` (XDG-compliant)
3. **Runtime overrides** — Managed by `AgentScheduler` (not in this module)

### API Key Resolution Order
1. Credentials file (`credentials.toml` `[api_keys]` section)
2. `EVOGIT_API_KEY_<PROVIDER>` environment variable
3. Provider-specific env var (e.g., `GOOGLE_API_KEY`, `OPENAI_API_KEY`)

### Validation Checks (`validate/0`)
| Check | Severity | Condition |
|-------|----------|-----------|
| LLM model | `:error` | Model is nil or empty string |
| GitHub username | `:warning` | Not configured |
| Scheduler fields | `:error` | Non-integer, below min, or above max |
| API keys | `:warning` | No keys configured in credentials |

## Constraints
- Uses `TomlElixir.parse!/1` for parsing; `write_user_config_toml/1` validates with same parser before writing
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately
- Config directory follows XDG conventions via `EvoGit.Platform.os()`
- All file reads are wrapped in try/rescue-safe patterns with Logger warnings on failure
