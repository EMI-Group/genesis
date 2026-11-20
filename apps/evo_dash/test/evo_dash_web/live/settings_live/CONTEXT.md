# SettingsLive Support Tests

## Intent

Focused pure-helper, provider-account panel/wizard and credential-status page contracts live here.
The nine suites declare 184 tests; every module is `async: true` except the 6 mounted tests of the sync `NavigationLiveTest`.
Pure helpers neither mount pages nor start shared services.
Config-directory isolation is per process (`EvoDash.Test.ConfigDir.isolate!/1` through the `:config_dir_fun` seam), never a BEAM-global `XDG_CONFIG_HOME` write.

## API Surface

- `provider_profiles_contract_test.exs` — 48, `async: true` (`EvoDashWeb.SettingsLive.ProviderProfilesContractTest`): pure `ProviderProfiles` / `ConfigIO` / `AuthStatus` / detached `ModelProfileEvents` editor boundary (identity, checkbox submissions, default-only model-name helper, `off_peak_holidays` round trip).
- `model_profile_helpers_test.exs` — 34, `async: true` (`EvoDashWeb.SettingsLive.ModelProfileHelpersTest`): the retained legacy `parse_model_profile_params/2` single-model parser and `generate_profile_id/2`.
- `config_io_test.exs` — 12, `async: true` (`EvoDashWeb.SettingsLive.ConfigIOTest`): flat-category conversions and the canonical runtime model-options push.
- `config_save_test.exs` — 6, `async: true` (`EvoDashWeb.SettingsLive.ConfigSaveTest`): the read-verified save receipt of `ConfigSave.save/3`.
- `auth_status_test.exs` — 33, `async: true` (`EvoDashWeb.SettingsLive.AuthStatusTest`): credential-status classification/render, stale guards, refresh, rendered-editor persistence, the auth save round trip and the wizard auth/model steps.
- `model_ids_test.exs` — 6, `async: true` (`EvoDashWeb.SettingsLive.ModelIdsTest`): retired model ids against the catalog and the mounted Settings page.
- `navigation_test.exs` — 23 (`EvoDashWeb.SettingsLive.NavigationTest`, 17, `async: true`; `EvoDashWeb.SettingsLive.NavigationLiveTest`, 6, SYNC): `/settings` category resolution/URL helpers plus the mounted sidebar.
- `provider_panel_live_test.exs` — 13, `async: true` (`EvoDashWeb.SettingsLive.ProviderPanelLiveTest`): the seeded account list and its single expanded editor.
- `provider_wizard_test.exs` — 9, `async: true` (`EvoDashWeb.SettingsLive.ProviderWizardTest`): the account-creation wizard, the per-account model and schedule editors, and the removed-Quick-Setup regression pin.
  Its in-browser sign-in test reads the `#settings-chatgpt-waiting` block AND its `#settings-chatgpt-sign-in-url` link from the CLICK's own `render_click/1` reply, because the stub's queued terminal status (`[:pending, {:ok, …}]`) can be applied the moment the event returns; the rule and its siblings are documented in `../CONTEXT.md` ("deterministic waits").
- `NavigationLiveTest` is the only sync module in this directory: it drives platform/nix gating through the BEAM-global app-env seams `:platform_os_override` and `:nix_available_override`, which the `async: true` `EvoDashWeb.PlatformInfoTest` / `system_live_test` also read (and `SettingsLiveGlobalStateTest` mutates).

## Provider account identity (pure)

`EvoDashWeb.SettingsLive.ProviderProfiles` derives an account's `id` and display `name` from its PROVIDER through `EvoDashWeb.LLMSetup.Identity`, never from a model string.
Collisions allocate the next free suffix independently per field (`zai` → `zai-2` by id, `Z.ai (Zhipu AI)` → `Z.ai (Zhipu AI)-2` by name).
An explicitly typed `profile_id_new`/`name` always wins, including on a legacy saved string id `"new"`.
Editing a saved account keeps its saved identity, even when the provider is changed.
A catalog entry with its own identity slug renders its own id (`openai_compatible` → `openai-compatible`, name `OpenAI-Compatible API`) instead of borrowing the shared `:openai` provider display name.
A blank or untouched generated id stays an automatic placeholder until the user edits it explicitly, and targeted `_target` edits keep the generated identity in sync.
The mounted wizard asserts the same derivation end to end (its preview before any write, and the saved config), while the panel suite drives the edited `profile_id_new` through a real save.

