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
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.AgentScheduler.Subagents

  # --- Agent Registry ---

  @doc """
  Registers a new agent in the ETS tables and returns the agent ID and updated state.

  Assigns agent IDs, computes task-local IDs,
  and writes both the agent state and scheduler metadata ETS tables.
  """
  @spec register_agent(
          State.t(),
          AgentSpec.t(),
          GenServer.from() | nil,
          pos_integer() | nil,
          non_neg_integer(),
          String.t() | nil,
          pos_integer() | nil
        ) ::
          {pos_integer(), State.t()}
  def register_agent(state, spec, from, parent_id, depth, task_id, task_number) do
    id = state.next_agent_id

    # Compute per-task local agent ID (display/branch naming only)
    task_local_id = Map.get(state.task_local_counters, task_id, 1)

    state = %{
      state
      | task_local_counters: Map.put(state.task_local_counters, task_id, task_local_id + 1)
    }

    # Track total agents spawned per task (for stats reporting)
    state = %{
      state
      | task_agent_counts: Map.update(state.task_agent_counts, task_id, 1, &(&1 + 1))
    }

    # Agent state table: live spatial/temporal state for the agent process
    # Resolve repo root from the spec's own data (avoids reading shared mutable state)
    agent_repo_root = resolve_agent_repo_root(spec, state)

    Store.put_agent_state(id, %AgentState{
      context_node: spec.context_node,
      phylo_node: nil,
      llm_model: state.llm_model,
      llm_generation_params: state.llm_generation_params,
      max_retries: state.max_retries,
      max_depth: state.max_depth,
      max_turns: if(is_nil(parent_id), do: state.max_turns_root, else: state.max_turns),
      parent_id: parent_id,
      objective: spec.objective,
      repo_id: spec.repo_id,
      repo_root: agent_repo_root,
      task_local_id: task_local_id,
      archive: Keyword.get(spec.opts, :archive, false),
      foreign_repos: spec.foreign_repos
    })

    # Scheduler metadata table: scheduling bookkeeping
    Store.put_sched_meta(id, %SchedMeta{
      id: id,
      depth: depth,
      status: :pending,
      from: from,
      parent_id: parent_id,
      task_id: task_id,
      task_number: task_number,
      spec: spec
    })

    state = %{state | next_agent_id: id + 1}
    {id, state}
  end

  @doc """
  Computes the next task number by scanning the `.evogit/workers/` directory.
  Returns max+1 of existing `worker_T<n>_a<m>` entries, or 1 if none/empty.
  """
  @spec next_task_number(String.t()) :: pos_integer()
  def next_task_number(repo_root) do
    workers_dir = Path.join(repo_root, ".evogit/workers")

    case File.ls(workers_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&parse_task_number/1)
        |> Enum.filter(&(&1))
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      {:error, _} ->
        1
    end
  end

  defp parse_task_number("worker_T" <> rest) do
    rest
    |> String.split("_", parts: 2)
    |> List.first()
    |> String.to_integer()
  rescue
    _ -> nil
  end

  defp parse_task_number(_), do: nil

  # --- Dispatch ---

  @doc """
  Dispatches an agent by creating/assigning a worktree and spawning a Task.

  Creates a persistent worktree for the agent (if it doesn't exist), prepares it,
  runs the init script on first creation, and spawns the agent Task. Updates ETS
  with worktree assignment and running status.
  """
  @spec try_dispatch(State.t(), pos_integer()) :: State.t()
  def try_dispatch(state, agent_id) do
    # Bail cleanly if either ETS entry is missing — genuine race with cleanup.
    # Returns state unchanged rather than crashing the GenServer.
    with {:ok, meta} <- Store.get_sched_meta(agent_id),
         {:ok, agent_state} <- Store.get_agent_state(agent_id) do
      do_try_dispatch(state, agent_id, meta, agent_state)
    else
      _ ->
        Logger.debug("AgentScheduler: try_dispatch for #{agent_id} — entry missing, skipping")
        state
    end
  end

  defp do_try_dispatch(state, agent_id, meta, agent_state) do
    retries = meta.retries
    spec = meta.spec
    task_number = meta.task_number
    task_local_id = agent_state.task_local_id

    # Create a persistent worktree for this agent: worker_T<task_number>_A<task_local_id>
    # Determine repo root from the agent's spec data, with repos map as fallback
    agent_repo_root = resolve_agent_repo_root(spec, state)

    worktree_path =
      Path.join([agent_repo_root, ".evogit/workers", "worker_T#{task_number}_A#{task_local_id}"])

    # Create the worktree if it doesn't exist (e.g., on first dispatch)
    newly_created =
      unless File.exists?(worktree_path) do
        commit_sha = spec.phylo_node.current_commit
        branch_name = "evogit-agent-T#{task_number}-A#{task_local_id}"

        case Git.add_worktree(agent_repo_root, worktree_path, commit_sha, branch_name) do
          {:ok, _} ->
            Logger.info(
              "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} (T#{task_number}-A#{task_local_id}) on branch #{branch_name}"
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
          case Store.get_sched_meta(meta.parent_id) do
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
        Process.put(:evogit_started_at, DateTime.utc_now() |> DateTime.to_iso8601())

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

        # The agent process owns git operations. After the agent finishes
        # (any exit path), commit any pending changes as a best-effort
        # fallback so the worktree is clean before the scheduler processes
        # the result. The scheduler never touches git directly.
        try do
          spec.agent_module.run(spec.objective)
        after
          commit_pending_in_worktree()
        end
      end)

    # Update scheduler metadata with worktree assignment and running status.
    # Store the full %Task{} struct so cancel_agent can call Task.shutdown/2.
    # ref_to_agent still keys on task.ref (the monitor reference).
    Store.put_sched_meta(agent_id, %{
      meta
      | status: :running,
        worktree: worktree_path,
        task_ref: task
    })

    %{
      state
      | ref_to_agent: Map.put(state.ref_to_agent, task.ref, agent_id)
    }
  end

  # --- Auto-Commit Fallback (agent process) ---

  @doc """
  Best-effort commit of pending changes in the agent's worktree.

  Designed to run in the AGENT (Task) process — not the scheduler. Uses
  `Process.get(:repo_path)` for the worktree path. This is a safety net
  called after agent execution completes (normal or max-turns) and is the
  idiomatic place for a try/rescue: git may fail if the worktree is in a
  bad state, but that must not crash the agent.

  The scheduler process must NEVER call git directly.
  """
  @spec commit_pending_in_worktree() :: :ok
  def commit_pending_in_worktree do
    wt = Process.get(:repo_path)

    if wt do
      try do
        case Git.status(wt) do
          {:ok, ""} ->
            :ok

          {:ok, _changes} ->
            Logger.info("Agent: Auto-committing pending changes in worktree #{wt}")

            {:ok, prev_sha} = Git.rev_parse(wt)

            Git.run(["add", "--all"], wt)
            Git.commit(wt, "Agent: auto-commit fallback")

            case Git.rev_parse(wt) do
              {:ok, ^prev_sha} ->
                Logger.debug("Agent: Auto-commit resulted in no new commit")

              {:ok, new_sha} ->
                case Git.diff_stat(wt, prev_sha, new_sha) do
                  {:ok, stats} when stats != "" ->
                    Logger.info("Agent: Auto-commit stats:\n#{stats}")

                  _ ->
                    :ok
                end
            end

            :ok

          _ ->
            :ok
        end
      rescue
        e ->
          Logger.warning(
            "Agent: Auto-commit fallback failed (best-effort, ignoring): #{inspect(e)}"
          )
      end
    end

    :ok
  end

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

        case Store.get_sched_meta(agent_id) do
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
end
