defmodule EvoDash.AccentCache do
  @moduledoc """
  In-memory per-node last-known accent cache for the shell-wide config accent
  (`EvoDashWeb.LiveHooks.Appearance`), backed by a named public ETS table (no
  process).

  A LiveView viewing a REMOTE node (`?node=<connection-target-id>`) can only
  learn that node's accent via an async RPC fetch — which must never run on
  the render path. Without a cache, every page load first paints the
  local/default accent and then flips to the remote one as soon as the fetch
  lands (the accent-flash bug this cache fixes). This module caches the most
  recently APPLIED (successfully fetched) accent per node so a remounting
  LiveView can paint the correct accent on the very first render — dead
  render, connected mount, and every cross-LiveView navigation — with no
  interim color.

  The table `:evo_dash_accent_cache` is a named public `:set` table created
  at boot by `EvoDash.Application.start/2` and owned by the long-lived
  application process (NOT a supervised child), so it survives child-process
  restarts and lives for the whole `mix test` run (same boot-created shape as
  the `EvoDash.ActiveTasks` hub).

  Accents are keyed by the connection-target id ALONE — `nil` for the local
  node, the target id string for a remote/pending target — deliberately NOT
  by `{node_id, node}` like the ActiveTasks hub: the accent is a per-target
  CONFIG value, so the same target must hit the same entry across the
  pending→connected flip of the BEAM node atom (a target's accent does not
  change when its connection completes; ActiveTasks keys by node because task
  data genuinely originates from a node).

  Values are normalized accent names (one of the ten CSS-known names — the
  only writer, `EvoDashWeb.LiveHooks.Appearance`, normalizes via its
  `resolve_accent/1` before calling `put/2`); `nil` is never stored. The
  cache is written only on the non-stale APPLY of a successful async fetch —
  stale/dropped results and failed fetches never write, so a known warm value
  is never regressed.

  Each public function operates on a single object (`:ets.lookup`,
  `:ets.insert`, `:ets.delete_all_objects`), which ETS makes atomic. All
  functions are guarded with `:ets.whereis/1` and degrade gracefully
  (`:empty` / no-op) if invoked before the application has booted. `reset/0`
  clears every entry (test hygiene).
  """

  @table :evo_dash_accent_cache

  @doc """
  Returns the last-known accent for a node context.

  `node_id` is `nil` for the local node or a connection-target id string for
  a remote/pending target. Returns `{:ok, accent}` (a known accent name)
  when the node has a cached accent and `:empty` when it has never been
  written or the table does not exist.
  """
  def get(node_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :empty

      _tid ->
        case :ets.lookup(@table, node_id) do
          [{_key, accent}] -> {:ok, accent}
          [] -> :empty
        end
    end
  end

  @doc """
  Stores the last-known accent for a node context, overwriting any previous
  entry. Writers must pass a normalized accent name (one of the ten CSS-known
  names); the hook's `resolve_accent/1` normalization happens before the
  write. No-op if the table does not exist.
  """
  def put(node_id, accent) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.insert(@table, {node_id, accent})
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
