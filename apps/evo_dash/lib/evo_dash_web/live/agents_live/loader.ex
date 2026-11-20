defmodule EvoDashWeb.AgentsLive.Loader do
  @moduledoc """
  LiveView-side async spawners for the Agents page.
  It spawns the page load and the broadcast-triggered refresh in
  `EvoDash.TaskSupervisor` children, sends the tagged results to the caller and
  returns the updated socket (never renders, never blocks).
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias EvoDash.SafeCall
  alias EvoDashWeb.AgentsLive.LoadData

  # ---------------------------------------------------------------------------
  # Async load machinery
  # ---------------------------------------------------------------------------

  @doc """
  Kicks off the async page load (agents + config status + threshold cache).
  """
  # Kicks off the async page load (agents + config status + threshold cache).
  # Sets the loading flag and a fresh generation; the task sends
  # {:agents_data_loaded, node, gen, result} back, which is stale-guarded by
  # generation + node in handle_info/2.
  def start_page_load(socket) do
    parent = self()
    node = socket.assigns.current_node
    gen = Map.get(socket.assigns, :load_generation, 0) + 1
    threshold_cache = socket.assigns.threshold_cache

    # A new load supersedes any previous failure: the banner clears as soon as
    # the retry is in flight.
    socket = assign(socket, agents_loading: true, load_generation: gen, agents_error: nil)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Exit-safe boundary: the load RPCs to a possibly-dead remote daemon (or a
      # node that disconnected mid-flight). `SafeCall.run/1` captures an `exit`
      # (a GenServer.call timeout / dead target, which `rescue` cannot catch) as
      # an error VALUE, so the result message is ALWAYS sent and
      # `agents_loading` can never wedge.
      result =
        case SafeCall.run(fn -> LoadData.load(node, threshold_cache) end) do
          {:ok, {:ok, data}} -> {:ok, data}
          {:ok, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
          {:ok, other} -> {:error, {:unexpected_load_result, other}}
        end

      send(parent, {:agents_data_loaded, node, gen, result})
    end)

    socket
  end

  @doc """
  Spawns the shared async agent refresh (one per coalesced flush window).
  """
  # Spawns the shared async agent refresh (used by the {:agents_updated, node}
  # broadcasts, the {:agent_registered} summary-fallback, and the
  # {:agent_updated} missing-agent race). Bumps the monotonic :refresh_seq
  # (never reset); the result is stale-guarded by seq + node in handle_info/2.
  def spawn_refresh(socket) do
    parent = self()
    node = socket.assigns.current_node
    seq = Map.get(socket.assigns, :refresh_seq, 0) + 1
    threshold_cache = socket.assigns.threshold_cache

    socket = assign(socket, :refresh_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      # Exit-safe boundary: the refresh RPCs to a possibly-dead remote daemon.
      # `SafeCall.run/1` turns an exit (which `rescue` cannot catch) into an
      # error value, so the result message is always sent; the seq stale-guard
      # drops late/duplicate results and an error keeps the last good tree.
      result =
        case SafeCall.run(fn -> LoadData.refresh(node, threshold_cache) end) do
          {:ok, {agents, cache}} -> {:ok, agents, cache}
          {:error, reason} -> {:error, reason}
          {:ok, other} -> {:error, {:unexpected_refresh_result, other}}
        end

      send(parent, {:agents_refresh_result, seq, node, result})
    end)

    socket
  end
end
