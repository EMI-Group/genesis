# SettingsLive Support Modules

## Intent and Routing

This leaf owns canonical provider-profile transformations, detached editor events, config form conversion, node-data/OAuth loaders, custom-agent events and search resets.
Files are provider_profiles.ex, model_profile_helpers.ex, model_profile_events.ex, config_io.ex, config_save.ex, node_data.ex, auth_status.ex, custom_agent_events.ex and search_events.ex.
The parent ../settings_live.ex, ../../components/, core schema/runtime and dashboard tests are sibling-owned integration surfaces, not writable here.
There are no child directories or temporary test handoff files in this leaf.

## Canonical ProviderProfiles API

profiles/1 delegates read-only normalization and legacy migration to Schema.provider_profiles/1 rather than duplicating migration.
Persistence is llm.providers plus llm.default_provider_profile, never a legacy llm.models shadow.
Provider/model maps and drafts use STRING keys; written config containers use atom :llm/:providers/:default_provider_profile.
put_profiles/2 removes both spellings of legacy collections, preserves unrelated config and retains an existing valid default or chooses the first account.
update/3 replaces or appends a profile and follows an explicit default-account rename; appending with no explicit default preserves the first migrated account instead of selecting the new account.
delete/2, move/3 and set_default/2 handle removal, order and default selection.
Unknown ids, invalid/missing directions and boundary moves return the ORIGINAL config without normalization.
new_draft/1 creates an unsaved profile-N account with blank provider/default_model, api_key mode, concurrency 3 and empty model/peak rows.
draft/1 stringifies maps, JSON-encodes extra/provider_options at both levels and supplies [] models for iteration without fabricating model overrides.
normalize_draft/1 numerically orders indexed model rows and normalizes peak/day fields while preserving blank input and nested generation drafts.
submission/2 preserves omitted draft models/peak_hours/off_peak_days, including explicitly emptied lists, except that models never overrides legacy model_id input.
parse(params, id, original \\ %{}) overlays the original draft and returns {:ok, string_keyed_provider} or {:error, reason_string}.
Unknown original provider keys survive, while nested model rows use an allowlist.
Provider fields include identity, auth/endpoint, shared concurrency/schedules/context, generation defaults, default_model and reasoning inventory/default.
Nested model rows allow model/context_window/reasoning_efforts/default_reasoning_effort/generation/extra/provider_options, not separate auth, concurrency or schedules.
The parser treats model rows as OPTIONAL OVERRIDES rather than an allowlist: a default-only save omits models and a default_model need not occur in models.
A blank default falls back to the first parsed override or returns default_model_invalid.
Non-map, duplicate or partially populated model rows, invalid numbers and invalid/non-object JSON are errors; wholly blank rows are ignored.
Optional generation keys stay absent until supplied, concurrency defaults to 3 and core owns authoritative provider/range/context validation.
Reasoning inventories accept comma/newline strings or lists, trim/deduplicate in order and NEVER invent a default from the first entry.
Absent model inventory inherits provider inventory, explicit []/blank stays unrestricted and an effective nonnil default must belong to its effective nonempty inventory.
Known providers resolve through a catalog whitelist without creating atoms from client input; unknown strings remain for core validation.
OAuth-only forces oauth, OAuth drops api_key/api_key_env_var/api_key_env and API-key mode drops oauth_file.
Credential drafts and parsed profiles emit api_key_env_var; legacy api_key_env input is accepted, with canonical key presence winning even when blank or nil.
Legacy model_id/context_window/reasoning_effort adapt to canonical fields without model/reasoning_effort shadows.
add_model/2 creates a complete account from a qualified string or ReqLLM map with a collision-safe model-slug id and concurrency 3.
field/2, rows/1, string_list/1 and provider_atom/1 provide shared key/row/inventory/catalog handling.

## ModelProfileHelpers and Detached Events

