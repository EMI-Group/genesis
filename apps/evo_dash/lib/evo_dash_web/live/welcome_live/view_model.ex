defmodule EvoDashWeb.WelcomeLive.ViewModel do
  @moduledoc """
  PURE derivation of `/welcome`'s per-step render assigns from the wizard draft.
  The page (`EvoDashWeb.WelcomeLive`) owns events, persistence and the socket;
  this module turns the page's assigns plus the draft
  (`EvoDashWeb.WelcomeLive.Wizard`) into the exact values the shared step bodies
  (`EvoDashWeb.WelcomeLive.Steps` → `EvoDashWeb.SettingsComponents.ProviderWizard`)
  render — provider/variant rows, the auth modes, the scoped model rows, the
  primary model's reasoning inventory/default, the schedule presets, the holiday
  selector, the schedule summary rows and the done-step summary.
  It owns NO state and NO side effect: no I/O, no process, no clock, no
  `try/rescue`, no `String.to_atom/1`. Catalog entries are TRUSTED server data,
  so a client string is only ever COMPARED with `Atom.to_string/1` and the atom
  handed back is one that already exists in the catalog.
  The step order, the draft's transitions and the reasoning/schedule
  vocabularies are NOT re-implemented here: they belong to
  `EvoDashWeb.LLMSetup.Wizard`, `.Reasoning` and `.Schedule`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias EvoDashWeb.LLMSetup.{Reasoning, Schedule}
  alias EvoDashWeb.WelcomeLive.{Presentation, Setup, Wizard}
  alias EvoGit.Config.LLMCatalog, as: Catalog

  @doc """
  Adds every assign the step bodies read, derived from the draft in `@draft`.
  Total: a missing/unusable draft becomes a fresh one, and every catalog lookup
  degrades to "no selection" rather than raising.
  """
  def prepare_view(assigns) do
    draft = if is_map(assigns.draft), do: assigns.draft, else: Wizard.new()
    provider = Presentation.provider_entry(assigns.llm_providers, draft["provider"])
    provider_id = provider && Map.get(provider, :id)
    variant_id = Presentation.variant_id(provider, draft["variant"])
    capabilities = Wizard.capabilities(draft)
    scoped = Setup.provider_models(assigns.flat_models, provider_id, variant_id)
    wire = Presentation.wire_atom(provider, variant_id)
    primary = draft["default_model"]
    primary_entry = Presentation.model_entry(scoped, primary)

    extra_models =
      draft
      |> Map.get("models")
      |> List.wrap()
      |> Enum.reject(&(&1 == primary))
      |> Enum.map(fn model ->
        entry = Presentation.model_entry(scoped, model)

        %{
          "id" => model,
          "label" => map_field(entry, :model_display_name) || model,
          "efforts" => Wizard.reasoning_choices(map_field(entry, :reasoning_efforts)),
          "default" => model_reasoning_default(draft, model)
        }
      end)

    assigns
    |> assign(:draft, draft)
    |> assign(:provider_options, Presentation.provider_options(assigns.llm_providers))
    |> assign(:variant_options, variant_options(provider, draft))
    |> assign(:auth_modes, Map.get(capabilities, :auth_modes, ["api_key"]))
    |> assign(:oauth_only?, oauth_only?(wire))
    |> assign(:login_instructions, Presentation.login_instructions(wire))
    |> assign(
      :model_rows,
      scoped |> Setup.filtered_models(assigns.search_query) |> Presentation.model_rows()
    )
    |> assign(:all_model_rows, Presentation.model_rows(scoped))
    |> assign(:inventory, Presentation.primary_inventory(draft, primary_entry))
    |> assign(:default_effort, Presentation.primary_effort(draft))
    |> assign(:presets, Presentation.schedule_presets(provider, variant_id))
    |> assign(:preset_applied, Presentation.preset_applied(draft, assigns.preset_dismissed))
    |> assign(:holidays, Wizard.holiday_value(draft))
    |> assign(:holiday_options, Schedule.holiday_options())
    |> assign(:holiday_help, Schedule.holiday_help())
    |> assign(:schedule_rows, Wizard.schedule_rows(draft))
    |> assign(:inventory_name, Reasoning.inventory_input_name())
    |> assign(:default_name, Reasoning.default_input_name())
    |> assign(:extra_models, extra_models)
    |> assign(:summary, Wizard.summary_rows(draft))
    |> assign(:key_present?, key_present?(assigns.credentials, provider))
    |> assign(:key_placeholder, key_placeholder(provider))
  end

  @doc """
  The provider's variant rows with the draft's current variant marked selected.
  """
  def variant_options(provider, draft) do
    Presentation.variant_options(provider, Map.get(ensure_map(draft), "variant"))
  end

  @doc """
  Whether the wizard has already produced a model on disk, i.e. whether the
  page should render its "you're all set" state instead of the wizard.
  """
  def all_set?(:provider, has_model?, wizard_active?), do: has_model? and not wizard_active?

  def all_set?(_step, _has_model?, _wizard_active?), do: false

  @doc "Label of the shell's primary action; `nil` keeps the component default."
  def next_label(:test), do: gettext("Save and finish")
  def next_label(_step), do: nil

  @doc "Whether the provider already has a stored credential."
  def key_present?(credentials, provider) when is_map(credentials) do
    key = map_field(provider, :credential_key)
    not is_nil(key) and Map.get(credentials, key) not in [nil, ""]
  end

  def key_present?(_credentials, _provider), do: false

  @doc "API-key input placeholder naming the selected provider when known."
  def key_placeholder(provider) do
    case map_field(provider, :display_name) do
      name when is_binary(name) and name != "" ->
        gettext("Paste your %{provider} API key", provider: name)

      _other ->
        gettext("Paste your API key")
    end
  end

  @doc "Whether the wire provider supports subscription (OAuth) auth only."
  def oauth_only?(wire) when is_atom(wire) and not is_nil(wire),
    do: Catalog.oauth_only?(wire) == true

  def oauth_only?(_wire), do: false

  # ── Private ──────────────────────────────────────────────────────────────

  defp map_field(map, key) when is_map(map), do: Map.get(map, key)
  defp map_field(_map, _key), do: nil

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_map), do: %{}

  # The ONE unwrap of a recorded `"model_reasoning"` entry lives in `Wizard`, so
  # each extra model's select, the primary select and the persisted row agree.
  defp model_reasoning_default(draft, model), do: Wizard.model_default_effort(draft, model)
end
