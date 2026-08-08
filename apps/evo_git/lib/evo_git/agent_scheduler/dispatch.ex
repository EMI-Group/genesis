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
  def register_agent(
        %State{} = state,
        %AgentSpec{} = spec,
        from,
        parent_id,
        depth,
        task_id,
        task_number
      ) do
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

    # Resolve the model profile for this agent from spec.model_id,
    # falling back to the default profile from state.model_profiles.
    {resolved_model_id, resolved_model, resolved_params} =
      resolve_model_for_agent(state, spec.model_id)

    Store.put_agent_state(id, %AgentState{
      context_node: spec.context_node,
      phylo_node: nil,
      llm_model: resolved_model,
      llm_generation_params: resolved_params,
      model_id: resolved_model_id,
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
  Computes the next task number by scanning the `.genesis/workers/` directory.
  Returns max+1 of existing `worker_T<n>_a<m>` entries, or 1 if none/empty.
  """
  @spec next_task_number(String.t()) :: pos_integer()
  def next_task_number(repo_root) do
    workers_dir = Worktrees.workers_dir(repo_root)

    case File.ls(workers_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reduce(0, fn entry, max_acc ->
          case parse_task_number(entry) do
            nil -> max_acc
            n -> max(max_acc, n)
          end
        end)
        |> Kernel.+(1)

      {:error, _} ->
        1
    end
  end

  defp parse_task_number("worker_T" <> rest) do
    with [num_str | _] <- String.split(rest, "_", parts: 2),
         {n, _} <- Integer.parse(num_str) do
      n
    else
      _ -> nil
    end
  end

  defp parse_task_number(_), do: nil

  # --- Dispatch ---

  @doc """
  Dispatches an agent by computing the worktree path and spawning a Task.

  The GenServer phase (this function) is fast: it computes the worktree path,
  stores it in sched_meta (so cancel_agent can find the worktree), and spawns
  the agent Task. All blocking I/O — worktree creation, git clean/checkout,
  and the init script — runs inside the Task process, allowing multiple
  subagents to start up concurrently.
  """
  @spec try_dispatch(State.t(), pos_integer()) :: State.t()
  def try_dispatch(%State{} = state, agent_id) do
    # Bail cleanly if either ETS entry is missing — genuine race with cleanup.
    # Returns state unchanged rather than crashing the GenServer.
    with {:ok, meta} <- Store.get_sched_meta(agent_id),
         {:ok, agent_state} <- Store.get_agent_state(agent_id) do
      do_try_dispatch(state, agent_id, meta, agent_state)
    else
      _ ->
        Logger.info("AgentScheduler: try_dispatch for #{agent_id} — entry missing, skipping")
        state
    end
  end

  defp do_try_dispatch(state, agent_id, meta, agent_state) do
    retries = meta.retries
    spec = meta.spec
    task_local_id = agent_state.task_local_id

    # Phase 1 — GenServer phase (fast, no blocking I/O):
    # Compute the worktree path and store it in sched_meta BEFORE spawning the
    # task, so cancel_agent can find the worktree to clean up even if the task
    # hasn't finished its setup yet.
    agent_repo_root = resolve_agent_repo_root(spec, state)

    worktree_path =
      Path.join([
        agent_repo_root,
        ".genesis/workers",
        "worker_T#{meta.task_number}_A#{task_local_id}"
      ])

    Store.put_sched_meta(agent_id, %{meta | worktree: worktree_path})

    # Phase 2 — Task phase (slow, concurrent):
    # All blocking I/O (worktree creation, preparation, init script) runs
    # inside the task process, so multiple subagents start in parallel.
    dispatch_ctx = [
      agent_id: agent_id,
      depth: meta.depth,
      repo_root: agent_repo_root,
      repo_id: spec.repo_id,
      worktree_path: worktree_path,
      retries: retries,
      spec: spec,
      meta: meta
    ]

    task =
      Task.Supervisor.async_nolink(
        EvoGit.TaskSupervisor,
        spec.agent_module,
        :run,
        [spec.objective, dispatch_ctx]
      )

    # Update scheduler metadata with running status and the task reference.
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

  @doc """
  Performs worktree setup inside the agent (Task) process. This is the
  blocking I/O that runs concurrently across subagents:
    1. Create the worktree if it doesn't exist (Git.add_worktree)
    2. Prepare it (Git.clean + Git.checkout) via assign_and_prepare_worktree
    3. Run the init script on first creation (primary repo only)

  Called by the agent's `run/2` when a dispatch context is present.
  """
  def setup_worktree(agent_id, agent_repo_root, worktree_path, spec, meta) do
    task_number = meta.task_number
    {:ok, agent_state} = Store.get_agent_state(agent_id)
    task_local_id = agent_state.task_local_id

    # Create the worktree if it doesn't exist (e.g., on first dispatch)
    newly_created =
      unless File.exists?(worktree_path) do
        commit_sha = spec.phylo_node.current_commit
        branch_name = "evogit-agent-T#{task_number}-A#{task_local_id}"
        source_path = resolve_source_path(agent_repo_root, meta)

        # Try CoW-optimized creation first, fall back to standard method
        cow_result =
          if EvoGit.Adapters.CowWorktree.enabled?() do
            EvoGit.Adapters.CowWorktree.create_worktree(
              agent_repo_root,
              worktree_path,
              commit_sha,
              branch_name,
              source_path
            )
          else
            {:fallback, :disabled}
          end

        case cow_result do
          :ok ->
            Logger.info(
              "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} (T#{task_number}-A#{task_local_id}) on branch #{branch_name} via CoW"
            )

          {:fallback, reason} ->
            Logger.debug("AgentScheduler: Falling back to standard worktree creation (#{reason})")

            case Git.add_worktree(agent_repo_root, worktree_path, commit_sha, branch_name) do
              {:ok, _} ->
                Logger.info(
                  "AgentScheduler: Created worktree #{worktree_path} for agent #{agent_id} (T#{task_number}-A#{task_local_id}) on branch #{branch_name}"
                )

              {:error, {_, msg}} ->
                Logger.error("AgentScheduler: Failed to create worktree #{worktree_path}: #{msg}")
                raise "Failed to create worktree for agent #{agent_id}"
            end
        end

        true
      else
        false
      end

    Worktrees.assign_and_prepare_worktree(agent_id, worktree_path)

    # Run worktree init script on first creation only, and only for the primary repo
    # (foreign repos are independent and should not inherit the primary repo's init script)
    if newly_created and spec.repo_id == "primary" do
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
  end

  defp resolve_source_path(agent_repo_root, meta) do
    # For subagents: use the parent's worktree path (already has most files at same content)
    # For top-level agents: use the main repo root
    if meta.parent_id do
      case Store.get_sched_meta(meta.parent_id) do
        {:ok, parent_meta} when parent_meta.worktree != nil ->
          parent_meta.worktree

        _ ->
          agent_repo_root
      end
    else
      agent_repo_root
    end
  end

  # --- Auto-Commit Fallback (agent process) ---

  @doc """
  Best-effort commit of pending changes in the agent's worktree.

  Designed to run in the AGENT (Task) process — not the scheduler. Uses
  `Process.get(:repo_path)` for the worktree path. This is a safety net
  called after agent execution completes (normal or max-turns).

  Git can legitimately fail here (nothing to commit, worktree in a bad
  state, merge conflict state). We handle all git adapter error tuples
  explicitly via `with` rather than a broad rescue, so failures are logged
  but never crash the agent.

  The scheduler process must NEVER call git directly.
  """
  @spec commit_pending_in_worktree() :: :ok
  def commit_pending_in_worktree do
    if wt = Process.get(:repo_path) do
      do_commit_pending(wt)
    end

    :ok
  end

  defp do_commit_pending(wt) do
    with {:ok, changes} when changes != "" <- Git.status(wt),
         {:ok, prev_sha} <- Git.rev_parse(wt),
         {:ok, _} <- Git.run(["add", "--all"], wt),
         {:ok, _} <- Git.commit(wt, "Agent: auto-commit fallback") do
      Logger.info("Agent: Auto-committing pending changes in worktree #{wt}")

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

        _ ->
          :ok
      end
    else
      {:ok, ""} ->
        :ok

      error ->
        Logger.warning(
          "Agent: Auto-commit fallback failed (best-effort, ignoring): #{inspect(error)}"
        )
    end
  end

  # --- Model Profile Resolution ---

  @doc """
  Resolves the model profile for an agent based on the spec's `model_id`.

  If `model_id` is nil or empty, uses the default profile from `state.model_profiles`.
  If the requested `model_id` is not found in the profiles, falls back to the default.

  Returns `{model_id, model_spec, generation_params}`.
  """
  @spec resolve_model_for_agent(State.t(), String.t() | nil) ::
          {String.t(), ReqLLM.model_input(), keyword()}
  def resolve_model_for_agent(%State{} = state, model_id) do
    profiles = state.model_profiles

    profile =
      cond do
        # Explicit model_id provided and found
        model_id != nil and model_id != "" ->
          case Enum.find(profiles, fn p -> Map.get(p, :id) == model_id end) do
            nil ->
              Logger.warning(
                "AgentScheduler: Model profile '#{model_id}' not found, falling back to default"
              )

              List.first(profiles)

            found ->
              found
          end

        # No model_id — use default profile
        true ->
          List.first(profiles)
      end

    case profile do
      nil ->
        # No profiles configured at all — use state's backward-compat values
        {State.default_model_id(state), state.llm_model, state.llm_generation_params}

      profile ->
        resolved_id = Map.get(profile, :id, "default")
        model = Map.get(profile, :model, state.llm_model)
        params = EvoGit.Config.Schema.llm_generation_params(profile)
        {resolved_id, model, params}
    end
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
    if spec.repo_id == "primary" do
      # spec.phylo_node.repo is either:
      # - A repo root (e.g., "/home/bill/Source/evoclass") for top-level agents
      # - A worktree path (e.g., ".../.genesis/workers/worker_T1_A1") for subagents
      # Derive the repo root by stripping the worktree suffix if present.
      case String.split(spec.phylo_node.repo, "/.genesis/workers/", parts: 2) do
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
  def dispatch_queued_agents(%State{queue: queue} = state) do
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
  def process_queue(%State{paused: true} = state), do: state

  def process_queue(%State{queue: queue} = state) do
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
