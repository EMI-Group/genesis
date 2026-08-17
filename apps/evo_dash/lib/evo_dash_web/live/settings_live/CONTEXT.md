# SettingsLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.SettingsLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (six module files: `node_data.ex`, `model_profile_helpers.ex`, `model_profile_events.ex`, `config_io.ex`, `search_events.ex`, `custom_agent_events.ex`).

## API Surface

### `EvoDashWeb.SettingsLive.NodeData` (`node_data.ex`)

Async node-aware data loading for the Settings page (remote-SSH UX optimization #4). `handle_params/3` must never block the LiveView render loop on cross-node RPCs — `EvoDash.NodeContext.get_resolved_config/1` (a FULL merged config map) can take up to 30s on a slow or unreachable remote node, and every navigation used to run it (plus config status, platform info, and the custom-agents list) synchronously in the LiveView process.

| Function | Purpose |
|----------|---------|
| `start/2` | Spawns the supervised load task (`Task.Supervisor.start_child(EvoDash.TaskSupervisor, ...)`) for the socket's current node, capturing `parent` + `node` BEFORE spawning. Returns `:ok` (fire-and-forget). The task sends `{tag, node, results}` back; a `try/rescue` (justified: RPC boundary + user config files; expected failure = unreachable node) funnels ANY failure — erpc exit, config-parse raise — into error results so the LiveView renders the error banner instead of silently keeping mount's stale data. |

Results map: `%{file_config: map(), config_status: map(), remote_config_error: nil | term(), custom_agents: %{agents: [map()], model_selection_script: String.t(), script_status: :ok | {:error, {:compile_error, String.t()}}}}`.

Local and remote share ONE code path (`EvoDash.NodeContext` unifies local-direct with `:erpc`): local → `ConfigIO.load_file_config()` + `EvoGit.Config.config_status()`; remote → `get_resolved_config/1` (failure → `%{}` file_config + `remote_config_error: reason` — never a silently-empty config that would trigger a spurious "No LLM Model Configured" box) + `get_remote_config_status/1` (safe degraded map). `fetch_custom_agents/1` is TOLERANT (any non-matching result shape → empty defaults) — the LiveView's synchronous `load_custom_agents_data/1` keeps its strict match for the save flows.

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
- `NodeData` is the ONE justified exception: its `try/rescue` is at the RPC/config-file boundary (expected failure = unreachable node) and funnels every failure mode into the results map (see above).

## Async node-data loading (NodeData) — behavior contract

SettingsLive navigation loads are ASYNC (remote-SSH UX optimization #4); per-save flows remain synchronous.

- **`handle_params/3`** (settings_live.ex:668): `assign_node/2` → `assign(:current_path)` → **synchronous** platform-OS/nix gating + schema filtering + category resolution (`?category=` param, whitelist via `ConfigIO.category_str_to_atom`, `:llm` fallback for missing/unknown categories) → `EvoDashWeb.SettingsLive.NodeData.start(socket, @node_data_tag)` → `{:noreply, socket}`. The platform/nix gating stays SYNCHRONOUS deliberately (cheap — short-circuits on the `:platform_os_override`/`:nix_available_override` test seams — and category resolution depends on it), so the page shell + active category are correct on the very first render of every navigation. Only the DATA (config + custom agents) is async.
- **Result message**: `{:settings_node_data_loaded, requested_node, results}` (`@node_data_tag :settings_node_data_loaded`, settings_live.ex:18). `requested_node` is the node captured at spawn time.
- **Stale-guard** (`handle_info({@node_data_tag, requested_node, results}, socket)`, settings_live.ex:751): the result is DROPPED when `requested_node != socket.assigns.current_node` — the user switched nodes while the load was in flight and a newer load is already running for the new node. Never flashes the wrong node's config/agents.
- **`apply_node_data_results/2`** (private, settings_live.ex:1650): assigns `file_config`, `config_status`, `remote_config: false` (legacy assign preserved), `remote_config_error` (nil → nil; reason → gettext `"Could not load configuration from the remote node: %{reason} — the node may be unreachable."` with `inspect(reason)`), and the custom-agent assigns (`custom_agents`, `model_selection_script`, `script_status`, plus resets `editing_agent_id: nil`, `script_save_error: nil`, `script_test_results: []` — mirrors the old synchronous `load_custom_agents_data/1` reset semantics).
- **mount/3 stays synchronous** (runs with `current_node` = local default — NodeAware resolves `?node=` only in `handle_params`): seeds `file_config`/`config_status`/`remote_config_error: nil`/`custom_agents` from LOCAL reads, so the first render is never blank and local tests remain deterministic (mount seeds the same values the async task later re-assigns).
- **Per-save flows stay synchronous** (user-initiated, flash feedback): `save_category` (~:907), `save_search` (~:995), `save_api_key`, `persist_file_config/3` (~:1502), and all `CustomAgentEvents` saves reload their own fresh data (`ConfigIO.load_file_config()` / `get_remote_config` + `remote_config_to_file_config/1` / `NodeContext.save_user_config/2` + `reload_remote_config/1`). `load_custom_agents_data/1` (public, settings_live.ex:1608) remains for these synchronous reloads.
- **`remote_config_to_file_config/1`** (settings_live.ex:1686) is LEGACY: the navigation load path and the persist paths now fetch the FULL resolved config via `get_resolved_config/1`. The flat scheduler-map converter remains ONLY for `save_category`/`save_search` (settings_live.ex) and `SearchEvents.handle_reset_key/2`.

## Test strategy (async loads)

- The async result arrives as a message, so tests asserting async-loaded content must deliver it deterministically: **`send(view.pid, {:settings_node_data_loaded, node, results})` + `render(view)`** (render drains the mailbox synchronously). This is the same direct-send pattern as the LLM connection test. `render_async/1` does NOT help — it only awaits LiveView `start_async`/`assign_async` pids, not `TaskSupervisor` tasks.
- The real task may also deliver its message (same node, same values) — a duplicate delivery is an idempotent no-op, so direct-send tests are race-free.
- **Stale-guard test** (`settings_live_test.exs`, "stale async result for a different node is dropped"): deliver a results map with sentinel values tagged with a DIFFERENT node atom (`:"some_other_node@host"`), then `refute` each sentinel in the assigns (refutes hold regardless of whether the real in-flight load has landed).
- Local-node tests need NO changes: mount seeds the same values the async task re-assigns (config from local disk, empty custom agents in the isolated XDG test dir), so assertions right after `live()` remain deterministic.
- Remote-node tests in `settings_live_agents_test.exs` (remote degradation, empty agents) also need no changes: mount's LOCAL `load_custom_agents_data/1` seeds the same empty defaults, and the async task's tolerant fetch degrades to the same empties.

## RPC / Query Inventory (for remote-SSH UX optimization)

Where each support module hits the network (NodeContext → RemoteNode → direct call or `:erpc`) or local core calls. All line numbers verified.

- **custom_agent_events.ex is the only support module with direct NodeContext calls** (besides search_events.ex). `save_custom_agent` (custom_agent_events.ex:47, `NodeContext.save_custom_agent/2`), `delete_custom_agent` (:69), `save_model_selection_script` (:100), `reload_custom_agents` (:105, :125 — return value ignored, pure cache invalidation), `test_model_selection_script` (:132, 3× sequential `NodeContext.call_remote(node, EvoGit.CustomAgents.ModelSelector, :select_model, [attrs])` for the 3 sample attr maps at :266-296). **All save/delete results are tag-only** — `{:ok, _saved}` (the saved def is ignored, :48), `:ok | {:error, :not_found} | {:error, reason}` (:69-89). Error atoms mapped by `error_message/1` (:225-251) and `script_save_error_message/1` (:253-258; unwraps `{:compile_error, msg}` AND `{:error, {:compile_error, msg}}`).
- **Save flows reload via `SettingsLive.load_custom_agents_data/1`** (settings_live.ex:1608) — NOT direct list calls. It destructures `{:ok, %{agents:, model_selection_script:, script_status:}}` from `NodeContext.list_custom_agents/1` (which degrades to `{:ok, %{agents: [], model_selection_script: nil, script_status: :ok}}` on RPC failure, node_context.ex:508, so the match never fails), assigns `custom_agents`/`model_selection_script` (`script || ""`)/`script_status`, and **resets `editing_agent_id`, `script_save_error`, `script_test_results: []`** on every reload (test results are ephemeral — cleared by any navigation/mutation). Called from mount (settings_live.ex:657, runs on BOTH dead+live render with current_node still = local default, i.e. local reads) and from the CustomAgentEvents save flows; the NAVIGATION path no longer calls it synchronously — `handle_params/3` spawns `NodeData.start/2` instead (see "Async node-data loading" above), whose tolerant `fetch_custom_agents/1` assigns the same fields via `apply_node_data_results/2`. Category switches (`select_category`, settings_live.ex:845) are plain assigns — no handle_params, no RPC.
- **Agent def map keys read** (all in `CustomAgentsEditor`, custom_agents_editor.ex, atom-or-string fallback): `id` (:359), `name` (:368), `description` (:374), `prompt` (:380), `agent_type` (:386), `delegation_level` (:392), `model_id` (:398), `max_turns` (:404), `tools` (:411), `subagents` (:420). All 10 keys ARE consumed, but full prompts are only used as a truncated one-line preview (:112-114) and as the edit-form textarea value — a slim-list + lazy-full-fetch optimization would cut RPC payload on navigation. `script_status` consumed by `model_selection_editor.ex` `script_compile_error/1` (:162-163): `{:error, {:compile_error, msg}}` → msg in red box; `:ok`/anything else → nil. `script_test_results` consumed as `%{label:, result:}` (:136) with `result` matched `{:ok, nil}` → "default model" badge, `{:ok, model_id}` → badge (string verbatim), `{:error, reason}` → `format_error/1` (:166-169 unwraps `:compile_error`/`:script_raised`/`:invalid_result` msgs).
- **config_io.ex calls NO NodeContext** — purely local: `EvoGit.Config.resolve/0` (load_file_config, :18), `EvoGit.AgentScheduler.get_config/0` (load_scheduler_config, :25), `EvoGit.AgentScheduler.update_config/1` (update_runtime_from_file_config, :68), `EvoGit.Config.LLMCatalog.providers/0` (:238) and `provider_variants/1` (:246). `update_runtime_from_file_config` pushes only `[:scheduler, :default_llm_max_concurrency | :max_tool_concurrency | :agent_max_retries | :max_agent_depth | :max_retries | :max_turns | :max_turns_root]` + `:model_profiles` (via `Schema.model_profiles/1` = `[:llm, :models]` list, schema/llm.ex:56-60) and re-assigns `scheduler_config` from `load_scheduler_config()` on `:ok` (:71). Callers guard `node == node()` (settings_live.ex:930, :1021, :1523) — remote saves never push; they use `reload_remote_config` instead.
- **model_profile_helpers.ex is 100% pure** (no I/O/RPC); profile keys constructed in `parse_model_profile_params/2` (:243-256): `id`, `model` (string `"provider:model_id"` or map spec `%{provider:, id:}` + optional `:base_url`/`:extra`), `concurrency`, `temperature`, `reasoning_effort`, `max_tokens`, `top_p`, `top_k`, `frequency_penalty`, `presence_penalty`, `provider_options`. **model_profile_events.ex has NO direct NodeContext calls** — its RPC footprint is indirect via `SettingsLive.persist_file_config/3` (settings_live.ex:1502-1569: local → `ConfigIO.load_file_config` + `update_runtime_from_file_config`; remote → `reload_remote_config` (:1528) + `get_resolved_config` (:1532), full config into `@file_config`). `maybe_put_gen_opt/3` (model_profile_events.ex:295-298) reads profile keys atom-or-string; used by test_llm (settings_live.ex:1334-1339) for `temperature/max_tokens/top_p/top_k/frequency_penalty/presence_penalty`.
- **search_events.ex**: `handle_reset_key` (:57-101) is the only NodeContext user — `save_user_config` (:70), then local: `ConfigIO.load_file_config` (:74) + `config_status()` (Helpers → `EvoGit.Config.config_status()`); remote: `reload_remote_config` (:77) + `get_remote_config` (:78, flat scheduler map) → `SettingsLive.remote_config_to_file_config/1` (settings_live.ex:1686-1712, reads `:default_llm_max_concurrency`, `:max_tool_concurrency`, `:agent_max_retries`, `:max_agent_depth`, `:max_retries`, `:max_turns`, `:max_turns_root`, `:llm_model`, `:model_profiles` — all 9 consumed) + `get_remote_config_status` (:80). `File.exists?` on the LOCAL `config_path` even when remote (:83).
- **Payload-vs-consumed summary**: list_custom_agents transfers full defs incl. prompts (all consumed by UI, but only as truncated preview + edit form); save_user_config transfers the WHOLE resolved config per category save (whole-file write model); select_model transfers tiny attrs, returns model-id string; reload_custom_agents is tag-only.

## Notes for Agents — model-profile id naming (model_value → base name)

- `add_model_profile/2` derives the new profile id from the **model value**, not a counter. All callers — `model_profile_events.ex` (`select_llm_model_shortcut`, `save_custom_model`, `save_quick_setup`), `welcome_live.ex` `do_save_model_profile`, and the Settings "Add Profile" draft button (nil) — pass the model value / nil.
- **Test gotcha (conflict-suffix tests):** when seeding existing profiles to test `-2`/`-3` suffixing through `add_model_profile/2`, the seeded profiles MUST carry a `:model` key — `add_model_profile/2` drops incomplete profiles (no/empty `:model`) BEFORE id generation, so a seeded `%{id: "deepseek-flash", concurrency: 3}` (no model) would be removed and the new profile would get the base id with no suffix. Direct `generate_profile_id/2` unit tests are unaffected (no draft-cleaning).
- Slugify: `String.downcase` + `~r/[^a-zA-Z0-9]+/` → single `-`, trimmed at both ends. `"DeepSeek V3.2"` → `deepseek-v3-2`; `"!!!"` → nil → `profile-N` fallback.
