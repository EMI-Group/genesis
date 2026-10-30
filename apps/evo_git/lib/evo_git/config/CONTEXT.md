# Config — Unified Configuration Resolver

## Intent
`EvoGit.Config` — single source of truth for non-project configuration: merges built-in defaults with user config (`~/.config/genesis/config.toml`), loads API keys from `credentials.toml` into ReqLLM's key store, persists user config changes, and diagnoses configuration completeness.

## Routing Table
- `./schema/` → config schema definitions (pure data: keys, types, defaults, validation) + provider/model generation-parameter extraction (`schema/CONTEXT.md`)

## API Surface

### `EvoGit.Config`
| Function | Description |
|----------|-------------|
| `resolve/0` | Merged config map (defaults + user config). Runtime overrides live in `AgentScheduler` state. |
| `resolve/1` | Resolved value for a key path (atom or list of atoms) |
| `user_config/0` | Parsed `config.toml`, or `%{}` if not found. `:persistent_term`-cached with `File.stat` mtime+size validation (see "Config Caching"). |
| `save_user_config/1` | Validates, then persists a config map to `config.toml` (creates the config dir); invalidates the cache on success. `:ok \| {:error, reason}` |
| `save_credentials/1` | Merges/persists an API key map to `credentials.toml`; sets keys via `ReqLLM.put_key` for immediate in-process use; invalidates cache. `:ok \| {:error, reason}` |
| `config_status/0` | Diagnostic map `:missing`/`:warnings`/`:ok?` from LLM-model + API-key presence; GitHub username is optional and NOT checked. |
| `credentials/0` | Reads `credentials.toml`, loads each key into ReqLLM's key store, returns the parsed map. Cached (`put_key` runs only on a cache miss). |
| `defaults/0` | Built-in defaults (scheduler concurrency/retry settings, empty llm/user maps, sandbox mode); three values are CPU-thread-derived (see Configuration Levels). |
| `config_path/0` | Full path to `config.toml` |
| `config_dir/0` | Platform config dir (XDG/macOS/Windows) via `EvoGit.Platform.config_dir("genesis")` |
| `credentials_path/0` | Full path to `credentials.toml` |
| `lsp_enabled?/0` | SINGLE gate for offering the `lsp` tool (see `[lsp]` below): `true` only when the resolved `[:lsp]` section is a map whose `:enabled` is `true`/`"true"` AND whose `:command` is a non-blank binary. Never raises (nil/non-map section, other enabled values, nil/non-binary/blank command → `false`). |

