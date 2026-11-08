# SettingsLive Support Tests

## Intent

Focused helper, canonical provider-editor and credential-status page contracts live here.
The five suites declare 130 tests and preserve `async: true`; pure helpers neither mount pages nor start shared services.

## API Surface

- `provider_profiles_contract_test.exs` holds 39 pure contracts for `ProviderProfiles`, `ConfigIO`, `AuthStatus` and detached `ModelProfileEvents` sockets.
- Simplified-editor identity contracts distinguish blank or untouched generated ids from explicit identities, allocate provider-derived ids and display names independently across collisions, and preserve saved identity on blank edits including a saved string id `"new"`.
- Detached form-change contracts pin generated-id tracking and explicit identity edits through `_target` without mounting a page or writing configuration.
- Checkbox contracts preserve custom reasoning values and order, distinguish omitted inheritance from explicit empty inventories, strip override sentinels, and clear saved schedule-day selections through hidden empty seeds.
- Explicit nested reasoning overrides with an empty inventory must remove a stale `high` default even when the submitted default remains `high`, for both boolean and string override flags; legacy unrestricted rows without that UI sentinel retain their defaults.
- Default-only helper contracts pin `_target`-directed name/select synchronization, save without a prior change event, blank validation and correction, UI-helper stripping, absent/empty/blank model-row preservation and last-row removal followed by Add.
- Advanced credential-source contracts round-trip `api_key_env_var` through detached submissions, preserving omitted values and clearing explicit blanks without leaking the legacy key.
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
- `auth_status_test.exs` holds 32 credential-status classification/page and rendered-editor persistence contracts, including verdict forwarding, exact fallback and supplied vendor guidance, node/sequence guards, refresh, canonical auth persistence and editing a legacy OAuth row into `llm.providers` without a shadow `llm.models` table.
- The rendered-editor reasoning regression seeds a model's `high` default, changes only its checkbox inventory to the hidden `[""]` sentinel with explicit `override_reasoning = "true"`, then submits the real form without blanking its still-selected `high` default.
- Both change and submit serialize the rendered form, the change leaves disk untouched, and the owned writer receipt plus remount must preserve exactly an empty model reasoning inventory with no model default or UI sentinel.
- Default-only mounted regressions seed `models = []`, require rendered `default_model_name`/select synchronization and local blank rejection, then pin core inventory rejection without changing live config or on-disk bytes while retaining the no-row editing UI.
- Both mounted regressions correct the core-invalid inventory through the rendered Add model row button and real form changes, save successfully, remount the matching nested model/default and prove `default_model_name` never persists.
- The rendered API-key-source state machine preserves a closed Advanced field through an unrelated save, changes its value with the real form, remounts, explicitly clears it and remounts again; omitted-field preservation remains covered by the detached-submission helper contract.
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
The original auth-mode/OAuth-file save contracts assert live canonical providers and `EvoGit.Config.user_config()` persistence with no legacy shadow, while the rendered API-key-source and model reasoning-clear contracts additionally remount to prove restored editor state.
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