ModelProfileHelpers exposes canonical delegates for provider_profiles, provider_profile_draft, new_provider_profile_draft, parse_provider_profile_params, put_in_provider_profiles and set_default_provider_profile.
Compatibility add_model_profile/update_model_profile/put_in_model_profiles/move_model_profile write canonical providers; nil/empty Add is a no-op and Move delegates to the same no-op-preserving ProviderProfiles.move/3.
generate_profile_id/1,2, profile_id/1 and id_collision?/3 support atom/string ids and collision-safe slugs/profile-N names.
parse_model_profile_params/2 remains the LEGACY atom-keyed flat parser, not canonical Save.
ModelProfileEvents functions take socket then params and return LiveView tuples, never sockets to double-wrap.
editing_profile_id is an account id or the atom :new for an unsaved account, so the saved string id "new" remains an ordinary account.
Creation uses a nil original id for collision detection and update.
Add creates only draft state, Edit snapshots/toggles an existing account and unknown ids no-op.
model_profile_form_change replaces the ENTIRE detached draft; row add/remove changes only draft lists and invalid/negative/out-of-range removal is a no-op.
Row clicks carry no form input, so phx-change snapshots must preserve typing before rerender.
Cancel clears editor assigns without changing file_config.
Save snapshots submitted drafts before identity/parser validation and retains translated string-keyed profile_form_errors for invalid fields or sections.
A parsed Save creates profile_save_token and explicitly calls parent persist_file_config(config, socket, success_msg, editor_token: token).
Delete of the currently edited account creates its own token and uses the same /4 overload; unrelated Delete uses /3 and never captures or replaces an existing editor token.
Quick Setup, Move and Default also retain /3 with no editor options.
persistence_succeeded/2 clears only a matching reference token after confirmed persistence; persistence_failed/3 retains its draft and clears the matching token.
Draft mutations and editor changes invalidate old tokens, so stale callbacks cannot close newer edits.
Move persists only a real move and never calls the parent persistence boundary for a no-op.
Default persists through the parent and quick paths resolve catalog variants/models without saving credentials.
advanced_open?/1 inspects provider and model generation/extra/provider_options in BOTH flat parser drafts and nested UI generation maps.
An explicit profile_advanced_open boolean overrides the auto rule and resets on add/edit/cancel/success.
maybe_put_gen_opt/3 remains a legacy compatibility helper rather than the canonical connection-test path.

## Parent and Component Contract

The canonical form uses phx-submit="save_provider_profile" and phx-change="provider_profile_form_change", adapted by the parent to ModelProfileEvents.
Canonical add/edit/delete/cancel names route to the compatibility CRUD helpers, and provider model/peak row names route to the detached row helpers.
Move takes id/direction, Edit/Delete take profile_id, Default accepts profile_id or id, row removal takes nonnegative integer STRING index and Save takes profile_id_new or id for the new identity.
The entire form is the change payload; there is no wrapper map.
Nested input names are models[index][model|context_window|reasoning_efforts|default_reasoning_effort] plus per-model generation maps and JSON overrides.
Peak inputs are peak_hours[index][start|end|days] and off_peak_days[], including hidden blank checkbox seeds.
The parent preserves nested drafts during Change and flattens known generation fields only for Save, removing override_reasoning UI sentinels without converting inheritance to an explicit empty inventory.
Pass editing_profile_id/profile_form_draft/profile_advanced_open/auth_statuses through category_section to the standalone provider editor.
Render a standalone new-draft form for editing_profile_id=:new because file_config contains no unsaved row.
The parent must export persist_file_config(file_config, socket, success_msg, opts) with keyword opts and pass them unchanged to ConfigSave.start(socket, file_config, success_msg, opts).
The /3 overload must delegate with [] rather than infer editor_token from socket assigns, so generic saves cannot close an unrelated editor.
The parent owns ConfigSave start/result presentation and authoritative config application; route the complete nested {{:settings_config_saved, token, scope}, result} message to ConfigSave.complete/2 and use ConfigSave.invalidate/1 before replacing target state.
ConfigSave rejects pending target contexts that resolve to node(), but permits a known same-BEAM alias only when the parent supplies the current target's authoritative remote_status=%{phase: :connected} (NodeAware's contract).
A missing/non-connected status rejects the same-BEAM alias; the parent must refresh status on target changes and never reuse another target's connected status.
The parent /4 export and ConfigSave wiring are required integration work outside this leaf; no fallback shim hides a missing overload.
Render default_model as independent text, not a select restricted to saved override rows.
Native details open must use the explicit boolean or the SAME ModelProfileEvents.advanced_open?/1 rule, with collapsed inputs remaining in the DOM.
All save paths, including generic category/search/reset and Quick Setup, must pass through ConfigIO.canonicalize_file_config/1 in the parent persistence boundary.
Provider editor rows and OAuth loads use ProviderProfiles.profiles(file_config), not runtime Schema.model_profiles/1 or raw llm.models.
Dedicated provider schemas must be excluded from generic editing and reset surfaces in both category and search views; ConfigIO.params_to_category_config/3 independently excludes their collection/default paths from flat saves.
SettingCard supports an informational :provider_profiles summary but does not own provider-account editing.
The parent owns node/target/generation freshness guards for data loads, saves and connection tests; NodeData and remote-save responses carry node-only freshness checks.
Connection-test results use nested {{:llm_test_result, seq, scope}, result} tags guarded by sequence, target/BEAM-node/selection scope and testing state, and legacy unscoped results are ignored.
Pending remote targets cannot start a local connection test, and authoritative config loads reconcile test_profile_id against canonical account/model values.
Remote config reload unwraps SafeCall's {:ok, {:ok, config}} response; a successful write with a failed authoritative refetch remains a saved config with an unavailable-config warning.
Custom-agent model_id remains an account/default-model selector under its string-only core contract, so choices deduplicate canonical selections by provider_profile_id rather than inventing per-model ids.

