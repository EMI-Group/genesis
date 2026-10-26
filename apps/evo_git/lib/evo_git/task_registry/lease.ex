defmodule EvoGit.TaskRegistry.Lease do
  @moduledoc """
  SchedMeta ETS and lease helper functions for `EvoGit.TaskRegistry`.

  These are pure or ETS-only functions with no GenServer state dependency.
  """

  @doc """
  Checks the `:evogit_sched_meta` ETS table for active agents belonging to the
  given `task_id`. The table stores `{id, %SchedMeta{task_id: ..., status: ...}}`.
  Terminal agents are removed from the table, so ANY entry for this `task_id`
  means agents are still active. Returns `false` if the table doesn't exist.

  Uses `:ets.info/1` which returns `:undefined` for missing/nonexistent tables
  (non-crashing) — no `try/rescue` needed.
  """
  def sched_meta_has_active_agents?(task_id) do
    case :ets.info(:evogit_sched_meta) do
      :undefined ->
        false

      _ ->
        :evogit_sched_meta
        |> :ets.tab2list()
        |> Enum.any?(fn {_id, meta} ->
          Map.get(meta, :task_id) == task_id
        end)
    end
  end

  @doc """
  Best-effort result lookup from the `:evogit_sched_meta` ETS table for a given
  `task_id`. Scans all entries for this task and looks for a top-level agent
  (`parent_id == nil`) that has accumulated a result in its sched_meta. The
  scheduler stores the final result in the SchedMeta before deleting it, so if
  any entry still exists, it may carry the result.

  Returns `{:ok, _}`, `{:error, _}`, `{:exit, _}` if a recognizable result is
  found, or `nil` if no result is available. Uses `:ets.info/1` for table
  existence (non-crashing) per the codebase's ETS convention.
  """
  def lookup_sched_meta_result(task_id) do
    case :ets.info(:evogit_sched_meta) do
      :undefined ->
        nil

      _ ->
        :evogit_sched_meta
        |> :ets.tab2list()
        |> Enum.find_value(fn {_id, meta} ->
          if Map.get(meta, :task_id) == task_id and Map.get(meta, :parent_id) == nil do
            # Check if this top-level agent has a result in its sub_agent_results
            # or if result_sent is true. The actual result value isn't stored in
            # sched_meta (it's delivered via GenServer.reply), so this is a
            # heuristic check.
            Map.get(meta, :sub_agent_results) |> Map.values() |> List.first()
          end
        end)
    end
  end

  @doc """
  Returns `true` if the lease has not yet expired (is a future timestamp).
  `nil` means no lease → not valid → eligible for cleanup.
  """
  def lease_valid?(nil), do: false

  def lease_valid?(expires_at) do
    System.system_time(:second) < expires_at
  end

  ## Liveness classification of a `EvoGit.Store.get_task_status/2` result
  ##
  ## That read answers THREE shapes and callers must not collapse them:
  ##
  ##   * `nil` — NO row with that id (the only "absent" answer),
  ##   * a known status atom — see `EvoGit.Store.Codec.known_statuses/0`,
  ##   * `{:unknown, raw}` — the row EXISTS but its status text is outside the
  ##     whitelist (already logged by `Codec.decode_status/1`).
  ##
  ## An unreadable status must never be mistaken for an absent/leaked task: the
  ## checks below answer conservatively for `{:unknown, _}` (the row is there,
  ## so keep its lease renewed and never declare it orphaned). They live here —
  ## beside the sweep's other predicates — so the heartbeat and the sweep share
  ## ONE classification instead of re-deriving `in [...]` lists.

  # Statuses whose lease the heartbeat RENEWS. `:cancelling` is included so a
  # long graceful cancel keeps its lease while the wrapper is still alive.
  @renewed_statuses [:running, :pending, :cancelling]

  @doc """
  `true` when the task's lease should be RENEWED: a live status, or a row that
  exists with a status we cannot read (`{:unknown, _}` — renew rather than let
  an unrelated status spelling expire a live task's lease).
  """
  @spec lease_renewable?(atom() | {:unknown, term()} | nil) :: boolean()
  def lease_renewable?({:unknown, _}), do: true
  def lease_renewable?(status), do: status in @renewed_statuses

  @doc """
  `true` when the task is PROVABLY a leaked `:running` row: a known `:running`
  status, an expired (or missing) lease, and not owned by this registry — the
  verdict the one-shot `:lease_sweep` acts on.

  `{:unknown, _}` is NEVER leaked: the row exists, its status is just
  unreadable, so the sweep leaves it alone (conservative — a live task must
  never be failed because of a status spelling).
  """
  @spec leaked?(atom() | {:unknown, term()} | nil, boolean(), integer() | nil) :: boolean()
  def leaked?(:running, owned?, lease_expires_at) do
    not owned? and not lease_valid?(lease_expires_at)
  end

  def leaked?(_status, _owned?, _lease_expires_at), do: false
end
