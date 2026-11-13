# Config — Unified Configuration Resolver

## Intent
`EvoGit.Config` — single source of truth for non-project configuration: merges built-in defaults with user config (`~/.config/genesis/config.toml`), loads API keys from `credentials.toml` into ReqLLM's key store, persists user config changes, and diagnoses configuration completeness.
Reads are served from ONE RAM snapshot per config directory (`EvoGit.Config.Cache`), refreshed only by a config-changed event raised by a save or by `EvoGit.Config.Watcher`'s file watch — never by a per-call file stat.

## Routing Table
- `./schema/` → config schema definitions (pure data: keys, types, defaults, validation) + provider/model generation-parameter extraction (`schema/CONTEXT.md`)

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Merged config map (defaults + user config) from the RAM snapshot — a `:persistent_term` lookup with no file I/O and no validation (see "Config Caching"). Runtime overrides live in `AgentScheduler` state. |
| `resolve/1` | Resolved value for a key path (atom or list of atoms), read from the same snapshot with schema defaults applied on nil. |
| `user_config/0` | Parsed `config.toml` from the RAM snapshot, or `%{}` if absent/unparseable; zero `File.stat`/`File.read` per call (see "Config Caching"). |
| `save_user_config/1` | Validates, then persists a config map to `config.toml` (creates the config dir); raises `EvoGit.Config.Watcher.notify_change/1`, so the snapshot is refreshed synchronously on success. `:ok \| {:error, reason}` |
| `save_credentials/1` | Merges/persists an API key map to `credentials.toml`; sets keys via `ReqLLM.put_key` for immediate in-process use; raises `EvoGit.Config.Watcher.notify_change/1`, so the snapshot is refreshed synchronously. `:ok \| {:error, reason}` |
| `config_status/0` | Diagnostic map `:missing`/`:warnings` from LLM-model + credential presence, `:validation_errors` from the SAME snapshot value it resolved, and `:ok?` only when both checks pass; the `:api_key` check is OAuth-aware (API key present OR an OAuth profile's subscription credential resolves — see "OAuth / Subscription Auth"); GitHub username is optional and NOT checked. |
| `credentials/0` | Credentials map from the RAM snapshot; the `ReqLLM.put_key` side effects run only on a snapshot BUILD (cold miss or reload), never on a hit. |
| `defaults/0` | Built-in defaults (scheduler concurrency/retry settings, empty llm/user maps, sandbox mode); three values are CPU-thread-derived (see Configuration Levels). |
| `config_path/0` | Full path to `config.toml` |
| `config_dir/0` | Platform config dir (XDG/macOS/Windows) via `EvoGit.Platform.config_dir("genesis")` |
| `credentials_path/0` | Full path to `credentials.toml` |
| `lsp_enabled?/0` | SINGLE gate for offering the `lsp` tool (see `[lsp]` below): `true` only when the resolved `[:lsp]` section is a map whose `:enabled` is `true`/`"true"` AND whose `:command` is a non-blank binary. Never raises (nil/non-map section, other enabled values, nil/non-binary/blank command → `false`). |

### `EvoGit.Config.LLMCatalog` (provider/model shortcuts)
| Function | Description |
|----------|-------------|
| `providers/0` | Predefined providers (Anthropic, OpenAI, ChatGPT Codex (OAuth), Google, DeepSeek, Alibaba, Z.ai, MiniMax, Moonshot AI (Kimi), xAI, OpenRouter, OpenAI-Compatible) with models |
| `provider_models/1` | Model shortcuts for a provider atom |
| `resolve_model/2` | `{provider_atom, model_input}` → `"provider:model"` string (backward-compat) |
| `resolve_model_spec/3` | Map analog: `%{provider: atom, id: string}` + optional `base_url`/`extra`. Opts `:base_url`, `:variant`, `:extra`. |
| `requires_base_url?/1` | Provider requires a custom `base_url` (flag; default `false`). `:openai_compatible` → `true`. |
| `find_provider/1` | Provider entry by atom (checks `provider_atoms`) |
| `auth_modes/1` | `[:api_key] \| [:api_key, :oauth] \| [:oauth]` for a provider atom; **default `[:api_key]`** for an unknown/API-key-only provider |
| `oauth_source/1` | Vendor CLI whose login file the credential is imported from (`:codex_cli` for `:openai_codex`, `:claude_code` for `:anthropic`), else `nil` |
| `oauth_only?/1` | `true` when `:api_key` is NOT in `auth_modes/1` — i.e. a subscription is the only way to authenticate |
| `supports_oauth?/1` | `true` when `:oauth` is in `auth_modes/1`, which is what enables the dashboard's auth-mode choice |
| `unknown_provider_help/0` | Guidance text (llmdb.xyz + ReqLLM docs links) |
| `known_credential_keys/0` | All unique credential key names from the catalog — an entry's `credential_key` is contributed ONLY when `:api_key` is in its `auth_modes` (so the OAuth-only `:openai_codex` never makes `EvoGit.Config.api_key_present?/1` report a key), while VARIANT keys are contributed unconditionally |
**Model lists are derived data, not curated history**: each provider's `models` are newest-generation-first shortcuts derived from the vendored LLMDB snapshot (`deps/llm_db/priv/llm_db/snapshot.json`), with retired/superseded generations and non-chat entries dropped — EXCEPT `:openai_codex`, whose ids come from the Codex backend's own model cache (priority order, hidden entries excluded) and which LLMDB does not know (`test/evo_git/config/llm_catalog_test.exs` exempts exactly that provider from its "every catalog model resolves via `LLMDB.model/2`" bar). Refresh a list by re-deriving it from the same source; do NOT hand-add a generation the snapshot does not carry.

### `EvoGit.Config.VersionState` (upgrade detection)
Tracks the last-seen Genesis version in `version_state.toml` (config dir); defaults to `"0.8.0"` when no file exists.
| Function | Description |
|----------|-------------|
| `get_version/0` | Recorded version string (default `"0.8.0"` if absent/unparseable/missing key) |
| `current_version/0` | Runtime version via `Application.spec(:evo_git, :vsn) \|> to_string()` |
| `save_version/1` | Persists a version string. `:ok \| {:error, reason}`. Also `save_version/0` (persists `current_version/0`). |
| `upgraded?/0` | `true` if recorded version ≠ current version |
| `record_current_version/0` | Persists `current_version/0`. Call after showing the update log. |

### `EvoGit.Platform` (cross-platform utilities)
| Function | Description |
|----------|-------------|
| `os/0` | `:linux`, `:macos`, `:windows`, or `:unknown` |
| `config_dir/1` | Config dir (XDG/Linux, Application Support/macOS, APPDATA/Windows) |
| `data_dir/1` | Platform data dir |
| `shell/0` | Effective shell executable — honors the `[tools] shell` config override; defaults `"bash"` (Linux/macOS) / `"powershell"` (Windows) |
| `shell_args/1` | `["-c", cmd]` (POSIX shells) or PowerShell `-EncodedCommand` args (via `EvoGit.Powershell`) — chosen from the effective shell |
| `systemd_available?/0` | Linux + systemd |
| `nix_available?/0` | `nix` binary in PATH (Linux and macOS) |

### `EvoGit.ProjectConfig` (per-repo genesis.toml)
| Function | Description |
|----------|-------------|
| `read/1` | Parses `genesis.toml` from repo root |
| `worktree_script/1` | Worktree init script for the current OS (backward-compat wrapper) |
| `worktree_script/2` | Worktree init script for a given OS, with variant resolution |
| `write_worktree_script/2` | Writes/merges the worktree init script into `genesis.toml` `[worktree].script`; preserves existing sections/keys |
| `commands/1` | User-defined dev command shortcuts from `[commands]` |
| `foreign_repos/1` | `ForeignRepo` structs |

### genesis.toml Structure
```toml
[worktree]
script = "..."                 # Single fallback script (any OS)
script.linux = "..."           # OR OS-specific variants (TOML dotted keys)
script.macos = "..."
script.windows = "..."
# Resolution: script.<current_os> → script (fallback) → nil

[commands]
dev = "npm run dev"      # User-defined shortcuts, displayed in dashboard
test = "mix test"        # Manually triggered, NOT auto-executed

[foreign_repos.original]
path = "/Source/original-proj"
description = "Legacy Project"
```

### Foreign repos — schema & machine-binding gotchas
- **There is NO `[[repos]]`/repo-registry table in `config.toml`**: `Definitions.schemas/0` contains no repo/path key at all (`repos`/`repo`/`foreign` appear nowhere in `schema/`), so `Schema.validate/1` never validates a repository path and `Config.resolve/0` returns no repo list. The only repository configuration is the per-repo `genesis.toml` `[foreign_repos.<id>]` read by `EvoGit.ProjectConfig` (sibling `../project_config.ex`, deliberately NOT Ecto-validated), plus the per-task `:foreign_repos` opt.
- **Schema**: `[foreign_repos.<id>]` tables with `path` (REQUIRED — missing → entry dropped + `Logger.warning` "Failed to parse foreign_repos", `ProjectConfig.build_foreign_repo/2`) and `description` (optional). The TOML table key IS the id. **The key is `description`, NOT `name`** — a `name` key is silently ignored (only `"description"` is read; the `ForeignRepo` struct field is `:description`). No other keys (no `enabled`/opt-in flag): every entry is always loaded.
- **Committed to git**: `genesis.toml` is NOT git-ignored (the `.gitignore` Genesis auto-writes into new repos contains only `/.genesis`; the root `.gitignore` doesn't cover it) and Genesis Mode B auto-creates it via `ProjectConfig.write_worktree_script/2` — so absolute paths in `[foreign_repos]` are committed and wrong on any other machine.
- **Path handling**: nothing validates absolute paths, but they are semantically required — `ForeignRepo.new/3` only runs `EvoGit.Platform.safe_expand/1`: `~` → home, RELATIVE → the PROCESS CWD (the calling process's cwd, NOT the repo root), and no `$VAR`/`${VAR}` expansion exists in `config.ex`/`project_config.ex`. No existence check at load or task start: a path missing on this machine flows into the agent's context table and fails only at delegation time (`build_subagent_phylo_node` hard-matches `{:ok, foreign_head} = Git.rev_parse(target_repo_root)` → MatchError on first delegation when no tracked commit exists).
- **Task-opt merge**: `Runtime.Helpers.merge_foreign_repos/2` normalizes both lists via `ForeignRepo.normalize/1` then `Map.merge(toml_map, opt_map)` — the task opt wins per id, unparseable dropped, and it can OVERRIDE but never REMOVE a genesis.toml entry. The dashboard's per-project in-memory list (loaded at project open; edits live only in socket assigns, never persisted) is passed per task via `runtime_opts[:foreign_repos]`. `ResumeContext` does NOT carry `:foreign_repos` on resume_from tasks (only `MergeContext` does) — resumed tasks re-get only genesis.toml repos.

### Worktree Init Script Environment Variables
| Variable | Description |
|----------|-------------|
| `SOURCE_REPO_PATH` | Main repository checkout path |
| `TARGET_WORKTREE_PATH` | Newly created worktree path |
| `SOURCE_WORKTREE_PATH` | Parent agent's worktree path (`SOURCE_REPO_PATH` for top-level agents) |

### Configuration Levels (priority low → high)
1. **Application defaults** — `defaults/0` (no model, no username). Three defaults are **dynamic** (computed at `Definitions.schemas/0` runtime): `[:scheduler, :max_tool_concurrency]` and both sandbox `:cpu_quota` values (`[:sandbox, :resources, :cpu_quota]`, `[:sandbox, :process, :cpu_quota]`) derive from `EvoGit.Platform.cpu_threads/0` (= `max(System.schedulers_online(), 1)`) — the tool cap equals the CPU thread count and each quota string is `"#{cores * 100}%"`. Living on the schema map itself, the value is shared by display, reset-to-default (dashboard) and resolution.
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`.
3. **Runtime overrides** — `AgentScheduler` GenServer state via `handle_call({:update_config, opts})`; set by dashboard settings / `RemoteAPI.reload_config` — concurrency/retry/turn values are config.toml-only, and model selection is task-level, carried in task opts rather than as a scheduler override.

### config.toml Structure
**`[data] dir` relocates the runtime data dir** (which holds `tasks.sqlite`, logs, remote binaries, nix cache, `genesis-source`) — see `[data]` below.
`EvoGit.Platform.data_dir/0` consults `EvoGit.Config.resolve([:data, :dir])`: a non-empty absolute (or `~`-expanded home-relative) value is returned; invalid values (nil / empty / non-binary / relative) log a `Logger.warning` and fall back to the OS + env default via `base_dir("genesis", "XDG_DATA_HOME", ".local/share")`. It NEVER raises (called from sandbox/agent contexts where crash-resilience is a hard constraint).
**Precedence chain**: TaskRegistry `opts[:data_dir]` test seam → app env `config :evo_git, :data_dir` (honored ONLY where `Application.get_env(:evo_git, :data_dir, ...)` is read — the Store child spec, `TaskRegistry.init/1`, `mix migrate.store`; set only in `config/test.exs`) → TOML `[data] dir` → XDG platform default (env `XDG_DATA_HOME` (Linux) / `APPDATA` (Windows) / `HOME` (fallbacks); `XDG_CONFIG_HOME` drives the config dir). Direct `Platform.data_dir()` consumers — the desktop log path, `SelfReflectiveSource` genesis-source clone, `RemoteBootstrap` remote_binaries cache, `Sandbox.Nix` cache — honor the TOML override too (ignoring only the app-env override). Per-repo `.genesis` artifacts (agent worktrees at `<repo_root>/.genesis/workers`) stay repo-root-fixed, NOT relocatable via `[data] dir`.
**Boot ordering**: config.toml IS parsed before the Store child spec's data-dir computation — `EvoGit.Config.resolve()` runs unconditionally in `config/runtime.exs` (release boot, before any app starts, in every release — `genesis`, `genesis_desktop`, `genesis_server`) and again inside `EvoGit.Application.start/2` via `EvoGit.Distribution.maybe_enable/0`, so `[data] dir` is readable when the Store child spec evaluates `Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())`. The config file's own location never depends on the data dir (`Config.config_path/0` → `Config.config_dir/0` → `EvoGit.Platform.config_dir("genesis")`, a separate `base_dir` call keyed on `XDG_CONFIG_HOME`), so the override creates no chicken-and-egg.
Platform→Config runtime calls are safe (no compile cycle — the calls live in function bodies): `Platform.shell/0` calls `Config.resolve([:tools, :shell])`, and `Platform.data_dir/0` calls `Config.resolve([:data, :dir])`.
```toml
[scheduler]
default_llm_max_concurrency = 3   # Per-LLM concurrency when a model profile has none
max_tool_concurrency = 8          # Max concurrent tool executions (default = detected CPU thread count)
agent_max_retries = 3             # Crash-retry limit per agent (non_neg_integer, min 0)
max_agent_depth = 8               # Max subagent recursion depth (pos_integer, min 1)
max_retries = 15                  # Max total LLM API retries (pos_integer, min 1)
max_turns = 128                   # Turn cap for SUB-agents (pos_integer, min 1)
max_turns_root = 1000             # Turn cap for the ROOT agent only (pos_integer, min 1)
delegation_hint_threshold = 5     # Write-tool calls to a child dir before a delegation nudge (pos_integer, min 1; 0 disables)
read_delegation_hint_threshold = 8 # Read-tool calls to a child dir before an investigator nudge (pos_integer, min 1; 0 disables)
max_tool_timeout = 1_800_000      # Hard cap (ms) on any agent-requested tool timeout (pos_integer, min 1)
default_tool_timeout = 10_000     # Default tool timeout (ms) when the agent omits one (pos_integer, min 1)
[llm]
model = "provider:model"          # REQUIRED, e.g. "anthropic:claude-sonnet-4-20250514"
# compression_threshold_tokens = 150_000  # OPTIONAL explicit override (pos_integer, min 1); default nil = threshold derived from the profile's context_window (default 200_000)
tool_result_pruning = true        # Stage-1 model-free pruning of old tool results (boolean, default true)
tool_result_pruning_target_fraction = 0.5  # Stage-1 pruning target as a fraction of the context window (float 0.0–1.0, default 0.5)

[user]
github_username = "..."           # For PR creation

[sandbox]
mode = "auto"                     # "auto" | "enabled" | "disabled"
backend = "auto"                  # "auto" | "systemd" | "bwrap"
write_paths = []                  # Optional; unset/nil = platform defaults, set (incl. []) = REPLACES built-in list

[nix]
enabled = false                   # Run tool calls inside a cached Nix dev environment (requires flake.nix in config dir)
flake_output = nil                # Optional, e.g. "devShells.x86_64-linux.default"

[appearance]
accent_color = "blue"             # Dashboard UI accent color (GNOME/libadwaita palette: blue|teal|green|yellow|orange|red|pink|purple|brown|slate)

[data]
dir = "/abs/path/to/data"         # Optional: relocate the runtime data/state dir (tasks.sqlite, logs, caches). Absent/nil = platform default. Takes effect at next boot.

[tmp]
mode = "system"                   # Per-task temporary-directory mode: "system" (default) | "custom" | "per_repo"
path = "/abs/path/to/tmp"         # Base path for :custom mode; absolute (or ~-relative). Absent/nil = system tmp

[lsp]
enabled = false                   # Offers the `lsp` tool (Elixir diagnostics/hover/definition) to agents. While false (default) no agent gets the tool at all
command = "lexical"               # Language server executable, e.g. "lexical" or an absolute elixir-ls launcher path
args = ["start"]                  # Arguments passed to the command
timeout = 30_000                  # Overall per-call budget (ms)
diagnostics_timeout = 10_000      # How long to wait for publishDiagnostics after opening the file (ms)
```

**`[tmp]` — per-task managed temporary directory**: `EvoGit.Config.resolve([:tmp, :mode])` + `[:tmp, :path]` select the base directory for an agent task's managed tmpdir (`task_<id>`):
- `:system` (default) → `<system tmp>/genesis/task_<id>` (honors the user's OS tmp configuration, e.g. `$TMPDIR`).
- `:custom` → `<[tmp] path>/genesis/task_<id>`; when the base is empty/nil (or not an absolute / `~`-relative path) the mode falls back to the system tmp.
- `:per_repo` → `<task's primary repo>/.genesis/tmp/task_<id>`.

`mode` is an `:atom` enum (`"system" | "custom" | "per_repo"`); the TOML string is atomized by the dedicated `[:tmp]` clause in `EvoGit.Config.atomize_enum_values/1` before `Schema.validate` — without that clause the raw string fails the `:atom` type check and lands in validation warnings.
The `[:tmp, :*]` keys carry `category: :data` (NOT a new `:tmp` category): the dashboard Settings page hardcodes its category set (`EvoDashWeb.SettingsComponents.CategoryMetadata`) and a new category would crash its sidebar render; `:data` renders them generically with no platform filtering, and the `[tmp]` TOML table itself is unaffected by that grouping.

**`[lsp]` — Elixir code intelligence for the `lsp` tool**: the tool (`agent/tools/lsp.ex`) never installs, downloads or bundles a language server — it speaks LSP over stdio to whatever this section points at (a user-installed `lexical start` or an elixir-ls launcher), one disposable server process per call.
Keys (all `category: :tools` — the dashboard renders them under Tools despite the `[lsp]` table): `enabled` (`:boolean`, default `false`), `command` (`:string`, default `nil` — resolved through `EvoGit.Executable.resolve/1` + `System.find_executable/1`), `args` (`:list_of_strings`, default `[]`), `timeout` (`:pos_integer` ms, default `30_000`, `min: 1` — the WHOLE-call budget: spawn, `initialize` handshake and the one analysis request) and `diagnostics_timeout` (`:pos_integer` ms, default `10_000`, `min: 1` — the settle window for `textDocument/publishDiagnostics`, ending early once the stream goes quiet).
The tool is NOT OFFERED AT ALL while `EvoGit.Config.lsp_enabled?/0` is false (the default): no `lsp` schema is built, so no agent — root, subagent or repo-less — sees the tool and no prompt tokens are spent on it.
Re-enable: `[lsp]` with `enabled = true` and `command = "lexical"` (plus `args = ["start"]`); once offered, a still-unconfigured call returns the self-explaining `Error: no language server configured — set [lsp] command in config.toml`, telling the model to fall back to `read_file`/`rg` — so the section can be absent from `config.toml` entirely and nothing breaks.
Validation is warning-only at runtime: `EvoGit.Config.resolve/0` logs `Config validation error at [:lsp, ...]` via `Logger.warning` and still returns the merged config; only `save_user_config/1` refuses a malformed value. `EvoGit.Config.lsp_enabled?/0` and the tool's own settings normalize defensively (non-map section → disabled, non-list `args` → `[]`, invalid timeouts → defaults) and accept the STRING `"true"` for `enabled` even though the strict `:boolean` type flags it as a validation error.
Only two consumers read the section: `lsp_enabled?/0` (the offering gate, via `resolve([:lsp])`) and the tool itself (also `resolve([:lsp])`, treating a non-map result as `%{}`).

**`[[llm.providers]]` canonical inventory**: each STRING-keyed account has `id`, `provider`, optional `name`, shared auth/endpoint/concurrency/peak/generation settings, ordered `models`, optional `default_model`, `reasoning_efforts` and `default_reasoning_effort`.
The optional `[llm] default_provider_profile` selects an account by id; absent selectors choose the first account/model, while explicit unknown selectors return resolution errors.
Nested models accept a model id string or a map with `model` (`id` is an input alias), optional generation/context/effort overrides, and remain recursively string-keyed after config resolution.
The `Schema.provider_profiles/1`, `model_selections/1` and `resolve_model_spec/2` APIs delegate to `Schema.ProviderProfiles`; exact maps, precedence and error shapes are documented in `schema/CONTEXT.md`.

**Legacy `[[llm.models]]` profile fields** (still accepted when providers are absent/empty): `id` (required), `model` (required), `concurrency` (per-profile LLM concurrency), `context_window` (optional positive integer, default `200_000` — the model's context window in tokens, used as the context-compression window), `auth_mode` + `oauth_file` (optional subscription-auth selection, see "OAuth / Subscription Auth"), plus optional `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days`:
```toml
[[llm.models]]
id = "deepseek"
model = "provider:model"       # same format as [llm] model
concurrency = 4                # normal (off-peak) concurrency
context_window = 200000        # optional — context window in tokens (default 200000)
auth_mode = "api_key"          # optional — "api_key" (default) | "oauth" (subscription)
# oauth_file = "~/.config/genesis/auth.json"   # optional — per-profile managed OAuth credential file
peak_concurrency = 0           # optional — concurrency during peak windows (0 = hard pause)
peak_hours = [                 # optional — daily windows; local wall clock unless `timezone` set
  { start = "09:00", end = "12:00", days = ["mon", "tue", "wed", "thu", "fri"] },
  { start = "14:00", end = "18:00", days = "weekdays" }   # keyword = mon-fri
]
timezone = "Asia/Shanghai"     # optional — IANA tz for this profile's peak windows
off_peak_days = ["sat", "sun"] # optional — entire day off-peak: normal concurrency 24/7
```
- `auth_mode` — optional enum, `"api_key"` (default) | `"oauth"`; it is bookkeeping for humans and the dashboard, while the RUNTIME decision is `Schema.LLM.oauth_profile?/1` (`auth_mode == :oauth` OR an OAuth-only provider). Validated by `EctoValidation.validate_auth_mode/2` (path `[:llm, :models, <idx>, :auth_mode]`, message `"auth_mode must be \"api_key\" or \"oauth\", got <inspect>"`; atom spellings `:api_key`/`:oauth` are accepted for programmatic callers).
- `oauth_file` — optional non-empty path for THIS profile's managed OAuth credential file; absent → `<config_dir>/auth.json` (there is no global `[llm] oauth_file` key). Validated by `EctoValidation.validate_oauth_file/2` (path `[:llm, :models, <idx>, :oauth_file]`, message `"oauth_file must be a non-empty string path, got <inspect>"`).
- `context_window` — optional positive integer (tokens); absent/nil → `200_000`; it is the model's context window for context compression (Stage-1 pruning target + derived threshold). Validated by `EctoValidation.validate_model_profile/2` (path `[:llm, :models, <idx>, :context_window]`, rule `:integer`, message `"context_window must be a positive integer, got <inspect of value>"`). Read via the ONE shared resolver in `EvoGit.Config.Schema.LLM`: `default_context_window/0` → `200_000`; `context_window/1` (profile map, atom- or string-keyed; absent → default, invalid → `Logger.warning` + default, never raises); `context_window_for/2` (config map + model profile id; unknown id → default).
- `peak_concurrency` — NON-NEGATIVE integer when present (`0` = hard pause: zero LLM slots during peak, never raised by the `default_llm_max_concurrency` floor; negatives/floats/strings → validation error at `[:llm, :models, <idx>, :peak_concurrency]`); absent → off-peak `concurrency` always applies.
- `peak_hours` — list of maps with `start`/`end` as `"HH:MM"` 24h strings OR integer minutes of day (0..1439; both values of one window must use the same representation), atom- or string-keyed. Half-open `[start, end)`; `start > end` = overnight wrap; absent/`[]`/invalid → disabled (normal `concurrency` 24/7). `peak_hours` without `peak_concurrency` → legal no-op. `EvoGit.PeakHours.parse_window/1` + `validate_windows/1` are the single parse/validate path — they accept BOTH representations uniformly, so profiles whose `peak_hours` arrive as canonical integer windows (e.g. TOML `start = 540`) still get correct engine peak-exemption and transition wakeups.
- `timezone` — optional IANA name (e.g. `"Asia/Shanghai"`): all peak computations for that profile (in-peak checks + next-transition wakeups) use that tz wall clock, DST-aware; absent/empty/nil → server local wall clock. Validated by `EvoGit.PeakHours.validate_timezone/1` (single source of truth): nil/"" valid; unknown IANA name / no tz database → error at `[:llm, :models, <idx>, :timezone]`. Requires the tz database at boot: `Calendar.put_time_zone_database(Tz.TimeZoneDatabase)` in `EvoGit.Application.start/2` (`tz ~> 0.28`; IANA data pre-compiled, no auto-update).
- `off_peak_days` — optional list of days (atom- or string-keyed map tolerated) on which the profile is off-peak the **ENTIRE day**: normal `concurrency` 24/7, every `peak_hours` window suppressed, `peak_concurrency` (incl. hard-pause `0`) never applies. **Precedence: `off_peak_days` wins over window `days`.** Absent/`[]` → disabled. Vocabulary: `"mon"|"tue"|"wed"|"thu"|"fri"|"sat"|"sun"` (canonical 3-letter lowercase; case-insensitive input) + keywords `"weekdays"` (= mon-fri) and `"weekends"` (= sat-sun). Validated by `EvoGit.PeakHours.validate_days/1` (single source of truth — do NOT re-implement the day vocabulary); a bad value → `%ValidationError{}` at `[:llm, :models, <idx>, :off_peak_days]`.
- **Window `days`** — optional key on each `peak_hours` window (same vocabulary as `off_peak_days`): the window applies ONLY on the listed days; absent → every day. A bad value → `%ValidationError{}` at `[:llm, :models, <idx>, :peak_hours, <window_idx>, :days]` (falling back to bare `[:llm, :models, <idx>, :peak_hours]` when the window can't be located); validation delegates to `EvoGit.PeakHours` — the schema does NOT re-implement day parsing.
- **Validation ownership**: window parse/format/overlap/days checks delegate to `EvoGit.PeakHours.validate_windows/1`, `off_peak_days` to `validate_days/1`. `Schema.validate/1` reports `%ValidationError{}` at `[:llm, :models, <idx>, :peak_hours]` (non-list) or `[:llm, :models, <idx>, :peak_hours, <window_idx>]` (invalid entry; overlap error at the later window's index), plus `[:llm, :models, <idx>, :off_peak_days]` and `[:llm, :models, <idx>, :peak_hours, <window_idx>, :days]` for day-vocabulary errors.
- Peak-hour fields (incl. `timezone`, `off_peak_days`, window `days`) and `context_window` survive resolution (`deep_merge` → `atomize_enum_values` → `migrate_llm_models` → `Schema.validate`) untouched — profile keys are never stripped — reaching `state.model_profiles`, read via `get_config(:model_profiles)`.
- **`provider_options` / `store: false`**: `Schema.LLM.provider_options_for_model/1` returns `[store: false]` (from `default_provider_options/0`) for a NATIVE OpenAI endpoint only — provider `:openai` AND no custom endpoint override. A model-spec MAP carrying a non-nil `:base_url` or `:extra` is an OpenAI-**compatible** third-party endpoint (presence check, so even an empty `extra` counts), so e.g. an `:openai_compatible` catalog profile (`provider_atoms: [:openai]`, `requires_base_url: true` — OpenRouter et al.) gets `[]`.
- `store` is a Responses-API-only field: ReqLLM materializes it only in the OpenAI Responses driver body — the shared Chat-Completions encoder reads `provider_options` ONLY for `[:response_format]`. A profile's explicit `provider_options` override always wins over the provider-aware default (an empty override map yields no `:provider_options` key at all), and a `provider_options` key the provider does not declare RAISES at request time (req_llm validates against the provider schema — `zai` accepts `[:thinking]` only).
- **Generation parameters are provider/model-aware** at the single choke point `Schema.LLM.profile_generation_params/1`, which pipes its assembled keyword list through `Schema.LLMConstraints.filter/3` (declarative Z.AI/GLM constraint table + llm_db model metadata; full contract in `schema/CONTEXT.md`). The dashboard persists NO generation params unless the user typed them (an untouched profile is `id`/`model`/`concurrency` only), so the filter only ever removes parameters the user explicitly set.
  That call is the ONLY path in this subtree that reaches the LLMDB catalog: `Schema.LLM.model_metadata/1` is uncached and, when the `:llm_model_metadata_fun` seam is unset, the first call on a cold BEAM performs the whole catalog load in the CALLING process — at boot that caller is `EvoGit.CatalogWarmup`'s throwaway process (started immediately before `AgentScheduler`, which then only reads the warm catalog) — detail: `schema/CONTEXT.md` → "Model metadata seam".
- **Not every extracted key reaches the wire**: `top_k`/`reasoning_effort` are accepted ReqLLM options, but the Z.AI family encodes neither (`Zai.Shared.add_basic_options/2` emits only `temperature`, `top_p`, `frequency_penalty`, `presence_penalty`, `user`, `seed`, `stop`; `reasoning_effort` is telemetry-only there), while the OpenAI chat-completions path DOES emit `reasoning_effort`. `stream_options: %{include_usage: true}` is emitted unconditionally on EVERY streamed chat call by req_llm's encoders; it is not an accepted ReqLLM option (passing it raises `NimbleOptions.ValidationError`) and streaming cannot be turned off, so it is NOT suppressible from the config layer.

**`[sandbox] backend`**: `:atom` schema key, default `:auto`, validation `[in: [:auto, :systemd, :bwrap]]`. `:auto` tries systemd-run → bwrap → no sandbox (macOS always uses sandbox-exec; bwrap is Linux-only). `:systemd` forces systemd-run (no sandbox if systemd unavailable). `:bwrap` forces bubblewrap — filesystem isolation only, no resource limits; falls back to no sandbox if `bwrap` is unavailable. **`[sandbox.resources]`/`[sandbox.process]` are systemd-only, ignored with bwrap.** String values are atomized by `atomize_enum_values/1` (`config.ex:209–220`, the hardcoded `:sandbox` clause covering `:mode` + `:backend`) before `Schema.validate`.
**Sandbox mode/backend are read from the CONFIG SNAPSHOT, never from scheduler state**: `Sandbox.backend/0` (`sandbox.ex:30`) and every backend's mode gate call `EvoGit.Config.resolve([:sandbox, :mode|:backend])`, and `resolve/0` deliberately excludes runtime overrides, so `AgentScheduler.update_config(sandbox_mode: …)` (accepted at `state.ex:477,500`) only changes the REPORTED `sandbox_mode`/`get_config` value, not what the sandbox does.
`sandbox_resources`/`sandbox_process_resources` DO apply live — `state.ex:519–525` pushes `SandboxSlice.update_resources_async/1` (Linux + a map value only); `get_config(:sandbox_backend)` reports platform detection (`Platform.sandbox_backend/0`), NOT the configured `[sandbox] backend`.
**There is NO app-env sandbox switch**: no `.ex` file reads `Application.get_env(:evo_git, :sandbox)`, so `Application.put_env(:evo_git, :sandbox, …)` is a NO-OP and `config/config.exs:70`'s `sandbox: :auto` is dead config.
Per-key types/defaults of all 19 `[sandbox]` descriptors: `schema/CONTEXT.md`.

**`[sandbox] write_paths`**: `:list_of_strings` schema key, default `nil`. nil → sandbox backends use platform-default writable paths; set (incl. `[]`) → REPLACES the built-in list (`[]` disables those writable paths entirely). Non-list/non-string-list → validation error (never crash). Consumed ONCE by `EvoGit.Sandbox.Spec.build/2` via `EvoGit.Config.resolve([:sandbox, :write_paths])` (renderers read the resolved `spec.cache_write_paths`): nil → the default cache-dir list; set → replaces the built-in cache-dir list only; `~`-prefixed entries expand to `System.user_home!()`, absolute as-is, relative joined to `$HOME`. Structural paths (cwd, tmp, nix store, repo `.git`) are always appended; deny lists are never affected. Details: `sandbox/CONTEXT.md`.

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
Keys are loaded into ReqLLM's in-process key store on load. Only one key is needed (matching the LLM model's provider).

## Adding a New Config Category / Schema (round-trip contract)

All schemas live in ONE flat list — `EvoGit.Config.Schema.Definitions.schemas/0` (NOT per-category modules). A schema is a plain map with 7 keys (`key_path`/`type`/`default`/`validation`/`category`/`sub_category`/`description`) — there is NO `%Schema{}` struct. `schemas_by_category/0` = `Enum.group_by(& &1.category)`; per-category order = definition order.

Adding a NEW top-level category is additive for: enumeration (append a schema map), `Schema.validate/1` (only checks defined keys; absent keys and nil values pass; unknown keys never rejected), `defaults/0` (derived automatically from each schema's `:default` via `deep_put` — no separate defaults map), and save-side serialization (`stringify_keys` + `TomlElixir.encode` write any map; atom VALUES encode as quoted TOML strings, e.g. `:blue` → `accent = "blue"`; nil values are dropped).

**The one non-additive gap is the READ/resolve path**: TOML has no atoms, and string enum values are atomized ONLY by `atomize_enum_values/1`, whose HARDCODED per-category clauses cover `:sandbox` (`:mode`/`:backend`), `:git` (`:cow_worktree_creation`), `:llm` (model normalization), `:tools` (search provider + per-provider `search_depth`, via `search_providers/0`) and `[tmp]` (`:mode`). The `:tools` clause touches ONLY `[:tools, :search, :provider]` and `[:tools, :search, <provider>, :search_depth]`, so a NEW atom-typed key under `:tools` needs its own handling (or `type: :string` + `validation: [in: [...]]`). A NEW `:atom`-enum key (e.g. `[appearance] accent = "blue"`) needs a matching clause (or `:string` typing + atomization at the consumption point, like `[:llm, :reasoning_effort]`); without it every snapshot build logs `must be an atom, got "blue"` and `config_status/0` reports it (non-fatal — the value just stays a string). The dashboard save path is unaffected: `SettingsUtils.parse_atom/2` (evo_dash) converts `:atom` form values against `validation[:in]` BEFORE `Schema.validate`, so saves round-trip through TOML as quoted strings — read-side atomization is the only gap.

Dashboard-side requirements for a new schema-driven category (evo_dash, not core): `category_display_name/1`, `category_icon/1`, `category_description/1` clauses in `EvoDashWeb.SettingsComponents.CategoryMetadata` (no catch-all — a missing clause = FunctionClauseError in the sidebar/header) plus an entry in its `sort_categories/1` order list (missing = sorts last). `:agents`/`:remote_connections` are NOT core categories — the dashboard injects them as empty-schema pseudo-categories rendered by dedicated inline UI branches.

## Validation Engine — Ecto-backed (architecture)

The scalar/rule validator beneath the DSL is **Ecto-backed, but Ecto is a VALIDATOR ONLY** — no `Ecto.Changeset` is ever built, `apply_changes` is never called, and the validated map passes through unchanged on `{:ok, config}` (unknown keys survive, model profiles stay plain maps).

- **`EctoTypes`** (`ecto_types.ex`) — eight nested strict `use Ecto.Type` modules (`PosInteger`, `NonNegInteger`, `Integer`, `String`, `ListOfStrings`, `Float`, `Atom`, `Boolean`), one per scalar DSL type; public `type_for/1` (scalar type → fully-qualified module), `cast/2` (`Ecto.Type.cast(type_for(t), v)` — no base-type coercion) and `valid?/2`. They are **strict decision oracles**: no numeric-string coercion (`"3"` fails integer types), `""` is meaningful (never stripped), `:float` accepts int-or-float, `:atom` never casts strings.
- **`EctoValidation`** (`ecto_validation.ex`) — error adapter + composite recursion; `errors_for(key_path, type, validation, value) :: [%ValidationError{}]` returns type errors FIRST then rule errors. All window/day/timezone math **delegates to `EvoGit.PeakHours`** (`validate_windows/1` / `validate_timezone/1` / `validate_days/1`); `min`/`max`/`in` stay hand-written pure predicates (Ecto's `validate_number`/`validate_inclusion` are banned by design). Message sentences, `value`/`rule` terms, sub-path key_paths and error ordering are **byte-pinned** by the `schema_test.exs` / `config_test.exs` suites.

**Delegation path**: `Schema.validate/1` keeps its map-walk + `safe_get_in/2` and calls `EctoValidation.errors_for/4` per present value; scalar decisions route through `EctoTypes.valid?/2` (→ `Ecto.Type.cast` → module `cast/1`). Composite types (`:model_spec`, `:model_profiles`) and the optional profile fields (`peak_concurrency`, `peak_hours`, `timezone`, `context_window`, `off_peak_days`) recurse explicitly (multi-error, sub-path-aware), with scalar leaves through `EctoTypes` where a matching type exists (e.g. `peak_concurrency` → `EctoTypes.valid?(:non_neg_integer, v)`, rule preserved as `:integer`).

**What stays hand-written (and why)**: Ecto has no TOML story and the pipeline runs on variable-depth maps with byte-pinned shapes, so the **transform pipeline stays in `config.ex`** — `deep_merge`, `atomize_enum_values` (atomization stays PRE-Ecto: Ecto validates atoms, never produces them), `migrate_llm_models`, and save serialization (`strip_flat_llm_fields`, `stringify_keys`, `TomlElixir`). `Schema.defaults/0` stays a hand-written `deep_put` from each descriptor's `:default` (byte-identical output, 106 entries — per-category breakdown in `schema/CONTEXT.md`). `config.ex` calls `Schema.validate/1` exactly once per snapshot build (`build_snapshot/1`, which keeps its errors in the snapshot) and validate-first in `save_user_config/1`.

**Ecto quirk handling**: (a) numeric strings fail number types — the custom `cast/1` modules never coerce; (b) `""` is never stripped; (c) unknown keys survive — Ecto is oracle-only; (d) no `Ecto.Enum` — atomized categories validate as atoms, so a bad enum string that survived `atomize_enum_values` surfaces as a *type* error (`rule == :atom`), never an `in:` error; (e) `Ecto.Type.cast(_, nil)` → `{:ok, nil}`, matching nil ≡ absent (absent keys are skipped by `safe_get_in` before `errors_for` runs); (f) `EctoTypes.type_for/1` must return **fully-qualified** module atoms (`__MODULE__.PosInteger`) — a bare `PosInteger` before its nested `defmodule` would not be alias-expanded and Ecto's runtime dispatch would fail.

**Deliberate exclusions (NOT Ecto-validated)**: `LLMCatalog` (static catalog), `VersionState` (self-validating TOML file), `credentials.toml` (free-form keys), `ProjectConfig`/`genesis.toml` (per-repo, lenient by design), `CustomAgents`/`agents.toml` (own CRUD validation), `RuntimeOpts` (task-opts contract, raises `ArgumentError`). Only the `config.toml` DSL (the 106 `Definitions.schemas/0` entries, including 14 LLM descriptors) is Ecto-validated.

## Direct API Admission and Persistence Boundaries
`EvoGit.Config` lives in this directory's `config.ex`, not in the parent directory.
`Schema.all_schemas/0`, `schemas_by_category/0`, `defaults/0`, and `validate/1` are real public APIs in `schema.ex`; `Schema.effective_model_profiles/1` supplies the runtime's legacy-profile fallback.
The Assistant evaluator admits direct `Config.resolve/0,1` reads and, only in approved tier-2 write calls, `Config.save_user_config/1`, `EvoGit.AgentScheduler.RemoteAPI.reload_config/0` and `EvoGit.AgentScheduler.update_config/1` through explicit exact-MFA lists, never namespace grants.
These calls retain actual arguments and return values rather than facade projections; the full admission and execution contract belongs to `../agent/tools/elixir_eval/CONTEXT.md`.
The permission model protects against accidental self-corruption rather than malicious attackers: read/write remain Dune-interpreted with bounded execution and authorization checks, while separately and explicitly approved sudo is unrestricted native evaluation with full VM authority, not an automatic escalation from write.
`Config.resolve/0,1` and `user_config/0` return unredacted data, including node cookies, model `extra`/`provider_options`, endpoint credentials and arbitrary unknown TOML keys; admitted direct reads are not required to be projected or secret-safe, and output caps do not redact secrets.
`Config.resolve/0,1` reads defaults plus user configuration, not live scheduler runtime overrides.
`Config.config_status/0` returns `missing`, `warnings`, `ok?`, and `validation_errors`, but loads credentials into ReqLLM and may lazily import OAuth credentials into a managed file; its validation errors include original values and messages with inspected values.
`config_status/0` takes `resolved` and `validation_errors` from ONE `EvoGit.Config.Cache.get/0` snapshot value, so the errors it returns are exactly the ones that resolved map was validated with.
There is no process-dictionary validation-error propagation: `resolve/0` is a plain snapshot read and writes nothing anywhere.
The snapshot is a RAM value, not a global/latest-status cache: a later `config_status/0` re-reads the same snapshot, another process cannot overwrite it, and `Schema.validate/1` (once per build) or `save_user_config/1` (validate-first) never rewrite it — only a `Cache` store does.
`config_status/0` does not guarantee a transactionally consistent disk/config-path snapshot across its nested health reads (an in-flight `Cache.reload/1` may swap the snapshot between them).
`:ok?` requires both no missing critical settings and an empty validation-error snapshot; `missing` and `warnings` remain presence/credential diagnostics and do not include validation values or credentials.
`Config.resolve/0` also logs invalid values verbatim, and neither its logging nor `Schema.ValidationError` provides redaction.
Public visibility alone does not grant evaluator access: `user_config/0`, `config_status/0`, `read_toml_file/2,3`, credential helpers and schema APIs remain unlisted.
`Config.read_toml_file/2,3` reads any supplied file path despite `@doc false`, and `Config.credential_key_to_reqllm_key/1` calls `String.to_atom/1` for arbitrary suffixed input.
`Config.save_user_config/1` validates the supplied map then REPLACES the entire config file; it is not a patch or merge API, it reloads the snapshot synchronously, and it performs no scheduler reload or PubSub `"config"` broadcast on its own behalf.
For a targeted persistent change, resolve the full map, update only intended fields and save it in the same approved write call, preserving unrelated keys; saving a resolved map also materializes defaults.
That save uses plain `File.write/2` with no atomic rename, lock, rollback or chmod, drops nil map entries and mirrored flat LLM fields, and reloads the config snapshot only after a successful write.
Avoid concurrent edits because read-modify-save is not atomic and can overwrite another writer's changes.
After a successful save, explicitly call `RemoteAPI.reload_config/0` and inspect its result to apply reloadable scheduler settings; save success does not imply reload success, and boot-only settings still require restart.
`AgentScheduler.update_config/1` is a separate runtime-only mutation, not config persistence; it can be overwritten by a reload or restart.
`Schema.validate/1` walks atom-keyed schema paths, skips missing/nil/non-map intermediates and preserves unknown keys, so string-keyed top-level maps and malformed intermediate sections can bypass validation.
Model-profile validation checks id/model, atom-keyed provider-options container and optional peak/context/auth fields, but does not validate per-profile concurrency or generation-parameter ranges.
`Config.save_credentials/1` merges new credentials into existing data without schema validation, mutates ReqLLM's key store BEFORE the filesystem write, and does not clear previously loaded keys when given empty/nil replacements.
`Config.credentials/0` returns raw secrets and mutates the ReqLLM key store on a snapshot BUILD; this differs from a credential-presence boolean, and neither credential API is admitted directly.
Schema validation is not authorization, and neither approval nor evaluation timeouts roll back committed side effects.
Leaf-specific OAuth assembly, atom creation and catalog side effects are documented in `schema/CONTEXT.md`.

## Config Caching

`EvoGit.Config.Cache` holds ONE RAM-resident config snapshot per config directory in `:persistent_term` under `{EvoGit.Config.Cache, dir}`, shaped `%{dir, user_config, credentials, resolved, validation_errors, generation, fingerprint}`.

- **Reads are pure term lookups**: `Cache.get/0` resolves the directory AT CALL TIME through `EvoGit.Config.config_dir/0` (so the per-process `:config_dir_fun` seam keeps working), and a hit performs zero `File.stat`/`File.read`, no merge and no `Schema.validate/1`.
- **One build, then lookups**: a miss calls `EvoGit.Config.build_snapshot/1` once and stores the result with `generation: 1` and NO broadcast; `build_snapshot/1` is the ONLY reader of `config.toml`/`credentials.toml` and runs the whole pipeline once (`defaults() |> deep_merge(atomize_keys(user_config)) |> atomize_enum_values() |> migrate_llm_models()`, then `Schema.validate/1`), keeping the ReqLLM `put_key/1` credential side effects and the per-error "Config validation error at …: … (got: …)" warnings.
- **Fingerprint-driven reload**: the snapshot fingerprints the raw bytes of both files (`:erlang.phash2({config_bytes, credentials_bytes})`), so `Cache.reload/0,1` rebuilds and compares — unchanged contents return the previous snapshot with no store, no generation bump and no broadcast; a change costs exactly ONE `:persistent_term.put` with `generation + 1` followed by a best-effort `{:config_reloaded, node(), dir, generation}` on PubSub topic `"config"` (skipped when `EvoGit.PubSub` is not running, never raises into the caller).
- **ONE total reload helper**: `Cache.reload_safely/0,1` is the total variant of `reload/0,1` and the ONLY place in the codebase that wraps a snapshot reload in rescue/catch logging (naming the directory) and answers `:error`; `reload/0,1` stays raw, and `Watcher`'s private `refresh/1` delegates to `reload_safely/1`, so the debounced file event, the save event and the fallback share ONE reload implementation.
- **Freshness is event-driven, never polled**, from exactly two event sources — a successful save and a file event on the watched directory — that both converge on the watcher's single refresh handler.
- **Saves refresh synchronously through the watcher event**: `save_user_config/1` and `save_credentials/1` call `EvoGit.Config.Watcher.notify_change(dir)` after their successful write and before returning `:ok`, which runs the SAME refresh as a file event — or the `Cache.reload_safely/1` fallback when no watcher is registered — so the settings page, the Welcome setup and the Assistant `elixir_eval` write tier read fresh values immediately.
- **`EvoGit.Config.Watcher`** is a GenServer started after `Phoenix.PubSub` and before `EvoGit.AgentScheduler` (and NOT started when `Mix.env() == :test`, so it never watches a developer's real config dir) that owns "config changed → refresh snapshot": it watches the config dir through the vendored `file_system` dep and debounces ONE ~150 ms coalesced refresh per burst of `config.toml`/`credentials.toml` create/modify/remove/rename events, its `handle_call({:config_changed, dir})` runs the same refresh for the save event (the explicit requested dir, even when it watches a different one) and replies `:ok`, and an `agents.toml` event calls `EvoGit.CustomAgents.reload/0` instead.
- **Watcher degradation**: a backend that cannot start (no `inotifywait`/`inotify-tools`, watch limits, missing dir) logs ONE warning and the GenServer stays alive unwatched, a stopped worker logs one warning, and saves plus explicit reloads still refresh the snapshot — `notify_change/2` is total and bounded (a `nil`, unregistered, dead or slow watcher falls back to the same guarded refresh and still answers `:ok`, never failing or indefinitely blocking a save), the watcher is a convenience, never a requirement, and never crashes the application; its `dir:`/`name:` options (default the module name, `nil` = unnamed) exist so tests run isolated instances.
- **Explicit reload re-reads disk**: `EvoGit.AgentScheduler.RemoteAPI.reload_config/0` FORCES `EvoGit.Config.Cache.reload()` before `Config.resolve()` + `update_config/1`, so an explicit reload observes current disk content — including a remote/SSH-triggered one.
- **`read_toml_file/3` stays uncached** (`@doc false`): `project_config.ex` (`genesis.toml`), `remote_connections.ex` (`remote_connections.toml`) and `custom_agents.ex` (`agents.toml`) read through it and keep their own freshness rules.
- **Missing vs unparseable**: an absent/unreadable `config.toml`/`credentials.toml` silently yields `%{}` with no warning log; a TOML decode failure logs one warning and also yields `%{}`.
- `config_status/0` takes BOTH `resolved` and `validation_errors` from ONE `Cache.get()` value, and the errors are only recomputed by the next snapshot build.
- `defaults/0` stays uncached — a cheap `deep_put` fold whose three CPU-thread-derived values read `EvoGit.Platform.cpu_threads/0` at call time.

**Snapshot vs scheduler state:**
- The runtime config agents use is the **`AgentScheduler` GenServer state**: `RemoteAPI.get_config/0` reads it, `reload_config/0` forces a snapshot reload and replaces it, and `get_config_status/0` reads the snapshot per call for truthful `:missing`/`:warnings`/`:ok?`.
- `save_user_config/1` refreshes the snapshot but does NOT apply scheduler runtime state — the dashboard (SettingsLive) calls `reload_remote_config` but IGNORES its return, so a reloadable setting can stay unapplied until an explicit reload.
- `RemoteConnections` does NOT auto-create an empty `remote_connections.toml` (unlike the config skeleton) — the file appears only when a target is saved.

## Boot-Time Resolve Cost & Retention

- `resolve/0` and `resolve/1` are `:persistent_term` lookups: the pipeline (defaults + atomized TOML merge → `atomize_enum_values` → `migrate_llm_models` → `Schema.validate/1` over all 106 schemas) runs ONCE per config directory per actual file change, inside `build_snapshot/1`.
- No read on the hot path pays for that pipeline, and no read stats a file — the only remaining per-call cost is resolving the config dir through `EvoGit.Platform.config_dir/1`.
- `EvoGit.Config.Watcher.init/1` primes the snapshot at boot with the RAW `Cache.reload(dir: dir)` (not the total variant; a fingerprint-diffed no-op when `runtime.exs`'s early `resolve/0` already built it), before every CHILD that reads config, so no boot child pays a build on its own stack; in production the very first build happens in the boot/config phase, from `runtime.exs`.
- In the test env the watcher is absent, so the first `Cache.get/0` in a config dir builds the snapshot in the calling process.
- Retention: one snapshot per config dir lives in `:persistent_term` for the BEAM lifetime — the parsed string-keyed TOML maps, the resolved atom-keyed map and the validation errors (a few KB plus the resolved map, still small); `AgentScheduler` independently keeps its selected fields (`model_profiles`, generation params, sandbox/scheduler scalars).
- `PeakHourEngine.init` reads AgentScheduler state (`safe_get_config/2`), never the disk; `SystemSampler` samples that state too.
- ⚠️ The DOMINANT boot cost is not config resolution at all: `AgentScheduler.init` → `Schema.LLM.llm_generation_params/1` → `model_metadata/1` → `ReqLLM.model/1` triggers LLMDB's LAZY packaged-catalog load (`priv/llm_db/snapshot.json`, 11.7 MB, ~10,100 models across ~100+ providers), whose decoded table is retained in `:persistent_term` for the BEAM lifetime (tests measure ~2.5 s for the decode/pricing/index pass). It fires whenever ANY profile carries a `model` — i.e. every configured install; a model-less fresh install pays nothing.
- Benign: config BEAM code is ~220 KB and lazily loaded; the `[lsp]`/search/`LLMCatalog` data are module literals touched only on demand; no schema validation runs at compile time.

## Test Seam — per-process config dir (`:config_dir_fun`)

- `EvoGit.Platform.config_dir/1` consults the app-env seam `:evo_git, :config_dir_fun` at CALL time before the XDG resolution.
- The seam accepts a zero-arity fun or an `{m, f, a}` tuple; the result must be a non-empty binary (garbage falls through to the production default, no `try/rescue`).
- It is **default-inert**: production never sets `:config_dir_fun`, so production paths are byte-identical to the XDG/APPDATA/Library resolution.
- `test/test_helper.exs` installs `{EvoGit.TestSupport.ConfigDir, :resolve, []}` (compiled from `test/support/config_dir.ex`).
- Helpers: `resolve/0` (own process dict → `$callers` pids on the local node → `nil`), `activate/1` (put in the calling process, e.g. from `setup`), `isolate_module!/1` (`setup_all`; unique tmp dir + `on_exit` cleanup, no process dict) and `isolate!/1` (`isolate_module!/1` + `activate/1`).
- `$callers` reaches `GenServer`/`Task`/`Supervisor` children started FROM the test process (OTP 24+ `proc_lib`), NOT boot-time singletons (`AgentScheduler`, `TaskRegistry`, `Store`, `PeakHourEngine`) — a module reading config inside those must stay `async: false`.
- The config snapshot is keyed by config DIRECTORY (`{EvoGit.Config.Cache, dir}`) and resolved through the seam at CALL time, so a unique dir per test is snapshot-safe and a stale snapshot can never leak across dirs.
- `EvoGit.Config.Cache.get(dir)` and `Cache.reload(dir: dir)` address an explicit dir, and `Cache.invalidate/0,1` erases a snapshot (the next `get` rebuilds it at `generation: 1` and re-reads disk) — the seam for a test that changes the files behind the cache's back.
- A test that goes through `save_user_config/1`/`save_credentials/1` needs no extra cache step: both reload the snapshot synchronously.
- The watcher is not started in the test env, so no test needs to account for an asynchronous refresh unless it starts its own unnamed `EvoGit.Config.Watcher` (`name: nil`).

## Web Search Provider Config

Web search (`[tools.search]`) supports providers `[:tavily, :perplexity, :exa, :bing, :brave]`. The **single source of truth** for that list is `EvoGit.Config.Schema.Definitions.search_providers/0` (module attribute `@search_providers`) — do NOT hardcode it elsewhere. It feeds BOTH the schema `in:` validation (`[:tools, :search, :provider]`) and `EvoGit.Config.atomize_enum_values/1`, which atomizes `provider` and each provider section's `search_depth` against `[:basic, :advanced]` via that accessor. `tools_search_enabled?/0` is provider-generic: it resolves the SELECTED provider's own `api_key_credential_key` (with a tavily fallback).

## LLM Shape and Normalization Boundaries
The canonical persisted account inventory is `[[llm.providers]]`, selected by optional `[llm] default_provider_profile`, with one stable id per account and an ordered nested `models` inventory.
Provider profiles share provider/auth/endpoint/concurrency/peak fields, generation defaults and an ordered `reasoning_efforts` inventory; nested model maps may override generation/context/effort settings, and `default_model` plus optional `default_reasoning_effort` choose defaults without inventing an effort from inventory order.
Canonical provider maps and all nested maps use STRING keys, while the surrounding resolved config uses atom schema keys.
`Config.atomize_enum_values/1` explicitly stringifies the full providers subtree through `Schema.ProviderProfiles.Normalize.stringify/1`, preserving malformed entries for validation rather than silently dropping them.
Legacy `[[llm.models]]` and flat `[llm] model` remain accepted and retain their established in-memory normalization and save behavior when no nonempty providers list exists.
`Schema.provider_profiles/1` exposes canonical string-keyed profiles and migrates legacy accounts one-for-one without combining equal provider/model/endpoint accounts or changing ids; this read projection does not rewrite files.
`Schema.model_selections/1` enumerates ordered model/effort inventory without resolving credentials or metadata, and `Schema.resolve_model_spec/2` resolves a nil/default, provider id, or explicit provider/model/effort selection through `Schema.ProviderProfiles`.
Canonical providers are authoritative over stale legacy fields, and config resolution does not materialize their derived `llm.models` or flat model mirrors.
Saving a config with nonempty providers strips legacy `models`, flat generation/model fields and flat auth/provider-options mirrors, retaining the providers and default selector as the sole persisted account inventory.
Key normalization for legacy model maps uses existing atoms only, with `@model_profile_extra_keys` pinning otherwise-unreferenced allowed atoms.
`Schema.validate/1` appends `ProviderProfileValidation.cross_field_errors/1` after descriptor validation, requiring an explicit `llm.default_provider_profile` to match an id in a nonempty configured canonical providers list.
An absent or nil selector is valid; an unknown id reports `%ValidationError{key_path: [:llm, :default_provider_profile], rule: {:in, configured_ids}}`, while blank selectors report `:string` errors and non-string selectors retain the descriptor's single type error.
This cross-field check reads raw atom- or string-keyed provider ids rather than normalized profiles, never hides malformed-row errors, and leaves legacy-only or empty-provider configs' selector validation unchanged.
`ProviderProfileValidation.default_model_errors/4` checks each account's raw `default_model` against its model inventory (`provider_profile_validation.ex:168–184`), accepting absent/nil and matching provider-qualified names, rejecting unknown names with `{:in, ids}` and blank/non-string values with `:string` errors at `[:llm, :providers, index, :default_model]`.
Runtime normalization can repair blank/non-string account defaults and runtime default selection treats a global `false` selector as absent, but raw schema validation still rejects those inputs, so `config_status/0` reports `ok?: false` even if another account supplies a model and credentials.
The model-presence diagnostic enumerates explicit accounts rather than resolving the configured global default, so invalid selectors need not produce `missing` or `warnings`; the returned validation errors, not `missing == []`, are authoritative for that failure.
`Schema.effective_model_profiles/1` delegates to `Schema.LLM.effective_model_profiles/1` for scheduler boot, reload and catalog warm-up, and does not fall back to stale flat settings when a configured canonical inventory has no usable runtime profiles.
Presence and OAuth diagnostics use `Schema.model_profiles/1`'s runtime projection.
For a canonical API-key account's explicit `api_key_env_var`, health checks accept a nonempty environment string first, then a nonempty `Config.credentials/0` string under that exact name, without catalog-key fallback or borrowing another same-provider account's custom key.
OAuth accounts never use this custom API-key status path; the existing global known-key and usable-OAuth health checks remain separate.
The detailed generation/auth/reasoning assembly, selection error contracts and compatibility traps belong to `schema/CONTEXT.md`.

## LLM Model Presence Decision (config_status `:llm_model` gate)

`config_status/0` reports `missing: [:llm_model]` + the warning "LLM model is not configured. Set [llm] model in config.toml." when NO model profile carries a usable model. The predicate runs over `Schema.model_profiles(resolved)` (ALL profiles): a profile counts as configured when its `:model` is a non-empty binary OR a valid map model spec (non-empty map with non-nil `:provider` and a non-empty binary `:id`) — **nil, empty-string and empty-map `%{}` models all fail the gate**. `config_status/0` reads `resolved` and `validation_errors` from ONE `EvoGit.Config.Cache.get()` snapshot in its own process, so its verdict and its reported errors always come from the same snapshot (never another process's state, and never a re-validation of a different map).

**Validation asymmetry**: per-profile `:model` validation (`EctoValidation.validate_model_profile/2`) treats `nil` as an error ("profile must have a 'model' field") but accepts ANY binary — **`""` passes `Schema.validate`** yet still fails the `config_status` gate, so such a profile yields `validation_errors: []` plus `missing: [:llm_model]`. The flat `[:llm, :model]` `:model_spec` validation is equally lax (any binary accepted). `config_status`'s check is the ONLY place empty strings are rejected; a missing `:llm` section / `llm.models = []` / flat nil model produce NO validation error — the `:llm_model` warning is the sole signal, by design.

**Map-model profiles with override keys pass the gate**: a custom-endpoint map model (e.g. `%{provider: :openai_compatible, id: "x", base_url: "..."}` — kept as a map by `normalize_model_map/1` whenever `base_url`/other override keys are present) counts as configured, matching SystemCheck/ReqLLM acceptance.

**Legacy mirror rule (`migrate_llm_models/1`)**: when no canonical providers are configured, the flat `[llm] model` is mirrored ONLY from the FIRST legacy profile; if that profile has no/nil model the flat field stays nil even when later profiles carry valid models, so consumers reading `Config.resolve([:llm, :model])` (flat) rather than `Schema.model_profiles/1` see nil.
A first-profile model of `""` mirrors as `""`; canonical configs do not synthesize a flat mirror.

**Disk shape after save**: when a nonempty providers list is present, `save_user_config/1` strips legacy `llm.models` and flat model/generation/auth/provider-options mirrors before serialization so only the canonical account inventory persists.
For legacy-only configs, the same save path preserves `[[llm.models]]` and strips flat generation/model fields only when that legacy list is nonempty.
`stringify_keys/1` drops nil values at every map level; legacy nil-model profiles therefore round-trip without a model key.

## OAuth / Subscription Auth
Subscription (OAuth) auth spends an existing ChatGPT/Claude **login** instead of a per-token API key; the ONLY credential store is the managed file (the profile's `oauth_file`, default `<config_dir>/auth.json`) — ReqLLM-native JSON keyed by provider OAuth id `"openai-codex"` / `"anthropic"`, entries `type`/`access`/`refresh`/`expires`(ms)/`accountId` — `credentials.toml` never carries OAuth data.
- **Path precedence** (`Schema.LLM.oauth_file_for/1`): `opts[:oauth_file]` (explicit argument) → the profile's `oauth_file` → `EvoGit.Auth.default_oauth_file/0` (`<config_dir>/auth.json`, resolved through `EvoGit.Platform.config_dir/1` so the `:config_dir_fun` seam applies); a leading `~` is expanded and a broken managed-file read degrades to the default. There is NO global `[llm] oauth_file` config key.
- **Catalog auth metadata** (`EvoGit.Config.LLMCatalog`): each provider entry carries `auth_modes` (default `[:api_key]`), `oauth_source`, `provider_atoms` and `credential_key`; accessors `auth_modes/1`, `oauth_source/1`, `oauth_only?/1` (`:api_key not in auth_modes`), `supports_oauth?/1`. `:openai_codex` ("ChatGPT Codex (OAuth)", `oauth_source: :codex_cli`) is OAuth-ONLY; `:anthropic` is `[:api_key, :oauth]` with `oauth_source: :claude_code`; every other provider is API-key only.
- **Which profiles are OAuth** (`Schema.LLM.oauth_profile?/1`): `auth_mode == :oauth`, OR the provider is `oauth_only?` — so `model = "openai_codex:gpt-5.6-terra"` needs no `auth_mode` at all.
- **What reaches the request** (`Schema.LLM.profile_generation_params/1`): an OAuth profile gains `provider_options: [auth_mode: :oauth, oauth_file: <resolved>]`, overridden key-wise by explicit profile `provider_options`; the full three-level precedence lives in `schema/CONTEXT.md`.
- **Lazy import**: Genesis runs no OAuth flow of its own — on first use `EvoGit.Auth.ensure_credentials/2` imports the vendor CLI login (`codex login` → `$CODEX_HOME/auth.json` or `~/.codex/auth.json`; `claude` → `~/.claude/.credentials.json`) into the managed file and `login_instructions/1` carries the one-time guidance; a found-but-unstorable login is `{:error, {:managed_file_unwritable, posix_reason}}` (never `:no_credentials`) and the mtime/atomicity contract is in `auth/CONTEXT.md`.
- **Env fallback**: `CLAUDE_CODE_OAUTH_TOKEN` (then `ANTHROPIC_OAUTH_TOKEN`) is honoured for `:anthropic` when no file credential exists — OAuth without refresh, never written to disk; `:openai_codex` has no env fallback.
- **`known_credential_keys/0` auth-mode filter**: a provider entry contributes its `credential_key` only when `:api_key` is in its `auth_modes`, so an OAuth-only provider can never make `api_key_present?/1` report a configured key; variant keys stay unconditional.
- **Health (`config_status/0`)**: the `:api_key` check passes when `api_key_present?(credentials())`, an API-key account's exact custom `api_key_env_var` resolves from the environment or persisted credentials, OR a configured OAuth profile's credential resolves (`Schema.LLM.oauth_credential_status/1`, which imports first and degrades to "not configured" on a broken file); when it fails AND OAuth profiles exist, the warning names the OAuth providers, their `login_instructions/1` text and the per-profile managed file(s) resolved by `Schema.LLM.oauth_file_for/1` (`"Managed OAuth file: <path>"`, or `"Managed OAuth files: <p1>, <p2>"` when profiles differ; `EvoGit.Auth.default_oauth_file/0` when none resolves), while a config with no OAuth profile keeps the unchanged generic `"No API key found. Add keys to credentials.toml or configure via the settings page."`. When an OAuth profile instead reports `{:error, {:managed_file_unwritable, reason}}` (the login exists but the managed copy cannot be written — read-only home, Nix sandbox), the message is `EvoGit.Auth.managed_file_unwritable_remedy/2`'s text for that profile's resolved path (`Schema.LLM.oauth_file_for/1`) and the misleading "run the vendor login" instructions are omitted (`oauth_failure_detail/2` → `managed_file_failure/1`).
- **Onboarding**: the dashboard's Welcome setup and Settings → LLM provider-profile editor ask an OAuth-capable provider for an auth mode ("API key" vs "Subscription (OAuth)"), skip the question for an OAuth-only provider and never prompt for an API key on the OAuth path — the saved account gets `auth_mode = "oauth"`, while the API-key path writes none and clears a stale one, and `credentials.toml` never carries OAuth data. `EvoGit.SystemCheck.do_llm_test/2` runs `ensure_profile_credentials/1` before its connection test and, for a `{:managed_file_unwritable, reason}` outcome, returns `{:error, "LLM connection test not run — <remedy>"}` WITHOUT issuing a request (`oauth_credential_blocker/1`).

## Constraints
- **No config key caps TOTAL agents / live worktrees / subagent spawn breadth.** The full `Definitions.schemas/0` inventory contains NO `max_agents`/`max_worktrees`/`max_subagents`/breadth key. `[:scheduler, :max_agent_depth]` (default 8) is the ONLY structural limit, and it bounds recursion DEPTH only (`Subagents.validate_subagent_depth/3`: reject when `parent.depth + 1 > state.max_depth`). `spawn_validated_subagents/5` spawns EVERY validated spec via `Dispatch.register_agent/7` — no queue, no spawn cap; each gets a FRESH worktree (`Dispatch.try_dispatch` → `WorktreeManager.create_worktree_for_agent/6`). The ONLY bound is worktree CREATE-pipeline concurrency: WorktreeManager's bounded FIFO admission queue capped at `:max_concurrent_worktree_creation` (app env, default 4 — NOT a config.toml schema key; detail: `agent_scheduler/CONTEXT.md`), which never limits live worktrees/agents. Slot pools gate LLM/tool CALLS (indirectly the rate), not worktree creation; `State`'s `queue` is the resume FIFO for paused schedulers, not a worktree-count queue.
- `save_user_config/1` → `config.toml`; `save_credentials/1` → `credentials.toml`. Both create the config dir if needed.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- **`Config.resolve/0` and `Schema.validate/1` never read model metadata or the LLMDB catalog** — they are pure map work (merge → atomize → migrate → validate); the ONLY catalog reach in this subtree is `Schema.LLM.model_metadata/1` (see `schema/CONTEXT.md` → "Model metadata seam"), so a memory or latency surprise attributed to config resolution is never catalog-related.
- Config dir follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads use `case File.read/1` (non-crashing) with explicit `with`/`case` handling — no `try/rescue`.
- All config access should go through `EvoGit.Config.resolve/1`.
- **Model format**: `"provider:model"` string (preferred; resolves through LLMDB for cost tracking) OR map spec `%{provider: atom, id: string, base_url: string, extra: %{...}}` (ReqLLM-native). Map specs are normalized at resolve time (`normalize_model_map/1` in `atomize_enum_values/1`): simple models (only `:provider`+`:id`) → `"provider:id"` strings; models with override keys (`:base_url`, `:extra`) stay as atomized maps. Both are LLMDB-compatible; string specs pass through as-is. `[[llm.models]]` supports multiple endpoints per provider+model via per-profile `base_url`. The provider atom determines which API key env var is used.
- `config_status/0` checks: LLM model presence + at least one API key. GitHub username **optional** — a missing username does NOT appear in `:missing`/`:warnings` nor make `:ok?` false.
- **Crash resilience (untrusted user config boundary)**: the `resolve/0` → `config_status()` pipeline MUST NEVER raise on user-provided content (incl. valid TOML with wrong value types, e.g. `llm = "string"`). `deep_merge/2` discards type-mismatched values (keeping defaults); `migrate_llm_models/1`, `atomize_enum_values/1`, `Schema.model_profiles/1` and `Schema.validate/1` guard non-map structures; `Schema.validate/1` uses `safe_get_in` (not `get_in`) to avoid Access-behaviour crashes. Bad config → `validation_errors`, never a crash — the user must always boot the app and reach the settings page.
- **Enum atomization gap for NEW top-level sections** — see "Adding a New Config Category" above (clause list + why atomization stays PRE-Ecto); the `:string` workaround is UI-only, since the dashboard `SettingCard` renders `:string` as free text unless special-cased (`reasoning_effort` precedent).
- **Shared `@doc false` helpers (anti-duplication homes)**: `EvoGit.Config.Schema.safe_get_in/2` — safe nested key-path lookup that NEVER raises on non-map intermediates (unlike `get_in`/Access); use it for any nested schema-key read (`resolve/1`, `Schema.validate`, `tools_search_enabled?` already do). `EvoGit.Config.ensure_trailing_newline/1` — guarantees TOML content ends with a trailing newline before `File.write` (used by `save_credentials/1` and `version_state.ex`). Both are public and shared across `config.ex`/`schema.ex`/`version_state.ex` — reuse rather than re-implement.
