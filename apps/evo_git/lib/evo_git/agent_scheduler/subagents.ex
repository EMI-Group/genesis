defmodule EvoGit.AgentScheduler.Subagents do
  @moduledoc """
  Subagent validation, spawning, and result tracking for the AgentScheduler.

  Handles validating subagent specs (depth, ignored paths, spatial contracts),
  spawning validated subagents with pre-delegation cleanliness checks,
  tracking subagent results, and resuming parent agents when all subagents complete.
  """

  require Logger

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Dispatch

  # --- Validation and Spawning ---

  @doc """
  Validates and spawns subagents. Each spec is validated independently;
  failed specs get an error result, valid specs are spawned.

  Performs pre-delegation cleanliness (auto-commit), marks the parent as :waiting,
  then validates and registers each subagent spec.
  """
  @spec spawn_validated_subagents(
          pos_integer(),
          SchedMeta.t(),
          [EvoGit.AgentSpec.t()],
          GenServer.from(),
          State.t()
        ) :: {:noreply, State.t()}
  def spawn_validated_subagents(parent_id, %SchedMeta{} = parent, specs, from, %State{} = state) do
    # Get parent agent state for validation context.
    # Parent entry may be reaped by cancel_agent while a subagent spawn is in flight.
    case Store.get_agent_state(parent_id) do
      {:ok, parent_agent_state} ->
        # Pre-Delegation Cleanliness: the parent agent commits its pending changes
        # BEFORE calling spawn_sub_agents (done in the agent process via
        # Dispatch.commit_pending_in_worktree/0, not in the scheduler).

        # Mark parent as :waiting
        Logger.info(
          "AgentScheduler: Agent #{parent_id} yielding to spawn #{length(specs)} subagents"
        )

        parent = %{parent | status: :waiting}
        Store.put_sched_meta(parent_id, parent)

        # Single reduce: validate, register, and build all collections in one pass
        {sub_ids_rev, sub_agent_indices, invalid_results, state} =
          specs
          |> Enum.with_index()
          |> Enum.reduce({[], %{}, %{}, state}, fn {spec, idx},
                                                   {sub_ids_rev, sub_agent_indices_acc,
                                                    invalid_acc, state_acc} ->
            case validate_single_subagent(parent_id, parent, spec, parent_agent_state, state) do
              :ok ->
                {sub_id, state_acc} =
                  Dispatch.register_agent(
                    state_acc,
                    spec,
                    _from = nil,
                    parent_id,
                    parent.depth + 1,
                    parent.task_id,
                    parent.task_number
                  )

                {[sub_id | sub_ids_rev], Map.put(sub_agent_indices_acc, sub_id, idx), invalid_acc,
                 state_acc}

              {:error, reason} ->
                Logger.warning(
                  "AgentScheduler: Subagent #{idx} failed validation: #{inspect(reason)}"
                )

                {sub_ids_rev, sub_agent_indices_acc, Map.put(invalid_acc, idx, {:error, reason}),
                 state_acc}
            end
          end)

        sub_ids = :lists.reverse(sub_ids_rev)

        # Track pending subagents, pre-failed results, and index mapping on the parent
        Store.put_sched_meta(parent_id, %{
          parent
          | sub_agent_from: from,
            total_sub_specs: length(specs),
            pending_sub_agents: MapSet.new(sub_ids),
            sub_agent_results: invalid_results,
            sub_agent_indices: sub_agent_indices
        })

        # Dispatch all valid subagents
        state = Enum.reduce(sub_ids, state, &Dispatch.try_dispatch(&2, &1))

        # If no valid subagents, immediately reply with all errors
        if sub_ids == [] do
          results = build_ordered_results(invalid_results, length(specs))
          GenServer.reply(from, results)
          Store.put_sched_meta(parent_id, %{parent | status: :running})
          {:noreply, state}
        else
          {:noreply, state}
        end

      :error ->
        Logger.warning(
          "AgentScheduler: Parent #{parent_id} recycled while spawning subagents; replying with errors"
        )

        results = Enum.map(specs, fn _ -> {:error, :parent_recycled} end)
        GenServer.reply(from, results)
        {:noreply, state}
    end
  end

  @doc """
  Validates a single subagent spec. All checks are per-subagent.
  """
  @spec validate_single_subagent(
          pos_integer(),
          SchedMeta.t(),
          EvoGit.AgentSpec.t(),
          AgentState.t(),
          State.t()
        ) :: :ok | {:error, term()}
  def validate_single_subagent(
        parent_id,
        %SchedMeta{} = parent,
        spec,
        parent_agent_state,
        %State{} = state
      ) do
    subagent_depth = parent.depth + 1

    with :ok <- validate_subagent_depth(parent_id, subagent_depth, state),
         :ok <- validate_subagent_not_ignored(spec),
         :ok <- validate_spatial_contract_for_spec(parent_id, parent_agent_state, spec) do
      :ok
    end
  end

  @doc """
  Checks if the subagent's depth exceeds the maximum allowed depth.
  """
  @spec validate_subagent_depth(pos_integer(), non_neg_integer(), State.t()) ::
          :ok | {:error, :max_depth_exceeded}
  def validate_subagent_depth(_parent_id, subagent_depth, state) do
    if subagent_depth > state.max_depth do
      Logger.warning(
        "AgentScheduler: Subagent depth #{subagent_depth} exceeds max #{state.max_depth}"
      )

      {:error, :max_depth_exceeded}
    else
      :ok
    end
  end

  @doc """
  Checks if the subagent's path is ignored by git.
  """
  @spec validate_subagent_not_ignored(EvoGit.AgentSpec.t()) :: :ok | {:error, :path_ignored}
  def validate_subagent_not_ignored(spec) do
    if EvoGit.Core.ContextNode.is_ignored?(spec.context_node) do
      {:error, :path_ignored}
    else
      :ok
    end
  end

  @doc """
  Builds the final results list in the same order as input specs.
  """
  @spec build_ordered_results(%{non_neg_integer() => term()}, non_neg_integer()) :: [term()]
  def build_ordered_results(sub_results, spec_count) do
    if spec_count == 0 do
      []
    else
      0..(spec_count - 1)//1
      |> Enum.map(fn idx ->
        Map.get(sub_results, idx, {:error, :unknown_error})
      end)
    end
  end

  # --- Spatial Contract Validation ---

  @doc """
  Validates that a subagent spec obeys spatial contract rules.

  Cross-repo delegation enforces read-only access — only `:read` agent types
  are allowed in foreign repos. Same-repo delegation checks that the child
  node is a descendant of (or same as) the parent node when the child is a
  read-write agent.
  """
  @spec validate_spatial_contract_for_spec(
          pos_integer(),
          AgentState.t(),
          EvoGit.AgentSpec.t()
        ) :: :ok | {:error, term()}
  def validate_spatial_contract_for_spec(
        _parent_id,
        %{context_node: parent_context, repo_id: parent_repo_id},
        spec
      ) do
    cond do
      # Cross-repo delegation: enforce read-only access for foreign repos
      spec.repo_id != parent_repo_id ->
        if spec.agent_module.agent_type() == :read_write do
          {:error,
           {:foreign_repo_read_only,
            """
            Read-write agents cannot be spawned in foreign repositories.
            Use read-only agent types instead:
            - subagent_codebase_investigator — for investigating and analyzing code
            - subagent_task_scheduler — for planning and scheduling tasks

            Foreign repos are read-only to prevent unintended modifications.
            If you need to apply changes based on foreign repo findings, do so in your primary repository.
            """}}
        else
          :ok
        end

      # Same-repo delegation: enforce spatial hierarchy for read-write agents
      true ->
        parent_path = EvoGit.Agent.Tools.Shared.normalize_relpath(parent_context.path)
        child_type = spec.agent_module.agent_type()
        child_path = EvoGit.Agent.Tools.Shared.normalize_relpath(spec.context_node.path)
        validate_spawn_spatiality(:read_write, parent_path, child_type, child_path)
    end
  end

  @doc """
  Validates spawn spatiality rules.

  A read-write child can only be spawned on the same node or a child node
  of a read-write parent. Read-only children can be spawned anywhere.
  """
  @spec validate_spawn_spatiality(atom(), String.t(), atom(), String.t()) ::
          :ok | {:error, term()}
  def validate_spawn_spatiality(
        :read_write,
        parent_path,
        :read_write,
        child_path
      ) do
    if EvoGit.Agent.Tools.Shared.is_child_or_same_node?(parent_path, child_path) do
      :ok
    else
      {:error,
       {:spatial_contract_violation,
        """
        Subagent that requires editing permissions can only be spawned on the same node or child nodes of your assigned node.
        You attempted to spawn a read-write subagent at '#{child_path}' from your assigned node '#{parent_path}'.

        This violates the contract - you do NOT have write permission on sibling or parent nodes.
        If you need to make changes to '#{child_path}', do the following:
        1. Complete your work within your assigned node '#{parent_path}'
        2. Return and report to the user about your progress and the changes needed on '#{child_path}'
        """}}
    end
  end

  def validate_spawn_spatiality(_parent_type, _parent_path, _child_type, _child_path), do: :ok

  # --- Result Tracking ---

  @doc """
  Stores a subagent result at the correct index in the parent's results map.
  """
  @spec store_sub_result(pos_integer(), pos_integer(), term()) :: :ok
  def store_sub_result(parent_id, sub_id, result) do
    # Parent entry may be reaped by cancel_agent while a subagent completes in flight
    case Store.get_sched_meta(parent_id) do
      {:ok, parent} ->
        idx = Map.get(parent.sub_agent_indices, sub_id)
        results = Map.put(parent.sub_agent_results, idx, result)

        # Track foreign repo commit SHAs — when a foreign-repo subagent completes,
        # record its commit so subsequent subagents can start from it instead of HEAD.
        foreign_repo_commits =
          case result do
            {:ok, %EvoGit.Agent.Result{commit_sha: sha, repo_id: repo_id}}
            when is_binary(sha) and not is_nil(repo_id) and repo_id != "primary" ->
              Map.put(parent.foreign_repo_commits, repo_id, sha)

            _ ->
              parent.foreign_repo_commits
          end

        Store.put_sched_meta(parent_id, %{
          parent
          | sub_agent_results: results,
            foreign_repo_commits: foreign_repo_commits
        })

      :error ->
        Logger.warning(
          "AgentScheduler: Parent #{parent_id} recycled; dropping result from subagent #{sub_id}"
        )

        :ok
    end
  end

  @doc """
  Checks if all subagents of a parent have completed and, if so, resumes the parent.

  When all results are in, marks the parent as :ready and dispatches it
  (replies to the blocked GenServer.call from the parent agent).
  """
  @spec maybe_resume_parent(State.t(), pos_integer()) :: State.t()
  def maybe_resume_parent(%State{} = state, parent_id) do
    # Parent entry may be reaped by cancel_agent while a subagent completes in flight
    case Store.get_sched_meta(parent_id) do
      {:ok, parent} ->
        all_done? = map_size(parent.sub_agent_results) == parent.total_sub_specs

        if all_done? do
          Logger.info(
            "AgentScheduler: Agent #{parent_id} ready to resume, all subagents completed"
          )

          # Parent always has its persistent worktree - resume immediately
          parent = %{parent | status: :ready}
          Store.put_sched_meta(parent_id, parent)

          if state.paused do
            %{state | queue: :queue.in(parent_id, state.queue)}
          else
            dispatch_ready_parent(state, parent_id, parent)
          end
        else
          state
        end

      :error ->
        Logger.warning("AgentScheduler: Parent #{parent_id} recycled; cannot resume")
        state
    end
  end

  @doc """
  Resumes a waiting parent agent. The parent keeps its persistent worktree
  while waiting, so no worktree assignment is needed.
  """
  @spec dispatch_ready_parent(State.t(), pos_integer(), SchedMeta.t()) :: State.t()
  def dispatch_ready_parent(%State{} = state, agent_id, %SchedMeta{worktree: wt} = meta) do
    results = build_ordered_results(meta.sub_agent_results, meta.total_sub_specs)

    GenServer.reply(meta.sub_agent_from, results)

    Store.put_sched_meta(agent_id, %{
      meta
      | status: :running,
        sub_agent_from: nil,
        pending_sub_agents: MapSet.new(),
        sub_agent_results: %{},
        sub_agent_indices: %{},
        total_sub_specs: 0
    })

    # Agent entry may be reaped by cancel_agent while a subagent completes in flight
    commit_sha =
      case Store.get_agent_state(agent_id) do
        {:ok, agent_state} ->
          agent_state.phylo_node.current_commit

        :error ->
          Logger.warning(
            "AgentScheduler: Agent #{agent_id} state missing on resume; commit unknown"
          )

          "unknown"
      end

    Logger.info(
      "AgentScheduler: Waiting agent #{agent_id} resumed with persistent worktree #{wt} at commit #{commit_sha}"
    )

    state
  end
end