Pure canonical parser contracts accept default-only profiles with absent or empty `models` and omit the stored `models` key; helper-level configured rows are overrides rather than an allowlist restricting `default_model`.
The production core validator still rejects default-only account fixtures with `default_model must be one of []`, independently of the editor's helper-level acceptance and synchronization.
`provider_profiles_contract_test.exs` declares the helper contracts as "default-only profiles round-trip without manufacturing model overrides" and "models are overrides and do not restrict the default model", and its submission contract preserves explicit empty rows while allowing a nonblank default-only profile.
Default-only helper synchronization contracts pin targeted name/select changes, save without a prior change event, blank validation/correction and last-row transitions without manufacturing model rows.
The two mounted default-only regressions preserve these UI contracts but distinguish them from successful core persistence: a nonblank default with no model rows receives `default_model must be one of []`, leaves disk/live config unchanged and retains the draft.
Successful Save → remount requires explicitly adding a nested inventory row matching the chosen default; this core limitation remains outside the test node's scope.
The actual rendered reasoning-checkbox clear and closed-Advanced API-key-source state machines pass, including persistence and remount; no production changes or input weakening are needed for those cases.
Mounted auth persistence success fixtures include nested model rows matching their default and do not establish default-only Save success.
The `profile save round-trip (auth_mode / oauth_file persistence)` describe in `auth_status_test.exs` covers OAuth auth/path persistence, explicit API-key mode with stale-path removal, blank-path omission, OAuth-only mode inference, legacy migration and unsupported-auth rejection.
The four new-profile success cases assert the nested model shape in live config and persistence without relaxing auth verdicts or successful-save assertions.
The unsupported-auth case retains its invalid authentication fixture and verifies rejection without persistence.
Focused validation uses `mix test apps/evo_dash/test/evo_dash_web/live/settings_live/auth_status_test.exs --only 'describe:profile save round-trip (auth_mode / oauth_file persistence)' --seed 0` (also seed 1) and passes all six selected tests with 22 excluded in each run.
This focused run does not establish full-file, directory or broader dashboard-suite success.
The pure canonical helper slice is `mix test apps/evo_dash/test/evo_dash_web/live/settings_live/provider_profiles_contract_test.exs apps/evo_dash/test/evo_dash_web/live/settings_live/config_io_test.exs apps/evo_dash/test/evo_dash_web/live/settings_live/model_profile_helpers_test.exs --seed 1` and selects 92 tests.
Pure helper-slice success alone does not establish mounted Save → remount success; the full subtree includes both the unchanged no-row fidelity contracts and the rendered core-rejection/correction flows.
The full helper subtree contains 130 tests and runs with `mix test apps/evo_dash/test/evo_dash_web/live/settings_live --seed 0` or `--seed 1`.
Scoped validation passes all 130 tests at both seed 0 (5.5 seconds ExUnit time) and seed 1 (6.8 seconds ExUnit time).
Scoped formatting passes with `mix format --check-formatted apps/evo_dash/test/evo_dash_web/live/settings_live/auth_status_test.exs`.
These runs establish leaf-subtree coverage only, not parent-file or broader dashboard-suite success.
Mounted auth identity assertions pin the profile heading and separate provider text within the account article selected by its Edit control, including the sibling article retained after stripping credential-status blocks.
These row-scoped identity checks preserve the credential verdict, managed-path, writable-path remedy and vendor-guidance surface-split assertions.

## UI Simplification Survey

`auth_status_test.exs` declares apply/render/classification/stale/refresh/rendered-editor/save/Quick Setup groups at lines 76, 171, 370, 411, 476, 495, 715 and 887 respectively.
Auth events use `render_hook` with compatibility names `edit_model_profile`, `add_model_profile`, `save_model_profile`, `refresh_auth_status`, `select_llm_provider` and `select_llm_model`, rather than submitting rendered forms.
Auth row helper `profile_row/2` at line 1083 finds exactly one `article` containing `button[phx-click="edit_provider_profile"]` whose `phx-value-profile_id` matches the saved account id.
Auth block helpers at lines 1102 and 1115 locate `[role="status"]` by its `button[phx-click="refresh_auth_status"]` and matching `phx-value-profile_id`; status-line counts also depend on that event attribute.
The unwritable surface-split test additionally pins `id="provider-profile-edit-form"`, and Quick Setup contracts pin `phx-submit="save_api_key"` and `name="api_key"` presence for API-key-capable providers and absence for OAuth-only providers.
The rendered-editor persistence describe drives actual Edit buttons and `form("#provider-profile-edit-form", overrides)` change/submit events rather than the compatibility hooks used by the auth fixtures.
Closed Advanced/custom-effort ordering round trips already belong to the parent `settings_live_test.exs`, and exact catalog suggestions, unchecked suggested choices and custom-value order belong to sibling `components/provider_profile_fields_test.exs`; this leaf does not duplicate those matrices.
The parent-file direct-hook nested-generation fixture's restoration of a nonblank model `high` default is owned outside this leaf and is not repaired here.
Auth saves pin the exact `Provider profile saved.` flash, detached `editing_profile_id == :new`, canonical `llm.providers`, absent legacy `llm.models` and authoritative async completion.
`model_ids_test.exs` declares rendered Quick Setup guards at lines 126 and 136 and drives `select_llm_provider` (`provider_id`) and `select_llm_variant` (`variant_id`) while requiring a real current `provider:model` string for non-custom populated catalogs.
`provider_profiles_contract_test.exs` keeps detached form/row/cancel and advanced-auto-open contracts, including `toggle_profile_advanced`, `profile_advanced_open` and `advanced_open?/1`; these are helper API assertions, not rendered disclosure requirements.
`model_ids_test.exs` has a one-pass owner-filtered mount wait with a silent 5-second timeout, unlike the auth suite's repeated drain and failing 30-second budget.
Focused commands from the umbrella root are `mix test apps/evo_dash/test/evo_dash_web/live/settings_live --seed 0` or individual filenames, with `--only 'describe:credential status render (injected result)'` and `--only 'describe:Quick Setup OAuth-only provider'` useful for auth UI work.
The full-subtree seed-0 validation includes all mounted auth render/save and pure helper contracts; it does not establish broader dashboard-suite success.

## Routing Table

This directory has no child directories.