### `EvoGit.Config.LLMCatalog` (provider/model shortcuts)
| Function | Description |
|----------|-------------|
| `providers/0` | Predefined providers (Anthropic, OpenAI, Google, DeepSeek, ZAI, Alibaba, MiniMax, Moonshot AI (Kimi), xAI) with models |
| `provider_models/1` | Model shortcuts for a provider atom |
| `resolve_model/2` | `{provider_atom, model_input}` → `"provider:model"` string (backward-compat) |
| `resolve_model_spec/3` | Map analog: `%{provider: atom, id: string}` + optional `base_url`/`extra`. Opts `:base_url`, `:variant`, `:extra`. |
| `requires_base_url?/1` | Provider requires a custom `base_url` (flag; default `false`). `:openai_compatible` → `true`. |
| `find_provider/1` | Provider entry by atom (checks `provider_atoms`) |
| `unknown_provider_help/0` | Guidance text (llmdb.xyz + ReqLLM docs links) |
| `known_credential_keys/0` | All unique credential key names from the catalog |

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
- **Schema**: `[foreign_repos.<id>]` tables with `path` (REQUIRED — missing → entry dropped + `Logger.warning` "Failed to parse foreign_repos", `ProjectConfig.build_foreign_repo/2`) and `description` (optional). The TOML table key IS the id. **The key is `description`, NOT `name`** — a `name` key is silently ignored (only `"description"` is read; the `ForeignRepo` struct field is `:description`). No other keys (no `enabled`/opt-in flag): every entry is always loaded.
- **Committed to git**: `genesis.toml` is NOT git-ignored (the `.gitignore` Genesis auto-writes into new repos contains only `/.genesis`; the root `.gitignore` doesn't cover it) and Genesis Mode B auto-creates it via `ProjectConfig.write_worktree_script/2` — so absolute paths in `[foreign_repos]` are committed and wrong on any other machine.
- **Path handling**: nothing validates absolute paths, but they are semantically required — `ForeignRepo.new/3` only runs `EvoGit.Platform.safe_expand/1`: `~` → home, RELATIVE → the PROCESS CWD (CLI/dashboard cwd, NOT the repo root), and no `$VAR`/`${VAR}` expansion exists in `config.ex`/`project_config.ex`. No existence check at load or task start: a path missing on this machine flows into the agent's context table and fails only at delegation time (`build_subagent_phylo_node` hard-matches `{:ok, foreign_head} = Git.rev_parse(target_repo_root)` → MatchError on first delegation when no tracked commit exists).
- **`-R` CLI merge**: `Runtime.Helpers.merge_foreign_repos/2` normalizes both lists via `ForeignRepo.normalize/1` then `Map.merge(toml_map, cli_map)` — CLI wins per id, unparseable dropped; CLI can OVERRIDE but never REMOVE a genesis.toml entry. The dashboard's per-project in-memory list (loaded at project open; edits live only in socket assigns, never persisted) is passed per task via `runtime_opts[:foreign_repos]`. `ResumeContext` does NOT carry `:foreign_repos` on resume_from tasks (only `MergeContext` does) — resumed tasks re-get only genesis.toml repos.

### Worktree Init Script Environment Variables
| Variable | Description |
|----------|-------------|
| `SOURCE_REPO_PATH` | Main repository checkout path |
| `TARGET_WORKTREE_PATH` | Newly created worktree path |
| `SOURCE_WORKTREE_PATH` | Parent agent's worktree path (`SOURCE_REPO_PATH` for top-level agents) |

### Configuration Levels (priority low → high)
1. **Application defaults** — `defaults/0` (no model, no username). Three defaults are **dynamic** (computed at `Definitions.schemas/0` runtime): `[:scheduler, :max_tool_concurrency]` and both sandbox `:cpu_quota` values (`[:sandbox, :resources, :cpu_quota]`, `[:sandbox, :process, :cpu_quota]`) derive from `EvoGit.Platform.cpu_threads/0` (= `max(System.schedulers_online(), 1)`) — the tool cap equals the CPU thread count and each quota string is `"#{cores * 100}%"`. Living on the schema map itself, the value is shared by display, reset-to-default (dashboard) and resolution.
2. **User config** — `~/.config/genesis/config.toml` (XDG-compliant), parsed with `TomlElixir.decode/1`.
3. **Runtime overrides** — `AgentScheduler` GenServer state via `handle_call({:update_config, opts})`; set by dashboard settings / `RemoteAPI.reload_config` (the CLI makes NO scheduler overrides — concurrency/retry/turn values are config.toml-only, and `-m` is task-level model selection carried in task opts, not a scheduler override).

### config.toml Structure
**`[data] dir` relocates the runtime data dir** (which holds `tasks.sqlite`, logs, remote binaries, nix cache, `genesis-source`) — see `[data]` below.
`EvoGit.Platform.data_dir/0` consults `EvoGit.Config.resolve([:data, :dir])`: a non-empty absolute (or `~`-expanded home-relative) value is returned; invalid values (nil / empty / non-binary / relative) log a `Logger.warning` and fall back to the OS + env default via `base_dir("genesis", "XDG_DATA_HOME", ".local/share")`. It NEVER raises (called from sandbox/agent contexts where crash-resilience is a hard constraint).
**Precedence chain**: TaskRegistry `opts[:data_dir]` test seam → app env `config :evo_git, :data_dir` (honored ONLY where `Application.get_env(:evo_git, :data_dir, ...)` is read — the Store child spec, `TaskRegistry.init/1`, `mix migrate.store`; set only in `config/test.exs`) → TOML `[data] dir` → XDG platform default (env `XDG_DATA_HOME` (Linux) / `APPDATA` (Windows) / `HOME` (fallbacks); `XDG_CONFIG_HOME` drives the config dir). Direct `Platform.data_dir()` consumers — the desktop log path, `SelfReflectiveSource` genesis-source clone, `RemoteBootstrap` remote_binaries cache, `Sandbox.Nix` cache — honor the TOML override too (ignoring only the app-env override). Per-repo `.genesis` artifacts (agent worktrees at `<repo_root>/.genesis/workers`) stay repo-root-fixed, NOT relocatable via `[data] dir`.
**Boot ordering**: config.toml IS parsed before the Store child spec's data-dir computation — `EvoGit.Config.resolve()` runs unconditionally in `config/runtime.exs` (release boot, before any app starts, in every release incl. `genesis_remote`) and again inside `EvoGit.Application.start/2` via `EvoGit.Distribution.maybe_enable/0`, so `[data] dir` is readable when the Store child spec evaluates `Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())`. The config file's own location never depends on the data dir (`Config.config_path/0` → `Config.config_dir/0` → `EvoGit.Platform.config_dir("genesis")`, a separate `base_dir` call keyed on `XDG_CONFIG_HOME`), so the override creates no chicken-and-egg.
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

**`[[llm.models]]` profile fields**: `id` (required), `model` (required), `concurrency` (per-profile LLM concurrency), `context_window` (optional positive integer, default `200_000` — the model's context window in tokens, used as the context-compression window), plus optional `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days`:
```toml
[[llm.models]]
id = "deepseek"
model = "provider:model"       # same format as [llm] model
concurrency = 4                # normal (off-peak) concurrency
context_window = 200000        # optional — context window in tokens (default 200000)
peak_concurrency = 0           # optional — concurrency during peak windows (0 = hard pause)
peak_hours = [                 # optional — daily windows; local wall clock unless `timezone` set
  { start = "09:00", end = "12:00", days = ["mon", "tue", "wed", "thu", "fri"] },
  { start = "14:00", end = "18:00", days = "weekdays" }   # keyword = mon-fri
]
timezone = "Asia/Shanghai"     # optional — IANA tz for this profile's peak windows
off_peak_days = ["sat", "sun"] # optional — entire day off-peak: normal concurrency 24/7
```
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
- **Not every extracted key reaches the wire**: `top_k`/`reasoning_effort` are accepted ReqLLM options, but the Z.AI family encodes neither (`Zai.Shared.add_basic_options/2` emits only `temperature`, `top_p`, `frequency_penalty`, `presence_penalty`, `user`, `seed`, `stop`; `reasoning_effort` is telemetry-only there), while the OpenAI chat-completions path DOES emit `reasoning_effort`. `stream_options: %{include_usage: true}` is emitted unconditionally on EVERY streamed chat call by req_llm's encoders; it is not an accepted ReqLLM option (passing it raises `NimbleOptions.ValidationError`) and streaming cannot be turned off, so it is NOT suppressible from the config layer.

**`[sandbox] backend`**: `:atom` schema key, default `:auto`, validation `[in: [:auto, :systemd, :bwrap]]`. `:auto` tries systemd-run → bwrap → no sandbox (macOS always uses sandbox-exec; bwrap is Linux-only). `:systemd` forces systemd-run (no sandbox if systemd unavailable). `:bwrap` forces bubblewrap — filesystem isolation only, no resource limits; falls back to no sandbox if `bwrap` is unavailable. **`[sandbox.resources]`/`[sandbox.process]` are systemd-only, ignored with bwrap.** String values are atomized by `atomize_enum_values/1` before `Schema.validate`.

**`[sandbox] write_paths`**: `:list_of_strings` schema key, default `nil`. nil → sandbox backends use platform-default writable paths; set (incl. `[]`) → REPLACES the built-in list (`[]` disables those writable paths entirely). Non-list/non-string-list → validation error (never crash). Consumed by `EvoGit.Sandbox.Linux.args/4` + `EvoGit.Sandbox.MacOS.generate_profile/2` via `EvoGit.Config.resolve([:sandbox, :write_paths])`: nil → the default cache-dir list; set → replaces the built-in cache-dir list only; `~`-prefixed entries expand to `System.user_home!()`, absolute as-is, relative joined to `$HOME`. Structural paths (cwd, tmp, nix store, repo `.git`) are always appended; deny lists are never affected. Details: `sandbox/CONTEXT.md`.

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

**The one non-additive gap is the READ/resolve path**: TOML has no atoms, and string enum values are atomized ONLY by `atomize_enum_values/1`, whose HARDCODED per-category clauses cover `:sandbox` (`:mode`/`:backend`), `:git` (`:cow_worktree_creation`), `:llm` (model normalization), `:tools` (search provider + per-provider `search_depth`, via `search_providers/0`) and `[tmp]` (`:mode`). The `:tools` clause touches ONLY `[:tools, :search, :provider]` and `[:tools, :search, <provider>, :search_depth]`, so a NEW atom-typed key under `:tools` needs its own handling (or `type: :string` + `validation: [in: [...]]`). A NEW `:atom`-enum key (e.g. `[appearance] accent = "blue"`) needs a matching clause (or `:string` typing + atomization at the consumption point, like `[:llm, :reasoning_effort]`); without it every `resolve/0` logs `must be an atom, got "blue"` and `config_status/0` reports it (non-fatal — the value just stays a string). The dashboard save path is unaffected: `SettingsUtils.parse_atom/2` (evo_dash) converts `:atom` form values against `validation[:in]` BEFORE `Schema.validate`, so saves round-trip through TOML as quoted strings — read-side atomization is the only gap.

Dashboard-side requirements for a new schema-driven category (evo_dash, not core): `category_display_name/1`, `category_icon/1`, `category_description/1` clauses in `EvoDashWeb.SettingsComponents.CategoryMetadata` (no catch-all — a missing clause = FunctionClauseError in the sidebar/header) plus an entry in its `sort_categories/1` order list (missing = sorts last). `:agents`/`:remote_connections` are NOT core categories — the dashboard injects them as empty-schema pseudo-categories rendered by dedicated inline UI branches.

## Validation Engine — Ecto-backed (architecture)

The scalar/rule validator beneath the DSL is **Ecto-backed, but Ecto is a VALIDATOR ONLY** — no `Ecto.Changeset` is ever built, `apply_changes` is never called, and the validated map passes through unchanged on `{:ok, config}` (unknown keys survive, model profiles stay plain maps).

- **`EctoTypes`** (`ecto_types.ex`) — eight nested strict `use Ecto.Type` modules (`PosInteger`, `NonNegInteger`, `Integer`, `String`, `ListOfStrings`, `Float`, `Atom`, `Boolean`), one per scalar DSL type; public `type_for/1` (scalar type → fully-qualified module), `cast/2` (`Ecto.Type.cast(type_for(t), v)` — no base-type coercion) and `valid?/2`. They are **strict decision oracles**: no numeric-string coercion (`"3"` fails integer types), `""` is meaningful (never stripped), `:float` accepts int-or-float, `:atom` never casts strings.
- **`EctoValidation`** (`ecto_validation.ex`) — error adapter + composite recursion; `errors_for(key_path, type, validation, value) :: [%ValidationError{}]` returns type errors FIRST then rule errors. All window/day/timezone math **delegates to `EvoGit.PeakHours`** (`validate_windows/1` / `validate_timezone/1` / `validate_days/1`); `min`/`max`/`in` stay hand-written pure predicates (Ecto's `validate_number`/`validate_inclusion` are banned by design). Message sentences, `value`/`rule` terms, sub-path key_paths and error ordering are **byte-pinned** by the `schema_test.exs` / `config_test.exs` suites.

**Delegation path**: `Schema.validate/1` keeps its map-walk + `safe_get_in/2` and calls `EctoValidation.errors_for/4` per present value; scalar decisions route through `EctoTypes.valid?/2` (→ `Ecto.Type.cast` → module `cast/1`). Composite types (`:model_spec`, `:model_profiles`) and the optional profile fields (`peak_concurrency`, `peak_hours`, `timezone`, `context_window`, `off_peak_days`) recurse explicitly (multi-error, sub-path-aware), with scalar leaves through `EctoTypes` where a matching type exists (e.g. `peak_concurrency` → `EctoTypes.valid?(:non_neg_integer, v)`, rule preserved as `:integer`).

**What stays hand-written (and why)**: Ecto has no TOML story and the pipeline runs on variable-depth maps with byte-pinned shapes, so the **transform pipeline stays in `config.ex`** — `deep_merge`, `atomize_enum_values` (atomization stays PRE-Ecto: Ecto validates atoms, never produces them), `migrate_llm_models`, and save serialization (`strip_flat_llm_fields`, `stringify_keys`, `TomlElixir`). `Schema.defaults/0` stays a hand-written `deep_put` from each descriptor's `:default` (byte-identical output, 102 entries — per-category breakdown in `schema/CONTEXT.md`). `config.ex` calls `Schema.validate/1` as before (oracle in `resolve/0` via `Process.put(:evo_git_config_validation_errors, ...)`; validate-first in `save_user_config/1`).

**Ecto quirk handling**: (a) numeric strings fail number types — the custom `cast/1` modules never coerce; (b) `""` is never stripped; (c) unknown keys survive — Ecto is oracle-only; (d) no `Ecto.Enum` — atomized categories validate as atoms, so a bad enum string that survived `atomize_enum_values` surfaces as a *type* error (`rule == :atom`), never an `in:` error; (e) `Ecto.Type.cast(_, nil)` → `{:ok, nil}`, matching nil ≡ absent (absent keys are skipped by `safe_get_in` before `errors_for` runs); (f) `EctoTypes.type_for/1` must return **fully-qualified** module atoms (`__MODULE__.PosInteger`) — a bare `PosInteger` before its nested `defmodule` would not be alias-expanded and Ecto's runtime dispatch would fail.

**Deliberate exclusions (NOT Ecto-validated)**: `LLMCatalog` (static catalog), `VersionState` (self-validating TOML file), `credentials.toml` (free-form keys), `ProjectConfig`/`genesis.toml` (per-repo, lenient by design), `CustomAgents`/`agents.toml` (own CRUD validation), `RuntimeOpts` (task-opts contract, raises `ArgumentError`). Only the `config.toml` DSL (the 102 `Definitions.schemas/0` entries) is Ecto-validated.

## Config Caching

`user_config/0` and `credentials/0` cache **parsed TOML maps** in `:persistent_term` keyed by file path, storing `{mtime, size, parsed_map}` (private `cached_file_read/2`).

- Every call runs `File.stat/1`: matching mtime AND size → cached map; else read + TOML-decode + store; `{:error, _}` (missing/unreadable) → `%{}` with no warning log.
- **Per-path keys** (`{EvoGit.Config, :file_cache, path}`): tests flipping `XDG_CONFIG_HOME`/`APPDATA` resolve different paths → no staleness (stale old-path entries linger harmlessly).
- **Explicit invalidation**: `save_user_config/1`/`save_credentials/1` erase their path's entry after a successful `File.write` (covers coarse-mtime filesystems + same-second same-size rewrites).
- **External-edit freshness**: the mtime+size check picks up external edits on the next call — this is what lets `RemoteAPI.reload_config/0` → `Config.resolve/0` observe fresh disk content, including remote/SSH reloads.
- **Parse-failure edge**: on read/decode failure `read_toml_file/3` logs a warning and returns the default, which IS cached with the current stat — the warning isn't re-emitted until the file changes.
- **`credentials/0` shares the mechanism** (separate path key): the cache stores the post-`put_key` result, so `ReqLLM.put_key` side effects run only on an actual file read; `save_credentials/1` also sets them explicitly.
- **Documented limitation**: a same-second + same-size external rewrite on coarse-mtime filesystems may be missed (theoretical — ext4/APFS/NTFS have ns granularity).

**NOT cached:**
- **The `resolve/0` pipeline** (deep_merge → atomize_enum_values → migrate_llm_models → Schema.validate) runs on EVERY call — its side effect `Process.put(:evo_git_config_validation_errors, ...)` is read by `config_status/0` from the **calling process's** dict; caching would break validation-error propagation.
- `defaults/0` — cheap (a `deep_put` fold; three values read off `EvoGit.Platform.cpu_threads/0` at call time).
- `read_toml_file/3` itself (`@doc false`) — `project_config.ex`/`remote_connections.ex` use it for `genesis.toml`/`remote_connections.toml`, which must stay fresh.

`config_status/0` truthfulness: it calls `resolve()` + `credentials()` per invocation and the cache only serves stat-matched content, so `:missing`/`:warnings` reflect current on-disk state.

**Two-level caching — disk cache vs scheduler state:**
- The ACTUAL runtime config cache is the **`AgentScheduler` GenServer state**: `RemoteAPI.get_config/0` reads it (resolved at boot / last reload); `reload_config/0` re-reads disk via `Config.resolve()` and replaces it; `get_config_status/0` re-reads disk per call for truthful `:missing`/`:warnings`/`:ok?`.
- `save_user_config/1` does NOT auto-reload scheduler state — the dashboard (SettingsLive) calls `reload_remote_config` but IGNORES its return → a silent stale-config window until a manual reload.
- `RemoteConnections` does NOT auto-create an empty `remote_connections.toml` (unlike the config skeleton) — the file appears only when a target is saved.

## Test Seam — per-process config dir (`:config_dir_fun`)

- `EvoGit.Platform.config_dir/1` consults the app-env seam `:evo_git, :config_dir_fun` at CALL time before the XDG resolution.
- The seam accepts a zero-arity fun or an `{m, f, a}` tuple; the result must be a non-empty binary (garbage falls through to the production default, no `try/rescue`).
- It is **default-inert**: production never sets `:config_dir_fun`, so production paths are byte-identical to the XDG/APPDATA/Library resolution.
- `test/test_helper.exs` installs `{EvoGit.TestSupport.ConfigDir, :resolve, []}` (compiled from `test/support/config_dir.ex`).
- Helpers: `resolve/0` (own process dict → `$callers` pids on the local node → `nil`), `activate/1` (put in the calling process, e.g. from `setup`), `isolate_module!/1` (`setup_all`; unique tmp dir + `on_exit` cleanup, no process dict) and `isolate!/1` (`isolate_module!/1` + `activate/1`).
- `$callers` reaches `GenServer`/`Task`/`Supervisor` children started FROM the test process (OTP 24+ `proc_lib`), NOT boot-time singletons (`AgentScheduler`, `TaskRegistry`, `Store`, `PeakHourEngine`) — a module reading config inside those must stay `async: false`.
- The `:persistent_term` file cache is keyed by path, so a unique dir per test is cache-safe.

## Web Search Provider Config

Web search (`[tools.search]`) supports providers `[:tavily, :perplexity, :exa, :bing, :brave]`. The **single source of truth** for that list is `EvoGit.Config.Schema.Definitions.search_providers/0` (module attribute `@search_providers`) — do NOT hardcode it elsewhere. It feeds BOTH the schema `in:` validation (`[:tools, :search, :provider]`) and `EvoGit.Config.atomize_enum_values/1`, which atomizes `provider` and each provider section's `search_depth` against `[:basic, :advanced]` via that accessor. `tools_search_enabled?/0` is provider-generic: it resolves the SELECTED provider's own `api_key_credential_key` (with a tavily fallback).

## LLM Model Presence Decision (config_status `:llm_model` gate)

`config_status/0` reports `missing: [:llm_model]` + the warning "LLM model is not configured. Set [llm] model in config.toml." when NO model profile carries a usable model. The predicate runs over `Schema.model_profiles(resolved)` (ALL profiles): a profile counts as configured when its `:model` is a non-empty binary OR a valid map model spec (non-empty map with non-nil `:provider` and a non-empty binary `:id`) — **nil, empty-string and empty-map `%{}` models all fail the gate**. `config_status/0` calls `resolve()` first in its own process, so its results reflect a fresh stat-validated disk read in the calling process (never another process's `Process.get(:evo_git_config_validation_errors, [])`, set/deleted only by `resolve/0`).

**Validation asymmetry**: per-profile `:model` validation (`EctoValidation.validate_model_profile/2`) treats `nil` as an error ("profile must have a 'model' field") but accepts ANY binary — **`""` passes `Schema.validate`** yet still fails the `config_status` gate, so such a profile yields `validation_errors: []` plus `missing: [:llm_model]`. The flat `[:llm, :model]` `:model_spec` validation is equally lax (any binary accepted). `config_status`'s check is the ONLY place empty strings are rejected; a missing `:llm` section / `llm.models = []` / flat nil model produce NO validation error — the `:llm_model` warning is the sole signal, by design.

**Map-model profiles with override keys pass the gate**: a custom-endpoint map model (e.g. `%{provider: :openai_compatible, id: "x", base_url: "..."}` — kept as a map by `normalize_model_map/1` whenever `base_url`/other override keys are present) counts as configured, matching SystemCheck/ReqLLM acceptance.

**Mirror rule (`migrate_llm_models/1`)**: the flat `[llm] model` is mirrored ONLY from the FIRST profile; if that profile has no/nil model the flat field stays nil even when later profiles carry valid models, so consumers reading `Config.resolve([:llm, :model])` (flat) rather than `Schema.model_profiles/1` see nil. A first-profile model of `""` mirrors as `""`.

**Disk shape after save**: `save_user_config/1` validates first, then `strip_flat_llm_fields/1` deletes the flat `[llm]` keys (`model, temperature, max_tokens, reasoning_effort, top_p, top_k, frequency_penalty, presence_penalty`) from the written TOML **only when `llm.models` is a non-empty list** — a profile-based config therefore has NO `[llm] model = ...` line on disk; the flat value reappears purely as a resolve-time mirror. `stringify_keys/1` drops nil values, so a nil-model profile round-trips without a `:model` key.

## Constraints
- **No config key caps TOTAL agents / live worktrees / subagent spawn breadth.** The full `Definitions.schemas/0` inventory contains NO `max_agents`/`max_worktrees`/`max_subagents`/breadth key. `[:scheduler, :max_agent_depth]` (default 8) is the ONLY structural limit, and it bounds recursion DEPTH only (`Subagents.validate_subagent_depth/3`: reject when `parent.depth + 1 > state.max_depth`). `spawn_validated_subagents/5` spawns EVERY validated spec via `Dispatch.register_agent/7` — no queue, no spawn cap; each gets a FRESH worktree (`Dispatch.try_dispatch` → `WorktreeManager.create_worktree_for_agent/6`). The ONLY bound is worktree CREATE-pipeline concurrency: WorktreeManager's bounded FIFO admission queue capped at `:max_concurrent_worktree_creation` (app env, default 4 — NOT a config.toml schema key; detail: `agent_scheduler/CONTEXT.md`), which never limits live worktrees/agents. Slot pools gate LLM/tool CALLS (indirectly the rate), not worktree creation; `State`'s `queue` is the resume FIFO for paused schedulers, not a worktree-count queue.
- `save_user_config/1` → `config.toml`; `save_credentials/1` → `credentials.toml`. Both create the config dir if needed.
- Does NOT depend on `AgentScheduler` — runtime overrides are managed separately.
- Config dir follows XDG conventions via `EvoGit.Platform.os()`.
- All file reads use `case File.read/1` (non-crashing) with explicit `with`/`case` handling — no `try/rescue`.
- All config access should go through `EvoGit.Config.resolve/1`.
- **Model format**: `"provider:model"` string (preferred; resolves through LLMDB for cost tracking) OR map spec `%{provider: atom, id: string, base_url: string, extra: %{...}}` (ReqLLM-native). Map specs are normalized at resolve time (`normalize_model_map/1` in `atomize_enum_values/1`): simple models (only `:provider`+`:id`) → `"provider:id"` strings; models with override keys (`:base_url`, `:extra`) stay as atomized maps. Both are LLMDB-compatible; string specs pass through as-is. `[[llm.models]]` supports multiple endpoints per provider+model via per-profile `base_url`. The provider atom determines which API key env var is used.
- `config_status/0` checks: LLM model presence + at least one API key. GitHub username **optional** — a missing username does NOT appear in `:missing`/`:warnings` nor make `:ok?` false.
- **Crash resilience (untrusted user config boundary)**: the `resolve/0` → `config_status()` pipeline MUST NEVER raise on user-provided content (incl. valid TOML with wrong value types, e.g. `llm = "string"`). `deep_merge/2` discards type-mismatched values (keeping defaults); `migrate_llm_models/1`, `atomize_enum_values/1`, `Schema.model_profiles/1` and `Schema.validate/1` guard non-map structures; `Schema.validate/1` uses `safe_get_in` (not `get_in`) to avoid Access-behaviour crashes. Bad config → `validation_errors`, never a crash — the user must always boot the app and reach the settings page.
- **Enum atomization gap for NEW top-level sections** — see "Adding a New Config Category" above: `atomize_enum_values/1` is a MANUAL reduce with clauses ONLY for `:sandbox` (`mode`/`backend`), `:git`, `:llm`, `:tools`, `:tmp`, so a new `:atom`-typed key needs its own clause (or `type: :string` + `validation: [in: [...]]`); without it the raw TOML string fails the `:atom` type check and lands in validation errors, and keys under an existing atomized category are covered only if its clause atomizes the whole category map. The `:string` workaround is UI-only (the dashboard `SettingCard` renders `:string` as free text unless special-cased — `reasoning_effort` precedent).
- **Shared `@doc false` helpers (anti-duplication homes)**: `EvoGit.Config.Schema.safe_get_in/2` — safe nested key-path lookup that NEVER raises on non-map intermediates (unlike `get_in`/Access); use it for any nested schema-key read (`resolve/1`, `Schema.validate`, `tools_search_enabled?` already do). `EvoGit.Config.ensure_trailing_newline/1` — guarantees TOML content ends with a trailing newline before `File.write` (used by `save_credentials/1` and `version_state.ex`). Both are public and shared across `config.ex`/`schema.ex`/`version_state.ex` — reuse rather than re-implement.
