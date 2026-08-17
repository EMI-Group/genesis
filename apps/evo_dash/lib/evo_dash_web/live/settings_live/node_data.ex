defmodule EvoDashWeb.SettingsLive.NodeData do
  @moduledoc """
  Async node-aware data loading for the Settings page.

  `handle_params/3` must never block the LiveView render loop on cross-node
  RPCs — `EvoDash.NodeContext.get_resolved_config/1` (a FULL merged config
  map) can take up to 30s on a slow or unreachable remote node. This module
  runs the whole node-data load sequence — resolved config, config status,
  and the custom-agents list — in a supervised task OUTSIDE the LiveView
  process and reports the result back as `{tag, requested_node, results}`.

  Local and remote nodes share ONE code path: `EvoDash.NodeContext` already
  unifies local-direct calls with `:erpc`-routed remote calls, so the same
  task body serves both. The task never crashes the LiveView: a failed remote
  fetch (or any unexpected error in the load) is funneled into the results map
  as `:remote_config_error` so the LiveView can render the error banner
  instead of silently keeping stale mount data.

  The LiveView applies the results in `handle_info/3` with a stale-guard:
  results are dropped when `requested_node` no longer matches the currently
  viewed node — the user switched nodes while the load was in flight, and a
  newer load is already running for the new node.

  ## Results map

      %{
        file_config: map(),                        # %{} on remote fetch failure
        config_status: map(),
        remote_config_error: nil | term(),         # raw reason; the LiveView gettexts it
        custom_agents: %{
          agents: [map()],
          model_selection_script: String.t(),
          script_status: :ok | {:error, {:compile_error, String.t()}}
        }
      }
  """

  @doc false
  # Spawns the supervised load task for the node currently assigned on the
  # socket. Returns `:ok` (fire-and-forget); the result message carries the
  # requested node so the LiveView can stale-guard it.
  def start(socket, tag) do
    parent = self()
    node = socket.assigns.current_node

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      results =
        try do
          load(node)
        rescue
          # The load crosses an RPC boundary on remote nodes (and touches the
          # user's config files locally). Any unexpected failure — an erpc
          # exit, a raise in config parsing — must surface via the error
          # banner instead of silently leaving mount's stale data on screen.
          # Expected: unreachable nodes; the rescue is the cleanest funnel for
          # every failure mode into the results map.
          e ->
            error_results(node, e)
        end

      send(parent, {tag, node, results})
    end)

    :ok
  end

  defp load(node) do
    config =
      case fetch_node_config(node) do
        {:ok, config} -> config
        {:error, err} -> error_results(node, err.reason)
      end

    Map.put(config, :custom_agents, fetch_custom_agents(node))
  end

  defp error_results(node, reason) do
    %{
      file_config: %{},
      config_status: config_status(node),
      remote_config_error: reason
    }
  end

  defp config_status(node) do
    if node == node() do
      EvoGit.Config.config_status()
    else
      EvoDash.NodeContext.get_remote_config_status(node)
    end
  end

  # Fetches the config to display for the given node. Local: loaded from disk
  # exactly as SettingsLive.mount/3 does. Remote: the FULL resolved user config
  # (defaults + user config merged — the same atom-keyed nested shape
  # `ConfigIO.load_file_config/0` produces locally) via
  # `EvoDash.NodeContext.get_resolved_config/1`. A remote fetch failure is
  # returned as `{:error, %{reason: reason}}` — never raised — so the caller
  # can surface it via `:remote_config_error` instead of silently rendering an
  # empty config (which would trigger a spurious "No LLM Model Configured"
  # box).
  defp fetch_node_config(node) do
    if node == node() do
      {:ok,
       %{
         file_config: EvoDashWeb.SettingsLive.ConfigIO.load_file_config(),
         config_status: EvoGit.Config.config_status(),
         remote_config_error: nil
       }}
    else
      case EvoDash.NodeContext.get_resolved_config(node) do
        {:ok, resolved} ->
          {:ok,
           %{
             file_config: resolved,
             config_status: EvoDash.NodeContext.get_remote_config_status(node),
             remote_config_error: nil
           }}

        {:error, reason} ->
          {:error,
           %{
             reason: reason,
             config_status: EvoDash.NodeContext.get_remote_config_status(node)
           }}
      end
    end
  end

  # Loads the custom-agents data (agent definitions, model-selection script,
  # script compile status) for the given node. Tolerant: any unexpected result
  # shape degrades to the empty defaults (the LiveView's synchronous
  # `load_custom_agents_data/1` keeps its strict match for the save flows).
  defp fetch_custom_agents(node) do
    case EvoDash.NodeContext.list_custom_agents(node) do
      {:ok, %{agents: agents, model_selection_script: script, script_status: script_status}} ->
        %{agents: agents, model_selection_script: script || "", script_status: script_status}

      _ ->
        %{agents: [], model_selection_script: "", script_status: :ok}
    end
  end
end
