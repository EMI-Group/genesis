defmodule EvoDashWeb.HomeLive.Workspace do
  @moduledoc "Optional, node-scoped project selection. Selecting a directory reads no project files."
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2]
  alias EvoDash.{NodeContext, SafeCall}
  alias EvoDashWeb.HomeLive.ChatState
  alias EvoDashWeb.ProjectsLive.ProjectFlow

  def scope(assigns), do: {assigns[:current_node_id], assigns[:current_node] || node()}
  def locked?(assigns), do: assigns[:chat_status] in [:running, :cancelling]

  def normalize(%{path: path, node: target} = workspace)
      when is_binary(path) and is_atom(target) and target not in [nil, true, false] do
    if ProjectFlow.absolute_path_for_node?(target, path) do
      %{
        path: path,
        node: target,
        node_id: workspace[:node_id],
        name: workspace[:name] || Path.basename(path)
      }
    end
  end

  def normalize(_), do: nil

  def restore(workspace, {node_id, target}) do
    case normalize(workspace) do
      %{node: ^target, node_id: ^node_id} = workspace -> workspace
      _ -> nil
    end
  end

  def list(node_id, target) do
    with :ok <- ready_target(node_id, target),
         {:ok, projects} when is_list(projects) <-
           SafeCall.run(fn -> NodeContext.projects(target) end) do
      {:ok, Enum.filter(projects, &valid_project?(&1, target))}
    else
      _ -> {:error, gettext("Connect to the selected node before choosing a project.")}
    end
  end

  def open(node_id, target, input) when is_binary(input) do
    with :ok <- ready_target(node_id, target),
         {:ok, path} <- normalize_path(node_id, target, input),
         true <- ProjectFlow.absolute_path_for_node?(target, path),
         {:ok, true} <- SafeCall.run(fn -> NodeContext.dir?(target, path) end),
         {:ok, {:ok, mount}} <-
           SafeCall.run(fn -> NodeContext.mount_project(target, path, nil) end) do
      {:ok, %{path: mount.path, name: mount.name, node: target, node_id: node_id}}
    else
      {:error, :unavailable} ->
        {:error, gettext("Connect to the selected node before choosing a project.")}

      {:error, reason} when reason in [:blank, :relative] ->
        {:error, gettext("Enter a full directory path.")}

      _ ->
        {:error,
         gettext(
           "This directory is unavailable on the selected node. Check the path and try again."
         )}
    end
  end

  def open(_, _, _), do: {:error, gettext("Enter a full directory path.")}

  def toggle(socket) do
    socket = assign(socket, workspace_open: !socket.assigns.workspace_open, workspace_error: nil)
    if socket.assigns.workspace_open, do: load(socket, :list), else: socket
  end

  def select(socket, path) do
    if locked?(socket.assigns) or socket.assigns.workspace_loading do
      socket
    else
      load(assign(socket, workspace_path: path), {:open, path})
    end
  end

  def clear(socket) do
    if locked?(socket.assigns) or socket.assigns.workspace_loading do
      socket
    else
      socket
      |> assign(workspace: nil, workspace_error: nil, workspace_open: false, workspace_path: "")
      |> ChatState.persist()
    end
  end

  def apply_result(socket, seq, request_scope, chat_id, kind, result) do
    if seq == socket.assigns.workspace_seq and request_scope == scope(socket.assigns) and
         chat_id == socket.assigns.chat_id do
      socket = assign(socket, workspace_loading: false)

      case {kind, result} do
        {:list, {:ok, {:ok, projects}}} ->
          assign(socket, workspace_projects: projects)

        {:open, {:ok, {:ok, workspace}}} ->
          if locked?(socket.assigns) do
            socket
          else
            socket
            |> assign(workspace: workspace, workspace_open: false, workspace_error: nil)
            |> ChatState.persist()
          end

        {_, {:ok, {:error, message}}} ->
          assign(socket, workspace_error: message)

        _ ->
          assign(socket, workspace_error: gettext("Could not load the project. Try again."))
      end
    else
      socket
    end
  end

  defp load(socket, operation) do
    {node_id, target} = request_scope = scope(socket.assigns)
    seq = socket.assigns.workspace_seq + 1
    kind = if operation == :list, do: :list, else: :open
    tag = {:assistant_workspace_loaded, seq, request_scope, socket.assigns.chat_id, kind}

    result =
      SafeCall.start(self(), tag, fn ->
        case operation do
          :list -> list(node_id, target)
          {:open, path} -> open(node_id, target, path)
        end
      end)

    case result do
      {:ok, _} ->
        assign(socket, workspace_seq: seq, workspace_loading: true, workspace_error: nil)

      _ ->
        assign(socket, workspace_error: gettext("Could not load the project. Try again."))
    end
  end

  defp ready_target(nil, target) when target == node(), do: :ok

  defp ready_target(id, target)
       when is_binary(id) and id != "" and is_atom(target) and target not in [nil, true, false] do
    if target != node() and target in Node.list(:connected), do: :ok, else: {:error, :unavailable}
  end

  defp ready_target(_, _), do: {:error, :unavailable}
  defp normalize_path(nil, _, input), do: ProjectFlow.normalize_project_path(input)

  defp normalize_path(_, target, input),
    do: ProjectFlow.normalize_remote_project_path(target, input)

  defp valid_project?(%{path: path}, target) when is_binary(path),
    do: ProjectFlow.absolute_path_for_node?(target, path)

  defp valid_project?(_, _), do: false
end