## ConfigIO and Credential Boundaries

load_file_config/0 reads Config.resolve/0 and canonicalize_file_config/1 normalizes accounts and removes legacy shadows.
model_selections/1 delegates to Schema.model_selections/1 and returns credential-free account/model/reasoning metadata.
Persisted task/picker selections contain only string-keyed provider_profile_id, model and optional reasoning_effort.
resolve_model_spec/2 delegates to Schema.resolve_model_spec/2 and is SERVER-ONLY because the result includes provider_profile/runtime_profile/generation_params that may contain secrets.
The resolved model_spec is a ReqLLM-ready identifier, NOT the persisted canonical task map.
Connection tests pass resolved.model_spec and resolved.generation_params together to SystemCheck.llm_test or RemoteNode.llm_test; never reconstruct a partial option list.
Remote tests resolve on the VIEWED node through RPC so OAuth import, managed credential paths and named API-key environment variables are that node's, never the dashboard's.
Never send the resolved object or its generation_params to browser state, ChatHistory, DOM option values or push_event payloads.
Core owns runtime resolution, validation and credential composition; do not add dashboard fallbacks that conceal missing credentials or rejected selections.
load_scheduler_config/0 uses SafeCall with an empty-map fallback for a stopped scheduler.
build_config_from_category_params/4 parses supplied schemas, deep-merges and deletes explicitly emptied paths.
generic_schema?/1 excludes :model_profiles/:provider_profiles and llm.models/llm.providers/llm.default_provider_profile paths and descendants with mixed atom/string spellings because dedicated forms own them.
Generic category/search conversion and reset handlers share that guard, and parse_key_path/2 accepts only complete known generic schema paths rather than recombining individually allowed segments.
Booleans parse before nil/blank and only "true" is true; malformed floats are neither written nor deleted and list_of_strings_value/1 preserves [] while absent/non-list signals deletion.
update_runtime_from_file_config/2 best-effort pushes scheduler limits plus Schema.model_profiles(file_config), then reloads scheduler_config on success; runtime-push failure does not invalidate an already-written file.
Category/provider/variant/key-path conversions use schema/catalog whitelists rather than client-derived atoms.
SearchEvents resets in memory and delegates parent persistence/reload, handling invalid key paths only.

## ConfigSave Ownership
ConfigSave.start/4 returns {:started, socket}, {:rejected, reason, socket} or {:failed, {:startup, reason}, socket} and never optimistically assigns file_config.
complete/2 consumes the entire nested SafeCall message and returns {:saved, receipt, socket}, {:failed, receipt, socket} or {:stale, unchanged_socket}.
Requests bind a unique reference and {target_id, beam_node}, carry an explicit optional editor_token and prevent overlapping writes owned by the same LiveView.
Both local and remote whole-file saves are asynchronous, so event-return HTML, immediate disk reads and immediate flash assertions are not completion barriers.
Mounted tests must await the owned settings_config_saved result and its applied file_config or success/failure presentation before inspecting persisted configuration.
ConfigSave captures the target scope, canonical candidate and explicit callbacks, not arbitrary process dictionary values; process-local test overrides depend on the downstream resolver's caller-chain support across Task.Supervisor children.
Saved receipts contain authoritative file_config, warnings, scope, success_msg and runtime?, while failed receipts contain reason instead of file_config/warnings.
A confirmed write followed by failed reload remains saved with the confirmed candidate and a tagged config_reload warning.
The helper settles matching editor tokens but leaves authoritative config assignment, test-selection reconciliation, status/OAuth refreshes and flashes to the parent.
invalidate/1 detaches presentation ownership while retaining a live-worker guard; stale completions change no assigns or loading state.
Preserve config_save_owner across scope resets, invalidate pre-save config-load generations and refetch authoritative configuration before constructing a new scope's candidate.
Ownership is per LiveView rather than a distributed file lock, so remounts, other tabs and timed-out remote writes require core-level serialization for cross-page ordering.
## NodeData and AuthStatus

