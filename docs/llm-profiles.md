# LLM provider profiles and task model selection

Configure an account once, list the models you want to use, then select a model for each task.
This guide describes the canonical provider-profile format in `config.toml` and the dashboard behavior.

## 1. Accounts are not task selections

A **provider profile** is a named account or endpoint configuration: credentials, provider, shared defaults, concurrency and schedule.
One profile can serve multiple models and reasoning efforts; you do not need a separate account for each effort.
Create separate profiles when credentials, endpoints or scheduling policies differ.

Account identity follows the **provider**, never a model: an account is a `deepseek` or `zai_coding_plan` account that happens to serve several models, not a `REPLACE_WITH_MODEL_ID` account.
The dashboard enforces this by deriving a new account's id from the provider's slug (with collision-safe `-2`/`-3` suffixes) and its display name from the provider's catalog entry, so a second account for the same vendor reads `<provider>-2` rather than a model name.
An id or name you type explicitly is kept as written; the rule constrains what the dashboard generates.
Naming an account after one of its models misdescribes it, because every model and effort in the account shares its slots, backoff and schedule.

A **task selection** is a credential-free identity:

```elixir
%{provider_profile_id: "work", model: "REPLACE_WITH_MODEL_ID", reasoning_effort: "high"}
```

`reasoning_effort` is optional in the core API.
The profile ID is your account label, not a provider name or model ID.
Never put API keys or OAuth tokens in this selection.

## 2. A practical configuration

**All model IDs below are placeholders**, not claims of catalog availability.
Replace `REPLACE_WITH_MODEL_ID` and `REPLACE_WITH_SECOND_MODEL_ID` everywhere with actual IDs served by your chosen provider.
The example uses the `openai` provider; change it and the advertised effort values to match your endpoint's capabilities.

```toml
[llm]
default_provider_profile = "work"

[[llm.providers]]
id = "work"
name = "Work account"
provider = "openai"
auth_mode = "api_key"
api_key_env_var = "WORK_LLM_API_KEY"
# Optional: a compatible endpoint's base URL, not a model URL.
# base_url = "https://YOUR_ENDPOINT.example/v1"
concurrency = 3
context_window = 200000
temperature = 0.7
max_tokens = 4096
reasoning_efforts = ["low", "high"]
default_reasoning_effort = "low"
default_model = "REPLACE_WITH_MODEL_ID"

# Optional schedule, shared by every model in this account.
peak_concurrency = 1
timezone = "Asia/Hong_Kong"
off_peak_days = ["sat", "sun"]
# Optional: treat a calendar's non-working days as off-peak (see §7).
# off_peak_holidays = "CN"
peak_hours = [{start = "09:00", end = "18:00", days = ["weekdays"]}]

[[llm.providers.models]]
model = "REPLACE_WITH_MODEL_ID"

[[llm.providers.models]]
model = "REPLACE_WITH_SECOND_MODEL_ID"
context_window = 100000
max_tokens = 2048
reasoning_efforts = ["high"]
default_reasoning_effort = "high"
```

**Include every selectable model in `[[llm.providers.models]]`.**
The backend requires the selected model to belong to this configured inventory.
Setting only `default_model`, without a matching inventory entry, does not make a model resolvable.
Settings permits free-text model entries, but that is not permission to select an unconfigured model at task start.
Do not rely on help text suggesting that a default model alone is sufficient.

Provider-level `context_window` and generation defaults apply unless a model entry overrides them.
Generation settings include `temperature`, `max_tokens`, `top_p`, `top_k`, `frequency_penalty` and `presence_penalty`; use only those supported by the provider/model.
`context_window` defaults to **200000** and sets Genesis's configured context-compression budget: it is not automatically taken from catalog metadata.
Choose a budget appropriate to the endpoint's actual limits.

A model's `reasoning_efforts` list replaces the inherited effort inventory.
A model-level `provider_options` map **replaces** the account map; it does not deep-merge it.
If overriding that map, include all required non-secret options again.

## 3. Defaults and reasoning effort

Core resolution follows these orders:

| Choice | First available value wins |
|---|---|
| Provider profile | Explicit selection → `[llm].default_provider_profile` → first configured profile |
| Model | Explicit selection → account `default_model` → first configured model |
| Reasoning effort | Explicit selection → model's configured default → account's configured default → omit parameter |