## Reasoning ladder

One stable keyed chip list renders `EvoDashWeb.LLMSetup.Reasoning.efforts/0` — `none minimal low medium high xhigh`, with no `max` entry — plus a SEPARATE inventory-scoped default select.
`xhigh` therefore appears exactly once and the core wire alias `max` never reaches the DOM, in the wizard step and in the expanded detail of the account it created.
Chip submissions carry the rendered hidden blank seed plus the checked value (`%{reasoning_efforts: ["", "xhigh"]}`), because query encoding omits an empty list.
Checkbox contracts preserve custom values and their order, distinguish omitted inheritance from an explicit empty inventory, strip the override sentinel, and clear saved schedule-day selections through hidden empty seeds.
An explicit nested reasoning override with an empty inventory removes a saved `high` default even when the submitted default remains `high`, for both the boolean and the string override flag; legacy unrestricted rows without that UI sentinel retain their defaults.

## Schedule presets and holidays

Preset buttons come from `EvoDashWeb.LLMSetup.Schedule.presets_for_provider/1` and post `apply_provider_schedule` with `phx-value-preset_id`.
Applying a preset sets the draft and reveals the applied strip (`#provider-schedule-applied`); Save then persists concurrency, `peak_concurrency`, `timezone`, `off_peak_days`, `off_peak_holidays` and both peak windows, and the sibling account keeps its own absent schedule (no fan-out).
A later form edit marks the recommendation stale ("modified after applying") while `undo_provider_schedule` stays available.
Undo restores the pre-apply draft verbatim, clears the hint and the applied strip, and a later Save persists the pre-apply values rather than the preset.
`off_peak_holidays` round-trips through the real form (`select#provider-off-peak-holidays[name="off_peak_holidays"]`), is OMITTED while blank, and an unsupported calendar is rejected under its own field key (`off_peak_holidays_invalid`) rather than masquerading as a peak-hours error.
Day selections arrive as the checkbox list with its hidden empty seed (values trimmed, downcased, whitelisted and de-duplicated), a single checked value may also arrive as a bare string, and empty selections are omitted from the saved account.

## Rendered panel and wizard

The LLM category renders ONE guided surface: `#provider-profiles-panel` with a compact account list, at most ONE expanded editor, and the inline account wizard.
Rows are `#provider-profile-<slug>` and carry `data-expanded`; the expanded editor is `#provider-profile-detail-<slug>`, and `edit_provider_profile` toggles it.
Opening a second account collapses the first, so exactly one detail id exists in the document — for seeded accounts and for a wizard-created one alike.
The expanded editor saves identity, models, generation and concurrency (`provider_profile_form_change` / `save_provider_profile` inside the account detail form) with the exact `Provider profile saved.` flash.
Rename, Make default and Delete run through the rendered row actions, and model-row actions (`add_provider_model`, `remove_provider_model` with `phx-value-index`) preserve unsaved nested input while rejecting an emptied collection.
Opening another account replaces the draft and Cancel discards it.
An empty account list offers `add_provider_profile`, and a cancelled wizard persists nothing.
`context_window` is persisted as an integer and OMITTED (never nil) when blank, so the core default applies.
Removing the last model row leaves an authoritative `models == []` draft that a save REJECTS (`default_model must be one of []`) without touching disk or live config, and re-adding a row corrects it.
Two distinct models survive save, reload and remount, including a persisted string id `"new"`; a page reload reads DISK, not the editor's candidate.
The wizard posts `provider_wizard_next` / `provider_wizard_back` / `provider_wizard_change` / `provider_wizard_cancel` / `provider_wizard_save` and renders `#wizard-step-provider` → `#wizard-step-auth` → `#wizard-step-model` → `#wizard-step-reasoning_schedule`.
An OAuth-only provider SKIPS the auth step (3 steps, "Step 2 of 3"), an OAuth-capable provider offers both `phx-value-mode="api_key"` and `"oauth"`, and an API-key-only provider keeps the API-key choice.
Back is disabled on the first step and Next is gated until a provider (and, on the model step, an actual model) is chosen; repeated Back/Next clamp at both ends, and navigation persists nothing.
Saving shows `Provider account saved.`, the first account becomes `default_provider_profile`, and the saved account stays expanded.
A blank model on the save step is refused with the translated `Select a model or enter a custom model name.` message, writes nothing and leaves the wizard open.
Adding a model starts from the account row (`start_add_provider_model`), renders `#provider-model-form-<id>` scoped to THAT account, and saves through `provider_model_save` with the `Model added to the provider account.` flash; the account's default model is not re-pointed and the other account keeps byte-identical config.
Provider and model generation disclosures are native `<details>` elements (`details#provider-profile-advanced`, `details#provider-model-details-<index>`) and stay closed until opened.

