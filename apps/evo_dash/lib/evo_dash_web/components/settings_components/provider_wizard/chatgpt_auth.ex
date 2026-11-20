defmodule EvoDashWeb.SettingsComponents.ProviderWizard.ChatGPTAuth do
  @moduledoc """
  Connects the ChatGPT account picker to an IN-BROWSER sign-in.

  Two modes, decided by the owning page (it knows whether the dashboard runs on
  the same machine as the execution node):

    * local (`manual: false`) — a "Sign in with ChatGPT" button starts a real
      sign-in; while it waits the panel shows the sign-in URL, a waiting line
      and a Cancel button; a failure shows the friendly message from
      `EvoDashWeb.LLMSetup.ChatGPTSignIn.message/1`;
    * remote/unsupported (`manual: true`) — no button: the only route is
      `genesis chatgpt login` on the execution node, plus the one-line reason.

  Both modes keep the connection check. The `sign_in` map is owned by the page
  (`:flow_id`, `:url`, `:phase` — `:idle | :waiting | :ok | :error` — and
  `:reason`); nothing here reads config, the clock or a flow module.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.ChatGPTSignIn
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

  def chatgpt_auth(assigns) do
    account = ChatGPT.account_name(assigns.account)

    options =
      assigns.accounts
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, status} -> {"#{name} · #{status.account_id}", name} end)

    sign_in = normalize_sign_in(assigns.sign_in)
    message = if sign_in.phase == :error, do: ChatGPTSignIn.message(sign_in.reason)

    assigns =
      assign(assigns,
        selected: account,
        options: options,
        connected?: Map.has_key?(assigns.accounts, account),
        sign_in: sign_in,
        message: message,
        message_tone: tone(message)
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

      <%= if @manual do %>
        <div id={@id <> "-manual-hint"} class="space-y-1">
          <p class="text-sm text-base-content/70">
            {gettext("To connect a ChatGPT account, run this command on the execution node.")}
          </p>
          <p><code>genesis chatgpt login</code></p>
          <p class="text-xs text-base-content/60">
            {gettext(
              "The dashboard can only open a sign-in page when it runs on the same machine as the execution node."
            )}
          </p>
        </div>
      <% else %>
        <button
          :if={@sign_in.phase != :waiting}
          id={@id <> "-sign-in"}
          type="button"
          phx-click={@sign_in_event}
          class="btn btn-primary btn-sm"
          phx-disable-with={gettext("Starting…")}
        >
          {gettext("Sign in with ChatGPT")}
        </button>

        <div
          :if={@sign_in.phase == :waiting}
          id={@id <> "-waiting"}
          class="space-y-2 rounded-lg border border-base-300 bg-base-100 px-3 py-2"
        >
          <.sign_in_link :if={@sign_in.url} id={@id <> "-sign-in-url"} url={@sign_in.url} />
          <p role="status" class="flex items-center gap-2 text-xs text-base-content/70">
            <span
              aria-hidden="true"
              class="size-1.5 shrink-0 rounded-full bg-primary motion-safe:animate-pulse"
            ></span>
            {gettext("Waiting for authorization…")}
          </p>
          <%!-- zh_CN: 取消（放弃本次浏览器登录） --%>
          <button
            id={@id <> "-sign-in-cancel"}
            type="button"
            phx-click={@cancel_event}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Cancel")}
          </button>
        </div>

        <p
          :if={@sign_in.phase == :error and @message}
          id={@id <> "-sign-in-error"}
          role="alert"
          class={"text-sm " <> @message_tone}
        >
          {@message.text}
        </p>
      <% end %>

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

  attr(:id, :string, required: true)
  attr(:url, :string, required: true)

  defp sign_in_link(assigns) do
    ~H"""
    <a
      id={@id}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="block break-all text-sm link link-primary"
    >
      {gettext("Open the ChatGPT sign-in page")}
    </a>
    """
  end

  # Total normalization: an unknown/absent phase is `:idle`, and a non-binary
  # url is dropped so the panel never renders a broken link.
  defp normalize_sign_in(sign_in) when is_map(sign_in) do
    %{
      flow_id: value(sign_in, :flow_id),
      url: sign_in_url(value(sign_in, :url)),
      phase: phase(value(sign_in, :phase)),
      reason: value(sign_in, :reason)
    }
  end

  defp normalize_sign_in(_sign_in), do: %{flow_id: nil, url: nil, phase: :idle, reason: nil}

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp sign_in_url(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp sign_in_url(_value), do: nil

  defp phase(:idle), do: :idle
  defp phase(:waiting), do: :waiting
  defp phase(:ok), do: :ok
  defp phase(:error), do: :error
  defp phase("idle"), do: :idle
  defp phase("waiting"), do: :waiting
  defp phase("ok"), do: :ok
  defp phase("error"), do: :error
  defp phase(_value), do: :idle

  defp tone(%{kind: :error}), do: "text-error"
  defp tone(%{kind: :info}), do: "text-base-content/70"
  defp tone(%{kind: :success}), do: "text-success"
  defp tone(_message), do: "text-base-content/70"
end
