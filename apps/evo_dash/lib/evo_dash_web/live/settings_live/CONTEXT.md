# SettingsLive Support Modules
## Intent and Routing
`EvoDashWeb.SettingsLive` (`../settings_live.ex`, ~1,000 lines) is the stateful orchestrator only: `render/1`, `mount/3`, `handle_params/3`, one-line `handle_event/3`/`handle_info/2` routing, `persist_file_config/3,4` and the two async custom-agent/custom-tool refresh kickers (`refresh_custom_agents/1`, `refresh_custom_tools/1`).
Everything else lives in this leaf: `Navigation` (category navigation), `PageState` (mount assigns, config scope, node-aware read helpers), `ProviderPanelEvents` (the provider-account surface state machine), `ChatGPTSignInState` (the WHOLE page-level in-browser Sign in with ChatGPT feature shared by the wizard, an account detail and an auth-status row: state machine, socket handlers, post-sign-in side effects, wizard projection and the close-path cancel), `CategoryEvents` (generic categories + the ONE persistence entry point), `LlmTestEvents` (connection tests), `RemoteEvents` + `RemotePanel` (remote-target behaviour and view), `AsyncResults` (every async result and broadcast handler), `ProviderProfiles` + `ModelProfileHelpers` + `ModelProfileEvents` (canonical account transforms and detached editor state), `ConfigIO`, `ConfigSave`, `NodeData`, `AuthStatus`, `CustomAgentEvents` and `SearchEvents`.
The parent `../settings_live.ex`, `../../components/`, the core schema/runtime and the dashboard tests are sibling-owned integration surfaces, not writable here.
There are no child directories in this leaf.
## Category Navigation
`Navigation.category_from_param/2` whitelists a client value (string or atom) against the displayable category map and returns `nil` for an unknown or gated category, so no client input is ever interned as an atom.
`Navigation.resolve/3` resolves requested → fallback → `:llm` → first available category, and `seed/3` resolves `params["category"]` against the LAST-KNOWN filtered map, else keeps the current category while it stays displayable, else takes the default.
`Navigation.path/2` builds `/settings?category=<cat>` and appends `&node=` when the caller passes it, because `Helpers.with_node_param/2` always appends `?` and would corrupt an existing query string.
`default_category/1`, `visible?/2` and `available_categories/1` complete the pure, I/O-free API (no `try/rescue`).
The nav never advertises a category the viewed node will not serve: the displayable map comes from the platform/nix FILTERED `schemas_by_category` plus the dashboard-only pseudo-categories `:remote_connections` and `:agents`.
`handle_params/3` assigns only the last-known filtered map (never the unfiltered one) and seeds through `Navigation.seed/3`, so a gated category cannot become active.
`select_category` whitelists through `Navigation.category_from_param/2` (an unknown/gated value is a no-op), assigns `active_category`, clears `search_text`/`per_category_errors`, records `category_patch: {ConfigSave.scope(socket), to_string(cat)}` and `push_patch`es to `Navigation.path/2`, so the URL stays the source of truth for the category.
`PageState.consume_category_patch/2` consumes that marker exactly once, so a category-only navigation neither re-reads config nor cancels an in-flight load.
The active category pane root is re-keyed `settings-pane-<category>` and carries the existing `wizard-step-enter` class, so every swap mounts a fresh element that replays the shared entrance keyframe (no JS, no new CSS, all other DOM ids and the `?category=` contract unchanged).
Selecting `:remote_connections` additionally refreshes `remote_targets`/`remote_statuses` from `PageState.safe_list_targets/0` and `safe_connection_statuses/0`.
## PageState
`node_data_tag/0` is the single node-data result tag, and `initial_assigns/1` seeds the whole page: category/schema maps, `file_config`, `config_status`, `scheduler_config`, provider/editor assigns, wizard and schedule assigns, remote assigns and `config_file_exists`.
`initial_assigns/1` holds the leaf's only direct filesystem call — `File.exists?(EvoGit.Config.config_path())` — feeding the sidebar's "config file does not exist" hint; after a save receipt the parent sets `config_file_exists: true` without touching disk.
`initial_assigns/1` injects the pseudo-categories `:remote_connections` and `:agents` into `schemas_by_category` with empty schema lists.
`initial_assigns/1` also seeds the custom-agent/custom-tool LOADING defaults (`custom_agents: []`, `model_selection_script: ""`, `script_status: :ok`, `custom_agents_loading: true`, `custom_tools_status: %{ok: [], errors: []}`, `custom_tools_loading: true`) plus the custom-agent editor assigns, so `mount/3` performs NO cross-node RPC and the page paints immediately.
Only the CONNECTED mount kicks `refresh_custom_agents/1` and `refresh_custom_tools/1`; the dead render leaves both loading flags true and spawns nothing.
`start_node_data_load/2` and `invalidate_config_load/1` own the node-data generations; `reset_config_scope/1` and `reconcile_config_scope/1` reset/re-scope config assigns on node changes; `pending_remote_target?/1` reports a requested-but-unconnected remote context.
`safe_config_status/0`, `safe_list_targets/0` and `safe_connection_statuses/0` are the SafeCall-guarded degraded reads used by mount, saves and category switches.
`test_config_scope/1` builds the connection-test scope, `nav_node/1` supplies the `?node=` value, and `remote_config_to_file_config/1` normalizes a remote resolved config into the editable file-config shape.
`sandbox_backend/1` derives the sandbox backend for rendering (local scheduler value, remote platform fallback), and `custom_agent_model_choices/1` builds the custom-agent model options from canonical accounts.
## Provider Account Panel
The in-browser Sign in with ChatGPT state is PAGE-level, never wizard-scoped: `:chatgpt_sign_in` holds `%{surface: nil | :wizard | {:detail, profile_id} | {:status, profile_id}, flow_id: nil | binary, url: nil | binary, phase: :idle | :waiting | :ok | :error, reason: nil | atom, port: nil | pos_integer, mode: nil | :loopback | :manual, paste: binary, paste_error: nil | atom}` and `:chatgpt_sign_in_manual` holds the page's local/remote verdict for EVERY surface.
`EvoDashWeb.SettingsLive.ChatGPTSignInState` owns the whole feature — the state machine (`new/0`, `surface_from_params/1`, `surface/1`, `owned_by?/2`, `surface_state/2`, `waiting?/1`, `flow_id/1`, `begin/4`, `apply_result/3`, `cancel/1`, `cancel_owned_by/2`, `manual?/1`) AND the socket-side glue (`chatgpt_sign_in/2`, `chatgpt_sign_in_cancel/2`, `chatgpt_sign_in_paste/2`, `chatgpt_sign_in_submit/2`, `chatgpt_signin_result/3`, `close_surface/2`, `detail_surface/1`, `ensure_wizard_keys/2`, plus `accounts/1` for the viewed node's registrations).
The MANUAL "paste the redirect URL" fallback lives in the SAME module as public PURE transitions over the plain state map — `paste_text/1` (the typed text of an event payload: the input's own `"paste"` field first, then a form-style `"value"`, atom keys tolerated, `""` for anything else), `paste_target?/2` (`owned_by?/2` of the surface AND `phase == :waiting`), `paste_payload_target?/2` (an event payload: a surface-named payload is judged by `paste_target?/2`, a surface-LESS one — the input-level `phx-change` shape — only needs `phase == :waiting`), `put_paste/2` (verbatim `:paste`, clears `:paste_error`), `submit_paste/2` (recorded `:paste`, else `paste_text/1`; blank input → `:no_code`, no flow id → `:error`/`:sign_in_unavailable`, else `LLMSetup.ChatGPTSignIn.submit/2` → `apply_submit_result/2`) and `apply_submit_result/2` (`:ok` keeps `:waiting` with the paste cleared; `:invalid_callback`/`:no_code`/`:already_finished` keep `:waiting` with that `:paste_error`; any other error becomes `:error`) — so `/welcome` reuses them instead of re-deriving the mapping and the terminal result still only arrives through the poll.
The state functions are pure and total apart from the bounded `ChatGPTSignIn.begin/1`/`start_poll/2` calls; the socket functions take and answer a socket exactly like the page's handlers, and the poll owner pid is an ARGUMENT, so only the handler passes `self()`.
The paste input is an INPUT-level `phx-change`, so its REAL payload is `%{"paste" => text, "_target" => "paste"}` — LiveView serializes the enclosing form's field VALUES but reads `phx-value-*` from the FORM, never the input — hence a page must read `"paste"` (never `"value"`) and a surface-less payload is matched to the ONE waiting state instead of a surface; the stricter surface/profile-id guard keeps applying to every payload that does name one, so a superseded or foreign attempt is still dropped.
Three surfaces share it and name themselves in the payload: the wizard sends no `surface` value, so `surface_from_params/1` answers `:wizard`; an expanded account detail sends `phx-value-surface="detail"` plus `phx-value-profile_id`; an auth-status row sends `phx-value-surface="status"` with the same id (absent/unknown values also fall back to `:wizard`, so the frozen wizard DOM keeps working).
`ChatGPTSignInState.surface_state/2` delegates to `SettingsComponents.ChatGPTSignInPanel.surface_state/2`, the ONE isolation rule: a surface sees the flow only while its own `:surface` matches (profile ids compared as strings) and gets `%{}` otherwise, so a flow begun on one surface never paints another.
`begin/4` closes any still-waiting flow first (`ChatGPTSignIn.cancel/1`, quiet on failure — only ONE live flow may exist), then stores `%{surface: surface, flow_id: id, url: url, phase: :waiting, port: port, mode: mode}` (the `:port` feeds the panel's expected redirect address and `:mode` records whether a loopback listener could be bound) or the `:error` phase with the reason and NO poll; `:paste`/`:paste_error` are reset on every begin.
`chatgpt_sign_in/2` resolves the account from the OWNING surface before calling `begin/4` (`:wizard` → the draft's `siwc_account` through `LLMSetup.ChatGPT.account_name/1`; `{:detail, id}`/`{:status, id}` → that profile's `siwc_account`; each falling back to the store default).
`{:chatgpt_signin_result, flow_id, result}` is handled by `ChatGPTSignInState.chatgpt_signin_result/3`, whose `apply_result/3` is the ONLY stale guard: a superseded, cancelled or surface-closed flow id changes NOTHING (no phase, no side effect), the current flow's `{:ok, %{account: account}}` becomes `:ok`, every error becomes `:error` with that reason, and an unexpected shape becomes `:error`/`:sign_in_unavailable`.
Success applies every side effect exactly once inside that same handler: `siwc_account` is written into the wizard draft for `:wizard`, or into `profile_form_draft["siwc_account"]` when the owning `{:detail, id}`/`{:status, id}` is the expanded `editing_profile_id` (never the wizard draft), the wizard's `:chatgpt_accounts` reload from `ChatGPTSignInState.accounts/1`, `LlmTestEvents.invalidate_llm_test/1` drops any pending connection test, `SettingsLive.start_auth_status_load/1` re-reads the credential-status rows, `:profile_save_token` is cleared and the wizard errors are cleared.
A successful sign-in performs NO config reload and writes NO `credentials.toml`: the flow installs a registration file (`<config_dir>/chatgpt/account-<name>.json`) through `EvoGit.Auth.ChatGPT.Store.install/2`, which raises no `EvoGit.Config.Watcher` event, so no other LiveView observes it.
The `openai_codex` model list is the REGISTRATION-CACHED set — `ChatGPTSignInState.accounts/1` → `LLMSetup.ChatGPT.accounts/1` → `EvoGit.Auth.ChatGPT.Store.accounts/0` (each record's `models` cached at install), rendered through `LLMSetup.ChatGPT.model_entries/2` and enforced by `chatgpt_model_available/3` — never LLM catalog metadata.
The wizard map keeps carrying `:chatgpt_sign_in` (its own surface PROJECTION via `surface_state(state, :wizard)`, else `%{}`) and `:chatgpt_sign_in_manual` (the page verdict) on EVERY build — `ChatGPTSignInState.ensure_wizard_keys/2`, called from `ProviderPanelEvents`' one-line `ensure_sign_in_keys/2` delegate — so `WizardForm`/`ChatGPTAuth` never receive `nil`.
Dismissing a surface abandons ONLY the flow it owns through `ChatGPTSignInState.close_surface/2` (the state module's `cancel_owned_by/2` rule), which every close site calls: `provider_wizard_cancel`, `provider_wizard_save`, `close_editor/1`, `expand_saved/2`, `provider_model_cancel`, `cancel_edit_provider_profile`, a same-profile `edit_provider_profile` toggle and `delete_provider_profile`, so a late poll result can never resurface in a later unrelated surface.
`ProviderPanelEvents` routes the panel's `"chatgpt_sign_in"` / `"chatgpt_sign_in_cancel"` events and the `{:chatgpt_signin_result, flow_id, result}` info message to the state module through one-line delegations, while the page's own allowlist adds dedicated clauses for `"chatgpt_sign_in_paste"` and `"chatgpt_sign_in_submit"` straight into `chatgpt_sign_in_paste/2` / `chatgpt_sign_in_submit/2`.
`SettingsLive.sync_sign_in_scope/2` cancels and resets the state on a node switch and always recomputes `:chatgpt_sign_in_manual`, and `SettingsLive.terminate/2` closes a still-waiting flow so its loopback listener cannot outlive the page.
`chatgpt_sign_in_manual` is true for a REMOTE viewed node (`current_node != node()` or `current_node_id != nil`), which is what makes every surface render the `genesis chatgpt login` hint instead of a button whose loopback callback a browser on another host could never reach.
`ProviderPanelEvents` owns the whole provider surface state machine: `:provider_wizard` (nil or a map), `:provider_schedule` (the expanded account's recommendation strip), plus the expanded editor state it delegates to `ModelProfileEvents`.
Wizard state is `%{mode: :account | {:model, profile_id}, step: :provider | :auth | :model | :reasoning_schedule, draft: string-keyed map, errors: %{field => translated message}, schedule: %{preset_id: nil, snapshot: nil, applied?: false, modified?: false}}`.
`empty_schedule/0` returns the expanded-account strip state `%{preset_id: nil, applied: false, modified: false, can_undo: false, snapshot: nil}`.
`events/0` + `dispatch/3` whitelist the panel's event names through `Map.fetch/2` (an unknown name is a no-op), and the parent's provider `handle_event` clause is one line into `dispatch/3`.
`add_provider_profile` closes any open editor and opens an add-account wizard on a fresh `ProviderProfiles.new_draft/1` at step `:provider`.
`provider_wizard_change` routes a schedule preset selection through `Schedule.apply/2` and a field change through `ProviderProfiles.submission/2` + `derive_identity/3`, then recomputes the wizard's `modified?` against its schedule snapshot.
A provider change inside the wizard drops the generated `profile_id_new` and blanks the name so the identity is re-derived from the new catalog entry.
`provider_wizard_next`/`provider_wizard_back` clamp to `WizardForm.rendered_steps/1`, and `provider_wizard_save` writes a complete account (one model row plus `default_model`), then persists through `persist/3`.
`start_add_provider_model` requires a saved `profile_id`, collapses the expanded editor and opens a model-only wizard for that account; `provider_model_save` appends the parsed row to the SAVED account and persists the whole account.
Expanded-editor events (`edit_provider_profile`, `cancel_edit_provider_profile`, `save_provider_profile`, `set_default_provider_profile`, `delete_provider_profile`, `add_profile_model`, `remove_profile_model`, `add_peak_hours_row`, `remove_peak_hours_row`, `toggle_profile_advanced`) delegate to `ModelProfileEvents`.
Every expanded-editor interaction closes the wizard and resets the recommendation strip, and `refresh_schedule/1` recomputes `modified` through `Schedule.changed?/2` only while a pre-apply snapshot exists.
`save_provider_profile` keeps the detached draft authoritative, flattens nested `generation` inputs and strips the `override_reasoning` UI sentinels before calling the canonical parser; it invalidates any previous `profile_save_token`.
`apply_provider_schedule` writes only the preset's schedule keys through `Schedule.apply/2`, keeps the pre-apply snapshot and marks the strip applied (`can_undo: true`); `undo_provider_schedule` restores that snapshot through `Schedule.undo/2`; `dismiss_schedule_applied` removes only the notice.
Nothing prefills on render and applying is always an explicit user action; a post-apply edit sets `modified` while Undo keeps working.
A successful save expands the saved account optimistically (`expand_saved/2`) with a fresh detached draft and flashes a translated message; the authoritative `file_config` arrives with the `ConfigSave` receipt.
Wizard and editor errors are translated once through `ModelProfileEvents.error_message/1`, stored per field and flashed as the first message.
## Canonical ProviderProfiles API
`profiles/1` delegates read-only normalization and legacy migration to `Schema.provider_profiles/1` rather than duplicating migration.
Persistence is `llm.providers` plus `llm.default_provider_profile`, never a legacy `llm.models` shadow.
Provider/model maps and drafts use STRING keys; written config containers use the atom `:llm`/`:providers`/`:default_provider_profile`.
`put_profiles/2` removes both spellings of legacy collections, preserves unrelated config and retains an existing valid default or chooses the first account.
`update/3` replaces or appends a profile and follows an explicit default-account rename; appending with no explicit default preserves the first migrated account instead of selecting the new account.
`delete/2`, `move/3` and `set_default/2` handle removal, order and default selection; unknown ids, invalid/missing directions and boundary moves return the ORIGINAL config without normalization.
`new_draft/1` creates an unsaved `profile-N` account with blank name/provider/`default_model`, `api_key` mode, concurrency 3 and empty model/peak rows.
`draft/1` stringifies maps, JSON-encodes `extra`/`provider_options` at both levels and supplies `[]` models for iteration without fabricating model overrides.
`normalize_draft/1` numerically orders indexed model rows and normalizes peak/day fields while preserving blank input and nested generation drafts.
`normalize_draft/1` and `submission/2` drop `@ui_only_keys` (`paste` — the ChatGPT sign-in panel's named input, which renders inside the provider-detail form and is therefore serialized with every profile change), from BOTH the incoming params and the inherited draft; `parse_editor/3` rebuilds the profile from its own field lists, so no UI-only key can reach `config.toml`.
`submission/2` overlays submitted fields on the whole detached draft, preserving omitted hidden advanced fields and explicitly emptied collections while canonicalizing credential aliases before merging.
Legacy `model_id` submissions discard detached `models`/`default_model`/`default_model_name`/`default_reasoning_effort` so old draft defaults cannot shadow single-model compatibility input.
`editor_identity/4` derives the account identity from the PROVIDER: a new blank or untouched generated id uses `Identity.provider_slug/1` with collision-safe `-2`/`-3` suffixes, and a blank name uses `Identity.provider_display_name/1` with independently collision-safe suffixes.
The identity source is the catalog ENTRY id rather than the shared runtime provider atom, so `openai_compatible` yields the `openai-compatible` slug and the "OpenAI-Compatible API" display name.
Explicit nonblank user ids and names always win and are retained for normal collision validation; blank or omitted edit identities retain the saved account id/name even when the provider changes, and a present blank `profile_id_new` requests automatic new identity.
A model name never becomes the account id or name.
`parse(params, id, original \\ %{})` overlays the original draft and returns `{:ok, string_keyed_provider}` or `{:error, reason_string}`.
Unknown original provider keys survive, while nested model rows use an allowlist.
Provider fields include identity, auth/endpoint, shared concurrency/schedules/context, generation defaults, `default_model` and the reasoning inventory/default.
Nested model rows allow `model`/`context_window`/`reasoning_efforts`/`default_reasoning_effort`/`generation`/`extra`/`provider_options`, not separate auth, concurrency or schedules.
The parser treats model rows as OPTIONAL OVERRIDES rather than an allowlist: a default-only save omits `models` and a `default_model` need not occur in `models`.
A blank default falls back to the first parsed override or returns `default_model_invalid`.
Non-map, duplicate or partially populated model rows, invalid numbers and invalid/non-object JSON are errors; wholly blank rows are ignored.
Optional generation keys stay absent until supplied, concurrency defaults to 3 and core owns authoritative provider/range/context validation.
Reasoning inventories accept comma/newline strings or lists, trim/deduplicate in order and NEVER invent a default from the first entry; absent model inventory inherits provider inventory, an explicit `[]`/blank stays unrestricted, and an effective nonnil default must belong to its effective nonempty inventory.
Known providers resolve through a catalog whitelist without creating atoms from client input; unknown strings remain for core validation.
OAuth-only forces `oauth`; OAuth drops `api_key`/`api_key_env_var`/`api_key_env` and API-key mode drops `oauth_file`.
Credential drafts and parsed profiles emit `api_key_env_var`; legacy `api_key_env` input is accepted, with canonical key presence winning even when blank or nil.
Legacy `model_id`/`context_window`/`reasoning_effort` adapt to canonical fields without model/reasoning_effort shadows.
Every provider account is created through the add-account wizard or the "Add model" mini-wizard, and an explicit typed id or the provider-derived `editor_identity/4` supplies its identity.
`field/2`, `rows/1`, `string_list/1` and `provider_atom/1` provide shared key/row/inventory/catalog handling.
## ModelProfileHelpers and Detached Events
`ModelProfileHelpers` exposes canonical delegates for `provider_profiles`, `provider_profile_draft`, `new_provider_profile_draft`, `parse_provider_profile_params`, `put_in_provider_profiles` and `set_default_provider_profile`.
Compatibility `move_model_profile` writes canonical providers and delegates to the same no-op-preserving `ProviderProfiles.move/3`.
`generate_profile_id/1,2`, `profile_id/1` and `id_collision?/3` support atom/string ids and collision-safe slugs/`profile-N` names.
`parse_model_profile_params/2` remains the LEGACY atom-keyed flat parser, not canonical Save.
`ModelProfileEvents` functions take socket then params and return LiveView tuples, never sockets to double-wrap.
`editing_profile_id` is an account id or the atom `:new` for an unsaved account, so the saved string id "new" remains an ordinary account.
Creation uses a nil original id for collision detection and update; Add creates only draft state, Edit snapshots/toggles an existing account and unknown ids no-op.
`model_profile_form_change` overlays the form on the detached draft; row add/remove changes only draft lists and an invalid/negative/out-of-range removal is a no-op.
Add records `profile_generated_id` from its initial `profile-N` placeholder; explicit id-targeted change events invalidate that marker, and edit/cancel/success clear it.
Save derives new identity against the current config without replacing the raw detached submission, so validation failures and provider changes never freeze an automatic identity prematurely.
Row clicks carry no form input, so `phx-change` snapshots must preserve typing before rerender.
Cancel clears editor assigns without changing `file_config`.
Save snapshots submitted drafts before identity/parser validation and retains translated string-keyed `profile_form_errors` for invalid fields or sections.
A parsed Save creates `profile_save_token` and explicitly calls the parent `persist_file_config(config, socket, success_msg, editor_token: token)`.
Delete of the currently edited account creates its own token and uses the same `/4` overload; unrelated Delete uses `/3` and never captures or replaces an existing editor token.
Move and Default also retain `/3` with no editor options.
`persistence_succeeded/2` clears only a matching reference token after confirmed persistence; `persistence_failed/3` retains its draft and clears the matching token.
Draft mutations and editor changes invalidate old tokens, so stale callbacks cannot close newer edits.
Move persists only a real move and never calls the parent persistence boundary for a no-op; Default persists through the parent.
`advanced_open?/1` inspects provider and model generation/`extra`/`provider_options` in BOTH flat parser drafts and nested UI generation maps.
An explicit `profile_advanced_open` boolean overrides the auto rule and resets on add/edit/cancel/success.
`maybe_put_gen_opt/3` remains a legacy compatibility helper rather than the canonical connection-test path.
`JsonObject.decode/2` is the shared pure JSON-object decoder for legacy and canonical `extra`/`provider_options` fields, preserving the exact field-specific object/invalid-JSON errors.
Callers retain preprocessing and error wrapping: legacy fields are trimmed strings with blank input omitted, while canonical fields also accept maps and stringify their keys.
## CategoryEvents
`CategoryEvents` owns the generic events `save_category`, `save_search`, `reset_key`, `select_appearance_accent`, `add_list_entry`, `remove_list_entry` and `save_api_key`, whitelisted through its own event map.
`persist_file_config/3,4` is the page's ONE config write entry point (public: the parent's `persist_file_config/3,4`, `ModelProfileEvents` and `ProviderPanelEvents` call it): it starts `ConfigSave` only when `config_loaded_scope == ConfigSave.scope(socket)`, so a whole-file write is never built from another scope's snapshot.
A refused start fails the owning editor token and flashes the not-loaded message; `{:started, _}` invalidates older config-load generations.
`apply_config_receipt/2` owns the receipt presentation (authoritative `file_config`/warnings/`config_status`, success or failure flash) and `apply_saved_credentials/2` owns the post-credential readback.
`add_list_entry`/`remove_list_entry` mutate only the in-memory draft, and `reset_key` delegates to `SearchEvents.handle_reset_key/2` while clearing the appearance draft.
`save_api_key` rejects a blank key, invalidates any running connection test, then writes credentials locally in the LiveView process (reading `config_status/0` and `EvoGit.Config.credentials/0` right after the write) or, for a remote node, saves over RPC and force-reloads that node's config.
`select_appearance_accent` stores the accent draft only; the shell accent (`@accent_color`) belongs to `EvoDashWeb.LiveHooks.Appearance`, so neither a draft nor a save here repaints it.
## LlmTestEvents
`LlmTestEvents` owns the `test_llm` and `select_test_profile` events plus the sequence-scoped test state (`test_profile_id`, `llm_test_seq`, `llm_test_status`).
`invalidate_llm_test/1` bumps the sequence and clears status so a superseded result can never render, and `assign_test_config/2` reconciles `test_profile_id` against authoritative canonical account/model values.
Connection-test results use nested `{{:llm_test_result, seq, scope}, result}` tags guarded by sequence, target/BEAM-node/selection scope and testing state; legacy unscoped results are ignored.
Pending remote targets cannot start a local connection test.
Connection tests pass `resolved.model_spec` and `resolved.generation_params` together to `SystemCheck.llm_test` or `RemoteNode.llm_test`; never reconstruct a partial option list.
Remote tests resolve on the VIEWED node through RPC so OAuth import, managed credential paths and named API-key environment variables are that node's, never the dashboard's.
## AsyncResults
`AsyncResults` owns every async result and broadcast handler the parent routes: `node_data_loaded/5`, `config_saved/2`, `saved_status_loaded/4`, `credentials_saved/3`, `config_load_wait_down/1`, `custom_agents_loaded/3`, `custom_tools_loaded/3`, `auth_status_loaded/4`, `llm_test_result/4`, `scheduler_config_updated/2`, `node_selected/2`, `remote_connection_status/2`, `remote_connect_result/3`, `bootstrap_complete/3`, `task_info/2` and `reload_tasks/1`.
Node-data results are applied once per captured node/generation, replace `schemas_by_category` with the authoritative filtered map and re-resolve the active category against it with the `:llm` fallback.
Remote config reload unwraps SafeCall's `{:ok, {:ok, config}}` response; a successful write with a failed authoritative refetch remains a saved config with an unavailable-config warning.
`scheduler_config_updated/2` re-assigns the viewed node's scheduler config and never reloads user config, and `node_selected`/`remote_connection_status` re-scope config and remote assigns.
`TaskInfo`/`reload_tasks` handlers implement the shared node-filtered `{:task_updated, ...}`/`{:task_deleted, ...}` forwarding plus the 300 ms debounce reload (`EvoDashWeb.LiveHooks.NodeAware`).
`custom_agents_loaded/3` and `custom_tools_loaded/3` always clear their own loading flag first, then apply the payload only when the result's captured node still matches `current_node`, so a node switch drops a late result without ever wedging the flag.
`custom_agents_loaded/3` maps `{:ok, %{agents:, model_selection_script:, script_status:}}` into `custom_agents`/`model_selection_script`/`script_status` and degrades every error or unexpected shape to `{[], "", :ok}`, exactly like the former inline loader.
It deliberately touches ONLY those three assigns, so a late refresh never wipes an open editor's `editing_agent_id`, `script_save_error` or `script_test_results`.
## RemoteEvents and RemotePanel
`RemoteEvents` owns the remote-connection category behaviour: `add_remote_target`, `cancel_edit_remote_target`, `edit_remote_target`, `toggle_remote_advanced`, `remote_form_change`, `save_remote_target`, `delete_remote_target`, `bootstrap_remote_target`, `confirm_bootstrap_restart`, `cancel_bootstrap_restart`, `connect_remote_target`, `disconnect_remote_target` and `retry_remote_connection`.
Bootstrap progress is `%{stage: nil | 0..4, active: boolean, status: :active | :success | :error, error: term}` and stays in assigns so the panel can render each step.
`RemotePanel` renders the `:remote_connections` category (`remote_connections_panel/1`) plus its pure render helpers (`bootstrap_step_class/3`, `remote_target_dot_color/3`) and holds NO state.
This leaf never connects on its own: connection lifecycle lives in `EvoGit.RemoteConnection`, and page data arrives from the destination page's own loads.
## ConfigIO and Credential Boundaries
`load_file_config/0` reads `Config.resolve/0` and `canonicalize_file_config/1` normalizes accounts and removes legacy shadows.
`model_selections/1` delegates to `Schema.model_selections/1` and returns credential-free account/model/reasoning metadata.
Persisted task/picker selections contain only string-keyed `provider_profile_id`, `model` and optional `reasoning_effort`.
`resolve_model_spec/2` delegates to `Schema.resolve_model_spec/2` and is SERVER-ONLY because the result includes `provider_profile`/`runtime_profile`/`generation_params` that may contain secrets; the resolved `model_spec` is a ReqLLM-ready identifier, NOT the persisted canonical task map.
Never send the resolved object or its `generation_params` to browser state, ChatHistory, DOM option values or `push_event` payloads.
Core owns runtime resolution, validation and credential composition; do not add dashboard fallbacks that conceal missing credentials or rejected selections.
`load_scheduler_config/0` uses SafeCall with an empty-map fallback for a stopped scheduler.
`build_config_from_category_params/4` parses supplied schemas, deep-merges and deletes explicitly emptied paths.
`generic_schema?/1` excludes `:model_profiles`/`:provider_profiles` and `llm.models`/`llm.providers`/`llm.default_provider_profile` paths and their descendants with mixed atom/string spellings because dedicated forms own them.
Generic category/search conversion and reset handlers share that guard, and `parse_key_path/2` accepts only complete known generic schema paths rather than recombining individually allowed segments.
Booleans parse before nil/blank and only `"true"` is true; malformed floats are neither written nor deleted and `list_of_strings_value/1` preserves `[]` while absent/non-list signals deletion.
`update_runtime_from_file_config/2` best-effort pushes scheduler limits plus `runtime_model_opts/1` — the canonical-safe `ModelSelection.config_opts/1` list of `model_profiles` with `provider_profiles` and `model_selection_config` — so the running scheduler keeps its provider-profile selection snapshot, then reloads scheduler config on success; a runtime-push failure does not invalidate an already-written file.
A legacy-only configuration yields no selection snapshot to keep, which is not an error.
Category/provider/model/key-path conversions use schema/catalog whitelists rather than client-derived atoms.
`SearchEvents` resets in memory and delegates parent persistence/reload, handling invalid key paths only.
## Config Read/Write Freshness
`ConfigIO.load_file_config/0` is the leaf's ONLY config read (`EvoGit.Config.resolve/0`); no function here reads or writes `config.toml`/`credentials.toml` with `File` APIs.
Whole-file config writes go `persist_file_config/3,4` → `ConfigSave.start/4` → `NodeContext.save_user_config/2` → core `EvoGit.Config.save_user_config/1`; credentials go `NodeContext.save_credentials/2` → core `EvoGit.Config.save_credentials/1`.
Custom-agent and model-selection-script saves write `<config_dir>/agents.toml` and remote-target CRUD writes `<config_dir>/remote_connections.toml` — separate files that never pass through the config save APIs.
`ConfigSave.save/3` re-reads the authoritative config AFTER the write from the SAME supervised task (local `ConfigIO.load_file_config/0`, remote `NodeContext.get_resolved_config/1` → `EvoGit.Config.resolve/0`); both the receipt's `file_config` and the `candidate_written?/2` decision for an unacknowledged write depend on that read observing the just-written file.
`ConfigSave` contains NO separate reload step: the single `NodeContext.save_user_config/2` write runs `EvoGit.AgentScheduler.RemoteAPI.save_user_config/1` → `EvoGit.Config.save_user_config/1` followed by its best-effort scheduler reload, so both local and remote saves order save → reload → authoritative re-read.
The only explicit `NodeContext.reload_remote_config/1` call site is the REMOTE credential save in `CategoryEvents`; the local credential save relies on `EvoGit.Config.save_credentials/1` writing ReqLLM keys in-process and then re-reads status/credentials.
Config freshness guards here are private per-page counters (`settings_load_seq`, `config_status_token`, `auth_status_seq`) plus `ConfigSave.scope/1`; no core config generation/token is threaded through any loader.
After a receipt the parent re-reads `config_status` (→ `resolve/0`) and OAuth statuses, and pushes runtime options to the LOCAL scheduler only.
`EvoGit.Config.config_status/0` takes `validation_errors` from the CALLER's process dictionary (written by `resolve/0` in that same process), so a resolve that validates elsewhere loses them and can report `ok?: true` for an invalid file.
`file_config` is a per-session snapshot refreshed only by mount, `handle_params` (node switch / URL navigation via `NodeData.start/3`), a save receipt, or the custom-agent loaders — a category switch re-uses the snapshot and starts no new read.
The page subscribes only to `"scheduler_config"` at mount and has no `"config"` subscription, so a config edit made outside the page never reaches an open page and the next whole-file save overwrites it from the stale snapshot.
## ConfigSave Ownership
`ConfigSave.start/4` returns `{:started, socket}`, `{:rejected, reason, socket}` or `{:failed, {:startup, reason}, socket}` and never optimistically assigns `file_config`.
`complete/2` consumes the entire nested SafeCall message and returns `{:saved, receipt, socket}`, `{:failed, receipt, socket}` or `{:stale, unchanged_socket}`.
Requests bind a unique reference and `{target_id, beam_node}`, carry an explicit optional `editor_token` and prevent overlapping writes owned by the same LiveView.
`ConfigSave` rejects pending target contexts that resolve to `node()`, but permits a known same-BEAM alias only when the parent supplies the current target's authoritative `remote_status: %{phase: :connected}` (NodeAware's contract).
A missing/non-connected status rejects the same-BEAM alias; the parent must refresh status on target changes and never reuse another target's connected status.
Both local and remote whole-file saves are asynchronous, so event-return HTML, immediate disk reads and immediate flash assertions are not completion barriers.
Mounted tests must await the owned `settings_config_saved` result and its applied `file_config` or success/failure presentation before inspecting persisted configuration.
`ConfigSave` captures the target scope, canonical candidate and explicit callbacks, not arbitrary process dictionary values; process-local test overrides depend on the downstream resolver's caller-chain support across `Task.Supervisor` children.
Saved receipts contain authoritative `file_config`, warnings, scope, `success_msg` and `runtime?`, while failed receipts contain `reason` instead of `file_config`/warnings.
A confirmed write followed by a failed reload remains saved with the confirmed candidate and a tagged `config_reload` warning.
An unacknowledged write (writer error/exit — e.g. the shared write path's scheduler reload timing out AFTER the file landed) is decided by the authoritative read: a read matching the written candidate is a saved receipt with NO warning, while the previous config or an unreadable config keeps the writer's reason as the failure.
Verification compares a persistence projection (both sides canonicalized, legacy flat `[llm]` mirrors/`models` dropped, nil-valued keys dropped) because a TOML round trip cannot reproduce them; it never duplicates the runtime push, which stays the parent's single best-effort push after the receipt lands.
The helper settles matching editor tokens but leaves authoritative config assignment, test-selection reconciliation, status/OAuth refreshes and flashes to the parent.
`invalidate/1` detaches presentation ownership while retaining a live-worker guard; stale completions change no assigns or loading state.
Preserve `config_save_owner` across scope resets, invalidate pre-save config-load generations and refetch authoritative configuration before constructing a new scope's candidate.
Ownership is per LiveView rather than a distributed file lock, so remounts, other tabs and timed-out remote writes require core-level serialization for cross-page ordering.
## NodeData and AuthStatus
`NodeData.start/3` captures node/category/`all_schemas`, loads platform/config/status/agent/tool data under `TaskSupervisor` + `SafeCall` and sends `{tag, node, category, {:ok, results} | {:error, reason}}`.
Results include `platform_os`/`filtered_schemas_by_category`/`file_config`/`config_status`/`remote_config_error`/`custom_agents`/`custom_tools_status`.
`filtered_schemas_by_category` is ALWAYS present (`load/2` and `error_results/3` both set it from the captured unfiltered `all_schemas_by_category` plus the viewed node's platform/nix gating), so it never arrives empty or missing; the parent assigns it as the authoritative `schemas_by_category` and re-resolves the active category against it with the `:llm` fallback.
Local config reads `ConfigIO`/`Config` directly and remote config reads the FULL `get_resolved_config`; `error_results/3` supplies conservative platform/schema/agent/tool values and a visible `remote_config_error`.
`degraded_config_status/0` is `%{ok?: false, missing: [], warnings: [], validation_errors: []}`.
Agent fetch tolerates odd shapes, tool fetch normalizes lists and preserves `{:error, reason}`, and remote status failures stay explicit.
`NodeData.fetch_custom_agents/1` is the PUBLIC normalized reader behind the async refresh: `{:ok, %{agents:, model_selection_script:, script_status:}}` or `{:error, term()}` (`{:error, :unexpected_result}` for an odd payload), and it is the only place the agents shape is normalized.
`NodeData.fetch_custom_tools_status/1` remains the sole normalizer of the custom-tool status map.
Platform filtering protects hidden sandbox fields on save; Linux uses the local scheduler sandbox backend through `PageState.sandbox_backend/1` and remote pages use the `PlatformInfo` fallback.
`NodeData` and `AuthStatus` ignore `start_child` failure, so the always-send guarantee applies only after a successful spawn.
`AuthStatus.credential_profile/1` adapts canonical or legacy profiles to credential-only `model`/`auth_mode`/`oauth_file` and never includes API secrets.
`statuses/2` includes only OAuth accounts with nonblank ids and `unknown_statuses/1` supplies neutral entries.
Status entries contain `state`/`expires`/`account_id`/`login_instructions`/`oauth_file`; `no_credentials`/`invalid_credentials` become missing, `managed_file_unwritable` alone becomes unwritable and unexpected transports/verdicts become unknown.
Credential verdict and managed-path calls run on the viewed node; login instructions are static and renderer fallback may use the configured path.
A profile's verdict renders in its OWN credential-status block, while the page-level core "Missing Configuration" banner describes the WHOLE config and may still name a vendor login command (e.g. `claude setup-token`) when another account's credential is unusable, so guidance assertions are scoped to one profile's block, never page-wide.
That banner is NOT fixture-driven: it renders only while `EvoGit.Config.config_status/0` is not `ok?`, and its api_key check reads ReqLLM's BEAM-global key store, so a root `mix test` (both umbrella apps in one VM, `:evo_git`'s helper installs `:req_llm, :openai_api_key`) renders no banner and no test may pin it.
Its detail lines come from `EvoDashWeb.ConfigIssues.lines/1` — the SAME lines the layouts banner renders — covering core `warnings` plus one line per schema `validation_error` formatted `joined.key_path: message`, so a validation-error-only status is explained instead of rendering a bare title.
Its trailing call-to-action is model-specific only when `:llm_model` is in `missing` (`EvoDashWeb.ConfigIssues.model_unconfigured?/1`), otherwise it is the model-neutral "Fix the settings listed above…" sentence.
`start/2` sends FLAT `{:settings_auth_status_loaded, node, seq, statuses}`; the parent checks node AND `auth_status_seq` after node-data loads, saves or explicit refresh, never polls.
Two remote calls per OAuth account are not deduplicated and unexpected errors degrade the map through the outer SafeCall.
## Custom Agents, Tools and Peak Helpers
`CustomAgentEvents` functions return SOCKETS rather than LiveView tuples and perform SafeCall-guarded local/remote mutations with translated errors and parent-owned refreshes.
Every post-mutation refresh is ASYNC: a save/delete/script-save/script-test returns the socket after `SettingsLive.refresh_custom_agents/1` and `SettingsLive.refresh_custom_tools/1`, never a blocking RPC.
Both refreshers spawn one `Task.Supervisor` child under `EvoDash.TaskSupervisor` that sends `{:custom_agents_loaded, node, result}` / `{:custom_tools_loaded, node, result}` back to the LiveView, and each sets its own loading flag so the flag clears in the result handler only.
They never reset `editing_agent_id`/`script_save_error`/`script_test_results`, so an in-flight refresh cannot disturb an open editor or a just-returned sample test.
While `custom_agents_loading` is true the parent renders a `#custom-agents-loading` daisyUI `skeleton` placeholder instead of the editor, so the panel never flashes a misleading "no custom agents" empty state.
Script test reloads the cache and evaluates three sample attr maps via core APIs while retaining per-sample errors.
The sibling Agents content renders `CustomAgentsEditor` → `CustomToolsPanel` → `ModelSelectionEditor`, with loaded custom-tool names feeding the whitelist chips.
Peak concurrency is an optional nonnegative integer (0 pauses), timezone is optional, clocks are strict `HH:MM` and start/end must differ.
Blank scheduling fields/rows omit keys and a days-only row with no times is dropped.
`normalize_days/1` handles scalar/list/hidden blanks and trims/downcases/whitelists/deduplicates day vocabulary in order.
`off_peak_holidays` is an optional canonical account key: string-keyed in draft/editor values, blank omits it, and an accepted value must be one of `EvoGit.PeakHours.Holidays.calendars/0` — an unknown calendar is the `off_peak_holidays` field error and never reaches the file.
`off_peak_holidays` round-trips form → draft → parse → `llm.providers` → re-render, so opening an account never loses its calendar.
Public helpers include `parse_peak_fields/1`, `normalize_peak_hours_draft/1`, `valid_clock_time?/1` and `clock_to_minutes/1`.
Errors are `peak_concurrency_invalid`, `peak_hours_invalid_time`, `peak_hours_start_equals_end`, `peak_hours_overlap` and `off_peak_holidays_invalid`.
Touching intervals are legal, but the UI overlap check ignores days and does not split overnight intervals; core validation remains authoritative.
`normalize_peak_hours_draft/1` tolerates non-map rows through `peak_draft_value/2` and guards day lookups, while `parse_peak_fields/1` rejects such rows as `peak_hours_invalid_time`.
## Tests and Constraints
Helper regression suites live in `apps/evo_dash/test/evo_dash_web/live/settings_live/` (`model_profile_helpers`, `provider_profiles_contract`, `config_io`, `navigation` and panel/wizard suites).
The canonical contract suite covers typed multi-model overrides, credentials, detached drafts, CRUD/default migration and default-only parser behavior; the flat-parser suite tests compatibility rather than canonical Save.
Parent-owned new regressions should cover blank/hidden/generated creation identities, explicit ids/names including `profile-N`, multiple same-provider accounts, saved-identity preservation on provider edits, and invalid-save retries before provider changes.
Parent-owned inventory regressions should submit ordered chip lists with blanks/duplicates/custom values, explicit empty versus inherited rows, raw nested generation maps, wholly blank sentinel rows and hidden advanced draft fields through mounted Save.
Nested UI clearing regressions must include `override_reasoning=true` with `[]` or the hidden blank seed and a nonblank obsolete default, verify that only the nested default is dropped, and contrast absent markers, missing inventories and `override_reasoning=false`.
Credential env omission preserves the saved value, while explicit blank, whitespace or nil clears it through both canonical and legacy input aliases, including detached submission over a saved draft.
Leaf-only implementation checks may run in-memory ExUnit modules with `mix run --no-start` without adding test artifacts under production source.
Auth/node integration lives in sibling `auth_status_test.exs` and `settings_live_test.exs` and uses explicit result messages rather than `render_async` for supervised tasks.
Transformations remain pure except documented I/O/runtime/socket boundaries, modules stay cohesive around or below 1000 lines and sibling tests are read-only under this node's scope.
`SafeCall` owns RPC/store/runtime exit and exception handling; do not silently swallow unexpected failures or add defensive rescue around core reads.
