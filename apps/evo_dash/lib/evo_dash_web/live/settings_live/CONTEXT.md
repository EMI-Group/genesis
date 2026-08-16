# SettingsLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SettingsLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (five module files: `model_profile_helpers.ex`, `model_profile_events.ex`, `config_io.ex`, `search_events.ex`, `custom_agent_events.ex`).

## API Surface

### `EvoDashWeb.SettingsLive.ModelProfileHelpers` (`model_profile_helpers.ex`)

Pure data-transformation functions for model profile CRUD operations on the `[[llm.models]]` configuration list.

| Function | Purpose |
|----------|---------|
| `add_model_profile/2` | Adds a new model profile with a unique ID and default concurrency (3). **IDs are named after the model**: `generate_profile_id(models, base_name)` produces `<base>`, `<base>-2`, `<base>-3`, ... (suffix from 2, skipping existing ids); base is derived from `model_value` (string `"provider:model_id"` → part after first `:`; plain string → itself; map spec → `:id`; slugified downcase + non-alphanumeric runs → `-`); nil/empty/unusable base falls back to the `profile-N` scheme (draft flow — `add_model_profile(file_config, nil)` — keeps `profile-N` ids). `generate_profile_id/1` kept as a wrapper delegating to `/2` with nil base. |
| `update_model_profile/3` | Updates an existing profile's fields. |
| `replace_model_profiles/2` | Replaces all profiles in a category. |
| `mirror_model_profiles_by_provider/2` | Copies profiles from one provider to another. |
| `parse_model_profile_params/2` | Parses form params, composing ReqLLM-native map model specs (provider, id, base_url, extra). |
| `model_profile_collision?/3` | Checks for duplicate provider+model combos. |

All functions are pure — no I/O, no socket, no process calls.

### `EvoDashWeb.SettingsLive.ConfigIO` (`config_io.ex`)

Configuration I/O bridge between the Settings LiveView and the core runtime.

| Function | Purpose |
|----------|---------|
| `load_file_config/0` | Loads the full resolved user config via `EvoGit.Config.resolve/0`. |
| `build_config_from_category_params/2` | Converts category form params into a config map for persistence. |
| `list_of_strings_value/1` | Parses a submitted `:list_of_strings` form value: list → binaries with blanks filtered (so `[]`/blank-only round-trips as `[]`, NEVER treated as delete); any non-list → `:explicitly_empty` (the only delete signal — absent/nil params). Used by the `:list_of_strings` branch in `params_to_category_config/3`. |
| `update_runtime_from_file_config/2` | Accepts and returns a LiveView socket — pushes runtime config changes to `EvoGit.AgentScheduler`. |
| `build_whitelist/1`, `build_provider_whitelist/1` | Builds whitelist maps for safe untrusted-string-to-atom conversion (avoids `String.to_existing_atom/1` + `try/rescue`). |

Only `update_runtime_from_file_config/2` touches the socket — all other functions are pure.
### `EvoDashWeb.SettingsLive.CustomAgentEvents` (`custom_agent_events.ex`)
Event handlers for the Settings `:agents` category (custom agents + model-selection script — the per-node `agents.toml` file, NOT config.toml). All functions take a socket (+ params) and return a socket; all persistence goes through `EvoDash.NodeContext` (local node calls `EvoGit.CustomAgents` directly, remote routes `:erpc` via `EvoGit.RemoteNode`), and atom conversions use whitelist lookups (no try/rescue).
| Function | Purpose |
|----------|---------|
| `add_custom_agent/2` | Enters edit mode for a new agent (`"new"` sentinel `editing_agent_id`) |
| `edit_custom_agent/2` | Enters edit mode for an existing agent id |
| `cancel_edit_custom_agent/2` | Clears edit mode |
| `save_custom_agent/2` | Parses form params into an agent def (whitelisted `agent_type`/`delegation_level` atoms; optional int `max_turns`; nil-safe `tools`/`subagents` lists) → `NodeContext.save_custom_agent/2`; maps core error atoms (`:duplicate_id`, `:missing_name`, `:invalid_prompt`, ...) to gettext error flashes; reloads the list on success |
| `delete_custom_agent/2` | `NodeContext.delete_custom_agent/2` + reload |
| `save_model_selection_script/2` | `NodeContext.save_model_selection_script/2`; then reloads and surfaces the compile error (core returns `:ok` even for broken scripts — the error only appears via the reloaded `script_status`) |
| `test_model_selection_script/2` | Invalidates the script compile cache via `EvoDash.NodeContext.reload_custom_agents/1`, then evaluates `ModelSelector.select_model/1` on 3 sample attribute maps (depth-0 `EvoGit.Agents.Architect`, depth-2 `EvoGit.Agents.Executor`, custom agent `"my-agent"` at depth-1) through `EvoDash.NodeContext.call_remote/4` and renders the resulting model ids |

## Constraints

- Both modules follow the project's `try/rescue` anti-pattern policy: whitelist `Map` lookups for atom conversion, no defensive rescuing of core runtime calls.
- `ModelProfileHelpers` delegates shared utilities to `EvoDash.SettingsUtils`.
- `ConfigIO` delegates to `EvoGit.Config`, `EvoGit.AgentScheduler`, and `EvoGit.Config.Schema` — never calls them through `try/rescue`.

## Notes for Agents — model-profile id naming (model_value → base name)

- `add_model_profile/2` derives the new profile id from the **model value**, not a counter. All callers — `model_profile_events.ex` (`select_llm_model_shortcut`, `save_custom_model`, `save_quick_setup`), `welcome_live.ex` `do_save_model_profile`, and the Settings "Add Profile" draft button (nil) — pass the model value / nil.
- **Test gotcha (conflict-suffix tests):** when seeding existing profiles to test `-2`/`-3` suffixing through `add_model_profile/2`, the seeded profiles MUST carry a `:model` key — `add_model_profile/2` drops incomplete profiles (no/empty `:model`) BEFORE id generation, so a seeded `%{id: "deepseek-flash", concurrency: 3}` (no model) would be removed and the new profile would get the base id with no suffix. Direct `generate_profile_id/2` unit tests are unaffected (no draft-cleaning).
- Slugify: `String.downcase` + `~r/[^a-zA-Z0-9]+/` → single `-`, trimmed at both ends. `"DeepSeek V3.2"` → `deepseek-v3-2`; `"!!!"` → nil → `profile-N` fallback.
