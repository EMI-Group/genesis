# LLM Setup — Shared Foundation (`EvoDashWeb.LLMSetup`)

## Intent

The PURE foundation of the dashboard's LLM-configuration UI, shared by `/welcome` onboarding and `/settings`.
Four small modules own the facts both surfaces must agree on — the reasoning vocabulary, provider-derived account identity, provider schedule presets/holiday calendars, and the wizard step model — so neither page re-implements (and drifts from) them.
Nothing here renders markup: the components live in `../components/settings_components/provider_wizard.ex`.
Every module is PURE and TOTAL: no I/O, no catalog lookup at render time beyond the core's own pure tables, no process, no clock, no `try/rescue`, and no raise on `nil`/wrongly-typed input.

## API Surface

| Module | File | Responsibility |
|--------|------|----------------|
| `EvoDashWeb.LLMSetup.Reasoning` | `reasoning.ex` | The dashboard's SINGLE reasoning vocabulary, delegated to the core ladder. |
| `EvoDashWeb.LLMSetup.Identity` | `identity.ex` | Provider-DERIVED account `id`/`name` + collision-safe uniqueness. |
| `EvoDashWeb.LLMSetup.Schedule` | `schedule.ex` | Provider schedule presets (apply/undo/snapshot) + off-peak holiday calendars. |
| `EvoDashWeb.LLMSetup.Wizard` | `wizard.ex` | The pure wizard step model shared by both pages (order, navigation, gating). |

### `Reasoning`

`efforts/0` → `["none","minimal","low","medium","high","xhigh"]` in core order (`EvoGit.Config.Schema.LLM.reasoning_efforts/0`), never `"max"`.
`options/0` → `efforts/0 ++ ["default"]` (`"default"` = send no field, provider decides).
`allowed?/1` delegates to `Schema.LLM.allowed?/1` (`"max"` is NOT an option).
`canonical/1` → core canonical level as a STRING, `"max"`/`:max` → `"xhigh"`, `nil`/unknown → `nil`.
`level?/1` → true only for a canonical LEVEL (so `"default"` is false, `"max"` is true as `"xhigh"`).
`label/1` → gettext label for the ladder and `"default"`; an unknown configured value is returned as its own cleaned string.
`normalize_inventory/1` → order-preserving, blank-dropping, case-insensitive-dedup, canonicalizing, TOTAL inventory list; KEEPS unknown configured values; never invents a level and never returns `"max"` for `"xhigh"`.
`inventory_of/1` / `default_of/1` read a string- or atom-keyed draft map (`"reasoning_efforts"`, `"default_reasoning_effort"`); `default_of/1` answers the canonical default ONLY when it is one of the draft's own inventory levels, else `nil` (= provider default).
`inventory_input_name/0` → `"reasoning_efforts[]"`, `default_input_name/0` → `"default_reasoning_effort"` (the ONE form names both surfaces submit).

### `Identity`

`provider_display_name/1` — the PROVIDER's catalog `display_name` (`:zai` / `"zai"` → `"Z.ai (Zhipu AI)"`), a titleized spelling for an unknown non-blank value, and gettext "Custom endpoint" for `nil`/blank. NEVER derived from a model.
`provider_slug/1` — lowercase ASCII slug of the catalog id (`:openai_compatible` → `"openai-compatible"`), or of the display name when the provider is not in the catalog (`"My Proxy"` → `"my-proxy"`); `nil`/blank slugs to `"custom-endpoint"` (it resolves THROUGH `provider_display_name/1`, whose nil/blank answer is gettext "Custom endpoint"), so `default_identity(nil, existing)` is `%{"id" => "custom-endpoint", "name" => "Custom endpoint"}` with `-2`/`-3` collision suffixes — the `profile-N` scheme only applies when a blank BASE is passed to `unique_id/2` directly.
`unique_id/2` — `base`, else `base-2`, `base-3`, … (case-insensitive collision check, comparison against strings/atoms/account maps/maps keyed by id); blank base → `profile-1`, `profile-2`, ….
`unique_name/2` — the same rules over display names; blank base → gettext "Account".
`default_identity/2` → `%{"id" => …, "name" => …}` for a new account, uniquified against the already-configured accounts.
`account_ids/1` / `account_names/1` — total extraction helpers (list of maps, bare ids, map keyed by id, `nil`).
An explicitly typed name/id is never re-derived: the caller keeps the last word.

### `Schedule`

