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
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.Subagents

  # --- Agent Recycling ---

  @doc """
  Recycles an agent by deleting its worktree and removing both ETS entries.

  Called on normal completion or when an agent's result has already been sent.
  Decrements the running count.
  """
  @spec recycle_agent(State.t(), pos_integer()) :: State.t()
  def recycle_agent(%State{} = state, agent_id) do
    # Genuine race: the :DOWN completion may race with another cleanup path.
    # If the entry is already gone, return state unchanged.
    with {:ok, meta} <- Store.get_sched_meta(agent_id),
         {:ok, %{repo_root: agent_repo_root}} <- Store.get_agent_state(agent_id) do
      if meta.worktree && agent_repo_root do
        Worktrees.delete(meta.worktree, agent_repo_root)
      end

      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
      state
    else
      _ ->
        Logger.info("AgentScheduler: recycle_agent for #{agent_id} — entry already cleaned up")
        state
    end
  end

  @doc """
  Cancels an agent by killing its Task process, replying to blocked callers,
  cleaning up worktree, and removing ETS entries.

  Unlike `recycle_agent/2` (which assumes normal completion), this function:
  - Kills the agent's Task process if still alive (via the stored task_ref)
  - Replies to the top-level `from` caller with `{:error, :cancelled}`
  - Replies to the `sub_agent_from` caller (waiting parent) with `{:error, :cancelled}`
  - Then performs the same cleanup as recycle_agent (delete worktree, ETS entries, decrement count)

  **Important**: The caller MUST remove the agent's ref from `state.ref_to_agent`
  BEFORE calling this function, otherwise the `:DOWN` handler will attempt to
  handle the killed process.
  """
  @spec cancel_agent(State.t(), pos_integer()) :: State.t()
  def cancel_agent(%State{} = state, agent_id) do
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} ->
        # Kill the agent's Task process if it has one and is alive
        if meta.task_ref do
          # task_ref is a %Task{} struct — Task.shutdown accepts it directly
          Task.shutdown(meta.task_ref, :brutal_kill)
        end

        # Reply to the top-level caller (EvoDash Task process) if not yet replied
        if meta.from do
          GenServer.reply(meta.from, {:error, :cancelled})
        end

        # Reply to the sub_agent_from caller (parent waiting for spawn_sub_agents)
        if meta.sub_agent_from do
          GenServer.reply(meta.sub_agent_from, {:error, :cancelled})
        end

        # Delete worktree — skip if agent_state is already gone (race with cleanup)
        agent_repo_root =
          case Store.get_agent_state(agent_id) do
            {:ok, %{repo_root: root}} -> root
            :error -> nil
          end

        if meta.worktree && agent_repo_root do
          Worktrees.delete(meta.worktree, agent_repo_root)
        end

        # Remove ETS entries
        Store.delete_agent_state(agent_id)
        Store.delete_sched_meta(agent_id)

        state

      :error ->
        # Agent already cleaned up, nothing to do
        state
    end
  end

  # --- Status Updates ---

  @doc """
  Applies a list of `{agent_id, status}` updates to the ETS SchedMeta table.
  Used by slot management to reflect blocked/running status in the dashboard.
  """
  @spec apply_status_updates([{pos_integer(), atom()}]) :: :ok
  def apply_status_updates(status_updates) do
    Enum.each(status_updates, fn {agent_id, new_status} ->
      case Store.get_sched_meta(agent_id) do
        {:ok, meta} ->
          # Only update running agents to blocked (don't overwrite :waiting or :ready)
          # and only restore to :running from :blocked
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

  On retry: keeps the persistent worktree, increments retry count, and re-dispatches.
  On permanent failure: deletes the worktree, cleans up ETS, and notifies the parent
  (for subagents) or replies with an error (for top-level agents).
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
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{meta.retries}/#{state.agent_max_retries}"
    end)

    if meta.retries < state.agent_max_retries do
      # On retry, keep the persistent worktree - just update retry count and status
      # The worktree will be reused on next dispatch (assign_and_prepare_worktree will clean/checkout)
      Store.put_sched_meta(agent_id, %{
        meta
        | retries: meta.retries + 1,
          status: :pending,
          task_ref: nil
      })

      # Reset agent state phylo_node (will be re-set on dispatch)
      case Store.get_agent_state(agent_id) do
        {:ok, %AgentState{} = agent_state} ->
          Store.put_agent_state(agent_id, %AgentState{agent_state | phylo_node: nil, context: nil})

        :error ->
          Logger.warning(
            "AgentScheduler: Agent #{agent_id} missing agent_state during retry, skipping reset."
          )

          :ok
      end

      # Re-dispatch the agent (worktree is persistent and reused).
      # Note: the crashed task's ref was already popped from ref_to_agent
      # in the :DOWN handler, so the derived running count is correct.
      state =
        if state.paused do
          %{state | queue: :queue.in(agent_id, state.queue)}
        else
          Dispatch.try_dispatch(state, agent_id)
        end

      state = Dispatch.process_queue(state)
      {:noreply, state}
    else
      msg =
        "Agent #{agent_id} failed after #{state.agent_max_retries} retries. Last: #{inspect(reason)}"

      Logger.error("AgentScheduler: #{msg}")

      # Delete the agent's persistent worktree on permanent failure
      agent_repo_root =
        case Store.get_agent_state(agent_id) do
          {:ok, %{repo_root: root}} when is_binary(root) -> root
          _ -> nil
        end

      if meta.worktree && agent_repo_root do
        Worktrees.delete(meta.worktree, agent_repo_root)
      end

      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)

      if meta.parent_id do
        Subagents.store_sub_result(
          meta.parent_id,
          agent_id,
          {:error, :agent_max_retries_exceeded}
        )

        state = Subagents.maybe_resume_parent(state, meta.parent_id)
        state = Dispatch.process_queue(state)
        {:noreply, state}
      else
        GenServer.reply(meta.from, {:error, :agent_max_retries_exceeded})
        state = %{state | task_agent_counts: Map.delete(state.task_agent_counts, meta.task_id)}
        state = Dispatch.process_queue(state)
        {:noreply, state}
      end
    end
  end

  # --- Task Result Handling ---

  @doc """
  Handles a task result from an agent's Task process.
  Stores the result for subagents or replies to the top-level caller.
  """
  @spec handle_task_result(reference(), term(), State.t()) :: {:noreply, State.t()}
  def handle_task_result(ref, result, %State{} = state) do
    case Map.get(state.ref_to_agent, ref) do
      nil ->
        {:noreply, state}

      agent_id ->
        case Store.get_sched_meta(agent_id) do
          {:ok, meta} ->
            Store.put_sched_meta(agent_id, %{meta | result_sent: true})

            if meta.parent_id do
              Subagents.store_sub_result(meta.parent_id, agent_id, result)
              state = Subagents.maybe_resume_parent(state, meta.parent_id)
              {:noreply, state}
            else
              agent_count = Map.get(state.task_agent_counts, meta.task_id, 1)
              result = inject_agent_count(result, agent_count)

              # Collect archive records for this task and inject into result
              archive_records = collect_archive_records(meta.task_id)
              result = inject_archive_records(result, archive_records)

              # Per-task collection is consumed at successful root completion;
              # a later run reusing the same task_id cannot re-collect stale
              # records. Non-success results retain their records — the
              # task-start reset covers them later.
              case result do
                {:ok, %EvoGit.Agent.Result{}} -> clear_archive_records(meta.task_id)
                _ -> :ok
              end

              GenServer.reply(meta.from, result)

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
  end

  @doc """
  Handles a :DOWN monitor message for a crashed or completed agent Task process.
  Releases slots, cleans up worktrees on normal exit, and triggers crash recovery
  on abnormal exit.
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
  Collects all archive records for the given task ID from the
  `:evogit_archive_records` ETS table.
  """
  def collect_archive_records(task_id) do
    Store.collect_archive_records(task_id)
  end

  @doc """
  Resets the per-task archive collection; called at task start (defensive) and
  after successful collection at root completion.
  """
  def clear_archive_records(task_id) do
    Store.clear_archive_records(task_id)
  end

  @doc """
  Injects archive records into a successful `%EvoGit.Agent.Result{}` tuple.
  Non-success results pass through unchanged.
  """
  def inject_archive_records({:ok, %EvoGit.Agent.Result{} = res}, records)
      when is_list(records) do
    {:ok, %{res | archive_records: records}}
  end

  def inject_archive_records(result, _records), do: result
end
