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
  def recycle_agent(state, agent_id) do
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
  def cancel_agent(state, agent_id) do
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

  # --- Crash Handling ---

  @doc """
  Handles an agent crash by either retrying the agent or marking it as permanently failed.

  On retry: keeps the persistent worktree, increments retry count, and re-dispatches.
  On permanent failure: deletes the worktree, cleans up ETS, and notifies the parent
  (for subagents) or replies with an error (for top-level agents).
  """
  @spec handle_agent_crash(State.t(), pos_integer(), term()) :: {:noreply, State.t()}
  def handle_agent_crash(state, agent_id, reason) do
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
    Logger.error(
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{meta.retries}/#{state.agent_max_retries}"
    )

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
        {:ok, agent_state} ->
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
        try do
          if state.paused do
            %{state | queue: :queue.in(agent_id, state.queue)}
          else
            Dispatch.try_dispatch(state, agent_id)
          end
        rescue
          e ->
            Logger.error(
              "AgentScheduler: Failed to retry dispatch for agent #{agent_id}: #{inspect(e)}. " <>
                "Treating as permanent failure."
            )

            # Clean up and permanently fail the agent
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
            updated_state = state

            updated_state =
              if meta.parent_id do
                Subagents.store_sub_result(
                  meta.parent_id,
                  agent_id,
                  {:error, :worktree_creation_failed}
                )

                Subagents.maybe_resume_parent(updated_state, meta.parent_id)
              else
                GenServer.reply(meta.from, {:error, :worktree_creation_failed})
                updated_state
              end

            updated_state
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
end