The first effort inventory item is **not** a configured core default.
The inventory advertises supported choices; `default_reasoning_effort` separately selects a default.
A model-specific effort inventory must be consistent with the default it inherits or overrides.

`"none"` is an ordinary explicit effort value, usable only when the model advertises support for it.
It is neither an unset marker nor a universal way to disable reasoning.
There is no task-level unset value that clears an inherited default.
A blank default in the editor means **inherit/omit**, not `"none"`.

### The canonical effort ladder

One ladder is the single source of truth: `EvoGit.Config.Schema.LLM.reasoning_efforts/0` returns `[:none, :minimal, :low, :medium, :high, :xhigh]` in ascending intensity.
`EvoGit.Config.Schema.LLM.reasoning_effort_options/0` returns that ladder plus `:default`, which is the ordered pick list a UI renders.
`:default` — and an absent or unset value — means "send no `reasoning_effort` field at all", so the provider's own default applies; it is a UI choice, not a provider level.
`EvoGit.Config.Schema.LLM.allowed?/1` is the total acceptance predicate (case-insensitive, whitespace-tolerant, `nil` accepted) and `EvoGit.Config.Schema.LLM.canonical_reasoning_effort/1` the total normalizer.
`max` is **not** a Genesis level: it is an accepted legacy alias of `xhigh`, so `canonical_reasoning_effort/1` reads a `"max"` string or a `:max` atom as `:xhigh`, a persisted `"max"` keeps loading, and a later save writes `xhigh`.
`allowed?("max")` is therefore `false`, and `reasoning_efforts/0` never contains it.
The schema enum of the flat `[llm] reasoning_effort` key is derived from `reasoning_effort_options/0`, so it offers exactly that list.

Use ladder names in `reasoning_efforts`, `default_reasoning_effort`, a task selection's `reasoning_effort` and the flat `[llm] reasoning_effort`.
The inventory is an ordered advertisement of what the model supports; the rank of a level carries no meaning for resolution.

### Vendor spellings are translated at the request boundary

Genesis keeps **one** ladder and adapts to a vendor's own vocabulary at the last moment, inside `EvoGit.Config.Schema.LLMConstraints`.
A table's `:reasoning_effort` allowlist is expressed in Genesis levels, and its `:reasoning_effort_wire_aliases` map renames a level that already survived that check.
Z.AI GLM-5.3 / GLM-5.3-FLASH document exactly `low|high|max`, so their allowlist is the Genesis levels `low|high|xhigh` and `xhigh` is emitted as the vendor's `max`.
This is a translation of an accepted level, never a silent substitution: the level you configure is the level sent, only the spelling changes.
An effort outside a model's documented set — or a model whose metadata declares no reasoning support — is omitted from the request with a logged warning, and the key order of the surviving parameters is preserved.
`EvoGit.Config.Schema.LLM.profile_generation_params/1` remains the single choke point where this filtering runs.

### Dashboard behavior differs from omitted core effort

Projects and the [Assistant](genesis-assistant.md) use shared provider/model dropdowns and an effort slider based on the advertised inventory:

- A resolved configured default selects that effort.
- With a nonempty inventory and no resolved default, the UI selects the **first effort**.
- There is **no omit position** on the slider.
- With no inventory, there is no slider and no task effort is sent.
- With one effort, the slider is disabled at that value.

Consequently, a dashboard selection can send an explicit first effort where an API caller omitting effort would send no parameter.
Switching provider profile or model resets dependent choices; recheck the model and effort before starting.

**Auto** omits the task selection and lock, leaving model-selection rules in control.
A concrete selection locks the full provider/model/effort identity downstream, rather than just a model name.
Choices use the selected node's configuration: remote-node selection does not silently fall back to local profiles.

## 4. Configure through the dashboard

### Settings → LLM → Provider profiles

Use the provider-profile editor for account identity, authentication, endpoint, concurrency, schedule and shared defaults.
Add nested model entries for every model you plan to select, with overrides only where needed.
Enter reasoning efforts as an **ordered inventory** in the text field, then choose a default from the default dropdown.
Enter ladder names (see §3); the editor writes the values you supply and the core owns authoritative validation, and a model's inventory must still contain its own default.
Order matters for the dashboard's first-effort fallback, even though it does not define a core default.
Leave a default blank to inherit or omit it, subject to the UI behavior above.
Save explicitly after reviewing the configuration.

