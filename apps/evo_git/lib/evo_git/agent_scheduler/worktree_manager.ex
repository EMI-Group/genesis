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
  - Crash-restart safety (this GenServer is a one_for_one child of
    `EvoGit.Supervisor` — a crash restarts IT without killing the running
    agent Tasks, which keep running in their live worktrees):
    * The destructive per-repo init (rm_rf workers dir + orphaned branch
      cleanup + prune) is gated on a PERSISTENT marker in the app-owned ETS
      table `:evogit_worktree_repos` (created in `EvoGit.Application.start/2`,
      same pattern as `:evogit_cancelling_tasks`). The marker survives
      WorktreeManager restarts — a manager-only restart SKIPS the wipe,
      preserving live agents' worktrees; it dies with the app, so a genuine
      BEAM restart (no live agents) re-runs the full wipe. Reading/writing is
      defensive via `:ets.whereis` (a missing table means "uninitialized").
    * The destructive steps (rm_rf workers base + orphaned `evogit-agent-*`
      branch cleanup) run for the PRIMARY repo only (`primary?` flag, derived
      at the call sites from `spec.repo_id` via `ForeignRepo.primary?/1`).
      Foreign repos — which may be writable per-task and hold real
      `evogit-agent-*` task branches — get only the non-destructive prune +
      workers-dir ensure + init marker.
    * On restart, live agents are re-monitored from their scheduler ETS rows
      (`:evogit_sched_meta` worktree + task_ref, `:evogit_agent_state`
      repo_root + task_local_id), so `:DOWN`-driven cleanup keeps working for
      agents whose worktrees predate the crash.

  The AgentScheduler itself never touches worktree I/O.
  """

  use GenServer
  require Logger
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.WorktreeRetry
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
    GenServer.call(
      __MODULE__,
      {:create_worktree_for_agent, agent_id, repo_root, worktree_path, spec, meta, agent_pid},
      @worktree_call_timeout
    )
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      # agent_id => %{worktree_path, repo_root, branch_name, creating, monitor_ref}
      agents: %{},
      # monitor ref => agent_id
      monitors: %{},
      # agents that died while their create was still in flight
      pending_cleanup: MapSet.new(),
      # agent_id => {from, request_params} — re-create request that arrived
      # while the previous create was still in flight
      pending_requests: %{}
    }

    # Crash-restart path: this GenServer restarts WITHOUT killing the running
    # agent Tasks. Re-monitor the live agents (worktree already created before
    # the crash) from their scheduler ETS rows so :DOWN-driven cleanup keeps
    # working. Tolerant — missing/stale rows are skipped, never crashes init.
    {:ok, rebuild_monitors(state)}
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
          Map.put(
            state.pending_requests,
            agent_id,
            {from, {agent_id, repo_root, worktree_path, spec, meta, agent_pid}}
          )

        {:noreply, %{state | pending_requests: pending_requests}}

      %{monitor_ref: old_ref} ->
        # Worktree live but the old agent's :DOWN hasn't been processed yet
        # (retry-after-crash race). Drop the stale monitor; the new create
        # task's destroy-before-create handles the old worktree.
        Process.demonitor(old_ref, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, old_ref)}

        state =
          maybe_init_repo(state, repo_root, EvoGit.Core.ForeignRepo.primary?(spec.repo_id))

        state =
          start_create(state, agent_id, repo_root, worktree_path, spec, meta, agent_pid, from)

        {:noreply, state}

      nil ->
        state =
          maybe_init_repo(state, repo_root, EvoGit.Core.ForeignRepo.primary?(spec.repo_id))

        state =
          start_create(state, agent_id, repo_root, worktree_path, spec, meta, agent_pid, from)

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
  # requested after the app started. The destructive wipe (rm_rf the whole
  # workers dir + orphaned branch cleanup + prune) is gated on a PERSISTENT
  # marker in the app-owned ETS table `:evogit_worktree_repos`:
  #
  # - Marker present → the wipe already ran for this repo. This is the
  #   WorktreeManager-only restart case: agents whose worktrees were created
  #   before the crash are STILL RUNNING, so re-wiping would delete their live
  #   worktrees and branches (the production crash cascade). Skip the wipe;
  #   only ensure the workers dir exists (git worktree add needs the parent)
  #   via the tolerant `WorktreeRetry.mkdir_p_retry/2`.
  # - Marker absent → full wipe (no worktrees for this repo can exist yet —
  #   either the app just started and no create has ever run, or the BEAM
  #   restarted, in which case all agents are dead). Then record the marker.
  # - Table missing entirely (`:ets.whereis` → `:undefined`, e.g. tests that
  #   do not start the app) → treated as marker absent → full wipe, mirroring
  #   the `:evogit_cancelling_tasks` defensive pattern.
  #
  # `primary?` scopes the DESTRUCTIVE steps to the primary repo: writable
  # foreign repos may hold REAL task work (`evogit-agent-*` branches + live
  # worktrees from previous runs), so their lazy init must never rm_rf the
  # workers base nor delete orphaned agent branches. The non-destructive
  # `Git.prune_worktrees` (admin metadata only), the loud workers-dir ensure,
  # and the per-repo init marker run for BOTH primary and foreign repos —
  # lazy init + the marker-gated skip path are still needed for foreign repos.
  defp maybe_init_repo(state, repo_root, primary?) do
    worker_base = workers_dir(repo_root)

    if worktree_repo_initialized?(repo_root) do
      Logger.debug(
        "WorktreeManager: Repo #{repo_root} already initialized " <>
          "(persistent marker) — skipping destructive wipe"
      )

      ensure_workers_dir(worker_base)
    else
      Logger.info("WorktreeManager: Initializing worktree directory at #{worker_base}")

      if primary? do
        # Use non-bang variant — when the scheduler crashes and restarts while
        # agents from the previous instance are still running, the workers
        # directory may be in use and rm_rf can fail with :eexist (or other
        # errors). Log a warning and continue — mkdir_p on the next line is a
        # no-op since the directory already exists. Transient failures
        # (Windows file locking, anti-virus scans) are retried first.
        case WorktreeRetry.rm_rf_retry(worker_base) do
          {:ok, _} ->
            :ok

          {:error, reason, path} ->
            Logger.warning(
              "WorktreeManager: Could not remove worker directory #{worker_base}: " <>
                "#{inspect(reason)} at #{path} — continuing with existing directory"
            )
        end

        # Clean up orphaned evogit-agent branches from previous runs — PRIMARY
        # repos only: foreign repos may carry real task branches.
        clean_orphaned_branches(repo_root)
      end

      WorktreeRetry.retry_on_transient(fn -> Git.prune_worktrees(repo_root) end)

      # Loud on exhaustion: raise exactly like File.mkdir_p!/1 does —
      # same File.Error struct and fields (reason, action, path). Note
      # File.mkdir_p/1 returns 2-tuples {:error, reason}, so the original
      # path is used in the raise, mirroring mkdir_p!.
      case WorktreeRetry.mkdir_p_retry(worker_base) do
        :ok ->
          :ok

        {:error, reason} ->
          raise File.Error,
            reason: reason,
            action: "make directory (with -p)",
            path: worker_base
      end

      mark_worktree_repo_initialized(repo_root)
    end

    state
  end

  # Ensures the workers dir exists for an already-initialized repo
  # (WorktreeManager-only restart). Tolerant: a failure is logged — the
  # create request itself will fail loudly if the parent dir cannot be
  # created; NOT caching success means the next request retries mkdir_p.
  defp ensure_workers_dir(worker_base) do
    case WorktreeRetry.mkdir_p_retry(worker_base) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "WorktreeManager: Could not create worker directory #{worker_base}: " <>
            "#{inspect(reason)}"
        )
    end
  end

  # Returns true when the destructive per-repo init has already run for this
  # repo (persistent marker present). Defensive against a missing table — the
  # app creates `:evogit_worktree_repos` in Application.start/2; tests create
  # it in setup (same pattern as the `:evogit_cancelling_tasks` reads).
  defp worktree_repo_initialized?(repo_root) do
    case :ets.whereis(:evogit_worktree_repos) do
      :undefined -> false
      _tid -> :ets.member(:evogit_worktree_repos, repo_root)
    end
  end

  # Records the persistent per-repo init marker (repo_root => init timestamp).
  defp mark_worktree_repo_initialized(repo_root) do
    case :ets.whereis(:evogit_worktree_repos) do
      :undefined -> :ok
      _tid -> :ets.insert(:evogit_worktree_repos, {repo_root, System.system_time(:second)})
    end

    :ok
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
            result =
              Worktrees.prepare_new_worktree(agent_id, repo_root, worktree_path, spec, meta)

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
  # that is checked out in another worktree. Idempotent and non-crashing
  # (runs in the WorktreeManager GenServer process). Transient failures
  # (Windows file locking, anti-virus scans) are retried via WorktreeRetry;
  # the retry budget is kept small (4 attempts, at most 350ms of sleeping).
  #
  # Main-HEAD-leak safety: `Git.prune_worktrees` runs ONLY after the dir is
  # actually gone. A dir that survives rm_rf WITH its `.git` file +
  # registration is a SAFE registered worktree; pruning it away would turn it
  # into a PLAIN unregistered dir — the foreign-repo main-HEAD leak
  # precondition. So on rm_rf failure we log at ERROR level and skip BOTH the
  # prune and the branch delete, keeping the dir+registration pair consistent
  # for a later create/cleanup to rm_rf properly.
  defp destroy_worktree(worktree_path, repo_root, branch_name) do
    case WorktreeRetry.rm_rf_retry(worktree_path) do
      {:ok, _} ->
        # Dir is gone — safe to prune stale registrations and delete the
        # branch.
        WorktreeRetry.retry_on_transient(fn -> Git.prune_worktrees(repo_root) end)

        case WorktreeRetry.retry_on_transient(fn ->
               Worktrees.delete_branch_tolerant(repo_root, branch_name)
             end) do
          :ok ->
            :ok

          {:error, output} ->
            Logger.warning(
              "WorktreeManager: Failed to delete branch #{branch_name}: #{inspect(output)}"
            )
        end

      {:error, reason, path} ->
        Logger.error(
          "WorktreeManager: Failed to remove worktree #{worktree_path}: " <>
            "#{inspect(reason)} at #{path} — not pruning (dir still present; " <>
            "keeping dir+registration consistent)"
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
          Worktrees.delete_branch_tolerant(repo_root, branch)
        end)

      {:error, {tag, output}} ->
        Logger.warning(
          "WorktreeManager: Failed to list evogit-agent-* branches for cleanup: " <>
            "{#{inspect(tag)}, #{inspect(output)}}"
        )
    end

    :ok
  end

  # --- Crash-restart re-monitoring (Bug 3) ---

  # Rebuilds the agents/monitors registrations from scheduler ETS after a
  # WorktreeManager-only restart. The manager's in-memory maps were lost with
  # the crash, but running agents' `:evogit_sched_meta` rows still carry their
  # live worktree path + `%Task{}` ref (Dispatch.try_dispatch/2 sets both
  # BEFORE the agent's Runner requests the worktree) and their
  # `:evogit_agent_state` row carries `repo_root`/`task_local_id`. Re-monitor
  # them so `:DOWN`-driven cleanup keeps working for agents whose worktrees
  # predate the crash — otherwise their worktree dirs + branches leak until
  # the next full BEAM restart.
  #
  # Tolerant by construction: agents that died while the manager was down have
  # their rows reaped by the scheduler (or are skipped here); a monitor on an
  # already-dead pid delivers an immediate `:DOWN`, which flows through the
  # normal cleanup path. Queued/not-yet-created agents (worktree nil, or no
  # task_ref) are skipped — they register when they make their create request.
  # Never crashes init.
  defp rebuild_monitors(state) do
    case :ets.whereis(:evogit_sched_meta) do
      :undefined ->
        state

      _tid ->
        :ets.foldl(
          fn {agent_id, meta}, acc -> rebuild_monitor(acc, agent_id, meta) end,
          state,
          :evogit_sched_meta
        )
    end
  end

  # Re-monitors a single live agent. The rebuilt entry shape EXACTLY matches
  # what `handle_info({:DOWN, ...})` and `destroy_worktree/3` expect on the
  # normal path: `%{worktree_path, repo_root, branch_name, creating: false,
  # monitor_ref}` plus the reverse `monitors` map entry — so cleanup after the
  # restart is identical to the normal path.
  defp rebuild_monitor(state, agent_id, meta) do
    with %{worktree: worktree, task_ref: %Task{} = task_ref, task_number: task_number}
         when is_binary(worktree) and is_integer(task_number) <- meta,
         {:ok, agent_state} <- Store.get_agent_state(agent_id),
         %{task_local_id: task_local_id, repo_root: repo_root} <- agent_state,
         true <- is_integer(task_local_id),
         false <- Map.has_key?(state.agents, agent_id) do
      ref = Process.monitor(task_ref.pid)

      %{
        state
        | agents:
            Map.put(state.agents, agent_id, %{
              worktree_path: worktree,
              repo_root: repo_root || derive_repo_root(worktree),
              branch_name: Worktrees.branch_name(task_number, task_local_id),
              creating: false,
              monitor_ref: ref
            }),
          monitors: Map.put(state.monitors, ref, agent_id)
      }
    else
      _ ->
        state
    end
  end

  # Derives the repo root from a worktree path (primary-repo layout), mirroring
  # `Dispatch.resolve_agent_repo_root/2`'s worktree-suffix strip. Used only as
  # a fallback when the AgentState `repo_root` is missing.
  defp derive_repo_root(worktree_path) do
    case String.split(worktree_path, "/.genesis/workers/", parts: 2) do
      [root, _rest] -> root
      [_] -> worktree_path
    end
  end
end
