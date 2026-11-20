# SettingsComponents — Sub-Components

## Intent

Sub-component modules extracted from `EvoDashWeb.SettingsComponents` so each presentation concern stays focused: `CategoryMetadata` (pure display/schema-matching helpers), `SettingCard` (the schema-driven field renderer plus its special cases), the `provider_profiles/` family (the ONE canonical `[[llm.providers]]` account surface: panel + summary row + accordion detail + schedule editor + inline wizards), `ProviderProfileFields` (pure provider-form building blocks), `ProviderWizard` (LLM-setup step components shared with `/welcome`), `ChatGPTSignInPanel` (the ONE Sign in with ChatGPT surface, plus its surface-isolation rule) with the `ProviderWizard.ChatGPTAuth` account control layered on it, the list editors (`CustomAgentsEditor`, `ModelSelectionEditor`), the read-only `CustomToolsPanel`, the sidebar/search shell (`Sidebar`, `SearchResults`) and four shared building blocks (`SaveBar`, `SectionHeader`, `CardShell`, `FormFooter`).

Presentation modules receive assigns and return HEEx without owning LiveView state or reading credential/configuration files, and emit event names the LiveView handles.
`CategoryMetadata` is a pure non-HEEx helper using Gettext directly rather than `use EvoDashWeb, :html`.
`ProviderProfileFields` also exposes catalog-backed helpers (`reasoning_suggestions/2`, provider/auth capability helpers and provider options), so this directory is not uniformly catalog-read-free.

## Routing Table

