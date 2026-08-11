defmodule EvoGit.AgentScheduler.WorktreeManager do
  @moduledoc """
  Worktree lifecycle owner for the AgentScheduler.

  Owns the ENTIRE worktree lifecycle so the AgentScheduler GenServer never
  blocks on worktree I/O:

  - Lazy per-repo initialization of the `.genesis/workers` directory (once per
    repo, on first request for that repo).
  - Fresh worktree creation on request from the agent Runner. The Runner's
    `GenServer.call` uses a 1-hour timeout (`@worktree_call_timeout`); the
    actual I/O is offloaded to a spawned task so this GenServer's message loop
    stays responsive for `:DOWN`/cleanup messages while creation is in flight.
  - Process monitoring: every agent process is monitored; when it exits (for
    ANY reason — `:normal` completion or crash), its worktree is destroyed.
    Cleanup is identical for normal and abnormal exits — there is no reuse
    semantics; every run gets a fresh worktree.
  - Deferred cleanup for agents that die while their create task is still in
    flight (the cleanup runs when the create finishes).
  - Per-agent serialization of re-create requests: a retry Runner arriving
    while the previous create is still in flight has its request queued in
    `pending_requests` and is started when the previous create finishes.

  The AgentScheduler itself never touches worktree I/O.
  """

  use GenServer
  require Logger
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees

  # The Runner's request can take a long time on slow filesystems (NFS,
  # Windows). 1 hour far exceeds any legitimate worktree creation.
  @worktree_call_timeout 3_600_000

  # --- Client API ---

  @doc """
  Starts the WorktreeManager GenServer.
  Registers under the module name so callers can use the module as the server name.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the path to the workers directory for a given repo root.
  """
  @spec workers_dir(String.t()) :: String.t()
  def workers_dir(repo_root), do: Path.join(repo_root, ".genesis/workers")

  @doc """
  Creates (or recreates) a fresh worktree for an agent and prepares it.

  Called by the agent's Runner from inside the agent (Task) process. The call
  has a 1-hour timeout; the WorktreeManager offloads the I/O to a spawned
  task and monitors the caller process — if the caller dies for any reason,
  the worktree is reclaimed.

  Returns `{:ok, worktree_path}` on success or `{:error, reason}`.
  """
  @spec create_worktree_for_agent(
          pos_integer(),
          String.t(),
          String.t(),
          EvoGit.AgentSpec.t(),
          EvoGit.AgentScheduler.SchedMeta.t(),
          pid()
        ) :: {:ok, String.t()} | {:error, term()}
  def create_worktree_for_agent(agent_id, repo_root, worktree_path, spec, meta, agent_pid) do
    GenServer.call(__MODULE__,
      {:create_worktree_for_agent, agent_id, repo_root, worktree_path, spec, meta, agent_pid},
      @worktree_call_timeout
    )
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok,
     %{
       # repos whose workers dir has been initialized (lazy, once per repo)
       repos: %{},
       # agent_id => %{worktree_path, repo_root, branch_name, creating, monitor_ref}
       agents: %{},
       # monitor ref => agent_id
       monitors: %{},
       # agents that died while their create was still in flight
       pending_cleanup: MapSet.new(),
       # agent_id => {from, request_params} — re-create request that arrived
       # while the previous create was still in flight
       pending_requests: %{}
     }}
  end

  @impl true
  def handle_call(
        {:create_worktree_for_agent, agent_id, repo_root, worktree_path, spec, meta, agent_pid},
        from,
        state
      ) do
    case Map.get(state.agents, agent_id) do
      %{creating: true} ->
        # Previous create still in flight (retry-after-crash-during-setup
        # race). Defer this request — it will be started when the previous
        # create finishes (the {:create_finished, ...} cast).
        pending_requests =
          Map.put(state.pending_requests, agent_id,
            {from, {agent_id, repo_root, worktree_path, spec, meta, agent_pid}}
          )

        {:noreply, %{state | pending_requests: pending_requests}}

      %{monitor_ref: old_ref} ->
        # Worktree live but the old agent's :DOWN hasn't been processed yet
        # (retry-after-crash race). Drop the stale monitor; the new create
        # task's destroy-before-create handles the old worktree.
        Process.demonitor(old_ref, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, old_ref)}
        state = maybe_init_repo(state, repo_root)
        state = start_create(state, agent_id, repo_root, worktree_path, spec, meta, agent_pid, from)
        {:noreply, state}

      nil ->
        state = maybe_init_repo(state, repo_root)
        state = start_create(state, agent_id, repo_root, worktree_path, spec, meta, agent_pid, from)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:create_finished, agent_id}, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        # Stale task (WorktreeManager restarted, or agent already cleaned up)
        {:noreply, state}

      %{creating: false} ->
        # Stale duplicate cast — ignore
        {:noreply, state}

      %{} = agent_info ->
        cond do
          MapSet.member?(state.pending_cleanup, agent_id) ->
            # The agent died while its create was in flight — the worktree is
            # now settled (the task has finished), so clean it up inline.
            destroy_worktree(
              agent_info.worktree_path,
              agent_info.repo_root,
              agent_info.branch_name
            )

            Process.demonitor(agent_info.monitor_ref, [:flush])

            state = %{
              state
              | agents: Map.delete(state.agents, agent_id),
                monitors: Map.delete(state.monitors, agent_info.monitor_ref),
                pending_cleanup: MapSet.delete(state.pending_cleanup, agent_id)
            }

            state = maybe_start_pending_request(state, agent_id)
            {:noreply, state}

          Map.has_key?(state.pending_requests, agent_id) ->
            # The previous agent died while its create was in flight and a
            # re-create request is queued. Drop the stale monitor (flushes
            # any queued :DOWN for the dead agent) and start the pending
            # create — its destroy-before-create cleans the just-created
            # worktree.
            Process.demonitor(agent_info.monitor_ref, [:flush])
            state = %{state | monitors: Map.delete(state.monitors, agent_info.monitor_ref)}
            state = maybe_start_pending_request(state, agent_id)
            {:noreply, state}

          true ->
            # Create finished normally — the worktree is live for the
            # running agent.
            {:noreply,
             %{state | agents: Map.put(state.agents, agent_id, %{agent_info | creating: false})}}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        # Stale DOWN (monitor already demonitored/flushed)
        {:noreply, state}

      agent_id ->
        case Map.get(state.agents, agent_id) do
          %{creating: true, monitor_ref: ^ref} ->
            # Agent died while its create was still in flight — defer the
            # cleanup until the create task finishes.
            {:noreply, %{state | pending_cleanup: MapSet.put(state.pending_cleanup, agent_id)}}

          %{monitor_ref: ^ref, worktree_path: wt, repo_root: repo_root, branch_name: branch_name} ->
            # Agent exited (normal or abnormal — identical cleanup; every run
            # gets a fresh worktree). Destroy and drop the registration.
            destroy_worktree(wt, repo_root, branch_name)
            Process.demonitor(ref, [:flush])

            {:noreply,
             %{
               state
               | agents: Map.delete(state.agents, agent_id),
                 monitors: Map.delete(state.monitors, ref)
             }}

          _ ->
            # Stale DOWN for a replaced registration
            {:noreply, state}
        end
    end
  end

  # --- Private Helpers ---

  # Initializes the workers directory for a repo the first time it is
  # requested. Safe: no worktrees for this repo can exist yet — this is the
  # first request.
  defp maybe_init_repo(state, repo_root) do
    if Map.has_key?(state.repos, repo_root) do
      state
    else
      worker_base = workers_dir(repo_root)

      Logger.info("WorktreeManager: Initializing worktree directory at #{worker_base}")

      # Use non-bang variant — when the scheduler crashes and restarts while
      # agents from the previous instance are still running, the workers
      # directory may be in use and rm_rf can fail with :eexist (or other
      # errors). Log a warning and continue — mkdir_p on the next line is a
      # no-op since the directory already exists.
      case File.rm_rf(worker_base) do
        {:ok, _} ->
          :ok

        {:error, reason, path} ->
          Logger.warning(
            "WorktreeManager: Could not remove worker directory #{worker_base}: " <>
              "#{inspect(reason)} at #{path} — continuing with existing directory"
          )
      end

      Git.prune_worktrees(repo_root)

      # Clean up orphaned evogit-agent branches from previous runs
      clean_orphaned_branches(repo_root)

      File.mkdir_p!(worker_base)
      %{state | repos: Map.put(state.repos, repo_root, true)}
    end
  end

  # Registers the agent (monitor + agents/monitors maps) and spawns the
  # offloaded create task. The reply is deferred to the task; the task
  # guarantees the {:create_finished, ...} cast via try/after.
  defp start_create(state, agent_id, repo_root, worktree_path, spec, meta, agent_pid, from) do
    case Store.get_agent_state(agent_id) do
      {:ok, agent_state} ->
        branch_name = Worktrees.branch_name(meta.task_number, agent_state.task_local_id)
        ref = Process.monitor(agent_pid)

        state = %{
          state
          | agents:
              Map.put(state.agents, agent_id, %{
                worktree_path: worktree_path,
                repo_root: repo_root,
                branch_name: branch_name,
                creating: true,
                monitor_ref: ref
              }),
            monitors: Map.put(state.monitors, ref, agent_id)
        }

        Task.start(fn ->
          try do
            result = Worktrees.prepare_new_worktree(agent_id, repo_root, worktree_path, spec, meta)
            GenServer.reply(from, result)
          after
            GenServer.cast(__MODULE__, {:create_finished, agent_id})
          end
        end)

        state

      :error ->
        GenServer.reply(from, {:error, {:agent_state_missing, agent_id}})
        state
    end
  end

  # Starts a queued re-create request for an agent, if one exists.
  defp maybe_start_pending_request(state, agent_id) do
    case Map.pop(state.pending_requests, agent_id) do
      {nil, _} ->
        state

      {{from, {agent_id, repo_root, worktree_path, spec, meta, agent_pid}}, pending_requests} ->
        state = %{state | pending_requests: pending_requests}

        start_create(state, agent_id, repo_root, worktree_path, spec, meta, agent_pid, from)
    end
  end

  # Destroys a worktree: rm_rf the directory, prune the worktree registry,
  # then delete the branch. Order matters — git refuses to delete a branch
  # that is checked out in another worktree. Idempotent and tolerant: all
  # failure modes log and continue.
  defp destroy_worktree(worktree_path, repo_root, branch_name) do
    case File.rm_rf(worktree_path) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "WorktreeManager: Failed to remove worktree #{worktree_path}: " <>
            "#{inspect(reason)} at #{path}"
        )
    end

    Git.prune_worktrees(repo_root)

    case Git.delete_branch(repo_root, branch_name) do
      {:ok, _} ->
        :ok

      {:error, {_tag, output}} ->
        Logger.warning(
          "WorktreeManager: Failed to delete branch #{branch_name}: #{inspect(output)}"
        )
    end

    :ok
  end

  # Cleans up orphaned `evogit-agent-*` branches from previous runs.
  # Matches all branches with the `evogit-agent-` prefix and deletes each one.
  # Called during initialization to prevent stale branches from accumulating.
  defp clean_orphaned_branches(repo_root) do
    case Git.list_branches(repo_root, "evogit-agent-*") do
      {:ok, branches} ->
        Enum.each(branches, fn branch ->
          Logger.info("WorktreeManager: Cleaning up orphaned branch #{branch}")
          Git.delete_branch(repo_root, branch)
        end)

      {:error, {tag, output}} ->
        Logger.warning(
          "WorktreeManager: Failed to list evogit-agent-* branches for cleanup: " <>
            "{#{inspect(tag)}, #{inspect(output)}}"
        )
    end

    :ok
  end
end