`schedule_keys/0` → `concurrency`, `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days`, `off_peak_holidays` — the ONLY keys `apply/2` writes (never identity/auth/model keys).
`presets_for_provider/1` / `preset/1` — the core's `EvoGit.Config.ProviderPresets` inventory for a provider atom/string / one preset by id.
`snapshot/1` — the schedule subset (present keys only) of a draft, for undo.
`apply/2` → `{draft, snapshot}`: merges a preset's `:schedule` into a STRING-KEYED draft (peak-hour rows become string-keyed maps) and returns the PRE-APPLY snapshot.
`undo/2` — restores snapshot keys verbatim and REMOVES schedule keys the snapshot does not carry; non-schedule keys are never touched.
`changed?/2` — true when the draft's schedule subset differs from the snapshot (clears to false after `undo/2` with that same snapshot).
`summary_rows/1` → `[{label, value}]` schedule summary rows in display order (shared by the wizard's schedule block and its done summary).
`holiday_calendars/0` → `["CN"]`; `holiday_label/1` → gettext "China (CN)" (blank → "No public-holiday calendar", unknown id shown as-is); `holiday_options/0` → `{value, label}` for REAL calendars only (the "none" option is the caller's); `holidays_supported_year_range/0` → `{first, last}`; `holiday_help/0` → the one-line localized explanation that a calendar's public holidays plus weekends count as off-peak.

### `Wizard`

`all_steps/0` → `[:provider, :auth, :model, :reasoning_schedule, :test, :done]`.
`steps_for/1` — the ordered run; `auth_choice?: false` (atom- or string-keyed capabilities map) drops `:auth`, so onboarding only asks the auth question where it is real.
`first/1`, `next/2`, `back/2` (both CLAMPED: last/first step stays), `index/2` (nil when absent), `step_at/2`, `progress/2` → `{current, total, percent}` with `percent` a pure integer 1..100.
`validate(step, draft)` → `:ok | {:error, reason}`: `:provider` needs a non-blank provider (`:missing_provider`), `:auth` needs `"api_key"`/`"oauth"` (`:invalid_auth_mode`), `:model` needs a catalog pick OR a custom model name (`:missing_model`); `:reasoning_schedule`, `:test`, `:done` and unknown steps never block.
No persisted state and no config access: the caller owns the draft and its persistence.

## Constraints

- Pure and total — no `try/rescue`, no process, no disk, no clock; `nil`/wrong shapes degrade to `[]`, `%{}` or the input unchanged.
- The reasoning ladder, the presets and the holiday table are NEVER copied here — they are delegated to `EvoGit.Config.Schema.LLM`, `EvoGit.Config.ProviderPresets` and `EvoGit.PeakHours.Holidays`.
- String-keyed drafts are the currency (`apply/2`, `snapshot/1`, `undo/2`); atom keys are tolerated on input and normalized away.
- All user-facing text is gettext-wrapped with a `# zh_CN:` anchor beside ambiguous labels (无/极低/低/中/高/极高/跟随提供方, 并发/高峰并发, 提供方/认证/模型/推理与时段/测试/完成).
- Never run `mix gettext.extract` / `mix gettext.merge` / `mix translate` during feature work.

## Test Strategy

Coverage is module-level ExUnit in the `apps/evo_dash/test` node (`test/evo_dash_web/llm_setup/{reasoning,identity,schedule,wizard}_test.exs`), `async: true` because none of these modules touch global state — that suite does not exist yet.
The pins it must hold: `efforts/0` contains exactly the canonical six and never `"max"`; `options/0` appends `"default"`; `canonical/1` returns strings and reads `"max"` as `"xhigh"`; `normalize_inventory/1` dedups, canonicalizes and keeps unknown values.
`Identity` pins provider-derived naming (two accounts of one provider differ by a `-2` suffix on BOTH id and name), collision suffixes, case-insensitive comparison, the `profile-N` blank-base scheme and the unknown/`nil` fallbacks.
`Schedule` pins the deepseek preset's applied schedule keys, `snapshot/1` returning only pre-existing keys, `undo/2` restoring them and removing preset-introduced ones, `changed?/2` clearing after undo, and the holiday calendar list/options/label/year range.
`Wizard` pins the six-step order with and without `auth_choice?: false`, clamped `next/2`/`back/2`, `index/2`, the `progress/2` tuples (`{4, 6, 67}`, `{6, 6, 100}`, `{0, total, 0}` for an unknown step) and every `validate/2` gate and reason.

## Routing Table

- `../components/settings_components/provider_wizard.ex` → `EvoDashWeb.SettingsComponents.ProviderWizard`, the step components that render these facts.
- `../live/welcome_live/` → onboarding that consumes this foundation (later rework step).
- `../live/settings_live/` → the canonical provider editor that consumes it (later rework step).
