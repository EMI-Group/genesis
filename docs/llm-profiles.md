# LLM provider profiles and task model selection

Configure an account once, list the models you want to use, then select a model for each task.
This guide describes the canonical provider-profile format in `config.toml` and the current dashboard and CLI behavior.

## 1. Accounts are not task selections

A **provider profile** is a named account or endpoint configuration: credentials, provider, shared defaults, concurrency and schedule.
One profile can serve multiple models and reasoning efforts; you do not need a separate account for each effort.
Create separate profiles when credentials, endpoints or scheduling policies differ.

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

## 4. Configure through the UI or wizard

### Settings → LLM → Provider profiles

Use the provider-profile editor for account identity, authentication, endpoint, concurrency, schedule and shared defaults.
Add nested model entries for every model you plan to select, with overrides only where needed.
Enter reasoning efforts as an **ordered inventory** in the text field, then choose a default from the default dropdown.
Order matters for the dashboard's first-effort fallback, even though it does not define a core default.
Leave a default blank to inherit or omit it, subject to the UI behavior above.
Save explicitly after reviewing the configuration.

### Welcome setup

Welcome setup is **local-only**.
Choose a provider, add multiple models, choose the default model, configure authentication, then test and save.
Each model has an effort dropdown; its blank **Provider default** choice inherits the provider default rather than disabling reasoning.
Use Settings for ongoing profile management and shared schedule/default editing.

### CLI setup

```bash
genesis setup
```

The wizard writes canonical provider accounts and their model inventory.
It does not prompt for reasoning effort; configure inventories and defaults later in Settings or `config.toml`.

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

After replacing the placeholder with the same configured model ID used above:

```bash
genesis evolve "Fix the failing tests" --path ./my-project \
  --provider-profile work --model REPLACE_WITH_MODEL_ID --reasoning-effort high
```

Canonical CLI selection requires **both** `--provider-profile` and `--model`.
`--reasoning-effort` is optional, but cannot be used alone; `high` here belongs to the example model's advertised inventory.
Legacy `-m` model/profile matching remains supported for compatibility.
For Auto behavior, omit all selection flags so model-selection rules can choose.

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
Schedules also apply to the whole account.

An explicit in-peak `peak_concurrency` is honored even below the global concurrency floor, including **0**.
Zero queues new requests until capacity resumes; reducing capacity does not evict in-flight requests.
`off_peak_days` wins over peak windows for the entire day.
Windows are half-open; overnight windows are supported.
If `timezone` is absent or blank, scheduling uses the server's local wall clock, not UTC.

## 8. Existing configurations

A nonempty canonical `llm.providers` list takes precedence over legacy configuration.
Otherwise, legacy `[[llm.models]]` or flat `[llm]` settings are converted **in memory**, one-to-one, preserving IDs.
Reading config neither merges accounts nor rewrites the file.

Use an explicit Settings/config save to migrate deliberately; canonical saves strip legacy fields.
Welcome setup is an exception to a blanket cleanup expectation: it preserves old raw entries while appending a canonical provider.
Review the saved file rather than assuming every setup path removes legacy entries.
Consolidate old profiles manually only when they really share credentials and scheduling policy.
Keep separate accounts when combining them would incorrectly share slots, backoff or authentication.
