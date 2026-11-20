defmodule EvoDashWeb.SettingsComponents.ProviderWizard.ChatGPTAuth do
  @moduledoc "Connects the account picker to the terminal-based ChatGPT sign-in."

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.ChatGPT

  attr(:id, :string, required: true)
  attr(:account, :string, default: nil)
  attr(:accounts, :map, default: %{})
  attr(:change_event, :string, required: true)
  attr(:refresh_event, :string, required: true)

  def chatgpt_auth(assigns) do
    account = ChatGPT.account_name(assigns.account)

    options =
      assigns.accounts
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, status} -> {"#{name} · #{status.account_id}", name} end)

    assigns =
      assign(assigns,
        selected: account,
        options: options,
        connected?: Map.has_key?(assigns.accounts, account)
      )

    ~H"""
    <div class="space-y-3">
      <form :if={@options != []} id={@id <> "-form"} phx-change={@change_event}>
        <.input
          type="select"
          id={@id <> "-account"}
          name="siwc_account"
          label={gettext("ChatGPT account")}
          options={@options}
          prompt={gettext("Choose a connected account")}
          value={@selected}
        />
      </form>
      <p :if={@connected?} role="status" class="text-sm text-success">
        {gettext("ChatGPT connected")}
      </p>
      <p class="text-sm text-base-content/70">
        {gettext("To connect a ChatGPT account, run this command on the execution node.")}
      </p>
      <p><code>genesis chatgpt login</code></p>
      <button
        id={@id <> "-refresh"}
        type="button"
        phx-click={@refresh_event}
        phx-value-refresh_chatgpt="true"
        class="btn btn-outline btn-sm"
        phx-disable-with={gettext("Checking…")}
      >
        {gettext("Check connection")}
      </button>
    </div>
    """
  end
end
