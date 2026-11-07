# SettingsLive Support Modules

## Intent and Routing

This leaf owns canonical provider-profile transformations and detached editor events, config form conversion, node-data/OAuth loaders, custom-agent events and search resets.
Files are provider_profiles.ex, model_profile_helpers.ex, model_profile_events.ex, config_io.ex, node_data.ex, auth_status.ex, custom_agent_events.ex and search_events.ex.
Parent ../settings_live.ex, ../../components/, core schema/runtime and dashboard tests are sibling-owned integration surfaces, not writable here.
provider_profiles_contract_test.exs is a temporary executable test handoff; its full contents must move to the sibling test tree before deletion here.

## Canonical ProviderProfiles API

profiles/1 delegates normalization/migration to Schema.provider_profiles/1; persistence is llm.providers plus llm.default_provider_profile, NOT legacy llm.models.
Provider/model maps and drafts use STRING keys; written containers use atom :llm/:providers/:default_provider_profile.
put_profiles/2 removes legacy shadows, preserves unrelated config and repairs default selection (first account or absent when empty).
update/3 replaces/appends and follows default-account rename; delete/2, move/3 and set_default/2 handle removal/order/default with unknown/boundary no-ops.
new_draft/1 creates unsaved profile-N, blank provider/default_model, api_key mode, concurrency 3 and empty models/peak rows.
draft/1 stringifies, JSON-encodes extra/provider_options maps at both levels and supplies [] models for iteration; default-only profiles NEVER fabricate override rows.
normalize_draft/1 numerically orders indexed models and normalizes peak/day fields without parsing away blank input.
submission/2 preserves omitted draft models/peak_hours/off_peak_days including emptied lists, except models never overrides legacy model_id.
parse(params, id, original \\ %{}) overlays the original draft and returns {:ok, string_keyed_provider} or {:error, reason_string}; unknown original provider keys survive, nested rows use an allowlist.
Provider fields include identity/auth/endpoint, shared concurrency/schedule/context/generation defaults, default_model and reasoning inventory/default; exact input names are below.
Model rows allow model/context_window/reasoning_efforts/default_reasoning_effort/generation/extra/provider_options, not separate auth/concurrency/schedules.
Models are OPTIONAL OVERRIDES, NOT an allowlist: default_model need not occur in models, default-only saves omit models, and blank default falls back to the first parsed override or returns default_model_invalid.
Non-map/duplicate/partially populated model rows, invalid numbers and invalid/non-object JSON are errors; wholly blank rows are ignored and empty overrides omitted.
Optional generation keys stay absent until supplied; concurrency defaults to 3 and core owns range/context-window defaults.
Reasoning inventories accept comma/newline strings or lists, trim/deduplicate in order and NEVER imply a default from the first entry.
Absent model inventory inherits provider; explicit []/blank stays unrestricted, and every nonnil effective default must belong to its effective nonempty inventory.
Known providers use catalog whitelist, unknown strings survive for core validation; OAuth-only forces oauth, OAuth drops API-key fields and API-key mode drops oauth_file.
Legacy model_id/context_window/reasoning_effort adapt to canonical fields without old model/reasoning_effort shadows.
add_model/2 adds complete accounts from qualified strings/ReqLLM maps with collision-safe model-slug ids and concurrency 3.
Utilities field/2, rows/1, string_list/1 and provider_atom/1 implement key/row/inventory/catalog handling without client-derived atoms.

## ModelProfileHelpers Compatibility

Canonical delegates: provider_profiles/1, provider_profile_draft/1, new_provider_profile_draft/1, parse_provider_profile_params/2,3, put_in_provider_profiles/2 and set_default_provider_profile/2.
Compatibility add_model_profile/2, update_model_profile/3, put_in_model_profiles/2 and move_model_profile/3 write providers; nil/empty add is a no-op, NOT draft insertion.
generate_profile_id/1,2, profile_id/1 and id_collision?/3 support atom/string ids and collision-safe slugs/profile-N names without discarding accounts.
parse_model_profile_params/2 remains the separate LEGACY atom-keyed flat parser, not canonical Save; numeric/string/map and peak helpers remain compatible.

## Detached ModelProfileEvents

