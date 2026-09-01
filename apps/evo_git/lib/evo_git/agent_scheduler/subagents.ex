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

        # Single reduce: validate, register, and build all collections in one pass.
        # `writable_accepted` tracks whether a writable-foreign-repo subagent was
        # already accepted in THIS batch — writable foreign spawns are serialized
        # (one per batch; the parent blocks until all batch subagents complete, so
        # one-per-batch == one-at-a-time). The 2nd+ accepted writable foreign spec
        # in the same batch is rejected with `:foreign_repo_write_serialized`.
        {sub_ids_rev, sub_agent_indices, invalid_results, _writable_accepted, state} =
          specs
          |> Enum.with_index()
          |> Enum.reduce({[], %{}, %{}, false, state}, fn {spec, idx},
                                                          {sub_ids_rev, sub_agent_indices_acc,
                                                           invalid_acc, writable_accepted,
                                                           state_acc} ->
            case validate_single_subagent(parent_id, parent, spec, parent_agent_state, state) do
              :ok ->
                parent_repo_id = parent_agent_state.repo_id

                cond do
                  # A writable-foreign-repo subagent was already accepted in this
                  # batch — writable foreign spawns run one at a time; keep the
                  # first accepted spec and reject the 2nd+ with the serialization
                  # error.
                  writable_accepted && writable_foreign_repo_spec?(parent_repo_id, spec) ->
                    reason =
                      {:foreign_repo_write_serialized,
                       foreign_repo_write_serialized_msg(spec.repo_id)}

                    Logger.warning(
                      "AgentScheduler: Subagent #{idx} failed validation: #{inspect(reason)}"
                    )

                    {sub_ids_rev, sub_agent_indices_acc,
                     Map.put(invalid_acc, idx, {:error, reason}), true, state_acc}

                  true ->
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

                    {[sub_id | sub_ids_rev], Map.put(sub_agent_indices_acc, sub_id, idx),
                     invalid_acc,
                     writable_accepted || writable_foreign_repo_spec?(parent_repo_id, spec),
                     state_acc}
                end

              {:error, reason} ->
                Logger.warning(
                  "AgentScheduler: Subagent #{idx} failed validation: #{inspect(reason)}"
                )

                {sub_ids_rev, sub_agent_indices_acc, Map.put(invalid_acc, idx, {:error, reason}),
                 writable_accepted, state_acc}
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
         :ok <-
           validate_spatial_contract_for_spec(parent_id, parent_agent_state, spec, parent.depth) do
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

  Cross-repo delegation: `:read` agent types are always allowed in foreign
  repos at any depth. `:read_write` agent types require the target repo's
  task-level entry to be explicitly writable in `spec.foreign_repos`, the
  spawning parent to be the ROOT agent (depth 0), and writable foreign
  spawns to be serialized one at a time (enforced by the caller,
  `spawn_validated_subagents/5`). Same-repo delegation checks that the
  child node is a descendant of (or same as) the parent node when the
  child is a read-write agent.

  The 3-arity form treats the parent as the ROOT agent (depth 0) — it
  exists for backward compatibility; the full depth-aware validation runs
  through `validate_single_subagent/5`, which passes the parent's real
  depth.
  """
  @spec validate_spatial_contract_for_spec(
          pos_integer(),
          AgentState.t(),
          EvoGit.AgentSpec.t()
        ) :: :ok | {:error, term()}
  def validate_spatial_contract_for_spec(parent_id, parent_agent_state, spec) do
    validate_spatial_contract_for_spec(parent_id, parent_agent_state, spec, 0)
  end

  @spec validate_spatial_contract_for_spec(
          pos_integer(),
          AgentState.t(),
          EvoGit.AgentSpec.t(),
          non_neg_integer()
        ) :: :ok | {:error, term()}
  def validate_spatial_contract_for_spec(
        _parent_id,
        %{context_node: parent_context, repo_id: parent_repo_id},
        spec,
        parent_depth
      ) do
    cond do
      # Cross-repo delegation: read-write agents may only be spawned into
      # foreign repos whose TASK-LEVEL entry is explicitly marked writable.
      # The target repo's role is resolved from spec.foreign_repos (the
      # task-level list of %ForeignRepo{} structs carried into subagent specs),
      # never from the path alone — an unknown repo id is read-only by default.
      # Writable cross-repo spawns are additionally ROOT-ONLY (depth 0) and
      # serialized one at a time (the serialization is enforced by the caller,
      # see spawn_validated_subagents/5). Same-repo spawns within a foreign
      # repo are unrestricted.
      spec.repo_id != parent_repo_id ->
        if spec.agent_module.agent_type() == :read_write do
          case foreign_repo_entry(spec) do
            %{writable: true} ->
              if parent_depth == 0 do
                :ok
              else
                {:error,
                 {:foreign_repo_write_not_root,
                  foreign_repo_write_not_root_msg(parent_depth, parent_repo_id)}}
              end

            _ ->
              {:error,
               {:foreign_repo_read_only,
                """
                This foreign repository is read-only for this task. Foreign repos
                may be writable for a task — changes are committed to
                evogit-agent-* branches, tracked by the task, and never merged
                back by the task — but this particular repo is not marked writable.

                Use read-only agent types instead:
                - subagent_investigator — for investigating and analyzing code
                - subagent_task_scheduler — for planning and scheduling tasks

                If your objective requires changes in this foreign repo, report
                back to the user or parent agent instead of writing directly.
                """}}
          end
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

  # --- Foreign Repo Writable Delegation Helpers ---

  # The task-level foreign repo entry for this spec's target repo id, or nil
  # when the repo id is absent from spec.foreign_repos (unknown → read-only).
  defp foreign_repo_entry(spec) do
    Enum.find(spec.foreign_repos || [], fn
      %{id: id} -> id == spec.repo_id
      _ -> false
    end)
  end

  # A spec is a "writable foreign repo spawn" when it is a CROSS-repo
  # (different repo id than the parent) `:read_write` spec whose target is
  # marked writable at the task level. Same-repo spawns within a foreign repo
  # are never restricted.
  defp writable_foreign_repo_spec?(parent_repo_id, spec) do
    spec.repo_id != parent_repo_id and
      spec.agent_module.agent_type() == :read_write and
      match?(%{writable: true}, foreign_repo_entry(spec))
  end

  defp foreign_repo_write_not_root_msg(parent_depth, parent_repo_id) do
    """
    Only the ROOT agent may spawn write-capable subagents in a foreign repository. You are a nested agent (depth #{parent_depth}) in '#{parent_repo_id}'. Your write scope is your assigned node inside your own repository.

    Alternatives: (a) spawn read-only agents (subagent_investigator / subagent_task_scheduler) into the foreign repo — read-only access is unrestricted; or (b) if changes ARE required in the foreign repo, report the needed change back up to the root agent, which will spawn the writable subagent (one at a time).
    """
  end

  defp foreign_repo_write_serialized_msg(repo_id) do
    """
    Only ONE write-capable subagent may run in a foreign repository at a time. You attempted to spawn several in parallel (targeting '#{repo_id}'). Parallel writes to a foreign repo create merge conflicts you cannot resolve (the sandbox restricts write access to your local path, not the foreign repo path). Spawn ONE writable foreign-repo subagent, wait for it to complete, then spawn the next. Let the Manager inside the foreign repo handle its own parallelism — it knows that repo and can serialize its own work.
    """
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

        # Roll up the completing subagent's subtree commits: its result carries
        # the per-repo commits of its own subtree (injected by Lifecycle at
        # completion), so multi-level trees accumulate at the root. Child
        # entries override the parent's for the same repo_id — the child's
        # subtree view is fresher.
        base_commits =
          case result do
            {:ok, %EvoGit.Agent.Result{} = res} ->
              child_frc = Map.get(res, :foreign_repo_commits, %{})
              Map.merge(parent.foreign_repo_commits, child_frc)

            _ ->
              parent.foreign_repo_commits
          end

        # Track foreign repo commit SHAs — when a foreign-repo subagent completes,
        # record its commit so subsequent subagents can start from it instead of HEAD.
        foreign_repo_commits =
          case result do
            {:ok, %EvoGit.Agent.Result{commit_sha: sha, repo_id: repo_id}}
            when is_binary(sha) and not is_nil(repo_id) and repo_id != "primary" ->
              Map.put(base_commits, repo_id, sha)

            _ ->
              base_commits
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

          # Parent keeps its live worktree while waiting (its process is
          # still alive, blocked on spawn_sub_agents) — resume immediately
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
  Resumes a waiting parent agent. The parent keeps its LIVE worktree while
  waiting because its process is still alive (blocked on spawn_sub_agents);
  WorktreeManager reclaims the worktree only on process exit, so no worktree
  assignment is needed here.
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
        {:ok, %AgentState{phylo_node: nil}} ->
          # Repo-less parent — no worktree/commits; only used for the log below.
          "unknown"

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