## Removed Quick Setup surface

`describe "the removed Quick Setup shortcut"` in `provider_wizard_test.exs` is a REGRESSION PIN, not a feature: it asserts the LLM category renders `#provider-profiles-panel` and a `button[phx-click="add_provider_profile"]`, that no `"Quick Setup"` string renders, and that none of `save_quick_setup`, `select_llm_provider`, `select_llm_variant`, `select_llm_model`, `save_custom_model` or `select_llm_model_shortcut` appears in the HTML.
Those six events must not come back as a second account-creation path; account creation happens in the wizard only.
No suite in this directory drives them, so nothing here persists provider config through them.

## Legacy single-model parser

`model_profile_helpers_test.exs` keeps the retained legacy `parse_model_profile_params/2` single-model parser with its full compatibility matrix, because legacy `[llm]` configuration still normalizes through it.
It pins the `provider:model` string versus ReqLLM map-spec serialization, `context_window` typing, and the peak/off-peak fields (`peak_concurrency` including `0` = hard pause, window order and numeric index sorting, timezone trimming, `off_peak_days` normalization, `off_peak_holidays` whitelisting, blank-row dropping, `start == end` and overlap rejection).
Its `auth_mode`/`oauth_file` block pins OAuth-capable versus OAuth-unsupported versus OAuth-only providers and that the API-key default writes neither key.
`generate_profile_id/2` pins base / `base-2` / `base-3` allocation that skips existing ids, the nil base and the one-arity `profile-N` wrapper.
These compatibility assertions are not canonical provider persistence contracts; the canonical editor path lives in `provider_profiles_contract_test.exs`.

## JSON object parsing coverage
Both async parser suites exercise the shared `JsonObject` decoder through its real callers rather than duplicating helper-only tests.
The legacy suite pins exact nonobject errors for arrays, null, booleans, numbers and strings in both fields, malformed-JSON precedence over peak validation, trimmed nil/empty/whitespace omission, and object-valued provider options remaining separate from the compact model spec.
The canonical suite pins object decoding, malformed/nonobject/whitespace errors for both fields at account and nested-model scope, exact `parse_editor/3` field-path wrapping versus `parse/3` reason unwrapping, direct submitted maps with recursive stringification, and nil/empty clearing of saved overrides.
Whitespace-only canonical JSON is invalid rather than blank, unlike the legacy caller's trimmed inputs.
## Config IO and the runtime push

`config_io_test.exs` pins `:list_of_strings`, `:boolean` and `:float` category conversions, including the absent/blank/scalar delete signal versus an explicit empty list.
`runtime_model_opts/1` must carry `model_profiles`, `provider_profiles` and `model_selection_config` so an explicit task selection still resolves after a Settings save.
A legacy-only `[llm]` configuration yields no invented provider accounts and no invented selection snapshot.

## Save receipts

`ConfigSave.save/3` decides by the AUTHORITATIVE READ: a writer error whose read-back matches the written candidate is a SAVED receipt with no warning, while a read-back still showing the previous config keeps the writer's reason as the failure.
The suite pins both receipts, the rejected-value case, an acknowledged write whose follow-up read fails, a real legacy-fixture round trip, and a genuinely unwritten candidate that fails even when both sides canonicalize identically.
The persistence projection canonicalizes both sides and drops legacy flat `[llm]` mirrors/`models` plus nil-valued keys.