Events accept socket then params and return LiveView tuples (never double-wrap); editing_profile_id is an account id or unsaved "new" sentinel.
Add creates only draft state, Edit snapshots/toggles the matching account, and unknown ids no-op.
model_profile_form_change replaces the ENTIRE draft; row add/remove changes only draft lists, with invalid/negative/out-of-range removal a no-op.
Row clicks carry no form input, so phx-change snapshots must preserve typing before rerender; Cancel clears all editor assigns without changing file_config.
Save restores omitted collections, checks identity/collision and parses against the original before provider update/persistence.
Parser failure retains submitted draft/identity; identity errors retain existing draft; parse success clears editor before persistence (write failure has no rollback/draft recovery).
Delete clears editor and persists, Move/Default persist order/selection, and quick paths resolve catalog variants/models without saving credentials.
advanced_open?/1 auto-opens for provider OR nested generation/extra/provider_options; toggle flips the explicit boolean or auto state, no-ops without editor, and resets on add/edit/cancel/success.
maybe_put_gen_opt/3 remains for legacy parent connection tests.

## Exact Parent and Components Wiring Handoff

These are sibling requirements, not changes made by this leaf.
The current parent already delegates CRUD, model_profile_form_change, toggle_profile_advanced and peak-row events, but still has legacy llm.models reads and flat component wiring.
Add direct delegates for set_default_provider_profile, add_profile_model and remove_profile_model; all event helpers return their own LiveView tuples.

| Event | Params |
| --- | --- |
| add_model_profile / cancel_edit_model_profile / add_profile_model / add_peak_hours_row / toggle_profile_advanced | none required |
| edit_model_profile / delete_model_profile | profile_id |
| move_model_profile | id, direction="up" or "down" |
| set_default_provider_profile | profile_id (id also accepted) |
| remove_profile_model / remove_peak_hours_row | index, nonnegative integer STRING |
| model_profile_form_change | ENTIRE unwrapped string-keyed form |
| save_model_profile | profile_id old identity, profile_id_new (or id) new identity and canonical fields |
| select_llm_model_shortcut | model_string |
| save_custom_model | provider_id, model_name, optional base_url |
| save_quick_setup | provider_id, model_string, optional base_url/variant_id |

The canonical form uses phx-submit="save_model_profile" and phx-change="model_profile_form_change".
Shared inputs use top-level names provider/name/auth_mode/api_key/api_key_env/oauth_file/base_url/concurrency/default_model/context_window/reasoning_efforts/default_reasoning_effort, generation fields, extra and provider_options.
Nested names are models[0][model], models[0][context_window], models[0][reasoning_efforts], models[0][default_reasoning_effort] and analogous generation/JSON overrides.
Peak names stay peak_hours[index][start|end|days] and off_peak_days[], with blank checkbox seed inputs.
Pass editing_profile_id/profile_form_draft/profile_advanced_open/auth_statuses through category_section to the provider editor.
Render a standalone new-draft form when editing_profile_id="new", because file_config intentionally contains no unsaved row to iterate.
Render from the STRING-keyed detached draft, not old flat model fields, and expose default_model as independent text input rather than a select restricted to saved override rows.
Native details open must use explicit boolean profile_advanced_open or else ModelProfileEvents.advanced_open?(draft), with summary clicks sending toggle_profile_advanced and collapsed inputs remaining in the DOM.
Replace/delegate the sibling ModelProfilesEditor.advanced_open?/3 flat auto rule to this exact canonical rule so render and server toggle agree, including nested advanced values.
Every write path (generic category/search/reset included) must invoke ConfigIO.canonicalize_file_config/1 before persistence to remove legacy shadows.
Provider editor rows and start_auth_status_load inputs must use ProviderProfiles.profiles(file_config), NOT runtime Schema.model_profiles/1 or raw llm.models.
Use ConfigIO.model_selections/1 for task/custom-agent/test choices and ConfigIO.resolve_model_spec/2 before connection tests, rather than manually collecting partial auth/generation params.
Update empty-config warnings, test_profile_id initialization, OAuth inputs and local/remote save reconciliation for canonical providers/selections.
Parent persist_file_config/3 remains the one transport boundary and returns the tuple these helpers expect.

## Core Dependencies and Explicit Limitations

Required APIs: Schema.provider_profiles/1 -> ordered STRING-keyed accounts, Schema.model_selections/1 -> ordered selection maps and Schema.resolve_model_spec(config, selection_or_legacy_id) -> {:ok, resolved} | {:error, reason}.
Schema.model_profiles/1 remains the atom-keyed RUNTIME projection sent under scheduler :model_profiles, never provider editor data.
The available core implements the new calls directly on Schema.ProviderProfiles but this snapshot lacks the umbrella Schema facade exports, so wrappers warn until integration lands.
The available core resolver still rejects unlisted models and default_model-only profiles, conflicting with the optional-overrides task contract; core normalization/enumeration/resolution/validation must be aligned for end-to-end operation.
Core EctoValidation.type_errors/3 also lacks :provider_profiles here, so normal mix test can fail during application boot before tests execute.
Core owns authoritative provider/range/config validation; do not invent dashboard inventory restrictions as a workaround.
Core currently consumes api_key_env_var while this parser accepts api_key_env; model-level extra/provider_options runtime merge support also needs core reconciliation.
No reasoning-slider mapping is implemented here; inventories/defaults are explicit strings.

