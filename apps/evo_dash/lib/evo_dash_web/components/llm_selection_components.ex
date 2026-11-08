defmodule EvoDashWeb.LLMSelectionComponents do
  @moduledoc """
  Shared provider-profile, model and discrete reasoning-effort picker.

  `llm_selection/1` is presentation only: pass canonical `provider_profiles/1`
  and `model_selections/1` projections plus a string-keyed `model_spec`.
  Provider profiles use `"id"`, `"name"` and `"provider"`; selections use the
  schema's atom-keyed projection. No credentials are rendered or fetched.

  The picker is a ChatGPT-style **fused capsule**: a collapsed pill showing
  the current model (`.capsule-main`) and reasoning effort (`.capsule-secondary`)
  side by side plus a chevron, expanding into a two-layer floating panel.
  Layer 1 is the reasoning-effort hero (discrete `.capsule-stop` buttons), and
  its `.capsule-subrow` entry opens Layer 2 (the provider selector nested at
  the top of the `.capsule-list` of models). See
  `components/CONTEXT.md` → "Shared LLM Selection" for the exact CSS-class and
  DOM-id contract.

  The controls need a caller-owned form (never a nested form). Render them
  inside that form, or pass its HTML id as `form` to associate the provider
  `<select>` with it from elsewhere on the page — the provider control is the
  only remaining `phx-change` input, and LiveView input change events require
  a form owner even when `phx-change` is bound directly to the input. Events
  default to `select_provider_profile`, `select_model`, and
  `select_reasoning_effort`; override `provider_event`, `model_event`, and
  `reasoning_event` to reuse the picker on another page. Payload field names
  are `provider_profile_id`, `model`, and `reasoning_effort`, respectively.

  Reasoning effort is selected with discrete buttons (`phx-click` +
  `phx-value-reasoning_effort`) carrying a zero-based INDEX into the selected
  model's ordered `reasoning_efforts`. Call `resolve_reasoning_effort/3` in
  both change and submit handlers to turn that index into a validated string
  BEFORE storing it in `model_spec`. That helper also accepts an
  already-resolved effort string. Provider/model changes must be validated by
  the caller and should clear downstream selections; the component never
  silently picks another model. A missing effort uses the selected model's
  advertised default, or its first supported effort if no valid default
  exists. Unsupported models have no reasoning stops and the caller should
  omit `reasoning_effort` from their spec.

  Supply a unique `id` when multiple pickers appear on a page; the default is
  `"llm-selection"`. `disabled`, `compact`, `class`, and `show_auto_option`
  are optional. Auto is a blank provider selection, leaving task-level model
  rules to the caller; it never becomes a provider-profile id.
  """

  use EvoDashWeb, :html

  attr(:id, :string, default: "llm-selection")
  attr(:form, :string, default: nil)
  attr(:provider_profiles, :list, default: [])
  attr(:model_selections, :list, default: [])
  attr(:model_spec, :map, default: %{})
  attr(:provider_event, :string, default: "select_provider_profile")
  attr(:model_event, :string, default: "select_model")
  attr(:reasoning_event, :string, default: "select_reasoning_effort")
  attr(:disabled, :boolean, default: false)
  attr(:compact, :boolean, default: false)
  attr(:show_auto_option, :boolean, default: false)
  attr(:class, :string, default: nil)

  def llm_selection(assigns) do
    spec = assigns.model_spec || %{}
    provider_id = spec_value(spec, "provider_profile_id")
    model = spec_value(spec, "model")
    models = models_for(assigns.model_selections, provider_id)
    selection = Enum.find(models, &(&1.model == model))
    efforts = efforts_for(selection)
    effort = selected_effort(spec, selection, efforts)
    known_provider? = Enum.any?(assigns.provider_profiles, &(profile_id(&1) == provider_id))
    known_model? = not is_nil(selection)

    model_label =
      model_trigger_label(%{
        selected_model: model,
        known_model?: known_model?,
        provider_id: provider_id,
        provider_profiles: assigns.provider_profiles,
        show_auto_option: assigns.show_auto_option
      })

    assigns =
      assigns
      |> assign(:provider_id, provider_id)
      |> assign(:selected_model, model)
      |> assign(:available_models, models)
      |> assign(:efforts, efforts)
      |> assign(:effort, effort)
      |> assign(:effort_index, Enum.find_index(efforts, &(&1 == effort)) || 0)
      |> assign(:known_provider?, known_provider?)
      |> assign(:known_model?, known_model?)
      |> assign(:model_label, model_label)

    ~H"""
    <details
      id={@id}
      class={[
        "capsule dropdown dropdown-top min-w-0 shrink-0",
        @disabled && "pointer-events-none opacity-60",
        @class
      ]}
    >
      <summary
        class="capsule-trigger flex items-center gap-1.5 rounded-full border border-base-300 bg-base-100 px-3 py-1.5 text-sm cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden"
        title={@model_label}
      >
        <span class="capsule-main min-w-0 truncate font-medium text-base-content">
          {@model_label}
        </span>
        <span
          :if={@efforts != []}
          id={@id <> "-reasoning-value"}
          class="capsule-secondary shrink-0 text-xs text-base-content/60"
        >
          {effort_label(@effort)}
        </span>
        <span class="capsule-chevron shrink-0 text-base-content/50" aria-hidden="true">
          <.icon name="hero-chevron-down" class="size-3.5" />
        </span>
      </summary>

      <div class="capsule-panel dropdown-content z-50 mb-2 w-72 rounded-2xl border border-base-300 bg-base-100 p-2 shadow-lg">
        <%!-- Layer 1: reasoning-effort hero (discrete stops) --%>
        <div
          :if={@efforts != []}
          id={@id <> "-reasoning"}
          class="capsule-stops flex flex-wrap gap-1"
          role="group"
          aria-label={gettext("Reasoning effort")}
        >
          <button
            :for={{effort, index} <- Enum.with_index(@efforts)}
            type="button"
            phx-click={@reasoning_event}
            phx-value-reasoning_effort={index}
            aria-pressed={to_string(effort == @effort)}
            disabled={@disabled or length(@efforts) == 1}
            class={[
              "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium",
              effort == @effort && "capsule-stop-active"
            ]}
          >
            {effort_label(effort)}
          </button>
        </div>

        <%!-- Layer-1 → Layer-2 entry: current model name + right arrow --%>
        <details class="capsule-sub">
          <summary class="capsule-subrow flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm cursor-pointer select-none list-none hover:bg-base-200 [&::-webkit-details-marker]:hidden">
            <span class="capsule-subrow-label min-w-0 flex-1 truncate text-base-content/80">
              {@model_label}
            </span>
            <span class="capsule-subrow-arrow shrink-0 text-base-content/50" aria-hidden="true">
              <.icon name="hero-chevron-right" class="size-4" />
            </span>
          </summary>

          <div class="capsule-list-panel">
            <%!-- Provider selector nested at the top of the model list --%>
            <div class="capsule-provider px-1 pt-1">
              <label
                for={@id <> "-provider"}
                class="mb-1 flex items-center gap-1.5 text-xs font-medium text-base-content/70"
              >
                <.icon name="hero-server-stack" class="size-3.5" />
                <%!-- zh_CN: 提供商配置包含连接和认证设置，不是单纯的厂商名称。 --%>
                {gettext("Provider profile")}
              </label>
              <select
                id={@id <> "-provider"}
                name="provider_profile_id"
                form={@form}
                phx-change={@provider_event}
                aria-invalid={if(@provider_id != "" and not @known_provider?, do: "true")}
                disabled={@disabled or @provider_profiles == []}
                class="select select-sm w-full min-w-0 truncate rounded-lg border-base-300 bg-base-100 focus-visible:outline-primary-standalone"
                aria-describedby={if(@provider_profiles == [], do: @id <> "-empty")}
              >
                <option value="" selected={@provider_id == ""}>
                  {if @show_auto_option,
                    do: gettext("Auto (by rules)"),
                    else: gettext("Choose a provider profile")}
                </option>
                <option
                  :if={@provider_id != "" and not @known_provider?}
                  value={@provider_id}
                  selected
                  disabled
                >
                  {gettext("Unavailable profile: %{profile}", profile: @provider_id)}
                </option>
                <option
                  :for={profile <- @provider_profiles}
                  value={profile_id(profile)}
                  selected={profile_id(profile) == @provider_id}
                >
                  {profile_label(profile)}
                </option>
              </select>
            </div>

            <div
              id={@id <> "-model"}
              class="capsule-list mt-1 space-y-0.5"
              role="listbox"
              aria-label={gettext("Model")}
              aria-describedby={
                if(@provider_id != "" and @known_provider? and @available_models == [],
                  do: @id <> "-model-empty"
                )
              }
            >
              <%!-- Leading blank / clear option (mirrors the old select's
                   first option): text depends on whether a provider is chosen. --%>
              <button
                type="button"
                role="option"
                phx-click={@model_event}
                phx-value-model=""
                aria-selected={to_string(@selected_model == "")}
                disabled={@disabled or @available_models == []}
                class={[
                  "capsule-item flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left",
                  @selected_model == "" && "capsule-item-active"
                ]}
              >
                <span class="capsule-item-label min-w-0 flex-1 truncate">
                  {if @provider_id == "",
                    do: gettext("Choose a provider first"),
                    else: gettext("Choose a model")}
                </span>
                <span
                  :if={@selected_model == ""}
                  class="capsule-item-check shrink-0 text-primary-standalone"
                  aria-hidden="true"
                >
                  <.icon name="hero-check" class="size-4" />
                </span>
              </button>

              <%!-- Stale/unavailable model — preserved, selected and disabled --%>
              <button
                :if={@selected_model != "" and not @known_model?}
                type="button"
                role="option"
                disabled
                aria-invalid="true"
                class="capsule-item capsule-item-placeholder flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left text-base-content/60"
              >
                <span class="capsule-item-label min-w-0 flex-1 truncate">
                  {gettext("Unavailable model: %{model}", model: @selected_model)}
                </span>
              </button>

              <button
                :for={selection <- @available_models}
                type="button"
                role="option"
                phx-click={@model_event}
                phx-value-model={selection.model}
                aria-selected={to_string(selection.model == @selected_model)}
                disabled={@disabled}
                class={[
                  "capsule-item flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left",
                  selection.model == @selected_model && "capsule-item-active"
                ]}
              >
                <span class="capsule-item-label min-w-0 flex-1 truncate">
                  {selection.model}
                </span>
                <span
                  :if={selection.model == @selected_model}
                  class="capsule-item-check shrink-0 text-primary-standalone"
                  aria-hidden="true"
                >
                  <.icon name="hero-check" class="size-4" />
                </span>
              </button>
            </div>

            <p
              :if={@provider_profiles == []}
              id={@id <> "-empty"}
              class="px-1 pt-2 text-xs text-base-content/70"
            >
              {gettext("No provider profiles configured. Add one in Settings to choose a model.")}
            </p>
            <p
              :if={@provider_id != "" and @known_provider? and @available_models == []}
              id={@id <> "-model-empty"}
              class="px-1 pt-2 text-xs text-base-content/70"
            >
              {gettext("No models are available for this provider profile.")}
            </p>
          </div>
        </details>
      </div>
    </details>
    """
  end

  @doc """
  Converts a reasoning-effort button index (integer or decimal string) or an
  effort string to `{:ok, effort}` for the exact provider/model in `model_spec`.
  Returns `{:error, :unsupported_reasoning_effort}` for a stale model, an
  unsupported effort, a malformed index or an out-of-range value.
  """
  def resolve_reasoning_effort(model_selections, model_spec, value) do
    selection =
      model_selections
      |> models_for(spec_value(model_spec, "provider_profile_id"))
      |> Enum.find(&(&1.model == spec_value(model_spec, "model")))

    efforts = efforts_for(selection)

    effort =
      cond do
        is_binary(value) and value in efforts -> value
        is_integer(value) and value >= 0 -> Enum.at(efforts, value)
        is_binary(value) -> effort_at(efforts, Integer.parse(value))
        true -> nil
      end

    if effort, do: {:ok, effort}, else: {:error, :unsupported_reasoning_effort}
  end

  defp effort_at(efforts, {index, ""}) when index >= 0, do: Enum.at(efforts, index)
  defp effort_at(_efforts, _index), do: nil

  defp models_for(selections, provider_id) do
    Enum.filter(selections, &(&1.provider_profile_id == provider_id and provider_id != ""))
  end

  defp efforts_for(nil), do: []
  defp efforts_for(selection), do: Map.get(selection, :reasoning_efforts, []) || []

  defp selected_effort(spec, selection, efforts) do
    requested = spec_value(spec, "reasoning_effort")
    default = if selection, do: Map.get(selection, :default_reasoning_effort)

    cond do
      requested in efforts -> requested
      default in efforts -> default
      true -> List.first(efforts)
    end
  end

  defp spec_value(spec, key) when is_map(spec), do: Map.get(spec, key) || ""
  defp spec_value(_, _key), do: ""

  defp profile_id(profile), do: Map.get(profile, "id", "")

  defp profile_label(profile) do
    name = Map.get(profile, "name")
    if name in [nil, ""], do: profile_id(profile), else: name
  end

  # Collapsed-pill + Layer-1→Layer-2 entry label for the current model. A
  # stale persisted model stays visible as "Unavailable model: …"; otherwise
  # the placeholder mirrors the old model select's leading option.
  defp model_trigger_label(%{
         selected_model: model,
         known_model?: known,
         provider_id: provider_id,
         provider_profiles: profiles,
         show_auto_option: show_auto
       }) do
    cond do
      model != "" and known ->
        model

      model != "" ->
        gettext("Unavailable model: %{model}", model: model)

      profiles == [] ->
        gettext("Choose a model")

      provider_id == "" and show_auto ->
        gettext("Auto (by rules)")

      provider_id == "" ->
        gettext("Choose a provider first")

      true ->
        gettext("Choose a model")
    end
  end

  defp effort_label("none"), do: gettext("None")
  defp effort_label("minimal"), do: gettext("Minimal")
  defp effort_label("low"), do: gettext("Low")
  defp effort_label("medium"), do: gettext("Medium")
  defp effort_label("high"), do: gettext("High")
  defp effort_label("xhigh"), do: gettext("Extra high")
  defp effort_label("default"), do: gettext("Default")
  defp effort_label(value), do: value
end