## Credential status

`auth_status_test.exs` pins `AuthStatus.classify/2` and `classify_remote/2` atom-precisely (`{:error, {:managed_file_unwritable, _}}` → `:unwritable`, every other shape unchanged) and the PAGE-level verdicts: `Login detected`, `No subscription login found`, `Login found, managed credential file not writable` plus the managed-file path and the writable remedy.
The mount-time credential load is ASYNC and spawned by the node-data apply, so each baseline verdict is awaited through `await_baseline_verdict/2` before an edit form replaces the summary row.
Credential injection waits for the real loaders and sends the mounted node's current `auth_status_seq`; older, unrequested-future and foreign-node results must not replace the baseline.
`profile_row/2` selects exactly one account `article` by its Edit control and `phx-value-profile_id`; the `[role="status"]` block helpers match the `refresh_auth_status` button, so status-line counts depend on that attribute.
Auth fixtures deliberately seed legacy `[[llm.models]]` rows to exercise migration, while the rendered-editor persistence describes drive the real Edit buttons and the account detail form.
Auth saves pin the exact `Provider profile saved.` flash, the detached `editing_profile_id == :new`, canonical `llm.providers` with no `llm.models` shadow, and authoritative async completion.
`describe "profile save round-trip (auth_mode / oauth_file persistence)"` covers OAuth auth/path persistence, explicit API-key mode with stale-path removal, blank-path omission, OAuth-only inference, legacy migration and unsupported-auth rejection; success fixtures carry a nested model row matching their `default_model`.
`blocked_oauth_file/1` creates a regular file named `blocker` and returns its nonexistent child `blocker/auth.json` — deterministic invalid-path fixture data, not a suspended process, FIFO or lock.

## Retired model ids

`model_ids_test.exs` pins the retired-id matcher (bare id and `provider:model` string, with a longer current id that merely starts with a retired prefix deliberately NOT matching), the catalog's providers/variants/credential keys, and the mounted page.
The rendered half asserts `#provider-profiles-panel` carries no retired id and walks every catalog provider's wizard model step, closing the wizard with `provider_wizard_cancel` between providers.

## Category navigation

`EvoDashWeb.SettingsLive.Navigation` (`resolve/3`, `seed/3`, `category_from_param/2`, `path/2`, `visible?/2`, `available_categories/1`) never yields a category absent from the map it resolved against.
`seed/3` opens an explicit displayable `?category=` and never a gated one, keeps the current category when the params carry none, and drops a current category that is no longer displayable.
`path/2` carries the category, preserves `?node=` and URL-encodes both parts.
The mounted module pins sidebar stability: the seeded and settled nav agree, the nav never advertises a gated category, and it never collapses when the previously active category becomes gated (the menu keeps rendering rather than snapping to an empty sidebar).
Every rendered item opens its pane through `select_category`, stays active and round-trips the URL; an unknown or gated value is a no-op, a later `handle_params` with the same params cannot undo the selection, and a click preserves `?node=`.

## Parent page coupling (`../settings_live_test.exs`)

