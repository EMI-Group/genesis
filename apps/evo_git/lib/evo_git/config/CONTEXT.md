# Config — Unified Configuration Resolver

## Intent
Contains `EvoGit.Config`, the unified configuration resolver that merges application defaults, user config (`~/.config/evogit/config.toml`), and provides API key lookup from credentials files and environment variables. This module serves as the single source of truth for all non-project configuration. It is **read-only** — it never writes or persists config files.

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Returns fully merged config map (defaults + user config). Runtime overrides are NOT included — those live in `AgentScheduler` state. |
| `resolve/1` | Returns resolved value for a specific key path (atom or list of atoms) |
| `user_config/0` | Reads and returns parsed `config.toml`, or `%{}` if not found |
| `credentials/0` | Reads and returns parsed `credentials.toml`, or `%{}` if not found |
| `api_key/1` | Gets a specific API key (checks credentials file → `EVOGIT_API_KEY_<PROVIDER>` env var → provider-specific env var) |
| `defaults/0` | Returns the built-in application defaults map |
| `config_dir/0` | Returns the platform config directory path (XDG-compliant) |
| `config_path/0` | Returns the full path to `config.toml` |
| `credentials_path/0` | Returns the full path to `credentials.toml` |

### Configuration Levels (priority: low → high)
1. **Application defaults** — Hardcoded in `defaults/0` (no model, no username)
2. **User config** — `~/.config/evogit/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`
3. **Runtime overrides** — Session-level, stored in `AgentScheduler` GenServer state via `update_config/1`

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

### API Key Resolution Order
1. Credentials file (`credentials.toml` `[api_keys]` section)
2. `EVOGIT_API_KEY_<PROVIDER>` environment variable
3. Provider-specific env var (e.g., `GOOGLE_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ZAI_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`, `TAVILY_API_KEY`)

### Config File Locations (via `EvoGit.Platform`)
- **Linux**: `$XDG_CONFIG_HOME/evogit` (defaults to `~/.config/evogit`)
- **macOS**: `~/Library/Application Support/evogit`
- **Windows**: `%APPDATA%/evogit`

### Supported Providers for API Keys
`google`, `zai`, `deepseek`, `groq`, `tavily`, `anthropic`, `openai`

## Constraints
- **Read-only**: Uses `TomlElixir.decode/1` for parsing only — this module NEVER writes or persists config files. There is no `save_config` or `write_config` function anywhere in the codebase.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- Config directory follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads are wrapped in try/rescue-safe patterns with Logger warnings on failure.
- `EvoGit.Defaults` is a backward-compatibility shim that delegates all calls to this module.
