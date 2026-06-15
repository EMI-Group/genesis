defmodule EvoGit.AgentScheduler.Lifecycle do
  @moduledoc """
  Agent lifecycle management for the AgentScheduler.

  Handles agent recycling (cleanup on normal completion) and crash recovery
  (retry logic, permanent failure handling, and parent notification).
  """

  require Logger

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.Subagents

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta

  # --- Agent Recycling ---

  @doc """
  Recycles an agent by deleting its worktree and removing both ETS entries.

  Called on normal completion or when an agent's result has already been sent.
  Decrements the running count.
  """
  @spec recycle_agent(State.t(), pos_integer()) :: State.t()
  def recycle_agent(state, agent_id) do
    {:ok, meta} = get_sched_meta(agent_id)

    # Resolve repo_root from the agent's own ETS state (correct even when
    # multiple tasks target different repos concurrently). No global fallback
    # — if the per-agent state is missing, skip worktree deletion.
    {:ok, %{repo_root: agent_repo_root}} = get_agent_state(agent_id)
    # Delete the agent's persistent worktree
    if meta.worktree && agent_repo_root do
      Worktrees.delete(meta.worktree, agent_repo_root)
    end

    delete_agent_state(agent_id)
    delete_sched_meta(agent_id)
    %{state | running_count: state.running_count - 1}
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
    case get_sched_meta(agent_id) do
      {:ok, meta} ->
        # Kill the agent's Task process if it has one and is alive
        if meta.task_ref do
          # The task_ref is actually a Task struct with .pid and .ref fields
          case meta.task_ref do
            %Task{pid: pid} when is_pid(pid) ->
              if Process.alive?(pid) do
                Task.shutdown(meta.task_ref, :brutal_kill)
              end

            _ ->
              :ok
          end
        end

        # Reply to the top-level caller (EvoDash Task process) if not yet replied
        if meta.from do
          GenServer.reply(meta.from, {:error, :cancelled})
        end

        # Reply to the sub_agent_from caller (parent waiting for spawn_sub_agents)
        if meta.sub_agent_from do
          GenServer.reply(meta.sub_agent_from, {:error, :cancelled})
        end

        # Delete worktree
        {:ok, %{repo_root: agent_repo_root}} = get_agent_state(agent_id)

        if meta.worktree && agent_repo_root do
          Worktrees.delete(meta.worktree, agent_repo_root)
        end

        # Remove ETS entries
        delete_agent_state(agent_id)
        delete_sched_meta(agent_id)

        # Decrement running count
        %{state | running_count: max(state.running_count - 1, 0)}

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
    {:ok, meta} = get_sched_meta(agent_id)

    Logger.error(
      "AgentScheduler: Agent #{agent_id} crashed: #{inspect(reason)}. " <>
        "Retry #{meta.retries}/#{state.agent_max_retries}"
    )

    if meta.retries < state.agent_max_retries do
      # On retry, keep the persistent worktree - just update retry count and status
      # The worktree will be reused on next dispatch (assign_and_prepare_worktree will clean/checkout)
      put_sched_meta(agent_id, %{
        meta
        | retries: meta.retries + 1,
          status: :pending,
          task_ref: nil
      })

      # Reset agent state phylo_node (will be re-set on dispatch)
      {:ok, agent_state} = get_agent_state(agent_id)
      put_agent_state(agent_id, %AgentState{agent_state | phylo_node: nil, context: nil})

      # Wrap dispatch in try/rescue to prevent GenServer crash on worktree creation failure
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
              case get_agent_state(agent_id) do
                {:ok, %{repo_root: root}} when is_binary(root) -> root
                _ -> nil
              end

            if meta.worktree && agent_repo_root do
              Worktrees.delete(meta.worktree, agent_repo_root)
            end

            delete_agent_state(agent_id)
            delete_sched_meta(agent_id)
            updated_state = %{state | running_count: state.running_count - 1}

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
        case get_agent_state(agent_id) do
          {:ok, %{repo_root: root}} when is_binary(root) -> root
          _ -> nil
        end

      if meta.worktree && agent_repo_root do
        Worktrees.delete(meta.worktree, agent_repo_root)
      end

      delete_agent_state(agent_id)
      delete_sched_meta(agent_id)
      state = %{state | running_count: state.running_count - 1}

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

  # --- Private ETS Helpers ---

  defp get_sched_meta(agent_id) do
    case :ets.lookup(@sched_table, agent_id) do
      [{^agent_id, %SchedMeta{} = meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  defp put_sched_meta(agent_id, meta) do
    :ets.insert(@sched_table, {agent_id, meta})
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end

  defp delete_sched_meta(agent_id) do
    :ets.delete(@sched_table, agent_id)
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end

  defp get_agent_state(agent_id) do
    case :ets.lookup(@agent_table, agent_id) do
      [{^agent_id, %AgentState{} = agent_state}] -> {:ok, agent_state}
      [] -> :error
    end
  end

  defp put_agent_state(agent_id, agent_state) do
    :ets.insert(@agent_table, {agent_id, agent_state})
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end

  defp delete_agent_state(agent_id) do
    :ets.delete(@agent_table, agent_id)
    EvoGit.AgentScheduler.PubSub.broadcast_agents_updated()
  end
end