The parent file declares 84 tests in three modules: 3 async `EvoDashWeb.SettingsLiveParentAdapterTest`, 64 async `EvoDashWeb.SettingsLiveTest` and 17 sync `EvoDashWeb.SettingsLiveGlobalStateTest`.
`SettingsLiveParentAdapterTest` renders the real `SettingsComponents.category_section/1` boundary and calls actual parent change/row/cancel handlers without a mounted page; its third test pins persisted-model connection resolution, inherited generation, API key and provider options through `ConfigIO.resolve_model_spec/2`.
`SettingsLiveTest` owns the parent page's remaining surfaces: settings search, `ModelProfileHelpers.move_model_profile/3`, LLM connection-test rendering and handlers, the sandbox `write_paths` list editor, remote-node config loading, the remote-connection bootstrap progress bar, the daemon-already-running permission dialog, Install wording/banner/Name auto-fill, the async connect flow, copy-to-clipboard, the appearance/accent category and the `md+ independent scroll layout contract`.
That scroll-layout describe pins the two-class regression gate behind the "panes scroll linked" bug: every `div#category-<cat>` root and the generic `<form id="settings-form-<cat>">` carry `flex-1 flex flex-col min-w-0` plus `min-h-0` and never `h-full`, an inner `.overflow-y-auto` body exists, and `form#settings-form-search` carries `overflow-y-auto` on the form itself.
The `test_llm` contract proves dispatch, auth, result rendering and rejection of unscoped/stale/wrong-node envelopes without public-provider traffic; its envelope is `{{:llm_test_result, seq, {target_id, node, selection}}, {:ok, result}}`, and the missing-remote handler test covers both `remote_config` flags.
The request-options contract captures the actual final HTTP request at an isolated loopback endpoint, including authentication and inherited generation settings, instead of expecting credentials to leak through resolver output.
`SettingsLiveGlobalStateTest` is sync because it mutates `:nix_available_override` / `:platform_os_override`, `EvoGit.AgentScheduler.pause/resume` and the `"scheduler_config"` broadcast; it pins the in-flight-save ownership test (which suspends the scheduler, resumes before awaiting success and keeps an `on_exit` resume safety net), the node-filtered broadcast, `nix.enabled` boolean rendering, platform gating, nix category gating and shell seeding.
Mounted Settings additions belong with the parent file's owner, pure provider transformations belong in this directory, and core atomic-write/cache-failure assertions belong to the core config test node.
Mounted Projects, Assistant and Welcome canonical contracts live in their own page suites, so helper-only success must not be mistaken for their integration validation.

## Mount funnel and seeding

