defmodule EvoDash.TaskRegistry do
  @moduledoc """
  Registry for tracking running EvoGit tasks.
  Tasks are identified by unique IDs and persisted to SQLite (the single source of truth)
  under namespaced keys `{:task, task_id}`.
  Runtime-only task references (`%Task{}`) are kept in-memory in `task_refs`.
  Supports configurable persistence of finished tasks and
  recently opened projects to SQLite (platform data directory via EvoGit.Platform),
  using namespaced keys `{:project, path}`.
  """
  use GenServer

  require Logger

  alias EvoDash.TaskInfo

  @max_recent_projects 10

  @lease_duration 120
  @heartbeat_interval 60_000
  # One-shot lease sweep delay: longer than the lease duration so the lease has
  # definitely expired by the time the sweep fires. The +30 buffer avoids a race
  # where the owner died right after a renewal.
  @sweep_after (@lease_duration + 30) * 1000

  ## Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_task(task_type, opts) do
    task_id = generate_id()
    GenServer.call(__MODULE__, {:start_task, task_id, task_type, opts})
  end

  def get_task(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id})
  end

  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks)
  end

  def cancel_task(task_id) do
    GenServer.call(__MODULE__, {:cancel_task, task_id})
  end

  def update_task_status(task_id, status, result \\ nil, opts \\ []) do
    GenServer.cast(__MODULE__, {:update_status, task_id, status, result, opts})
  end

  defp update_task_status_with_caller(task_id, status, result, opts) do
    GenServer.cast(
      __MODULE__,
      {:update_status, task_id, status, result, opts, {self(), capture_stacktrace(5)}}
    )
  end

  def update_task_log(task_id, log_entry) do
    GenServer.cast(__MODULE__, {:append_log, task_id, log_entry})
  end

  def set_review_status(task_id, status) do
    GenServer.cast(__MODULE__, {:set_review_status, task_id, status})
  end

  def set_review_metadata(task_id, base_sha, commit_sha) do
    GenServer.cast(__MODULE__, {:set_review_metadata, task_id, base_sha, commit_sha})
  end

  def list_tasks_by_path(path) do
    GenServer.call(__MODULE__, {:list_tasks_by_path, path})
  end

  def get_unique_paths do
    GenServer.call(__MODULE__, :get_unique_paths)
  end

  def delete_task(task_id) do
    GenServer.cast(__MODULE__, {:delete_task, task_id})
  end

  def clear_finished_tasks do
    GenServer.call(__MODULE__, :clear_finished_tasks)
  end

  ## Recent Projects Client API

  @doc """
  Adds or updates a project in the recently opened list.
  Moves it to the top with the current timestamp.
  """
  def add_recent_project(path, name) do
    GenServer.call(__MODULE__, {:add_recent_project, path, name})
  end

  @doc """
  Returns the list of recently opened projects, sorted by last_opened_at descending.
  """
  def list_recent_projects do
    GenServer.call(__MODULE__, :list_recent_projects)
  end

  @doc """
  Removes a project from the recent list by path.
  """
  def remove_recent_project(path) do
    GenServer.call(__MODULE__, {:remove_recent_project, path})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Allow data_dir to be overridden via opts (for testing), fallback to config
    # then platform default. Tests set `config :evo_dash, :data_dir` to a temp dir.
    data_dir = Keyword.get(opts, :data_dir, Application.get_env(:evo_dash, :data_dir, EvoGit.Platform.data_dir()))
    File.mkdir_p!(data_dir)

    # The TaskStore is started by the supervisor; here just reference by name.
    # Tests may pass their own task_store: name pointing to a test store.
    task_store = Keyword.get(opts, :task_store, EvoDash.Store)

    state = %{
      data_dir: data_dir,
      task_store: task_store,
      task_refs: %{}
    }

    # Repair the store from any corrupt (un-deserializable) entries before we
    # read or normalize anything. integrity_check returns {:error, _} for
    # problems rather than raising, so no rescue is needed here.
    EvoDash.Store.integrity_check(task_store)

    # Normalize SQLite entries in place (backfill fields, reset crashed tasks,
    # and re-monitor any tasks whose processes are still alive under the sibling
    # TaskSupervisor).
    state = normalize_tasks(state)

    # Cleanup expired tasks on startup
    cleanup_expired_tasks(state)

    # Subscribe to task status events from EvoGit.PubSub
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    Logger.warning(
      "TaskRegistry: INIT_LOGGING_V3 started, task_refs=#{inspect(map_size(state.task_refs))}"
    )

    # Start the periodic heartbeat timer for lease renewal (owned tasks only).
    # The sweep is NOT periodic — it fires once at startup (via reconcile) and
    # once more after the lease duration to catch owners that died around our
    # startup. After that, any new foreign instance does its own pair of checks.
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    Process.send_after(self(), :lease_sweep, @sweep_after)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:start_task, task_id, task_type, opts}, _from, state) do
    task_ref =
      Task.Supervisor.async_nolink(
        EvoDash.TaskSupervisor,
        __MODULE__,
        :execute_task,
        [task_type, opts, task_id]
      )

    task = %TaskInfo{
      id: task_id,
      type: task_type,
      status: :running,
      opts: opts,
      ref: task_ref,
      pid: task_ref.pid,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil,
      lease_expires_at: System.system_time(:second) + @lease_duration
    }

    # Persist to SQLite with ref nulled (ref is runtime-only data)
    EvoDash.Store.put_task(state.task_store, %{task | ref: nil})

    # Keep the runtime ref in-memory only
    state = %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, {:ok, task}, state}
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task = task_get(state, task_id)
    {:reply, task, state}
  end

  @impl true
  def handle_call(:list_tasks, _from, state) do
    tasks = select_all_tasks(state)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    {result, state} =
      case task_get(state, task_id) do
        %TaskInfo{status: :running} = task ->
          case Map.get(state.task_refs, task_id) do
            %Task{pid: pid} = task_ref ->
              if Process.alive?(pid) do
                # Notify the AgentScheduler to cancel all agents for this task
                # before killing the wrapper process. The scheduler uses the caller PID
                # to find the matching top-level agent and cascade cleanup to subagents.
                #
                # Justified catch :exit — cross-app boundary. The scheduler may
                # genuinely not be running (or the GenServer may be dead), in which
                # case the GenServer call raises an exit (not a rescue-able
                # exception). We always proceed to brutal_kill the wrapper
                # regardless, so we log the exit and continue.
                try do
                  EvoGit.AgentScheduler.cancel_task_agents(pid)
                catch
                  :exit, reason ->
                    Logger.warning(
                      "TaskRegistry: AgentScheduler cancel failed (exit): #{inspect(reason)}"
                    )
                end

                Task.shutdown(task_ref, :brutal_kill)
                updated = %{task | status: :cancelled, finished_at: DateTime.utc_now(), lease_expires_at: nil}
                EvoDash.Store.put_task(state.task_store, updated)
                cleanup_expired_tasks(state)
                state = %{state | task_refs: Map.delete(state.task_refs, task_id)}
                {:ok, state}
              else
                {{:error, :not_running}, state}
              end

            nil ->
              {{:error, :not_running}, state}
          end

        %TaskInfo{} ->
          {{:error, :not_running}, state}

        nil ->
          {{:error, :not_found}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tasks_by_path, path}, _from, state) do
    expanded = Path.expand(path)

    tasks =
      select_all_tasks(state)
      |> Enum.filter(fn task ->
        task.opts[:path] && Path.expand(task.opts[:path]) == expanded
      end)

    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:get_unique_paths, _from, state) do
    paths =
      select_all_tasks(state)
      |> Enum.map(fn task -> task.opts[:path] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:reply, paths, state}
  end

  @impl true
  def handle_call(:clear_finished_tasks, _from, state) do
    task_ids =
      select_all_tasks(state)
      |> Enum.filter(fn task -> task.status not in [:running, :pending] end)
      |> Enum.map(fn task -> task.id end)

    EvoDash.Store.delete_tasks(state.task_store, task_ids)

    cleanup_expired_tasks(state)
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:reply, :ok, state}
  end

  ## Recent Projects Handlers

  @impl true
  def handle_call({:add_recent_project, path, name}, _from, state) do
    now = DateTime.utc_now()

    EvoDash.Store.put_project(
      state.task_store,
      %EvoDash.RecentProject{path: path, name: name, last_opened_at: now}
    )

    # Enforce max limit
    trim_recent_projects(state)

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_recent_projects, _from, state) do
    reply =
      select_all_projects(state)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:remove_recent_project, path}, _from, state) do
    EvoDash.Store.delete_project(state.task_store, path)

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update_status, task_id, status, result, opts}, state) do
    {:noreply, handle_update_status(state, task_id, status, result, opts, nil)}
  end

  def handle_cast({:update_status, task_id, status, result, opts, caller_info}, state) do
    {:noreply, handle_update_status(state, task_id, status, result, opts, caller_info)}
  end

  @impl true
  def handle_cast({:append_log, task_id, log_entry}, state) do
    case task_get(state, task_id) do
      %TaskInfo{logs: logs} = task ->
        updated = %{task | logs: [log_entry | logs]}
        EvoDash.Store.put_task(state.task_store, updated)

      nil ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    EvoDash.Store.delete_task(state.task_store, task_id)

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_status, task_id, status}, state) do
    case task_get(state, task_id) do
      %TaskInfo{} = task ->
        updated = %{task | review_status: status}
        EvoDash.Store.put_task(state.task_store, updated)

      nil ->
        :ok
    end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_metadata, task_id, base_sha, commit_sha}, state) do
    case task_get(state, task_id) do
      %TaskInfo{} = task ->
        updated = %{task | base_sha: base_sha, commit_sha: commit_sha}
        EvoDash.Store.put_task(state.task_store, updated)

      nil ->
        :ok
    end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    {:noreply, state}
  end

  # Shared implementation for the :update_status cast handlers (5- and 6-tuple
  # variants). The optional caller_info is {pid, stacktrace} captured at the
  # call site by update_task_status_with_caller/4, or nil for the plain
  # update_task_status/4 API.
  defp handle_update_status(state, task_id, status, result, opts, caller_info) do
    usage = Keyword.get(opts, :usage)
    agent_count = Keyword.get(opts, :agent_count)
    commit_sha = Keyword.get(opts, :commit_sha)
    archive_records = Keyword.get(opts, :archive_records)

    state =
      case task_get(state, task_id) do
        %TaskInfo{} = task ->
          if task.status in [:completed, :failed, :cancelled] and
               status in [:completed, :failed, :cancelled] and
               task.status != status and
               status != :completed do
            Logger.warning(
              "TaskRegistry: Ignoring stale status update for task #{task_id}: " <>
                "already #{task.status}, ignoring #{status}"
            )

            state
          else
            # Log any transition INTO :failed that isn't already :failed.
            if status == :failed and task.status != :failed do
              log_failed_transition(task_id, :update_status_cast, task.status,
                result: result,
                caller_info: caller_info
              )
            end

            finished_at =
              if status in [:completed, :failed, :cancelled],
                do: DateTime.utc_now(),
                else: task.finished_at

            updated = %{task | status: status, result: result, finished_at: finished_at}
            updated = if usage, do: %{updated | usage: usage}, else: updated
            updated = if agent_count, do: %{updated | agent_count: agent_count}, else: updated
            updated = if commit_sha, do: %{updated | commit_sha: commit_sha}, else: updated

            updated =
              if archive_records,
                do: %{updated | archive_metadata: archive_records},
                else: updated

            updated =
              if status in [:completed, :failed, :cancelled],
                do: %{updated | lease_expires_at: nil},
                else: updated

            EvoDash.Store.put_task(state.task_store, updated)

            if status in [:completed, :failed, :cancelled] do
              cleanup_expired_tasks(state)
              %{state | task_refs: Map.delete(state.task_refs, task_id)}
            else
              state
            end
          end

        nil ->
          state
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    state
  end

  ## Public Task Functions

  @doc """
  Execute a task. This function runs in a separate process under Task.Supervisor.
  """
  def execute_task(:genesis, opts, task_id) do
    {_input_arg, runtime_opts} = build_common_runtime_opts(opts, task_id)
    prompt = Keyword.get(opts, :prompt, "")
    EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
  end

  def execute_task(:evolve, opts, task_id) do
    resume_from = Keyword.get(opts, :resume_from)

    {objective, runtime_opts} =
      if is_binary(resume_from) and String.trim(resume_from) != "" do
        apply_resume_context(opts, task_id, String.trim(resume_from))
      else
        objective = Keyword.get(opts, :objective, "")
        {_input_arg, runtime_opts} = build_common_runtime_opts(opts, task_id)
        {objective, runtime_opts}
      end

    EvoGit.Runtime.Evolution.run(objective, runtime_opts)
  end

  def execute_task(:extract_skills, opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    Application.ensure_all_started(:evo_git)

    runtime_opts = [repo_path: repo_path, task_id: task_id]

    # Pass through PR context keys to the runtime
    pr_context_keys = [
      :pr_title,
      :pr_objective,
      :pr_summary,
      :pr_commit_history,
      :base_sha,
      :commit_sha,
      :user_note,
      :foreign_repos
    ]

    runtime_opts =
      Enum.reduce(pr_context_keys, runtime_opts, fn key, acc ->
        case Keyword.get(opts, key) do
          nil -> acc
          value -> Keyword.put(acc, key, value)
        end
      end)

    EvoGit.Runtime.SkillExtraction.run(runtime_opts)
  end

  ## Private Functions

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # --- TaskStore Read Helpers ---

  defp task_get(state, task_id) do
    EvoDash.Store.get_task(state.task_store, task_id)
  end

  defp select_all_tasks(state) do
    EvoDash.Store.safe_select_all_tasks(state.task_store)
  end

  defp select_all_projects(state) do
    EvoDash.Store.safe_select_all_projects(state.task_store)
  end

  # --- Task Normalization ---

  defp normalize_tasks(state) do
    objects = select_all_tasks(state)

    Enum.reduce(objects, state, fn %TaskInfo{} = task, acc ->
      # Backfill safety: Map.merge ensures any newly-added TaskInfo fields
      # get their default values even if the codec produced a struct missing
      # them. When task is already a complete %TaskInfo{}, this is a no-op.
      task = Map.merge(%TaskInfo{}, task)
      {task, acc} = reconcile_task_status(task, acc)
      # Persist with ref nulled (ref is runtime-only data)
      EvoDash.Store.put_task(state.task_store, %{task | ref: nil})
      acc
    end)
  end

  # Reconcile a task's status after a registry restart.
  # Running/pending tasks that are still alive (pid exists and Process.alive?/1)
  # are kept as :running and re-monitored. Dead or pid-less tasks are evaluated
  # using lease-based logic: a running task is only marked :failed if its lease
  # has ACTUALLY expired (not just because the pid is dead/foreign). This prevents
  # a second BEAM VM instance from incorrectly marking the first instance's
  # running tasks as :failed. Other statuses are left unchanged.
  defp reconcile_task_status(%TaskInfo{status: status} = task, state)
       when status in [:running, :pending] do
    if task.pid != nil and Process.alive?(task.pid) do
      # Task process is still alive under the sibling TaskSupervisor.
      # Re-monitor, re-own, renew lease.
      ref = Process.monitor(task.pid)
      # Construct a %Task{} matching the shape of a Task.Supervisor task ref so
      # that the existing pattern matches (%Task{pid:, ref:, owner:}) keep
      # working. :mfa is required by the struct but unused for re-monitors.
      task_ref = %Task{pid: task.pid, ref: ref, owner: self(), mfa: nil}

      Logger.warning("TaskRegistry: re-monitoring still-running task #{task.id} after restart")

      now = System.system_time(:second)

      {%{task | status: :running, ref: nil, lease_expires_at: now + @lease_duration},
       %{state | task_refs: Map.put(state.task_refs, task.id, task_ref)}}
    else
      # Pid is nil or dead — foreign instance or crashed wrapper.
      if lease_valid?(task.lease_expires_at) do
        # Lease hasn't expired — the owning instance is still alive.
        # Do NOT mark failed. Do NOT add to task_refs (we don't own it).
        # The one-shot :lease_sweep (scheduled in init) will catch it if the
        # lease eventually expires — no periodic recheck needed.
        Logger.info(
          "TaskRegistry: task #{task.id} has dead pid but valid lease " <>
            "(expires_at=#{inspect(task.lease_expires_at)}) — leaving :running for lease sweep"
        )

        {%{task | status: :running, ref: nil}, state}
      else
        # Lease expired (nil or in the past). Check if AgentScheduler still has
        # active agents (same-VM recovery edge case).
        if sched_meta_has_active_agents?(task.id) do
          Logger.warning(
            "TaskRegistry: task #{task.id} lease expired but has active agents — scheduling recheck"
          )

          Process.send_after(self(), {:recheck_task, task.id}, 30_000)
          {%{task | status: :running, ref: nil}, state}
        else
          # Lease expired AND no active agents — the owner is genuinely gone.
          prev_status = task.status

          log_failed_transition(task.id, :reconcile, prev_status,
            result: "Lease expired; process crashed while task was running",
            extra: [
              pid_dead_or_nil: true,
              lease_expires_at: inspect(task.lease_expires_at),
              sched_meta_has_active_agents: false
            ]
          )

          {%{task | status: :failed, ref: nil, lease_expires_at: nil} |> set_crash_details(), state}
        end
      end
    end
  end

  defp reconcile_task_status(%TaskInfo{} = task, state) do
    {%{task | ref: nil}, state}
  end

  # Checks the :evogit_sched_meta ETS table for active agents belonging to the
  # given task_id. The table stores {id, %SchedMeta{task_id: ..., status: ...}}.
  # Terminal agents are removed from the table, so ANY entry for this task_id
  # means agents are still active. Returns false if the table doesn't exist.
  # Uses :ets.info/1 which returns :undefined for missing/nonexistent tables
  # (non-crashing) — no try/rescue needed.
  defp sched_meta_has_active_agents?(task_id) do
    case :ets.info(:evogit_sched_meta) do
      :undefined ->
        false

      _ ->
        :evogit_sched_meta
        |> :ets.tab2list()
        |> Enum.any?(fn {_id, meta} ->
          Map.get(meta, :task_id) == task_id
        end)
    end
  end

  # Best-effort result lookup from the :evogit_sched_meta ETS table for a given
  # task_id. Scans all entries for this task and looks for a top-level agent
  # (parent_id == nil) that has accumulated a result in its sched_meta. The
  # scheduler stores the final result in the SchedMeta before deleting it, so if
  # any entry still exists, it may carry the result.
  #
  # Returns `{:ok, _}`, `{:error, _}`, `{:exit, _}` if a recognizable result is
  # found, or `nil` if no result is available. Uses :ets.info/1 for table
  # existence (non-crashing) per the codebase's ETS convention.
  defp lookup_sched_meta_result(task_id) do
    case :ets.info(:evogit_sched_meta) do
      :undefined ->
        nil

      _ ->
        :evogit_sched_meta
        |> :ets.tab2list()
        |> Enum.find_value(fn {_id, meta} ->
          if Map.get(meta, :task_id) == task_id and Map.get(meta, :parent_id) == nil do
            # Check if this top-level agent has a result in its sub_agent_results
            # or if result_sent is true. The actual result value isn't stored in
            # sched_meta (it's delivered via GenServer.reply), so this is a
            # heuristic check.
            Map.get(meta, :sub_agent_results) |> Map.values() |> List.first()
          end
        end)
    end
  end

  # Returns true if the lease has not yet expired (is a future timestamp).
  # nil means no lease → not valid → eligible for cleanup.
  defp lease_valid?(nil), do: false

  defp lease_valid?(expires_at) do
    System.system_time(:second) < expires_at
  end

  defp set_crash_details(%{status: :failed, finished_at: nil} = task) do
    %{task | finished_at: DateTime.utc_now(), result: "Process crashed while task was running"}
  end

  defp set_crash_details(task), do: task

  # Shared result-recovery logic used by handle_info({:recheck_task, _}). The
  # wrapper process is dead so the runtime result was lost (delivered via
  # GenServer.reply to a dead process). We try a best-effort result lookup from
  # the sched_meta ETS table. If nothing definitive is found, we mark the task
  # :completed — agents finished without a recorded failure, so treating it as
  # completed is the least surprising outcome.
  defp resolve_recheck_task(state, task_id, %TaskInfo{} = task) do
    result = lookup_sched_meta_result(task_id)

    {final_status, final_result} =
      case result do
        {:ok, _} = ok ->
          {:completed, ok}

        {:error, _} = err ->
          {:failed, err}

        {:exit, _} = exit_val ->
          {:failed, exit_val}

        nil ->
          Logger.warning(
            "TaskRegistry: recheck resolved task #{task_id} — no result found, " <>
              "marking :completed (agents finished, wrapper was dead)"
          )

          {:completed, nil}
      end

    if final_status == :failed do
      log_failed_transition(task_id, :recheck_resolve, task.status, result: final_result)
    end

    finished_at = DateTime.utc_now()

    updated = %{
      task
      | status: final_status,
        result: final_result,
        finished_at: finished_at,
        lease_expires_at: nil
    }

    EvoDash.Store.put_task(state.task_store, updated)
    cleanup_expired_tasks(state)

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})

    Logger.info(
      "TaskRegistry: recheck resolved task #{task_id} to #{final_status}"
    )

    {:noreply, state}
  end

  # --- Failed-Transition Diagnostic Logging ---
  #
  # When a task transitions to :failed from an unexpected path, it's hard to
  # determine which code path triggered it. Every site that can set a task to
  # :failed calls log_failed_transition/4 with a consistent, greppable prefix
  # ("TaskRegistry: FAILED_TRANSITION") so occurrences can be diagnosed.

  @failed_transition_prefix "TaskRegistry: FAILED_TRANSITION"

  # Logs a consistent, greppable warning whenever a task transitions to :failed.
  #
  # ## Parameters
  #   - `task_id`     — the task being marked failed
  #   - `source`      — an atom identifying the code path (e.g. :result_handler,
  #                     :down_handler, :reconcile, :task_status_pubsub,
  #                     :update_status_cast)
  #   - `prev_status` — the status BEFORE transitioning to :failed (may be nil
  #                     if the task couldn't be found)
  #   - `opts`        — keyword list of extra context:
  #       * `:result`       — the result/reason value, if any
  #       * `:extra`        — a keyword list of additional diagnostic fields
  #       * `:caller_info`  — `{pid, stacktrace}` captured at the call site (for
  #                           cast-based transitions via update_task_status/4)
  #
  # The log captures a short stacktrace of the CURRENT process at the point of
  # transition, so the user can see WHO triggered it. For cast-based transitions
  # (where the actual setter is the GenServer, not the original caller), the
  # caller's pid + stacktrace are included via `caller_info`.
  defp log_failed_transition(task_id, source, prev_status, opts) do
    result = Keyword.get(opts, :result)
    extra = Keyword.get(opts, :extra, [])
    caller_info = Keyword.get(opts, :caller_info)

    # Current stacktrace (the GenServer process for most paths).
    stacktrace = format_stacktrace(capture_stacktrace(5))

    # Caller info (captured in the caller's process for cast-based transitions).
    caller_str =
      case caller_info do
        {caller_pid, caller_stack} when is_pid(caller_pid) ->
          "caller_pid=#{inspect(caller_pid)} caller_stack=\n#{format_stacktrace(caller_stack)}"

        _ ->
          "caller_pid=N/A (same-process transition)"
      end

    extra_str =
      case extra do
        [] -> ""
        fields -> " " <> Enum.map_join(fields, " ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
      end

    Logger.warning(
      "#{@failed_transition_prefix} task_id=#{task_id} source=#{source} " <>
        "prev_status=#{inspect(prev_status)} result=#{inspect(result)}#{extra_str}\n" <>
        "  current_stacktrace=\n#{stacktrace}\n" <>
        "  #{caller_str}"
    )
  end

  # Captures up to `n` frames of the current process stacktrace, skipping the
  # internal logging helper frames (capture_stacktrace/log_failed_transition) so
  # the first visible frame is the actual handler that triggered the transition.
  # GenServer dispatch frames are also skipped. Returns a list of stacktrace
  # entries. Note: we keep __MODULE__ frames because those are the handlers
  # (handle_info/handle_cast/reconcile_task_status) that identify the caller.
  defp capture_stacktrace(n) do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)

    trace
    |> Enum.drop_while(fn
      {Process, :info, _, _} ->
        true

      {mod, fun, _, _}
      when mod == __MODULE__ and fun in [:capture_stacktrace, :log_failed_transition] ->
        true

      {:gen_server, _, _, _} ->
        true

      _ ->
        false
    end)
    |> Enum.take(n)
  end

  # Formats a stacktrace (list of {module, function, arity_or_file_info, location})
  # into a readable, indented string, one frame per line.
  defp format_stacktrace([]), do: "  (no stacktrace available)"

  defp format_stacktrace(trace) do
    Enum.map_join(trace, "\n", fn frame ->
      "    #{format_stacktrace_frame(frame)}"
    end)
  end

  defp format_stacktrace_frame({module, function, arity, location}) do
    loc = format_location(location)
    fun = format_function(function, arity)
    "#{inspect(module)}.#{fun}#{loc}"
  end

  defp format_stacktrace_frame(other), do: "    #{inspect(other)}"

  defp format_function(name, arity) when is_atom(name) and is_integer(arity),
    do: "#{name}/#{arity}"

  defp format_function(name, args) when is_atom(name) and is_list(args),
    do: "#{name}(#{length(args)})"

  defp format_function(other, _), do: inspect(other)

  defp format_location([{file, line} | _]) when is_list(file) and is_integer(line),
    do: " at #{List.to_string(file)}:#{line}"

  defp format_location(_), do: ""

  defp task_history_config do
    defaults = %{max_tasks: 100, max_age_days: 14}
    config = EvoGit.Config.resolve()[:task_history] || %{}
    Map.merge(defaults, config)
  end

  defp cleanup_expired_tasks(state) do
    config = task_history_config()
    max_age_days = config.max_age_days
    max_tasks = config.max_tasks
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 24 * 60 * 60, :second)

    all_tasks = select_all_tasks(state)

    # Partition: age-expired finished tasks vs everything else
    {age_expired, remaining} =
      Enum.split_with(all_tasks, fn task ->
        task.finished_at != nil and DateTime.compare(task.finished_at, cutoff) == :lt
      end)

    age_expired_keys = Enum.map(age_expired, fn task -> task.id end)

    # From remaining finished tasks, enforce max_tasks limit (keep newest)
    over_limit_keys =
      remaining
      |> Enum.filter(&(&1.finished_at != nil))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
      |> Enum.drop(max_tasks)
      |> Enum.map(fn task -> task.id end)

    all_keys = age_expired_keys ++ over_limit_keys

    if all_keys != [] do
      EvoDash.Store.delete_tasks(state.task_store, all_keys)
    end

    :ok
  end

  # --- Recent Projects ---

  defp trim_recent_projects(state) do
    projects =
      select_all_projects(state)
      |> Enum.sort_by(& &1.last_opened_at, {:desc, DateTime})

    case Enum.split(projects, @max_recent_projects) do
      {_kept, []} ->
        :ok

      {_kept, to_remove} ->
        paths = Enum.map(to_remove, fn project -> project.path end)
        Enum.each(paths, &EvoDash.Store.delete_project(state.task_store, &1))
        :ok
    end
  end

  # --- Task Execution Helpers ---

  # Builds the objective and runtime_opts for an evolve task that resumes from
  # a previous task. Injects the previous task's context (commits, objective,
  # result) into the new objective and sets :starting_commit to the previous
  # task's end commit. Falls back gracefully if the previous task can't be
  # found or has no useful data.
  defp apply_resume_context(opts, task_id, resume_from_id) do
    # Strip :resume_from so it never leaks into the runtime opts.
    opts_without_resume = Keyword.delete(opts, :resume_from)

    prev_task = get_task(resume_from_id)

    {objective, runtime_opts} =
      if is_nil(prev_task) do
        # Previous task not found — run with the original objective.
        objective = Keyword.get(opts_without_resume, :objective, "")
        {_input_arg, runtime_opts} = build_common_runtime_opts(opts_without_resume, task_id)
        {objective, runtime_opts}
      else
        context_block = build_resume_context_block(prev_task)

        objective = Keyword.get(opts_without_resume, :objective, "")

        objective =
          if context_block != "", do: context_block <> "\n\n" <> objective, else: objective

        # The previous task's commit_sha takes priority as :starting_commit.
        prev_commit_sha = prev_task.commit_sha

        opts_with_commit =
          if is_binary(prev_commit_sha) and prev_commit_sha != "" do
            Keyword.put(opts_without_resume, :starting_commit, prev_commit_sha)
          else
            opts_without_resume
          end

        {_input_arg, runtime_opts} = build_common_runtime_opts(opts_with_commit, task_id)
        {objective, runtime_opts}
      end

    {objective, runtime_opts}
  end

  defp build_resume_context_block(%TaskInfo{} = prev_task) do
    base_sha = prev_task.base_sha
    commit_sha = prev_task.commit_sha

    commits_line =
      cond do
        is_binary(base_sha) and base_sha != "" and is_binary(commit_sha) and commit_sha != "" ->
          "#{base_sha}..#{commit_sha}"

        is_binary(commit_sha) and commit_sha != "" ->
          commit_sha

        true ->
          nil
      end

    old_objective =
      case prev_task.opts do
        opts when is_list(opts) -> Keyword.get(opts, :objective) || Keyword.get(opts, :prompt)
        _ -> nil
      end

    agent_response = extract_result_summary(prev_task.result)

    parts = []

    parts =
      if commits_line do
        parts ++ ["Previous task commits: #{commits_line}"]
      else
        parts
      end

    parts =
      if is_binary(old_objective) and old_objective != "" do
        parts ++ ["Previous task objective: #{old_objective}"]
      else
        parts
      end

    parts =
      if is_binary(agent_response) and agent_response != "" do
        parts ++ ["Previous task result:", agent_response]
      else
        parts
      end

    if parts == [] do
      ""
    else
      "--- Previous Task Context ---\n" <>
        Enum.join(parts, "\n") <> "\n--- End Previous Task Context ---"
    end
  end

  defp build_resume_context_block(_), do: ""

  defp extract_result_summary({:ok, %{result: summary}}) when is_binary(summary), do: summary

  defp extract_result_summary({:ok, %{result: summary}}) when is_atom(summary),
    do: to_string(summary)

  defp extract_result_summary({:error, reason}), do: "Error: #{inspect(reason)}"
  defp extract_result_summary({:exit, reason}), do: "Exited: #{inspect(reason)}"
  defp extract_result_summary(_), do: nil

  defp build_common_runtime_opts(opts, task_id) do
    repo_path = Keyword.fetch!(opts, :path)
    mode = Keyword.get(opts, :mode, "simple")
    node_path = Keyword.get(opts, :node_path)

    Application.ensure_all_started(:evo_git)

    runtime_opts = [
      repo_path: repo_path,
      mode: evolution_mode_atom(mode),
      task_id: task_id
    ]

    runtime_opts =
      if node_path, do: Keyword.put(runtime_opts, :node_path, node_path), else: runtime_opts

    seed_content = Keyword.get(opts, :seed_content)

    runtime_opts =
      if seed_content,
        do: Keyword.put(runtime_opts, :seed_content, seed_content),
        else: runtime_opts

    starting_commit = Keyword.get(opts, :starting_commit)

    runtime_opts =
      if starting_commit,
        do: Keyword.put(runtime_opts, :starting_commit, starting_commit),
        else: runtime_opts

    # Foreign repos are passed through opts from the dashboard (per-task scoping)
    foreign_repos = Keyword.get(opts, :foreign_repos)

    runtime_opts =
      if foreign_repos,
        do: Keyword.put(runtime_opts, :foreign_repos, foreign_repos),
        else: runtime_opts

    archive = Keyword.get(opts, :archive)

    runtime_opts =
      if archive,
        do: Keyword.put(runtime_opts, :archive, archive),
        else: runtime_opts

    {nil, runtime_opts}
  end

  defp evolution_mode_atom("simple"), do: :simple
  defp evolution_mode_atom("complex"), do: :complex

  defp evolution_mode_atom(other),
    do: raise(ArgumentError, "invalid evolution mode: #{inspect(other)}")

  ## GenServer Info Handlers

  @impl true
  def handle_info({:task_status, task_id, status}, state) do
    state =
      case task_get(state, task_id) do
        %TaskInfo{} = task ->
          if task.status in [:completed, :cancelled] do
            Logger.debug(
              "TaskRegistry: Ignoring stale :task_status update for task #{task_id}: " <>
                "already terminal (#{task.status}), ignoring #{status}"
            )

            state
          else
            # Log any transition INTO :failed. The core runtime normally only
            # broadcasts :finalizing on this topic, so :failed here is unexpected.
            if status == :failed do
              log_failed_transition(task_id, :task_status_pubsub, task.status, result: nil)
            end

            finished_at =
              if status in [:completed, :failed, :cancelled],
                do: DateTime.utc_now(),
                else: task.finished_at

            updated = %{task | status: status, finished_at: finished_at}
            updated = if status in [:completed, :failed, :cancelled],
                       do: %{updated | lease_expires_at: nil}, else: updated
            EvoDash.Store.put_task(state.task_store, updated)

            if status in [:completed, :failed, :cancelled] do
              cleanup_expired_tasks(state)
              %{state | task_refs: Map.delete(state.task_refs, task_id)}
            else
              state
            end
          end

        nil ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Search the in-memory task_refs map for the matching task reference
    task_id =
      Enum.find_value(state.task_refs, fn {id, %Task{ref: task_ref}} ->
        if task_ref == ref, do: id
      end)

    if task_id do
      status =
        case result do
          {:ok, _} ->
            :completed

          {:error, reason} ->
            Logger.warning("TaskRegistry: Task #{task_id} returned error: #{inspect(reason)}")
            :failed

          {:exit, reason} ->
            Logger.warning("TaskRegistry: Task #{task_id} exited: #{inspect(reason)}")
            :failed

          other ->
            Logger.warning(
              "TaskRegistry: Task #{task_id} returned unexpected result shape: #{inspect(other)}"
            )

            :failed
        end

      # Log the failed transition with the result value and current stacktrace.
      if status == :failed do
        prev_status =
          case task_get(state, task_id) do
            %TaskInfo{status: s} -> s
            nil -> nil
          end

        log_failed_transition(task_id, :result_handler, prev_status, result: result)
      end

      task_usage =
        case result do
          {:ok, %{usage: %EvoGit.Agent.Usage{} = u}} -> u
          _ -> nil
        end

      task_agent_count =
        case result do
          {:ok, %{agent_count: count}} when is_integer(count) -> count
          _ -> nil
        end

      task_commit_sha =
        case result do
          {:ok, %{commit_sha: sha}} when is_binary(sha) -> sha
          _ -> nil
        end

      task_archive_records =
        case result do
          {:ok, %{archive_records: records}} when is_list(records) -> records
          _ -> nil
        end

      update_task_status_with_caller(task_id, status, result,
        usage: task_usage,
        agent_count: task_agent_count,
        commit_sha: task_commit_sha,
        archive_records: task_archive_records
      )
    end

    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    task_id =
      Enum.find_value(state.task_refs, fn {id, %Task{ref: task_ref}} ->
        if task_ref == ref, do: id
      end)

    if task_id do
      case reason do
        :normal ->
          # Normal completion via :DOWN (task returned a result and exited cleanly).
          # The {ref, result} handler should have already processed this, but handle
          # the edge case where {ref, result} was somehow missed.
          update_task_status(task_id, :completed)

        reason ->
          Logger.warning(
            "TaskRegistry: Task #{task_id} wrapper process #{inspect(pid)} exited abnormally: #{inspect(reason)}. " <>
              "Checking if AgentScheduler still has active agents before marking as failed."
          )

          # Check if the AgentScheduler still has active agents for this task.
          # If so, the wrapper crashed but the real work is still ongoing — do NOT
          # mark as failed. The task will complete normally when the scheduler
          # eventually finishes and the result arrives via a different mechanism.
          if sched_meta_has_active_agents?(task_id) do
            Logger.info(
              "TaskRegistry: Task #{task_id} still has active agents in AgentScheduler — keeping as :running despite wrapper crash"
            )

            # Do NOT update status — leave as :running
          else
            # No active agents — genuine failure
            prev_status =
              case task_get(state, task_id) do
                %TaskInfo{status: s} -> s
                nil -> nil
              end

            log_failed_transition(task_id, :down_handler, prev_status,
              result: "Task process exited: #{inspect(reason)}",
              extra: [
                pid: inspect(pid),
                exit_reason: inspect(reason),
                sched_meta_has_active_agents: false
              ]
            )

            update_task_status_with_caller(
              task_id,
              :failed,
              "Task process exited: #{inspect(reason)}",
              []
            )
          end
      end
    end

    {:noreply, state}
  end

  # Periodic heartbeat handler. Renews leases for ALL tasks this registry owns
  # (in task_refs that are running/pending), so that we remain the authoritative
  # owner. This is purely renewal — no sweeping happens here. Reschedules itself.
  @impl true
  def handle_info(:heartbeat, state) do
    now = System.system_time(:second)

    # Renew leases for owned tasks (those in task_refs).
    Enum.each(state.task_refs, fn {task_id, _ref} ->
      case task_get(state, task_id) do
        %TaskInfo{status: s} = task when s in [:running, :pending] ->
          EvoDash.Store.put_task(state.task_store, %{task | lease_expires_at: now + @lease_duration})

        _ ->
          :ok
      end
    end)

    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    {:noreply, state}
  end

  # One-shot lease-expiry sweep handler. Sweeps ALL running tasks we DON'T own
  # with expired leases and no active sched_meta agents, marking them :failed
  # (the owning instance is gone). This fires once (scheduled in init after the
  # lease duration) and does NOT reschedule itself — any new foreign instance
  # performs its own pair of checks on its own startup.
  @impl true
  def handle_info(:lease_sweep, state) do
    owned_ids = MapSet.new(Map.keys(state.task_refs))

    # Track whether any task was actually marked failed so we only
    # broadcast/cleanup when something changed.
    changed =
      select_all_tasks(state)
      |> Enum.filter(fn task ->
        task.status == :running and
          task.id not in owned_ids and
          not lease_valid?(task.lease_expires_at)
      end)
      |> Enum.reduce(false, fn task, acc ->
        if sched_meta_has_active_agents?(task.id) do
          # Same VM, agents still active — skip (handled by :recheck_task)
          acc
        else
          log_failed_transition(task.id, :lease_sweep, task.status,
            result: "Lease expired; owning instance no longer renewing",
            extra: [lease_expires_at: inspect(task.lease_expires_at)]
          )

          updated = %{
            task
            | status: :failed,
              lease_expires_at: nil,
              finished_at: DateTime.utc_now(),
              result: "Lease expired; owning instance no longer renewing"
          }

          EvoDash.Store.put_task(state.task_store, updated)
          true
        end
      end)

    if changed do
      cleanup_expired_tasks(state)
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:tasks_updated})
    end

    {:noreply, state}
  end

  # Periodic recheck for tasks that had active agents but a dead wrapper pid at
  # reconcile time. The task could not be added to task_refs (no live process to
  # monitor), so the normal {ref, result} / {:DOWN, ...} handlers can never fire.
  # This handler periodically checks if agents are still active:
  #   - If YES: reschedule another check.
  #   - If NO: resolve the task. Since the wrapper process is dead, the runtime
  #     result was delivered via GenServer.reply to a dead process and is lost.
  #     We check the sched_meta ETS for any remaining entries (which may carry a
  #     result in sub_agent_results) as a best-effort lookup. If nothing
  #     definitive is found, we mark the task :completed — the agents finished
  #     without a recorded failure, so treating it as completed is the least
  #     surprising outcome.
  @impl true
  def handle_info({:recheck_task, task_id}, state) do
    case task_get(state, task_id) do
      nil ->
        # Task was cleaned up from the store — nothing to do.
        {:noreply, state}

      %TaskInfo{status: status} when status in [:completed, :failed, :cancelled] ->
        # Task already resolved via another path (e.g. PubSub update) — stop rechecking.
        {:noreply, state}

      %TaskInfo{} = task ->
        if sched_meta_has_active_agents?(task_id) do
          # Agents still active — reschedule another check.
          Process.send_after(self(), {:recheck_task, task_id}, 30_000)
          {:noreply, state}
        else
          resolve_recheck_task(state, task_id, task)
        end
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
