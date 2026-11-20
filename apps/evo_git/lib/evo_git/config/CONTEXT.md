# Config — Unified Configuration Resolver

## Intent
`EvoGit.Config` — single source of truth for non-project configuration: merges built-in defaults with user config (`~/.config/genesis/config.toml`), loads API keys from `credentials.toml` into ReqLLM's key store, persists user config changes, and diagnoses configuration completeness.
Reads are served from ONE RAM snapshot per config directory (`EvoGit.Config.Cache`), refreshed only by a config-changed event raised by a save or by `EvoGit.Config.Watcher`'s file watch — never by a per-call file stat.

## Routing Table
- `./schema/` → config schema definitions (pure data: keys, types, defaults, validation) + provider/model generation-parameter extraction (`schema/CONTEXT.md`)
- `./schema/reasoning_effort.ex` → `EvoGit.Config.Schema.ReasoningEffort`: the ONE reasoning-effort ladder (`levels/0`, `options/0`, `allowed?/1`, `canonical/1`, `convert/1`), re-exported by `EvoGit.Config.Schema.LLM` as `reasoning_efforts/0` / `reasoning_effort_options/0` / `allowed?/1` / `canonical_reasoning_effort/1` / `convert_reasoning_effort/1`; every effort read, schema enum, selection rule and wire alias is built on it.
- `./keys.ex` → `EvoGit.Config.Keys`: the ONE tolerant key reader (`fetch/2`, `get/2,3` over atom- OR string-keyed maps, presence-based, never interning an atom) and the ONE recursive string-key transform (`stringify/2`, policies `:drop_nils` / `:model_tuples` / `:keyword_lists`); every tolerant read and string-key conversion in the config subtree delegates here (`Normalization.get_key/2`, `LLM`'s profile reads, `ProviderProfiles.Normalize.stringify/1`, `Config`'s save-side stringification and `LLMConstraints`).

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Merged config map (defaults + user config) from the RAM snapshot — a `:persistent_term` lookup with no file I/O and no validation (see "Config Caching"). Runtime overrides live in `AgentScheduler` state. |
| `resolve/1` | Value at an atom key or atom list from the same snapshot; a MISSING path answers the schema default (possibly `nil`) and never an error. |
| `user_config/0` | Parsed `config.toml` from the RAM snapshot, or `%{}` if absent/unparseable; zero `File.stat`/`File.read` per call. |
| `save_user_config/1` | Validates, then REPLACES `config.toml` through `persist_user_config/1` (creates the config dir) and raises `Watcher.notify_change/1`, so the snapshot refreshes synchronously. `:ok \| {:error, reason}` (`reason` = `[ValidationError]` or a filesystem term). |
| `save_credentials/1` | MERGES into `credentials.toml` with a SHALLOW per-key `Map.merge/2` (a flat `ENV_VAR_NAME = "value"` table: a new value replaces the same key, unknown keys are preserved, a `nil`/`""` value is written rather than deleted); sets keys via `ReqLLM.put_key` BEFORE the filesystem write, then `Watcher.notify_change/1`. `:ok \| {:error, reason}` |
| `config_status/0` | `%{missing, warnings, ok?, validation_errors}`: `:llm_model` + `:api_key` (plus `:search_api_key` when search is enabled but unconfigured) checks; `resolved` and `validation_errors` come from ONE `Cache.get/0` snapshot value; the `:api_key` check is OAuth-aware; GitHub username is optional and NOT checked. |
| `credentials/0` | Credentials map from the RAM snapshot; `ReqLLM.put_key` side effects run only on a snapshot BUILD, never on a hit. |
| `defaults/0` | Built-in defaults — `Schema.defaults/0`, a `deep_put` fold over every descriptor's `:default`; three values are CPU-thread-derived (see Configuration Levels). |
| `list_settings/0` | `Settings.list_settings/0` → `Schema.all_schemas/0` |
| `show/0,1` / `update/1` | Settings facade (below). |
| `config_path/0` / `config_dir/0` / `credentials_path/0` | `config.toml` / `EvoGit.Platform.config_dir("genesis")` / `credentials.toml` |
| `api_key_present?/1` | `true` when any catalog credential key is in ReqLLM's key store or is a non-empty value in the given credentials map. |
| `tools_search_enabled?/0` | Provider-generic `[tools.search]` gate (see "Web Search Provider Config"). |
| `lsp_enabled?/0` | SINGLE gate for offering the `lsp` tool (see `[lsp]` below): `true` only when the resolved `[:lsp]` section is a map whose `:enabled` is `true`/`"true"` AND whose `:command` is a non-blank binary. Never raises (nil/non-map section, other enabled values, nil/non-binary/blank command → `false`). |
| `read_toml_file/2,3` / `ensure_trailing_newline/1` | `@doc false` shared helpers (see Constraints). |

### Settings facade (`EvoGit.Config` → `settings.ex`)

`list_settings/0` returns `Schema.all_schemas/0` unchanged: ordered descriptors with atom `key_path`, `type`, `default`, `validation`, `category`, `sub_category` and `description`.
`show/0` IS `resolve/0` (`EvoGit.Config.show/0` and `EvoGit.Config.Settings.show/0` are one-line delegations): the snapshot's resolved defaults plus persisted config, never live scheduler overrides or the separate credentials map.
`show/1` accepts an atom, dotted string or nonempty list of atom/string path segments, returns the value directly (including section maps or nil), and traverses existing map keys by comparison without creating atoms.
Malformed paths return `{:error, :invalid_path}` and missing/non-map traversal returns `{:error, {:unknown_setting, remaining_path}}`.
`update/1` accepts a non-struct map of nested section maps and/or dotted or list-path keys, resolves destinations against schema paths only, and rejects unknown paths with `{:error, {:unknown_setting, path}}`, malformed sections with `{:error, {:invalid_section, path}}`, malformed paths with `{:error, :invalid_path}`, and duplicate destination aliases or atom/string payload-key collisions with `{:error, :colliding_patch_paths}`.
A non-map/struct patch returns `{:error, :invalid_patch}`, an empty patch is a no-op `:ok`, and empty section maps are refused rather than interpreted as deletion.
Map-valued settings merge recursively, while list-valued settings (including provider/model inventories) replace the whole value; indices and account ids are not patch paths.
Leaf payload map keys normalize to strings, including canonical provider profiles and all their nested model/options maps.
An update starts from the snapshot's parsed USER map, overlays only requested leaves, preserves unrelated and unknown existing keys, and validates exactly ONCE — `Schema.validate(Normalization.resolve(candidate))`, the atomized, default-merged candidate — then hands that USER-only data to `Config.persist_user_config/1`, which serializes, writes and refreshes the snapshot synchronously.
There is no second validation pass (validating the raw string-keyed candidate is inert because `Schema.validate/1` walks atom-keyed schema paths only), and defaults plus derived legacy-model mirrors are never supplied to persistence.
Validation failures return the schema's `{:error, [ValidationError]}` unchanged with no write; serialization/filesystem errors return unchanged from the save path.
No settings facade operation changes credentials, invokes a scheduler reload or applies runtime overrides, and update's read-modify-save has the same non-atomic/concurrent-writer limitations as `save_user_config/1`.
`normalization.ex` owns the shared default merge, safe existing-atom key conversion, enum/model normalization and legacy migration used by BOTH snapshot loading and candidate validation; serialization and credential handling remain in `config.ex`.

### `EvoGit.Config.LLMCatalog` (provider/model shortcuts)
| Function | Description |
|----------|-------------|
| `providers/0` | Predefined providers with models (Anthropic, OpenAI, ChatGPT Subscription/Codex, Google, DeepSeek, Alibaba, Z.ai, MiniMax, Moonshot AI, xAI, OpenRouter, OpenAI-Compatible) |
| `provider_models/1` | Model shortcuts for a provider atom |
| `resolve_model/2` | `{provider_atom, model_input}` → `"provider:model"` string (backward-compat) |
| `resolve_runtime_spec/3` | CANONICAL map analog: `%{provider: atom, id: string}` (+ optional `base_url`/`extra`) — a ReqLLM `runtime_spec()`, NOT a task `model_spec`. Opts `:base_url`, `:variant`, `:extra`; `resolve_model_spec/3` remains the documented compatibility alias. |
| `requires_base_url?/1` | Provider requires a custom `base_url` (default `false`); `:openai_compatible` → `true`. |
| `find_provider/1` | Provider entry by atom (checks `provider_atoms`) |
| `auth_modes/1` | `[:api_key] \| [:api_key, :oauth] \| [:oauth]`; default `[:api_key]` for an unknown/API-key-only provider |
| `oauth_source/1` | Subscription login source (`:chatgpt` for `:openai_codex`, `:claude_code` for `:anthropic`), else `nil` |
| `oauth_only?/1` | `true` when `:api_key` is NOT in `auth_modes/1` — a subscription is the only way to authenticate |
| `supports_oauth?/1` | `true` when `:oauth` is in `auth_modes/1` |
| `unknown_provider_help/0` | Guidance text (llmdb.xyz + ReqLLM docs links) |
| `known_credential_keys/0` | All unique credential key names — an entry's `credential_key` is contributed ONLY when `:api_key` is in its `auth_modes` (so the OAuth-only `:openai_codex` never makes `api_key_present?/1` report a key); VARIANT keys are contributed unconditionally. |
**Model lists are derived data**: ChatGPT registrations supply the available model IDs and display names; other providers use shortcuts derived from the vendored LLMDB snapshot (`deps/llm_db/priv/llm_db/snapshot.json`).

