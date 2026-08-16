defmodule EvoGit.AgentScheduler.Dispatch do
  @moduledoc """
  Agent registration, dispatching, and queue processing for the AgentScheduler.

  Handles creating agent entries in ETS, dispatching agents to worktrees,
  auto-committing pending changes, and processing the agent queue. Model
  selection for registered agents can be driven by the user model-selection
  script (`EvoGit.CustomAgents.ModelSelector`) and custom agent defaults
  (`EvoGit.CustomAgents`).
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

    # Resolve the effective model id for this agent (user-locked model >
    # model-selection script > spec.model_id / custom-agent default), then map
    # it to a profile, falling back to the default profile from state.model_profiles.
    spec_model_id = effective_model_id(state, spec, parent_id, depth, task_id)

    {resolved_model_id, resolved_model, resolved_params} =
      resolve_model_for_agent(state, spec_model_id)

    Store.put_agent_state(id, %AgentState{
      context_node: spec.context_node,
      phylo_node: nil,
      llm_model: resolved_model,
      llm_generation_params: resolved_params,
      model_id: resolved_model_id,
      max_retries: state.max_retries,
      max_depth: state.max_depth,
      max_turns: resolve_max_turns(state, spec, parent_id),
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

    # Graceful-cancel registration guard: if the task is in the cancelling
    # marker (a graceful cancel is in flight), immediately put the newly
    # registered agent into cancel-grace — append the cancel notification
    # message and set cancel_requested so it enters grace at its first loop
    # top. This covers subagents spawned in the cancel window, crash-retries,
    # and queued agents starting late. The check is a cheap ETS lookup keyed
    # by task_id. task_id may be nil for agents spawned without a task.
    if is_binary(task_id) and cancelling_task?(task_id) do
      Store.append_pending_user_message(id, EvoGit.AgentScheduler.cancel_message())
      Store.set_cancel_requested(id)
    end

    state = %{state | next_agent_id: id + 1}
    {id, state}
  end

  # Returns true when the task_id is registered in the :evogit_cancelling_tasks
  # marker. Defensive against a missing table.
  defp cancelling_task?(task_id) do
    case :ets.whereis(:evogit_cancelling_tasks) do
      :undefined -> false
      _tid -> :ets.member(:evogit_cancelling_tasks, task_id)
    end
  end

  @doc """
  Computes the next task number by scanning the `.genesis/workers/` directory.
  Returns max+1 of existing `worker_T<n>_A<m>` entries, or 1 if none/empty.
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
  the agent Task. Worktree creation is requested by the agent's Runner from
  `EvoGit.AgentScheduler.WorktreeManager.create_worktree_for_agent/6` (1-hour
  call timeout; WorktreeManager offloads the I/O to a spawned task and
  monitors the agent process).
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
    # task, so cancel_agent can find the worktree even if the task hasn't
    # finished its setup yet.
    agent_repo_root = resolve_agent_repo_root(spec, state)

    worktree_path =
      Path.join([
        agent_repo_root,
        ".genesis/workers",
        "worker_T#{meta.task_number}_A#{task_local_id}"
      ])

    Store.put_sched_meta(agent_id, %{meta | worktree: worktree_path})

    # Phase 2 — Task phase (slow, concurrent):
    # Worktree creation does NOT run here. The agent's Runner requests a fresh
    # worktree from WorktreeManager (1h call timeout) inside `run/2`;
    # WorktreeManager offloads the I/O to a spawned task, so multiple
    # subagents create worktrees in parallel.
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

  # --- Effective Model / Max-Turns Resolution ---

  # Computes the effective model id for a newly-registered agent.
  #
  # Priority order (highest wins):
  #
  # 1. **User-locked model** — `spec.opts[:model_id_locked]` is `true` (set by the
  #    CLI `-m` flag): the user's explicit model choice wins over everything, so
  #    `spec.model_id` is returned immediately without consulting the script.
  # 2. **Model-selection script** — the user Elixir script from `agents.toml`
  #    (`EvoGit.CustomAgents.ModelSelector.select_model/1`): its returned id is
  #    used as-is. An unknown id keeps `resolve_model_for_agent/2`'s existing
  #    warn-and-fall-back-to-default behavior.
  # 3. **`spec.model_id` / custom-agent default** — the caller-supplied model id;
  #    when nil/empty and the spec carries a `:custom_agent_id`, the custom agent
  #    definition's `:model_id` is used instead.
  # 4. **Default profile** — `nil` reaches `resolve_model_for_agent/2`, which
  #    picks the scheduler's default profile.
  #
  # This runs in the scheduler GenServer and NEVER raises: a missing custom
  # agent definition is logged and treated as nil; script failures surface as
  # `{:error, reason}` from `select_model/1` and are logged with a fallback to
  # the base id.
  @spec effective_model_id(
          State.t(),
          AgentSpec.t(),
          pos_integer() | nil,
          non_neg_integer(),
          String.t() | nil
        ) :: String.t() | nil
  defp effective_model_id(_state, %AgentSpec{} = spec, parent_id, depth, task_id) do
    base_id =
      case spec.model_id do
        id when is_binary(id) and id != "" ->
          id

        _ ->
          case custom_agent_id(spec) do
            nil ->
              nil

            custom_id ->
              case EvoGit.CustomAgents.get(custom_id) do
                nil ->
                  Logger.warning(
                    "AgentScheduler: custom agent id #{inspect(custom_id)} not found; " <>
                      "falling back to default model"
                  )

                  nil

                definition ->
                  Map.get(definition, :model_id)
              end
          end
      end

    if Keyword.get(spec.opts, :model_id_locked, false) == true do
      base_id
    else
      attrs = %{
        agent_type: if(custom_id?(spec), do: :custom, else: spec.agent_module),
        custom_agent_id: custom_agent_id(spec),
        depth: depth,
        parent_id: parent_id,
        task_id: task_id,
        objective: spec.objective
      }

      case EvoGit.CustomAgents.ModelSelector.select_model(attrs) do
        {:ok, nil} ->
          base_id

        {:ok, model_id} ->
          model_id

        {:error, reason} ->
          Logger.warning(
            "AgentScheduler: model selection script failed for agent " <>
              "(task #{inspect(task_id)}): #{inspect(reason)}; using default model"
          )

          base_id
      end
    end
  end

  # Resolves the max-turns cap for a newly-registered agent.
  #
  # Custom agents are root-only in this version: when the agent is a root
  # (`parent_id` is nil) whose spec carries a `:custom_agent_id`, the custom
  # agent definition's positive-integer `:max_turns` override wins. A missing
  # definition is logged and falls back to `state.max_turns_root`. Subagents
  # (parent_id set) always use `state.max_turns` — they are never custom agents
  # in this version, but the default is kept defensive against a custom id
  # sneaking into a subagent spec.
  @spec resolve_max_turns(State.t(), AgentSpec.t(), pos_integer() | nil) :: pos_integer()
  defp resolve_max_turns(%State{} = state, %AgentSpec{} = spec, parent_id) do
    if is_nil(parent_id) do
      case custom_agent_id(spec) do
        nil ->
          state.max_turns_root

        custom_id ->
          case EvoGit.CustomAgents.get(custom_id) do
            %{max_turns: max_turns} when is_integer(max_turns) and max_turns > 0 ->
              max_turns

            nil ->
              Logger.warning(
                "AgentScheduler: custom agent id #{inspect(custom_id)} not found; " <>
                  "falling back to default max turns"
              )

              state.max_turns_root

            _definition ->
              state.max_turns_root
          end
      end
    else
      state.max_turns
    end
  end

  # Returns the custom agent id from spec.opts when it is a non-empty binary,
  # nil otherwise.
  defp custom_agent_id(spec) do
    case Keyword.get(spec.opts, :custom_agent_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp custom_id?(spec), do: custom_agent_id(spec) != nil

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
            # Regular agent - dispatch with a fresh worktree (WorktreeManager
            # creates/reclaims it)
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