## ConfigIO and SearchEvents

load_file_config/0 reads Config.resolve/0; canonicalize_file_config/1 normalizes accounts and removes legacy shadows; model_selections/1 and resolve_model_spec/2 are thin core facade calls.
load_scheduler_config/0 uses SafeCall with an empty-map fallback for stopped scheduler.
build_config_from_category_params/4 parses supplied schemas, deep-merges and deletes only explicitly emptied paths.
params_to_category_config/3 excludes :model_profiles/:provider_profiles AND llm.models/llm.providers/llm.default_provider_profile paths because dedicated forms own them.
Booleans parse before nil/blank (only "true" is true), malformed floats are neither written nor deleted, and list_of_strings_value/1 preserves [] while absent/non-list signals deletion.
update_runtime_from_file_config/2 best-effort pushes scheduler limits plus Schema.model_profiles(file_config) and reloads scheduler_config on success; failure does not invalidate an already-written file.
category_str_to_atom/1, provider_by_id_str/0, variant_id_by_str/1 and key_path_from_string/1 use whitelists, not client-derived atoms.
SearchEvents.handle_reset_key/2 resets in memory and delegates parent persistence/reload, owning only invalid-key-path handling.

## NodeData, Async Persistence and Platform Gating

NodeData.start/3 captures node/category/all_schemas, runs platform/config/status/agent/tool loads under TaskSupervisor + SafeCall and sends {tag, node, category, {:ok, results} | {:error, reason}} (page tag :settings_node_data_loaded).
Results contain platform_os/filtered_schemas_by_category/file_config/config_status/remote_config_error/custom_agents/custom_tools_status.
Local config reads ConfigIO/Config directly, remote reads FULL get_resolved_config; error_results/3 supplies :unknown platform, gated schemas, empty agents/tools and visible remote_config_error.
degraded_config_status/0 is %{ok?: false, missing: [], warnings: [], validation_errors: []}; agent fetch tolerates odd shapes, tool fetch normalizes lists and preserves {:error, reason}.
Mount uses local reads; handle_params seeds unfiltered shell then async loads even locally, seeding stable categories immediately and resolving sandbox/nix after filtering (fallback stable category or llm).
Applying results resets agent editor/script tests and starts separate auth loading; wrong-node results drop, but same-node loads/saves have no generation ordering.
Pre-result saves can see unfiltered schemas; otherwise filtering protects hidden sandbox fields, with local scheduler sandbox_backend and remote PlatformInfo fallback (bwrap is filesystem-only).
Local persistence is synchronous SafeCall; remote write/reload/full refetch/status uses ONE SafeCall.start task with NESTED {{:config_saved, node, msg}, result} or {{:credentials_saved, node, key}, result}.
config_saving clears on all paths; refetch failure keeps optimistic config with remote_config_error, write failure flashes without rollback and credentials save reloads status/credentials.
Tests always send {:llm_test_result, normalized_result}, but lack node/profile/generation scoping; remote scheduler broadcasts still reload LOCAL scheduler config.
NodeData/AuthStatus ignore start_child failure (always-send applies only after successful spawn), and credentials/auth are separate from node-data loads.

## AuthStatus

credential_profile/1 adapts canonical provider or legacy model to credential-only model/auth_mode/oauth_file, never API secrets; statuses/2 includes only OAuth accounts by nonblank id and unknown_statuses/1 supplies neutral entries.
Entries carry state/expires/account_id/login_instructions/oauth_file: ok map -> ok, no_credentials/invalid_credentials -> missing, ONLY managed_file_unwritable tuple -> unwritable, other verdicts/transports -> unknown.
Verdict/path calls run on the VIEWED node (direct locally, transport-unwrapped NodeContext.call_remote remotely), never borrowing local paths; instructions are static and renderer can fall back to configured path.
start/2 sends FLAT {:settings_auth_status_loaded, node, seq, statuses}; parent checks node AND auth_status_seq after node-data application, successful saves or refresh_auth_status, never polls.
Two remote calls per OAuth account are not deduplicated; unexpected errors degrade the whole map through outer SafeCall.

## Custom Agents, Tools and Peak Helpers

