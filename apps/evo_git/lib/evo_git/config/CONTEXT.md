# Config — Unified Configuration Resolver

## Intent
Contains `EvoGit.Config`, the unified configuration resolver that merges application defaults, user config (`~/.config/evogit/config.toml`), and provides API key lookup from a `.env` file and environment variables. This module serves as the single source of truth for all non-project configuration. It also provides write capability for persisting user config changes and a diagnostic function for checking configuration completeness.

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Returns fully merged config map (defaults + user config). Runtime overrides are NOT included — those live in `AgentScheduler` state. |
| `resolve/1` | Returns resolved value for a specific key path (atom or list of atoms) |
| `user_config/0` | Reads and returns parsed `config.toml`, or `%{}` if not found |
| `save_user_config/1` | Persists a config map to `config.toml`. Creates the config directory if needed. Encodes the map as TOML via `TomlElixir.encode/1` (atom keys are stringified). Returns `:ok` or `{:error, reason}`. |
| `config_status/0` | Returns diagnostic map with `:missing` (list of missing critical config key atoms), `:warnings` (human-readable warning messages), and `:ok?` (boolean). Checks for: LLM model, at least one API key, and GitHub username. |
| `load_env/0` | Loads environment variables from `~/.config/evogit/.env` (plain `KEY=VALUE` format) into the system environment. Returns `:ok` if loaded or file doesn't exist, `:error` on read failure. |
| `api_key/1` | Gets a specific API key by checking the system environment for the standard provider variable (e.g., `GOOGLE_API_KEY`). Keys are set via the `.env` file or directly in the environment. |
| `defaults/0` | Returns the built-in application defaults map |
| `config_dir/0` | Returns the platform config directory path (XDG-compliant) |
| `config_path/0` | Returns the full path to `config.toml` |
| `env_path/0` | Returns the full path to `.env` |

### Configuration Levels (priority: low → high)
1. **Application defaults** — Hardcoded in `defaults/0` (no model, no username)
2. **User config** — `~/.config/evogit/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`
3. **Runtime overrides** — Session-level, stored in `AgentScheduler` GenServer state via `update_config/1`

### `save_user_config/1`
Persists user configuration to disk. Used by the EvoDash `HelpLive` page's TOML editor:
- Accepts a map (atom or string keys)
- Creates config directory via `File.mkdir_p/1` if needed
- Stringifies atom keys for TOML compatibility
- Encodes with `TomlElixir.encode/1` and writes to `config_path()`
- Returns `:ok` on success, `{:error, reason}` on failure

### `config_status/0`
Returns a diagnostic map for UI display of configuration completeness:
```elixir
%{
  missing: [:llm_model, :api_key],   # atoms for missing critical keys
  warnings: ["LLM model is not configured...", ...],  # human-readable messages
  ok?: false  # true when all critical config is present
}
```
Checks three critical items:
1. **LLM model** (`[llm] model`) — must be non-nil, non-empty
2. **API key** — at least one provider key from the `.env` file or env vars (google, zai, deepseek, groq, anthropic, openai)
3. **GitHub username** (`[user] github_username`) — must be non-nil, non-empty

### Built-in Defaults (`defaults/0`)
```elixir
%{
  scheduler: %{
    max_concurrency: 3,
    max_tool_concurrency: 2,
    agent_max_retries: 3,
    max_agent_depth: 8,
    max_retries: 15
  },
  llm: %{},           # No default model — user MUST configure
  user: %{},          # No default username — user MUST configure
  sandbox: %{mode: :auto}
}
```

### API Key Resolution
API keys are read from the system environment using standard provider-specific variable names (e.g., `GOOGLE_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ZAI_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `TAVILY_API_KEY`). Environment variables can be set via the `.env` file (loaded by `load_env/0` at startup) or directly in the environment.

### Config File Locations (via `EvoGit.Platform`)
- **Linux**: `$XDG_CONFIG_HOME/evogit` (defaults to `~/.config/evogit`)
- **macOS**: `~/Library/Application Support/evogit`
- **Windows**: `%APPDATA%/evogit`

### Supported Providers for API Keys
`google`, `zai`, `deepseek`, `groq`, `tavily`, `anthropic`, `openai`

## Constraints
- **Write capability is limited**: Only `save_user_config/1` writes to disk, and only to `config.toml`. The `.env` file is never written programmatically.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- Config directory follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads are wrapped in try/rescue-safe patterns with Logger warnings on failure.
- `EvoGit.Defaults` is a backward-compatibility shim that delegates all calls to this module.
