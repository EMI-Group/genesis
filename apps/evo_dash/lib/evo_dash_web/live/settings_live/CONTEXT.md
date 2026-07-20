# SettingsLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SettingsLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## API Surface

### `EvoDashWeb.SettingsLive.ModelProfileHelpers` (`model_profile_helpers.ex`)

Pure data-transformation functions for model profile CRUD operations on the `[[llm.models]]` configuration list.

| Function | Purpose |
|----------|---------|
| `add_model_profile/2` | Adds a new model profile with a unique ID and default concurrency (3). |
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
| `update_runtime_from_file_config/2` | Accepts and returns a LiveView socket — pushes runtime config changes to `EvoGit.AgentScheduler`. |
| `build_whitelist/1`, `build_provider_whitelist/1` | Builds whitelist maps for safe untrusted-string-to-atom conversion (avoids `String.to_existing_atom/1` + `try/rescue`). |

Only `update_runtime_from_file_config/2` touches the socket — all other functions are pure.

## Constraints

- Both modules follow the project's `try/rescue` anti-pattern policy: whitelist `Map` lookups for atom conversion, no defensive rescuing of core runtime calls.
- `ModelProfileHelpers` delegates shared utilities to `EvoDash.SettingsUtils`.
- `ConfigIO` delegates to `EvoGit.Config`, `EvoGit.AgentScheduler`, and `EvoGit.Config.Schema` — never calls them through `try/rescue`.

## Routing Table

None — leaf directory.
