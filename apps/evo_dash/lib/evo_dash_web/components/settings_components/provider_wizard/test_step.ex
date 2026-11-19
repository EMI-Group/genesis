defmodule EvoDashWeb.SettingsComponents.ProviderWizard.TestStep do
  @moduledoc """
  Renderer behind `EvoDashWeb.SettingsComponents.ProviderWizard.step_test/1`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.SettingsComponents.ProviderWizard.Helpers

  import Helpers, only: [clean_string: 1, format_reason: 1]

  def step_test(assigns) do
    assigns =
      assigns
      |> assign(:test_label, assigns.test_label || gettext("Test connection"))
      |> assign(:skip_label, assigns.skip_label || gettext("Skip for now"))
      |> assign(:testing?, assigns.test_state == :testing)
      |> assign(:ok_detail, test_ok_detail(assigns.test_state))
      |> assign(:error_detail, test_error_detail(assigns.test_state))

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Check that Genesis can reach the provider with the credentials you just entered. Skipping is fine — a wrong key surfaces on the first task instead."
        )}
      </p>

      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click={@test_event}
          class="btn btn-primary btn-sm"
          disabled={@testing?}
        >
          <.icon name="hero-bolt" class={if(@testing?, do: "size-4 animate-spin", else: "size-4")} />
          {@test_label}
        </button>
        <button type="button" phx-click={@skip_event} class="btn btn-ghost btn-sm">{@skip_label}</button>
      </div>

      <p
        :if={@testing?}
        class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/70"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin" />
        {gettext("Testing the connection…")}
      </p>

      <p
        :if={@ok_detail}
        class="flex items-start gap-2 rounded-lg border border-success/30 bg-success/10 px-3 py-2 text-sm text-success"
      >
        <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0" />
        <span class="min-w-0">
          {gettext("Connection succeeded.")}
          <span :if={@ok_detail != ""} class="block text-xs text-success/80">{@ok_detail}</span>
        </span>
      </p>

      <p
        :if={@error_detail}
        class="flex items-start gap-2 rounded-lg border border-error/30 bg-error/10 px-3 py-2 text-sm text-error"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
        <span class="min-w-0">
          {gettext("Connection failed.")}
          <span class="block text-xs text-error/80">{@error_detail}</span>
        </span>
      </p>
    </div>
    """
  end

  # A success with no usable detail still renders the success box — a blank
  # detail only drops the detail SPAN, so `{:ok, nil}` / `{:ok, ""}` read like a
  # plain `:ok` instead of hiding the whole box.
  defp test_ok_detail({:ok, detail}), do: clean_string(detail) || ""
  defp test_ok_detail(:ok), do: ""

  defp test_ok_detail(%{status: status} = result) when status in [:ok, "ok"],
    do: clean_string(Map.get(result, :detail) || Map.get(result, "detail")) || ""

  defp test_ok_detail(_state), do: nil

  defp test_error_detail({:error, reason}), do: format_reason(reason)
  defp test_error_detail(_state), do: nil
end
