defmodule EvoDashWeb.ProjectsLive.AsyncLoad do
  @moduledoc """
  Async node-aware loads for `EvoDashWeb.ProjectsLive`.

  Coordinator for the node-aware loads that used to run synchronously in
  `handle_params/3` (custom agents, model profiles + the `selected_model_id`
  switch validation, remote agents, remote project config/mode, recent
  projects). All loads run in ONE supervised `EvoDash.TaskSupervisor` task per
  handle_params run so the LiveView process never blocks on cross-node RPCs —
  the remote path would otherwise serialize up to 6-8 `:erpc` round-trips on
  every navigation.

  Results arrive as a single `{:async_project_load, node, prev_node_id, path,
  results}` message; `handle_result/5` drops stale results (the captured node
  or active project path no longer matches the current socket) and applies
  the rest. `mount/3` still seeds every assign synchronously, so the first
  paint never depends on the async result — the async refresh overrides it a
  frame later with identical values.
  """

  alias EvoGit.Platform
  alias EvoGit.TaskRegistry

  alias EvoDash.NodeContext
  alias EvoDashWeb.ProjectsLive.Project
  alias EvoDashWeb.ProjectsLive.ProjectFlow

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @doc """
  Spawns the grouped async node-aware load for the current handle_params run
  and returns the socket unchanged.

  Captures the resolved node, the pre-`assign_node` node id (so the
  continuation can replicate the original node-switch `selected_model_id`
  validation), whether the context is remote, and the active project path at
  spawn time. The task body runs OUTSIDE the LiveView process; dead renders
  skip the spawn entirely (mount/3 already seeded every assign synchronously).
  """
  def maybe_spawn(socket, prev_node_id) do
    if connected?(socket) do
      %{current_node: node} = socket.assigns
      remote? = socket.assigns[:remote?] == true
      current_node_id = socket.assigns[:current_node_id]
      path = socket.assigns[:active_project_path]
      parent = self()

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        {custom_agents, model_selection_enabled} = load_custom_agents(node)
        {model_profiles, default_selected_model_id} = Project.load_model_profiles(node)

        results =
          %{
            custom_agents: custom_agents,
            model_selection_enabled: model_selection_enabled,
            model_profiles: model_profiles,
            default_selected_model_id: default_selected_model_id,
            recent_projects: load_recent_projects(remote?, current_node_id, node)
          }
          |> Map.merge(remote_extras(node, remote?, path))

        send(parent, {:async_project_load, node, prev_node_id, path, results})
      end)

      socket
    else
      socket
    end
  end

  @doc """
  Applies an async load result, dropping stale results (the captured node or
  active project path no longer matches the current socket).

  The `selected_model_id` validation — originally synchronous in
  `handle_params/3` — runs HERE in the continuation: when the spawn-time
  handle_params run was a node switch (`prev_node_id` differs from the
  current node id), the carried selection is kept only when it names a
  profile that exists on the (new) node, otherwise the node's default
  selection is used; same-node runs keep the current selection.
  """
  def handle_result(socket, node, prev_node_id, path, results) do
    %{active_project_path: active_path, current_node: current_node} = socket.assigns

    if node != current_node or path != active_path do
      socket
    else
      socket = assign(socket, :model_profiles, results.model_profiles)

      socket =
        assign(
          socket,
          :selected_model_id,
          resolve_selected_model_id(socket, prev_node_id, results)
        )

      # Apply every remaining key the task included. Remote-only keys
      # (`remote_agents`, `project_config`, `worktree_script`, `commands`,
      # `foreign_repos`, `task_mode`, `task_mode_info`) are absent from the
      # results map for local nodes and are skipped here — the local
      # activate_project flow owns those assigns.
      Enum.reduce(results, socket, fn
        {:model_profiles, _}, sock -> sock
        {:default_selected_model_id, _}, sock -> sock
        {key, value}, sock -> assign(sock, key, value)
      end)
    end
  end

  @doc """
  Loads the node's custom agents (agents.toml) and whether its model-selection
  script is configured, for the task form's agent select and the model
  select's "Auto (by rules)" option. Node-aware via `EvoDash.NodeContext`,
  which degrades to empty agents on transport failure. A
  configured-but-broken script still counts as enabled (script non-nil),
  matching `EvoGit.CustomAgents.ModelSelector.enabled?/0` semantics.
  """
  def load_custom_agents(node) do
    case NodeContext.list_custom_agents(node) do
      {:ok, %{agents: agents, model_selection_script: script}} ->
        {agents, is_binary(script) and script != ""}

      _ ->
        {[], false}
    end
  end

  @doc """
  Filters recent-project entries to absolute paths only. Stale cwd-joined
  entries (produced by the pre-fix Windows relative-input bug, which
  `Path.expand`ed bare folder names against the Tauri install dir) must never
  render in the palette, feed auto-load, or reach path suggestions.
  """
  def filter_absolute_recent_projects(recent_projects) do
    Enum.filter(recent_projects, fn project ->
      case project do
        %{path: path} when is_binary(path) -> Platform.absolute_path?(path)
        _ -> false
      end
    end)
  end

  @doc """
  Node-aware variant of `filter_absolute_recent_projects/1`: local nodes keep
  the strict `Platform.absolute_path?/1` semantics; remote nodes accept
  POSIX- or Windows-absolute paths via the single shared
  `ProjectFlow.absolute_path_for_node?/2` predicate so remote recents survive
  a dashboard running on a different OS.
  """
  def filter_absolute_recent_projects_for_node(node, recent_projects) do
    Enum.filter(recent_projects, fn project ->
      case project do
        %{path: path} -> ProjectFlow.absolute_path_for_node?(node, path)
        _ -> false
      end
    end)
  end

  # Recent projects for the node being viewed: connected remote → RPC +
  # node-aware filter; pending/error remote context → [] (local recents must
  # never leak into a remote view); local → the local TaskRegistry.
  defp load_recent_projects(remote?, current_node_id, node) do
    cond do
      remote? ->
        filter_absolute_recent_projects_for_node(node, NodeContext.list_recent_projects(node))

      is_binary(current_node_id) ->
        []

      true ->
        filter_absolute_recent_projects(TaskRegistry.list_recent_projects())
    end
  end

  # Remote-only extras: the remote node's active agents, plus — when a remote
  # project is active — its genesis.toml config / worktree script / commands /
  # foreign repos and the auto-detected task mode + info message. Omitted
  # entirely for local nodes so the continuation never touches those assigns.
  defp remote_extras(node, true, path) do
    extras = %{remote_agents: NodeContext.list_agents(node)}

    if is_binary(path) do
      config = NodeContext.read_project_config(node, path)

      {project_config, worktree_script, commands} =
        Project.load_project_config(node, path, config)

      foreign_repos = Project.load_foreign_repos(node, path, config)
      mode = Project.detect_mode(node, path)

      Map.merge(extras, %{
        project_config: project_config,
        worktree_script: worktree_script,
        commands: commands,
        foreign_repos: foreign_repos,
        task_mode: mode,
        task_mode_info: EvoDashWeb.Helpers.mode_info_message(mode)
      })
    else
      extras
    end
  end

  defp remote_extras(_node, false, _path), do: %{}

  # Replicates the original handle_params validation: on a node switch the
  # selection carried from the previous node is kept only when it names a
  # profile that exists on the new node, otherwise the new node's default is
  # used ("" when its model-selection script is enabled, else the first
  # profile id, or nil). Same-node runs never clobber the user's explicit
  # choice (that assign is owned by the select_model event / restore_state on
  # the same node).
  defp resolve_selected_model_id(socket, prev_node_id, results) do
    if prev_node_id != socket.assigns[:current_node_id] do
      carried = socket.assigns[:selected_model_id]

      if is_binary(carried) and carried != "" and
           Enum.any?(results.model_profiles, &(Map.get(&1, :id) == carried)) do
        carried
      else
        results.default_selected_model_id
      end
    else
      socket.assigns[:selected_model_id]
    end
  end
end