### `EvoGit.Config.ProviderPresets` (built-in schedule presets)
`provider_presets.ex` — machine-readable copies of peak/off-peak policies a vendor publishes unambiguously, so the dashboard's provider-profile editor can pre-fill an account's schedule in one click.
| Function | Description |
|----------|-------------|
| `all/0` | Every preset in display order |
| `ids/0` | The stable preset ids in display order |
| `get/1` | One preset by id; `nil` for an unknown id or a non-binary input |
| `for_provider/1` | Presets for one provider, given as the provider ATOM (`:deepseek`) or its STRING name (`"deepseek"`, `"zai_coding_plan"`, `"ZAI-Coding-Plan"` — case- and separator-insensitive); `[]` for nil or an unknown provider |
This module is DATA ONLY: it writes no config, touches no disk, starts no process, reads no clock and raises on nothing — the caller decides whether/when to apply a preset, to which account, and whether the user then edits it.
The envelope is atom-keyed `%{id, label, provider, schedule, note}`, while `schedule` is STRING-keyed so it merges verbatim into a string-keyed canonical account over `concurrency`, `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days` and `off_peak_holidays`, carrying only the keys that provider's policy uses and staying valid input for `EvoGit.PeakHours.validate_windows/1`, `validate_days/1` and `validate_holidays/1`.
A published price/quota ratio is conservatively mapped onto Genesis slots (a rate that halves off-peak becomes `peak_concurrency` = half of `concurrency`) as an editable pre-fill default, never a claim about vendor capacity.
Two presets ship today: `deepseek-standard` (`:deepseek`, UTC weekday windows excluding CN holidays, weekends off-peak) and `zai-glm-coding-plan` (`:zai_coding_plan`, weekday 14:00-18:00 Singapore time); source URLs live in the module's moduledoc.
A provider with NO published time-of-day policy deliberately gets no preset (`:anthropic`, `:openai`, `:openai_codex`, `:google`, `:xai`, `:openrouter`, pay-as-you-go `:zai`, and the flat or model-specific `:moonshotai`/`:minimax`/`:alibaba`) — per-provider reasons live in the moduledoc.

### `EvoGit.Config.VersionState` (upgrade detection)
Tracks the last-seen Genesis version in `version_state.toml` (config dir); defaults to `"0.8.0"` when no file exists.
| Function | Description |
|----------|-------------|
| `get_version/0` | Recorded version string (default `"0.8.0"` if absent/unparseable/missing key) |
| `current_version/0` | Runtime version via `Application.spec(:evo_git, :vsn) \|> to_string()` |
| `save_version/1` | Persists a version string (`save_version/0` persists `current_version/0`). `:ok \| {:error, reason}` |
| `upgraded?/0` | `true` if recorded version ≠ current version |
| `record_current_version/0` | Persists `current_version/0`; call after showing the update log. |

### `EvoGit.Platform` (cross-platform utilities)
| Function | Description |
|----------|-------------|
| `os/0` | `:linux`, `:macos`, `:windows`, or `:unknown` |
| `config_dir/1` | Config dir (XDG/Linux, Application Support/macOS, APPDATA/Windows) |
| `data_dir/1` | Platform data dir |
| `shell/0` | Effective shell — honors the `[tools] shell` override; defaults `"bash"` (Linux/macOS) / `"powershell"` (Windows) |
| `shell_args/1` | `["-c", cmd]` (POSIX) or PowerShell `-EncodedCommand` args (via `EvoGit.Powershell`) |
| `systemd_available?/0` | Linux + systemd |
| `nix_available?/0` | `nix` binary in PATH (Linux and macOS) |

### `EvoGit.ProjectConfig` (per-repo genesis.toml)
| Function | Description |
|----------|-------------|
| `read/1` | Parses `genesis.toml` from repo root |
| `worktree_script/1` | Worktree init script for the current OS (backward-compat wrapper) |
| `worktree_script/2` | Worktree init script for a given OS, with variant resolution |
| `write_worktree_script/2` | Writes/merges the script into `genesis.toml` `[worktree].script`, preserving existing sections/keys |
| `commands/1` | User-defined dev command shortcuts from `[commands]` |
| `foreign_repos/1` | `ForeignRepo` structs |

### genesis.toml Structure
```toml
[worktree]
script = "..."                 # single fallback script (any OS)
script.linux = "..."           # OR OS-specific variants (TOML dotted keys)
script.macos = "..."
script.windows = "..."
# Resolution: script.<current_os> → script (fallback) → nil

[commands]
dev = "npm run dev"            # displayed in dashboard; manually triggered, NOT auto-executed

[foreign_repos.original]
path = "/Source/original-proj"
description = "Legacy Project"
```

### Foreign repos — schema & machine-binding gotchas
- **There is NO `[[repos]]`/repo-registry table in `config.toml`**: `Definitions.schemas/0` contains no repo/path key at all, so `Schema.validate/1` never validates a repository path and `Config.resolve/0` returns no repo list; the only repository configuration is the per-repo `genesis.toml` `[foreign_repos.<id>]` read by `EvoGit.ProjectConfig` (sibling `../project_config.ex`, deliberately NOT Ecto-validated) plus the per-task `:foreign_repos` opt.
- **Schema**: `[foreign_repos.<id>]` with `path` (REQUIRED — missing → entry dropped + a `Logger.warning`, `ProjectConfig.build_foreign_repo/2`) and `description` (optional). The TOML table key IS the id; the key is `description`, NOT `name` (a `name` key is silently ignored), and there is no opt-in flag — every entry is always loaded.
- **Committed to git**: `genesis.toml` is not git-ignored and Genesis Mode B auto-creates it via `ProjectConfig.write_worktree_script/2`, so absolute paths in `[foreign_repos]` are committed and wrong on any other machine.
- **Path handling**: nothing validates absolute paths but they are semantically required — `ForeignRepo.new/3` only runs `EvoGit.Platform.safe_expand/1` (`~` → home, RELATIVE → the PROCESS CWD, no `$VAR` expansion) and nothing checks existence at load or task start, so a missing path flows into the agent context and fails only at delegation (`build_subagent_phylo_node` matches `{:ok, foreign_head} = Git.rev_parse(...)`).
- **Task-opt merge**: `Runtime.Helpers.merge_foreign_repos/2` normalizes both lists via `ForeignRepo.normalize/1` and `Map.merge(toml_map, opt_map)` — the task opt wins per id, unparseable entries drop, and it can OVERRIDE but never REMOVE a `genesis.toml` entry; the dashboard's per-project list lives only in socket assigns and `ResumeContext` does NOT carry `:foreign_repos` (only `MergeContext` does).

### Worktree Init Script Environment Variables
| Variable | Description |
|----------|-------------|
| `SOURCE_REPO_PATH` | Main repository checkout path |
| `TARGET_WORKTREE_PATH` | Newly created worktree path |
| `SOURCE_WORKTREE_PATH` | Parent agent's worktree path (`SOURCE_REPO_PATH` for top-level agents) |

### Configuration Levels (priority low → high)
1. **Application defaults** — `Schema.defaults/0` (no model, no username). Three values are DYNAMIC, computed at `Definitions.schemas/0` runtime from `EvoGit.Platform.cpu_threads/0`: `[:scheduler, :max_tool_concurrency]` (= CPU thread count) and both sandbox `:cpu_quota` values (`"#{cores * 100}%"`), shared by display, reset-to-default and resolution.
2. **User config** — `~/.config/genesis/config.toml` (XDG), parsed with `TomlElixir.decode/1`.
3. **Runtime overrides** — `AgentScheduler` GenServer state via `handle_call({:update_config, opts})`; concurrency/retry/turn values are config.toml-only, and model selection is task-level in task opts, never a scheduler override.

### config.toml Structure
```toml
[scheduler]
default_llm_max_concurrency = 3    # per-account concurrency when unset
max_tool_concurrency = 8           # default = CPU thread count
agent_max_retries = 3              # crash-retry limit per agent (min 0)
max_agent_depth = 8                # subagent recursion depth (min 1)
max_retries = 15                   # total LLM API retries (min 1)
max_turns = 128                    # SUB-agent turn cap (min 1)
max_turns_root = 1000              # ROOT agent turn cap only (min 1)
delegation_hint_threshold = 5      # write calls to a child dir before a nudge (0 disables)
read_delegation_hint_threshold = 8 # read calls to a child dir before a nudge (0 disables)
max_tool_timeout = 1_800_000       # ms cap on any agent-requested tool timeout
default_tool_timeout = 10_000      # ms default when the agent omits one

[llm]
model = "provider:model"                  # required when no [[llm.providers]] exist
# compression_threshold_tokens = 150_000  # optional explicit override
tool_result_pruning = true
tool_result_pruning_target_fraction = 0.5

[user]
github_username = "..."            # PR creation only (optional)

[sandbox]
mode = "auto"                      # "auto" | "enabled" | "disabled"
backend = "auto"                   # "auto" | "systemd" | "bwrap"
write_paths = []                   # unset/nil = platform defaults; set (incl. []) REPLACES them

[nix]
enabled = false                    # run tool calls in a cached Nix dev env (needs config-dir flake.nix)
flake_output = nil

[appearance]
accent_color = "blue"              # blue|teal|green|yellow|orange|red|pink|purple|brown|slate

[data]
dir = "/abs/path/to/data"          # relocate tasks.sqlite/logs/caches; next boot

[tmp]
mode = "system"                    # "system" | "custom" | "per_repo"
path = "/abs/path/to/tmp"          # base for :custom mode

[lsp]
enabled = false                    # offers the `lsp` tool only when true
command = "lexical"
args = ["start"]
timeout = 30_000
diagnostics_timeout = 10_000
```
Per-key types/defaults of all 112 descriptors (19 under `[sandbox]`): `schema/CONTEXT.md`.
Canonical `[[llm.providers]]` and legacy `[[llm.models]]` profile syntax: `docs/llm-profiles.md`.

