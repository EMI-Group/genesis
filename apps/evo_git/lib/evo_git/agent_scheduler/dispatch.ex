defmodule EvoGit.AgentScheduler.Dispatch do
  @moduledoc """
  Agent registration, dispatching, and queue processing for the AgentScheduler.

  Handles creating agent entries in ETS, dispatching agents to worktrees,
  auto-committing pending changes, and processing the agent queue.
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.AgentScheduler.Subagents

  @agent_table :evogit_agent_state
  @sched_table :evogit_sched_meta

  # --- Agent Registry ---

  @doc """
  Registers a new agent in the ETS tables and returns the agent ID and updated state.

  Assigns agent IDs, computes task-local IDs,
  and writes both the agent state and scheduler metadata ETS tables.
  """
  @spec register_agent(State.t(), AgentSpec.t(), GenServer.from() | nil, pos_integer() | nil, non_neg_integer(), pos_integer()) ::
          {pos_integer(), State.t()}
  def register_agent(state, spec, from, parent_id, depth, task_id) do
    id = state.next_agent_id

    # Compute per-task local agent ID (display/branch naming only)
    task_local_id = Map.get(state.task_local_counters, task_id, 1)
    state = %{state | task_local_counters: Map.put(state.task_local_counters, task_id, task_local_id + 1)}

    # Agent state table: live spatial/temporal state for the agent process
    # Resolve repo root from the spec's own data (avoids reading shared mutable state)
    agent_repo_root = resolve_agent_repo_root(spec, state)

    put_agent_state(id, %AgentState{
      context_node: spec.context_node,
      phylo_node: nil,
      llm_model: state.llm_model,
      max_retries: state.max_retries,
      max_depth: state.max_depth,
      max_turns: state.max_turns,
      parent_id: parent_id,
      objective: spec.objective,
      repo_id: spec.repo_id,
      repo_root: agent_repo_root,
      task_local_id: task_local_id,
      foreign_repos: spec.foreign_repos
    })

    # Scheduler metadata table: scheduling bookkeeping
    put_sched_meta(id, %SchedMeta{
      id: id,
      depth: depth,
      status: :pending,
      from: from,
      parent_id: parent_id,
      task_id: task_id,
      spec: spec
    })

    state = %{state | next_agent_id: id + 1}
    {id, state}
  end

  # --- Dispatch ---

  @doc """
  Dispatches an agent by creating/assigning a worktree and spawning a Task.

  Creates a persistent worktree for the agent (if it doesn't exist), prepares it,
  runs the init script on first creation, and spawns the agent Task. Updates ETS
  with worktree assignment and running status.
  """
  @spec try_dispatch(State.t(), pos_integer()) :: State.t()
  def try_dispatch(state, agent_id) do
    {:ok, meta} = get_sched_meta(agent_id)
    {:ok, agent_state} = get_agent_state(agent_id)
    retries = meta.retries
    spec = meta.spec
    task_id = meta.task_id
    task_local_id = agent_state.task_local_id

    # Create a persistent worktree for this agent: worker_T<task_id>_A<task_local_id>
    # Determine repo root from the agent's spec data, with repos map as fallback
    agent_repo_root = resolve_agent_repo_root(spec, state)

    worktree_path = Path.join([agent_repo_root, ".evogit/workers", "worker_T#{task_id}_A#{task_local_id}"])

    # Create the worktree if it doesn't exist (e.g., on first dispatch)
    newly_created =
      unless File.exists?(worktree_path) do
        commit_sha = spec.phylo_node.current_commit
        branch_name = "evogit-agent-T#{task_id}-A#{task_local_id}"

        case Git.add_worktree(agent_repo_root, worktree_path, commit_sha, branch_name) do
          {:ok, _} ->
            Logger.info(
              "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} (T#{task_id}-A#{task_local_id}) on branch #{branch_name}"
            )

          {:error, _, msg} ->
            Logger.error("AgentScheduler: Failed to create worktree #{worktree_path}: #{msg}")
            raise "Failed to create worktree for agent #{agent_id}"
        end

        true
      else
        false
      end

    Worktrees.assign_and_prepare_worktree(agent_id, worktree_path)

    # Run worktree init script on first creation only, and only for the primary repo
    # (foreign repos are independent and should not inherit the primary repo's init script)
    if newly_created and spec.repo_id == :primary do
      # Resolve parent worktree path for SOURCE_WORKTREE_PATH env var
      parent_worktree =
        if meta.parent_id do
          case get_sched_meta(meta.parent_id) do
            {:ok, parent_meta} -> parent_meta.worktree
            :error -> nil
          end
        else
          nil
        end

      Worktrees.run_init_script(agent_repo_root, worktree_path,
        source_worktree_path: parent_worktree || agent_repo_root
      )
    end

    task =
      Task.Supervisor.async_nolink(EvoGit.TaskSupervisor, fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:evogit_agent_depth, meta.depth)

        Process.put(:evogit_repo_root, agent_repo_root)
        Process.put(:evogit_repo_id, spec.repo_id)
        Process.put(:repo_path, worktree_path)

        if retries > 0 do
          Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
          Process.sleep(30_000 * retries)
        else
          Logger.info(
            "AgentScheduler: Agent #{agent_id} starting execution in worktree #{worktree_path}"
          )
        end

        spec.agent_module.run(spec.objective)
      end)

    # Update scheduler metadata with worktree assignment and running status
    put_sched_meta(agent_id, %{
      meta
      | status: :running,
        worktree: worktree_path,
        task_ref: task.ref
    })

    %{
      state
      | running_count: state.running_count + 1,
        ref_to_agent: Map.put(state.ref_to_agent, task.ref, agent_id)
    }
  end

  # --- Auto-Commit Fallback ---

  @doc """
  Commits any pending changes in the agent's worktree before a transition.

  Called before spawning subagents and on task completion to ensure a clean
  working tree. Returns the updated meta with synced commit SHA.
  """
  @spec auto_commit_fallback(pos_integer(), SchedMeta.t()) :: SchedMeta.t()
  def auto_commit_fallback(agent_id, %{status: :running, worktree: wt} = meta)
       when not is_nil(wt) do
    case Git.status(wt) do
      {:ok, ""} ->
        Worktrees.sync_current_commit(agent_id, meta)

      {:ok, _changes} ->
        Logger.info("AgentScheduler: Auto-committing pending changes for agent #{agent_id}")

        {:ok, prev_sha} = Git.rev_parse(wt)

        Git.run(["add", "--all"], wt)
        objective = meta.spec.objective || "task"
        Git.commit(wt, "Agent: #{objective} (auto-commit)")

        # Log diff stats for the auto-commit
        case Git.rev_parse(wt) do
          {:ok, ^prev_sha} ->
            Logger.debug(
              "AgentScheduler: Auto-commit for agent #{agent_id} resulted in no new commit"
            )

          {:ok, new_sha} ->
            case Git.diff_stat(wt, prev_sha, new_sha) do
              {:ok, stats} when stats != "" ->
                Logger.info("AgentScheduler: Auto-commit stats for agent #{agent_id}:\n#{stats}")

              _ ->
                :ok
            end
        end

        Worktrees.sync_current_commit(agent_id, meta)

      _ ->
        meta
    end
  end

  def auto_commit_fallback(_agent_id, meta), do: meta

  # --- Repo Root Resolution ---

  @doc """
  Resolves the repo root for an agent from its spec data.

  For primary repo agents, derives from phylo_node.repo (which is either
  the repo root for top-level agents or a worktree path for subagents).
  For foreign repo agents, looks up the foreign_repos map.
  """
  @spec resolve_agent_repo_root(AgentSpec.t(), State.t()) :: String.t() | nil
  def resolve_agent_repo_root(spec, _state) do
    if spec.repo_id == :primary do
      # spec.phylo_node.repo is either:
      # - A repo root (e.g., "/home/bill/Source/evoclass") for top-level agents
      # - A worktree path (e.g., ".../.evogit/workers/worker_T1_A1") for subagents
      # Derive the repo root by stripping the worktree suffix if present.
      case String.split(spec.phylo_node.repo, "/.evogit/workers/", parts: 2) do
        [root, _rest] -> root
        [_] -> spec.phylo_node.repo
      end
    else
      # Foreign repo — resolve from the spec's foreign_repos list
      spec.foreign_repos
      |> Enum.find(fn repo -> repo.id == spec.repo_id end)
      |> case do
        %ForeignRepo{root: root} -> root
        nil -> nil
      end
    end
  end

  # --- Queue Processing ---

  @doc """
  Drains the agent queue after a resume, dispatching each queued agent.
  """
  @spec dispatch_queued_agents(State.t()) :: State.t()
  def dispatch_queued_agents(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, agent_id}, rest_queue} ->
        state = %{state | queue: rest_queue}
        state = try_dispatch(state, agent_id)
        dispatch_queued_agents(state)

      {:empty, _} ->
        state
    end
  end

  @doc """
  Processes the agent queue, dispatching ready agents and resuming parent agents.
  """
  @spec process_queue(State.t()) :: State.t()
  def process_queue(%{paused: true} = state), do: state

  def process_queue(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, agent_id}, new_queue} ->
        state = %{state | queue: new_queue}

        case get_sched_meta(agent_id) do
          {:ok, %{status: :ready} = meta} ->
            # Ready parent agent - resume with its persistent worktree
            state = Subagents.dispatch_ready_parent(state, agent_id, meta)
            process_queue(state)

          {:ok, _meta} ->
            # Regular agent - dispatch with its persistent worktree
            state = try_dispatch(state, agent_id)
            process_queue(state)

          :error ->
            # Agent was already recycled; skip stale queue entry
            Logger.debug("AgentScheduler: Skipping stale queue entry for agent #{agent_id}")
            process_queue(state)
        end

      {:empty, _} ->
        state
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
end
