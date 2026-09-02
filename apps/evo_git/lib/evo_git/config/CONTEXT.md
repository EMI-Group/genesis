# Config — Unified Configuration Resolver

## Intent
`EvoGit.Config` — single source of truth for non-project configuration: merges application defaults with user config (`~/.config/genesis/config.toml`), loads API keys from credentials into ReqLLM's key store, persists user config changes, and diagnoses configuration completeness.

## Routing Table
- `./schema/` → Config schema definitions — pure data describing config keys, types, defaults, and validation rules

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Merged config map (defaults + user config). Runtime overrides live in `AgentScheduler` state, not here. |
| `resolve/1` | Resolved value for a key path (atom or list of atoms) |
| `user_config/0` | Parsed `config.toml`, or `%{}` if not found. Cached in `:persistent_term` with `File.stat` mtime+size validation (see "Config Caching"). |
| `save_user_config/1` | Persists config map to `config.toml` (creates config dir). Invalidates cache on success. `:ok \| {:error, reason}` |
| `save_credentials/1` | Merges/persists API key map to `credentials.toml`; sets keys via `ReqLLM.put_key` for immediate in-process use. Invalidates cache. `:ok \| {:error, reason}` |
| `config_status/0` | Diagnostic map `:missing`/`:warnings`/`:ok?`. Checks LLM model presence + API key presence. GitHub username optional — NOT checked (does not affect `:ok?`/`:missing`/`:warnings`). |
| `credentials/0` | Reads `credentials.toml`, loads each key into ReqLLM's key store, returns parsed map. Cached (put_key runs only on cache miss). |
| `defaults/0` | Built-in defaults (scheduler concurrency/retry settings, empty llm/user maps, sandbox mode) |
| `config_path/0` | Full path to `config.toml` |
| `config_dir/0` | Platform config dir (XDG/macos/windows). Delegates to `EvoGit.Platform.config_dir("genesis")`. |
| `credentials_path/0` | Full path to `credentials.toml` |

### `EvoGit.Config.LLMCatalog` (provider/model shortcuts)
| Function | Description |
|----------|-------------|
| `providers/0` | Predefined providers (Anthropic, OpenAI, Google, DeepSeek, ZAI, Alibaba) with models |
| `provider_models/1` | Model shortcuts for a provider atom |
| `resolve_model/2` | `{provider_atom, model_input}` → `"provider:model"` string (backward-compat) |
| `resolve_model_spec/3` | Map analog: `%{provider: atom, id: string}` + optional `base_url`/`extra`. Opts `:base_url`, `:variant`, `:extra`. |
| `requires_base_url?/1` | Provider requires custom `base_url` (flag; default `false`). `:openai_compatible` → `true`. |
| `find_provider/1` | Provider entry by atom (checks `provider_atoms`) |
| `unknown_provider_help/0` | Guidance text (llmdb.xyz + ReqLLM docs links) |
| `known_credential_keys/0` | All unique credential key names from the catalog |

### `EvoGit.Config.VersionState` (upgrade detection)
Tracks last-seen Genesis version in `version_state.toml` (config dir); defaults to `"0.8.0"` when no file exists.
| Function | Description |
|----------|-------------|
| `get_version/0` | Recorded version string (default `"0.8.0"` if absent/unparseable/missing key) |
| `current_version/0` | Runtime version via `Application.spec(:evo_git, :vsn) \|> to_string()` |
| `save_version/1` | Persists version string. `:ok \| {:error, reason}`. Also `save_version/0` (persists `current_version/0`). |
| `upgraded?/0` | `true` if recorded version ≠ current version |
| `record_current_version/0` | Persists `current_version/0`. Call after showing update log. |

