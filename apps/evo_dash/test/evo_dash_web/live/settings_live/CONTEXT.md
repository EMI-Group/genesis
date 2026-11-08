# SettingsLive Support Tests

## Intent

Focused helper, canonical provider-editor and credential-status page contracts live here.
The five suites declare 119 tests and preserve `async: true`; pure helpers neither mount pages nor start shared services.

## API Surface

- `provider_profiles_contract_test.exs` holds 32 pure contracts for `ProviderProfiles`, `ConfigIO`, `AuthStatus` and detached `ModelProfileEvents` sockets.
- Simplified-editor identity contracts distinguish blank or untouched generated ids from explicit identities, allocate provider-derived ids and display names independently across collisions, and preserve saved identity on blank edits including a saved string id `"new"`.
- Detached form-change contracts pin generated-id tracking and explicit identity edits through `_target` without mounting a page or writing configuration.
- Checkbox contracts preserve custom reasoning values and order, distinguish omitted inheritance from explicit empty inventories, strip override sentinels, and clear saved schedule-day selections through hidden empty seeds.
- Minimal-edit round trips retain hidden generation/JSON, OAuth path, endpoint, concurrency, context-window and schedule fields, while invalid nested generation values expose exact input-name error paths and remain intact in drafts.
- Provider parsing pins string-keyed canonical profiles, numeric ordering of nested models, sparse generation overrides, typed numbers/JSON, blank override clearing back to inheritance and untouched draft round trips.
- Reasoning contracts distinguish inherited inventories/defaults from explicit unrestricted model inventories and reject incompatible inherited defaults.
- CRUD contracts pin append/update/rename/move/delete/default semantics, default identity on rename, boundary no-ops, canonical shadow removal, unrelated-setting preservation and legacy one-account-per-row editing.
- Credential contracts pin canonical `api_key_env_var` precedence and explicit clearing, legacy draft normalization, OAuth secret stripping, OAuth-only authentication, managed-path trimming and secret-free unknown-status adapters.
- `model_profile_helpers_test.exs` holds 41 contracts for canonical Add delegates and the deliberately retained legacy single-model parameter parser, including the comprehensive peak/day/window compatibility matrix.
- Canonical Add writes `llm.providers` with string-keyed profiles and explicit `auth_mode`; nil/empty selections leave config unchanged and new drafts remain detached.
- The legacy `parse_model_profile_params/2` API still returns atom-keyed single-model profiles with its older clean-TOML auth rules; these compatibility assertions must not be confused with canonical provider persistence.
- `config_io_test.exs` holds 12 pure contracts: ten category conversions for list-of-strings, boolean and float values and two runtime model-option pushes.
- The canonical runtime push must include `model_profiles`, `provider_profiles` and `model_selection_config`, tested with pure scheduler state update and explicit model resolution; legacy-only pushes must not invent accounts or a selection snapshot.
- `auth_status_test.exs` holds 28 credential-status classification/page contracts, including verdict forwarding, exact fallback and supplied vendor guidance, node/sequence guards, refresh, canonical auth persistence and editing a legacy OAuth row into `llm.providers` without a shadow `llm.models` table.
- Auth page fixtures deliberately seed legacy `[[llm.models]]` rows to exercise migration, while row assertions select the actual mounted canonical provider article by its Edit control and profile id.
- Successful new-profile auth submissions use canonical `default_model` plus a matching nested `models` row and the atom `:new` detached-editor sentinel, assert the nested shape in live and persisted config, and require the exact Provider-profile success message plus persisted auth fields.
- Canonical auth persistence explicitly stores `auth_mode: "api_key"`, drops stale OAuth paths and rejects unsupported OAuth modes while retaining the failed draft without writing it.
- `model_ids_test.exs` holds six retired-id matcher, catalog and mounted-page guards.

## Constraints

Pure suites use the shared test bootstrap, never standalone `ExUnit.start/0` calls, and never patch missing core functions or skip failing integration contracts.
Mounted suites retain per-process `EvoDash.Test.ConfigDir.isolate!/1`, local-only ActiveTasks invalidation and owner-aware async mount settling.
Auth config-directory labels include the OS pid so interrupted or concurrent BEAM runs cannot reuse another run's blocker fixture.
The auth mount funnel drains the view before enumerating owned tasks, monitors every node-data/OAuth load chain under a bounded deadline and fails rather than silently timing out.
Credential injection waits for real loaders to finish and sends the mounted node's current `auth_status_seq`; older and unrequested future sequences and foreign nodes must not replace the baseline.
Auth save assertions wait for `config_saving` and `config_save_request` to clear through the authoritative writer receipt, then settle the receipt's OAuth refresh before rendering or reading persistence.
Every login verdict, managed-file path and writable-path remedy stays asserted; full supplied vendor instructions normalize only HTML whitespace, not their wording.
No test may make a real LLM request or rely on shared credentials, scheduler mutation or global ChatHistory.
The larger helper file intentionally keeps the legacy parser with its shared peak/day edge-case matrix, while the canonical contract file keeps parse/draft/CRUD round trips together without additional test modules or shared fixtures.
Production source and core modules are read-only from this node.

## Coverage Boundaries

