# Welcome Onboarding Helpers

## ChatGPT in-browser sign-in
`WelcomeLive` carries `:chatgpt_sign_in` in the SAME page-level shape `/settings` uses (`%{surface: :wizard, flow_id, url, phase: :idle | :waiting | :ok | :error, reason, port, mode, paste, paste_error}`, always built by `ChatGPTSignInState.new/0`) and `:chatgpt_sign_in_manual`, passed through `Steps.step_auth_body/1` into the shared `ChatGPTAuth` control (id `welcome-chatgpt`), so a first-run user never needs the terminal.
The `chatgpt_sign_in` event calls `ChatGPTSignInState.begin/4` (surface `:wizard`, poll owner `self()`), which runs `LLMSetup.ChatGPTSignIn.begin/1` for the draft's account (current `siwc_account` else the store default) and records `port`/`mode`; `chatgpt_sign_in_cancel` calls `ChatGPTSignInState.cancel/1`; a repeat click starts a new flow.
`chatgpt_sign_in_paste` and `chatgpt_sign_in_submit` reuse the shared pure transitions (`paste_target?(state, :wizard)` gate → `put_paste/2` / `submit_paste/2`, with the typed text read by the shared `paste_text/1` — the paste input's real `phx-change` payload carries its own `"paste"` field, never a `"value"`), so the wizard's waiting panel carries the same MANUAL paste-the-redirect-URL fallback as `/settings` with ONE mapping of `:invalid_callback`/`:no_code`/`:already_finished` (stays `:waiting` plus an inline `paste_error`) and no duplicated result interpretation.
`{:chatgpt_signin_result, flow_id, result}` is dropped unless its flow id is the current one; `{:ok, %{account: account}}` refreshes `ChatGPT.accounts(node())`, writes the draft's `siwc_account`, sets `phase: :ok` and invalidates the pending connection test, so the `:auth` gate (`accounts` must contain the selected account) now passes; every phase transition goes through the page's private `sign_in_phase/3`, which also clears `paste`/`paste_error`.
`chatgpt_sign_in_manual` is derived from the viewed node (`current_node_id != nil`); the sign-in state is reset to `ChatGPTSignInState.new/0` on a node switch, any provider re-pick, `wizard_back`/`wizard_next` step entry and `add_another_provider`, so neither a stale waiting state nor a stale paste ever lingers.
`WelcomeLive.terminate/2` cancels a still-waiting flow through the SAME `ChatGPTSignInState.cancel/1` entry point `/settings` uses (total and quiet: a missing/garbage assign, a non-waiting `:idle`/`:ok`/`:error` phase or a dead flow cancels nothing and never raises), so leaving `/welcome` closes the loopback listener instead of waiting for the flow's own timeout.
## Intent
`Setup` owns catalog-backed onboarding drafts and canonical provider-profile construction for the local-only `WelcomeLive` page.
`Wizard` (`wizard.ex`, `EvoDashWeb.WelcomeLive.Wizard`) is the pure string-keyed DRAFT model and transition set for the wizard-shaped onboarding flow; it delegates steps, reasoning, schedule presets and identity to `EvoDashWeb.LLMSetup`.
The parent page owns provider/variant selection, multi-model toggles, authentication UI, write ordering and asynchronous connection-test state.
`Presentation` (`presentation.ex`, `EvoDashWeb.WelcomeLive.Presentation`) owns the pure view-model helpers and the step copy: catalog resolution by string, provider/variant/model rows, the schedule presets, the connection-test status shape and the user-facing messages.
`variant_options/2` marks the option matching the draft's current variant `selected`, so a chosen chip renders as the active `btn-primary` choice.
`schedule_presets/2` resolves a provider/variant pair's presets and drops every entry without a nonblank id, so a nameless preset never reaches the step.
`preset_allowed?/3` is the ONLY gate for a submitted preset id: it refuses a blank id and any id absent from that exact provider/variant's preset list.
`test_status/1` is the ONE connection-test result projection: it unwraps exactly one `EvoDash.SafeCall` level, keeps `{:ok, detail}` as the success state with the tested model/response text, maps `{:ok, {:error, message}}` to the error state, and passes any other term through.
`ViewModel` (`view_model.ex`, `EvoDashWeb.WelcomeLive.ViewModel`) derives every per-step render assign from the draft, calling `Presentation` for each step's values.
Its `inventory` comes from `Presentation.primary_inventory/2` fed the PRIMARY model's flat entry, and each extra model's `"efforts"` comes from the same entry, both through `Wizard.reasoning_choices/1`, so every catalog model renders the ladder (or its declared subset) rather than an empty chip group.
Every default the reasoning step renders goes through `Wizard.model_default_effort`: `Presentation.primary_effort/1` for `#default-reasoning-effort` and `ViewModel.model_reasoning_default/2` for each extra model's select, so a picked level stays selected instead of snapping back to "Provider default".
`Wizard.model_default_effort/2` answers for either kind of model, reading the nested entry of a catalog pick and the draft's flat `"default_reasoning_effort"` field of the free-text custom model (which is what the save path persists for it), and the page's connection-test effort for the tested model comes from that same helper.
`Steps` (`steps.ex`, `EvoDashWeb.WelcomeLive.Steps`) owns only the per-step HEEx BODIES the page's `render/1` inserts into `EvoDashWeb.SettingsComponents.ProviderWizard.wizard_shell/1`: `step_provider_body/1`, `step_auth_body/1`, `step_model_body/1`, `step_reasoning_schedule_body/1`, `step_test_body/1` and `step_done_body/1`, each a pure function of its declared attrs (no socket, no events, no view-model derivation).
`step_auth_body/1` renders `#wizard-api-key` as an UNCONTROLLED password input — no `value` attribute, `autocomplete="off"` and `phx-debounce="300"` — so the typed secret reaches the server only through the (debounced) `wizard_api_key` change event and never appears in rendered markup or a push payload.
The model search and free-text custom-model inputs keep their per-keystroke change events: their markup lives in `EvoDashWeb.SettingsComponents.ProviderWizard.ModelStep`, not in this directory.
`WelcomeLive.mount/3` seeds the hook-owned assigns it renders (`remote_targets`, `connection_statuses`, `session_list`, `session_list_loading`, `session_list_error`, `current_session_id`, `accent_color`) with `assign_new/3` defaults, so `render/1` reads every one of them strictly as `@key`.
While the draft holds a key the auth step shows a status line ("A key is set for this session — type to replace it") instead of the value, and the draft drops the key once a save succeeds.

## API Surface
`Steps` declares one `attr` per assign a body reads and renders exactly the markup (ids, event names, `phx-value-*` keys, class lists and the wrapping `phx-change` forms) the page used to inline; each body is the byte-equivalent structure it replaces, so a body change is a rendered-contract change.
`Wizard` carries the string-keyed draft (`provider`, `variant`, `auth_mode`, `base_url`, `api_key`, `models`, `custom_model`, `default_model`, `model_reasoning`, `reasoning_efforts`, `default_reasoning_effort`, `schedule`, `schedule_snapshot`, `preset_id`) with `new/0,1`, `put/3` (whitelisted keys only), `capabilities/1`, `steps/1`, `validate/2,3`, `valid?/2,3`, `next_step/2`/`prev_step/2`/`progress/2`, `reasoning_choices/0,1`, `toggle_model/2`, `set_custom_model/2`, `apply_preset/2`, `undo_preset/1`, `preset_state/1`, `schedule_keys/0`, `schedule_rows/1`, `holiday_value/1`, `model_default_effort/1,2`, `model_effort_inventory/1` and `summary_rows/1`.
`"model_reasoning"` is a model-keyed map of NESTED entries — `%{"efforts" => [picked level…], "default" => picked default or ""}` — written by the reasoning step for the primary catalog model and for each extra model; the free-text custom model keeps its own flat `"reasoning_efforts"`/`"default_reasoning_effort"` draft keys.
`Wizard.model_default_effort/1,2` is the ONE unwrap of such an entry: it reads the default from the nested map OR from a flat effort string and answers `""` when nothing is recorded, so a picked level can never live in the draft yet vanish from the select, the saved row or the connection-test request.
Its two-arity form also answers for the free-text custom model by reading the draft's flat `"default_reasoning_effort"` field, which outranks any stale `"model_reasoning"` entry because that flat field is what the save path persists for that model.
`Wizard.model_effort_inventory/1` reads the same entry's recorded `"efforts"` the same way (`[]` for a flat entry), so one entry is never read as a ladder by one surface and as a default by another.
`summary_rows/1` renders its Reasoning row through `model_default_effort`, so the done step shows the level the user actually picked.
`capabilities/1` always answers exactly the four keys (`auth_choice?`, `auth_modes`, `oauth_only?`, `requires_base_url?`): a DRAFT (the string `"provider"` key is the marker) derives them from its provider even when it also carries capability keys, a ready-made capabilities map keeps its own values without being returned whole, and anything else is read as a catalog entry.
`steps/1` runs the same derivation, so the step list for a custom/OpenAI-compatible endpoint and an OAuth-only provider follows the provider and never a stale draft key.
`validate/2,3` is total — it normalizes a `nil`/non-map draft to the empty draft, so `:model` answers `{:error, :missing_model}`, `:auth` answers `{:error, :invalid_auth_mode}`, `:reasoning_schedule` answers `:ok` and `:provider` answers `{:error, :missing_provider}` instead of raising.
`summary_rows/1` emits a Provider/Model/Reasoning row only when the draft carries a non-blank value, so an empty draft yields no rows and never invents a "Custom endpoint"; the schedule rows keep their own rules.
It is pure and total — no I/O, process, clock or catalog lookup — and treats the typed `api_key` as transient draft state that is never persisted by this module.
`flatten_models/1`, `provider_models/3`, and `filtered_models/2` build and filter trusted catalog entries without converting client strings into atoms.
`reasoning_efforts/0` exposes standard choices, while `reasoning_efforts/1` reads atom- or string-keyed inventories, preserves their order and explicit empty lists, and falls back to standard choices only for absent or nil inventories.
`Wizard.reasoning_choices/1` is the DISPLAYED inventory both reasoning surfaces use: a normalized inventory, with an unrestricted empty (or absent) inventory expanded to the canonical ladder (`none, minimal, low, medium, high, xhigh` — never `max`) for display only, so a catalog model that declares no efforts still offers the whole ladder plus the separate default select while a model that declares a subset offers exactly that subset.
`flatten_models/1` uses the same inventory helper, so draft construction and page controls agree.
`has_model?/1` delegates to `EvoGit.Config.Schema.model_selections/1`, respecting the core's canonical precedence and legacy migration, including flat `llm.model` input.
`auth_mode/1` defaults OAuth-only providers to subscription authentication, and `can_save?/1` gates API-key mode on an existing or typed key while OAuth requires none.
`prepare/3` validates selections, default model, supported authentication, required endpoint and reasoning choices before invoking `EvoGit.Config.Schema.validate/1`.
Its success tuple is `{:ok, config, profile, default_entry, trimmed_api_key}` and performs no credential or configuration writes.
Profiles contain `id`, `name`, resolved `provider`, `auth_mode`, `default_model`, optional `base_url`, and nested model rows with bare catalog model ids.
Each row retains its full `reasoning_efforts` inventory independently of `default_reasoning_effort`, and a blank choice adds no default override.
A catalog model's picked default and a custom model's flat default reach that row the same way: `Setup` reads every `model_reasoning` entry through `Wizard.model_default_effort/1` (never through a string-only cast), so the persisted `default_reasoning_effort` is one the picker offered and is omitted when the user left "Provider default".
A nonblank reasoning default must be a standard choice and belong to any nonempty advertised inventory, matching the core's unrestricted-empty-inventory convention.
`prepare/3` appends a uniquely named provider profile, sets `llm.default_provider_profile`, and preserves unrelated raw settings, existing provider profiles and legacy `llm.models` verbatim.
Validation failures return schema paths rather than inspected validation records, because those records can contain secret raw configuration values.
`read_config/0` reads raw TOML afresh without resolved defaults or migrations and returns explicit errors for malformed or unreadable files.
`test_request/3` resolves the validated profile and selected entry through `Schema.resolve_model_spec/2`, retaining endpoint overrides, inherited generation options, OAuth settings and independent reasoning defaults.
Its return is `{resolved.model_spec, resolved.generation_params}`, where `model_spec` is the ReqLLM-ready string or endpoint map, never a canonical task-picker selection map.
Its third argument is the tested model's ALREADY-UNWRAPPED reasoning level as a plain string (never a per-model entry map, so no shape is re-interpreted here), read by the page through `Wizard.model_default_effort/2` exactly as the save path reads it; the request therefore carries the level that will be persisted.
A blank or `"default"` level adds no `reasoning_effort` at all, leaving the account's own default authoritative for "Provider default".
Invalid test drafts raise at this server-side boundary and are reported by the surrounding connection worker's `SafeCall`.
`write/1` exposes the exit-safe boundary for local config and credential writes.

## Constraints
All helpers that construct drafts are pure, and page event handlers own the local-node guard before reading or writing local configuration or credentials.
The parent must reject mutation and connection-test events whenever `current_node_id` is non-nil, including disconnected targets temporarily resolving to the local BEAM.
No onboarding path creates or edits legacy `llm.models`, and persistence must never write a resolved config snapshot with migration-generated profiles or runtime defaults.
Save and connection test both run fresh raw-config preflight before credential writes, and only save persists the resulting config.
`read_config/0` is a direct `File.read/1` of `EvoGit.Config.config_path/0` decoded with `TomlElixir`, deliberately bypassing `EvoGit.Config.user_config/0` (its file cache and any in-RAM snapshot), so the read-modify-write always starts from disk truth.
`write/1` only wraps its argument in `EvoDash.SafeCall.run/1`, returning the value or `{:error, reason}`; the actual disk write is always `EvoGit.Config.save_credentials/1` or `save_user_config/1`.
Credential writes preceding config writes are not transactional and cannot be rolled back by this helper.
Catalog entries are trusted server data, while model selections must remain constrained to the active provider and variant.
Configuration, credentials, resolved profiles and generation parameters are server-only and must never enter browser persistence, push-event payloads or client data attributes.
`test_request/3` belongs inside the supervised `SafeCall` worker, never the LiveView render or event process, because canonical resolution can import OAuth credentials and consult metadata.
The call-time two-arity `:welcome_llm_test_runner` seam defaults to `EvoGit.SystemCheck.llm_test/2`.
Scoped test messages use the nested `{{:welcome_llm_test_result, seq}, guarded_result}` SafeCall shape, and the page invalidates tokens on draft and node changes and ignores legacy unscoped results.
The page answers a guarded result by unwrapping exactly one level before assigning `llm_test_status`, so a provider answer of `{:error, message}` reaches the error state and only a genuine provider `{:ok, detail}` renders success.
`apply_schedule_preset` applies a preset only when `Presentation.preset_allowed?/3` admits that id for the draft's current provider and variant, and otherwise leaves the draft untouched.
All new UI strings are gettext-wrapped, and translation catalogs remain release-time-only work.
## Shell height (welcome pages are content-box pages)
Both `/welcome` and `/welcome/complete` render inside `Layouts.app`, so the persistent top bar is present and the pages size against `main#main-content`'s definite content box, never the viewport.
`welcome_live.ex`'s page root is `min-h-full max-w-5xl mx-auto px-4 lg:px-6 py-4 space-y-5` (normal page flow, scrolls in `#main-scroll`).
`welcome_complete_live.ex`'s page root is `min-h-full lg:h-full lg:min-h-0 lg:overflow-hidden max-w-3xl mx-auto … flex flex-col`, a fixed non-scrolling desktop layout bounded by the content box whose inner body owns the scroll.
Neither page may take `height`/`min-height` from `100vh`/`100dvh` (`min-h-screen`/`h-screen` would be exactly one top bar too tall and clip the bottom); mobile keeps normal page flow.

## Parent Wiring and Tests
The parent uses entry-aware `reasoning_efforts/1`, retains full inventories separately from defaults, guards remote mutation events, and runs `test_request/3` inside a supervised worker.
Its `welcome_defaults_changed` whitelist treats an explicit empty inventory as allowing only blank, while `prepare/3` and core resolution treat that inventory as unrestricted.
If unrestricted empty inventories are exposed for selection, the page must offer standard reasoning choices for that case without changing the stored empty inventory.
The sibling `test/evo_dash_web/live/welcome_live_test.exs` covers multi-model save, independent defaults and inventories, OAuth modes, local-only mutation, config preservation and scoped test results.
Additional persistent helper regressions belong in that sibling suite: atom/string/nil/empty inventories, core-backed legacy-flat and canonical-precedence all-set detection, endpoint and inherited-generation test-request parity, invalid test selections, and secret-free validation errors.
That suite still pins the OLD double-wrapped test-result shape, so its connection-test assertions must expect the one-level `{:ok, detail}` status; the page and sibling tests are owned outside this helper node.

## Core-Owned Validation Boundary
`Schema.validate/1` is available and canonical provider preflight runs normally, but its general path accessor still walks atom keys only in this checkout.
`read_config/0` returns raw string-keyed TOML, so unrelated raw sections are preserved but are not fully validated by that schema call.
For example, `Setup.prepare/3` currently accepts an unrelated raw `"scheduler" => %{"max_tool_concurrency" => "invalid"}` section while the atom-keyed equivalent is rejected.
This gap belongs to the core's validation normalization and must not be bypassed with an onboarding-specific validator or resolved-config persistence.

## Config I/O Touch Points (page + helper)
`welcome_live.ex` reads config only via `ConfigIO.load_file_config/0` (= `EvoGit.Config.resolve/0`) in `mount/3` and after a save, and carries `EvoGit.Config.credentials/0` into the `credentials` assign at mount, after save and after a connection test.
`Setup.read_config/0` (`setup.ex:176-194`) is the deliberate raw-TOML read (`File.read(EvoGit.Config.config_path())` + `TomlElixir.decode`) used as the read-modify-write base for save and test, so persisted defaults and migration output never land in the file.
Writes are only `EvoGit.Config.save_credentials/1` (`save_key/3` at `welcome_live.ex:676`) and `EvoGit.Config.save_user_config/1` (`welcome_live.ex:504`), both wrapped by `Setup.write/1` (`EvoDash.SafeCall.run/1`, not transactional together).
After a successful save the page re-reads `load_file_config/0` (`:505`), re-reads `credentials/0` (`:514`) and pushes scheduler options through `ConfigIO.update_runtime_from_file_config/2` (`:519`); it never calls `reload_remote_config/1` or `RemoteAPI.reload_config/0`.
`save_key/3` runs before both the config write and the connection test, so the API key reaches the test through `save_credentials/1`'s file write plus its `ReqLLM.put_key` side effect, not from the `api_key_input` assign.
The page subscribes to no config-change topic: `has_model?`, `credentials` (and the `key_is_set` badge / `can_save?/1`) only refresh on mount or after this page's own writes, so an external config or credentials edit stays invisible until remount.
The page carries no `file_config` assign: the resolved config is read into a LOCAL binding in `mount/3` (for `has_model?/1`) and after a save (for the runtime push), and never stored in socket state.

## Routing Table
This helper directory has no child directories.
