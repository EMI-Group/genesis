defmodule EvoDashWeb.SettingsComponents.ProviderWizard.ChatGPTAuth do
  @moduledoc """
  Connects the ChatGPT account picker to an IN-BROWSER sign-in.

  This control is the ACCOUNT part of the auth step — the `siwc_account` select,
  the "ChatGPT connected" line and the "Check connection" action — wrapped
  around the shared `EvoDashWeb.SettingsComponents.ChatGPTSignInPanel`, which is
  the ONE sign-in surface (button / waiting block / CLI hint / failure message,
  see its moduledoc). Two modes, decided by the owning page (it knows whether
  the dashboard runs on the same machine as the execution node):

    * local (`manual: false`) — a "Sign in with ChatGPT" button starts a real
      sign-in and the panel reports waiting/failure;
    * remote/unsupported (`manual: true`) — no button: the only route is
      `genesis chatgpt login` on the execution node, plus the one-line reason.

  The `sign_in` map is owned by the page (`:flow_id`, `:url`, `:phase` —
  `:idle | :waiting | :ok | :error` — and `:reason`); nothing here reads config,
  the clock or a flow module.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.SettingsComponents.ChatGPTSignInPanel
  alias EvoDashWeb.LLMSetup.ChatGPT

  attr(:id, :string, required: true)
  attr(:account, :string, default: nil)
  attr(:accounts, :map, default: %{})
  attr(:change_event, :string, required: true)
  attr(:refresh_event, :string, required: true)
  attr(:sign_in_event, :string, default: "chatgpt_sign_in")
  attr(:cancel_event, :string, default: "chatgpt_sign_in_cancel")
  attr(:sign_in, :map, default: %{})
  attr(:manual, :boolean, default: false)
  attr(:surface, :string, default: "wizard")
  attr(:profile_id, :string, default: nil)

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

      <ChatGPTSignInPanel.sign_in_panel
        id={@id}
        sign_in={@sign_in}
        manual={@manual}
        begin_event={@sign_in_event}
        cancel_event={@cancel_event}
        surface={@surface}
        profile_id={@profile_id}
      />

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
