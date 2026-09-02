defmodule EvoDashWeb.LiveHooks.Appearance do
  @moduledoc """
  Global on-mount hook that applies the user-configured accent color to the
  app shell.

  Reads `EvoGit.Config.resolve([:appearance, :accent_color])` (schema default
  `"blue"`, validated to one of the ten CSS-known names) and seeds the
  `@accent_color` assign on EVERY LiveView (registered globally via `on_mount`
  in the `live_view/0` macro, after `NodeAware`, before `DesktopQuit` — Guide
  stays LAST). The shared app layout (`EvoDashWeb.Layouts.app`) declares
  `attr(:accent_color, :string, default: "blue")` and sets
  `data-accent-color={@accent_color}` on the `#app-layout` shell div, which
  activates the ten `[data-accent-color="<name>"]` override rules in app.css
  (un-layered author CSS placed after the daisyUI theme `@plugin` blocks) that
  retarget `--color-primary`/`--color-accent` within the shell subtree.

  Resolution is NODE-AWARE, mirroring the `params["node"]` presence heuristic
  used by `UpdateStatus`:

  * **Local node** (no `?node=`, or a not-yet-connected/unknown target): the
    value is resolved SYNCHRONOUSLY inside the attached `:handle_params`
    interceptor via a direct `EvoGit.Config.resolve([:appearance,
    :accent_color])` call — a local file read, cheap on every mount and page
    push, so the accent is correct on the very first paint (dead render and
    connected mount both run `handle_params` after `on_mount`).
  * **Remote node** (`params["node"]` naming a connected `genesis_remote`
    target): resolved ASYNC via a supervised fetch on `EvoDash.TaskSupervisor`
    (never an RPC on the render path) that calls
    `EvoDash.NodeContext.get_resolved_config/1` (the remote node's full
    resolved config — the same RPC SettingsLive uses) and extracts the
    `appearance.accent_color` key. The seed (`"blue"` via `assign_new`) stays
    until the result message lands through the attached `:handle_info`
    interceptor, which applies it only when both the fetch seq AND the node
    context still match (stale-guard).

  Re-resolution is driven by a `:handle_params` interceptor: it re-resolves
  only when `params["node"]` OR the resolved node mode changed since the last
  run (the initial mount, node switches, and a pending→connected transition —
  which re-runs `handle_params` with the same `?node=` via NodeAware's
  `handle_connection_status/2` push_patch — all re-resolve; pagination/search
  push_patches that leave the node context untouched pass through cheaply).

  No PubSub subscription is needed: the accent is static per node until the
  config changes, and the config change would require a page reload anyway.
  `on_mount` (seed + attach) and the `handle_params`/`handle_info`
  interceptors suffice.
  """

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  # The ten accent names the `[data-accent-color="<name>"]` override rules in
  # app.css understand. Anything else (including nil from an unset/absent key,
  # or an unknown value from an older remote config) normalizes to the schema
  # default "blue".
  @known_accents ~w(blue teal green yellow orange red pink purple brown slate)

  @doc """
  Seeds the `@accent_color` assign (safe default `"blue"` via `assign_new`) and
  attaches the `:handle_params` + `:handle_info` interceptors on EVERY mount
  path (dead render AND connected — the `handle_params` interceptor needs no
  `connected?` gating and there is no desktop-mode gate; the async remote fetch
  itself is gated on `connected?` inside the interceptor).
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign_new(:accent_color, fn -> "blue" end)
      |> attach_hook(:appearance_accent, :handle_params, &handle_params/3)
      |> attach_hook(:appearance_accent, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  @doc false
  # Normalizes a resolved accent value: the ten CSS-known names pass through;
  # anything else (nil from an unset/absent key, unknown values from an older
  # remote config) falls back to the schema default "blue". Pure seam for unit
  # tests.
  def resolve_accent(accent) when accent in @known_accents, do: accent
  def resolve_accent(_accent), do: "blue"

  @doc false
  # Extracts the accent from a resolved config map (`%{appearance:
  # %{accent_color: ...}}`, atom-keyed as returned by `EvoGit.Config.resolve/0`).
  # Missing key / invalid value → "blue". Pure seam for unit tests.
  def accent_from_config(config) when is_map(config) do
    resolve_accent(get_in(config, [:appearance, :accent_color]))
  end

  def accent_from_config(_config), do: "blue"

  # Attached `:handle_params` hook — runs BEFORE the LiveView's own
  # `handle_params/3` (which calls `NodeAware.assign_node/2`), on every mount
  # and every push_patch/push_navigate. Re-resolves the accent only when the
  # node param OR the resolved node mode changed since the last run; otherwise
  # passes through cheaply. Always returns `{:cont, socket}` — the view's own
  # `handle_params` must run regardless.
  def handle_params(params, _uri, socket) do
    node_param = params["node"]
    mode = resolve_mode(node_param)

    if node_param == Map.get(socket.assigns, :accent_node_param, :unset) and
         mode == Map.get(socket.assigns, :accent_node_mode, :unset) do
      {:cont, socket}
    else
      socket = apply_mode(socket, node_param, mode)

      socket =
        socket
        |> assign(:accent_node_param, node_param)
        |> assign(:accent_node_mode, mode)

      {:cont, socket}
    end
  end

  # Attached `:handle_info` hook — routes async remote-accent results through
  # the stale-guard; `{:halt, socket}` consumes the matching message, everything
  # else passes through `{:cont, socket}`.
  def handle_info({:appearance_accent_result, _seq, _node_param, _accent} = message, socket) do
    {:halt, handle_accent_result(socket, message)}
  end

  def handle_info(_message, socket) do
    {:cont, socket}
  end

  # Stale-guarded application of an async remote-accent result. Drops the
  # result (socket unchanged) when the fetch seq no longer matches (a newer
  # fetch was spawned since — only the latest result is ever applied) or the
  # node param changed while the fetch was in flight (the user switched nodes).
  # Otherwise assigns `:accent_color`.
  defp handle_accent_result(
         socket,
         {:appearance_accent_result, seq, node_param, accent}
       ) do
    if seq != Map.get(socket.assigns, :accent_fetch_seq, 0) or
         node_param != Map.get(socket.assigns, :accent_node_param, :unset) do
      # Stale — a node switch or a newer fetch superseded this result.
      socket
    else
      assign(socket, :accent_color, resolve_accent(accent))
    end
  end

  # Resolves a `?node=` param to the node mode whose accent should be shown:
  # `{:remote, remote_node_atom}` when the target exists AND is connected
  # (mirroring `NodeAware.assign_node/2`'s resolution), else `:local` — nil /
  # "local", unknown ids, and known-but-not-yet-connected targets all fall back
  # to the local node's config (data comes from the local node until the
  # connection completes; the mode flip re-resolves on the connection
  # transition's `handle_params` re-run).
  defp resolve_mode(nil), do: :local
  defp resolve_mode("local"), do: :local

  defp resolve_mode(node_param) do
    case EvoDash.NodeContext.get_target(node_param) do
      {:ok, target} ->
        case EvoDash.NodeContext.connection_status(target.id) do
          %{phase: :connected, node: remote_node} when is_binary(remote_node) ->
            {:remote, String.to_atom(remote_node)}

          _ ->
            :local
        end

      {:error, :not_found} ->
        :local
    end
  end

  # Applies the resolved mode to the socket. Remote + connected socket: spawns
  # the async fetch (the seed stays until the result lands). Local, or remote on
  # a dead render: the local config is the best available value — read
  # synchronously (a local file read, never an RPC).
  defp apply_mode(socket, node_param, {:remote, remote_node}) do
    if Phoenix.LiveView.connected?(socket) do
      request_remote_accent(socket, node_param, remote_node)
    else
      # Dead render: no RPC on the render path — the "blue" seed stays until the
      # connected mount re-runs on_mount + handle_params and spawns the fetch.
      socket
    end
  end

  defp apply_mode(socket, _node_param, :local) do
    assign(socket, :accent_color, local_accent())
  end

  # Reads the resolved accent from the LOCAL node's config (a file read —
  # acceptable on all mounts including the dead render; avoids an accent flash).
  defp local_accent do
    resolve_accent(EvoGit.Config.resolve([:appearance, :accent_color]))
  end

  # Spawns a supervised fetch of the remote node's resolved accent and returns
  # the socket unchanged; the result arrives later via the attached
  # `:handle_info` hook. Captures the view pid, the node param, and the next
  # `:accent_fetch_seq` value BEFORE spawning and bumps the seq assign (so only
  # the latest request's result is ever applied).
  defp request_remote_accent(socket, node_param, remote_node) do
    view_pid = self()
    seq = Map.get(socket.assigns, :accent_fetch_seq, 0) + 1

    socket = assign(socket, :accent_fetch_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      accent =
        try do
          case EvoDash.NodeContext.get_resolved_config(remote_node) do
            {:ok, config} -> accent_from_config(config)
            {:error, _reason} -> "blue"
          end
        rescue
          # (1) Do we expect this error? Any unexpected failure inside a
          # fire-and-forget supervised task (e.g. a crashed remote connection) —
          # the spawned fn must NEVER raise, or the result message would never
          # be sent and the accent would silently stay at its seed.
          # (2) Is try/rescue the cleanest approach? Yes — the established
          # async-boundary rescue pattern (NodeAware's request_tasks_load).
          _ -> "blue"
        end

      send(view_pid, {:appearance_accent_result, seq, node_param, accent})
    end)

    socket
  end
end
