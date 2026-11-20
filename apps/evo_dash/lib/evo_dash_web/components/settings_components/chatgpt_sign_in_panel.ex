defmodule EvoDashWeb.SettingsComponents.ChatGPTSignInPanel do
  @moduledoc """
  The dashboard's ONE Sign in with ChatGPT (SIWC) surface.

  `sign_in_panel/1` renders ONLY the sign-in control — no account select, no
  "ChatGPT connected" line and no connection check. `ProviderWizard.ChatGPTAuth`
  adds those on top of it, and the settings surfaces render this panel alone.

  Two modes, decided by the owning page (it knows whether the dashboard runs on
  the same machine as the execution node):

    * local (`manual: false`) — a primary button starts a real sign-in; while it
      waits the panel shows the authorization link, a waiting line and a Cancel
      button; a failure shows the friendly message from
      `EvoDashWeb.LLMSetup.ChatGPTSignIn.message/1`;
    * remote/unsupported (`manual: true`) — no button: the only route is
      `genesis chatgpt login` on the execution node (or the caller's own
      account-specific `command`), plus the one-line reason.

  Every control is `type="button"`: this panel renders INSIDE the provider
  detail `<form>`, so it must never submit. Both actions carry
  `phx-value-surface` (and `phx-value-profile_id` when one is set), so a page
  can drive several surfaces with one handler pair.

  Anti-replay / surface isolation for the page state itself (`surface_state/2`)
  lives here too: the page owns the state
  (`EvoDashWeb.SettingsLive.ChatGPTSignInState`), this module only interprets it.

  The `sign_in` map is handled TOTALLY: a nil/non-map value is idle, atom- and
  string-keyed maps both work, an unknown/absent phase is `:idle`, and a
  blank/non-binary url is dropped so the panel never renders a broken link.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.ChatGPTSignIn

  @idle %{flow_id: nil, url: nil, phase: :idle, reason: nil}

  attr(:id, :string, required: true)
  attr(:sign_in, :map, default: %{})
  attr(:manual, :boolean, default: false)
  attr(:begin_event, :string, default: "chatgpt_sign_in")
  attr(:cancel_event, :string, default: "chatgpt_sign_in_cancel")
  attr(:surface, :string, required: true)
  attr(:profile_id, :string, default: nil)
  # The exact CLI command a manual (remote/unsupported) surface should show —
  # e.g. an account-specific `genesis chatgpt login --account …`. A nil/blank
  # value falls back to the plain command.
  attr(:command, :string, default: nil)

  @doc """
  Renders the sign-in surface under the given id prefix.

  DOM ids: `#<id>-sign-in`, `#<id>-waiting`, `#<id>-sign-in-url`,
  `#<id>-sign-in-cancel`, `#<id>-sign-in-error`, `#<id>-manual-hint`.
  """
  def sign_in_panel(assigns) do
    sign_in = normalize_sign_in(assigns.sign_in)
    message = if sign_in.phase == :error, do: ChatGPTSignIn.message(sign_in.reason)

    assigns =
      assign(assigns,
        sign_in: sign_in,
        message: message,
        message_tone: tone(message),
        surface: surface_string(assigns.surface),
        login_command: login_command(assigns.command)
      )

    ~H"""
    <%= if @manual do %>
      <div id={@id <> "-manual-hint"} class="space-y-1">
        <p class="text-sm text-base-content/70">
          {gettext("To connect a ChatGPT account, run this command on the execution node.")}
        </p>
        <p><code>{@login_command}</code></p>
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
        phx-click={@begin_event}
        phx-value-surface={@surface}
        phx-value-profile_id={@profile_id}
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
          phx-value-surface={@surface}
          phx-value-profile_id={@profile_id}
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

  @doc """
  The normalized sign-in state for ONE surface — TOTAL, no I/O.

  `surface` is `:wizard`, `{:detail, id}`, `{:status, id}` or `nil`. The page
  state's own `:surface` (atom or string keys) is compared with it, profile ids
  compared as strings, so a surface never renders another surface's flow.

  Answers the normalized `%{flow_id:, url:, phase:, reason:}` when the
  requested surface owns the state (`%{flow_id: nil, url: nil, phase: :idle,
  reason: nil}` when that surface is idle), and `%{}` for a nil/non-map state,
  an absent/unknown surface or a DIFFERENT surface.

  This is the ONE surface-isolation rule: the page state is owned by
  `EvoDashWeb.SettingsLive.ChatGPTSignInState` and this module only interprets
  it (`sign_in_panel/1` renders whatever state its caller resolved).
  """
  @spec surface_state(term(), :wizard | {:detail, term()} | {:status, term()} | nil) ::
          %{
            optional(:flow_id | :url | :phase | :reason) => term()
          }
  def surface_state(sign_in, surface) when is_map(sign_in) do
    if surface_match?(value(sign_in, :surface), surface) do
      case normalize_sign_in(sign_in) do
        %{phase: :idle} -> @idle
        state -> state
      end
    else
      %{}
    end
  end

  def surface_state(_sign_in, _surface), do: %{}

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

  defp normalize_sign_in(_sign_in), do: @idle

  defp surface_string(value) when is_binary(value), do: value
  defp surface_string(_value), do: ""

  # A caller may hand the panel an account-specific command; anything else
  # (nil/blank/non-binary) degrades to the plain login command.
  defp login_command(command) when is_binary(command) do
    if String.trim(command) == "", do: "genesis chatgpt login", else: command
  end

  defp login_command(_command), do: "genesis chatgpt login"

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

  # ── Surface matching ──────────────────────────────────────────────────────

  defp surface_match?(stored, :wizard), do: stored in [:wizard, "wizard"]

  defp surface_match?({stored_kind, stored_id}, {kind, id}) when stored_kind == kind,
    do: same_id?(stored_id, id)

  defp surface_match?(_stored, _surface), do: false

  # Ids compare as strings; an absent/blank id never matches.
  defp same_id?(stored, requested) do
    case {string_id(stored), string_id(requested)} do
      {nil, _id} -> false
      {_id, nil} -> false
      {"", _id} -> false
      {_id, ""} -> false
      {stored_id, requested_id} -> stored_id == requested_id
    end
  end

  defp string_id(id) when is_binary(id), do: id
  defp string_id(id) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
  defp string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp string_id(_id), do: nil
end