`mount_settings/2` in `settings_live_test.exs` funnels every mount: `live/3`, then `await_mount_async_loads/1` (monitor this mount's `$callers` children, then drain), and only then hands the view to the test, so a late node-data apply can never clobber test-driven state; the ORIGINAL mount HTML is returned unchanged.
`provider_panel_live_test.exs` and `provider_wizard_test.exs` carry LOCAL copies of `mount_settings`, `settings_hook/3` and `await_config_save` so each file compiles and runs alone; the shared `EvoDashWeb.SettingsLiveTest.Helpers` module only exists once `settings_live_test.exs` is loaded, which the loader does not guarantee in alphabetical order.
`settings_live_agents_test.exs` uses its OWN owner-aware variant (`mount_settings/1` → `await_view_async_loads/1`): a bounded 2 ms poll on "no live `EvoDash.TaskSupervisor` child whose `$callers` contain THIS view pid", a ~5 s best-effort cap (`@settle_timeout_ms`), then a `render/1` drain — the same helper is reused at the `reload_custom_tools` click.
`settings_live_test.exs`, `provider_panel_live_test.exs` and `provider_wizard_test.exs` SEED canonical provider fixtures straight into this test's `config.toml` (string keys, one nested model row, optional explicit default) instead of driving the add/save UI for setup; the mounted suites drive the actual rendered controls for Add/Save/Cancel/CRUD/model-row flows.
Mutations acknowledge dispatch before the off-process write completes, so every assertion reads the authoritative completion (`config_saving == false`, then `render/1`), never the dispatch render.

## Constraints

Pure suites use the shared test bootstrap and never call `ExUnit.start/0`, patch missing core functions or skip failing integration contracts.
Mounted suites retain per-process `EvoDash.Test.ConfigDir.isolate!/1` and local-only `EvoDash.ActiveTasks.invalidate(nil, node())`; the whole-table `reset/0` belongs to sync modules only.
Every async-load budget here is a load-tolerant 30 s (`@async_wait_budget_ms`, `@assigns_timeout_ms`) with a 1–2 ms poll cadence; no fixed `Process.sleep` is a wait mechanism.
`assigns/1` is a synchronous `:sys.get_state(view.pid, 30_000)` round-trip, so `send` followed by an `assigns/1` read is already ordered.
Auth config-directory labels include the OS pid so interrupted or concurrent BEAM runs cannot reuse another run's blocker fixture.
Auth save assertions wait for `config_saving` and `config_save_request` to clear through the authoritative writer receipt, then settle the receipt's OAuth refresh before rendering or reading persistence.
Every login verdict, managed-file path and writable-path remedy stays asserted; supplied vendor instructions normalize only HTML whitespace, not their wording.
No test may make a real LLM request or rely on shared credentials, scheduler mutation or global ChatHistory.
Multi-model coverage here is pure parsing/draft round trips and sparse inheritance; a mounted multi-model Save → remount cycle is `provider_panel_live_test.exs`'s `two distinct models survive save, reload and remount, including the id new`.
Production source and core modules are read-only from this node.

## Validation and integration boundary

Pure canonical parser contracts accept default-only profiles with absent or empty `models` and omit the stored `models` key; helper-level configured rows are overrides rather than an allowlist restricting `default_model`.
The production core validator rejects a default-only account fixture (`default_model must be one of []`), independently of the editor's helper-level acceptance and synchronization.
The two mounted default-only regressions preserve these UI contracts but distinguish them from successful core persistence: a nonblank default with no model rows receives that rejection, leaves disk and live config unchanged, and retains the draft.
Successful Save → remount requires explicitly adding a nested inventory row matching the chosen default; that core limitation stays outside this test node's scope.
The rendered reasoning-checkbox clear and the closed-Advanced API-key-source state machines pass including persistence and remount, with no production change or input weakening.
The `:managed_file_unwritable` classification tests concern OAuth credential files, not `config.toml` write failures.
The legacy OAuth migration save preserves its path for both OAuth accounts, so its appearance in scheduler update options is expected.
No suite in this directory installs an app-env blocking runner or suspends the scheduler; `config_io_test.exs` exercises `State.do_update_config/2` on local state values, not the registered scheduler process.
`await_profile_save/1` waits for save markers to clear and then drains OAuth refresh tasks, but marker clearance alone is not success: a failed runtime scheduler update can also finish the writer request, so the exact success-flash assertion stays.
A longer test polling deadline cannot repair a runtime `GenServer.call` timeout already returned as a failed save acknowledgement.

## Known Issues

Collective LiveView-directory validation at seed 1 can fail `the API-key default is explicit and drops a stale OAuth path` in `auth_status_test.exs` (describe `profile save round-trip (auth_mode / oauth_file persistence)`) at its exact success-flash assertion, because saving returns `Failed to save configuration` with an `{:exit, {:timeout, {GenServer, :call, [EvoGit.AgentScheduler, {:update_config, full_canonical_options}, 5000]}}}` error.
That is a core scheduler acknowledgement timeout, not a test polling failure; the exact success assertion and async concurrency stay, rather than extending polling deadlines.
No scheduler stack or mailbox capture establishes the underlying cause, so neither OAuth, Finch nor the request payload is implicated by this failure alone.
The source failure belongs to the core scheduler owner, outside this leaf test node.
`ConfigSave`'s read-verified receipt (see `config_save_test.exs`) covers the write path; a core-side log-and-succeed reload would remove the need for it.

## Focused commands

`mix test apps/evo_dash/test/evo_dash_web/live/settings_live --seed 0` (184 tests) or `--seed 1` runs this directory; naming one file runs just that suite.
The pure helper slice is `mix test apps/evo_dash/test/evo_dash_web/live/settings_live/provider_profiles_contract_test.exs apps/evo_dash/test/evo_dash_web/live/settings_live/config_io_test.exs apps/evo_dash/test/evo_dash_web/live/settings_live/model_profile_helpers_test.exs --seed 1` (94 tests).
Useful describe filters are `--only 'describe:credential status render (injected result)'`, `--only 'describe:profile save round-trip (auth_mode / oauth_file persistence)'`, `--only 'describe:wizard auth step (provider capability)'` and `--only 'describe:the removed Quick Setup shortcut'`.
Leaf-subtree or pure-slice success does not establish collective LiveView-directory or broader dashboard-suite success.

## Routing Table

This directory has no child directories.
