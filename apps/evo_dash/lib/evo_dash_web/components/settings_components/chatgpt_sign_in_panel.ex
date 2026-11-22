defmodule EvoDashWeb.SettingsComponents.ChatGPTSignInPanel do
  @moduledoc """
  The dashboard's ONE Sign in with ChatGPT (SIWC) surface.

  `sign_in_panel/1` renders ONLY the sign-in control — no account select, no
  "ChatGPT connected" line and no connection check. `ProviderWizard.ChatGPTAuth`
  adds those on top of it, and the settings surfaces render this panel alone.

  Two modes, decided by the owning page (it knows whether the dashboard runs on
  the same machine as the execution node):

    * local (`manual: false`) — a primary button starts a real sign-in; while it
      waits the panel shows the authorization link, a waiting line, a Cancel
      button and an ALWAYS-PRESENT "Can't reach this page?" disclosure that
      hands a pasted redirect URL (or bare code) back to the same attempt; a
      failure shows the friendly message from
      `EvoDashWeb.LLMSetup.ChatGPTSignIn.message/1`;
    * remote/unsupported (`manual: true`) — no button: the only route is
      `genesis chatgpt login` on the execution node (or the caller's own
      account-specific `command`, which also accepts a pasted redirect URL),
      plus the one-line reason.

  The paste disclosure is NOT conditional on a remote verdict: the common
  remote-dashboard case views the LOCAL node, so the browser is redirected to
  its own loopback and cannot reach the flow's listener even though the page is
  not "manual". Explaining the expected redirect address (from the flow's
  `port`) is the only way that user learns what to copy.

  Every control is `type="button"` and the paste input uses `phx-change`, never
  a nested form: this panel renders INSIDE the provider detail `<form>`, so it
  must never submit itself. Both actions carry `phx-value-surface` (and
  `phx-value-profile_id` when one is set), so a page can drive several surfaces
  with one handler pair.
  That input is an INPUT-level `phx-change`, so its real payload carries ONLY
  the input's own field (`%{"paste" => text, "_target" => "paste"}` — LiveView
  reads `phx-value-*` from the FORM, never the input) and a page must read
  `"paste"`, not `"value"`; pressing Enter in it still triggers the enclosing
  form's implicit submit, which is harmless only because the provider draft
  boundary drops the `paste` key.

  Anti-replay / surface isolation for the page state itself (`surface_state/2`)
  lives here too: the page owns the state
  (`EvoDashWeb.SettingsLive.ChatGPTSignInState`), this module only interprets it.

  The `sign_in` map is handled TOTALLY: a nil/non-map value is idle, atom- and
  string-keyed maps both work, an unknown/absent phase is `:idle`, a
  blank/non-binary url is dropped so the panel never renders a broken link, and
  `port`/`mode`/`paste`/`paste_error` degrade to `nil`/`nil`/`""`/`nil`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.ChatGPTSignIn

  @idle %{
    flow_id: nil,
    url: nil,
    phase: :idle,
    reason: nil,
    port: nil,
    mode: nil,
    paste: "",
    paste_error: nil
  }

  attr(:id, :string, required: true)
  attr(:sign_in, :map, default: %{})
  attr(:manual, :boolean, default: false)
  attr(:begin_event, :string, default: "chatgpt_sign_in")
  attr(:cancel_event, :string, default: "chatgpt_sign_in_cancel")
  attr(:paste_event, :string, default: "chatgpt_sign_in_paste")
  attr(:submit_event, :string, default: "chatgpt_sign_in_submit")
  attr(:surface, :string, required: true)
  attr(:profile_id, :string, default: nil)
  # The exact CLI command a manual (remote/unsupported) surface should show —
  # e.g. an account-specific `genesis chatgpt login --account …`. A nil/blank
  # value falls back to the plain command.
  attr(:command, :string, default: nil)

  @doc """
  Renders the sign-in surface under the given id prefix.

  DOM ids: `#<id>-sign-in`, `#<id>-waiting`, `#<id>-sign-in-url`,
  `#<id>-sign-in-cancel`, `#<id>-sign-in-paste-hint`,
  `#<id>-sign-in-paste-input`, `#<id>-sign-in-paste-submit`,
  `#<id>-sign-in-paste-error`, `#<id>-sign-in-error`, `#<id>-manual-hint`.
  """
  def sign_in_panel(assigns) do
    sign_in = normalize_sign_in(assigns.sign_in)
    message = if sign_in.phase == :error, do: ChatGPTSignIn.message(sign_in.reason)
    paste_message = if sign_in.paste_error, do: ChatGPTSignIn.message(sign_in.paste_error)

    assigns =
      assign(assigns,
        sign_in: sign_in,
        message: message,
        message_tone: tone(message),
        paste_message: paste_message,
        paste_tone: tone(paste_message),
        redirect_address: redirect_address(sign_in.port),
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
        <%!-- zh_CN: 说明这条 CLI 登录也能接收手工粘贴回来的重定向地址，远程主机没有本地回调监听时仍可完成。 --%>
        <p class="text-xs text-base-content/60">
          {gettext(
            "That command also accepts a pasted redirect URL, so a sign-in started on another machine can still be finished."
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
          class="btn btn-ghost btn-sm"
        >
          {gettext("Cancel")}
        </button>

        <%!-- Always in the DOM: on a remote host the browser is redirected to its
        OWN loopback and lands on a connection error while the address bar still
        holds the callback query. --%>
        <details
          id={@id <> "-sign-in-paste-hint"}
          class="rounded-md border border-base-300/70 bg-base-200/40 px-2 py-1.5"
        >
          <summary class="cursor-pointer text-xs font-medium text-base-content/70">
            {gettext("Can't reach this page?")}
          </summary>
          <div class="mt-2 space-y-2">
            <p class="text-xs leading-relaxed text-base-content/70">
              {gettext(
                "If the browser shows a connection error after you approve, that is expected when Genesis runs on a remote host. Approve in the browser, then copy the address it redirected to — or just the code — and paste it below."
              )}
            </p>
            <p :if={@redirect_address} class="text-xs text-base-content/70">
              {gettext("Expected redirect address:")}
              <code class="break-all">{@redirect_address}</code>
            </p>
            <input
              id={@id <> "-sign-in-paste-input"}
              type="text"
              name="paste"
              value={@sign_in.paste}
              phx-change={@paste_event}
              phx-value-surface={@surface}
              phx-value-profile_id={@profile_id}
              autocomplete="off"
              spellcheck="false"
              class="input input-bordered input-sm w-full font-mono text-xs"
              placeholder={gettext("Paste the full redirect address or the code")}
            />
            <button
              id={@id <> "-sign-in-paste-submit"}
              type="button"
              phx-click={@submit_event}
              phx-value-surface={@surface}
              phx-value-profile_id={@profile_id}
              class="btn btn-outline btn-sm"
            >
              {gettext("Submit pasted link")}
            </button>
            <p
              :if={@paste_message}
              id={@id <> "-sign-in-paste-error"}
              role="alert"
              class={"text-xs " <> @paste_tone}
            >
              {@paste_message.text}
            </p>
          </div>
        </details>
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

  Answers the normalized `%{flow_id:, url:, phase:, reason:, port:, mode:,
  paste:, paste_error:}` when the requested surface owns the state (the
  canonical idle map when that surface is idle), and `%{}` for a nil/non-map
  state, an absent/unknown surface or a DIFFERENT surface.

  This is the ONE surface-isolation rule: the page state is owned by
  `EvoDashWeb.SettingsLive.ChatGPTSignInState` and this module only interprets
  it (`sign_in_panel/1` renders whatever state its caller resolved).
  """
  @spec surface_state(term(), :wizard | {:detail, term()} | {:status, term()} | nil) ::
          %{
            optional(:flow_id | :url | :phase | :reason | :port | :mode | :paste | :paste_error) =>
              term()
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

  # Total normalization: an unknown/absent phase is `:idle`, a non-binary url is
  # dropped so the panel never renders a broken link, and the paste fields
  # degrade to `nil`/`""` (an unknown port/mode is simply not shown).
  defp normalize_sign_in(sign_in) when is_map(sign_in) do
    %{
      flow_id: value(sign_in, :flow_id),
      url: sign_in_url(value(sign_in, :url)),
      phase: phase(value(sign_in, :phase)),
      reason: value(sign_in, :reason),
      port: redirect_port(value(sign_in, :port)),
      mode: redirect_mode(value(sign_in, :mode)),
      paste: paste_text(value(sign_in, :paste)),
      paste_error: paste_error(value(sign_in, :paste_error))
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

  # The redirect-URI port is only shown when it is a real port; anything else
  # (an absent key, nil, a string, 0) means "render no address line".
  defp redirect_port(value) when is_integer(value) and value > 0, do: value
  defp redirect_port(_value), do: nil

  defp redirect_mode(:loopback), do: :loopback
  defp redirect_mode(:manual), do: :manual
  defp redirect_mode("loopback"), do: :loopback
  defp redirect_mode("manual"), do: :manual
  defp redirect_mode(_value), do: nil

  defp paste_text(value) when is_binary(value), do: value
  defp paste_text(_value), do: ""

  defp paste_error(value) when is_atom(value) and not is_nil(value), do: value
  defp paste_error(_value), do: nil

  defp redirect_address(port) when is_integer(port) and port > 0,
    do: "http://127.0.0.1:#{port}/auth/callback"

  defp redirect_address(_port), do: nil

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
