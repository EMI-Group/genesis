# Config — Unified Configuration Resolver

## Intent
Contains `EvoGit.Config`, the single source of truth for non-project configuration. Merges application defaults with user config (`~/.config/genesis/config.toml`), loads API keys from credentials into ReqLLM's key store, and provides write capability for persisting user config changes plus a diagnostic function for configuration completeness.

## Routing Table

- `./schema/` → Config schema definitions — pure data describing config keys, types, defaults, and validation rules

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Returns merged config map (defaults + user config). Runtime overrides live in `AgentScheduler` state, not here. |
| `resolve/1` | Returns resolved value for a specific key path (atom or list of atoms) |
| `user_config/0` | Reads and returns parsed `config.toml`, or `%{}` if not found |
| `save_user_config/1` | Persists a config map to `config.toml`. Creates config directory if needed. Returns `:ok` or `{:error, reason}`. |
| `save_credentials/1` | Merges and persists API key map to `credentials.toml`. Sets keys via ReqLLM.put_key for immediate in-process use. Returns `:ok` or `{:error, reason}`. |
| `config_status/0` | Returns diagnostic map with `:missing`, `:warnings`, and `:ok?`. Checks LLM model presence and API key presence. GitHub username is **optional** — it is NOT checked here (a missing username does not affect `:ok?`, `:missing`, or `:warnings`). |
| `credentials/0` | Reads `credentials.toml`, loads each key-value pair into ReqLLM's key store via ReqLLM.put_key, returns parsed map |
| `defaults/0` | Returns built-in application defaults (scheduler concurrency/retry settings, empty llm/user maps, sandbox mode) |
| `config_path/0` | Returns the full path to `config.toml` |
| `config_dir/0` | Returns platform-specific config directory (XDG/macos/windows) |
| `credentials_path/0` | Returns full path to `credentials.toml` |

### `EvoGit.Config.LLMCatalog` (provider/model shortcuts)
| Function | Description |
|----------|-------------|
| `providers/0` | Returns list of predefined provider entries (Anthropic, OpenAI, Google, DeepSeek, ZAI, Alibaba) with models |
| `provider_models/1` | Returns model shortcuts for a given provider atom |
| `resolve_model/2` | Resolves `{provider_atom, model_input}` to `"provider:model"` string (backward-compat string form) |
| `resolve_model_spec/3` | Map-producing analog of `resolve_model/2`. Returns `%{provider: atom, id: string}` plus optional `base_url`/`extra`. Opts: `:base_url`, `:variant`, `:extra`. |
| `requires_base_url?/1` | Returns whether a provider requires a custom `base_url` (reads the `requires_base_url` flag; default `false`). `:openai_compatible` → `true`. |
| `find_provider/1` | Finds provider entry by atom (checks `provider_atoms` list) |
| `unknown_provider_help/0` | Returns guidance text with links to llmdb.xyz and ReqLLM docs |
| `known_credential_keys/0` | Returns all unique credential key names from the catalog |

### `EvoGit.Defaults` (backward-compatibility shim)
Delegates all calls to `EvoGit.Config.resolve/1`. Functions: `max_concurrency`, `max_tool_concurrency`, `max_retries`, `agent_max_retries`, `max_agent_depth`, `llm_model`, `github_username`, `compression_threshold_tokens`, `sandbox`.

### `EvoGit.Platform` (cross-platform utilities)
| Function | Description |
|----------|-------------|
| `os/0` | Returns `:linux`, `:macos`, `:windows`, or `:unknown` |
| `config_dir/1` | Platform-specific config dir (XDG/Linux, Application Support/macOS, APPDATA/Windows) |
| `data_dir/1` | Platform-specific data dir |
| `shell/0` | Returns `"bash"` or `"powershell"` |
| `shell_args/1` | Returns `["-c", cmd]` or `["-Command", cmd]` |
| `systemd_available?/0` | Returns true on Linux with systemd |
| `nix_available?/0` | Returns true when the `nix` binary is found in PATH (Linux and macOS) |

### `EvoGit.ProjectConfig` (per-repo genesis.toml)
| Function | Description |
|----------|-------------|
| `read/1` | Parses `genesis.toml` from repo root |
| `worktree_script/1` | Returns worktree init script for current OS (backward-compat wrapper) |
| `worktree_script/2` | Returns worktree init script for given OS, with variant resolution |
| `write_worktree_script/2` | Writes/merges worktree init script (inline content) into `genesis.toml` `[worktree].script`; preserves existing sections/keys |
| `commands/1` | Returns map of user-defined dev command shortcuts from `[commands]` section |
| `foreign_repos/1` | Returns list of `ForeignRepo` structs |