Multi-model contracts here exercise pure parsing/draft round trips and sparse inheritance, not a mounted multi-model Save → remount/reload cycle.
Auth save contracts assert live canonical providers and `EvoGit.Config.user_config()` persistence with no legacy shadow, but do not remount to prove restored editor state.
The stale-result tests here cover OAuth credential-status node/sequence guards only, not config reload or writer completion generations.
No suite here injects a configuration-writer failure or exercises category reset/reset-all preservation of canonical providers and defaults.
The `:managed_file_unwritable` classification tests concern OAuth credential files, not `config.toml` write failures.
`auth_status_test.exs`'s `blocked_oauth_file/1` creates a regular file named `blocker` and returns its nonexistent child `blocker/auth.json`; this is deterministic invalid-path fixture data, not a suspended process, FIFO, lock or blocking runner.
The legacy OAuth migration save preserves this path for both OAuth accounts, so its appearance in scheduler update options is expected and does not establish that the path caused a scheduler call timeout.
No suite in this helper directory installs an app-env blocking runner or suspends the scheduler; `config_io_test.exs` exercises `State.do_update_config/2` on local state values, not the registered scheduler process.
`await_profile_save/1` waits for save markers to clear and then drains OAuth refresh tasks, but marker clearance alone is not success: the exact success-flash assertion must remain because a failed runtime scheduler update can also finish the writer request.
A longer test polling deadline cannot repair a runtime `GenServer.call` timeout already returned as a failed save acknowledgement.
Mounted canonical editor save/reload/reset regressions belong with the parent `settings_live_test.exs`; pure shape and draft regressions belong in `provider_profiles_contract_test.exs`, and config writer atomicity belongs to the core-owned configuration tests.

## Validation and Integration Boundary

Pure canonical parser contracts accept default-only profiles with absent or empty `models` and omit the stored `models` key; configured model rows are overrides, not an allowlist restricting `default_model`.
`provider_profiles_contract_test.exs` declares these contracts as "default-only profiles round-trip without manufacturing model overrides" and "models are overrides and do not restrict the default model", and its submission contract preserves explicit empty rows while allowing a nonblank default-only profile.
Mounted auth persistence success fixtures still include nested model rows matching their default, so they do not establish default-only Save → remount behavior.
The `profile save round-trip (auth_mode / oauth_file persistence)` describe in `auth_status_test.exs` covers OAuth auth/path persistence, explicit API-key mode with stale-path removal, blank-path omission, OAuth-only mode inference, legacy migration and unsupported-auth rejection.
The four new-profile success cases assert the nested model shape in live config and persistence without relaxing auth verdicts or successful-save assertions.
The unsupported-auth case retains its invalid authentication fixture and verifies rejection without persistence.
Focused validation uses `mix test apps/evo_dash/test/evo_dash_web/live/settings_live/auth_status_test.exs --only 'describe:profile save round-trip (auth_mode / oauth_file persistence)' --seed 0` (also seed 1) and passes all six selected tests with 22 excluded in each run.
This focused run does not establish full-file, directory or broader dashboard-suite success.
The pure canonical helper slice is `mix test apps/evo_dash/test/evo_dash_web/live/settings_live/provider_profiles_contract_test.exs apps/evo_dash/test/evo_dash_web/live/settings_live/config_io_test.exs apps/evo_dash/test/evo_dash_web/live/settings_live/model_profile_helpers_test.exs --seed 1` and contains 85 passing tests.
The full helper subtree contains 119 tests and passes with `mix test apps/evo_dash/test/evo_dash_web/live/settings_live --seed 0` and `--seed 1`.
Mounted auth identity assertions pin the profile heading and separate provider text within the account article selected by its Edit control, including the sibling article retained after stripping credential-status blocks.
These row-scoped identity checks preserve the credential verdict, managed-path, writable-path remedy and vendor-guidance surface-split assertions.

## UI Simplification Survey

`auth_status_test.exs` declares apply/render/classification/stale/refresh/save/Quick Setup groups at lines 76, 171, 364, 405, 470, 489 and 661 respectively.
Auth events use `render_hook` with compatibility names `edit_model_profile`, `add_model_profile`, `save_model_profile`, `refresh_auth_status`, `select_llm_provider` and `select_llm_model`, rather than submitting rendered forms.
Auth row helper `profile_row/2` at line 857 finds exactly one `article` containing `button[phx-click="edit_provider_profile"]` whose `phx-value-profile_id` matches the saved account id.
Auth block helpers at lines 876 and 889 locate `[role="status"]` by its `button[phx-click="refresh_auth_status"]` and matching `phx-value-profile_id`; status-line counts also depend on that event attribute.
The unwritable surface-split test additionally pins `id="provider-profile-edit-form"`, and Quick Setup contracts pin `phx-submit="save_api_key"` and `name="api_key"` presence for API-key-capable providers and absence for OAuth-only providers.
Auth saves pin the exact `Provider profile saved.` flash, detached `editing_profile_id == :new`, canonical `llm.providers`, absent legacy `llm.models` and authoritative async completion.
`model_ids_test.exs` declares rendered Quick Setup guards at lines 126 and 136 and drives `select_llm_provider` (`provider_id`) and `select_llm_variant` (`variant_id`) while requiring a real current `provider:model` string for non-custom populated catalogs.
`provider_profiles_contract_test.exs` keeps detached form/row/cancel and advanced-auto-open contracts, including `toggle_profile_advanced`, `profile_advanced_open` and `advanced_open?/1`; these are helper API assertions, not rendered disclosure requirements.
`model_ids_test.exs` has a one-pass owner-filtered mount wait with a silent 5-second timeout, unlike the auth suite's repeated drain and failing 30-second budget.
Focused commands from the umbrella root are `mix test apps/evo_dash/test/evo_dash_web/live/settings_live --seed 0` or individual filenames, with `--only 'describe:credential status render (injected result)'` and `--only 'describe:Quick Setup OAuth-only provider'` useful for auth UI work.
The full-subtree seed-0 validation includes all mounted auth render/save and pure helper contracts; it does not establish broader dashboard-suite success.

## Routing Table

This directory has no child directories.
