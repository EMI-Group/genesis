defmodule EvoGit.AgentScheduler.Lifecycle do
  @moduledoc """
  Agent lifecycle management for the AgentScheduler.

  Handles agent recycling (cleanup on normal completion) and crash recovery
  (retry logic, permanent failure handling, and parent notification).
  """

  require Logger

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Slots
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Subagents

  # --- Close Waiters (EvoGit.AgentScheduler.await_close/2) ---

  @doc """
  Registers a caller blocked in `EvoGit.AgentScheduler.await_close/2`.

  Waiters live on the scheduler state, keyed by agent id, and are flushed
  EXACTLY ONCE by whichever terminal outcome reaches this module first
  (`handle_session_result/3`, the permanent crash-failure path,
  `cancel_agent/2`, or `recycle_agent/2`).

  The caller pid (`elem(from, 0)`) is the budget: dead entries are pruned, and
  one entry is kept per caller pid (the newest), so a caller that awaits twice
  sees one reply and the map cannot grow without bound. Total — never raises,
  and a dead caller is simply not registered.
  """
  @spec register_close_waiter(State.t(), pos_integer(), GenServer.from()) :: State.t()
  def register_close_waiter(%State{} = state, agent_id, from) when is_tuple(from) do
    case elem(from, 0) do
      caller when is_pid(caller) -> do_register_close_waiter(state, agent_id, caller, from)
      _other -> state
    end
  end

  # Total: an unexpected `from` shape is never registered and never raises.
  def register_close_waiter(%State{} = state, _agent_id, _from), do: state

  defp do_register_close_waiter(state, agent_id, caller, from) do
    existing =
      state.close_waiters
      |> Map.get(agent_id, [])
      |> Enum.reject(fn {pid, _from} -> pid == caller or not Process.alive?(pid) end)

    waiters = if Process.alive?(caller), do: existing ++ [{caller, from}], else: existing

    %{state | close_waiters: put_waiters(state.close_waiters, agent_id, waiters)}
  end

  @doc """
  Replies to every caller waiting in `EvoGit.AgentScheduler.await_close/2` for
  `agent_id` with `reply_term`, then forgets them.

  A missing key (or an empty list) is a no-op. Flushed exactly once by
  construction: the key is deleted in the same step.
  """
  @spec flush_close_waiters(State.t(), pos_integer(), term()) :: State.t()
  def flush_close_waiters(%State{} = state, agent_id, reply_term) do
    {waiters, remaining} = Map.pop(state.close_waiters, agent_id)

    Enum.each(waiters || [], fn {_pid, from} -> GenServer.reply(from, reply_term) end)

    %{state | close_waiters: remaining}
  end

  defp put_waiters(waiters_map, _agent_id, []), do: waiters_map
  defp put_waiters(waiters_map, agent_id, waiters), do: Map.put(waiters_map, agent_id, waiters)

  # --- Agent Recycling ---

  @doc """
  Recycles an agent by removing both ETS entries.

  Called on normal completion or when an agent's result has already been sent.
  Decrements the running count. Worktree cleanup is WorktreeManager's job via
  its process monitor (the agent's session exited).

  Any close waiter still blocked on this agent (a session that ended WITHOUT
  delivering a result) is answered `{:error, :not_found}`.
  """
  @spec recycle_agent(State.t(), pos_integer()) :: State.t()
  def recycle_agent(%State{} = state, agent_id) do
    # Genuine race: the :DOWN completion may race with another cleanup path.
    # If the entry is already gone, return state unchanged.
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} ->
        # Best-effort phase mirror on the ONE finalize/recycle site; the rows are
        # deleted immediately after, and the session was the live phase owner.
        Store.put_sched_meta(agent_id, %{meta | phase: :done})
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)
        flush_close_waiters(state, agent_id, {:error, :not_found})

      :error ->
        Logger.info("AgentScheduler: recycle_agent for #{agent_id} — entry already cleaned up")
        flush_close_waiters(state, agent_id, {:error, :not_found})
    end
  end

  @doc """
  Cancels an agent by force-stopping its session and replying to blocked callers.

  Unlike `recycle_agent/2` (which assumes normal completion), this function:
  - Force-stops the agent's `EvoGit.Agent.Session` if still alive (via the
    stored `session_pid`)
  - Replies to the top-level `from` caller with `{:error, :cancelled}`
  - Replies to the `sub_agent_from` caller (waiting parent) with `{:error, :cancelled}`
  - Answers any `EvoGit.AgentScheduler.await_close/2` waiter with `{:error, :cancelled}`
  - Then removes the ETS entries

  Killing the session fires the WorktreeManager monitor, which reclaims the
  worktree.

  **Important**: The caller MUST remove the agent's ref from `state.ref_to_agent`
  BEFORE calling this function, otherwise the `:DOWN` handler will attempt to
  handle the killed process.
  """
  @spec cancel_agent(State.t(), pos_integer()) :: State.t()
  def cancel_agent(%State{} = state, agent_id) do
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} ->
        force_stop_session(meta.session_pid)

        # Reply to the top-level caller (EvoDash Task process) if not yet replied
        if meta.from do
          GenServer.reply(meta.from, {:error, :cancelled})
        end

        # Reply to the sub_agent_from caller (parent waiting for spawn_sub_agents)
        if meta.sub_agent_from do
          GenServer.reply(meta.sub_agent_from, {:error, :cancelled})
        end

        # Flush close waiters BEFORE the rows disappear: a force cancel delivers
        # no session result, so this is their only terminal answer.
        state = flush_close_waiters(state, agent_id, {:error, :cancelled})

        # Remove ETS entries
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)

        state

      :error ->
        # Agent already cleaned up, nothing to do
        state
    end
  end

  # `Session.cancel(pid, :force)` is the normal path: the session kills its
  # exchange worker and stops WITHOUT delivering a result, so no reply can race
  # the `{:error, :cancelled}` replies above. The call is BOUNDED, and a session
  # still stuck in `:starting` (blocked in the worktree-create call) answers
  # `{:error, :not_found}` — so anything other than `:ok` kills the still-alive
  # pid directly. A force cancel therefore never leaves a live session behind,
  # and a `nil` pid (registered but never dispatched) is a no-op.
  defp force_stop_session(pid) when is_pid(pid) do
    case EvoGit.Agent.Session.cancel(pid, :force) do
      :ok -> :ok
      _other -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp force_stop_session(_pid), do: :ok

  # --- Status Updates ---

  @doc """
  Applies a list of `{agent_id, status}` updates to the ETS SchedMeta table.
  Used by slot management to reflect blocked/running status in the dashboard.

  Only `:running <-> :blocked` transitions are applied. An agent in ANY other
  status — notably an interactive session parked at `:awaiting_input`, which is
  idle rather than running — is left untouched by a (late) slot update.
  """
  @spec apply_status_updates([{pos_integer(), atom()}]) :: :ok
  def apply_status_updates(status_updates) do
    Enum.each(status_updates, fn {agent_id, new_status} ->
      case Store.get_sched_meta(agent_id) do
        {:ok, meta} ->
          # Only update running agents to blocked (don't overwrite :waiting or :ready)
          # and only restore to :running from :blocked. `:awaiting_input` is idle,
          # never "running", so it is never overwritten in either direction.
          if (new_status == :blocked and meta.status == :running) or
               (new_status == :running and meta.status == :blocked) do
            Store.put_sched_meta(agent_id, %{meta | status: new_status})
          end

        :error ->
          :ok
      end
    end)
  end

  # --- Crash Handling ---

  @doc """
  Handles an agent crash by either retrying the agent or marking it as permanently failed.

  On retry: increments retry count and re-dispatches (the retry's session
  requests a FRESH worktree; the crashed agent's worktree is reclaimed by
  WorktreeManager via its monitor).
  On permanent failure: removes the ETS entries (worktree cleanup is
  monitor-driven) and notifies the parent (for subagents) or replies with an
  error (for top-level agents).
  """
  @spec handle_agent_crash(State.t(), pos_integer(), term()) :: {:noreply, State.t()}
  def handle_agent_crash(%State{} = state, agent_id, reason) do
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} ->
        do_handle_agent_crash(state, agent_id, reason, meta)

      :error ->
        Logger.warning(
          "AgentScheduler: Agent #{agent_id} crashed but no sched_meta found. Ignoring."
        )

        {:noreply, state}
    end
  end

  defp do_handle_agent_crash(state, agent_id, reason, meta) do
    Logger.error(fn ->
      if meta.mode == :interactive do
        "AgentScheduler: Agent #{agent_id} interactive session crashed: #{inspect(reason)}. " <>
          "Interactive sessions are never retried."
      else
        "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
          "Retry #{meta.retries}/#{state.agent_max_retries}"
      end
    end)

    if retry?(state, meta) do
      retry_agent(state, agent_id, meta)
    else
      failure_term = permanent_failure_term(meta, reason)
      log_permanent_failure(state, agent_id, reason, meta)
      permanent_failure(state, agent_id, failure_term, meta)
    end
  end

  # An INTERACTIVE session is never retried: its transcript lives only in the
  # crashed session process, so a retry would silently restart the conversation
  # from the first objective. A crash is terminal on the first attempt.
  # One-shot agents keep the existing bounded-retry policy byte-identically.
  defp retry?(%State{} = _state, %SchedMeta{mode: :interactive}), do: false
  defp retry?(%State{} = state, %SchedMeta{} = meta), do: meta.retries < state.agent_max_retries

  # The term the root caller / close waiter receives. One-shot keeps the
  # historical `:agent_max_retries_exceeded`; an interactive crash reports the
  # crash itself, because it was never retried.
  defp permanent_failure_term(%SchedMeta{mode: :interactive}, reason),
    do: {:error, {:session_crashed, reason}}

  defp permanent_failure_term(%SchedMeta{}, _reason), do: {:error, :agent_max_retries_exceeded}

  defp log_permanent_failure(_state, agent_id, reason, %SchedMeta{mode: :interactive}) do
    Logger.error(
      "AgentScheduler: Agent #{agent_id} interactive session failed (retries exhausted by policy). " <>
        "Last: #{inspect(reason)}"
    )
  end

  defp log_permanent_failure(state, agent_id, reason, %SchedMeta{}) do
    msg =
      "Agent #{agent_id} failed after #{state.agent_max_retries} retries. Last: #{inspect(reason)}"

    Logger.error("AgentScheduler: #{msg}")
  end

  defp retry_agent(state, agent_id, meta) do
    # On retry, just update retry count and status. The crashed agent's
    # worktree is reclaimed by WorktreeManager via its monitor; the retry's
    # session requests a FRESH worktree.
    Store.put_sched_meta(agent_id, %{
      meta
      | retries: meta.retries + 1,
        status: :pending,
        session_pid: nil,
        phase: nil
    })

    # Reset the summary row's commit (the retry's session rebuilds its state
    # from the fresh worktree on dispatch)
    case Store.get_agent_state(agent_id) do
      {:ok, %AgentState{} = agent_state} ->
        Store.put_agent_state(agent_id, %AgentState{agent_state | current_commit: nil})

      :error ->
        Logger.warning(
          "AgentScheduler: Agent #{agent_id} missing agent_state during retry, skipping reset."
        )

        :ok
    end

    # Re-dispatch the agent (the retry's session requests a fresh worktree).
    # Note: the crashed session's ref was already popped from ref_to_agent
    # in the :DOWN handler, so the derived running count is correct.
    state =
      if state.paused do
        %{state | queue: :queue.in(agent_id, state.queue)}
      else
        Dispatch.try_dispatch(state, agent_id)
      end

    state = Dispatch.process_queue(state)
    {:noreply, state}
  end

  defp permanent_failure(state, agent_id, failure_term, meta) do
    # Cleanup is monitor-driven — WorktreeManager reclaims the crashed
    # agent's worktree on process exit; the scheduler only removes the ETS
    # entries.
    Store.delete_agent_state(agent_id)
    Store.delete_sched_meta(agent_id)

    # Flush any `await_close/2` waiter BEFORE the rows disappear: this is their
    # only terminal answer on the crash path.
    state = flush_close_waiters(state, agent_id, failure_term)

    if meta.parent_id do
      Subagents.store_sub_result(meta.parent_id, agent_id, failure_term)

      state = Subagents.maybe_resume_parent(state, meta.parent_id)
      state = Dispatch.process_queue(state)
      {:noreply, state}
    else
      if meta.from do
        GenServer.reply(meta.from, failure_term)
      end

      state = %{state | task_agent_counts: Map.delete(state.task_agent_counts, meta.task_id)}
      state = Dispatch.process_queue(state)
      {:noreply, state}
    end
  end

  # --- Session Result Handling ---

  @doc """
  Handles the ONE terminal result a session delivers before it stops
  (`{:agent_session_result, agent_id, session_pid, result}`).
  Stores the result for subagents or replies to the top-level caller.

  Keyed on `agent_id` directly: the session names its agent, so no
  monitor-reference lookup is involved.

  A NIL `SchedMeta.from` is a supported shape: an INTERACTIVE root session is
  registered without a caller to reply to (`EvoGit.AgentScheduler.start_session/1`),
  so only its `EvoGit.AgentScheduler.await_close/2` waiters — flushed with the
  SAME post-injection terminal term — are answered.
  """
  @spec handle_session_result(pos_integer(), term(), State.t()) :: {:noreply, State.t()}
  def handle_session_result(agent_id, result, %State{} = state) do
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} ->
        Store.put_sched_meta(agent_id, %{meta | result_sent: true})

        # Inject this agent's subtree foreign-repo commit map into the result
        # BEFORE the parent/root split, so both the subagent path
        # (Subagents.store_sub_result rolls it up into the parent's map) and
        # the root reply path carry it.
        result = inject_foreign_repo_commits(result, meta.foreign_repo_commits)

        if meta.parent_id do
          Subagents.store_sub_result(meta.parent_id, agent_id, result, meta.spec)
          state = Subagents.maybe_resume_parent(state, meta.parent_id)
          {:noreply, state}
        else
          agent_count = Map.get(state.task_agent_counts, meta.task_id, 1)
          result = inject_agent_count(result, agent_count)

          # A `nil` `from` (interactive root) has no caller to reply to.
          if meta.from do
            GenServer.reply(meta.from, result)
          end

          # Close waiters receive the SAME terminal term the caller would have.
          state = flush_close_waiters(state, agent_id, result)

          state = %{
            state
            | task_agent_counts: Map.delete(state.task_agent_counts, meta.task_id)
          }

          {:noreply, state}
        end

      :error ->
        Logger.warning(
          "AgentScheduler: result for agent #{agent_id} but no sched_meta found. Ignoring."
        )

        {:noreply, state}
    end
  end

  @doc """
  Handles a :DOWN monitor message for a crashed or completed agent session process.
  Releases slots, recycles/cleans up on normal exit, and triggers crash recovery
  on abnormal exit. (Worktree reclamation is WorktreeManager's job via its own
  process monitor on the session process.)
  """
  @spec handle_agent_down(reference(), pid(), term(), State.t()) :: {:noreply, State.t()}
  def handle_agent_down(ref, _pid, reason, %State{} = state) do
    case Map.pop(state.ref_to_agent, ref) do
      {nil, _} ->
        {:noreply, state}

      {agent_id, ref_to_agent} ->
        state = %{state | ref_to_agent: ref_to_agent}

        # Release any slots held by the dead agent and purge from queues.
        # This makes slot leaks impossible by construction — the holder sets
        # are cleaned up regardless of exit path.
        {state, slot_status} = Slots.release_agent_slots(state, agent_id)
        apply_status_updates(slot_status)

        case Store.get_sched_meta(agent_id) do
          {:ok, meta} ->
            if reason == :normal or meta.result_sent do
              state = recycle_agent(state, agent_id)
              state = Dispatch.process_queue(state)
              {:noreply, state}
            else
              handle_agent_crash(state, agent_id, reason)
            end

          :error ->
            Logger.warning(
              "AgentScheduler: :DOWN for agent #{agent_id} but no sched_meta found. Slots already released, ignoring."
            )

            {:noreply, state}
        end
    end
  end

  # --- Result Helpers ---

  @doc """
  Injects the agent count into a successful `%EvoGit.Agent.Result{}` tuple.
  Non-success results pass through unchanged.
  """
  def inject_agent_count({:ok, %EvoGit.Agent.Result{} = res}, agent_count) do
    {:ok, %{res | agent_count: agent_count}}
  end

  def inject_agent_count(result, _agent_count), do: result

  @doc """
  Injects the foreign repo commits map into a successful `%EvoGit.Agent.Result{}`
  tuple. Non-success results pass through unchanged.

  Uses `Map.put/3` (NOT struct update) because the `foreign_repo_commits` field
  is being introduced in parallel by the agent stream — it may not exist on the
  struct yet; `Map.put` is behaviorally identical once the field lands.
  """
  def inject_foreign_repo_commits({:ok, %EvoGit.Agent.Result{} = res}, commits)
      when is_map(commits) do
    {:ok, Map.put(res, :foreign_repo_commits, commits)}
  end

  def inject_foreign_repo_commits(result, _commits), do: result
end