### Welcome setup

Welcome setup is **local-only**.
Choose a provider, add multiple models, choose the default model, configure authentication, then test and save.
Each model has an effort dropdown; its blank **Provider default** choice inherits the provider default rather than disabling reasoning.
Use Settings for ongoing profile management and shared schedule/default editing.

## 5. Keep credentials separate

Store secrets in `credentials.toml` or environment variables, not in model inventories or task choices.
`api_key_env_var` names the **exact environment variable**, then the **exact saved credential key** used as fallback.
For the example, both lookups use `WORK_LLM_API_KEY`.
Different profile IDs alone do not isolate API keys: use distinct credential names when accounts need distinct keys.
Make environment variables available to the Genesis process that owns the configuration, including a remote server when applicable.

Do not paste tokens into `provider_options`, provider/model tables in `config.toml`, or browser task selections.
Use the authentication controls for secret entry.
For subscription authentication and vendor-CLI login import, see [Subscription (OAuth) LLM Support](llm-oauth.md).

## 6. Start a task

In the dashboard task form, choose **Provider profile** → **Model** → optional reasoning effort; an explicit choice locks the concrete selection for the task and its agents, while **Auto** leaves the choice to the configured rules and defaults.
Pass the same selection to MCP task submission to start a task programmatically.

For integrations with an already loaded config, resolve the credential-free selection through the schema API:

```elixir
selection = %{provider_profile_id: "work", model: "REPLACE_WITH_MODEL_ID", reasoning_effort: "high"}
EvoGit.Config.Schema.resolve_model_spec(config, selection)
# => {:ok, resolved} | {:error, reason}
```

Use the identity map as the selection, not `resolved.model_spec`: that field is a request identifier, not the selection contract.
Handle resolution errors before submitting work, especially after changing an inventory.

## 7. Shared limits and schedules

Concurrency slots and exhaustion backoff are shared **per provider profile**, across all its concrete models and efforts.
Adding another model or effort does not create a separate quota pool.
Schedules also apply to the whole account: an account carries `concurrency`, `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days` and `off_peak_holidays`.

### Peak windows and days

An explicit in-peak `peak_concurrency` is honored even below the global concurrency floor, including **0**.
Zero queues new requests until capacity resumes; reducing capacity does not evict in-flight requests.
`off_peak_days` wins over peak windows for the entire day.
Windows are half-open; overnight windows are supported, and a window may carry its own `days`.
If `timezone` is absent or blank, scheduling uses the server's local wall clock, not UTC.

### Holiday-aware off-peak

An account may set `off_peak_holidays` to a holiday-calendar id; the only calendar shipped is `"CN"` (`EvoGit.PeakHours.Holidays.calendars/0`).
`EvoGit.PeakHours.validate_holidays/1` validates the key: `nil`/`""` and any id the calendar table knows (case-insensitive) pass, and anything else returns `{:error, {:unknown_calendar, value}}`, which the config schema reports at the account key.
The key is account-level only; nested model entries neither read nor validate it.

A date the calendar reports as a non-working day is off-peak for the **entire** day, exactly like an `off_peak_days` entry.
A 调休 make-up workday (补班) is a working day even on a Saturday or Sunday, so windows apply there and the day is never off-peak.
`off_peak_holidays` is applied by `EvoGit.PeakHours.in_peak?/4`, `EvoGit.PeakHours.next_transition/4` and `EvoGit.PeakHours.effective_concurrency/2,3`, and `EvoGit.PeakHourEngine` carries the raw account key through to those calls rather than re-implementing any calendar logic.
The midnight edges of a holiday block (and of a make-up workday) are real peak-state transitions, so the engine wakes there instead of sleeping through the block.

