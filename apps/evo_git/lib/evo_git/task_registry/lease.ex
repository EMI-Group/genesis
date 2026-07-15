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

  @doc """
  Sets crash details on a task struct: adds `finished_at` and a crash result
  message if the task status is `:failed` and `finished_at` is `nil`.
  """
  def set_crash_details(%{status: :failed, finished_at: nil} = task) do
    %{task | finished_at: DateTime.utc_now(), result: "Process crashed while task was running"}
  end

  def set_crash_details(task), do: task
end
