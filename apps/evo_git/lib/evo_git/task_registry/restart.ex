defmodule EvoGit.TaskRegistry.Restart do
  @moduledoc """
  The ONE batched restart classifier: which of a set of wrapper-less live task
  rows are RESUMABLE and must therefore park as a DIRTY PAUSE instead of
  `:failed`.

  Both restart paths (`EvoGit.TaskRegistry.init/1`'s boot reconciliation and the
  one-shot `:lease_sweep`) used to classify per row, and each row cost a task
  read plus a durable roster read — 3 K round trips inside the registry
  GenServer, before it could answer anything. `classify/2` does it in TWO reads
  TOTAL regardless of how many rows are involved:

    1. ONE `EvoGit.Store.select_tasks_restart_info/2` for the narrow row
       projection (`id`, `status`, `type`, `opts`, `pause_kind`,
       `project_path` — no heavy JSON blob);
    2. ONE bounded `EvoGit.TaskRegistry.AgentStateRead.roster_many/2` for the
       CANDIDATE tasks only (a task that is interactive or opted out of
       `:persistent_state` cannot be resumable, so it never reaches the durable
       read).

  The decision itself is NOT re-derived here: `EvoGit.TaskRegistry.Pause`
  owns the pure `dirty_pausable?/2` rule (persistent state on, not interactive)
  and the `root_run?/1` predicate (a durable record whose `fields[:parent_id]`
  is nil), so the `:dirty` verdict means exactly what a single-row
  `Pause.pause_kind_for_restart/2` means.

  ## Degradation — nothing is classified

  A store outage (`StoreRead.restart_info/2` → `:unavailable`) and an
  unanswerable/degraded durable roster (`AgentStateRead.roster_many/2` → `[]`)
  both answer `%{}`: NO task is parked as a pause, so the rows keep their live
  status and the sweep later fails them exactly as before. Parking a task that
  cannot be restored would be the lie this classifier exists to prevent.
  """

  alias EvoGit.TaskRegistry.AgentStateRead
  alias EvoGit.TaskRegistry.Pause
  alias EvoGit.TaskRegistry.StoreRead

  @typedoc "The dirty-pause verdict per RESUMABLE task id (a non-resumable id is not a key)."
  @type classification :: %{optional(String.t()) => :dirty}

  @doc """
  Classifies `task_ids` for restart: `%{task_id => :dirty}` for every task whose
  row is present, whose options allow a pause AND whose durable tree holds a
  ROOT agent run. Every other id is simply absent from the map.

  Total: an empty/non-binary id list, a store outage and a degraded durable read
  all answer `%{}`.
  """
  @spec classify(GenServer.server(), [String.t()]) :: classification()
  def classify(store, task_ids) when is_list(task_ids) do
    task_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> classify_ids(store)
  end

  def classify(_store, _task_ids), do: %{}

  defp classify_ids([], _store), do: %{}

  defp classify_ids(task_ids, store) do
    case StoreRead.restart_info(store, task_ids) do
      {:ok, rows} -> classify_rows(rows)
      :unavailable -> %{}
    end
  end

  defp classify_rows([]), do: %{}

  defp classify_rows(rows) do
    # The pure option half first: an interactive session or a task that opted
    # out of durable state can never be resumed, so it never costs a durable
    # read. `dirty_pausable?/2` with `true` asks exactly that half.
    candidates = Enum.filter(rows, &Pause.dirty_pausable?(&1, true))

    case candidates do
      [] ->
        %{}

      candidates ->
        root_ids =
          candidates
          |> Enum.map(& &1.id)
          |> durable_root_ids()

        for row <- candidates, MapSet.member?(root_ids, row.id), into: %{} do
          {row.id, :dirty}
        end
    end
  end

  # ONE batched durable read for the candidate ids; a degraded read answers `[]`
  # and therefore classifies nothing.
  defp durable_root_ids(task_ids) do
    task_ids
    |> AgentStateRead.roster_many(op: "restart_classify_roster")
    |> Enum.filter(&Pause.root_run?/1)
    |> MapSet.new(& &1.task_id)
  end
end