**`[data] dir` relocates the runtime data dir** (`tasks.sqlite`, logs, remote binaries, nix cache, `genesis-source`, `agent_state.sqlite`).
`EvoGit.Platform.data_dir/0` consults `EvoGit.Config.resolve([:data, :dir])`: a non-empty absolute (or `~`-expanded) value wins; invalid values (nil/empty/non-binary/relative) log a `Logger.warning` and fall back to the OS+env default via `base_dir("genesis", "XDG_DATA_HOME", ".local/share")` — it NEVER raises.
**Precedence chain**: TaskRegistry `opts[:data_dir]` test seam → app env `config :evo_git, :data_dir` (honored only where `Application.get_env/3` is read — the Store child spec, `TaskRegistry.init/1`, `mix migrate.store`; set only in `config/test.exs`) → TOML `[data] dir` → XDG platform default (env `XDG_DATA_HOME` / `APPDATA` / `HOME`; `XDG_CONFIG_HOME` drives the config dir).
Direct `Platform.data_dir()` consumers (desktop log path, `SelfReflectiveSource` clone, `RemoteBootstrap` cache, `Sandbox.Nix` cache) honor the TOML override too, ignoring only the app-env one; per-repo `.genesis` artifacts stay repo-root-fixed.
**Boot ordering**: `EvoGit.Config.resolve()` runs unconditionally in `config/runtime.exs` (every release, before any app starts) and again in `EvoGit.Application.start/2` via `EvoGit.Distribution.maybe_enable/0`, so `[data] dir` is readable when the Store child spec evaluates; the config file's own location never depends on the data dir, so there is no chicken-and-egg.

**`[tmp]` — per-task managed temporary directory**: `EvoGit.Config.resolve([:tmp, :mode])` + `[:tmp, :path]` select the base for a task's managed tmpdir `task_<id>`:
- `:system` (default) → `<system tmp>/genesis/task_<id>` (honors the OS tmp config, e.g. `$TMPDIR`).
- `:custom` → `<[tmp] path>/genesis/task_<id>`; an empty/nil/non-absolute base falls back to the system tmp.
- `:per_repo` → `<task's primary repo>/.genesis/tmp/task_<id>`.

`mode` is an `:atom` enum atomized by the dedicated `[:tmp]` clause in `Normalization.atomize_enum_values/1` before `Schema.validate` (without it the raw string fails the `:atom` type check and lands in validation warnings).
The `[:tmp, :*]` keys carry `category: :data` (NOT a new `:tmp` category): the dashboard Settings page hardcodes its category set (`EvoDashWeb.SettingsComponents.CategoryMetadata`) and a new category would crash its sidebar render.

**`[lsp]` — Elixir code intelligence for the `lsp` tool**: the tool (`agent/tools/lsp.ex`) never installs, downloads or bundles a language server — it speaks LSP over stdio to whatever this section points at (a user-installed `lexical start` or an elixir-ls launcher), one disposable server process per call.
Keys (all `category: :tools` — rendered under Tools despite the `[lsp]` table): `enabled` (`:boolean`, default `false`), `command` (`:string`, default `nil`, resolved through `EvoGit.Executable.resolve/1` + `System.find_executable/1`), `args` (`:list_of_strings`, default `[]`), `timeout` (`:pos_integer` ms, default `30_000`, min 1 — the WHOLE-call budget: spawn, `initialize` handshake and the one analysis request) and `diagnostics_timeout` (`:pos_integer` ms, default `10_000`, min 1 — the settle window for `textDocument/publishDiagnostics`, ending early when the stream goes quiet).
The tool is NOT OFFERED AT ALL while `lsp_enabled?/0` is false (the default), so no agent — root, subagent or repo-less — sees it and no prompt tokens are spent; once offered, a still-unconfigured call returns the self-explaining `Error: no language server configured — set [lsp] command in config.toml`.
Validation is warning-only at runtime: `resolve/0` logs `Config validation error at [:lsp, ...]` and still returns the merged config; only `save_user_config/1` refuses a malformed value, and the gate plus the tool normalize defensively (non-map section → disabled, non-list `args` → `[]`, invalid timeouts → defaults, STRING `"true"` accepted for `enabled`).
Only two consumers read the section: `lsp_enabled?/0` (the offering gate) and the tool itself (both via `resolve([:lsp])`, a non-map result treated as `%{}`).

**`[[llm.providers]]` canonical inventory**: each STRING-keyed account has `id`, `provider`, optional `name`, shared auth/endpoint/concurrency/peak/generation settings, ordered `models`, optional `default_model`, `reasoning_efforts` and `default_reasoning_effort`.
The optional `[llm] default_provider_profile` selects an account by id; absent selectors choose the first account/model, while explicit unknown selectors return resolution errors.
Nested models accept a model id string or a map with `model` (`id` is an input alias), optional generation/context/effort overrides, and remain recursively string-keyed after resolution.
`Schema.provider_profiles/1`, `model_selections/1` and `resolve_selection/2` delegate to `Schema.ProviderProfiles`; `resolve_selection/2` returns the selection fields (`provider_profile_id`, `profile_name`, `provider`, `model`, `reasoning_efforts`, `default_reasoning_effort`, `context_window`) plus the chosen `reasoning_effort`, the canonical `provider_profile`, the atom-keyed `runtime_profile`, the ReqLLM `model_spec`, the shared concurrency/peak keys and `generation_params`; `resolve_model_spec/2` remains the documented compatibility alias.
Exact maps, precedence and error shapes: `schema/CONTEXT.md`.

