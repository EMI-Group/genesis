defmodule EvoGit.AgentScheduler.ControlPlane do
  @moduledoc """
  The per-agent CONTROL PLANE — the atomic transport for everything a process
  OTHER than the agent writes about a live agent.

  The agent's own state is a SUMMARY row with exactly ONE runtime writer: its
  `EvoGit.Agent.Session` (see `EvoGit.AgentScheduler.Store.put_agent_state/2`).
  Everything another process writes ABOUT a live agent lives in the two
  app-owned tables this module owns, so a cross-process write never
  read-modify-writes — and therefore never loses — the agent's own state row:

    * `:evogit_agent_inbox` — a `:bag` keyed by `agent_id`, object shape
      `{agent_id, {seq, message}}`. `seq` is a BEAM-monotonic integer, so a
      drain restores append order without holding a lock.
      Delivery is exactly-once by construction: `:ets.take/2` removes and
      returns every object for the key in ONE atomic BIF, so a concurrent
      append is either fully drained now or fully left for the next drain.
    * `:evogit_agent_control` — a `:set` keyed by `agent_id`, object shape
      `{agent_id, cancel_requested, pause_requested}` (3-tuple, so the writer
      updates ONE flag atomically with `:ets.update_element/3` — never a
      whole-struct read-modify-write, so the cancel and pause flags are
      independent of each other).
    * `:evogit_task_pause` — a `:set` of `{task_id}`: the TASK-level pause
      marker. `EvoGit.AgentScheduler.begin_task_pause/1` marks the task here
      BEFORE it flags the task's live agents, so an agent registered AFTER the
      pause began (a crash-retry, a subagent spawned just before the freeze, a
      late dispatch) is seeded with `pause_requested = true` by `ensure_row/1`
      instead of running a whole extra turn.

  All three tables are created by `EvoGit.Application` (app-owned, `:public`),
  so they survive an `AgentScheduler` crash/restart.

  Consumers: `EvoGit.Agent.Session` (the running exchange), plus
  `EvoGit.AgentScheduler.Store.drain_pending_user_messages/1`,
  `Store.cancel_requested?/1`, `Store.pause_requested?/1` and the task pause
  marker helpers, which are the only entry points other callers use.

  Every function here is TOTAL: a missing table (app shutdown) reads as its
  empty value and answers a write with `{:error, :not_found}`; nothing in this
  module raises.
  """

  alias EvoGit.Attachments

  @inbox :evogit_agent_inbox
  @control :evogit_agent_control
  @task_pause :evogit_task_pause
  @agent_table :evogit_agent_summary
  @sched_table :evogit_sched_meta

  @typedoc "The queue tolerates both message shapes (see `Store.append_pending_user_message/2`)."
  @type message :: String.t() | Attachments.message()

  # ---------------------------------------------------------------------------
  # Table names
  # ---------------------------------------------------------------------------

  @doc "The inbox table name (a `:bag` of `{agent_id, {seq, message}}`)."
  @spec inbox_table() :: atom()
  def inbox_table, do: @inbox

  @doc "The control table name (a `:set` of `{agent_id, cancel_requested, pause_requested}`)."
  @spec control_table() :: atom()
  def control_table, do: @control

  @doc "The task pause marker table name (a `:set` of `{task_id}`)."
  @spec task_pause_table() :: atom()
  def task_pause_table, do: @task_pause

  # ---------------------------------------------------------------------------
  # Inbox — pending user messages
  # ---------------------------------------------------------------------------

  @doc """
  Appends one message to the agent's inbox.

  A single atomic `:ets.insert/2` — no read — so concurrent appends can never
  overwrite each other. Returns `{:error, :not_found}` when the agent's state
  row (or the inbox table) is gone, mirroring the queue's "the agent must be
  live" contract: a message for a recycled agent is never queued.
  """
  @spec append_message(pos_integer(), message()) :: :ok | {:error, :not_found}
  def append_message(agent_id, message) do
    if agent_row?(agent_id) and table_exists?(@inbox) do
      :ets.insert(@inbox, {agent_id, {next_seq(), message}})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Removes and returns every pending message for the agent, in append order.

  `:ets.take/2` is ONE atomic BIF that removes all objects for the key, so a
  concurrent `append_message/2` is either fully included here or fully left for
  the next drain — never lost and never delivered twice. Returns `[]` when the
  agent has nothing pending or the table is gone.
  """
  @spec drain_messages(pos_integer()) :: [message()]
  def drain_messages(agent_id) do
    if table_exists?(@inbox) do
      @inbox
      |> :ets.take(agent_id)
      |> ordered_messages()
    else
      []
    end
  end

  @doc """
  Returns the agent's pending messages WITHOUT consuming them (a read-only peek),
  in append order. Returns `[]` when none are queued or the table is gone.
  """
  @spec pending_messages(pos_integer()) :: [message()]
  def pending_messages(agent_id) do
    if table_exists?(@inbox) do
      @inbox
      |> :ets.lookup(agent_id)
      |> ordered_messages()
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Control row — cancel + pause flags
  # ---------------------------------------------------------------------------

  @doc """
  Ensures the agent has a control row (`{agent_id, cancel_requested, pause_requested}`),
  idempotently.

  `:ets.insert_new/2` only writes when the key is absent, so an existing flag
  is never reset. The pause flag of a NEW row is SEEDED from the task pause
  marker: an agent registered for a task whose pause is already freezing starts
  with `pause_requested = true`, so a crash-retried or late-queued agent stops
  at its first turn boundary instead of running a whole extra turn.
  """
  @spec ensure_row(pos_integer()) :: :ok | {:error, :not_found}
  def ensure_row(agent_id) do
    if table_exists?(@control) do
      :ets.insert_new(@control, {agent_id, nil, initial_pause_flag(agent_id)})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Sets the agent's `cancel_requested` flag (`true` | `false` | `nil`).

  One atomic single-element update (`:ets.update_element/3`) — the agent's state
  row is never touched, and the pause flag on the same row is left untouched.
  A legacy/partial 2-tuple row is upgraded to the 3-tuple shape first, so a row
  written by an older build can never make the update fail.
  Returns `{:error, :not_found}` when the agent is not live.
  """
  @spec set_cancel(pos_integer(), boolean() | nil) :: :ok | {:error, :not_found}
  def set_cancel(agent_id, value) when value in [true, false, nil] do
    with true <- agent_row?(agent_id),
         :ok <- ensure_row_shape(agent_id),
         true <- :ets.update_element(@control, agent_id, {2, value}) do
      :ok
    else
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Returns whether a graceful cancel is pending for the agent (`== true`).

  `false` when the agent/row is absent or the flag is `nil`/`false`.
  """
  @spec cancel_requested?(pos_integer()) :: boolean()
  def cancel_requested?(agent_id) do
    case control_row(agent_id) do
      {_agent_id, value} -> value == true
      {_agent_id, value, _pause} -> value == true
      nil -> false
    end
  end

  @doc """
  Sets the agent's `pause_requested` flag (`true` | `false` | `nil`) — the
  TASK-PAUSE request an agent honours at a turn boundary (or while parked on its
  subagent batch).

  One atomic single-element update (`:ets.update_element/3`) on element 3, so it
  is independent of the cancel flag and never a whole-row read-modify-write.
  Returns `{:error, :not_found}` when the agent is not live.
  """
  @spec set_pause(pos_integer(), boolean() | nil) :: :ok | {:error, :not_found}
  def set_pause(agent_id, value) when value in [true, false, nil] do
    with true <- agent_row?(agent_id),
         :ok <- ensure_row_shape(agent_id),
         true <- :ets.update_element(@control, agent_id, {3, value}) do
      :ok
    else
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Returns whether a task pause is pending for the agent (`== true`).

  `false` when the agent/row is absent or the flag is `nil`/`false`.
  """
  @spec pause_requested?(pos_integer()) :: boolean()
  def pause_requested?(agent_id) do
    case control_row(agent_id) do
      {_agent_id, _cancel, pause} -> pause == true
      _other -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Task pause marker
  # ---------------------------------------------------------------------------

  @doc """
  Marks `task_id` as pausing (a task-level pause is freezing its agents).

  Total: an absent table (app shutdown) is a no-op. Idempotent.
  """
  @spec mark_task_pausing(String.t()) :: :ok
  def mark_task_pausing(task_id) when is_binary(task_id) do
    if table_exists?(@task_pause), do: :ets.insert(@task_pause, {task_id})
    :ok
  end

  @doc "Returns whether the task is marked as pausing. `false` for a missing table."
  @spec task_pausing?(String.t()) :: boolean()
  def task_pausing?(task_id) when is_binary(task_id) do
    table_exists?(@task_pause) and :ets.member(@task_pause, task_id)
  end

  def task_pausing?(_task_id), do: false

  @doc """
  Clears the task's pause marker.

  Called when the pause is abandoned — a cancel that arrives while `:pausing`
  wins, and a force-killed task must not leave the scheduler believing a pause
  is in progress — and when the freeze completes and the task becomes `:paused`.
  Idempotent, total.
  """
  @spec clear_task_pausing(String.t()) :: :ok
  def clear_task_pausing(task_id) when is_binary(task_id) do
    if table_exists?(@task_pause), do: :ets.delete(@task_pause, task_id)
    :ok
  end

  def clear_task_pausing(_task_id), do: :ok

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  @doc """
  Deletes the agent's inbox and control rows.

  Called from `EvoGit.AgentScheduler.Store.delete_agent_state/1` so the control
  plane never leaks rows for a finished agent.
  """
  @spec delete(pos_integer()) :: :ok
  def delete(agent_id) do
    if table_exists?(@inbox), do: :ets.delete(@inbox, agent_id)
    if table_exists?(@control), do: :ets.delete(@control, agent_id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # A BEAM-monotonic integer: appends within one BEAM are totally ordered, so a
  # drain can restore the exact append order without any lock or counter row.
  defp next_seq, do: System.unique_integer([:monotonic, :positive])

  defp ordered_messages(objects) do
    objects
    |> Enum.sort_by(fn {_agent_id, {seq, _message}} -> seq end)
    |> Enum.map(fn {_agent_id, {_seq, message}} -> message end)
  end

  defp control_row(agent_id) do
    if table_exists?(@control) do
      case :ets.lookup(@control, agent_id) do
        [row] -> row
        [] -> nil
      end
    end
  end

  # Guarantees the agent's control row is the 3-tuple shape BEFORE a single
  # element is updated. A legacy 2-tuple row (written by an older build) is
  # rewritten once, preserving its cancel flag and seeding the pause flag from
  # the task pause marker; a missing row is created; a 3-tuple row is left
  # exactly as it is (no write at all).
  defp ensure_row_shape(agent_id) do
    case control_row(agent_id) do
      {_agent_id, _cancel, _pause} ->
        :ok

      {_agent_id, cancel} ->
        _ = :ets.insert(@control, {agent_id, cancel, initial_pause_flag(agent_id)})
        :ok

      nil ->
        ensure_row(agent_id)
    end
  end

  # A NEW agent of a task whose pause is already freezing starts paused.
  # The task binding is the scheduler's own `SchedMeta.task_id` (the summary row
  # carries no task id); a missing row/table simply seeds nothing.
  defp initial_pause_flag(agent_id) do
    case task_id_for(agent_id) do
      task_id when is_binary(task_id) ->
        if task_pausing?(task_id), do: true, else: nil

      _other ->
        nil
    end
  end

  defp task_id_for(agent_id) do
    if table_exists?(@sched_table) do
      case :ets.lookup_element(@sched_table, agent_id, 2, nil) do
        %{task_id: task_id} -> task_id
        _other -> nil
      end
    end
  end

  defp agent_row?(agent_id) do
    table_exists?(@agent_table) and :ets.member(@agent_table, agent_id)
  end

  defp table_exists?(table), do: :ets.whereis(table) != :undefined
end
