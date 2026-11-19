defmodule EvoDashWeb.SettingsComponents.ProviderWizard.AuthStep do
  @moduledoc """
  Renderer behind `EvoDashWeb.SettingsComponents.ProviderWizard.step_auth/1`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.SettingsComponents.ProviderWizard.Helpers

  import Helpers, only: [card_class: 1]

  def step_auth(assigns) do
    assigns =
      assigns
      |> assign(:selected_mode, normalize_auth_mode(assigns.selected))
      |> assign(:available_modes, available_auth_modes(assigns))

    ~H"""
    <div class="space-y-4">
      <p
        :if={@oauth_only}
        class="rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/80"
      >
        {gettext(
          "This provider only accepts a subscription login, so API-key authentication is not offered."
        )}
      </p>

      <ul class="grid gap-2 sm:grid-cols-2" role="list">
        <li :if={"api_key" in @available_modes}>
          <button
            type="button"
            phx-click={@auth_event}
            phx-value-mode="api_key"
            aria-pressed={to_string(@selected_mode == "api_key")}
            aria-current={if @selected_mode == "api_key", do: "true"}
            class={card_class(@selected_mode == "api_key")}
          >
            <span class="block text-sm font-semibold text-base-content">{gettext("API key")}</span>
            <span class="mt-1 block text-xs text-base-content/60">
              {gettext("Bill the provider directly with a key stored in your credentials file.")}
            </span>
          </button>
        </li>
        <li :if={"oauth" in @available_modes}>
          <button
            type="button"
            phx-click={@auth_event}
            phx-value-mode="oauth"
            aria-pressed={to_string(@selected_mode == "oauth")}
            aria-current={if @selected_mode == "oauth", do: "true"}
            class={card_class(@selected_mode == "oauth")}
          >
            <span class="block text-sm font-semibold text-base-content">
              {gettext("Subscription")}
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              {gettext(
                "Reuse a vendor CLI login (Codex / Claude) instead of an API key. Genesis never runs the OAuth flow itself."
              )}
            </span>
          </button>
        </li>
      </ul>

      {render_slot(@auth_detail)}
    </div>
    """
  end

  defp available_auth_modes(assigns) do
    modes =
      assigns.modes
      |> List.wrap()
      |> Enum.map(&normalize_auth_mode/1)
      |> Enum.filter(&(&1 in ["api_key", "oauth"]))

    modes =
      case modes do
        [] -> ["api_key"]
        modes -> Enum.uniq(modes)
      end

    if assigns.oauth_only do
      Enum.uniq(["oauth" | Enum.reject(modes, &(&1 == "api_key"))])
    else
      modes
    end
  end

  defp normalize_auth_mode(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp normalize_auth_mode(value) when is_atom(value) and value not in [nil, true, false],
    do: value |> Atom.to_string() |> normalize_auth_mode()

  defp normalize_auth_mode(_value), do: ""
end
