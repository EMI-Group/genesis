defmodule EvoDashWeb.SettingsComponents.ProviderWizard.ProviderStep do
  @moduledoc """
  Renderer behind `EvoDashWeb.SettingsComponents.ProviderWizard.step_provider/1`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Identity
  alias EvoDashWeb.SettingsComponents.ProviderWizard.Helpers

  import Helpers, only: [card_class: 1, clean_string: 1, value_of: 2]

  def step_provider(assigns) do
    assigns =
      assigns
      |> assign(:rows, provider_rows(assigns.providers))
      |> assign(:selected_id, clean_string(assigns.selected))
      |> assign(:custom_selected?, clean_string(assigns.selected) == assigns.custom_value)
      |> assign(:base_url_label, assigns.base_url_label || gettext("Endpoint URL"))
      |> assign(
        :base_url_placeholder,
        assigns.base_url_placeholder || "https://api.example.com/v1"
      )

    ~H"""
    <div class="space-y-5">
      <ul class="grid gap-2 sm:grid-cols-2" role="list">
        <li :for={row <- @rows}>
          <button
            type="button"
            phx-click={@provider_event}
            phx-value-provider={row.id}
            aria-pressed={to_string(row.id == @selected_id)}
            aria-current={if row.id == @selected_id, do: "true"}
            class={card_class(row.id == @selected_id)}
          >
            <span class="block text-sm font-semibold text-base-content">{row.label}</span>
            <span :if={row.note} class="mt-1 block text-xs text-base-content/60">{row.note}</span>
          </button>
        </li>
        <li>
          <button
            type="button"
            phx-click={@provider_event}
            phx-value-provider={@custom_value}
            aria-pressed={to_string(@custom_selected?)}
            aria-current={if @custom_selected?, do: "true"}
            class={card_class(@custom_selected?)}
          >
            <span class="block text-sm font-semibold text-base-content">
              {gettext("Custom / OpenAI-compatible endpoint")}
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              {gettext("Any endpoint that speaks the OpenAI chat-completions API.")}
            </span>
          </button>
        </li>
      </ul>

      <div>
        <label
          for={@base_url_name <> "-input"}
          class="mb-1 block text-xs font-medium text-base-content/70"
        >
          {@base_url_label}
        </label>
        <input
          id={@base_url_name <> "-input"}
          type="url"
          name={@base_url_name}
          value={@base_url}
          placeholder={@base_url_placeholder}
          autocomplete="off"
          spellcheck="false"
          class="input input-bordered input-sm w-full rounded-md font-mono text-sm"
        />
        <p class="mt-1 text-xs text-base-content/60">
          {gettext("Required for a custom endpoint; it is pre-filled for catalog providers.")}
        </p>
      </div>
    </div>
    """
  end

  defp provider_rows(providers) when is_list(providers) do
    providers
    |> Enum.map(&provider_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp provider_rows(_providers), do: []

  defp provider_row(%{} = provider) do
    id = value_of(provider, ["id", "value", "provider"])

    case clean_string(id) do
      "" ->
        nil

      id ->
        %{
          id: id,
          label: provider_label(provider, id),
          note: clean_string(value_of(provider, ["note", "description", "subtitle"]))
        }
    end
  end

  defp provider_row(provider) when is_atom(provider) or is_binary(provider) do
    provider_row(%{"id" => provider})
  end

  defp provider_row(_provider), do: nil

  defp provider_label(provider, id) do
    case clean_string(value_of(provider, ["label", "display_name", "name"])) do
      "" -> Identity.provider_display_name(id)
      label -> label
    end
  end
end