None — leaf directory of reusable settings presentation modules (`./provider_profiles/` and `./provider_wizard/` hold the sub-module families described below).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `CategoryMetadata` | Pure helpers: category display name/icon/description, sort order, schema matching (`schema_matches?/2`, `category_match_count/3`) and the `dedicated_provider_path?/1` predicate that reserves the provider keys for the dedicated panel. |
| `SettingCard` | Schema-driven form field renderer (`setting_card/1`) with type-dispatched widgets, a per-key `reset_key` button, the `:list_of_strings` editor, and the two key-path special cases (`[:appearance, :accent_color]` swatches, `[:llm, :reasoning_effort]` select). Also exposes `flat_llm_schemas/1`, `reasoning_options/1`, `reasoning_value/1` and the accent helpers. |
| `ProviderProfiles.Panel` | `provider_profiles_panel/1` — the whole provider surface: one section header, one summary row per account, at most ONE expanded detail, and the two inline wizards. |
| `ProviderProfiles.Row` | `profile_row/1` — one read-only account summary row (identity, provider, default marker, schedule badge, model chips, auth badge, actions). Public helpers `schedule_badge/1`, `model_chips/1`, `profile_id/1`, `slug/1`. |
| `ProviderProfiles.Detail` | `profile_detail/1` — the expanded account editor form (identity, auth incl. the in-browser ChatGPT sign-in control, endpoint, models, default model/reasoning, collapsed advanced bucket with the schedule editor). |
| `ProviderProfiles.ScheduleEditor` | `schedule_editor/1` — peak/off-peak schedule fields, the preset recommendation, the applied strip and the holiday-calendar select. |
| `ProviderProfiles.WizardForm` | `add_account_wizard/1` + `add_model_wizard/1` — the two inline creation wizards over the shared `ProviderWizard` steps; public `rendered_steps/1` + `current_step/2`. |
| `ProviderProfileFields` | Pure provider-form building blocks: labeled inputs, the ONE keyed reasoning chip list, the inventory-scoped default-effort select, generation parameters, peak/day controls and node-correct OAuth guidance; `provider_auth_status/1` renders the shared auth/status line and, in its expanded ChatGPT form, the shared sign-in panel. |
| `ProviderWizard` | Shared LLM-setup step components (`wizard_shell/1`, `step_provider/1`, `step_auth/1`, `step_model/1`, `step_reasoning_schedule/1`, `step_test/1`, `step_done/1`) consumed by `/welcome` and the `/settings` wizards; pure, event names arrive as attrs. |
| `ChatGPTSignInPanel` | `sign_in_panel/1` — the ONE Sign in with ChatGPT surface (local begin/waiting/error control or the `genesis chatgpt login` manual hint, optionally the caller's account-specific `command`), plus the pure `surface_state/2` surface-isolation rule; no account select, no connected line, no connection check. Rendered by the wizard auth step, the expanded account detail and the auth/status row. |
| `ProviderWizard.ChatGPTAuth` | `chatgpt_auth/1` — the ChatGPT account control behind both wizards: account select, "ChatGPT connected" line and "Check connection", delegating the sign-in section to `ChatGPTSignInPanel.sign_in_panel/1`. |
| `CustomAgentsEditor` | `custom_agents_editor/1` — list editor for `agents.toml` custom agents: rows with id/type/level/model badges + prompt preview, inline edit form (name, description, prompt, agent_type, delegation_level, model_id, max_turns, tools/subagents chips), delete with `data-confirm`. |
| `CustomToolsPanel` | `custom_tools_panel/1` — read-only status panel for the modules under `<config_dir>/tools/`, plus the pure `custom_tool_names/1` helper. |
| `ModelSelectionEditor` | `model_selection_editor/1` — model-selection script editor (textarea, collapsible contract help, copyable example, compile-error box, test results). |
| `Sidebar` | Settings sidebar: search filter, category navigation, config-file footer. |
| `SearchResults` | Search results grouped by category. |
| `SaveBar` | Pinned bottom-right save bar (`save_bar/1`, attrs `:label` + optional `:form`). |
| `SectionHeader` | Sticky top section header (`section_header/1`). |
| `CardShell` | Editor card wrapper: header row + optional actions slot + body. |
| `FormFooter` | Edit-form action footer: Cancel ghost + primary submit. |

## Provider account panel — `provider_profiles/`

`ProviderProfiles.Panel.provider_profiles_panel/1` is the ONE rendering entry point for `[[llm.providers]]`, mounted by `SettingsComponents.category_section/1` outside the generic category form.
Attrs: `profiles`, `default_profile_id`, `expanded_id`, `draft`, `errors`, `auth_statuses`, `disabled`, `advanced_open`, `wizard`, `schedule`, `chatgpt_sign_in`, `chatgpt_sign_in_manual`.
`chatgpt_sign_in` (map) and `chatgpt_sign_in_manual` (boolean) are the page-owned sign-in state and local/remote verdict; both carry TOTAL defaults (`%{}` / `false`) and are forwarded verbatim to every row and to the one expanded editor.
The panel root is `#provider-profiles-panel` with `#provider-profiles-title`; the section header carries "Add account" (`phx-click="add_provider_profile"`).
An account row is read-only; editing, defaulting, deleting and adding a model are explicit row actions, so nothing in the summary list submits a form.
The row id is `#provider-profile-<slug>` (slug from `profile_id/1`), and its `data-expanded` attribute exposes the accordion state.
Row actions: `edit_provider_profile` / `set_default_provider_profile` / `start_add_provider_model` / `delete_provider_profile`, each carrying `phx-value-profile_id`.
`set_default_provider_profile` updates `[llm] default_provider_profile` and is not a provider-form field.
At most ONE account is expanded (`expanded_id`) and therefore one detail form exists, which is what keeps the constant form ids unique on the page.
The row summarizes identity, provider, the default marker, the schedule badge (`schedule_badge/1`), the model chips (`model_chips/1`) and the auth-mode badge for OAuth-supporting providers.
Each model chip and the schedule badge derive only from the account map, so a summary row never needs the draft.

`ProviderProfiles.Detail.profile_detail/1` renders the expanded editor form `#provider-profile-detail-<slug>`.
Form contract: `phx-change="provider_profile_form_change"` and `phx-submit="save_provider_profile"`, a hidden `profile_id`, and the footer's `cancel_event="cancel_edit_provider_profile"`.
Errors render in `#provider-profile-errors` (form-field name to translated message) and are referenced by the form's `aria-describedby`.
Visible controls: `provider` select (catalog-owned atoms as strings, regional/plan variants included, unknown configured provider retained), authentication controls (`#provider-auth-mode`), `base_url` for an OpenAI-compatible endpoint, the model rows under `#provider-models-title`, and the required default-model select `#provider-field-default_model`.
When there are no model rows the Models section renders the compact text input `#provider-field-default_model_name` ("Model name") instead, submitted as `default_model_name` and stripped by the owner on save.
The default-reasoning control comes from `ProviderProfileFields.reasoning_default/1` (inventory-scoped).
Each model row shows its name and remove action, with `#provider-model-details-<index>` holding context window, reasoning overrides and nested generation overrides.
`<details id="provider-profile-advanced">` (collapsed by default, `advanced_open`) holds the optional account identity (`profile_id_new`, `name`), `api_key_env_var` (the NAME only, never a value), `base_url`, `concurrency`, the schedule editor, shared `context_window`, shared reasoning support (`reasoning_fields show_default={false}`) and `<details id="provider-generation-defaults">`.
Advanced fields stay in the DOM while collapsed and still submit, so the disclosure is purely presentational.
OAuth-only providers emit a hidden `auth_mode=oauth` and never show an API-key prompt; other providers show API-key guidance without rendering any key/token field.
`auth_statuses` is keyed by profile id with `state` (`ok`/`missing`/`unwritable`/`unknown`), `expires`, `login_instructions` and `oauth_file`; a missing entry is normal.
Unwritable status withholds login instructions in favor of the writable-`oauth_file` remedy, unknown status makes no detected/missing claim, and the managed path never falls back to `EvoGit.Auth.default_oauth_file/0` on the dashboard machine.
`refresh_auth_status` (with `profile_id`) re-checks through the node-scoped status loader.

`SettingsComponents.category_section/1` threads `chatgpt_sign_in` / `chatgpt_sign_in_manual` into `provider_profiles_panel/1`, which forwards them to `Row.profile_row/1` and `Detail.profile_detail/1`, and both forward them to `ProviderProfileFields.provider_auth_status/1`; every one of those attrs has a TOTAL default (`%{}` / `false`), so a page renders before (and without) the page-level assigns.
The in-browser sign-in is reachable from three places over ONE implementation: the wizard auth step (`surface="wizard"`), the expanded account detail (`#provider-detail-<slug>-chatgpt`, `surface="detail"`) and the credential-status line (`#provider-status-<slug>-chatgpt`, `surface="status"`).
Each surface renders only its OWN flow: the caller passes `ChatGPTSignInPanel.surface_state/2` filtered on `{:detail, profile_id}` / `{:status, profile_id}`, so a flow started from the wizard or the other settings surface renders as that surface's idle control.
The detail editor renders the panel directly below the `siwc_account` field (ChatGPT providers only) and forwards the same two attrs to its `provider_auth_status/1` line; the collapsed summary row keeps `details={false}`, so it shows the icon/label/Recheck only and never the sign-in panel.
`siwc_account` help text describes the account NAME the sign-in registers and points at the sign-in control on that same fieldset, so the terminal command is no longer presented as the route.
Manual mode is the remote fallback everywhere: the panel renders `genesis chatgpt login` — or the account-specific command the status line passes as `command` — plus the one-line reason that a loopback listener must run where the browser can reach it.
`provider_auth_status/1` derives its own `slug` through `ProviderProfiles.Row.slug/1`, so both sign-in ids stay stable per account, and its expanded ChatGPT status branch renders the panel while the `:ok`/`:unwritable`/`:missing`/generic branches keep their existing wording.

### Schedule editor — `ProviderProfiles.ScheduleEditor`

`schedule_editor/1` (attrs `fields`, `schedule`) renders `#provider-schedule-editor` inside the advanced bucket: `peak_concurrency`, `timezone`, the off-peak day chips, the indexed `peak_hours[index][start|end]` windows with their day chips, `off_peak_holidays` and the read-only summary rows.
Nothing prefills on render; the preset recommendation is applied only by an explicit `apply_provider_schedule` click (`phx-value-preset_id`).
After an apply, `#provider-schedule-applied` states the recommendation was applied and offers re-apply (`apply_provider_schedule`) and dismiss (`dismiss_schedule_applied`).
Editing an applied schedule shows the "Schedule modified after applying the recommendation." hint, and `undo_provider_schedule` restores the pre-apply snapshot for as long as one exists.
`#provider-off-peak-holidays` is a select over the accepted holiday calendars, with a one-line explanation; a blank value omits the key.
Preset/undo/changed semantics live in `EvoDashWeb.LLMSetup.Schedule` (`apply/2`, `undo/2`, `changed?/2`); this module only renders and emits.

### Inline wizards — `ProviderProfiles.WizardForm`

`add_account_wizard/1` renders `#provider-wizard` when `wizard.mode == :account`; `add_model_wizard/1` renders `#provider-model-form-<slug>` when `wizard.mode == {:model, profile_id}`.
Both reuse the shared `ProviderWizard` step components and navigate over `rendered_steps/1` (`[:provider, :auth, :model, :reasoning_schedule]`), with `current_step/2` clamping the wizard state's step to that list.
Account-wizard events: `provider_wizard_change` (change), `provider_wizard_next`, `provider_wizard_back`, `provider_wizard_cancel` and `provider_wizard_save`.
Add-model events: `provider_model_change`, `provider_model_save`, `provider_model_cancel`.
The wizard's schedule block uses its own draft (`wizard.schedule`), so a preset applied in the wizard never touches a saved account's editor state.
The account preview (derived id/name) comes from `EvoDashWeb.LLMSetup.Identity`, and the wizard never renders a secret input.

## Reasoning vocabulary — ONE keyed chip list

`ProviderProfileFields.reasoning_fields/1` renders the effort inventory as ONE stable, keyed chip list built over `EvoDashWeb.LLMSetup.Reasoning.efforts/0`: `none`, `minimal`, `low`, `medium`, `high`, `xhigh` in canonical order.
Configured custom inventory values are appended ONCE at the end; every chip carries a stable DOM id derived from its effort, so a `phx-change` round trip can never reassign a checkbox the browser already flipped.
The list submits `reasoning_efforts[]` with a hidden blank seed, so an explicitly empty inventory is distinguishable from an absent one.
`max` never appears in the dashboard vocabulary; `LLMSetup.Reasoning.canonical/1` normalizes a configured or legacy `max` to `xhigh`.
Catalog suggestions are advisory only: they mark a chip's provenance and never drive membership or order.
`ProviderProfileFields.reasoning_default/1` is a SEPARATE inventory-scoped single select for the default effort: the blank "Provider default" option renders only when the inventory is non-empty, and an unsupported saved default stays selectable for correction with `aria-invalid="true"` rather than being silently changed.
`SettingCard.reasoning_options/1` and `SettingCard.reasoning_value/1` expose the same ladder for the flat `llm.reasoning_effort` card, which search results render outside `category_section`.
`ProviderProfileFields` also supplies the shared generation grid (temperature, max tokens, top_p, top_k, frequency/presence penalty as optional numeric strings, plus the JSON `extra`/`provider_options` textareas with key-safety help), the peak/day controls (`off_peak_days[]` and `peak_hours[index][days][]` with hidden blank sentinels) and the node-correct OAuth guidance.

## Custom tool error normalization

`CustomToolsPanel.error_entry/1` always produces a map because its reason falls back to `inspect/1`, which returns a string even for a missing reason (`"nil"`).
A missing file and reason renders the unknown-file fallback plus `"nil"` rather than dropping the entry.
Error status and entry maps accept atom or string keys, and non-map error entries are ignored.

## Visual rules

Every module here writes tokens only (`base-*`, `primary`, `error`, `warning`), never a raw color and never a hex.
Borders are hairlines (`border border-base-300`), radii stay at or below `rounded-xl`, and decoration is limited to subtle tints (`bg-base-200/20`, `error/5`).
Rows are compact and dense: one line per account summary, grids inside the detail, no hero boxes, gradients or decorative blurs.
Interactive affordances that must not submit carry `type="button"`, and `summary` toggles are plain clicks.

## SettingCard and generic category cards

`SettingCard.setting_card/1` accepts `schema`, `value`, optional `error` and `disabled`, names fields with dotted schema paths (`Enum.join(schema.key_path, ".")`), and owns no form, submit/change event or draft storage.
Widgets are type-dispatched only (`:boolean`, `:string`, `:pos_integer`, `:atom` enums as a `<select>`, `:list_of_strings` as the list editor), so a new core-owned category needs no dashboard code.
`dedicated_provider_path?/1` withholds the generic input and the generic `reset_key` button for `[:llm, :models]`, `[:llm, :providers]` and `[:llm, :default_provider_profile]`; the same predicate makes `schema_matches?/2` reject those paths even for an empty query, so search counts and result cards never advertise them.
`flat_llm_schemas/1` keeps only the remaining flat `[llm]` keys (compression/pruning), excluding the provider collection, its default key and legacy model/generation fields; `:model_profiles` therefore renders as a count badge and `:model_spec` as a free-text model string.
The `:list_of_strings` editor names every entry input with the dotted key path, adds/removes entries through `add_list_entry` / `remove_list_entry` (`phx-value-key_path`, `phx-value-index`), and renders a hidden blank sentinel only for a SET list, so an absent param is the sole delete signal and a set-but-empty list persists as `[]`.
The `[:appearance, :accent_color]` card renders one hidden input plus ten swatch buttons (`data-accent-color={name}`, `phx-click="select_appearance_accent"`); the palette names come from the core schema, the visuals resolve from the `[data-accent-color]` CSS rules, and a selection only sets the pending draft (nothing persists until Save).
Public accent helpers: `accent_palette/0`, `accent_name?/1` (the handler's whitelist), `accent_active/2` (nil/unknown → the schema default) and `accent_label/1` (gettext labels; the palette names are the config values).

## ProviderWizard — shared LLM-setup step components

`EvoDashWeb.SettingsComponents.ProviderWizard` is the ONE step-component set behind both `/welcome` onboarding and the `/settings` wizards.
`provider_wizard.ex` is the facade (`wizard_shell/1` + the progress-rail helpers + the thin `step_*` wrappers) and owns every `attr`/`slot` declaration; each step's markup lives in one module under `provider_wizard/` (`provider_step.ex`, `auth_step.ex`, `model_step.ex`, `reasoning_step.ex`, `test_step.ex`, `done_step.ex`), with shared helpers (value normalization, label fallback, reason formatting, card classes) in `provider_wizard/helpers.ex`.
Every event name is an attr with a default (`back_event`, `next_event`, `cancel_event` nil = no Cancel, `provider_event`, `auth_event`, `model_event`, `model_search_event`, `custom_model_event` nil = plain input, `preset_apply_event`, `preset_undo_event`, `preset_dismiss_event` nil = no dismiss, `test_event`, `skip_event`), so each caller keeps its own vocabulary.
Slots are optional (`:inner_block`, `:auth_detail`, `:secondary`), so rendering without a slot is safe.
The step list is always `LLMSetup.Wizard.steps_for/1`, the progress tuple `Wizard.progress/2`, the reasoning ladder `LLMSetup.Reasoning`, the holidays `LLMSetup.Schedule` and the account preview `LLMSetup.Identity` — nothing here duplicates that data.
`wizard_shell/1` renders the heading, "Step N of M", a `<ol class="wizard-progress">` rail with exactly one `aria-current="step"` row, the body wrapped in `<div class="wizard-step-enter" id={"wizard-step-" <> to_string(step)}>`, an inline error strip, and the Back / optional Cancel + primary Next footer.
`step_provider/1` renders selectable provider cards with `aria-pressed`/`aria-current` plus an always-present custom-endpoint URL input.
`step_auth/1` renders only the supported mode cards (no secret input — credentials arrive through the `:auth_detail` slot).
`step_model/1` renders a searchable catalog list with `aria-current="true"` on the pick and an always-present free-text custom-model input.
A row with no usable label is never blank: `Helpers.label_or_id/2` falls back to the id (model/preset rows), while `ProviderStep.provider_label/2` falls back to `LLMSetup.Identity.provider_display_name/1` for the provider id; every LABELLED row renders its label unchanged.
A row without a usable id is dropped, and "no usable id" means `nil`, a blank/whitespace string or any value the step cannot read as a string — so a `%{}` entry in `providers`/`models`/`presets` renders nothing instead of a nameless row, and an empty list still renders the custom-endpoint card / the empty-search note.
A label or value that cleans to `nil` or `""` is treated the same way: `step_done/1` drops such a summary row rather than rendering an empty cell.
`step_reasoning_schedule/1` renders the canonical reasoning chips, the inventory-scoped default select, the applied strip, one button per schedule preset, the holiday-calendar select and the read-only summary rows.
`step_test/1` renders `:idle`/`:testing`/success/error states with an always-available skip; `step_done/1` drops blank-or-nil summary rows and offers the dashboard link.
A success answer with no usable detail (`{:ok, nil}`, `{:ok, ""}`, a `%{status: :ok}` result without a detail) still renders the "Connection succeeded" box and only omits its detail line, so a detail-less success never reads like an idle step.
`wizard-progress` and `wizard-step-enter` are styled by `assets/css/app.css`, which disables the enter animation under `prefers-reduced-motion: reduce`.

### Sign in with ChatGPT — `ChatGPTSignInPanel` + `ChatGPTAuth`
`ChatGPTSignInPanel.sign_in_panel/1` is the ONE sign-in surface in the dashboard; attrs are `id` (id prefix), `sign_in` (map `:flow_id`, `:url`, `:phase` = `:idle | :waiting | :ok | :error`, `:reason`), `manual` (boolean), `begin_event` (default `"chatgpt_sign_in"`), `cancel_event` (default `"chatgpt_sign_in_cancel"`), `surface` (`"wizard"` / `"detail"` / `"status"`), `profile_id` (default `nil`) and `command` (default `nil`, the manual-mode CLI command; nil/blank falls back to `genesis chatgpt login`).
Local mode (`manual: false`) offers the primary `#<id>-sign-in` button; `phase: :waiting` renders `#<id>-waiting` with a REAL `#<id>-sign-in-url` link (`target="_blank"`, `rel="noopener noreferrer"`, rendered only when a url exists), the "Waiting for authorization…" status line and `#<id>-sign-in-cancel`; `phase: :error` renders `#<id>-sign-in-error` (`role="alert"`) with the text from `LLMSetup.ChatGPTSignIn.message/1` toned by `kind`.
Manual mode (`manual: true`) renders no button: `#<id>-manual-hint` carries the `command` (or plain `genesis chatgpt login`) plus the one-line reason that a sign-in page can only be completed on the machine where the loopback listener can reach the browser.
The three reachable surfaces are the wizard auth step, the expanded account detail and the credential-status line; each passes its own `surface` and filters the page state through `surface_state/2` first.
Every control is `type="button"` because the panel renders inside the provider-detail `<form>`, and the begin/cancel buttons carry `phx-value-surface` plus `phx-value-profile_id` when one is set, so one handler pair serves every surface.
The `sign_in` map is interpreted TOTALLY: `nil`/non-map is idle, atom- and string-keyed maps both work, an unknown/absent phase is `:idle`, and a blank/non-binary url is dropped.
`ChatGPTSignInPanel.surface_state/2` is the ONE surface-isolation rule: given the page-level `sign_in` state and `:wizard | {:detail, id} | {:status, id} | nil`, it answers the normalized phase map for THAT surface (canonical idle map when that surface is idle) and `%{}` for a nil/non-map state, an absent/unknown surface or a different surface, so a surface never renders another surface's flow.
The page state itself is owned by `EvoDashWeb.SettingsLive.ChatGPTSignInState`; this module only interprets it.
`ProviderWizard.ChatGPTAuth.chatgpt_auth/1` adds the account part on top of that panel and delegates the sign-in section, so the sign-in markup exists once; attrs are `id`, `account`, `accounts`, `change_event`, `refresh_event`, `sign_in_event` (default `"chatgpt_sign_in"`), `cancel_event` (default `"chatgpt_sign_in_cancel"`), `sign_in`, `manual`, `surface` (default `"wizard"`) and `profile_id` (default `nil`), all forwarded to the panel.
Its order is account select form → "ChatGPT connected" line → sign-in panel → refresh button: the account select (`#<id>-form` / `#<id>-account`), the "ChatGPT connected" status line and the `#<id>-refresh` "Check connection" button (`phx-value-refresh_chatgpt="true"`) are present in BOTH modes, and `ChatGPTSignIn` owns every message so no raw atom is ever rendered.
`provider_profiles/wizard_form.ex` threads `wizard.chatgpt_sign_in` / `wizard.chatgpt_sign_in_manual` into it and tolerates both being absent (`%{}` / `false`); `chatgpt_auth_ready?/2` still means "the selected account is a connected registration".
## Settings pane layout

The Settings page is a bounded-height two-column layout on md+: `#main-content` is `flex-1 min-h-0`, the settings root is `flex flex-col md:h-full`, warning banners are `shrink-0` siblings, and the sidebar and content columns scroll independently.
Every main-axis non-scroll flex intermediary between a bounded column and its inner `overflow-y-auto` body carries `min-h-0`; a content-column root never carries `h-full`.
Unified pane shape: root column (`flex-1 flex flex-col min-w-0 min-h-0`, `id="category-<cat>"`) → pinned `.section_header` → `flex-1 overflow-y-auto` scroll body → ONE minimal pinned `.save_bar` as a non-scrolling sibling.
The `:llm` pane keeps its flat `settings-form-llm` form and flat cards inside the scroll body, while its save bar sits outside the form and submits via `form="settings-form-llm"`; the provider panel and the connection-test card keep their own independent forms.
The config path lives only in the sidebar footer: a truncating `<code>` plus the copy button `#settings-config-path-copy` (`phx-hook="ClipboardCopy"`), with a "File does not exist yet" line when missing; the sidebar declares `config_path` and `config_file_exists` and renders for every category.

## Constraints

- All component modules use `use EvoDashWeb, :html` and are pure functions — assigns in, HEEx out, no state and no core calls during render.
- Styling is Tailwind CSS + daisyUI with theme tokens only; labels and help text are Gettext-wrapped.
- Every removed-item/action button inside a form is `type="button"`.
- Follows the project-wide `try/rescue` anti-pattern policy (no defensive rescuing of core calls; whitelist `Map` lookups for atom conversion).