### genesis.toml Structure
```toml
[worktree]
# Single fallback script (any OS):
script = "..." 
# OR OS-specific variants (TOML dotted keys):
script.linux = "..."
script.macos = "..."
script.windows = "..."
# Resolution: script.<current_os> → script (fallback) → nil

[commands]
dev = "npm run dev"      # User-defined shortcuts, displayed in dashboard
test = "mix test"        # Manually triggered, NOT auto-executed

[foreign_repos.original]
path = "/Source/original-proj"
name = "Legacy Project"
```

### Worktree Init Script Environment Variables
| Variable | Description |
|----------|-------------|
| `SOURCE_REPO_PATH` | The main repository checkout path |
| `TARGET_WORKTREE_PATH` | The newly created worktree path |
| `SOURCE_WORKTREE_PATH` | Parent agent's worktree path (or `SOURCE_REPO_PATH` for top-level agents) |

### Configuration Levels (priority: low → high)
1. **Application defaults** — Hardcoded in `defaults/0` (no model, no username)
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`
3. **Runtime overrides** — Session-level, stored in `AgentScheduler` GenServer state via `handle_call({:update_config, opts})`. Applied via CLI flags (`-c`, `-m`, `--retries`, etc.) or dashboard settings panel.

### config.toml Structure
```toml
[scheduler]
max_concurrency = 3          # Max concurrent LLM calls
max_tool_concurrency = 2     # Max concurrent tool executions
agent_max_retries = 3        # Crash-retry limit per agent
max_agent_depth = 8          # Max subagent recursion depth
max_retries = 15             # Max total LLM API retries

[llm]
model = "provider:model"     # REQUIRED. e.g. "anthropic:claude-sonnet-4-20250514"
compression_threshold_tokens = 100_000  # Token limit before context compression

[user]
github_username = "..."      # For PR creation

[sandbox]
mode = "auto"                # "auto" | "enabled" | "disabled"

[nix]
enabled = false              # Run tool calls inside a cached Nix dev environment (requires flake.nix in config dir)
flake_output = nil           # Optional: e.g. "devShells.x86_64-linux.default"
```

### credentials.toml Structure
```toml
GOOGLE_API_KEY = "AIza..."
ANTHROPIC_API_KEY = "sk-ant-..."
OPENAI_API_KEY = "sk-..."
ZAI_API_KEY = "sk-..."
DEEPSEEK_API_KEY = "sk-..."
GROQ_API_KEY = "gsk_..."
TAVILY_API_KEY = "tvly-..."
```
Keys are loaded into ReqLLM's in-process key store on load. Only one key needed (matching the LLM model's provider).

## Constraints
- `save_user_config/1` writes to `config.toml` and `save_credentials/1` writes to `credentials.toml`. Both create the config directory if needed.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- Config directory follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads use `case File.read/1` (non-crashing) with explicit error handling via `with`/`case`, not `try/rescue`.
- `EvoGit.Defaults` is a backward-compatibility shim that delegates all calls to this module.
- Model format: either a `"provider:model"` string (preferred, resolves through LLMDB for cost tracking) OR a map spec `%{provider: atom, id: string, base_url: string, extra: %{...}}` (ReqLLM-native). Map model specs are normalized at **resolve time** (`normalize_model_map/1` in `atomize_enum_values/1`): simple models (only `:provider`+`:id`) become `"provider:id"` strings, models with override keys (`:base_url`, `:extra`, etc.) stay as atomized maps — both are LLMDB-compatible formats that ReqLLM natively resolves. String model specs pass through as-is (no parsing). The `[[llm.models]]` data layer supports multiple endpoints per provider+model via per-profile `base_url`. The provider atom determines which API key env var is used.
- `config_status/0` checks: LLM model presence, at least one API key. GitHub username is **optional** — a missing username does NOT appear in `:missing`/`:warnings` or make `:ok?` false.
- **Crash resilience (untrusted user config boundary)**: The `resolve/0` → `config_status()` pipeline MUST NEVER raise on any user-provided config content, including valid TOML with wrong value types (e.g. `llm = "string"` instead of a `[llm]` table). `deep_merge/2` discards type-mismatched user values (keeping the default map). `migrate_llm_models/1`, `atomize_enum_values/1`, `Schema.model_profiles/1`, and `Schema.validate/1` all guard against non-map structures. `Schema.validate/1` uses `safe_get_in` (not `get_in`) to avoid Access-behaviour crashes on non-map intermediate values. Bad config produces `validation_errors` but does not crash the caller — the user must always be able to boot the app and access the settings page.