NodeData.start/3 captures node/category/all_schemas, loads platform/config/status/agent/tool data under TaskSupervisor + SafeCall and sends {tag, node, category, {:ok, results} | {:error, reason}}.
Results include platform_os/filtered_schemas_by_category/file_config/config_status/remote_config_error/custom_agents/custom_tools_status.
Local config reads ConfigIO/Config directly and remote config reads FULL get_resolved_config; error_results/3 supplies conservative platform/schema/agent/tool values and a visible remote_config_error.
degraded_config_status/0 is %{ok?: false, missing: [], warnings: [], validation_errors: []}.
Agent fetch tolerates odd shapes, tool fetch normalizes lists and preserves {:error, reason}, and remote status failures stay explicit.
Platform filtering protects hidden sandbox fields on save; Linux uses local scheduler sandbox_backend and remote pages use PlatformInfo fallback.
NodeData and AuthStatus ignore start_child failure, so always-send guarantees apply only after a successful spawn.
AuthStatus.credential_profile/1 adapts canonical or legacy profiles to credential-only model/auth_mode/oauth_file and never includes API secrets.
statuses/2 includes only OAuth accounts with nonblank ids and unknown_statuses/1 supplies neutral entries.
Status entries contain state/expires/account_id/login_instructions/oauth_file; no_credentials/invalid_credentials become missing, managed_file_unwritable alone becomes unwritable and unexpected transports/verdicts become unknown.
Credential verdict and managed-path calls run on the viewed node; login instructions are static and renderer fallback may use the configured path.
start/2 sends FLAT {:settings_auth_status_loaded, node, seq, statuses}; the parent checks node AND auth_status_seq after node-data loads, saves or explicit refresh, never polls.
Two remote calls per OAuth account are not deduplicated and unexpected errors degrade the map through the outer SafeCall.

## Custom Agents, Tools and Peak Helpers

CustomAgentEvents functions return SOCKETS rather than LiveView tuples and perform SafeCall-guarded local/remote mutations with translated errors and parent-owned refreshes.
Script test reloads the cache and evaluates three sample attr maps via core APIs while retaining per-sample errors.
Sibling Agents content is CustomAgentsEditor -> CustomToolsPanel -> ModelSelectionEditor, with loaded custom-tool names feeding whitelist chips.
Peak concurrency is optional nonnegative integer (0 pauses), timezone is optional, clocks are strict HH:MM and start/end must differ.
Blank scheduling fields/rows omit keys and a days-only row with no times is dropped.
normalize_days/1 handles scalar/list/hidden blanks and trims/downcases/whitelists/deduplicates day vocabulary in order.
Public helpers include parse_peak_fields/1, normalize_peak_hours_draft/1, valid_clock_time?/1 and clock_to_minutes/1.
Errors are peak_concurrency_invalid, peak_hours_invalid_time, peak_hours_start_equals_end and peak_hours_overlap.
Touching intervals are legal, but the UI overlap check ignores days and does not split overnight intervals; core validation remains authoritative.
normalize_peak_hours_draft assumes map rows in lists and malformed non-map rows can raise.

## Tests and Constraints

Existing helper regression suites live in apps/evo_dash/test/evo_dash_web/live/settings_live/{model_profile_helpers,provider_profiles_contract,config_io}_test.exs.
The canonical contract suite covers typed multi-model overrides, credentials, detached drafts, CRUD/default migration and default-only parser behavior; the flat-parser suite tests compatibility rather than canonical Save.
Auth/node integration lives in sibling auth_status_test.exs and settings_live_test.exs and uses explicit result messages rather than render_async for supervised tasks.
Core facade APIs and :provider_profiles validation are available; normal Mix tests boot without the former missing-delegate/validation prerequisites.
Transformations remain pure except documented I/O/runtime/socket boundaries, modules stay cohesive around or below 1000 lines and sibling tests are read-only under this node's scope.
SafeCall owns RPC/store/runtime exit and exception handling; do not silently swallow unexpected failures or add defensive rescue around core reads.