### `EvoGit.Platform` (cross-platform utilities)
| Function | Description |
|----------|-------------|
| `os/0` | `:linux`, `:macos`, `:windows`, or `:unknown` |
| `config_dir/1` | Config dir (XDG/Linux, Application Support/macOS, APPDATA/Windows) |
| `data_dir/1` | Platform data dir |
| `shell/0` | Effective shell executable — honors the `[tools] shell` config override; defaults `"bash"` (Linux/macOS) / `"powershell"` (Windows) |
| `shell_args/1` | `["-c", cmd]` (POSIX shells) or PowerShell `-EncodedCommand` args (PowerShell executables, via `EvoGit.Powershell`) — chosen from the effective shell |
| `systemd_available?/0` | Linux + systemd |
| `nix_available?/0` | `nix` binary in PATH (Linux and macOS) |

### `EvoGit.ProjectConfig` (per-repo genesis.toml)
| Function | Description |
|----------|-------------|
| `read/1` | Parses `genesis.toml` from repo root |
| `worktree_script/1` | Worktree init script for current OS (backward-compat wrapper) |
| `worktree_script/2` | Worktree init script for given OS, with variant resolution |
| `write_worktree_script/2` | Writes/merges worktree init script into `genesis.toml` `[worktree].script`; preserves existing sections/keys |
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
- **Schema**: `[foreign_repos.<id>]` tables with `path` (REQUIRED — missing → entry dropped + `Logger.warning` "Failed to parse foreign_repos", `ProjectConfig.build_foreign_repo/2` project_config.ex:302-311) and `description` (optional). The TOML table key IS the id. **The key is `description`, NOT `name`** — a `name` key is silently ignored (only `"description"` is read, project_config.ex:305; the `ForeignRepo` struct field is `:description`). No other keys (no `enabled`/opt-in flag) — every entry is always loaded.
- **Committed to git**: `genesis.toml` is NOT git-ignored — the `.gitignore` Genesis auto-writes into new repos contains only `/.genesis` (runtime.ex:22-24); root `.gitignore` doesn't cover it either. Genesis Mode B auto-creates it via `ProjectConfig.write_worktree_script/2` (genesis.ex:101,259). So absolute paths in `[foreign_repos]` are committed and shared across machines — wrong on any other computer.
- **Path handling**: no validation requires absolute paths, but they're semantically required — `ForeignRepo.new/3` only does `EvoGit.Platform.safe_expand/1` (foreign_repo.ex:65): `~` expands to home, RELATIVE paths expand against the PROCESS CWD (CLI/dashboard cwd, NOT the repo root), and there is NO `$VAR`/`${VAR}` env expansion anywhere in `config.ex` or `project_config.ex`. No existence check at load or task start — a path missing on the current machine flows into the agent's context table and only fails at delegation time (`build_subagent_phylo_node` hard-matches `{:ok, foreign_head} = Git.rev_parse(target_repo_root)` at subagent_processing.ex:625 → MatchError crash on first delegation when no tracked commit exists).
- **`-R` CLI merge**: `Helpers.merge_foreign_repos/2` (runtime/helpers.ex:132-138) normalizes both lists via `ForeignRepo.normalize/1` then `Map.merge(toml_map, cli_map)` — CLI wins per-id, unparseable dropped; CLI can OVERRIDE but never REMOVE a genesis.toml entry. Dashboard: per-project in-memory list (loaded at project open, add/remove only in socket assigns — never persisted back to genesis.toml) passed per-task via `runtime_opts[:foreign_repos]` (task_registry/runtime_opts.ex:40-45). `ResumeContext` does NOT carry `:foreign_repos` on resume_from tasks (only `MergeContext` does, merge_context.ex:54-64) — resumed tasks re-get only genesis.toml repos.

### Worktree Init Script Environment Variables
| Variable | Description |
|----------|-------------|
| `SOURCE_REPO_PATH` | Main repository checkout path |
| `TARGET_WORKTREE_PATH` | Newly created worktree path |
| `SOURCE_WORKTREE_PATH` | Parent agent's worktree path (`SOURCE_REPO_PATH` for top-level agents) |