**Legacy `[[llm.models]]` profile fields** (still accepted when providers are absent/empty): `id` (required), `model` (required), `concurrency`, `context_window` (default `200_000`), `auth_mode` + `oauth_file`, plus optional `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days`, `off_peak_holidays`.
```toml
[[llm.models]]
id = "deepseek"
model = "provider:model"
concurrency = 4                # normal (off-peak) concurrency
context_window = 200000        # compression window in tokens (default 200000)
auth_mode = "api_key"          # "api_key" (default) | "oauth"
# oauth_file = "~/.config/genesis/auth.json"
peak_concurrency = 0           # concurrency during peak windows (0 = hard pause)
peak_hours = [
  { start = "09:00", end = "12:00", days = ["mon", "tue", "wed", "thu", "fri"] },
  { start = "14:00", end = "18:00", days = "weekdays" }   # keyword = mon-fri
]
timezone = "Asia/Shanghai"     # IANA tz for this profile's peak windows
off_peak_days = ["sat", "sun"] # whole-day off-peak: normal concurrency 24/7
off_peak_holidays = "CN"       # holiday calendar: non-working days are off-peak whole days
```
- `auth_mode` — optional `"api_key"` (default) | `"oauth"`; bookkeeping for humans and the dashboard, while the RUNTIME decision is `Schema.LLM.oauth_profile?/1` (`auth_mode == :oauth` OR an OAuth-only provider). Validated by `EctoValidation.validate_auth_mode/2`.
- `oauth_file` — optional non-empty path for THIS profile's managed OAuth credential file; absent → `<config_dir>/auth.json` (there is no global `[llm] oauth_file` key). Validated by `EctoValidation.validate_oauth_file/2`.
- `context_window` — optional positive integer; absent/nil → `200_000`; it is the context-compression window (stage-1 pruning target + derived threshold), never catalog metadata. Validated by `validate_model_profile/2`, read through the ONE shared resolver in `Schema.LLM`: `default_context_window/0` (`200_000`), `context_window/1` (atom- or string-keyed profile; invalid → `Logger.warning` + default, never raises) and `context_window_for/2` (config + profile id; unknown id → default).
- `peak_concurrency` — NON-NEGATIVE integer (`0` = hard pause: zero LLM slots during peak, never raised by the `default_llm_max_concurrency` floor); absent → off-peak `concurrency` always applies.
- `peak_hours` — list of maps with `start`/`end` as `"HH:MM"` strings OR integer minutes of day (both values of one window in the same representation), atom- or string-keyed; half-open `[start, end)`, `start > end` = overnight wrap, absent/`[]`/invalid → disabled. `EvoGit.PeakHours.parse_window/1` + `validate_windows/1` are the single parse/validate path and accept BOTH representations uniformly.
- `timezone` — optional IANA name; all peak computations (in-peak checks + transition wakeups) use that tz wall clock, DST-aware; absent/empty/nil → server local wall clock. Validated by `EvoGit.PeakHours.validate_timezone/2`, which is passed the bundled `Tz.TimeZoneDatabase` explicitly (`config_time_zone_database/0`), never the ambient `Calendar` global, so a snapshot built before `EvoGit.Application.start/2` validates identically. `Calendar.put_time_zone_database(Tz.TimeZoneDatabase)` in `Application.start/2` installs the same database for runtime math (`tz ~> 0.28`, pre-compiled IANA data, no auto-update).
- `off_peak_days` — days on which the profile is off-peak the ENTIRE day (normal `concurrency` 24/7, every window suppressed, `peak_concurrency` incl. `0` never applies). **Precedence: `off_peak_days` wins over window `days`.** Vocabulary: `"mon".."sun"` (case-insensitive) plus `"weekdays"`/`"weekends"`; validated by `EvoGit.PeakHours.validate_days/1` — never re-implement the vocabulary.
- **Window `days`** — optional per-window key (same vocabulary): applies only on listed days; absent → every day; invalid → `%ValidationError{}` at `[:llm, :models, <idx>, :peak_hours, <window_idx>, :days]`, validation delegating to `EvoGit.PeakHours`.
- `off_peak_holidays` — optional holiday-calendar id (today only `"CN"`, case-insensitive, atom or string): any calendar NON-WORKING date is off-peak the ENTIRE day, exactly like `off_peak_days`. The calendar (`EvoGit.PeakHours.Holidays`) treats statutory CN holidays and weekends as non-working and 调休 make-up workdays as WORKING, so a make-up Saturday can still hit a `days: ["sat"]` window. Validated by `EvoGit.PeakHours.validate_holidays/1`; an ACCOUNT-level field — nested per-model overrides are neither read nor validated.
- **Validation ownership**: window parse/format/overlap/days delegate to `EvoGit.PeakHours.validate_windows/1`, `validate_days/1` and `validate_holidays/1`; `Schema.validate/1` reports `%ValidationError{}` at `[:llm, :models, <idx>, :peak_hours]`, `[:llm, :models, <idx>, :peak_hours, <window_idx>]` (overlap at the later window's index), `[:llm, :models, <idx>, :off_peak_days]` and `[:llm, :models, <idx>, :off_peak_holidays]`.
- Peak-hour fields (incl. `timezone`, `off_peak_days`, `off_peak_holidays`, window `days`) and `context_window` survive resolution (`deep_merge` → `atomize_enum_values` → `migrate_llm_models` → `Schema.validate`) untouched and reach `state.model_profiles` via `get_config(:model_profiles)`; `off_peak_holidays` rides `ProviderProfiles.Normalize.@shared_keys` through legacy migration.
- **`provider_options` / `store: false`**: `Schema.LLM.provider_options_for_model/1` returns `[store: false]` for a NATIVE OpenAI endpoint only (provider `:openai` AND no custom endpoint override); a model-spec map carrying a non-nil `:base_url` or `:extra` is an OpenAI-COMPATIBLE third-party endpoint (presence check, so even an empty `extra` counts) and gets `[]`.
- `store` is a Responses-API-only field — the shared Chat-Completions encoder reads `provider_options` ONLY for `[:response_format]`. A profile's explicit `provider_options` override always wins over the provider-aware default (an empty override map yields no `:provider_options` key at all), and a key the provider does not declare RAISES at request time (`zai` accepts `[:thinking]` only).
- **Generation parameters are provider/model-aware** at the single choke point `Schema.LLM.profile_generation_params/1`, which pipes its keyword list through `Schema.LLMConstraints.filter/3` (declarative Z.AI/GLM table + llm_db metadata; full contract in `schema/CONTEXT.md`). The dashboard persists NO generation params unless the user typed them, so the filter only removes explicitly set parameters.
- That call is the ONLY path in this subtree that reaches the LLMDB catalog: `model_metadata/1` is uncached and, when the `:llm_model_metadata_fun` seam is unset, the first call on a cold BEAM loads the whole catalog in the CALLING process — at boot `EvoGit.CatalogWarmup`'s throwaway process, started immediately before `AgentScheduler` (detail: `schema/CONTEXT.md` → "Model metadata seam").
- **Not every extracted key reaches the wire**: `top_k`/`reasoning_effort` are accepted ReqLLM options but the Z.AI family encodes neither (`Zai.Shared.add_basic_options/2` emits only `temperature`, `top_p`, `frequency_penalty`, `presence_penalty`, `user`, `seed`, `stop`; `reasoning_effort` is telemetry-only there), while the OpenAI chat-completions path DOES emit `reasoning_effort`. `stream_options: %{include_usage: true}` is emitted unconditionally by req_llm's encoders, is not an accepted ReqLLM option and is not suppressible from the config layer.

**`[sandbox] backend`**: `:atom` key, default `:auto`, validation `[in: [:auto, :systemd, :bwrap]]`. `:auto` tries systemd-run → bwrap → no sandbox (macOS always uses sandbox-exec; bwrap is Linux-only); `:systemd` forces systemd-run (no sandbox without systemd); `:bwrap` forces bubblewrap (filesystem isolation only, no resource limits, falls back to no sandbox when unavailable). `[sandbox.resources]`/`[sandbox.process]` are systemd-only and ignored with bwrap. Strings are atomized by `Normalization.atomize_enum_values/1` (the `:sandbox` clause covering `:mode` + `:backend`) before `Schema.validate`.
**Sandbox mode/backend are read from the CONFIG SNAPSHOT, never from scheduler state**: `Sandbox.backend/0` and every backend's mode gate call `EvoGit.Config.resolve([:sandbox, :mode|:backend])`, and `resolve/0` deliberately excludes runtime overrides, so `AgentScheduler.update_config(sandbox_mode: …)` only changes the REPORTED value, not what the sandbox does.
`sandbox_resources`/`sandbox_process_resources` DO apply live (a Linux-only `SandboxSlice.update_resources_async/1` push when the value is a map), and `get_config(:sandbox_backend)` reports platform detection (`Platform.sandbox_backend/0`), NOT the configured `[sandbox] backend`.
**There is NO app-env sandbox switch**: no `.ex` file reads `Application.get_env(:evo_git, :sandbox)`, so `Application.put_env(:evo_git, :sandbox, …)` is a NO-OP.

**`[sandbox] write_paths`**: `:list_of_strings`, default `nil`. nil → platform-default writable paths; set (incl. `[]`) → REPLACES the built-in list (`[]` disables those paths entirely); non-list/non-string-list → validation error, never a crash.
Consumed ONCE by `EvoGit.Sandbox.Spec.build/2` via `resolve([:sandbox, :write_paths])` (renderers read the resolved `spec.cache_write_paths`): `~`-prefixed entries expand home, absolute as-is, relative joined to `$HOME`; structural paths (cwd, tmp, nix store, repo `.git`) are always appended and deny lists are never affected (detail: `sandbox/CONTEXT.md`).

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
Keys are loaded into ReqLLM's in-process key store on a snapshot build; only one key is needed (matching the LLM model's provider). OAuth data never lives here.

## Adding a New Config Category / Schema (round-trip contract)

All schemas live in ONE flat list — `EvoGit.Config.Schema.Definitions.schemas/0` (NOT per-category modules). A schema is a plain map with 7 keys (`key_path`/`type`/`default`/`validation`/`category`/`sub_category`/`description`) — there is NO `%Schema{}` struct. `schemas_by_category/0` = `Enum.group_by(& &1.category)`; per-category order = definition order.

Adding a NEW top-level category is additive for enumeration (append a schema map), `Schema.validate/1` (only checks defined keys; absent keys and nil values pass; unknown keys are never rejected), `defaults/0` (derived automatically from each `:default` via `deep_put`) and save-side serialization (`Keys.stringify/2` + `TomlElixir.encode` write any map; atom VALUES encode as quoted strings, nil values drop).

**The one non-additive gap is the READ/resolve path**: TOML has no atoms, and string enum values are atomized ONLY by `atomize_enum_values/1`, whose HARDCODED clauses cover `:sandbox` (`:mode`/`:backend`), `:git` (`:cow_worktree_creation`), `:llm` (model normalization + reasoning-effort canonicalization), `:tools` (search provider + per-provider `search_depth` via `search_providers/0`) and `[tmp]` (`:mode`). A NEW atom-typed key under `:tools` needs its own handling (or `type: :string` + `validation: [in: [...]]`); a NEW `:atom`-enum key needs a matching clause (or `:string` typing + atomization at the consumption point, like `[:llm, :reasoning_effort]`), else every snapshot build logs `must be an atom, got "blue"` and `config_status/0` reports it (non-fatal — the value stays a string). The dashboard save path is unaffected: `SettingsUtils.parse_atom/2` (evo_dash) converts `:atom` form values against `validation[:in]` BEFORE `Schema.validate`.

Dashboard-side requirements for a new schema-driven category (evo_dash, not core): `category_display_name/1`, `category_icon/1`, `category_description/1` clauses in `EvoDashWeb.SettingsComponents.CategoryMetadata` (no catch-all — a missing clause is a FunctionClauseError in the sidebar/header) plus an entry in its `sort_categories/1` order list (missing = sorts last). `:agents`/`:remote_connections` are NOT core categories — the dashboard injects them as empty-schema pseudo-categories.

## Validation Path Typing
`Schema.key_path/0` describes atom-only schema descriptor paths.
`Schema.ValidationError.key_path/0` describes error paths containing atoms and non-negative list indexes, as emitted by composite profile validators, and is used by `Schema.ValidationError.t/0`.

## Validation Engine — Ecto-backed (architecture)

The scalar/rule validator beneath the DSL is **Ecto-backed, but Ecto is a VALIDATOR ONLY** — no `Ecto.Changeset` is ever built, `apply_changes` is never called, and the validated map passes through unchanged on `{:ok, config}` (unknown keys survive, model profiles stay plain maps).

