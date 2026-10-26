defmodule EvoDashWeb.ProjectsLive.Notifications do
  @moduledoc """
  Browser-notification detection for `EvoDashWeb.ProjectsLive`.

  Notification detection needs two store reads (the minimal terminal-id
  projection, then one lite row per NEWLY terminal id) and must never run in
  the LiveView process: every `EvoGit.TaskRegistry` call is a `GenServer.call`
  that can take seconds (`get_task_lite/1` decodes the row without the archive
  blob, but still decodes `opts`/`result`) and EXITS the caller on timeout or a
  dead server.
  Each entry point here is therefore wrapped in `EvoDash.SafeCall`:

    * `load_terminal_ids/0` — the mount/handle_params SEED of the
      `:notified_task_ids` assign (returns `nil` when the store call failed, so
      the caller can retry on a later navigation instead of seeding an empty
      set that would fire a notification for every historical task).
    * `spawn_scan/4` — runs the "which terminal ids are new?" scan in one
      supervised `EvoDash.TaskSupervisor` task and sends
      `{:task_notifications, seq, node, result}` back to the caller.

  Local-context only by design: remote nodes have no local task store to scan.
  """

  alias EvoGit.TaskRegistry

  alias EvoDash.SafeCall
  alias EvoDashWeb.ProjectsLive.Project

  @terminal_statuses [:completed, :failed, :cancelled]

  @doc """
  Loads the ids of every terminal task (`:completed` / `:failed` /
  `:cancelled`) as a `MapSet`, or `nil` when the store call failed.

  Exit-safe: a timed-out/dead `EvoGit.TaskRegistry` becomes `nil` instead of
  crashing the caller (the assign is then re-seeded on the next navigation).
  """
  @spec load_terminal_ids() :: MapSet.t(String.t()) | nil
  def load_terminal_ids do
    case SafeCall.run(fn -> TaskRegistry.list_task_ids(@terminal_statuses) end) do
      {:ok, rows} -> rows |> Enum.map(& &1.id) |> MapSet.new()
      {:error, _reason} -> nil
    end
  end

  @doc """
  Starts the notification scan in one supervised task and returns whatever
  `Task.Supervisor.start_child/2` returns.

  The scan runs OUTSIDE the LiveView process; its outcome always lands as
  `{:task_notifications, seq, node, result}` where `result` is
  `{:ok, {new_ids, notifications}}` or an `EvoDash.SafeCall` error tuple.
  `seq`/`node` are echoed back verbatim for the caller's stale-guards.
  """
  @spec spawn_scan(pid(), non_neg_integer(), node(), MapSet.t(String.t())) ::
          {:ok, pid()} | {:error, term()}
  def spawn_scan(parent, seq, node, known_ids) do
    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> scan_new(known_ids) end)
      send(parent, {:task_notifications, seq, node, result})
    end)
  end

  # Terminal ids not yet in `known_ids`, plus one `{id, title, body}`
  # notification per id that still resolves to a task row. An id whose
  # `get_task_lite/1` returns nil is still reported in `new_ids` (it gets
  # marked notified and produces no notification — the id vanished between
  # queries). Lite is enough here: `task_notification_content/1` reads only
  # `opts`/`result`/`type`.
  defp scan_new(known_ids) do
    new_ids =
      TaskRegistry.list_task_ids(@terminal_statuses)
      |> Enum.map(& &1.id)
      |> Enum.reject(&MapSet.member?(known_ids, &1))

    notifications =
      Enum.flat_map(new_ids, fn id ->
        case TaskRegistry.get_task_lite(id) do
          %EvoGit.TaskInfo{} = task ->
            {title, body} = Project.task_notification_content(task)
            [{id, title, body}]

          _ ->
            []
        end
      end)

    {new_ids, notifications}
  end
end
