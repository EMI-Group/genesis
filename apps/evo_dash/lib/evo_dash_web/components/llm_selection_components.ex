defmodule EvoDashWeb.LLMSelectionComponents do
  @moduledoc """
  Shared provider-profile, model and discrete reasoning-effort picker.

  `llm_selection/1` is presentation only: pass canonical `provider_profiles/1`
  and `model_selections/1` projections plus a string-keyed `model_spec`.
  Provider profiles use `"id"`, `"name"` and `"provider"`; selections use the
  schema's atom-keyed projection. No credentials are rendered or fetched.

  The controls need a caller-owned form (never a nested form). Render them
  inside that form, or pass its HTML id as `form` to associate every control
  with it from elsewhere on the page. LiveView input change events require a
  form owner even when `phx-change` is bound directly to the input. Events
  default to `select_provider_profile`, `select_model`, and
  `select_reasoning_effort`; override `provider_event`, `model_event`, and
  `reasoning_event` to reuse the picker on another page. Payload field names
  are `provider_profile_id`, `model`, and `reasoning_effort`, respectively.

  A native range only supports numeric values, so `reasoning_effort` carries
  a zero-based INDEX into the selected model's ordered `reasoning_efforts`.
  Call `resolve_reasoning_effort/3` in both change and submit handlers to turn
  that index into a validated string BEFORE storing it in `model_spec`.
  That helper also accepts an already-resolved effort string.
  Provider/model changes must be validated by the caller and should clear
  downstream selections; the component never silently picks another model.
  A missing effort uses the selected model's advertised default, or its first
  supported effort if no valid default exists. Unsupported models have no
  slider and the caller should omit `reasoning_effort` from their spec.

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

    assigns =
      assigns
      |> assign(:provider_id, provider_id)
      |> assign(:selected_model, model)
      |> assign(:available_models, models)
      |> assign(:efforts, efforts)
      |> assign(:effort, effort)
      |> assign(:effort_index, Enum.find_index(efforts, &(&1 == effort)) || 0)
      |> assign(
        :known_provider?,
        Enum.any?(assigns.provider_profiles, &(profile_id(&1) == provider_id))
      )
      |> assign(:known_model?, not is_nil(selection))

    ~H"""
    <fieldset
      id={@id}
      disabled={@disabled}
      class={[
        "min-w-0 shrink-0 rounded-lg border border-base-300 bg-base-200/40",
        if(@compact, do: "p-3", else: "p-4"),
        @class
      ]}
    >
      <legend class="sr-only">{gettext("Language model selection")}</legend>
      <div class={[
        "grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2",
        @efforts != [] && "lg:grid-cols-3"
      ]}>
        <div class="min-w-0">
          <label
            for={@id <> "-provider"}
            class="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-base-content/70"
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

        <div class="min-w-0">
          <label
            for={@id <> "-model"}
            class="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-base-content/70"
          >
            <.icon name="hero-cpu-chip" class="size-3.5" />
            {gettext("Model")}
          </label>
          <select
            id={@id <> "-model"}
            name="model"
            form={@form}
            phx-change={@model_event}
            title={@selected_model}
            aria-invalid={if(@selected_model != "" and not @known_model?, do: "true")}
            aria-describedby={
              if(@provider_id != "" and @known_provider? and @available_models == [],
                do: @id <> "-model-empty"
              )
            }
            disabled={@disabled or @available_models == []}
            class="select select-sm w-full min-w-0 truncate rounded-lg border-base-300 bg-base-100 focus-visible:outline-primary-standalone"
          >
            <option value="" selected={@selected_model == ""}>
              {if @provider_id == "",
                do: gettext("Choose a provider first"),
                else: gettext("Choose a model")}
            </option>
            <option
              :if={@selected_model != "" and not @known_model?}
              value={@selected_model}
              selected
              disabled
            >
              {gettext("Unavailable model: %{model}", model: @selected_model)}
            </option>
            <option
              :for={selection <- @available_models}
              value={selection.model}
              selected={selection.model == @selected_model}
            >
              {selection.model}
            </option>
          </select>
        </div>

        <div :if={@efforts != []} class="min-w-0 sm:col-span-2 lg:col-span-1">
          <div class="mb-1.5 flex items-center justify-between gap-2 text-xs">
            <label
              for={@id <> "-reasoning"}
              class="flex items-center gap-1.5 font-medium text-base-content/70"
            >
              <.icon name="hero-adjustments-horizontal" class="size-3.5" />
              <%!-- zh_CN: 模型推理强度，与任务的速度/质量策略是两个独立选项。 --%>
              {gettext("Reasoning effort")}
            </label>
            <output
              id={@id <> "-reasoning-value"}
              for={@id <> "-reasoning"}
              class="min-w-0 max-w-[50%] rounded-md bg-primary/10 px-1.5 py-0.5 text-right font-medium wrap-break-word text-primary-standalone"
            >
              {effort_label(@effort)}
            </output>
          </div>
          <input
            id={@id <> "-reasoning"}
            type="range"
            name="reasoning_effort"
            form={@form}
            min="0"
            max={length(@efforts) - 1}
            step="1"
            value={@effort_index}
            list={@id <> "-reasoning-ticks"}
            phx-change={@reasoning_event}
            disabled={@disabled or length(@efforts) == 1}
            aria-valuetext={effort_label(@effort)}
            aria-describedby={@id <> "-reasoning-help"}
            class="range range-primary range-xs mt-2 w-full focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary-standalone"
          />
          <datalist id={@id <> "-reasoning-ticks"}>
            <option
              :for={{effort, index} <- Enum.with_index(@efforts)}
              value={index}
              label={effort_label(effort)}
            />
          </datalist>
          <div class="mt-1 flex justify-between gap-2 text-xs text-base-content/70" aria-hidden="true">
            <span>{effort_label(List.first(@efforts))}</span>
            <span :if={length(@efforts) > 1}>{effort_label(List.last(@efforts))}</span>
          </div>
          <p id={@id <> "-reasoning-help"} class="sr-only">
            {gettext(
              "Use the arrow keys to select a supported reasoning level. This is independent of task quality."
            )}
          </p>
        </div>
      </div>
      <p :if={@provider_profiles == []} id={@id <> "-empty"} class="mt-3 text-xs text-base-content/70">
        {gettext("No provider profiles configured. Add one in Settings to choose a model.")}
      </p>
      <p
        :if={@provider_id != "" and @known_provider? and @available_models == []}
        id={@id <> "-model-empty"}
        class="mt-3 text-xs text-base-content/70"
      >
        {gettext("No models are available for this provider profile.")}
      </p>
    </fieldset>
    """
  end

  @doc """
  Converts a range index (integer or decimal string) or an effort string to
  `{:ok, effort}` for the exact provider/model in `model_spec`.
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

  defp effort_label("none"), do: gettext("None")
  defp effort_label("minimal"), do: gettext("Minimal")
  defp effort_label("low"), do: gettext("Low")
  defp effort_label("medium"), do: gettext("Medium")
  defp effort_label("high"), do: gettext("High")
  defp effort_label("xhigh"), do: gettext("Extra high")
  defp effort_label("default"), do: gettext("Default")
  defp effort_label(value), do: value
end
