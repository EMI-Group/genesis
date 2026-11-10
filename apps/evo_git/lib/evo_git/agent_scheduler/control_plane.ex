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
      `{agent_id, cancel_requested}` (2-tuple, so the writer updates the flag
      atomically with `:ets.update_element/3`).

  Both tables are created by `EvoGit.Application` (app-owned, `:public`), so
  they survive an `AgentScheduler` crash/restart.

  Consumers: `EvoGit.Agent.Session` (the running exchange), plus
  `EvoGit.AgentScheduler.Store.drain_pending_user_messages/1` and
  `Store.cancel_requested?/1`, which are the only entry points other callers
  use.

  Every function here is TOTAL: a missing table (app shutdown) reads as its
  empty value and answers a write with `{:error, :not_found}`; nothing in this
  module raises.
  """

  alias EvoGit.Attachments

  @inbox :evogit_agent_inbox
  @control :evogit_agent_control
  @agent_table :evogit_agent_summary

  @typedoc "The queue tolerates both message shapes (see `Store.append_pending_user_message/2`)."
  @type message :: String.t() | Attachments.message()

  # ---------------------------------------------------------------------------
  # Table names
  # ---------------------------------------------------------------------------

  @doc "The inbox table name (a `:bag` of `{agent_id, {seq, message}}`)."
  @spec inbox_table() :: atom()
  def inbox_table, do: @inbox

  @doc "The control table name (a `:set` of `{agent_id, cancel_requested}`)."
  @spec control_table() :: atom()
  def control_table, do: @control

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
  # Control row — cancel flag
  # ---------------------------------------------------------------------------

  @doc """
  Ensures the agent has a control row (`{agent_id, nil}`), idempotently.

  `:ets.insert_new/2` only writes when the key is absent, so an existing flag
  is never reset.
  """
  @spec ensure_row(pos_integer()) :: :ok | {:error, :not_found}
  def ensure_row(agent_id) do
    if table_exists?(@control) do
      :ets.insert_new(@control, {agent_id, nil})
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Sets the agent's `cancel_requested` flag (`true` | `false` | `nil`).

  One atomic single-element update (`:ets.update_element/3`) — the agent's state
  row is never touched. Returns `{:error, :not_found}` when the agent is not
  live.
  """
  @spec set_cancel(pos_integer(), boolean() | nil) :: :ok | {:error, :not_found}
  def set_cancel(agent_id, value) when value in [true, false, nil] do
    with true <- agent_row?(agent_id),
         :ok <- ensure_row(agent_id),
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
      nil -> false
    end
  end

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

  defp agent_row?(agent_id) do
    table_exists?(@agent_table) and :ets.member(@agent_table, agent_id)
  end

  defp table_exists?(table), do: :ets.whereis(table) != :undefined
end