### Configuration Levels (priority low → high)
1. **Application defaults** — `defaults/0` (no model, no username)
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`
3. **Runtime overrides** — `AgentScheduler` GenServer state via `handle_call({:update_config, opts})`; set by CLI flags (`-c`, `-m`, `--retries`) or dashboard settings.

### config.toml Structure
```toml
[scheduler]
default_llm_max_concurrency = 3   # Per-LLM concurrency when a model profile has none
max_tool_concurrency = 2          # Max concurrent tool executions
agent_max_retries = 3             # Crash-retry limit per agent
max_agent_depth = 8               # Max subagent recursion depth
max_retries = 15                  # Max total LLM API retries

[llm]
model = "provider:model"          # REQUIRED, e.g. "anthropic:claude-sonnet-4-20250514"
compression_threshold_tokens = 100_000  # Token limit before context compression

[user]
github_username = "..."           # For PR creation

[sandbox]
mode = "auto"                     # "auto" | "enabled" | "disabled"
backend = "auto"                  # "auto" | "systemd" | "bwrap"
write_paths = []                  # Optional; unset/nil = platform defaults, set (incl. []) = REPLACES built-in list

[nix]
enabled = false                   # Run tool calls inside a cached Nix dev environment (requires flake.nix in config dir)
flake_output = nil                # Optional, e.g. "devShells.x86_64-linux.default"
```

**`[[llm.models]]` profile fields**: `id` (required), `model` (required), `concurrency` (per-profile LLM concurrency), plus optional `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days`:
```toml
[[llm.models]]
id = "glm"
concurrency = 4        # normal (off-peak) concurrency
peak_concurrency = 2   # optional — effective concurrency during peak windows (0 = hard pause)
peak_hours = [         # optional — daily windows (local wall-clock unless timezone set)
  { start = "09:00", end = "12:00" },
  { start = "14:00", end = "18:00" }
]
timezone = "Asia/Shanghai"  # optional — IANA tz for this profile's peak windows
off_peak_days = []     # optional — days the profile is off-peak the ENTIRE day (see below)
```

A DeepSeek weekends-off-peak example — off-peak all day Saturday/Sunday, peak windows on weekdays only:
```toml
[[llm.models]]
id = "deepseek"
concurrency = 4
peak_concurrency = 0        # hard pause inside weekday peak windows
peak_hours = [              # applies ONLY on weekdays (mon-fri) — see `days`
  { start = "09:00", end = "12:00", days = ["mon", "tue", "wed", "thu", "fri"] },
  { start = "14:00", end = "18:00", days = "weekdays" }   # keyword = mon-fri
]
off_peak_days = ["sat", "sun"]   # entire weekend: normal concurrency 24/7
```

- `peak_concurrency` — NON-NEGATIVE integer when present (`0` = hard pause: zero LLM slots during peak, never raised by the `default_llm_max_concurrency` floor; negatives/floats/strings → validation error at `[:llm, :models, <idx>, :peak_concurrency]`); absent → off-peak `concurrency` always applies.
- `peak_hours` — list of maps with `start`/`end` written as `"HH:MM"` 24h strings OR integer minutes of day (0..1439; both values of one window must use the same representation), atom- or string-keyed (TOML may yield string keys). Half-open `[start, end)`; `start > end` = overnight wrap; absent/`[]`/invalid → disabled (normal `concurrency` 24/7). `peak_hours` without `peak_concurrency` → legal no-op. `EvoGit.PeakHours.parse_window/1`+`validate_windows/1` are the single parse/validate path — they accept BOTH representations uniformly, so profiles whose `peak_hours` arrive as canonical integer windows (e.g. programmatic/TOML `start = 540`) still get correct engine peak-exemption and transition wakeups.
- `timezone` — optional IANA name (e.g. `"Asia/Shanghai"`): when present, all peak computations for that profile (in-peak checks + next-transition wakeups) use that tz wall clock, DST-aware; absent/empty/nil → server local wall clock. Validated by `EvoGit.PeakHours.validate_timezone/1` (single source of truth): nil/"" valid; unknown IANA name / no tz database → error at `[:llm, :models, <idx>, :timezone]`. Requires tz database at boot: `Calendar.put_time_zone_database(Tz.TimeZoneDatabase)` in `EvoGit.Application.start/2` (`tz ~> 0.28`; IANA data pre-compiled, no auto-update).
- `off_peak_days` — optional list of days (atom- or string-keyed map tolerated) on which the profile is off-peak the **ENTIRE day**: normal `concurrency` 24/7, every `peak_hours` window suppressed, `peak_concurrency` (incl. hard-pause `0`) never applies. **Precedence: `off_peak_days` wins over window `days`.** Absent/`[]` → disabled. Vocabulary: day identifiers `"mon"|"tue"|"wed"|"thu"|"fri"|"sat"|"sun"` (canonical 3-letter lowercase; case-insensitive input) + keywords `"weekdays"` (= mon-fri) and `"weekends"` (= sat-sun). Validated by `EvoGit.PeakHours.validate_days/1` (single source of truth — do NOT re-implement the day vocabulary); a bad value → `%ValidationError{}` at `[:llm, :models, <idx>, :off_peak_days]`.
- **Window `days`** — optional key on each `peak_hours` window (same vocabulary as `off_peak_days`): the time window applies ONLY on the listed days; absent → every day (fully backward compatible). A bad window `days` value → `%ValidationError{}` at `[:llm, :models, <idx>, :peak_hours, <window_idx>, :days]` (falling back to bare `[:llm, :models, <idx>, :peak_hours]` when the window can't be located). Validation delegates to `EvoGit.PeakHours` — the schema does NOT re-implement day parsing.
- **Validation ownership**: window parse/format/overlap/days checks delegate to `EvoGit.PeakHours.validate_windows/1` (single source of truth — schema does NOT re-implement); `off_peak_days` delegates to `EvoGit.PeakHours.validate_days/1`. `Schema.validate/1` reports `%ValidationError{}` at `[:llm, :models, <idx>, :peak_hours]` (non-list) or `[:llm, :models, <idx>, :peak_hours, <window_idx>]` (invalid entry; overlap error at the later window's index), plus `[:llm, :models, <idx>, :off_peak_days]` and `[:llm, :models, <idx>, :peak_hours, <window_idx>, :days]` for day-vocabulary errors.
- Peak-hour fields (incl. `timezone`, `off_peak_days`, window `days`) survive resolution (`deep_merge` → `atomize_enum_values` → `migrate_llm_models` → `Schema.validate`) untouched — profile keys never stripped — reaching `state.model_profiles`, read via `get_config(:model_profiles)`.

**`[sandbox] backend`**: `:atom` schema key, default `:auto`, validation `[in: [:auto, :systemd, :bwrap]]`. `:auto` tries systemd-run → bwrap → no sandbox (macOS always uses sandbox-exec; bwrap is Linux-only). `:systemd` forces systemd-run (no sandbox if systemd unavailable). `:bwrap` forces bubblewrap — filesystem isolation only, no resource limits; falls back to no sandbox if `bwrap` unavailable. **`[sandbox.resources]`/`[sandbox.process]` are systemd-only, ignored with bwrap.** String values atomized by `atomize_enum_values/1` before `Schema.validate`.

**`[sandbox] write_paths`**: `:list_of_strings` schema key, default `nil`. nil → sandbox backends use platform-default writable paths; set (incl. `[]`) → REPLACES the built-in list (`[]` disables those writable paths entirely). Non-list/non-string-list → validation error (never crash). Consumed by `EvoGit.Sandbox.Linux.args/4` + `EvoGit.Sandbox.MacOS.generate_profile/2` via `EvoGit.Config.resolve([:sandbox, :write_paths])`: nil → default cache-dir list; set → replaces built-in cache-dir list only; `~`-prefixed entries expand to `System.user_home!()`, absolute as-is, relative joined to `$HOME`. Structural paths (cwd, tmp, nix store, repo `.git`) always appended; deny lists never affected. Details: `sandbox/CONTEXT.md`.

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
Keys loaded into ReqLLM's in-process key store on load. Only one key needed (matching the LLM model's provider).

## Adding a New Config Category / Schema (round-trip contract)

All schemas are defined in ONE flat list — `EvoGit.Config.Schema.Definitions.schemas/0` (`config/schema/definitions.ex`, ~949 lines; NOT per-category modules). A schema is a plain map with 7 keys (`key_path`/`type`/`default`/`validation`/`category`/`sub_category`/`description`) — there is NO `%Schema{}` struct. `schemas_by_category/0` = `Enum.group_by(& &1.category)`; per-category order = definition order.

Adding a NEW top-level category is additive for: enumeration (just append a schema map), `Schema.validate/1` (only checks defined keys; absent keys and nil values pass; unknown keys never rejected), `defaults/0` (derived automatically from each schema's `:default` via `deep_put` — no separate defaults map), and save-side serialization (`stringify_keys` + `TomlElixir.encode` write any map; atom VALUES encode as quoted TOML strings, e.g. `:blue` → `accent = "blue"`; nil values are dropped).

**The one non-additive gap is the READ/resolve path**: string enum values coming back from TOML are atomized ONLY by `atomize_enum_values/1` (config.ex:182-275), which has HARDCODED per-category clauses for `:sandbox` (`:mode`/`:backend`), `:git` (`:cow_worktree_creation`), `:llm` (model normalization), and `:tools` (search provider + per-provider `search_depth`, via `search_providers/0`). A NEW `:atom`-enum key (e.g. `[appearance] accent = "blue"`) needs a matching clause there (or must be typed `:string` + atomized at the consumption point, like `[:llm, :reasoning_effort]`) — otherwise every `resolve/0` logs a validation warning (`must be an atom, got "blue"`) and `config_status/0` reports it (non-fatal; the value just stays a string). The dashboard save path is unaffected: `SettingsUtils.parse_atom/2` (evo_dash) converts `:atom` form values against the schema `validation[:in]` whitelist BEFORE `Schema.validate`, so saves succeed and round-trip through TOML as quoted strings — the string-to-atom conversion on read is the only place that needs the new clause.

Dashboard-side requirements for a new schema-driven category (evo_dash, not core): `category_display_name/1`, `category_icon/1`, `category_description/1` clauses in `EvoDashWeb.SettingsComponents.CategoryMetadata` (no catch-all — missing clause = FunctionClauseError in the sidebar/header), and an entry in that module's `sort_categories/1` order list (missing = sorts last). `:agents`/`:remote_connections` are NOT core categories — the dashboard injects them as empty-schema pseudo-categories (`Map.put(schemas_by_category, :remote_connections, [])` / `:agents` at settings_live.ex:677-678) rendered by dedicated inline UI branches.

## Adding a New Config Category / Schema (round-trip contract)

All schemas are defined in ONE flat list — `EvoGit.Config.Schema.Definitions.schemas/0` (`config/schema/definitions.ex`, ~949 lines; NOT per-category modules). A schema is a plain map with 7 keys (`key_path`/`type`/`default`/`validation`/`category`/`sub_category`/`description`) — there is NO `%Schema{}` struct. `schemas_by_category/0` = `Enum.group_by(& &1.category)`; per-category order = definition order.

Adding a NEW top-level category is additive for: enumeration (just append a schema map), `Schema.validate/1` (only checks defined keys; absent keys and nil values pass; unknown keys never rejected), `defaults/0` (derived automatically from each schema's `:default` via `deep_put` — no separate defaults map), and save-side serialization (`stringify_keys` + `TomlElixir.encode` write any map; atom VALUES encode as quoted TOML strings, e.g. `:blue` → `accent = "blue"`; nil values are dropped).

**The one non-additive gap is the READ/resolve path**: string enum values coming back from TOML are atomized ONLY by `atomize_enum_values/1` (config.ex:182-275), which has HARDCODED per-category clauses for `:sandbox` (`:mode`/`:backend`), `:git` (`:cow_worktree_creation`), `:llm` (model normalization), and `:tools` (search provider + per-provider `search_depth`, via `search_providers/0`). A NEW `:atom`-enum key (e.g. `[appearance] accent = "blue"`) needs a matching clause there (or must be typed `:string` + atomized at the consumption point, like `[:llm, :reasoning_effort]`) — otherwise every `resolve/0` logs a validation warning (`must be an atom, got "blue"`) and `config_status/0` reports it (non-fatal; the value just stays a string). The dashboard save path is unaffected: `SettingsUtils.parse_atom/2` (evo_dash) converts `:atom` form values against the schema `validation[:in]` whitelist BEFORE `Schema.validate`, so saves succeed and round-trip through TOML as quoted strings — the string-to-atom conversion on read is the only place that needs the new clause.

Dashboard-side requirements for a new schema-driven category (evo_dash, not core): `category_display_name/1`, `category_icon/1`, `category_description/1` clauses in `EvoDashWeb.SettingsComponents.CategoryMetadata` (no catch-all — missing clause = FunctionClauseError in the sidebar/header), and an entry in that module's `sort_categories/1` order list (missing = sorts last). `:agents`/`:remote_connections` are NOT core categories — the dashboard injects them as empty-schema pseudo-categories (`Map.put(schemas_by_category, :remote_connections, [])` / `:agents` at settings_live.ex:677-678) rendered by dedicated inline UI branches.

## Config Caching

`user_config/0` and `credentials/0` cache **parsed TOML maps** in `:persistent_term` keyed by file path, storing `{mtime, size, parsed_map}` (private `cached_file_read/2`, config.ex ~line 920).

- Every call runs `File.stat(path)`: matching mtime AND size → cached map; else read + TOML-decode + store. `{:error, _}` (missing/unreadable) → `%{}`, no warning log.
- **Per-path keys** (`{EvoGit.Config, :file_cache, path}`): tests flipping `XDG_CONFIG_HOME`/`APPDATA` resolve different paths → no staleness; stale old-path entries linger harmlessly.
- **Explicit invalidation**: `save_user_config/1`/`save_credentials/1` erase their path's entry after successful `File.write` (covers coarse-mtime filesystems + same-second same-size rewrites).
- **External-edit freshness**: external changes to `config.toml`/`credentials.toml` are picked up by the mtime+size check on next call — this is what makes `RemoteAPI.reload_config/0` → `Config.resolve()` observe fresh disk content.
- **Parse-failure edge**: on read/decode failure `read_toml_file/3` logs a warning and returns the default; that result IS cached with the current stat, so the warning isn't re-emitted until the file changes.
- **`credentials/0` shares the mechanism** (separate path key): cache stores the post-`put_key` result, so `ReqLLM.put_key` side effects run only on an actual file read (cache miss); `save_credentials/1` also sets them explicitly.

**NOT cached:**
- **The `resolve/0` pipeline** (deep_merge → atomize_enum_values → migrate_llm_models → Schema.validate) runs on EVERY call — it has a side effect: `Process.put(:evo_git_config_validation_errors, ...)` (config.ex ~153), read by `config_status/0` from the **calling process's** dict (config.ex ~634). Caching would break validation-error propagation.
- `defaults/0` — pure, cheap.
- `read_toml_file/3` itself (`@doc false`) — `project_config.ex`/`remote_connections.ex` use it for `genesis.toml`/`remote_connections.toml`, which must stay fresh. The cache lives only inside `user_config/0`/`credentials/0`.

`config_status/0` truthfulness: calls `resolve()` + `credentials()` per invocation; the cache only serves validated (mtime+size-matched) content, so missing/warning lists reflect current on-disk state.

Documented limitation: a same-second + same-size external rewrite on coarse-mtime filesystems may be missed (theoretical — modern ext4/APFS/NTFS have ns granularity).

**Two-level caching — disk cache vs scheduler state:**
- The ACTUAL runtime config cache is the **AgentScheduler GenServer state**: `RemoteAPI.get_config/0` reads the cached scheduler state (resolved at boot / last reload); `reload_config/0` re-reads disk via `Config.resolve()` (stat-validated) and replaces the scheduler state; `get_config_status/0` re-reads disk per call to report `:missing`/`:warnings`/`:ok?` truthfully.
- `save_user_config/1` does NOT auto-reload the scheduler state — after saving, the dashboard (SettingsLive) calls `reload_remote_config` but IGNORES its return → a silent stale-config window until a manual reload.
- `RemoteConnections` does NOT auto-create an empty `remote_connections.toml` (unlike the config skeleton behavior) — the file appears only when a target is actually saved.

## Web Search Provider Config

Web search (`[tools.search]`) supports providers `[:tavily, :perplexity, :exa, :bing, :brave]`. The **single source of truth** for the provider list is `EvoGit.Config.Schema.Definitions.search_providers/0` (module attribute `@search_providers` in `schema/definitions.ex`) — do NOT hardcode the list elsewhere. It is used by BOTH the schema `in:` validation (`[:tools, :search, :provider]`) and `EvoGit.Config.atomize_enum_values/1`, which atomizes the `provider` value and each provider section's `search_depth` against `[:basic, :advanced]` generically via that accessor. `tools_search_enabled?/0` is provider-generic: it resolves the SELECTED provider's own `api_key_credential_key` (with a tavily fallback) — no per-provider branching needed.

## Constraints
- `save_user_config/1` → `config.toml`; `save_credentials/1` → `credentials.toml`. Both create the config dir if needed.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- Config dir follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads use `case File.read/1` (non-crashing) with explicit `with`/`case` handling — no `try/rescue`.
- All config access should go through `EvoGit.Config.resolve/1`.
- **Model format**: `"provider:model"` string (preferred; resolves through LLMDB for cost tracking) OR map spec `%{provider: atom, id: string, base_url: string, extra: %{...}}` (ReqLLM-native). Map specs normalized at resolve time (`normalize_model_map/1` in `atomize_enum_values/1`): simple models (only `:provider`+`:id`) → `"provider:id"` strings; models with override keys (`:base_url`, `:extra`) stay as atomized maps. Both are LLMDB-compatible; string specs pass through as-is. `[[llm.models]]` supports multiple endpoints per provider+model via per-profile `base_url`. The provider atom determines which API key env var is used.
- `config_status/0` checks: LLM model presence + at least one API key. GitHub username **optional** — a missing username does NOT appear in `:missing`/`:warnings` nor make `:ok?` false.
- **Crash resilience (untrusted user config boundary)**: the `resolve/0` → `config_status()` pipeline MUST NEVER raise on any user-provided content (incl. valid TOML with wrong value types, e.g. `llm = "string"`). `deep_merge/2` discards type-mismatched values (keeping defaults); `migrate_llm_models/1`, `atomize_enum_values/1`, `Schema.model_profiles/1`, `Schema.validate/1` guard non-map structures; `Schema.validate/1` uses `safe_get_in` (not `get_in`) to avoid Access-behaviour crashes. Bad config → `validation_errors`, never a crash — the user must always boot the app and reach the settings page.
- **Enum atomization gap for NEW top-level sections**: `atomize_enum_values/1` (config.ex:182-275) is a MANUAL per-category reduce with clauses ONLY for `:sandbox` (`mode`/`backend`), `:git`, `:llm`, `:tools`. TOML has no atoms — enum values round-trip as STRINGS. A new top-level category whose key has `type: :atom` therefore needs a new clause in `atomize_enum_values/1`; without it the raw string fails the `:atom` type check in `Schema.validate` and lands in validation errors. Keys added to an EXISTING atomized category (e.g. `:sandbox`) are covered by its existing clause only if that clause atomizes the whole category map — check the clause shape. Simplest path avoiding the gap: `type: :string` + `validation: [in: [...]]` (schema validates strings natively via `rule_errors/3`); down side is UI-only (the dashboard `SettingCard` renders `:string` as free text unless special-cased — see `apps/evo_dash` setting_card.ex `reasoning_effort` precedent).