- **`EctoTypes`** (`ecto_types.ex`) — eight nested strict `use Ecto.Type` modules (`PosInteger`, `NonNegInteger`, `Integer`, `String`, `ListOfStrings`, `Float`, `Atom`, `Boolean`), one per scalar DSL type; public `type_for/1`, `cast/2` and `valid?/2`. They are strict decision oracles: no numeric-string coercion (`"3"` fails integer types), `""` is meaningful (never stripped), `:float` accepts int-or-float, `:atom` never casts strings.
- **`EctoValidation`** (`ecto_validation.ex`) — error adapter + composite recursion; `errors_for(key_path, type, validation, value) :: [%ValidationError{}]` returns type errors FIRST then rule errors. All window/day/timezone/holiday math delegates to `EvoGit.PeakHours`, and the timezone validator receives the bundled `Tz.TimeZoneDatabase` explicitly; `provider_profile_shared_errors/2` covers `peak_concurrency`, `peak_hours`, `timezone`, `context_window`, `off_peak_days`, `off_peak_holidays`, `auth_mode` and `oauth_file` for BOTH canonical accounts and legacy profiles; `min`/`max`/`in` stay hand-written pure predicates (Ecto's `validate_number`/`validate_inclusion` are banned by design). Message sentences, `value`/`rule` terms, sub-path key_paths and error ordering are byte-pinned by the `schema_test.exs` / `config_test.exs` suites.
- **Delegation path**: `Schema.validate/1` keeps its map-walk + `safe_get_in/2` and calls `EctoValidation.errors_for/4` per present value; scalar decisions route through `EctoTypes.valid?/2`. Composite types (`:model_spec`, `:model_profiles`) and the optional profile fields recurse explicitly (multi-error, sub-path-aware).
- **What stays hand-written (and why)**: Ecto has no TOML story and the pipeline runs on variable-depth maps with byte-pinned shapes, so the transform pipeline lives in `normalization.ex` (`deep_merge`, `atomize_enum_values` — atomization stays PRE-Ecto, and it writes every reasoning-effort site in the ONE ladder's canonical spelling — and `migrate_llm_models`); save serialization (`strip_flat_llm_fields`, `Keys.stringify/2`, `TomlElixir`) remains in `config.ex` (`persist_user_config/1`). `Schema.defaults/0` stays a hand-written `deep_put` from each descriptor's `:default` (112 entries). `config.ex` calls `Schema.validate/1` exactly once per snapshot build (`build_snapshot/1`), validate-first in `save_user_config/1`, and once over the normalized candidate in `Settings.update/1`.
- **Ecto quirk handling**: numeric strings fail number types; `""` is never stripped; unknown keys survive (Ecto is oracle-only); there is no `Ecto.Enum`, so a bad enum string that survived atomization surfaces as a TYPE error (`rule == :atom`), never an `in:` error; `Ecto.Type.cast(_, nil)` → `{:ok, nil}`, matching nil ≡ absent (absent keys are skipped by `safe_get_in/2` before `errors_for/4` runs); `EctoTypes.type_for/1` must return FULLY-QUALIFIED module atoms (`__MODULE__.PosInteger`) or Ecto's runtime dispatch fails.
- **Deliberate exclusions (NOT Ecto-validated)**: `LLMCatalog` (static catalog), `VersionState` (self-validating TOML file), `credentials.toml` (free-form keys), `ProjectConfig`/`genesis.toml` (per-repo, lenient by design), `CustomAgents`/`agents.toml` (own CRUD validation), `RuntimeOpts` (task-opts contract, raises `ArgumentError`). Only the `config.toml` DSL (the 112 `Definitions.schemas/0` entries, including 14 LLM descriptors) is Ecto-validated.

## Direct API Admission and Persistence Boundaries
`EvoGit.Config` lives in this directory's `config.ex`, not in the parent directory.
`Schema.all_schemas/0`, `schemas_by_category/0`, `defaults/0` and `validate/1` are real public APIs in `schema.ex`; `Schema.effective_model_profiles/1` delegates to `Schema.LLM` and supplies the runtime's legacy-profile fallback.
The Assistant evaluator admits direct `Config.resolve/0,1`, `list_settings/0`, `show/0,1`, `user_config/0` and `config_path/0` reads in read and write tiers through explicit exact-MFA lists, never namespace grants; only approved tier-2 write calls additionally admit `Config.update/1`, `save_user_config/1`, `AgentScheduler.RemoteAPI.reload_config/0` and `AgentScheduler.update_config/1` (full contract: `../agent/tools/elixir_eval/CONTEXT.md`).
The permission model protects against accidental self-corruption, not malicious attackers: read/write stay Dune-interpreted with bounded execution, while separately approved sudo is unrestricted native evaluation — never an automatic escalation.
`Config.resolve/0,1`, `show/0,1` and `user_config/0` return UNREDACTED data (node cookies, model `extra`/`provider_options`, endpoint credentials, arbitrary unknown TOML keys), and neither output caps nor error messages redact secrets; both reads cover defaults plus user configuration, not live scheduler overrides.
`Config.list_settings/0` discovers supported settings and `config_path/0` returns the config.toml location.
`Config.config_status/0` returns `missing`, `warnings`, `ok?` and `validation_errors`, but loads credentials into ReqLLM and may lazily import OAuth credentials into a managed file; it takes `resolved` and `validation_errors` from ONE `Cache.get/0` value, so the errors match the resolved map exactly, though its nested health reads are not transactionally isolated from an in-flight `Cache.reload/1`.
There is no process-dictionary validation-error propagation: `resolve/0` is a plain snapshot read, and only a `Cache` store ever replaces the snapshot.
`:ok?` requires both no missing critical settings and an empty validation-error list; `missing`/`warnings` remain presence/credential diagnostics without validation values or credentials.
Public visibility alone does not grant evaluator access: `config_status/0`, `read_toml_file/2,3`, credential helpers and schema APIs stay unlisted; `read_toml_file/2,3` reads any supplied path despite `@doc false`, and `credential_key_to_reqllm_key/1` calls `String.to_atom/1` for arbitrary suffixed input (the config file is a trusted source).
`Config.save_user_config/1` validates the supplied map then REPLACES the entire config file — not a patch or merge API; it reloads the snapshot synchronously and performs no scheduler reload or PubSub `"config"` broadcast on its own behalf.
`Config.persist_user_config/1` is the UNVALIDATED half (mkdir_p → mirror stripping → `Keys.stringify/2` → TOML encode → `File.write/2` → `Watcher.notify_change/1`), `@doc false`, and only `save_user_config/1` and `Settings.update/1` call it — every other caller must go through `save_user_config/1`.
For a targeted persistent change prefer approved `Config.update/1` (partial patch over the snapshot's user map, preserving unrelated settings); it delegates persistence and synchronous refresh to `persist_user_config/1` after its own single validation pass, and neither API applies scheduler runtime state.
`save_user_config/1` remains the replacement API: saving a resolved map also materializes defaults; the write is plain `File.write/2` with no atomic rename, lock, rollback or chmod, drops nil entries and mirrored flat LLM fields, and reloads the snapshot only after a successful write.
Both the partial and replacement read-modify-save paths are non-atomic and can overwrite another writer's changes.
After a successful `update/1` or `save_user_config/1`, explicitly call `AgentScheduler.RemoteAPI.reload_config/0` and inspect its result to apply reloadable scheduler settings; persistence success does not imply reload success, and boot-only settings still require a restart.
`AgentScheduler.update_config/1` is a separate runtime-only mutation (overwritten by a reload or restart).
`Schema.validate/1` walks atom-keyed schema paths, skips missing/nil/non-map intermediates and preserves unknown keys, so string-keyed top-level maps and malformed intermediate sections can bypass validation; model-profile validation checks id/model, the atom-keyed provider-options container and optional peak/context/auth fields, but not per-profile concurrency or generation-parameter ranges.
`Config.save_credentials/1` merges without schema validation, mutates ReqLLM's key store BEFORE the filesystem write, and does not clear previously loaded keys given empty/nil replacements; `Config.credentials/0` returns raw secrets and mutates that store on a snapshot BUILD.
Schema validation is not authorization, and neither approval nor evaluation timeouts roll back committed side effects.
Leaf-specific OAuth assembly, atom creation and catalog side effects: `schema/CONTEXT.md`.

## Config Caching

`EvoGit.Config.Cache` holds ONE RAM-resident snapshot per config directory in `:persistent_term` under `{EvoGit.Config.Cache, dir}`, shaped `%{dir, user_config, credentials, resolved, validation_errors, generation, fingerprint}`.

- **Reads are pure term lookups**: `Cache.get/0` resolves the directory AT CALL TIME through `EvoGit.Config.config_dir/0` (so the per-process `:config_dir_fun` seam keeps working); a hit performs zero `File.stat`/`File.read`, no merge and no `Schema.validate/1`.
- **One build, then lookups**: a miss calls `EvoGit.Config.build_snapshot/1` once and stores the result with `generation: 1` and NO broadcast; `build_snapshot/1` is the ONLY reader of `config.toml`/`credentials.toml` and runs the whole pipeline once (`defaults() |> deep_merge(atomize_keys(user_config)) |> atomize_enum_values() |> migrate_llm_models()`, then `Schema.validate/1`), keeping the ReqLLM `put_key/1` side effects and one "Config validation error at …" warning per error.
- **Fingerprint-driven reload**: the snapshot fingerprints the raw bytes of both files (`:erlang.phash2({config_bytes, credentials_bytes})`), so `Cache.reload/0,1` rebuilds and compares — unchanged contents return the previous snapshot with no store, no generation bump and no broadcast; a change costs exactly ONE `:persistent_term.put` with `generation + 1`, followed by a best-effort `{:config_reloaded, node(), dir, generation}` on PubSub topic `"config"` (skipped when `EvoGit.PubSub` is not running, never raises into the caller; a raise inside the broadcast is logged at debug).
- **ONE total reload helper**: `Cache.reload_safely/0,1` is the total variant of `reload/0,1` and the ONLY place in the codebase that wraps a snapshot reload in rescue/catch logging (naming the directory), answering `:error`; `reload/0,1` stays RAW, and `Watcher`'s private `refresh/1` delegates to `reload_safely/1` and normalizes its answer to `:ok | :error`, so the boot prime, the debounced file event, the save event and the fallback share ONE reload implementation.
- **Freshness is event-driven, never polled**, from exactly two event sources — a successful save and a file event on the watched directory — that both converge on the watcher's single refresh handler.
- **Saves refresh synchronously through the watcher event**: `save_user_config/1` and `save_credentials/1` call `EvoGit.Config.Watcher.notify_change(dir)` after their successful write and before returning `:ok`, which runs the SAME refresh as a file event — or the `Cache.reload_safely/1` fallback when no watcher is registered — so the settings page, the Welcome setup and the Assistant `elixir_eval` write tier read fresh values immediately.
- **`EvoGit.Config.Watcher`** is a GenServer started after `Phoenix.PubSub` and before `EvoGit.AgentScheduler` (and NOT started when `Mix.env() == :test`) that owns "config changed → refresh snapshot": it watches the config dir through the vendored `file_system` dep and debounces ONE ~150 ms coalesced refresh per burst of `config.toml`/`credentials.toml` create/modify/remove/rename events; its `handle_call({:config_changed, dir})` runs the same refresh for the save event (the explicit requested dir, even when it watches a different one) and replies the refresh VERDICT, which is what lets `notify_change/2` take its own guarded fallback when the refresh failed instead of reporting a save that never landed; an `agents.toml` event calls `EvoGit.CustomAgents.reload/0` instead.
- **Watcher degradation**: a backend that cannot start (no `inotifywait`/`inotify-tools`, watch limits, missing dir) logs ONE warning and the GenServer stays alive unwatched; a stopped worker logs one warning; saves plus explicit reloads still refresh the snapshot. `notify_change/1,2` is total and bounded (a `nil`, unregistered, dead or slow watcher falls back to the same guarded refresh and still answers `:ok`); its bounded `GenServer.call/3` guard is `catch :exit` ONLY, because a dead/restarting watcher (`:noproc`, `:shutdown`) or a slow one (`:timeout`) EXITS the caller rather than raising it, so a `rescue` arm there would be dead code. The watcher is a convenience, never a requirement, and never crashes the application; its `dir:`/`name:` options (default the module name, `nil` = unnamed) exist so tests run isolated instances.
- **Explicit reload re-reads disk**: `EvoGit.AgentScheduler.RemoteAPI.reload_config/0` FORCES `EvoGit.Config.Cache.reload()` before `Config.resolve()` + `update_config/1`, so an explicit reload observes current disk content — including a remote/SSH-triggered one.
- **`read_toml_file/3` stays uncached** (`@doc false`): `project_config.ex` (`genesis.toml`), `remote_connections.ex` (`remote_connections.toml`) and `custom_agents.ex` (`agents.toml`) read through it and keep their own freshness rules.
- **Missing vs unparseable**: an absent/unreadable `config.toml`/`credentials.toml` silently yields `%{}` with no warning log; a TOML decode failure logs one warning and also yields `%{}`.
- `config_status/0` takes BOTH `resolved` and `validation_errors` from ONE `Cache.get()` value, and the errors are only recomputed by the next build.
- `defaults/0` stays uncached — a cheap `deep_put` fold whose three CPU-thread-derived values read `EvoGit.Platform.cpu_threads/0` at call time.

**Snapshot vs scheduler state:**
- The runtime config agents use is the **`AgentScheduler` GenServer state**: `RemoteAPI.get_config/0` reads it, `reload_config/0` forces a snapshot reload and replaces it, and `get_config_status/0` reads the snapshot per call for truthful `:missing`/`:warnings`/`:ok?`.
- `save_user_config/1` refreshes the snapshot but does NOT apply scheduler runtime state — the dashboard (SettingsLive) calls `reload_remote_config` but ignores its return, so a reloadable setting can stay unapplied until an explicit reload.
- `RemoteConnections` does NOT auto-create an empty `remote_connections.toml` (unlike the config skeleton) — the file appears only when a target is saved.

## Boot-Time Resolve Cost & Retention

- `resolve/0` and `resolve/1` are `:persistent_term` lookups: the pipeline (defaults + atomized TOML merge → `atomize_enum_values` → `migrate_llm_models` → `Schema.validate/1` over all 112 schemas) runs ONCE per config directory per actual file change, inside `build_snapshot/1`; no hot-path read pays for it and no read stats a file.
- `Watcher.init/1` primes the snapshot at boot through `refresh/1` → `Cache.reload_safely/1` (the total variant, so a raising build cannot crash-loop the watcher and take `:evo_git` down) — a fingerprint-diffed no-op when `runtime.exs`'s early `resolve/0` already built it — before every CHILD that reads config; in the test env the watcher is absent, so the first `Cache.get/0` in a config dir builds in the calling process.
- Retention: one snapshot per config dir lives in `:persistent_term` for the BEAM lifetime (parsed string-keyed TOML maps, the resolved atom-keyed map and the validation errors — small); `AgentScheduler` independently keeps its selected fields (`model_profiles`, generation params, sandbox/scheduler scalars), and `PeakHourEngine.init`/`SystemSampler` read that state, never the disk.
- ⚠️ The DOMINANT boot cost is not config resolution: `AgentScheduler.init` → `Schema.LLM.llm_generation_params/1` → `model_metadata/1` → `ReqLLM.model/1` triggers LLMDB's LAZY packaged-catalog load (`priv/llm_db/snapshot.json`, ~11.7 MB, ~10,100 models), whose decoded table is retained in `:persistent_term` for the BEAM lifetime (tests measure ~2.5 s). It fires whenever ANY profile carries a `model` — every configured install; a model-less fresh install pays nothing. Config BEAM code is ~220 KB, lazily loaded, and no schema validation runs at compile time.

## Test Seam — per-process config dir (`:config_dir_fun`)

- `EvoGit.Platform.config_dir/1` consults the app-env seam `:evo_git, :config_dir_fun` at CALL time before the XDG resolution.
- The seam accepts a zero-arity fun or an `{m, f, a}` tuple; the result must be a non-empty binary (garbage falls through to the production default, no `try/rescue`).
- It is **default-inert**: production never sets `:config_dir_fun`, so production paths are byte-identical to the XDG/APPDATA/Library resolution; `test/test_helper.exs` installs `{EvoGit.TestSupport.ConfigDir, :resolve, []}` (compiled from `test/support/config_dir.ex`).
- Helpers: `resolve/0` (own process dict → `$callers` pids on the local node → `nil`), `activate/1` (put in the calling process, e.g. from `setup`), `isolate_module!/1` (`setup_all`; unique tmp dir + `on_exit` cleanup, no process dict) and `isolate!/1` (`isolate_module!/1` + `activate/1`).
- `$callers` reaches `GenServer`/`Task`/`Supervisor` children started FROM the test process (OTP 24+ `proc_lib`), NOT boot-time singletons (`AgentScheduler`, `TaskRegistry`, `Store`, `PeakHourEngine`) — a module reading config inside those must stay `async: false`.
- The snapshot is keyed by config DIRECTORY and resolved through the seam at CALL time, so a unique dir per test is snapshot-safe and a stale snapshot can never leak across dirs; `Cache.get(dir)` and `Cache.reload(dir: dir)` address an explicit dir, and `Cache.invalidate/0,1` erases a snapshot (the next `get` rebuilds at `generation: 1` and re-reads disk) — the seam for a test that changes files behind the cache's back.
- A test that goes through `save_user_config/1`/`save_credentials/1` needs no extra cache step (both reload synchronously); the watcher is not started in test, so no test need account for an asynchronous refresh unless it starts its own unnamed `EvoGit.Config.Watcher` (`name: nil`).

## Web Search Provider Config

Web search (`[tools.search]`) supports providers `[:tavily, :perplexity, :exa, :bing, :brave, :keenable]`. The **single source of truth** for that list is `EvoGit.Config.Schema.Definitions.search_providers/0` (module attribute `@search_providers`) — do NOT hardcode it elsewhere.
It feeds BOTH the schema `in:` validation (`[:tools, :search, :provider]`) and `Normalization.atomize_enum_values/1`, which atomizes `provider` and each provider section's `search_depth` against `[:basic, :advanced]` via that accessor.
`tools_search_enabled?/0` is provider-generic: it resolves the SELECTED provider's own `api_key_credential_key` (with a tavily fallback), EXCEPT for a keyless-capable provider (`Schema.Definitions.search_provider_keyless?/1`, today only `:keenable`), which counts as enabled with no key because it falls back to its public endpoint; `[:tools, :search, :enabled]` must still be `true`.

## LLM Shape and Normalization Boundaries
The canonical persisted account inventory is `[[llm.providers]]`, selected by optional `[llm] default_provider_profile`, with one stable id per account and an ordered nested `models` inventory; canonical provider maps and all nested maps use STRING keys while the surrounding resolved config uses atom schema keys.
Provider profiles share provider/auth/endpoint/concurrency/peak fields, generation defaults and an ordered `reasoning_efforts` inventory; nested model maps may override generation/context/effort settings, and `default_model` plus optional `default_reasoning_effort` choose defaults without inventing an effort from inventory order.
`Normalization.atomize_enum_values/1` stringifies the full providers subtree through `Schema.ProviderProfiles.Normalize.stringify/1` and canonicalizes its effort fields, preserving malformed entries for validation rather than silently dropping them.
Legacy `[[llm.models]]` and flat `[llm] model` remain accepted and retain their in-memory normalization/save behavior when no nonempty providers list exists.
`Schema.provider_profiles/1` exposes canonical string-keyed profiles and migrates legacy accounts one-for-one without combining equal provider/model/endpoint accounts or changing ids; this read projection does not rewrite files.
`Schema.model_selections/1` enumerates ordered model/effort inventory without resolving credentials or metadata, and `Schema.resolve_selection/2` (with `resolve_model_spec/2` as its alias) resolves a nil/default, provider id, or explicit provider/model/effort selection through `Schema.ProviderProfiles`.
Canonical providers are authoritative over stale legacy fields, and resolution does not materialize their derived `llm.models`/flat mirrors; saving a config with nonempty providers strips legacy `models`, flat generation/model fields and flat auth/provider-options mirrors, retaining providers + default selector as the sole persisted inventory.
Key normalization for legacy model maps uses existing atoms only, with `@model_profile_extra_keys` pinning otherwise-unreferenced allowed atoms.
`Schema.validate/1` appends `ProviderProfileValidation.cross_field_errors/1` after descriptor validation, requiring an explicit `llm.default_provider_profile` to match an id in a nonempty canonical providers list: an absent/nil selector is valid, an unknown id reports `%ValidationError{key_path: [:llm, :default_provider_profile], rule: {:in, configured_ids}}`, blank selectors report `:string` errors and non-string selectors retain the descriptor's single type error. The check reads raw atom- or string-keyed provider ids rather than normalized profiles and never hides malformed-row errors.
`ProviderProfileValidation.default_model_errors/4` checks each account's raw `default_model` against its model inventory, accepting absent/nil and matching provider-qualified names, rejecting unknown names with `{:in, ids}` and blank/non-string values with `:string` errors at `[:llm, :providers, index, :default_model]`.
Runtime normalization can repair blank/non-string account defaults and treats a global `false` selector as absent, but raw schema validation still rejects those inputs, so `config_status/0` reports `ok?: false` even if another account supplies a model and credentials; the returned validation errors, not `missing == []`, are authoritative for that failure.
`Schema.effective_model_profiles/1` delegates to `Schema.LLM.effective_model_profiles/1` for scheduler boot, reload and catalog warm-up and does not fall back to stale flat settings when a configured canonical inventory has no usable runtime profiles; presence/OAuth diagnostics use `Schema.model_profiles/1`'s runtime projection.
For a canonical API-key account's explicit `api_key_env_var`, health checks accept a nonempty environment string first, then a nonempty `Config.credentials/0` string under that exact name, without catalog-key fallback or borrowing another same-provider account's custom key; OAuth accounts never use this path.
The single reasoning-effort ladder is `Schema.ReasoningEffort`: `levels/0` → `[:none, :minimal, :low, :medium, :high, :xhigh]`, `options/0` adds `:default` (send no effort at all), `allowed?/1` is the total acceptance predicate, `canonical/1` the total normalizer (`nil` for anything unrecognized) and `convert/1` its documented ECHO (an unknown value comes back unchanged so validation can report it).
`max` is an accepted legacy ALIAS normalized to `xhigh` on read and is NEVER an offered level: `Normalization.atomize_enum_values/1` canonicalizes every effort site (trim + downcase + `max` → `xhigh`) — the flat `[:llm, :reasoning_effort]`, each account's `reasoning_effort`/`default_reasoning_effort`/`reasoning_efforts[]` and every nested `models[*]` equivalent — while `ProviderProfiles.Normalize.string_effort/1` does the same when resolving a profile; an UNKNOWN effort value is left untouched so validation still reports it.
`[:llm, :reasoning_effort]` carries `validation: [in: <canonical option strings>]`, so `Config.save_user_config/1` (which validates the RAW map it was handed) rejects a literal `"max"`/`" High "`, whereas the snapshot build and `Config.update/1` canonicalize first, so `" High "` loads as `"high"` and a persisted `"max"` reads as `"xhigh"`.
Detailed generation/auth/reasoning assembly, selection error contracts and compatibility traps: `schema/CONTEXT.md`.

## LLM Model Presence Decision (config_status `:llm_model` gate)

`config_status/0` reports `missing: [:llm_model]` plus the warning "LLM model is not configured. Set [llm] model in config.toml." when NO model profile carries a usable model.
The predicate runs over `Schema.model_profiles(resolved)` (ALL profiles): a profile counts as configured when its `:model` is a non-empty binary OR a valid map model spec (non-empty map with non-nil `:provider` and a non-empty binary `:id`) — nil, `""` and `%{}` all fail.
**Validation asymmetry**: per-profile `:model` validation treats `nil` as an error but accepts ANY binary, so `""` passes `Schema.validate` yet still fails this gate — such a profile yields `validation_errors: []` plus `missing: [:llm_model]`; the flat `[:llm, :model]` spec is equally lax. This gate is the ONLY place empty strings are rejected; a missing `:llm` section / `llm.models = []` / flat nil model produce NO validation error — the warning is the sole signal, by design.
**Map-model profiles with override keys pass**: a custom-endpoint map model (e.g. `%{provider: :openai_compatible, id: "x", base_url: "..."}`, kept as a map whenever `base_url`/other override keys are present) counts as configured, matching SystemCheck/ReqLLM acceptance.
**Legacy mirror rule (`migrate_llm_models/1`)**: when no canonical providers are configured, the flat `[llm] model` is mirrored ONLY from the FIRST legacy profile — if that profile has no/nil model the flat field stays nil even when later profiles carry valid models, so consumers reading `resolve([:llm, :model])` see nil; a first-profile `""` mirrors as `""`, and canonical configs synthesize no flat mirror.
**Disk shape after save**: with a nonempty providers list, `save_user_config/1` strips legacy `llm.models` and flat model/generation/auth/provider-options mirrors so only the canonical inventory persists; for legacy-only configs the same path preserves `[[llm.models]]` and strips flat generation/model fields only when that list is nonempty. `stringify_keys/1` drops nil values at every map level, so legacy nil-model profiles round-trip without a model key.

## OAuth / Subscription Auth
Subscription (OAuth) auth spends an existing ChatGPT/Claude login instead of a per-token API key; the ONLY credential store is the managed file (the profile's `oauth_file`, default `<config_dir>/auth.json`) — ReqLLM-native JSON keyed by provider OAuth id (`"openai-codex"` / `"anthropic"`), entries `type`/`access`/`refresh`/`expires`(ms)/`accountId` — and `credentials.toml` never carries OAuth data.
- **Path precedence** (`Schema.LLM.oauth_file_for/1`): `opts[:oauth_file]` (explicit argument) → the profile's `oauth_file` → `EvoGit.Auth.default_oauth_file/0` (`<config_dir>/auth.json`, resolved through `EvoGit.Platform.config_dir/1` so the `:config_dir_fun` seam applies); a leading `~` is expanded and a broken managed-file read degrades to the default. There is NO global `[llm] oauth_file` config key.
- **Catalog auth metadata** (`EvoGit.Config.LLMCatalog`): each provider entry carries `auth_modes` (default `[:api_key]`), `oauth_source`, `provider_atoms` and `credential_key`, with accessors `auth_modes/1`, `oauth_source/1`, `oauth_only?/1` and `supports_oauth?/1`; `:openai_codex` ("ChatGPT Subscription", `oauth_source: :chatgpt`) is OAuth-ONLY, `:anthropic` is `[:api_key, :oauth]` with `oauth_source: :claude_code`, and every other provider is API-key only.
- **Which profiles are OAuth** (`Schema.LLM.oauth_profile?/1`): `auth_mode == :oauth`, OR the provider is `oauth_only?` — so `model = "openai_codex:gpt-5.6-terra"` needs no `auth_mode` at all.
- **What reaches the request** (`Schema.LLM.profile_generation_params/1`): an OAuth profile gains `provider_options: [auth_mode: :oauth, oauth_file: <resolved>]`, overridden key-wise by explicit profile `provider_options`; the three-level precedence lives in `schema/CONTEXT.md`.
- **Credentials**: Anthropic OAuth uses the lazy vendor import into its configured managed file; ChatGPT Subscription uses the protected Genesis SIWC registration identified by `siwc_account`, resolved at request time, and existing `openai_codex` identifiers continue through the SIWC adapter.
- **Env fallback**: `CLAUDE_CODE_OAUTH_TOKEN` (then `ANTHROPIC_OAUTH_TOKEN`) is honoured for `:anthropic` when no file credential exists — OAuth without refresh, never written to disk; `:openai_codex` has no env fallback.
- **`known_credential_keys/0` auth-mode filter**: a provider entry contributes its `credential_key` only when `:api_key` is in its `auth_modes`, so an OAuth-only provider can never make `api_key_present?/1` report a configured key; variant keys stay unconditional.
- **Health (`config_status/0`)**: the `:api_key` check passes when `api_key_present?(credentials())`, an API-key account's exact custom `api_key_env_var` resolves from the environment or persisted credentials, OR a configured OAuth profile's credential resolves (`Schema.LLM.oauth_credential_status/1`, which imports first and degrades to "not configured" on a broken file). When it fails AND OAuth profiles exist, the warning names the OAuth providers, their `login_instructions/1` text and the per-profile managed file(s) resolved by `oauth_file_for/1` ("Managed OAuth file: <path>", or a plural form when profiles differ; `EvoGit.Auth.default_oauth_file/0` when none resolves); a config with no OAuth profile keeps the generic "No API key found. Add keys to credentials.toml or configure via the settings page." An OAuth profile reporting `{:error, {:managed_file_unwritable, reason}}` (the login exists but the managed copy cannot be written — read-only home, Nix sandbox) instead gets `EvoGit.Auth.managed_file_unwritable_remedy/2`'s actionable text and the misleading "run the vendor login" instructions are omitted.
- **Onboarding**: the dashboard's Welcome setup and Settings → LLM provider-profile editor ask an OAuth-capable provider for an auth mode ("API key" vs "Subscription (OAuth)"), skip the question for an OAuth-only provider and never prompt for an API key on the OAuth path — the saved account gets `auth_mode = "oauth"`, the API-key path writes none and clears a stale one, and `credentials.toml` never carries OAuth data; `EvoGit.SystemCheck.do_llm_test/2` runs `ensure_profile_credentials/1` before its connection test and, for a `{:managed_file_unwritable, reason}` outcome, returns `{:error, "LLM connection test not run — <remedy>"}` WITHOUT issuing a request.

## Naming & Vocabulary (audit)

- **"Account" is spelled six ways**: the account id string is `profile["id"]` in `ProviderProfiles.provider_profiles/1`, `model_selections/1` and `resolve_selection/2` — the SAME value a task `model_spec` calls `provider_profile_id`; `[llm] default_provider_profile` is that id again, `provider_profile` in a resolution result is the whole account MAP, and bare `profile` means a legacy `[[llm.models]]` entry or a model-selection row.
- **`model_spec` in a resolution result is the ReqLLM identifier, not the task selection map**: `resolve_selection/2` returns the ReqLLM-ready qualified string or endpoint-override map under the `"model_spec"` key (dispatch stores it as `llm_model`), while a task-level `model_spec` is the STRING-keyed identity (`provider_profile_id` + `model` + optional `reasoning_effort`).
- **`model_id` names a legacy profile/account id in `context_window_for/2`** but a model identifier in `LLMConstraints`' table lookup and `ProviderProfiles.Normalize` — same parameter name, unrelated values.
- **`model_profiles` names both the raw legacy list and a resolved runtime projection**: `Schema.LLM.model_profiles/1` returns untouched `[[llm.models]]` entries for a legacy config but atom-keyed runtime profiles for canonical accounts, and the schema TYPE `:model_profiles` is the former only.
- **`id` carries three namespaces in one pipeline**: an account `id`, a model `id` selected from that account's inventory, and a model `id` inside the ReqLLM spec; `LLMCatalog` adds its own entry `id` (e.g. `:openai_compatible`).
- **`show/0` IS `resolve/0`**: `EvoGit.Config.show/0` and `EvoGit.Config.Settings.show/0` are one-line delegations; `show/1` differs only by accepting atom/dotted/list paths and returning `{:error, :invalid_path | {:unknown_setting, path}}` — two public names for one read.
- **`save_*` means REPLACE in one function and MERGE in the other**: `save_user_config/1` validates then REPLACES the whole file through `persist_user_config/1`, while `save_credentials/1` shallowly `Map.merge/2`s keys; `Config.update/1` → `Settings.update/1` is the partial patch path.
- **Two `canonical_providers?/1` implementations** remain — public `Normalization.canonical_providers?/1` and private `LLM.canonical_providers?/1` — but both read through `Keys.get/2`'s presence semantics, so they agree; the duplication, not a behavioural split, is what stays.
- **Tolerant key reads have ONE home**: `EvoGit.Config.Keys.fetch/2` and `get/2,3` own atom- OR string-keyed presence-based reads (`String.to_existing_atom/1` inside its one justified rescue) and never intern an atom, so `Normalization.get_key/2` is a one-line `Keys.fetch/2` delegation and the `LLM` / `LLMConstraints` / `ProviderProfiles` profile reads go through it — `LLM.profile_field/2`, `EctoValidation.profile_field/2` and `LLMConstraints.fetch_key/2` do not exist. `Schema.safe_get_in/2` is a different job (an atom-only schema key-path walk), and the remaining hand-rolled readers live outside this node: `PeakHourEngine.profile_field/2` (sibling `agent_scheduler/`) and `Settings.fetch_path/2` (the dotted/list path walk behind `show/1`).
- **Key stringification has ONE home**: `Keys.stringify/2` with the `drop_nils:` / `model_tuples:` / `keyword_lists:` policies serves `Config`'s save-side conversion, the credentials map and `ProviderProfiles.Normalize.stringify/1`; `CustomAgents.stringify_keys/1` keeps its own copy in the sibling `custom_agents/` node.
- **Atom-tolerant converters fail three different ways**: `Normalization.safe_atomize/1` keeps the string, `ProviderProfiles.existing_key/1` keeps the string, `LLM.existing_atom_key/2` drops the pair to `nil`; `LLM.provider_from_model/1` resolves a name through its compile-time known-provider whitelist (built from `LLMCatalog.providers/0`) and falls back to `String.to_existing_atom/1`, so it never interns an atom — hence a provider atom absent from the VM has no catalog metadata (`catalog_key/1` → `nil`), so model metadata and constraint filtering degrade (the constraint table and schema whitelist still work) and nothing raises.
- **`LLMCatalog` has two provider-lookup rules**: `find_provider/1` matches `provider_atoms` only while private `resolve_entry/1` matches the entry `id` first, so `provider_models(:openai_compatible)` is `[]` while `requires_base_url?(:openai_compatible)` is `true`.
- **`get_model_profile/2` and `default_model_profile/1` are `fetch_`-shaped under the wrong names** (`{:ok, _} | {:error, :not_found}`) and have no non-map clause, unlike their total siblings `model_profiles/1` and all of `ProviderProfiles` — two totality contracts in one module.
- **Account validation is split over three entry points in two directories**: `ProviderProfileValidation.errors/2` + `.cross_field_errors/1`, `EctoValidation.provider_profile_shared_errors/2` (`@doc false` but provider-profile-specific) and `Schema.validate/1`'s tail call, with `config/` and `config/schema/` aliasing each other in both directions.
- **`maybe_param/3` is public but internal-only** (with `@doc`/`@spec`, called only from `LLM.llm_generation_params/1`) and is the keyword twin of private `maybe_put/3`.
- Intentional distinctions that MUST stay: legacy `[[llm.models]].id` ≡ canonical account `id` (the one-for-one migration contract, `schema/provider_profiles_normalize.ex`); `model_spec` (selection identity) vs `llm_model` (ReqLLM-ready value); explicit `model_spec` vs unlocked `default_model_spec`; the `:openai` → `:openai_codex` auth-route rewrite (`schema/provider_profiles_normalize.ex`).
- The schema subtree's own copies of these findings: `schema/CONTEXT.md` → `## Known Issues`.

## Constraints
- **No config key caps TOTAL agents / live worktrees / subagent spawn breadth.** The full `Definitions.schemas/0` inventory contains NO `max_agents`/`max_worktrees`/`max_subagents`/breadth key. `[:scheduler, :max_agent_depth]` (default 8) is the ONLY structural limit and bounds recursion DEPTH only (`Subagents.validate_subagent_depth/3`); `spawn_validated_subagents/5` spawns EVERY validated spec via `Dispatch.register_agent/7` — no queue, no spawn cap, each with a FRESH worktree. The ONLY bound is worktree CREATE-pipeline concurrency: `WorktreeManager`'s bounded FIFO admission queue capped at the app env `:max_concurrent_worktree_creation` (default 4 — NOT a config.toml schema key; detail: `agent_scheduler/CONTEXT.md`), which never limits live worktrees/agents. Slot pools gate LLM/tool CALLS, not worktree creation; `State`'s `queue` is the resume FIFO for paused schedulers, not a worktree-count queue.
- `save_user_config/1` → `config.toml`; `save_credentials/1` → `credentials.toml`. Both create the config dir if needed.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- **`Config.resolve/0` and `Schema.validate/1` never read model metadata or the LLMDB catalog** — they are pure map work (merge → atomize → migrate → validate); the ONLY catalog reach in this subtree is `Schema.LLM.model_metadata/1` (`schema/CONTEXT.md` → "Model metadata seam"), so a memory or latency surprise attributed to config resolution is never catalog-related.
- Config dir follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads use `case File.read/1` (non-crashing) with explicit `with`/`case` handling — no `try/rescue`.
- Reads go through `EvoGit.Config.resolve/0,1` (the RAM snapshot); the only persisted writes are `save_user_config/1`, `save_credentials/1` and the partial `Config.update/1`, all of which delegate the actual `config.toml`/`credentials.toml` write to `@doc false Config.persist_user_config/1` / `save_credentials/1` and then refresh the snapshot through `Watcher.notify_change/1`.
- **Model format**: `"provider:model"` string (preferred; resolves through LLMDB for cost tracking) OR map spec `%{provider: atom, id: string, base_url: string, extra: %{...}}` (ReqLLM-native). Map specs are normalized at resolve time (`normalize_model_map/1` in `atomize_enum_values/1`): simple models (only `:provider`+`:id`) → `"provider:id"` strings; models with override keys stay as atomized maps. `[[llm.models]]` supports multiple endpoints per provider+model via per-profile `base_url`, and the provider atom determines which API key env var is used.
- `config_status/0` checks: LLM model presence + at least one API key. GitHub username **optional** — a missing username does NOT appear in `:missing`/`:warnings` nor make `:ok?` false.
- **Crash resilience (untrusted user config boundary)**: the `resolve/0` → `config_status/0` pipeline MUST NEVER raise on user-provided content (incl. valid TOML with wrong value types, e.g. `llm = "string"`). `deep_merge/2` discards type-mismatched values (keeping defaults); `migrate_llm_models/1`, `atomize_enum_values/1`, `Schema.model_profiles/1` and `Schema.validate/1` guard non-map structures; `Schema.validate/1` uses `safe_get_in` (not `get_in`) to avoid Access crashes. Bad config → `validation_errors`, never a crash — the user must always boot the app and reach the settings page.
- **Enum atomization gap for NEW top-level sections** — see "Adding a New Config Category" above (clause list + why atomization stays PRE-Ecto); the `:string` workaround is UI-only, since the dashboard `SettingCard` renders `:string` as free text unless special-cased (`reasoning_effort` precedent).
- **Shared `@doc false` helpers (anti-duplication homes)**: `EvoGit.Config.Schema.safe_get_in/2` — safe nested key-path lookup that NEVER raises on non-map intermediates (unlike `get_in`/Access); `EvoGit.Config.ensure_trailing_newline/1` — guarantees TOML content ends with a trailing newline before `File.write` (used by `save_credentials/1` and `version_state.ex`). Reuse rather than re-implement.

## Notes for Agents
The built-in defaults live in `EvoGit.Config.Schema.defaults/0` — a `deep_put` fold over every schema descriptor's `:default` — exposed publicly as `EvoGit.Config.defaults/0`; there is NO `EvoGit.Config.Defaults` module.
`EvoGit.Config.Schema.ReasoningEffort` is the ONE reasoning-effort ladder: `Normalization.atomize_enum_values/1`, `LLM`'s re-exports, `ProviderProfiles.Normalize.string_effort/1` and the wire alias table only consume its answer, so a new effort rule belongs there rather than in another copy.
Tolerant key reads and key stringification belong to `EvoGit.Config.Keys`; a new caller delegates instead of re-implementing.
The `config.toml` write half is `@doc false Config.persist_user_config/1` (serialize → write → notify), and only `save_user_config/1` (after validating) and `Settings.update/1` (after validating the normalized candidate) call it.
