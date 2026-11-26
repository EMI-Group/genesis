defmodule EvoDashWeb.HomeLive.WorkbenchScope do
  @moduledoc """
  PAGE-LOCAL SCOPE wiring of `EvoDashWeb.HomeLive`: the project/workspace
  picker, the canonical model selection, the node-context switches, the shared
  sidebar Conversations refresh and the Genesis source gate.
  Nothing here decides a conversation's identity — that is
  `EvoDashWeb.HomeLive.SessionResolution` — and nothing here owns the model
  rules, which stay in `EvoDashWeb.HomeLive.ModelSelection` /
  `ModelSelection.update_model_selection/3`:
    * the workspace picker events, all thin delegations to
      `EvoDashWeb.HomeLive.Workspace` (its scope IS the draft identity) — the
      toggle, the idempotent `workspace_close` behind click-away/Escape, and
      the selection/clear/expand events;
    * `select_provider/2`, `select_model/2`, `select_reasoning_effort/2` — the
      shared capsule's selection events, forwarded verbatim;
    * the model-snapshot result (`{:model_select_loaded, …}`) with its node +
      seq + pending-remote guards;
    * `{:node_selected, …}` / `{:remote_connection_status, …}` — the node
      context moves, each followed by one Conversations reload
      (`AttachPipeline.maybe_load_sessions/1`);
    * `maybe_check_source/1`, `download_source/1` and their two results — the
      local-only Genesis source gate (`EvoDashWeb.HomeLive.SourceGate`).
  Extracted verbatim: every guard, seq and gettext string is unchanged.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]
  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.HomeLive.{AttachPipeline, ModelSelection, SourceGate, Workspace}

  ## Workspace / model selection -----------------------------------------

  def workspace_toggle(socket), do: {:noreply, Workspace.toggle(socket)}
  def workspace_close(socket), do: {:noreply, Workspace.close(socket)}
  def workspace_clear(socket), do: {:noreply, Workspace.clear(socket)}

  def workspace_path(socket, %{"workspace" => %{"path" => path}}),
    do: {:noreply, assign(socket, workspace_path: path, workspace_error: nil)}

  def workspace_open(socket, %{"workspace" => %{"path" => path}}),
    do: {:noreply, Workspace.select(socket, path)}

  def workspace_select(socket, %{"path" => path}),
    do: {:noreply, Workspace.select(socket, path)}

  def workspace_browsed(socket, context, target, path) do
    {:noreply,
     if(
       context == Workspace.picker_context(socket.assigns) and
         target == elem(Workspace.scope(socket.assigns), 1),
       do: Workspace.select(socket, path, :browse),
       else: socket
     )}
  end

  def workspace_pick(socket, %{"point" => point}),
    do: {:noreply, Workspace.select_workspace(socket, point)}

  def workspace_pick(socket, _params), do: {:noreply, socket}

  def workspace_expand(socket, %{"point" => point}),
    do: {:noreply, Workspace.toggle_expanded(socket, point)}

  def workspace_expand(socket, _params), do: {:noreply, socket}

  def select_provider(socket, %{"provider_profile_id" => id}),
    do: ModelSelection.update_model_selection(socket, :select_provider, id)

  def select_model(socket, %{"model" => model}),
    do: ModelSelection.update_model_selection(socket, :select_model, model)

  def select_reasoning_effort(socket, %{"reasoning_effort" => index}),
    do: ModelSelection.update_model_selection(socket, :select_reasoning_effort, index)

  def model_select_loaded(socket, {{:model_select_loaded, seq, target_node}, result}) do
    if target_node != elem(ModelSelection.selection_scope(socket), 1) or
         seq != socket.assigns.model_select_seq or ModelSelection.pending_remote?(socket) do
      {:noreply, socket}
    else
      case result do
        {:ok, snapshot_result} ->
          {:noreply, ModelSelection.apply_model_snapshot(socket, snapshot_result)}

        {:error, reason} ->
          {:noreply, ModelSelection.apply_model_snapshot(socket, {:error, reason})}
      end
    end
  end

  ## Node context --------------------------------------------------------

  def node_selected(socket, {:node_selected, node_id}) do
    {:noreply, socket} = NodeAware.handle_node_selected(socket, node_id)
    {:noreply, AttachPipeline.maybe_load_sessions(socket)}
  end

  def remote_connection_status(socket, {:remote_connection_status, target_id, status}) do
    {:noreply, socket} =
      NodeAware.handle_connection_status(socket, {:remote_connection_status, target_id, status})

    {:noreply, AttachPipeline.maybe_load_sessions(socket)}
  end

  ## Genesis source gate -------------------------------------------------

  def maybe_check_source(socket) do
    if connected?(socket) and SourceGate.visible?(socket.assigns[:current_node]) do
      seq = socket.assigns[:source_check_seq] + 1
      node = socket.assigns[:current_node] || node()
      SourceGate.spawn_availability_check(self(), seq, node)
      assign(socket, source_check_seq: seq, source_check_loading: true)
    else
      socket
    end
  end

  def download_source(socket) do
    if socket.assigns[:source_busy] != nil do
      {:noreply, socket}
    else
      SourceGate.spawn_clone(self(), socket.assigns[:current_node] || node())
      {:noreply, assign(socket, source_busy: :clone)}
    end
  end

  def source_availability_loaded(socket, {:source_availability_loaded, seq, node, result}) do
    if seq == socket.assigns[:source_check_seq] and is_atom(node) and
         NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, assign(socket, source_available: result, source_check_loading: false)}
    else
      {:noreply, socket}
    end
  end

  def source_clone_result(socket, {:source_clone_result, node, result}) do
    if is_atom(node) and NodeAware.event_from_current_node?(socket.assigns, node) do
      case result do
        {:ok, _status} ->
          {:noreply, socket |> assign(source_busy: nil) |> maybe_check_source()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(source_busy: nil)
           |> put_flash(
             :error,
             gettext("Failed to download the Genesis source: %{reason}",
               reason: inspect(reason)
             )
           )}

        {:unavailable, _reason} ->
          {:noreply, assign(socket, source_busy: nil, source_available: nil)}

        _other ->
          {:noreply, assign(socket, source_busy: nil)}
      end
    else
      {:noreply, socket}
    end
  end
end
