defmodule EvoDash.ActiveTasks do
  @moduledoc """
  In-memory per-node-context last-known-state hub for the sidebar "Active
  Tasks" list.

  The sidebar blinks on page navigation because every LiveView remounts with
  empty assigns and re-fetches its active-task lists before the (debounced,
  push-based) `"tasks"` PubSub refresh lands. This GenServer caches the most
  recently applied fetch result — the partitioned `{running, pending}` lists —
  so a remounting LiveView can render instantly instead of flashing empty.

  Snapshots are keyed by `{node_id, node}` so lists fetched for one node
  context can never leak into another view:

    * local context — `node_id: nil`, `node: node()` (the local BEAM node);
    * remote context — `node_id: <connection-target id string>`,
      `node: <remote BEAM node atom>`.

  The hub is a passive cache only: it stores whatever shape of task-summary
  maps it is given (it never inspects or transforms them) and broadcasts
  nothing — the existing `"tasks"` PubSub machinery keeps the cache fresh, and
  writers (the async per-page fetch results) call `put/4` on every successful
  apply.

  `get/3` is a synchronous call so mount-time reads are race-free; `put/4` and
  `reset/0` are casts (mirroring `EvoDash.UpdateStatus`'s mutator style) — the
  writer never blocks on the store.
  """

  use GenServer

  @doc """
  Starts the hub, registered as `EvoDash.ActiveTasks`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the last-known `{running, pending}` snapshot for a node context.

  `node_id` is `nil` for the local context or a connection-target id string
  for a remote one; `node` is the BEAM node atom the lists were fetched from.

  Returns `{:ok, {running, pending}}` when the context has a snapshot and
  `:empty` when it has never been written. Storing empty lists (`{[], []}`) is
  a valid snapshot and still returns `{:ok, {[], []}}`.
  """
  def get(node_id, node) do
    GenServer.call(__MODULE__, {:get, {node_id, node}})
  end

  @doc """
  Stores the last-known `{running, pending}` snapshot for a node context
  (cast — the writer never blocks). Overwrites any previous snapshot for that
  context. Shape-agnostic: the lists are stored verbatim.
  """
  def put(node_id, node, running, pending) do
    GenServer.cast(__MODULE__, {:put, {node_id, node}, {running, pending}})
  end

  @doc """
  Clears all node contexts back to the initial empty state (cast). Test
  support + defensive.
  """
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    reply =
      case Map.fetch(state, key) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> :empty
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:put, key, snapshot}, state) do
    {:noreply, Map.put(state, key, snapshot)}
  end

  def handle_cast(:reset, _state) do
    {:noreply, %{}}
  end
end
