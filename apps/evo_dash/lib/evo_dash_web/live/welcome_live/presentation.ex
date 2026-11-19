defmodule EvoDashWeb.WelcomeLive.Presentation do
  @moduledoc """
  PURE view-model helpers behind `/welcome`'s step-by-step wizard.

  The page (`EvoDashWeb.WelcomeLive`) owns assigns, events and persistence; this
  module turns the page's draft (`EvoDashWeb.WelcomeLive.Wizard`) plus the core
  catalog into the exact values the shared step components
  (`EvoDashWeb.SettingsComponents.ProviderWizard`) render — provider cards,
  variant chips, model rows, the primary model's reasoning inventory/default,
  the applied schedule preset and the per-step copy.

  It owns NO state and NO side effect: no I/O, no process, no clock, no
  `try/rescue`, no `String.to_atom/1`. Catalog entries are TRUSTED server data,
  so a client string is only ever COMPARED with `Atom.to_string/1` and the atom
  handed back is one that already exists in the catalog.

  The step order, the draft's transitions and the reasoning/schedule
  vocabularies are NOT re-implemented here: they belong to
  `EvoDashWeb.LLMSetup.Wizard`, `.Reasoning` and `.Schedule`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.LLMSetup.{Reasoning, Schedule}
  alias EvoDashWeb.WelcomeLive.Wizard
  alias EvoGit.Config.LLMCatalog, as: Catalog

  # The `phx-value-provider` of the shared custom-endpoint card.
  @custom_value "custom"
  # The catalog entry that card stands for: the OpenAI-compatible endpoint.
  @custom_endpoint_id "openai_compatible"

  @doc "The `phx-value-provider` of the custom-endpoint card (`\"custom\"`)."
  @spec custom_value() :: String.t()
  def custom_value, do: @custom_value

  # ── catalog resolution (strings only, never interned) ──────────────────────

  @doc """
  The catalog provider entry for a draft's `"provider"` value.

  `"custom"` maps to the OpenAI-compatible catalog entry (which declares
  `requires_base_url`); an unknown/blank value answers `nil`, so every caller
  degrades instead of raising.
  """
  @spec provider_entry(term(), term()) :: map() | nil
  def provider_entry(providers, value) do
    case value |> clean() |> String.downcase() do
      "" -> nil
      @custom_value -> find_provider(providers, @custom_endpoint_id)
      wanted -> find_provider(providers, wanted)
    end
  end

  @doc "The variant entry of `entry` whose id string equals `value` (`nil` when absent)."
  @spec variant_entry(term(), term()) :: map() | nil
  def variant_entry(entry, value) do
    case clean(value) |> String.downcase() do
      "" -> nil
      wanted -> Enum.find(variants(entry), &(Atom.to_string(&1.id) == wanted))
    end
  end

  @doc "The variant ATOM id for a stored variant string (only atoms the catalog already owns)."
  @spec variant_id(term(), term()) :: atom() | nil
  def variant_id(entry, value) do
    case variant_entry(entry, value) do
      %{id: id} -> id
      _entry -> nil
    end
  end

  @doc "The first variant's id STRING (the default selection), or `nil` for a variant-less provider."
  @spec first_variant(term()) :: String.t() | nil
  def first_variant(entry) do
    case variants(entry) do
      [%{id: id} | _rest] -> Atom.to_string(id)
      _none -> nil
    end
  end

  @doc """
  The provider's WIRE atom for a variant (`:zai` + `:zai_coding_plan` →
  `:zai_coding_plan`): runtime identity, the key the schedule presets and the
  OAuth guidance are looked up by.
  """
  @spec wire_atom(term(), term()) :: atom() | nil
  def wire_atom(entry, variant_id) do
    case entry do
      %{id: id} when is_atom(id) and not is_nil(id) -> Catalog.resolve_provider_atom(id, variant_id)
      _entry -> nil
    end
  end

  @doc "Selectable provider cards (`%{\"id\" => string, \"label\" => localized brand name}`)."
  @spec provider_options(term()) :: [%{String.t() => String.t()}]
  def provider_options(providers) do
    providers
    |> List.wrap()
    |> Enum.reject(&(&1[:custom_model] == true))
    |> Enum.sort_by(&String.downcase(to_string(&1.display_name)))
    |> Enum.map(fn entry ->
      %{"id" => Atom.to_string(entry.id), "label" => t_provider(entry.display_name)}
    end)
  end

  @doc "Selectable variant chips, or `[]` for a provider that declares no variants."
  @spec variant_options(term()) :: [%{String.t() => String.t()}]
  def variant_options(entry) do
    Enum.map(variants(entry), fn variant ->
      %{"id" => Atom.to_string(variant.id), "label" => to_string(variant.display_name)}
    end)
  end

  @doc "The flat-model entries as model rows (`id`/`label`/`variant`)."
  @spec model_rows(term()) :: [%{String.t() => String.t() | nil}]
  def model_rows(entries) do
    Enum.map(List.wrap(entries), fn entry ->
      %{
        "id" => entry.model_string,
        "label" => entry.model_display_name,
        "variant" => entry.variant_display_name
      }
    end)
  end

  @doc "The flat-model entry for a draft model string (`nil` for a custom/unknown name)."
  @spec model_entry(term(), term()) :: map() | nil
  def model_entry(entries, model_string) do
    case clean(model_string) do
      "" -> nil
      model -> Enum.find(List.wrap(entries), &(&1.model_string == model))
    end
  end

  # ── draft-derived view values ──────────────────────────────────────────────

  @doc """
  `true` when the draft's primary model is the FREE-TEXT custom name (so its
  reasoning inventory/default live in the draft rather than in the catalog).
  """
  @spec custom_primary?(term()) :: boolean()
  def custom_primary?(draft) do
    model = model(draft, "default_model")
    custom = model(draft, "custom_model")
    custom != "" and model == custom
  end

  @doc """
  The reasoning inventory the reasoning step displays for the draft's primary
  model: the draft's own (expanded for an unrestricted empty inventory) for the
  custom name, else the catalog entry's display inventory.
  """
  @spec primary_inventory(term(), term()) :: [String.t()]
  def primary_inventory(draft, entry) do
    if custom_primary?(draft) do
      Wizard.reasoning_choices(Map.get(draft, "reasoning_efforts"))
    else
      List.wrap(Map.get(entry || %{}, :reasoning_efforts))
    end
  end

  @doc "The primary model's default reasoning effort (`\"\"` = provider default)."
  @spec primary_effort(term()) :: String.t()
  def primary_effort(draft) do
    if custom_primary?(draft) do
      model(draft, "default_reasoning_effort")
    else
      draft |> map_field("model_reasoning") |> Map.get(model(draft, "default_model"), "")
    end
  end

  @doc """
  The applied schedule preset the reasoning step's strip renders — `nil` when
  nothing was applied or the strip was dismissed.

  Derived from `Wizard.preset_state/1`, so a manual schedule edit never
  silently re-applies (or discards) a preset.
  """
  @spec preset_applied(term(), boolean()) :: map() | nil
  def preset_applied(_draft, true), do: nil

  def preset_applied(draft, _dismissed?) do
    case Wizard.preset_state(draft) do
      %{applied?: true, preset: %{} = preset} -> preset
      _state -> nil
    end
  end

  @doc "The schedule presets the provider publishes (`[]` when it publishes none)."
  @spec schedule_presets(term(), term()) :: [map()]
  def schedule_presets(entry, variant_id) do
    case wire_atom(entry, variant_id) do
      nil -> []
      atom -> Schedule.presets_for_provider(atom)
    end
  end

  @doc "The vendor login guidance for an OAuth provider (`\"\"` when it has none)."
  @spec login_instructions(term()) :: String.t()
  def login_instructions(wire_atom) when is_atom(wire_atom) and not is_nil(wire_atom) do
    to_string(EvoGit.Auth.login_instructions(wire_atom))
  end

  def login_instructions(_wire_atom), do: ""

  # ── copy ───────────────────────────────────────────────────────────────────

  # zh_CN: one decision per step, so each title names THAT decision.
  @doc "The step's heading."
  @spec step_title(atom()) :: String.t()
  def step_title(:provider), do: gettext("Choose a provider")
  def step_title(:auth), do: gettext("Choose authentication")
  def step_title(:model), do: gettext("Pick a model")
  def step_title(:reasoning_schedule), do: gettext("Reasoning & schedule")
  def step_title(:test), do: gettext("Test the connection")
  def step_title(:done), do: gettext("You're all set")
  def step_title(_step), do: gettext("Set up a provider")

  @doc "The step's one-line explanation."
  @spec step_subtitle(atom()) :: String.t()
  def step_subtitle(:provider),
    do: gettext("Where should Genesis send its requests?")

  def step_subtitle(:auth),
    do: gettext("Use an API key, or reuse a vendor subscription login.")

  def step_subtitle(:model),
    do: gettext("This model becomes the account's default.")

  def step_subtitle(:reasoning_schedule),
    do: gettext("Optional: limit the reasoning levels offered and set off-peak slots.")

  def step_subtitle(:test),
    do: gettext("Optional: check that the provider answers before you finish.")

  def step_subtitle(:done),
    do: gettext("Your provider account is saved.")

  def step_subtitle(_step), do: ""

  @doc "The message shown when a step's gate refuses to advance."
  @spec gate_message(term()) :: String.t()
  def gate_message(:missing_provider), do: gettext("Choose a provider before continuing.")
  # zh_CN: 自定义端点必须填写 URL 才能继续
  def gate_message(:missing_base_url), do: gettext("Enter the endpoint URL for this provider.")
  def gate_message(:invalid_auth_mode), do: gettext("Choose a supported authentication mode.")

  def gate_message(:missing_model),
    do: gettext("Pick a model or enter a custom model name.")

  def gate_message(_reason), do: gettext("Complete this step before continuing.")

  @doc "A user-facing message for any failure term (never inspects a bare string)."
  @spec display_error(term()) :: String.t()
  def display_error(reason) when is_binary(reason), do: reason

  def display_error(reason),
    do: gettext("Configuration or connection failed: %{reason}", reason: inspect(reason))

  # ── private ────────────────────────────────────────────────────────────────

  defp find_provider(providers, wanted) do
    Enum.find(List.wrap(providers), fn entry ->
      is_map(entry) and Atom.to_string(entry.id) == wanted
    end)
  end

  defp variants(%{variants: variants}) when is_list(variants), do: variants
  defp variants(_entry), do: []

  defp model(draft, key) do
    case Map.get(ensure_map(draft), key) do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp map_field(draft, key) do
    case Map.get(ensure_map(draft), key) do
      %{} = map -> map
      _value -> %{}
    end
  end

  defp ensure_map(draft) when is_map(draft), do: draft
  defp ensure_map(_draft), do: %{}

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)

  defp clean(value) when is_atom(value) and value not in [true, false],
    do: Atom.to_string(value)

  defp clean(_value), do: ""

  # Provider names retain the existing localized brand labels.
  defp t_provider("Anthropic"), do: gettext("Anthropic")
  # zh_CN: 谷歌
  defp t_provider("Google"), do: gettext("Google")
  # zh_CN: 深度求索
  defp t_provider("DeepSeek"), do: gettext("DeepSeek")
  # zh_CN: 阿里云（通义千问）
  defp t_provider("Alibaba Cloud (Qwen)"), do: gettext("Alibaba Cloud (Qwen)")
  # zh_CN: 智谱（Z.ai）
  defp t_provider("Z.ai (Zhipu AI)"), do: gettext("Z.ai (Zhipu AI)")
  # zh_CN: 稀宇科技
  defp t_provider("MiniMax"), do: gettext("MiniMax")
  # zh_CN: 月之暗面（Kimi）
  defp t_provider("Moonshot AI (Kimi)"), do: gettext("Moonshot AI (Kimi)")
  defp t_provider("xAI"), do: gettext("xAI")
  defp t_provider("OpenRouter"), do: gettext("OpenRouter")
  # zh_CN: OpenAI 兼容 API
  defp t_provider("OpenAI-Compatible API"), do: gettext("OpenAI-Compatible API")
  defp t_provider("OpenAI"), do: gettext("OpenAI")
  defp t_provider(name), do: to_string(name)

  @doc false
  # Exposed for the page's reasoning normalization: the ladder, never `"max"`.
  def reasoning_choices, do: Reasoning.efforts()
end
