defmodule EvoDashWeb.LiveHooks.Guide do
  @moduledoc """
  Global on-mount hook bridging the core's `guide_user` tool to the dashboard.

  The `:evo_git` core's `guide_user` tool broadcasts a guide on `EvoGit.PubSub`
  topic `"guides"` with the message shape

      {:guide_updated, guide_id, %{message: String.t(), page: String.t() | nil,
        selector: String.t() | nil, dismissible: boolean}, node()}

  This hook subscribes on the connected mount of EVERY LiveView (registered
  globally via `on_mount` in the `live_view/0` macro, after `UpdateStatus`) and
  keeps the `@guide` assign in sync with those broadcasts. The shared app
  layout (`EvoDashWeb.Layouts.app`) renders the assign as a floating "Genesis
  Guide" panel, and the 8 `guide={@guide}` call sites in the live pages pass it
  through.

  Broadcasts are node-filtered FIRST through
  `EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?/2` (wrapped by the
  pure `relevant?/2` helper), so a guide broadcast on a remote
  `genesis_remote` node only surfaces while that node is being viewed.

  `@guide` is ALSO persisted to a `:persistent_term` store keyed by a per-tab
  `guide_client_id` that the `Guide` JS hook generates once per page load
  (sessionStorage-backed) and passes in the LiveSocket connect params
  (`socket.private[:connect_params]["guide_client_id"]`). `on_mount` seeds the
  assign back from that store via `assign_new/3`, so a guide survives
  `push_navigate` (which keeps the same WebSocket connection and therefore the
  same client id) and is restored — panel and highlight — on arrival at the
  destination `page`. With the client id present, retention works; when it is
  absent (non-desktop dead render, bare test sockets) the seed falls back to
  `nil` — the safe default.

  When the guide carries a `selector`, the hook pushes the `"guide_highlight"`
  event (`%{selector: selector}`) — consumed by the `Guide` JS hook
  (`assets/js/app.js`), which highlights the targeted element. Dismissal
  arrives as the `"guide_dismissed"` event; the handler clears BOTH the assign
  and the store and pushes a `"guide_cleared"` event so the JS hook drops its
  module-level highlight store — a later remount or navigation cannot
  resurrect it.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  alias EvoDashWeb.LiveHooks.NodeAware

  @store_namespace {:evogit, :guide}

  @doc """
  Seeds the `@guide` assign (from the navigation-retention store, so guides
  survive `push_navigate`) and attaches the PubSub `:handle_info` + event
  `:handle_event` interceptors on the connected mount only (dead-render skip,
  mirroring `UpdateStatus`).
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign_new(:guide, fn -> stored_guide(socket) end)
      |> maybe_attach()

    {:cont, socket}
  end

  @doc false
  # Thin wrapper over NodeAware's node filter so unit tests exercise the hook's
  # decision path without a LiveView. A guide broadcast is only relevant when
  # its publishing node is the node currently being viewed.
  def relevant?(assigns, node), do: NodeAware.event_from_current_node?(assigns, node)

  @doc false
  # Defensive normalizer tolerant of BOTH atom-keyed and string-keyed payloads
  # (the contract says atoms; tolerate strings). Never raises — missing or
  # malformed fields degrade to safe defaults.
  def normalize_guide(id, payload) when is_map(payload) do
    %{
      id: id,
      message: binary_or_default(field(payload, :message), ""),
      page: binary_or_nil(field(payload, :page)),
      selector: binary_or_nil(field(payload, :selector)),
      dismissible: boolean_or_default(field(payload, :dismissible), false)
    }
  end

  def normalize_guide(id, _payload) do
    %{id: id, message: "", page: nil, selector: nil, dismissible: false}
  end

  # Attached `:handle_info` hook — keeps `@guide` in sync with the core's
  # "guides" topic broadcasts. `{:halt, socket}` consumes the matching message.
  def handle_info({:guide_updated, id, payload, node}, socket) do
    if relevant?(socket.assigns, node) do
      guide = normalize_guide(id, payload)

      socket =
        socket
        |> assign(:guide, guide)
        |> store_guide(guide)

      socket =
        if is_binary(guide.selector) do
          push_event(socket, "guide_highlight", %{selector: guide.selector})
        else
          socket
        end

      {:halt, socket}
    else
      {:cont, socket}
    end
  end

  # Any other message flows through to the LiveView untouched.
  def handle_info(_message, socket) do
    {:cont, socket}
  end

  # Attached `:handle_event` hook — runs BEFORE the LiveView's own callback.
  # Dismissal clears both the assign and the retention store so a later remount
  # or navigation can't resurrect the guide, and pushes "guide_cleared" so the
  # JS hook drops its module-level highlight store (without it, a stale
  # highlight would re-apply on a later navigation after dismissal).
  def handle_event("guide_dismissed", _payload, socket) do
    socket =
      socket
      |> assign(:guide, nil)
      |> clear_guide()

    {:halt, push_event(socket, "guide_cleared", %{})}
  end

  # Any other event flows through to the LiveView untouched.
  def handle_event(_event, _payload, socket) do
    {:cont, socket}
  end

  # Subscribes to the "guides" topic and attaches both interceptors on the
  # connected mount only (dead-render skip, mirroring NodeAware/UpdateStatus).
  defp maybe_attach(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "guides")

      socket
      |> attach_hook(:guide, :handle_info, &handle_info/2)
      |> attach_hook(:guide, :handle_event, &handle_event/3)
    else
      socket
    end
  end

  # Reads the retained guide for this socket's client id, or nil when absent.
  # The connect params are only present on connected sockets (and in the dead
  # render they are absent), so bare sockets in tests degrade to nil safely.
  defp stored_guide(socket) do
    case client_id(socket) do
      nil -> nil
      id -> :persistent_term.get({@store_namespace, id}, nil)
    end
  end

  # Persists the guide for this socket's client id so `push_navigate` (same
  # WebSocket connection, same client id) can restore it on the destination
  # page. Returns the socket.
  defp store_guide(socket, guide) do
    case client_id(socket) do
      nil ->
        socket

      id ->
        :persistent_term.put({@store_namespace, id}, guide)
        socket
    end
  end

  # Clears the retained guide for this socket's client id. Returns the socket.
  defp clear_guide(socket) do
    case client_id(socket) do
      nil ->
        socket

      id ->
        :persistent_term.erase({@store_namespace, id})
        socket
    end
  end

  # The per-tab client id generated by the Guide JS hook (assets/js/app.js)
  # and passed in the LiveSocket connect params — stable across push_navigate
  # (same WebSocket connection) so the destination mount restores the guide.
  defp client_id(socket) do
    params = socket.private[:connect_params]

    cond do
      is_map(params) and is_binary(params["guide_client_id"]) -> params["guide_client_id"]
      is_map(params) and is_binary(params[:guide_client_id]) -> params[:guide_client_id]
      true -> nil
    end
  end

  # Reads a field from an atom-keyed OR string-keyed payload map. `||` treats
  # nil/false as absent, so an atom-keyed `dismissible: false` correctly falls
  # through to the string-key lookup (which misses) and degrades to the default.
  defp field(payload, key), do: Map.get(payload, key) || Map.get(payload, to_string(key))

  defp binary_or_default(value, _default) when is_binary(value), do: value
  defp binary_or_default(_value, default), do: default

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp boolean_or_default(value, _default) when is_boolean(value), do: value
  defp boolean_or_default(_value, default), do: default
end
