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

## RPC / Query Inventory (for remote-SSH UX optimization)

Where each support module hits the network (NodeContext → RemoteNode → direct call or `:erpc`) or local core calls. All line numbers verified.

- **custom_agent_events.ex is the only support module with direct NodeContext calls** (besides search_events.ex). `save_custom_agent` (custom_agent_events.ex:47, `NodeContext.save_custom_agent/2`), `delete_custom_agent` (:69), `save_model_selection_script` (:100), `reload_custom_agents` (:105, :125 — return value ignored, pure cache invalidation), `test_model_selection_script` (:132, 3× sequential `NodeContext.call_remote(node, EvoGit.CustomAgents.ModelSelector, :select_model, [attrs])` for the 3 sample attr maps at :266-296). **All save/delete results are tag-only** — `{:ok, _saved}` (the saved def is ignored, :48), `:ok | {:error, :not_found} | {:error, reason}` (:69-89). Error atoms mapped by `error_message/1` (:225-251) and `script_save_error_message/1` (:253-258; unwraps `{:compile_error, msg}` AND `{:error, {:compile_error, msg}}`).
- **Reloads delegate to `SettingsLive.load_custom_agents_data/1`** (settings_live.ex:1583-1597) — NOT direct list calls. It destructures `{:ok, %{agents:, model_selection_script:, script_status:}}` from `NodeContext.list_custom_agents/1` (which degrades to `{:ok, %{agents: [], model_selection_script: nil, script_status: :ok}}` on RPC failure, node_context.ex:508, so the match never fails), assigns `custom_agents`/`model_selection_script` (`script || ""`)/`script_status`, and **resets `editing_agent_id`, `script_save_error`, `script_test_results: []`** on every reload (test results are ephemeral — cleared by any navigation/mutation). Called from mount (settings_live.ex:657, runs on BOTH dead+live render with current_node still = local default, i.e. local reads) and handle_params (:733, after `assign_node/2` resolves `?node=` → the remote RPC; runs on dead render + live + every navigation/push_patch). Net: viewing a remote node, one page load ≈ 2 local reads + 2 `list_custom_agents` RPCs; every `handle_params` adds 1 RPC. Category switches (`select_category`, :820-845) are plain assigns — no handle_params, no RPC.
- **Agent def map keys read** (all in `CustomAgentsEditor`, custom_agents_editor.ex, atom-or-string fallback): `id` (:359), `name` (:368), `description` (:374), `prompt` (:380), `agent_type` (:386), `delegation_level` (:392), `model_id` (:398), `max_turns` (:404), `tools` (:411), `subagents` (:420). All 10 keys ARE consumed, but full prompts are only used as a truncated one-line preview (:112-114) and as the edit-form textarea value — a slim-list + lazy-full-fetch optimization would cut RPC payload on navigation. `script_status` consumed by `model_selection_editor.ex` `script_compile_error/1` (:162-163): `{:error, {:compile_error, msg}}` → msg in red box; `:ok`/anything else → nil. `script_test_results` consumed as `%{label:, result:}` (:136) with `result` matched `{:ok, nil}` → "default model" badge, `{:ok, model_id}` → badge (string verbatim), `{:error, reason}` → `format_error/1` (:166-169 unwraps `:compile_error`/`:script_raised`/`:invalid_result` msgs).
- **config_io.ex calls NO NodeContext** — purely local: `EvoGit.Config.resolve/0` (load_file_config, :18), `EvoGit.AgentScheduler.get_config/0` (load_scheduler_config, :25), `EvoGit.AgentScheduler.update_config/1` (update_runtime_from_file_config, :68), `EvoGit.Config.LLMCatalog.providers/0` (:238) and `provider_variants/1` (:246). `update_runtime_from_file_config` pushes only `[:scheduler, :default_llm_max_concurrency | :max_tool_concurrency | :agent_max_retries | :max_agent_depth | :max_retries | :max_turns | :max_turns_root]` + `:model_profiles` (via `Schema.model_profiles/1` = `[:llm, :models]` list, schema/llm.ex:56-60) and re-assigns `scheduler_config` from `load_scheduler_config()` on `:ok` (:71). Callers guard `node == node()` (settings_live.ex:930, :1021, :1523) — remote saves never push; they use `reload_remote_config` instead.
- **model_profile_helpers.ex is 100% pure** (no I/O/RPC); profile keys constructed in `parse_model_profile_params/2` (:243-256): `id`, `model` (string `"provider:model_id"` or map spec `%{provider:, id:}` + optional `:base_url`/`:extra`), `concurrency`, `temperature`, `reasoning_effort`, `max_tokens`, `top_p`, `top_k`, `frequency_penalty`, `presence_penalty`, `provider_options`. **model_profile_events.ex has NO direct NodeContext calls** — its RPC footprint is indirect via `SettingsLive.persist_file_config/3` (settings_live.ex:1502-1569: local → `ConfigIO.load_file_config` + `update_runtime_from_file_config`; remote → `reload_remote_config` (:1528) + `get_resolved_config` (:1532), full config into `@file_config`). `maybe_put_gen_opt/3` (model_profile_events.ex:295-298) reads profile keys atom-or-string; used by test_llm (settings_live.ex:1334-1339) for `temperature/max_tokens/top_p/top_k/frequency_penalty/presence_penalty`.
- **search_events.ex**: `handle_reset_key` (:57-101) is the only NodeContext user — `save_user_config` (:70), then local: `ConfigIO.load_file_config` (:74) + `config_status()` (Helpers → `EvoGit.Config.config_status()`); remote: `reload_remote_config` (:77) + `get_remote_config` (:78, flat scheduler map) → `SettingsLive.remote_config_to_file_config/1` (settings_live.ex:1683-1709, reads `:default_llm_max_concurrency`, `:max_tool_concurrency`, `:agent_max_retries`, `:max_agent_depth`, `:max_retries`, `:max_turns`, `:max_turns_root`, `:llm_model`, `:model_profiles` — all 9 consumed) + `get_remote_config_status` (:80). `File.exists?` on the LOCAL `config_path` even when remote (:83).
- **Payload-vs-consumed summary**: list_custom_agents transfers full defs incl. prompts (all consumed by UI, but only as truncated preview + edit form); save_user_config transfers the WHOLE resolved config per category save (whole-file write model); select_model transfers tiny attrs, returns model-id string; reload_custom_agents is tag-only.

## Notes for Agents — model-profile id naming (model_value → base name)

- `add_model_profile/2` derives the new profile id from the **model value**, not a counter. All callers — `model_profile_events.ex` (`select_llm_model_shortcut`, `save_custom_model`, `save_quick_setup`), `welcome_live.ex` `do_save_model_profile`, and the Settings "Add Profile" draft button (nil) — pass the model value / nil.
- **Test gotcha (conflict-suffix tests):** when seeding existing profiles to test `-2`/`-3` suffixing through `add_model_profile/2`, the seeded profiles MUST carry a `:model` key — `add_model_profile/2` drops incomplete profiles (no/empty `:model`) BEFORE id generation, so a seeded `%{id: "deepseek-flash", concurrency: 3}` (no model) would be removed and the new profile would get the base id with no suffix. Direct `generate_profile_id/2` unit tests are unaffected (no draft-cleaning).
- Slugify: `String.downcase` + `~r/[^a-zA-Z0-9]+/` → single `-`, trimmed at both ends. `"DeepSeek V3.2"` → `deepseek-v3-2`; `"!!!"` → nil → `profile-N` fallback.
