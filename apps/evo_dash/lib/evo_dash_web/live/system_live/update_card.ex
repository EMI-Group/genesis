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

  ## Busy tasks vs idle interactive sessions

  The BUSY set for update gating is exactly
  `[:running, :pending, :cancelling, :finalizing]` — tasks that can still do
  work while the update is applied.

  A NON-TERMINAL but IDLE interactive agent session (`:awaiting_input`) is
  deliberately NOT busy: it holds no exchange worker, no LLM/tool slot and no
  timer, so it cannot make progress on its own and must never block the update
  gate (nor is it counted by `/server/status`). The wind-down therefore ASKS
  such sessions to CLOSE gracefully — `EvoDash.NodeContext.close_session/3`,
  the only non-cancellation way out of `:awaiting_input` (completion
  bookkeeping runs once, the session stops, the worktree is released) — instead
  of force-killing them. An idle session holds no in-flight work to lose, so a
  force kill would be needless data loss.

  A session that never closes must not wedge the busy modal, so an idle session
  blocks completion for at most 3 wind-down polls
  (`@session_close_grace_polls`); after that grace it simply stops counting and
  the wind-down completes, leaving the session alive for the user.

  The user-warned FORCE-KILL fallback deliberately does NOT touch idle sessions
  (they are safe to leave running) — it only force-kills busy tasks.

  Every store/registry call the gate and the wind-down need goes through
  `EvoDash.SafeCall`: a `GenServer.call` to the task registry that times out
  EXITS its caller (`rescue` cannot catch that), which would either crash the
  LiveView or kill a supervised task before it reports back — leaving the busy
  modal or the gate spinner wedged. The `start_*` helpers run their work in ONE
  `EvoDash.TaskSupervisor` task and always report a result, so the LiveView can
  clear its in-progress flag unconditionally.
  """

  alias EvoDash.SafeCall
  alias EvoDash.UpdateStatus

  # Statuses that count as BUSY/active for update gating: the update can only be
  # applied when no task is in any of these states, because only these can still
  # do work (a worker is running, queued or finalizing).
  #
  # A non-terminal but IDLE interactive session (`:awaiting_input`) is
  # deliberately NOT in this set: it holds no worker, no LLM/tool slot and no
  # timer, so it is not busy and must never block the update gate. It is wound
  # down by a graceful CLOSE (see `close_session/1`), never a force kill.
  @active_statuses [:running, :pending, :cancelling, :finalizing]

  # How many wind-down polls an idle interactive session may hold up completion
  # before it stops blocking. A session that never closes must not wedge the busy
  # modal: after this grace it simply stops counting and the wind-down completes,
  # leaving the session alive for the user.
  @session_close_grace_polls 3

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

  The default branch runs inside `EvoDash.SafeCall.run/2`, so a store call that
  exits (call timeout / dead registry) degrades to `[]` instead of killing the
  caller. Callers on the LiveView process MUST use `start_active_task_ids/3`
  instead, so the query never runs on the LiveView process at all.
  """
  def active_task_ids(ctx) do
    case Application.get_env(:evo_dash, :update_active_task_ids) do
      nil ->
        SafeCall.run(
          fn ->
            EvoDash.NodeContext.list_task_ids(node(), @active_statuses)
            |> Enum.map(&task_id/1)
            |> Enum.reject(&is_nil/1)
          end,
          []
        )

      seam when is_function(seam, 1) ->
        seam.(ctx) |> List.wrap()

      list ->
        List.wrap(list)
    end
  end

  @doc """
  Runs `active_task_ids/1` for `ctx` in ONE supervised task, reporting
  `{tag, {:ok, ids} | {:error, reason}}` to `parent`.

  The exit-safe async form used by the LiveView's apply gate, so the store query
  never runs on the LiveView process and its result message is always sent
  (even on an exit), letting the gate spinner never stick.
  """
  def start_active_task_ids(parent, tag, ctx) do
    SafeCall.start(parent, tag, fn -> active_task_ids(ctx) end)
  end

  @doc """
  Returns the agent ids of idle interactive sessions (tasks in the NON-TERMINAL
  but IDLE `:awaiting_input` status).

  These sessions are NOT busy (no worker, no slot, no timer), so they never
  block the update gate; the wind-down asks them to close instead. `ctx` is
  `:gate` or `:winddown_poll`, mirroring `active_task_ids/1`.

  Test seam `config :evo_dash, :update_awaiting_session_ids` mirrors
  `:update_active_task_ids`: it may be (a) a plain list (used for both contexts)
  or (b) a one-arg fun `(ctx) -> ids`. Without the seam, the default branch runs
  INSIDE `EvoDash.SafeCall.run/2` (fallback `[]`) and maps
  `EvoDash.NodeContext.list_awaiting_input/1` rows to their agent ids.
  """
  def awaiting_session_ids(ctx \\ :winddown_poll) do
    case Application.get_env(:evo_dash, :update_awaiting_session_ids) do
      nil ->
        SafeCall.run(
          fn ->
            EvoDash.NodeContext.list_awaiting_input(node())
            |> Enum.map(&session_agent_id/1)
            |> Enum.reject(&is_nil/1)
          end,
          []
        )

      seam when is_function(seam, 1) ->
        seam.(ctx) |> List.wrap()

      list ->
        List.wrap(list)
    end
  end

  @doc """
  Spawns the never-wedge check watchdog on `EvoDash.TaskSupervisor`.

  The runner is a test seam (`config :evo_dash, :update_check_runner`, default
  `default_watchdog/1`); a raising — or exiting — runner is reported as a
  failed check so the `:checking` phase can never stick. When the seam replaces
  the default watchdog, the never-wedge timeout watchdog ALSO runs in parallel —
  otherwise a runner that never reports (e.g. the no-result test seam) would
  leave `:checking` stuck forever. In production the runner IS the default
  watchdog, so the extra task is not spawned.
  """
  def spawn_check_watchdog(view_pid) do
    runner = Application.get_env(:evo_dash, :update_check_runner) || (&default_watchdog/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      case SafeCall.run(fn -> runner.(view_pid) end) do
        {:ok, _result} -> :ok
        # A crashing runner must not wedge the :checking phase.
        {:error, _reason} -> UpdateStatus.check_failed("check_failed")
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
  cancels `ids` (the tasks the gate saw), then loops cancelling whatever busy
  task is still active and asking every idle interactive session
  (`:awaiting_input`) to close, until no busy task and no still-blocking session
  remains (or the deadline passes), and reports completion/timeout back to the
  view.

  Idle sessions are closed, never force-killed, and they hold up completion for
  at most `@session_close_grace_polls` polls (`:update_awaiting_session_ids`
  seam), so a session that never closes cannot wedge the modal.
  """
  def start_graceful_winddown(view_pid, ids) do
    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      case SafeCall.run(fn ->
             for id <- List.wrap(ids), do: graceful_cancel(id)
             winddown_loop(view_pid)
           end) do
        {:ok, _result} -> :ok
        # A crashed wind-down must not wedge the busy modal.
        {:error, reason} -> send(view_pid, {:update_winddown_error, reason})
      end
    end)
  end

  @doc """
  Starts the busy-apply wind-down without pre-cancelling anything (the
  wind-down loop itself cancels every active task it finds).
  """
  def start_winddown(view_pid) do
    start_graceful_winddown(view_pid, [])
  end

  @doc """
  Gracefully cancels a single task (3-turn grace, worktree auto-commit, results
  preserved as `:cancelled` and reviewable). Errors are ignored per call —
  unknown ids are normal in tests and racing completions.
  """
  def graceful_cancel(task_id) do
    SafeCall.run(fn -> EvoGit.TaskRegistry.cancel_task(task_id) end, :ok)
  end

  @doc """
  Asks ONE idle interactive session to close gracefully — the graceful close
  path used by the wind-down, NEVER a force kill: an idle session holds no
  in-flight work to lose, and closing is the only non-cancellation way out of
  `:awaiting_input`.

  Per-call errors are ignored (a session that already closed or a racing close
  is normal), and the call is exit-safe so one failing session cannot abort the
  rest of the list.
  """
  def close_session(agent_id) do
    SafeCall.run(
      fn -> EvoDash.NodeContext.close_session(node(), agent_id, :normal) end,
      :ok
    )
  end

  @doc """
  Force-kills the given task ids — the user-warned fallback ("in-flight work
  will be lost"). Results are ignored, and every call is exit-safe so one dead
  registry process cannot abort the rest of the list.
  """
  def force_kill(ids) do
    for id <- List.wrap(ids) do
      SafeCall.run(fn -> EvoGit.TaskRegistry.force_kill_task(id) end)
    end

    :ok
  end

  @doc """
  Force-kills every active task — the user-warned fallback ("in-flight work
  will be lost"). Results are ignored.
  """
  def force_kill_all do
    force_kill(active_task_ids(:gate))
  end

  @doc """
  Runs the force-kill fallback in ONE supervised task (never on the LiveView
  process) and reports `{{:update_force_kill_done, node}, {:ok, :ok} |
  {:error, reason}}` to `parent`.
  """
  def start_force_kill(parent, node) do
    SafeCall.start(parent, {:update_force_kill_done, node}, fn -> force_kill_all() end)
  end

  # Maps one `list_task_ids/2` row to its id (atom- or string-keyed, any other
  # shape dropped) so a single odd row can never crash the gate.
  defp task_id(%{id: id}), do: id
  defp task_id(%{"id" => id}), do: id
  defp task_id(_row), do: nil

  # Maps one `list_awaiting_input/1` row to its agent id (atom- or string-keyed,
  # any other shape dropped) so a single odd row can never crash the wind-down.
  defp session_agent_id(%{agent_id: id}), do: id
  defp session_agent_id(%{"agent_id" => id}), do: id
  defp session_agent_id(_row), do: nil

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

  # Wind-down loop: cancels whatever busy task is active, asks every idle
  # interactive session to close, polls until none remain, then reports
  # completion. The deadline bounds the wait (~35min default — plan: grace is
  # not wall-clock bounded; LLM retries ~9min, per-tool cap 30min). Idle
  # sessions are bounded separately by `@session_close_grace_polls`, so one that
  # never closes cannot wedge the modal.
  defp winddown_loop(view_pid) do
    deadline =
      System.monotonic_time(:millisecond) +
        Application.get_env(:evo_dash, :update_winddown_timeout, 2_100_000)

    do_winddown_loop(view_pid, deadline, %{})
  end

  defp do_winddown_loop(view_pid, deadline, session_waits) do
    ids = active_task_ids(:winddown_poll)

    # Keep cancelling newly-appearing tasks so nothing starts mid-wind-down.
    for id <- ids do
      graceful_cancel(id)
    end

    # IDLE interactive sessions are ASKED TO CLOSE, never force-killed: they
    # hold no in-flight work to lose, and closing is the only
    # non-cancellation way out of `:awaiting_input`.
    session_ids = awaiting_session_ids(:winddown_poll)

    # Per-call errors are ignored (already-closed / racing closes are normal).
    for sid <- session_ids do
      close_session(sid)
    end

    # Count polls only for sessions still present: a session that disappeared is
    # dropped from the map, so a re-appearing one starts its grace window fresh.
    session_waits =
      Map.new(session_ids, fn sid -> {sid, Map.get(session_waits, sid, 0) + 1} end)

    # A session blocks completion only while inside its grace window; after that
    # it stops counting and the wind-down may complete with it still alive.
    still_blocking =
      for {sid, polls} <- session_waits, polls <= @session_close_grace_polls, do: sid

    cond do
      ids == [] and still_blocking == [] ->
        send(view_pid, {:update_winddown_complete})

      System.monotonic_time(:millisecond) > deadline ->
        send(view_pid, {:update_winddown_timeout, length(ids) + length(still_blocking)})

      true ->
        Process.sleep(Application.get_env(:evo_dash, :update_winddown_poll_ms, 5_000))
        do_winddown_loop(view_pid, deadline, session_waits)
    end
  end
end
