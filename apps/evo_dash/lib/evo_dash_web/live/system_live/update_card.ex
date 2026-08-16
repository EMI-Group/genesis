defmodule EvoDashWeb.SystemLive.UpdateCard do
  @moduledoc """
  Software Update card support for `EvoDashWeb.SystemLive`.

  Mirrors the `review_live/MergeCheck` support-module pattern: the single-page
  LiveView stays lean while this module hosts the check/download/apply flows
  backed by the `EvoDash.UpdateStatus` hub — including the never-wedge check
  watchdog and the busy-apply wind-down (graceful-cancel) machinery.

  Integration surface with workstream B (the global JS hook): this module only
  ever pushes server→client request events (`update_check_requested` /
  `update_download_requested` / `update_apply_requested`); results arrive via
  hub broadcasts on the `"updates"` topic.
  """

  alias EvoDash.UpdateStatus

  # Statuses that count as "active" for update gating: the update can only be
  # applied when no task is in any of these states.
  @active_statuses [:running, :pending, :cancelling, :finalizing]

  @doc "Statuses considered active for update gating."
  def active_statuses, do: @active_statuses

  @doc "Whether the update card should render for the given node context."
  def visible?(node), do: UpdateStatus.visible?(node)

  @doc """
  Returns the ids of active tasks (running/pending/cancelling/finalizing).

  `ctx` is `:gate` (the apply gate, called from the LiveView event handler) or
  `:winddown_poll` (the wind-down loop). Test seam
  `config :evo_dash, :update_active_task_ids` may be (a) a plain list (used
  for both contexts) or (b) a one-arg fun `(ctx) -> ids`. Without the seam,
  delegates to the node-aware `EvoDash.NodeContext.list_task_ids/2` (local
  node → TaskRegistry under the hood), mapping each result map to its `:id`.
  """
  def active_task_ids(ctx) do
    case Application.get_env(:evo_dash, :update_active_task_ids) do
      nil ->
        EvoDash.NodeContext.list_task_ids(node(), @active_statuses)
        |> Enum.map(& &1.id)

      seam when is_function(seam, 1) ->
        seam.(ctx) |> List.wrap()

      list ->
        List.wrap(list)
    end
  end

  @doc """
  Spawns the never-wedge check watchdog on `EvoDash.TaskSupervisor`.

  The runner is a test seam (`config :evo_dash, :update_check_runner`, default
  `default_watchdog/1`); a raising runner is caught and reported as a failed
  check so the `:checking` phase can never stick. When the seam replaces the
  default watchdog, the never-wedge timeout watchdog ALSO runs in parallel —
  otherwise a runner that never reports (e.g. the no-result test seam) would
  leave `:checking` stuck forever. In production the runner IS the default
  watchdog, so the extra task is not spawned.
  """
  def spawn_check_watchdog(view_pid) do
    runner = Application.get_env(:evo_dash, :update_check_runner) || (&default_watchdog/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        runner.(view_pid)
      rescue
        # A crashing runner must not wedge the :checking phase.
        _ -> UpdateStatus.check_failed("check_failed")
      end
    end)

    if Application.get_env(:evo_dash, :update_check_runner) != nil do
      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        default_watchdog(view_pid)
      end)
    end

    :ok
  end

  @doc """
  Starts the busy-apply wind-down on `EvoDash.TaskSupervisor`: gracefully
  cancels active tasks in a loop until none remain (or the deadline passes),
  then reports completion/timeout back to the view.
  """
  def start_winddown(view_pid) do
    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        winddown_loop(view_pid)
      rescue
        # A crashed wind-down must not wedge the busy modal.
        _ -> send(view_pid, {:update_winddown_error, :check_failed})
      end
    end)
  end

  @doc """
  Gracefully cancels a single task (3-turn grace, worktree auto-commit, results
  preserved as `:cancelled` and reviewable). Errors are ignored per call —
  unknown ids are normal in tests and racing completions.
  """
  def graceful_cancel(task_id) do
    EvoGit.TaskRegistry.cancel_task(task_id)
  rescue
    _ -> :ok
  end

  @doc """
  Force-kills every active task — the user-warned fallback ("in-flight work
  will be lost"). Results are ignored.
  """
  def force_kill_all do
    for id <- active_task_ids(:gate) do
      EvoGit.TaskRegistry.force_kill_task(id)
    end

    :ok
  end

  @doc """
  Transitions the hub to `:applying` and pushes the apply request to the
  client (workstream B's JS hook invokes the Rust `begin_update` command).
  """
  def proceed_apply(socket) do
    UpdateStatus.applying()
    Phoenix.LiveView.push_event(socket, "update_apply_requested", %{})
  end

  # Default watchdog: waits out the check timeout, then fails the check if it
  # never completed. The CHECK step is bounded so the UI never wedges on a
  # spinner (the apply side's grace is deliberately NOT wall-clock bounded —
  # LLM retries ~9min, per-tool cap 30min).
  defp default_watchdog(_view_pid) do
    timeout = Application.get_env(:evo_dash, :update_check_timeout, 30_000)
    Process.sleep(timeout)

    if UpdateStatus.phase() == :checking do
      UpdateStatus.check_failed("timeout")
    end
  end

  # Wind-down loop: cancels whatever is active, polls until empty, then reports
  # completion. The deadline bounds the wait (~35min default — plan: grace is
  # not wall-clock bounded; LLM retries ~9min, per-tool cap 30min).
  defp winddown_loop(view_pid) do
    deadline =
      System.monotonic_time(:millisecond) +
        Application.get_env(:evo_dash, :update_winddown_timeout, 2_100_000)

    do_winddown_loop(view_pid, deadline)
  end

  defp do_winddown_loop(view_pid, deadline) do
    ids = active_task_ids(:winddown_poll)

    # Keep cancelling newly-appearing tasks so nothing starts mid-wind-down.
    for id <- ids do
      graceful_cancel(id)
    end

    cond do
      ids == [] ->
        send(view_pid, {:update_winddown_complete})

      System.monotonic_time(:millisecond) > deadline ->
        send(view_pid, {:update_winddown_timeout, length(ids)})

      true ->
        Process.sleep(Application.get_env(:evo_dash, :update_winddown_poll_ms, 5_000))
        do_winddown_loop(view_pid, deadline)
    end
  end
end
