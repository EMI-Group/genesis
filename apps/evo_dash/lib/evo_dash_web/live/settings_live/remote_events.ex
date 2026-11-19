defmodule EvoDashWeb.SettingsLive.RemoteEvents do
  @moduledoc """
  The remote-connection surface of `/settings`: target CRUD, connect /
  disconnect, bootstrap install and the bootstrap progress model.

  Every write here is exit-safe (`EvoDash.SafeCall`) because the connection
  registry and the connection manager are local GenServers whose calls can EXIT
  the LiveView. Async work never blocks the page: connects report their terminal
  outcome through the `"remote_connections"` broadcast (see
  `AsyncResults.remote_connection_status/2`) and a synchronous connect error
  through `AsyncResults.remote_connect_result/3`; a bootstrap runs in a plain
  task and reports `{:bootstrap_complete, id, result}`.

  The bootstrap progress entry here is `%{stage: nil | 0..4, active: boolean,
  status: :active | :success | :error, error: String.t() | nil}` — `:stage` is
  the MAPPED 0..4 step index the template renders directly (never re-map it).

  The remote-connections HEEx and its render-only helpers live in
  `EvoDashWeb.SettingsLive.RemotePanel`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDashWeb.SettingsLive.PageState

  @events [
    "add_remote_target",
    "cancel_edit_remote",
    "edit_remote_target",
    "toggle_remote_advanced",
    "remote_connections_form_change",
    "save_remote_target",
    "delete_remote_target",
    "bootstrap_remote_target",
    "confirm_bootstrap_restart",
    "cancel_bootstrap_restart",
    "connect_remote_target",
    "disconnect_remote_target",
    "retry_remote_connection"
  ]

  @doc """
  The event names this module owns.
  """
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  Routes one of `events/0` to its handler.

  Called from `SettingsLive.handle_event/3` (one-line delegation).
  """
  def handle_event(event, params, socket) when event in @events do
    case event do
      "add_remote_target" -> add_remote_target(socket, params)
      "cancel_edit_remote" -> cancel_edit_remote(socket, params)
      "edit_remote_target" -> edit_remote_target(socket, params)
      "toggle_remote_advanced" -> toggle_remote_advanced(socket, params)
      "remote_connections_form_change" -> remote_connections_form_change(socket, params)
      "save_remote_target" -> save_remote_target(socket, params)
      "delete_remote_target" -> delete_remote_target(socket, params)
      "bootstrap_remote_target" -> bootstrap_remote_target(socket, params)
      "confirm_bootstrap_restart" -> confirm_bootstrap_restart(socket, params)
      "cancel_bootstrap_restart" -> cancel_bootstrap_restart(socket, params)
      "connect_remote_target" -> connect_remote_target(socket, params)
      "disconnect_remote_target" -> disconnect_remote_target(socket, params)
      "retry_remote_connection" -> retry_remote_connection(socket, params)
    end
  end

  defp retry_remote_connection(socket, _params) do
    # Async connect — connect/1 returns promptly; terminal outcomes arrive via
    # the "remote_connections" PubSub broadcast, and sync errors (subsystem
    # unavailable etc.) via {:remote_connect_result, ...}.
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(
      socket,
      socket.assigns.current_node_id
    )

    {:noreply, socket}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Remote Connections event handlers
  # ───────────────────────────────────────────────────────────────────────────

  defp add_remote_target(socket, _params) do
    {:noreply,
     assign(socket,
       remote_form_target: %{
         dist_port: 9000,
         remote_path: "/tmp/genesis_server",
         platform: nil,
         # Internal marker: while true, the Name field auto-tracks the SSH
         # Target (see remote_connections_form_change). Never persisted.
         auto_name: true
       },
       remote_show_advanced: false
     )}
  end

  defp cancel_edit_remote(socket, _params) do
    {:noreply, assign(socket, remote_form_target: nil, remote_show_advanced: false)}
  end

  defp edit_remote_target(socket, %{"id" => id}) do
    # Exit-safe lookup: the target registry is a local GenServer whose call can
    # EXIT (dead/hung process) — `EvoDash.SafeCall` turns that into an error
    # value, which reads exactly like an unknown target (no edit form).
    form_target =
      case EvoDash.SafeCall.run(
             fn -> EvoDash.NodeContext.get_target(id) end,
             {:error, :not_found}
           ) do
        {:ok, target} ->
          target
          |> Map.put_new(:dist_port, 9000)
          |> Map.put_new(:remote_path, "/tmp/genesis_server")
          # Editing starts with the saved name shown verbatim — never
          # auto-track the SSH Target (internal marker, never persisted).
          |> Map.put(:auto_name, false)

        {:error, _reason} ->
          nil
      end

    {:noreply, assign(socket, remote_form_target: form_target, remote_show_advanced: false)}
  end

  defp toggle_remote_advanced(socket, _params) do
    {:noreply, update(socket, :remote_show_advanced, &(!&1))}
  end

  # Form change (every keystroke in the add/edit remote-connection form). The
  # Name field auto-fills from the SSH Target while the user has not typed a
  # custom name: the whole form-target assign is rebuilt from the submitted
  # params so the re-render shows the current values (name == full ssh_target
  # as it is typed). Once the user types into the Name field, that value is
  # kept verbatim and never clobbered by later SSH Target edits.
  defp remote_connections_form_change(socket, params) do
    current = socket.assigns.remote_form_target

    if is_nil(current) do
      {:noreply, socket}
    else
      rendered = current[:name] || ""
      submitted = params["name"] || ""
      tracking = Map.get(current, :auto_name, false)

      {name, tracking} =
        cond do
          tracking and submitted == rendered ->
            # Name untouched (its submitted value is the previous render's
            # auto-filled value) — keep tracking the SSH Target as it is typed.
            {params["ssh_target"] || "", true}

          tracking and submitted != rendered ->
            # The user took over the Name field — keep their value verbatim.
            {submitted, false}

          true ->
            {submitted, false}
        end

      form_target = %{
        name: name,
        ssh_target: params["ssh_target"] || "",
        local_binary_path: params["local_binary_path"] || "",
        platform: params["platform"] || "",
        dist_port: parse_remote_port(params["dist_port"]),
        remote_path: params["remote_path"] || "/tmp/genesis_server",
        auto_name: tracking
      }

      # Editing keeps the existing id; adding must NOT generate one here (the
      # hidden _id input would otherwise carry a frozen "target-<ts>" id into
      # save_remote_target instead of a slug from the effective name).
      form_target =
        case params["_id"] do
          id when is_binary(id) and id != "" -> Map.put(form_target, :id, id)
          _ -> form_target
        end

      {:noreply, assign(socket, remote_form_target: form_target)}
    end
  end

  defp save_remote_target(socket, params) do
    target = build_remote_target_from_params(params)

    # Exit-safe write: the registry call can EXIT the LiveView (dead/hung
    # process); the fallback lands on the existing "Failed to save" flash.
    case EvoDash.SafeCall.run(
           fn -> EvoDash.NodeContext.save_target(target) end,
           {:error, :unavailable}
         ) do
      {:ok, _saved} ->
        socket =
          socket
          |> assign(:remote_form_target, nil)
          |> put_flash(:info, gettext("Connection saved."))
          |> reload_remote_targets()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to save: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp delete_remote_target(socket, %{"id" => id}) do
    # Exit-safe delete (see save_remote_target/2).
    case EvoDash.SafeCall.run(
           fn -> EvoDash.NodeContext.delete_target(id) end,
           {:error, :unavailable}
         ) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, gettext("Connection deleted."))
          |> reload_remote_targets()

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Connection not found."))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to delete: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp bootstrap_remote_target(socket, %{"id" => id}) do
    # Double-click guard — already bootstrapping
    if get_in(socket.assigns.bootstrap_progress, [id, :active]) do
      {:noreply, socket}
    else
      # Immediately show the progress bar so the user sees feedback right away
      bootstrap_progress =
        Map.put(socket.assigns.bootstrap_progress, id, %{
          stage: nil,
          active: true,
          status: :active
        })

      socket = assign(socket, :bootstrap_progress, bootstrap_progress)

      lv_pid = self()

      Task.start(fn ->
        result = EvoDash.NodeContext.bootstrap(id)
        send(lv_pid, {:bootstrap_complete, id, result})
      end)

      {:noreply, socket}
    end
  end

  defp confirm_bootstrap_restart(socket, %{"target_id" => id}) do
    # Permission granted — close the dialog and re-bootstrap with
    # on_running: :restart (the core runs `<launcher> remote stop`, which only
    # DETACHES Erlang distribution — the remote server and its tasks keep
    # running — broadcasting :stopping_daemon, mapped to step 3 "Configuring",
    # then re-enables distribution with this connection's identity).
    socket = assign(socket, :bootstrap_restart_confirm, nil)

    bootstrap_progress =
      Map.put(socket.assigns.bootstrap_progress, id, %{stage: nil, active: true, status: :active})

    socket = assign(socket, :bootstrap_progress, bootstrap_progress)

    lv_pid = self()

    Task.start(fn ->
      result = EvoDash.NodeContext.bootstrap(id, on_running: :restart)
      send(lv_pid, {:bootstrap_complete, id, result})
    end)

    {:noreply, socket}
  end

  defp cancel_bootstrap_restart(socket, %{"target_id" => _id}) do
    {:noreply, assign(socket, :bootstrap_restart_confirm, nil)}
  end

  defp connect_remote_target(socket, %{"id" => id}) do
    # Duplicate guard — a connect is already in flight for this target; its
    # terminal outcome (:connected | :error | :disconnected) will arrive via
    # the "remote_connections" PubSub broadcast and be flashed by
    # consume_remote_connect_pending (which clears the marker).
    pending = Map.get(socket.assigns, :remote_connect_pending, %{})

    if Map.get(pending, id) == true do
      {:noreply, socket}
    else
      socket =
        assign(socket, :remote_connect_pending, Map.put(pending, id, true))

      # Async connect: connect/1 returns promptly ({:ok, :connecting} |
      # {:ok, :connected}); terminal outcomes arrive ONLY via broadcast.
      # Synchronous errors (subsystem unavailable — never broadcast) are
      # surfaced via {:remote_connect_result, ...}. No premature flash, no
      # status reload here — the broadcast handler re-reads statuses.
      {:noreply, EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, id)}
    end
  end

  defp disconnect_remote_target(socket, %{"id" => id}) do
    # Deliberately SYNCHRONOUS: disconnect is a fast GenServer.call (normally
    # <5s) and the Disconnect button renders only when the phase is :connected
    # (no bootstrap can be queued on that manager), so it cannot block the
    # LiveView meaningfully. Its terminal outcome is the sync result below.
    # EXIT-SAFE: the manager call can still EXIT this LiveView (dead/hung
    # process), so it runs through `EvoDash.SafeCall`; a failure reads as an
    # unavailable subsystem for `flash_remote_lifecycle_result/3`.
    result =
      EvoDash.SafeCall.run(
        fn -> EvoDash.NodeContext.disconnect(id) end,
        {:error, :remote_connection_unavailable}
      )

    socket =
      socket
      |> reload_remote_statuses()
      |> flash_remote_lifecycle_result(result, gettext("Disconnect"))

    {:noreply, socket}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Remote Connections
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Reloads the saved remote-connection targets (exit-safe read).
  """
  def reload_remote_targets(socket) do
    assign(socket, :remote_targets, PageState.safe_list_targets())
  end

  @doc """
  Reloads the per-target connection-status map (exit-safe read).
  """
  def reload_remote_statuses(socket) do
    assign(socket, :remote_statuses, PageState.safe_connection_statuses())
  end

  # ── Bootstrap progress helpers ───────────────────────────────────────────────
  #
  # `@bootstrap_progress[target_id]` entry shape:
  #   %{stage: nil | 0..4, active: boolean, status: :active | :success | :error,
  #     error: String.t() | nil}
  # `:stage` is the MAPPED 0-4 step index (see bootstrap_stage_idx/1), NOT the
  # raw core atom — the template uses it directly (do not re-map). `:active`
  # mirrors `status == :active` and keeps the double-click guard + template
  # condition working. `:error` is set only when status == :error.
  #
  # 5-step mapping (daisyUI steps in the Settings target card):
  #   step 0 "Probing / preparing" ← :probing_platform, :uploading, :detecting_os
  #   step 1 "Downloading"         ← :downloading, :downloading_locally
  #   step 2 "Extracting"          ← :extracting
  #   step 3 "Configuring"         ← :setting_permissions, :copying_config,
  #                                   :generating_cookie, :patching_binaries,
  #                                   :stopping_daemon
  #   step 4 "Starting daemon"     ← :starting_daemon
  # Unknown atoms → -1 (no step highlighted).

  @doc """
  Maps a raw core bootstrap stage atom to the rendered 0..4 step index.
  """
  def bootstrap_stage_idx(stage) do
    case stage do
      :probing_platform -> 0
      :uploading -> 0
      :detecting_os -> 0
      :downloading -> 1
      :downloading_locally -> 1
      :extracting -> 2
      :setting_permissions -> 3
      :copying_config -> 3
      :generating_cookie -> 3
      :patching_binaries -> 3
      :stopping_daemon -> 3
      :starting_daemon -> 4
      _ -> -1
    end
  end

  # Progress entry transitions driven by {:remote_connection_status, ...}
  # broadcasts. A :bootstrapping stage broadcast always advances the entry to
  # :active. While the entry is :active, a phase that ended the bootstrap is
  # FROZEN (:error keeps the last-known stage + message; any other end phase —
  # :connected/:disconnected/... — freezes :success). Every other broadcast
  # (different target, plain connect/disconnect, or a target with a frozen
  # :success/:error entry) PRESERVES the entry — the frozen bar must survive
  # unrelated traffic. The definitive terminal signals still come from
  # {:bootstrap_complete, id, result} (the Task result), which re-freezes.
  @doc """
  Applies one connection-status broadcast to the bootstrap progress map.
  """
  def update_bootstrap_progress(progress, target_id, status) do
    case status do
      %{phase: :bootstrapping, bootstrap_stage: stage} when not is_nil(stage) ->
        Map.put(progress, target_id, %{
          stage: bootstrap_stage_idx(stage),
          active: true,
          status: :active
        })

      status when is_map(status) ->
        case Map.get(progress, target_id) do
          %{status: :active} = entry ->
            cond do
              bootstrap_error?(status) ->
                Map.put(progress, target_id, %{
                  stage: entry.stage,
                  active: false,
                  status: :error,
                  error: bootstrap_error_message(status)
                })

              bootstrap_ended?(status) ->
                Map.put(progress, target_id, %{stage: 4, active: false, status: :success})

              true ->
                progress
            end

          _frozen_or_absent ->
            progress
        end

      _non_map ->
        progress
    end
  end

  # An error phase, or any map carrying a non-nil last_error, ends the
  # bootstrap in failure.
  defp bootstrap_error?(%{phase: :error}), do: true

  defp bootstrap_error?(status) when is_map(status) do
    case Map.get(status, :last_error) do
      nil -> false
      _ -> true
    end
  end

  defp bootstrap_error_message(status) do
    case Map.get(status, :last_error) do
      nil -> nil
      msg when is_binary(msg) -> msg
      msg -> EvoDashWeb.Helpers.format_remote_reason(msg)
    end
  end

  # Any phase other than :bootstrapping/:error while the entry is active means
  # the bootstrap ended. The core sets phase: :disconnected with
  # bootstrap_stage: nil right after a successful bootstrap, so :disconnected
  # MUST count as ended here.
  defp bootstrap_ended?(%{phase: phase}) when phase not in [:bootstrapping, :error],
    do: true

  defp bootstrap_ended?(_), do: false

  @doc """
  Human-readable error text for a frozen :error bar, derived from a
  `{:bootstrap_complete, id, {:error, reason}}` result.
  """
  def bootstrap_error_text(reason) do
    cond do
      is_binary(reason) -> reason
      is_map(reason) and Map.has_key?(reason, :last_error) -> bootstrap_error_message(reason)
      true -> EvoDashWeb.Helpers.format_remote_reason(reason)
    end
  end

  @doc """
  Freezes the target's progress entry in a terminal state (keeps the last
  known stage; success always freezes at step 4).
  """
  def freeze_bootstrap_progress(socket, id, status, error \\ nil) do
    progress = socket.assigns.bootstrap_progress
    last_stage = Map.get(Map.get(progress, id, %{}), :stage)

    frozen =
      case status do
        :success -> %{stage: 4, active: false, status: :success}
        :error -> %{stage: last_stage, active: false, status: :error, error: error}
      end

    assign(socket, :bootstrap_progress, Map.put(progress, id, frozen))
  end

  @doc """
  Drops the target's transient progress entry (e.g. a refused bootstrap).
  """
  def clear_bootstrap_progress(socket, id) do
    assign(socket, :bootstrap_progress, Map.delete(socket.assigns.bootstrap_progress, id))
  end

  defp build_remote_target_from_params(params) do
    # A blank/absent name falls back to the SSH Target (the Name field
    # auto-fills from it while untouched) so a new target always persists
    # name == ssh_target even on a direct submit with no change event.
    name = params["name"]

    name =
      if is_binary(name) and name != "" do
        name
      else
        params["ssh_target"] || ""
      end

    id = params["_id"]
    id = if id && id != "", do: id, else: generate_remote_id(name)

    %{
      id: id,
      name: name,
      ssh_target: params["ssh_target"] || "",
      local_binary_path: params["local_binary_path"] || "",
      platform: params["platform"] || "",
      dist_port: parse_remote_port(params["dist_port"]),
      remote_path: params["remote_path"] || "/tmp/genesis_server"
    }
  end

  defp parse_remote_port(nil), do: nil
  defp parse_remote_port(""), do: nil

  defp parse_remote_port(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_remote_port(num) when is_integer(num), do: num

  defp generate_remote_id(nil), do: generate_remote_id("")

  defp generate_remote_id(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "" do
      "target-#{System.system_time(:second)}"
    else
      slug
    end
  end

  # Consumes the per-target pending-connect marker (set by
  # connect_remote_target) and flashes the FIRST terminal outcome broadcast of
  # an initiation made from THIS page. NodeAware.handle_connection_status has
  # already recomputed @connection_statuses/@remote_status by the time this
  # runs, so the gate reconciles automatically. Broadcasts for connects
  # initiated elsewhere (node selector, another page) never set the marker →
  # no flash. `:connecting` (non-terminal) neither clears nor flashes.
  @doc """
  Clears the pending-connect marker for a terminal outcome and flashes it.
  """
  def consume_remote_connect_pending(socket, target_id, status) do
    phase = if is_map(status), do: Map.get(status, :phase), else: nil

    # Read the pending marker defensively: broadcasts for connects initiated
    # elsewhere (bootstrap, node selector, another page) never set the marker,
    # so the map may legitimately lack the key — bare dot-access would KeyError
    # only if the assign itself were missing, and a nil marker must not crash
    # `and` with a BadBooleanError.
    pending = Map.get(socket.assigns, :remote_connect_pending, %{})

    if Map.get(pending, target_id) == true and
         phase in [:connected, :error, :disconnected] do
      socket =
        assign(socket, :remote_connect_pending, Map.delete(pending, target_id))

      case phase do
        :connected ->
          flash_remote_lifecycle_result(socket, :ok, gettext("Connect"))

        :error ->
          reason =
            case Map.get(status, :last_error) do
              nil -> gettext("Unknown error")
              msg when is_binary(msg) -> msg
              msg -> EvoDashWeb.Helpers.format_remote_reason(msg)
            end

          put_flash(socket, :error, gettext("Connect failed: %{reason}", reason: reason))

        :disconnected ->
          # Some other flow disconnected the target — nothing useful to flash.
          socket
      end
    else
      socket
    end
  end

  @doc """
  Flashes the outcome of a remote lifecycle action (connect/disconnect/install).
  """
  def flash_remote_lifecycle_result(socket, result, action) do
    case result do
      {:error, :remote_connection_unavailable} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} unavailable — the remote connection subsystem is not running.",
            action: action
          )
        )

      :ok ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:ok, _} ->
        put_flash(socket, :info, gettext("%{action} succeeded.", action: action))

      {:error, reason} ->
        put_flash(
          socket,
          :error,
          gettext("%{action} failed: %{reason}",
            action: action,
            reason: EvoDashWeb.Helpers.format_remote_reason(reason)
          )
        )

      _other ->
        put_flash(socket, :info, gettext("%{action} completed.", action: action))
    end
  end
end