CustomAgentEvents add/edit/cancel/save/delete agent and save/test script functions return SOCKETS rather than LiveView tuples.
Mutations are synchronous but SafeCall-guarded on local and remote nodes, with translated error mappings and parent-owned refreshes.
Script test reloads cache and evaluates three sample attr maps via core APIs, retaining per-sample errors.
Sibling agents content order is CustomAgentsEditor -> CustomToolsPanel -> ModelSelectionEditor, with panel custom_tool_names feeding whitelist chips.
Tool refresh sends {:custom_tools_loaded, node, result}, node-guards application and clears loading on failure as well as success.
Peak concurrency is optional nonnegative integer (0 pauses), timezone optional, clocks strict HH:MM and start/end distinct.
Blank fields/rows omit scheduling keys; a days-only row with no times is dropped.
normalize_days/1 accepts scalar/list/hidden blanks and trim/downcase/whitelist/deduplicates mon/tue/wed/thu/fri/sat/sun/weekdays/weekends in order.
Public helpers also include parse_peak_fields/1, normalize_peak_hours_draft/1, valid_clock_time?/1 and clock_to_minutes/1.
Errors are peak_concurrency_invalid, peak_hours_invalid_time, peak_hours_start_equals_end and peak_hours_overlap.
Touching intervals are legal, but UI overlap checks ignore days and do not split overnight intervals, so disjoint-day windows can be rejected and real overnight overlaps missed; core validation is final.
normalize_peak_hours_draft assumes map rows within lists, so malformed non-map rows can raise despite broad totality claims.

## Remote-Connection Bootstrap and Form (sibling-owned)

Five steps: probing_platform/uploading/detecting_os -> 0; downloading/downloading_locally -> 1; extracting -> 2; setting_permissions/copying_config/generating_cookie/patching_binaries/stopping_daemon -> 3; starting_daemon -> 4; unknown -> -1.
bootstrap_progress[target_id] stores mapped stage/active/status/error; clicks seed active, broadcasts advance, errors freeze last stage and leaving bootstrapping (including disconnected) freezes success at 4.
Unrelated broadcasts preserve frozen entries; bootstrap_complete is definitive, daemon_running instead removes progress and opens bootstrap_restart_confirm %{id:, details:}.
Active hides buttons, success shows all-green progress and Install/Connect, error shows partial progress/text/retry; bootstrap_step_class/3 is nil-safe and failure text uses Helpers.format_remote_reason/1.
confirm_bootstrap_restart/cancel_bootstrap_restart take target_id; confirm calls NodeContext.bootstrap(id, on_running: :restart), re-enabling distribution with this identity WITHOUT stopping server/tasks or launching another instance.
User labels are Install then Connect; internal events/phases retain bootstrap names and tasks survive local app exit.
Blank local_binary_path/platform means auto-download/auto-probe; defaults are dist_port 9000, remote_path /tmp/genesis_server and platform nil.
Advanced dist_port/local_binary_path/remote_path/platform inputs use CSS hidden, NOT DOM removal; add/edit/cancel resets collapsed.
remote_connections_form_change rebuilds the draft, tracking Name from ssh_target only while assign-only auto_name is true (new true/edit false); explicit names survive, blank save names fall back to ssh_target for id generation and auto_name is never persisted.

## Tests and Handoff

WARNING: provider_profiles_contract_test.exs remains here because sibling writes are forbidden; never delete it without relocating FULL contents.
Parent must move it to apps/evo_dash/test/evo_dash_web/live/settings_live/provider_profiles_contract_test.exs and remove standalone ExUnit.start() when test_helper already starts ExUnit.
During incomplete core boot integration run `elixir -pa '_build/test/lib/*/ebin' apps/evo_dash/lib/evo_dash_web/live/settings_live/provider_profiles_contract_test.exs` after compiling changed modules.
Normal focused mix test is the integration gate after core facade/validation lands; never hide missing dependencies behind fake production core fallbacks.
Parent tests must cover canonical CRUD/default/rename, param wiring, draft row typing/new editor, disclosure parity, canonicalized generic saves and node-aware auth/tests.
Flat-parser tests target only parse_model_profile_params/2; CRUD/events assert providers and detached drafts.
NodeData tests deliver {:settings_node_data_loaded, node, category, {:ok, results}} via send(view.pid, ...) then render(view), not render_async (TaskSupervisor tasks).
Use all_schemas_by_category/PlatformInfo seams for fixtures; deliver gated results and wrong-node platform sentinels explicitly.

## Constraints

Transformations stay pure except documented I/O/runtime/socket boundaries; no sibling writes, duplicate migration, client-derived atoms or defensive rescue around core reads.
SafeCall owns RPC/store/runtime exit/exception handling; do not silently swallow unexpected failures.
