defmodule EvoDashWeb.ProjectsLive.AsyncLoad do
  @moduledoc """
  Async node-aware loads for `EvoDashWeb.ProjectsLive`.

  Coordinator for the node-aware loads that must NOT run in the LiveView
  process (custom agents, model profiles + the `selected_model_id` switch
  validation, remote project config/mode, recent projects, and the
  notified-terminal-id seed). All loads run in ONE supervised
  `EvoDash.TaskSupervisor` task per connected handle_params run so the
  LiveView process never blocks on cross-node RPCs or on the task store — the
  remote path would otherwise serialize up to 6-8 `:erpc` round-trips on every
  navigation, and even the LOCAL store reads can take seconds.

  This batch is the SINGLE seed for recent projects and the notified-id set:
  `mount/3` seeds those assigns EMPTY (`recent_projects: []`,
  `notified_task_ids: MapSet.new()`, `notified_task_ids_ready?: false`) so the
  first paint never touches the store, and the continuation fills them a frame
  later (the mount's project auto-activation is likewise deferred to the
  continuation — see `ProjectsLive.maybe_auto_activate_recent_project/1`).
  `terminal_ids` is loaded only for a LOCAL context that has not been seeded
  yet; a remote/pending context or an already-seeded socket leaves it nil.

  Results arrive as a single `{:async_project_load, node, prev_node_id, path,
  results}` message; `handle_result/5` drops stale results (the captured node
  or active project path no longer matches the current socket) and reports
  whether it applied anything, so the caller only runs post-apply follow-ups
  (auto-activation, GitHub detection) for results that actually landed.

  The batch BODY is resolved from the `:projects_async_load_runner` app-env
  seam AT SPAWN TIME (a 0-arity fun; default
  `fn -> default_batch(node, remote?, current_node_id, path, seed_terminal_ids?,
  auto_activate?) end`) and runs inside `EvoDash.SafeCall.run/1`, so an injected
  batch that exits/raises (e.g. `fn -> exit(:boom) end`) cannot crash anything.
  On failure NO message is sent — the page simply keeps the defaults `mount/3`
  seeded (empty recent projects / notified ids) instead of filling them a frame
  later.
  """

  alias EvoGit.Platform
  alias EvoGit.TaskRegistry

  alias EvoDash.NodeContext
  alias EvoDashWeb.ProjectsLive.Notifications
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
  skip the spawn entirely (the assigns are seeded in mount/3 and filled by the
  connected run).

  Two extra result keys ride along:

    * `terminal_ids` — the notified-task-id SEED, computed inside the task and
      only when this is a LOCAL context whose set has not been seeded yet
      (`nil` otherwise, so a remote/pending context and any later refresh
      never re-seed it).
    * `auto_activate?` — whether this spawn was the "no project in the URL"
      candidate run, so the continuation may auto-activate the most recent
      project.
  """
  def maybe_spawn(socket, prev_node_id) do
    if connected?(socket) do
      %{current_node: node} = socket.assigns
      remote? = socket.assigns[:remote?] == true
      current_node_id = socket.assigns[:current_node_id]
      path = socket.assigns[:active_project_path]

      seed_terminal_ids? =
        current_node_id == nil and socket.assigns[:notified_task_ids_ready?] != true

      auto_activate? = socket.assigns[:auto_activate_candidate?] == true
      parent = self()

      # Resolved AT SPAWN TIME (dashboard runner-seam idiom): a test can swap
      # the whole batch body for an exiting fun and assert the page keeps its
      # seeded defaults. Default = today's loads (default_batch/6).
      runner =
        Application.get_env(:evo_dash, :projects_async_load_runner, fn ->
          default_batch(node, remote?, current_node_id, path, seed_terminal_ids?, auto_activate?)
        end)

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        # EXIT-SAFE: the batch performs store reads and (for remote nodes)
        # `:erpc` round-trips whose target can be dead/hung — either EXITS the
        # task. `EvoDash.SafeCall.run/1` captures that as a value, so a failing
        # batch sends nothing at all (see the moduledoc) and the LiveView keeps
        # its seeded defaults instead of crashing.
        case EvoDash.SafeCall.run(runner) do
          {:ok, results} ->
            send(parent, {:async_project_load, node, prev_node_id, path, results})

          {:error, _reason} ->
            :ok
        end
      end)

      socket
    else
      socket
    end
  end

  @doc """
  The DEFAULT async batch body — today's grouped node-aware loads.

  Runs OFF the LiveView process (inside the supervised task spawned by
  `maybe_spawn/2`). Returns the `results` map carried by the
  `{:async_project_load, node, prev_node_id, path, results}` message. Public so
  the `:projects_async_load_runner` seam's default can reference it and tests
  can call it directly.
  """
  def default_batch(node, remote?, current_node_id, path, seed_terminal_ids?, auto_activate?) do
    {custom_agents, model_selection_enabled} = load_custom_agents(node)
    {model_profiles, default_selected_model_id} = Project.load_model_profiles(node)

    %{
      custom_agents: custom_agents,
      model_selection_enabled: model_selection_enabled,
      model_profiles: model_profiles,
      default_selected_model_id: default_selected_model_id,
      recent_projects: load_recent_projects(remote?, current_node_id, node),
      terminal_ids: if(seed_terminal_ids?, do: Notifications.load_terminal_ids()),
      auto_activate?: auto_activate?
    }
    |> Map.merge(remote_extras(node, remote?, path))
  end

  @doc """
  Applies an async load result, dropping stale results (the captured node or
  active project path no longer matches the current socket).

  Returns `{socket, applied?}` — `applied?` is false for a dropped result, so
  the caller can skip every post-apply follow-up (project auto-activation,
  GitHub upstream detection) for a result that never landed.

  The `selected_model_id` validation — originally synchronous in
  `handle_params/3` — runs HERE in the continuation: when the spawn-time
  handle_params run was a node switch (`prev_node_id` differs from the
  current node id), the carried selection is kept only when it names a
  profile that exists on the (new) node, otherwise the node's default
  selection is used; same-node runs keep the current selection.

  `terminal_ids` (when present as a `MapSet`) seeds/merges the notified-task-id
  set and marks it READY — the notification scan is skipped entirely until
  then, so an empty set can never fire a notification for every historical
  task. `auto_activate?` is not assigned here; the caller reads it.

  Resume-restore guard: when the socket carries
  `:resume_foreign_repos_guard` (set by the remote activation continuation in
  `ProjectsLive.handle_info/2` after a resume-aware activation restored the
  previous task's foreign repos) AND this result carries `:foreign_repos`
  (a remote_extras reload), the `:foreign_repos` key is NOT applied — the
  genesis.toml reload must not clobber the task-restored repos the activation
  just applied. The flag is cleared on that application, so subsequent
  navigations refresh foreign repos from genesis.toml as usual.
  """
  def handle_result(socket, node, prev_node_id, path, results) do
    %{active_project_path: active_path, current_node: current_node} = socket.assigns

    if node != current_node or path != active_path do
      {socket, false}
    else
      socket = assign(socket, :model_profiles, results.model_profiles)

      socket =
        assign(
          socket,
          :selected_model_id,
          resolve_selected_model_id(socket, prev_node_id, results)
        )

      socket =
        case Map.get(results, :terminal_ids) do
          %MapSet{} = terminal_ids ->
            socket
            |> assign(
              :notified_task_ids,
              MapSet.union(socket.assigns[:notified_task_ids] || MapSet.new(), terminal_ids)
            )
            |> assign(:notified_task_ids_ready?, true)

          _ ->
            socket
        end

      {skip_foreign_repos?, socket} =
        if socket.assigns[:resume_foreign_repos_guard] == true and
             Map.has_key?(results, :foreign_repos) do
          {true, assign(socket, :resume_foreign_repos_guard, false)}
        else
          {false, socket}
        end

      # Apply every remaining key the task included. Remote-only keys
      # (`project_config`, `worktree_script`, `commands`,
      # `foreign_repos`, `task_mode`, `task_mode_info`) are absent from the
      # results map for local nodes and are skipped here — the local
      # activate_project flow owns those assigns. `:foreign_repos` is dropped
      # when the resume-restore guard above fired (its task-derived value must
      # win over the genesis.toml reload). `:terminal_ids` / `:auto_activate?`
      # are consumed above (not assign names).
      results =
        if skip_foreign_repos? do
          Map.delete(results, :foreign_repos)
        else
          results
        end

      socket =
        Enum.reduce(results, socket, fn
          {:model_profiles, _}, sock -> sock
          {:default_selected_model_id, _}, sock -> sock
          {:terminal_ids, _}, sock -> sock
          {:auto_activate?, _}, sock -> sock
          {key, value}, sock -> assign(sock, key, value)
        end)

      {socket, true}
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

  @doc """
  Recent projects for the node being viewed: connected remote → RPC +
  node-aware filter; pending/error remote context → `[]` (local recents must
  never leak into a remote view); local → the local `EvoGit.TaskRegistry`.

  Callers must run this OUTSIDE the LiveView process (it is used by the async
  load batch here and by `ProjectsLive`'s `{:recent_projects_updated}`
  handler task) — the local branch is a task-store `GenServer.call`.
  """
  def load_recent_projects(remote?, current_node_id, node) do
    cond do
      remote? ->
        filter_absolute_recent_projects_for_node(node, NodeContext.list_recent_projects(node))

      is_binary(current_node_id) ->
        []

      true ->
        filter_absolute_recent_projects(TaskRegistry.list_recent_projects())
    end
  end

  # Remote-only extras: when a remote project is active — its genesis.toml
  # config / worktree script / commands / foreign repos and the auto-detected
  # task mode + info message. Omitted entirely for local nodes so the
  # continuation never touches those assigns.
  defp remote_extras(node, true, path) do
    if is_binary(path) do
      config = NodeContext.read_project_config(node, path)

      {project_config, worktree_script, commands} =
        Project.load_project_config(node, path, config)

      foreign_repos = Project.load_foreign_repos(node, path, config)
      mode = Project.detect_mode(node, path)

      %{
        project_config: project_config,
        worktree_script: worktree_script,
        commands: commands,
        foreign_repos: foreign_repos,
        task_mode: mode,
        task_mode_info: EvoDashWeb.Helpers.mode_info_message(mode)
      }
    else
      %{}
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