The data lives in `EvoGit.PeakHours.Holidays`, a static module — no dependency, no clock, no network, and no automatic updates.
It publishes `calendars/0`, `supported_years/0`, `holiday?/1`, `make_up_workday?/1`, `non_working_day?/1` and `holiday_name/1`, over statutory holidays and 调休 make-up workdays for 2025, 2026 and 2027.
`non_working_day?/1` is "statutory holiday, or an ordinary weekend that is not a make-up workday".
The predicates are total and take a wall-clock `%Date{}` (a `%NaiveDateTime{}` uses its date): a year outside the table answers `false` everywhere, so an unextended calendar degrades to weekend-only behaviour instead of raising.

To add a year, edit the module's data after the State Council publishes the arrangement (usually in November): append one `{~D[YYYY-MM-DD], "name"}` entry per statutory holiday day, append the make-up workdays as plain date literals, and add the year to the supported-years list.
Keep both lists ascending and unique, and mark a not-yet-official year in `provisional_years/0` instead of assuming it.
Adding another calendar means a new id in `calendars/0` plus its own holiday and make-up-workday data; the schedule evaluator resolves the id through this table, so no config key changes.

### Built-in schedule presets

`EvoGit.Config.ProviderPresets` carries the machine-readable copy of the peak/off-peak policies a vendor publishes unambiguously, so an account's schedule does not have to be hand-written from prose.
It exposes `all/0` (display order), `ids/0`, `get/1` by stable id (`nil` when unknown or not a binary) and `for_provider/1` (by provider atom or case-/separator-insensitive name, `[]` when unknown).
Each preset is the envelope `%{id, label, provider, schedule, note}`, where `schedule` is **string-keyed** so it merges straight into a canonical (string-keyed) `[[llm.providers]]` account over `concurrency`, `peak_concurrency`, `peak_hours`, `timezone`, `off_peak_days` and `off_peak_holidays`.
A preset carries only the keys its provider's policy actually uses, and every preset is valid input for `EvoGit.PeakHours.validate_windows/1`, `validate_days/1` and `validate_holidays/1`.

Two presets ship:

| Id | Provider | Schedule it describes |
|---|---|---|
| `deepseek-standard` | `:deepseek` | Peak 01:00–04:00 and 06:00–10:00 UTC Monday–Friday, half price off-peak, weekends and Chinese public holidays fully off-peak (`timezone "UTC"`, weekday windows, `off_peak_days ["sat", "sun"]`, `off_peak_holidays "CN"`). |
| `zai-glm-coding-plan` | `:zai_coding_plan` | Peak Monday–Friday 14:00–18:00 Singapore time (UTC+8), off-peak charged at 50 % of the standard credit rate, no holiday exclusions (`timezone "Asia/Singapore"`, one weekday window, `off_peak_days ["sat", "sun"]`). |

A provider with no published time-of-day policy deliberately gets no preset: `:anthropic`, `:openai`, `:openai_codex`, `:google`, `:xai` and `:openrouter` publish none; pay-as-you-go `:zai` lists flat per-token prices and only its Coding Plan subscription has peak terms; `:moonshotai` lists flat prices; `:minimax` thins traffic in peak hours without time-of-day pricing; and `:alibaba` scopes its night window to individual, often limited-time, model discounts rather than an account-level schedule.
The per-provider reasons live in the module's moduledoc, next to the verified sources.

No vendor publishes "Genesis LLM slots", so a published price, quota or credit multiplier is mapped conservatively: a rate that doubles in peak (halves off-peak) becomes `peak_concurrency` = half of `concurrency`.
That ratio is a pre-fill default to be edited, never a claim about vendor capacity.

The module is data only: it writes no config, touches no disk, starts no process, reads no clock and raises on nothing.
Nothing applies a preset automatically — you (or a UI acting for you) copy one into an account's schedule fields and then adjust it.

## 8. Existing configurations

A nonempty canonical `llm.providers` list takes precedence over legacy configuration.
Otherwise, legacy `[[llm.models]]` or flat `[llm]` settings are converted **in memory**, one-to-one, preserving IDs.
Reading config neither merges accounts nor rewrites the file.

Use an explicit Settings/config save to migrate deliberately; canonical saves strip legacy fields.
Welcome setup is an exception to a blanket cleanup expectation: it preserves old raw entries while appending a canonical provider.
Review the saved file rather than assuming every setup path removes legacy entries.
Consolidate old profiles manually only when they really share credentials and scheduling policy.
Keep separate accounts when combining them would incorrectly share slots, backoff or authentication.
