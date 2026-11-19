defmodule EvoDashWeb.SettingsComponents.ProviderWizard.ModelStep do
  @moduledoc """
  Renderer behind `EvoDashWeb.SettingsComponents.ProviderWizard.step_model/1`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.SettingsComponents.ProviderWizard.Helpers

  import Helpers, only: [clean_string: 1, label_or_id: 2, value_of: 2]

  def step_model(assigns) do
    assigns =
      assigns
      |> assign(:rows, model_rows(assigns.models))
      |> assign(:selected_id, clean_string(assigns.selected))
      |> assign(:query_value, clean_string(assigns.query))
      |> assign(
        :custom_model_value,
        assigns.custom_model_value || gettext("Use a custom model name")
      )

    ~H"""
    <div class="space-y-4">
      <form
        id="wizard-model-search"
        phx-change={@model_search_event}
        phx-submit={@model_search_event}
        class="relative"
      >
        <label for="wizard-model-search-input" class="sr-only">{gettext("Search models")}</label>
        <input
          id="wizard-model-search-input"
          type="search"
          name={@search_name}
          value={@query}
          placeholder={gettext("Search models")}
          autocomplete="off"
          class="input input-bordered input-sm w-full rounded-md pl-9"
        />
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
        />
      </form>

      <ul
        :if={@rows != []}
        class="max-h-72 space-y-1 overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-2"
        role="list"
      >
        <li :for={row <- @rows}>
          <button
            type="button"
            phx-click={@model_event}
            phx-value-model={row.id}
            aria-current={if row.id == @selected_id, do: "true"}
            class={model_row_class(row.id == @selected_id)}
          >
            <span class="min-w-0">
              <span class="block truncate text-sm font-medium text-base-content">{row.label}</span>
              <span
                :if={row.label != row.id}
                class="block truncate font-mono text-xs text-base-content/50"
              >
                {row.id}
              </span>
            </span>
            <span :if={row.variant} class="badge badge-ghost badge-sm shrink-0">{row.variant}</span>
          </button>
        </li>
      </ul>

      <p
        :if={@rows == []}
        class="rounded-lg border border-dashed border-base-300 px-3 py-6 text-center text-sm text-base-content/60"
      >
        {gettext("No catalog model matches this search. Enter the model name below.")}
      </p>

      <.custom_model_field
        event={@custom_model_event}
        name={@custom_model_name}
        value={@custom_model}
        label={@custom_model_value}
      />
    </div>
    """
  end

  attr(:event, :string, default: nil)
  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:label, :string, required: true)

  defp custom_model_field(%{event: nil} = assigns) do
    ~H"""
    <.custom_model_input name={@name} value={@value} label={@label} />
    """
  end

  defp custom_model_field(assigns) do
    ~H"""
    <form id="wizard-custom-model-form" phx-change={@event} phx-submit={@event}>
      <.custom_model_input name={@name} value={@value} label={@label} />
    </form>
    """
  end

  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:label, :string, required: true)

  defp custom_model_input(assigns) do
    ~H"""
    <div>
      <label for={@name <> "-input"} class="mb-1 block text-xs font-medium text-base-content/70">
        {@label}
      </label>
      <input
        id={@name <> "-input"}
        type="text"
        name={@name}
        value={@value}
        autocomplete="off"
        spellcheck="false"
        placeholder={gettext("model-name-as-the-api-expects-it")}
        class="input input-bordered input-sm w-full rounded-md font-mono text-sm"
      />
      <p class="mt-1 text-xs text-base-content/60">
        {gettext("For an unreleased or self-hosted model that is not in the catalog.")}
      </p>
    </div>
    """
  end

  defp model_rows(models) when is_list(models) do
    models
    |> Enum.map(&model_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp model_rows(_models), do: []

  defp model_row(%{} = model) do
    id = clean_string(value_of(model, ["id", "model", "value"]))

    case id do
      "" ->
        nil

      id ->
        %{
          id: id,
          label: label_or_id(value_of(model, ["label", "display_name", "name"]), id),
          variant: clean_string(value_of(model, ["variant", "variant_label", "variant_id"]))
        }
    end
  end

  defp model_row(model) when is_binary(model), do: %{id: model, label: model, variant: nil}
  defp model_row(_model), do: nil

  defp model_row_class(true) do
    "flex w-full items-center justify-between gap-2 rounded-md border border-primary bg-primary/5 px-3 py-2 text-left transition hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end

  defp model_row_class(_selected?) do
    "flex w-full items-center justify-between gap-2 rounded-md border border-transparent px-3 py-2 text-left transition hover:border-base-300 hover:bg-base-200/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end
end
