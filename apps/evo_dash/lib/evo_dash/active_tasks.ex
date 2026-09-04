defmodule EvoDash.ActiveTasks do
  @moduledoc """
  In-memory per-node-context last-known-state cache for the sidebar "Active
  Tasks" list, backed by a named public ETS table (no process).

  The sidebar blinks on page navigation because every LiveView remounts with
  empty assigns and re-fetches its active-task lists before the (debounced,
  push-based) `"tasks"` PubSub refresh lands. This module caches the most
  recently applied fetch result — the partitioned `{running, pending}` lists —
  so a remounting LiveView can render instantly instead of flashing empty.

  The table `:evo_dash_active_tasks` is a named public `:set` table created at
  boot by `EvoDash.Application.start/2` and owned by the long-lived application
  process (NOT a supervised child), so it survives child-process restarts and
  lives for the whole `mix test` run. Snapshots are `{running, pending}`
  2-tuples keyed by `{node_id, node}` so lists fetched for one node context can
  never leak into another view:

    * local context — `node_id: nil`, `node: node()` (the local BEAM node);
    * remote context — `node_id: <connection-target id string>`,
      `node: <remote BEAM node atom>`;
    * pending remote context — `node_id: <connection-target id string>`,
      `node: node()` (the target id is preserved so a pending key never
      collides with the pure-local key).

  The cache is passive and shape-agnostic: it stores whatever task-summary
  lists it is given verbatim (never inspects or transforms them) and broadcasts
  nothing — the existing `"tasks"` PubSub machinery keeps the cache fresh, and
  writers (the async per-page fetch results) call `put/4` on every successful
  apply.

  Each public function operates on a single object (`:ets.lookup`,
  `:ets.insert`, `:ets.delete`, `:ets.delete_all_objects`), which ETS makes
  atomic — readers never see partial snapshots. There are no compound
  read-modify-write operations anywhere, so no locking is needed. Storing empty
  lists (`{[], []}`) is a valid snapshot and still returns `{:ok, {[], []}}`;
  `get/2` returns `:empty` only when the context has never been written (or the
  table does not exist). `invalidate/2` deletes one node context's snapshot so
  the next mount on that context is cold and re-fetches via the existing
  machinery (the review-action refresh); `reset/0` clears every node context
  (test hygiene). All functions are guarded with `:ets.whereis/1` and degrade
  gracefully (`:empty` / no-op) if invoked before the application has booted.
  """

  @table :evo_dash_active_tasks

  @doc """
  Returns the last-known `{running, pending}` snapshot for a node context.

  `node_id` is `nil` for the local context or a connection-target id string
  for a remote one; `node` is the BEAM node atom the lists were fetched from.

  Returns `{:ok, {running, pending}}` when the context has a snapshot and
  `:empty` when it has never been written or the table does not exist. Storing
  empty lists (`{[], []}`) is a valid snapshot and still returns
  `{:ok, {[], []}}`.
  """
  def get(node_id, node) do
    case :ets.whereis(@table) do
      :undefined ->
        :empty

      _tid ->
        case :ets.lookup(@table, {node_id, node}) do
          [{_key, snapshot}] -> {:ok, snapshot}
          [] -> :empty
        end
    end
  end

  @doc """
  Stores the last-known `{running, pending}` snapshot for a node context.
  Overwrites any previous snapshot for that context. Shape-agnostic: the lists
  are stored verbatim. No-op if the table does not exist.
  """
  def put(node_id, node, running, pending) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.insert(@table, {{node_id, node}, {running, pending}})
        :ok
    end
  end

  @doc """
  Deletes the `{node_id, node}` snapshot so a subsequent `get/2` for that
  context returns `:empty`. Used by review actions on completed tasks before
  navigating away, so the next mount on that node context is cold and
  re-fetches via the existing machinery. No-op if the table does not exist.
  """
  def invalidate(node_id, node) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.delete(@table, {node_id, node})
        :ok
    end
  end

  @doc """
  Clears all node contexts back to the initial empty state. Test support +
  defensive. No-op if the table does not exist.
  """
  def reset do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end
end
