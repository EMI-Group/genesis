defmodule EvoGit.TaskRegistry do
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

  alias EvoGit.TaskInfo

  alias EvoGit.TaskRegistry.Cleanup
  alias EvoGit.TaskRegistry.Diagnostics
  alias EvoGit.TaskRegistry.Lease
  alias EvoGit.TaskRegistry.TaskExecutor

  ## Call timeout

  # GenServer self-calls can block on EvoGit.Store calls (SQLite I/O may be
  # very slow on high-latency storage like an NFS-mounted home directory), so
  # they use an explicit 30s timeout instead of the 5s default. Keep the value
  # tunable in one place.
  @call_timeout 30_000

  @max_recent_projects 10

  # Maximum number of log entries retained per task. Logs grow on every
  # update_task_log call and are stored as a JSON array in SQLite; without a
  # cap, each subsequent decode/encode in task_get grows unboundedly.
  @max_log_entries 500

  @lease_duration 120
  @heartbeat_interval 60_000
  # One-shot lease sweep delay: longer than the lease duration so the lease has
  # definitely expired by the time the sweep fires. The +30 buffer avoids a race
  # where the owner died right after a renewal.
  @sweep_after (@lease_duration + 30) * 1000

  # Default grace (minutes) for the stuck-:finalizing watchdog — overridable via
  # the app env :finalizing_watchdog_grace_minutes (see finalizing_watchdog_grace/0).
  @finalizing_watchdog_default_minutes 60

  ## Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start_task(task_type, opts) do
    task_id = TaskExecutor.generate_id()
    GenServer.call(__MODULE__, {:start_task, task_id, task_type, opts}, @call_timeout)
  end

  def get_task(task_id) do
    GenServer.call(__MODULE__, {:get_task, task_id}, @call_timeout)
  end

  def list_tasks do
    GenServer.call(__MODULE__, :list_tasks, @call_timeout)
  end

  @doc """
  Returns a paginated slice of tasks (most-recent-first) with the total count.

  `opts` is a keyword list accepting `:limit` and `:offset` (both forwarded
  to `EvoGit.Store.safe_select_paginated_tasks/2`). Returns `{tasks, total_count}`.
  """
  def list_tasks_paginated(opts \\ []) do
    GenServer.call(__MODULE__, {:list_tasks_paginated, opts}, @call_timeout)
  end

  @doc """
  Gracefully cancels a running (or pending) task by id.

  - `:pending` → marked `:cancelled` immediately (no agents exist yet) and a
    subsequent `start_task` for the same id is refused.
  - `:running` → status set to `:cancelling` (broadcast to the dashboard) and
    `AgentScheduler.begin_graceful_cancel/1` is invoked, which injects a
    cancel notification + `cancel_requested` flag into every agent of the task
    so they enter a grace period and finish cleanly. The task's final mapping
    to `:cancelled` (with result preserved) happens when the wrapper completes.
  - `:cancelling` → `:ok` (idempotent; does NOT re-send messages).

  Returns `:ok` on success, `{:error, :not_found}` for an unknown task, or
  `{:error, :not_running}` for terminal states (`:completed`/`:failed`/
  `:cancelled`) and `:finalizing`.

  For the brutal (no grace period) cancellation, use `force_kill_task/1`.
  """
  def cancel_task(task_id) do
    GenServer.call(__MODULE__, {:cancel_task, task_id}, @call_timeout)
  end

  @doc """
  Force-kills a running or cancelling task by id — the BRUTAL cancellation path.

  Kills every agent of the task (via `AgentScheduler.force_kill_task_agents/1`,
  reverse-depth cascade with `:brutal_kill`), then brutal-kills the wrapper
  process and persists the task as `:failed` with finished_at set, the lease
  cleared, and no result (result nil). Works from both `:running` (normal
  force-kill) and `:cancelling` (escalation path — a graceful cancel that
  hangs).

  Returns `:ok` on success, `{:error, :not_found}` for an unknown task, or
  `{:error, :not_running}` for other states.

  For the graceful cancellation, use `cancel_task/1`.
  """
  def force_kill_task(task_id) do
    GenServer.call(__MODULE__, {:force_kill_task, task_id}, @call_timeout)
  end

  def update_task_status(task_id, status, result \\ nil, opts \\ []) do
    GenServer.cast(__MODULE__, {:update_status, task_id, status, result, opts})
  end

  defp update_task_status_with_caller(task_id, status, result, opts) do
    GenServer.cast(
      __MODULE__,
      {:update_status, task_id, status, result, opts, {self(), Diagnostics.capture_stacktrace(5)}}
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
    GenServer.call(__MODULE__, {:list_tasks_by_path, path}, @call_timeout)
  end

  @doc """
  Returns lightweight task summaries for all tasks — only columns needed for
  the dashboard sidebar listing. Returns a list of plain maps.

  `statuses` is a list of status ATOMS; `[]` (default) means all statuses. When
  non-empty, the status filter is pushed into SQL.

  `since` is an optional fixed-precision ISO-8601 timestamp string; when
  non-nil, only tasks updated at or after `since` are returned (nil = no time
  filter). The filter is pushed into SQL.
  """
  def list_tasks_summary(statuses \\ [], since \\ nil) do
    GenServer.call(__MODULE__, {:list_tasks_summary, statuses, since}, @call_timeout)
  end

  @doc """
  Returns a minimal id/status/updated_at projection for tasks matching
  `statuses` (atoms; `[]` = all tasks).

  This is a lightweight query — only the `id`, `status`, and `updated_at`
  columns are read, no heavy JSON fields are decoded. `updated_at` is returned
  as the raw stored fixed-precision ISO string (not decoded to a DateTime).
  When `statuses` is non-empty, the status filter is pushed into SQL.
  """
  def list_task_ids(statuses \\ []) do
    GenServer.call(__MODULE__, {:list_task_ids, statuses}, @call_timeout)
  end

  @doc """
  Same as list_tasks_summary/2 but filtered to a specific project_path.
  """
  def list_tasks_summary_by_path(path, statuses \\ [], since \\ nil) do
    GenServer.call(
      __MODULE__,
      {:list_tasks_summary_by_path, path, statuses, since},
      @call_timeout
    )
  end

  @doc """
  Returns tasks created or updated at or after the given fixed-precision
  ISO-8601 timestamp string (`since_iso`). Delegates to
  `EvoGit.Store.select_tasks_changed_since/2`; returns a list of plain maps
  (id, status, updated_at, ...).
  """
  def list_tasks_changed_since(since_iso) do
    GenServer.call(__MODULE__, {:list_tasks_changed_since, since_iso}, @call_timeout)
  end

  def get_unique_paths do
    GenServer.call(__MODULE__, :get_unique_paths, @call_timeout)
  end

  def delete_task(task_id) do
    GenServer.cast(__MODULE__, {:delete_task, task_id})
  end

  def clear_finished_tasks do
    GenServer.call(__MODULE__, :clear_finished_tasks, @call_timeout)
  end

  ## Recent Projects Client API

  @doc """
  Adds or updates a project in the recently opened list.
  Moves it to the top with the current timestamp.
  """
  def add_recent_project(path, name) do
    GenServer.call(__MODULE__, {:add_recent_project, path, name}, @call_timeout)
  end

  @doc """
  Returns the list of recently opened projects, sorted by last_opened_at descending.
  """
  def list_recent_projects do
    GenServer.call(__MODULE__, :list_recent_projects, @call_timeout)
  end

  @doc """
  Removes a project from the recent list by path.
  """
  def remove_recent_project(path) do
    GenServer.call(__MODULE__, {:remove_recent_project, path}, @call_timeout)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Allow data_dir to be overridden via opts (for testing), fallback to config
    # then platform default. Tests set `config :evo_git, :data_dir` to a temp dir.
    data_dir =
      Keyword.get(
        opts,
        :data_dir,
        Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())
      )

    File.mkdir_p!(data_dir)

    # The TaskStore is started by the supervisor; here just reference by name.
    # Tests may pass their own task_store: name pointing to a test store.
    task_store = Keyword.get(opts, :task_store, EvoGit.Store)

    state = %{
      data_dir: data_dir,
      task_store: task_store,
      task_refs: %{}
    }

    # Startup reconciliation for orphaned :finalizing and :cancelling tasks. A
    # task that was mid-finalization when the runtime died (e.g. slow git calls
    # in merge_and_report/3 hanging while the app is killed) can never reach a
    # terminal status in-process: the {ref, result} and {:DOWN, ...} handlers
    # key off task_refs, which is empty after restart. Likewise a task that was
    # mid-graceful-cancel when the runtime died must resolve to :cancelled, not
    # stay :cancelling forever. Mark such tasks synchronously here (NOT via the
    # async update_task_status/4 cast, which would race callers). :running
    # tasks are deliberately left alone — the one-shot :lease_sweep handles
    # orphaned owners after the lease duration.
    state =
      EvoGit.Store.select_running_lease_info(task_store)
      |> Enum.reduce(state, fn %{id: task_id, status: status}, acc ->
        case status do
          :finalizing ->
            handle_update_status(
              acc,
              task_id,
              :failed,
              "Runtime restarted during task finalization",
              [],
              {:startup_reconcile, :finalizing}
            )

          :cancelling ->
            handle_update_status(
              acc,
              task_id,
              :cancelled,
              "Runtime restarted during task cancellation",
              [],
              {:startup_reconcile, :cancelling}
            )

          _ ->
            acc
        end
      end)

    # Subscribe to task status events from EvoGit.PubSub
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

    # Start the periodic heartbeat timer for lease renewal (owned tasks only).
    # The sweep is NOT periodic — it fires once after the lease duration to
    # catch owners that died around our startup. After that, any new foreign
    # instance does its own check. (init itself reconciles orphaned
    # :finalizing tasks directly, above.)
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
    Process.send_after(self(), :lease_sweep, @sweep_after)

    # Periodic cleanup: sweep expired tasks every 5 minutes
    Process.send_after(self(), :periodic_cleanup, 300_000)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:start_task, task_id, task_type, opts}, _from, state) do
    # Graceful-cancel guard: a task that was cancelled while :pending (or is
    # currently :cancelling) must never start. There is no in-runtime
    # :pending → :running scheduled transition, so this is the only place a
    # cancelled pending task could slip through.
    case EvoGit.Store.get_task_status(state.task_store, task_id) do
      status when status in [:cancelled, :cancelling] ->
        {:reply, {:error, :cancelled}, state}

      _ ->
        task_ref =
          Task.Supervisor.async_nolink(
            EvoGit.TaskSupervisor,
            TaskExecutor,
            :execute_task,
            [task_type, opts, task_id]
          )

        task = %TaskInfo{
          id: task_id,
          type: task_type,
          status: :running,
          opts: opts,
          ref: task_ref,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          logs: [],
          result: nil,
          lease_expires_at: System.system_time(:second) + @lease_duration,
          model_id: Keyword.get(opts, :model_id)
        }

        # Persist to SQLite with ref nulled (ref is runtime-only data). A
        # disk-full write must NOT crash the registry: the task still runs
        # in-memory (unpersisted) and the next status write (terminal or
        # otherwise) retries the persistence.
        case EvoGit.Store.put_task(state.task_store, %{task | ref: nil}) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            Logger.warning(
              "TaskRegistry: disk full — task #{task_id} could not be persisted; " <>
                "continuing in-memory only"
            )
        end

        # Keep the runtime ref in-memory only
        state = %{state | task_refs: Map.put(state.task_refs, task_id, task_ref)}

        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, :running, node()}
        )

        {:reply, {:ok, task}, state}
    end
  end

  @impl true
  def handle_call({:get_task, task_id}, _from, state) do
    task = task_get(state, task_id)
    {:reply, task, state}
  end

  @impl true
  def handle_call(:list_tasks, from, state) do
    offload(from, state, fn ->
      EvoGit.Store.safe_select_all_tasks(state.task_store)
    end)
  end

  @impl true
  def handle_call({:list_tasks_paginated, opts}, from, state) do
    offload(from, state, fn ->
      EvoGit.Store.safe_select_paginated_tasks(state.task_store, opts)
    end)
  end

  @impl true
  def handle_call({:force_kill_task, task_id}, _from, state) do
    # Narrow-column existence/status check (reads only the status column).
    # Works from :running (normal force-kill) and :cancelling (escalation path
    # — a graceful cancel that hangs must be force-killable).
    {result, state} =
      case EvoGit.Store.get_task_status(state.task_store, task_id) do
        status when status in [:running, :cancelling] ->
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
                  EvoGit.AgentScheduler.force_kill_task_agents(pid)
                catch
                  :exit, reason ->
                    Logger.warning(
                      "TaskRegistry: AgentScheduler force_kill failed (exit): #{inspect(reason)}"
                    )
                end

                Task.shutdown(task_ref, :brutal_kill)

                # Clear the graceful-cancel marker (the task is now terminally
                # :failed via this direct write, bypassing
                # handle_update_status's cleanup hook).
                clear_cancelling_marker(task_id)

                # Targeted write — only the changed columns. A :running task's
                # result is always nil (results are written only on terminal
                # transitions), so writing result: nil preserves the old
                # put_task semantics. `ref` is runtime-only and never persisted.
                # A force-killed task is persisted as :failed (never :cancelled)
                # — "cancelled" means ONLY graceful cancellation. On disk-full
                # the in-memory cleanup still happens (task_refs deleted, marker
                # cleared) and {:error, :disk_full} is returned.
                reply =
                  case EvoGit.Store.update_task_columns(state.task_store, task_id,
                         status: :failed,
                         finished_at: DateTime.utc_now(),
                         lease_expires_at: nil,
                         result: nil
                       ) do
                    :ok ->
                      :ok

                    {:error, :disk_full} ->
                      Logger.warning(
                        "TaskRegistry: disk full — force-killed task #{task_id} " <>
                          "could not be persisted as :failed"
                      )

                      {:error, :disk_full}
                  end

                state = %{state | task_refs: Map.delete(state.task_refs, task_id)}
                {reply, state}
              else
                {{:error, :not_running}, state}
              end

            nil ->
              {{:error, :not_running}, state}
          end

        nil ->
          {{:error, :not_found}, state}

        _status ->
          {{:error, :not_running}, state}
      end

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, task_id, :failed, node()})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:cancel_task, task_id}, _from, state) do
    # GRACEFUL cancellation. Narrow-column existence/status check.
    result =
      case EvoGit.Store.get_task_status(state.task_store, task_id) do
        :pending ->
          # No agents exist yet — mark :cancelled immediately. The start_task
          # guard (see {:start_task, ...} handler) then refuses to start it.
          # On disk-full the persisted status stays :pending and
          # {:error, :disk_full} is returned (a later cancel retry would work).
          # Broadcast only on the successful write — the :running arm below
          # funnels through handle_update_status/6, which broadcasts the
          # :cancelling transition itself (no double broadcast).
          case EvoGit.Store.update_task_columns(state.task_store, task_id,
                 status: :cancelled,
                 finished_at: DateTime.utc_now(),
                 lease_expires_at: nil
               ) do
            :ok ->
              Phoenix.PubSub.broadcast(
                EvoGit.PubSub,
                "tasks",
                {:task_updated, task_id, :cancelled, node()}
              )

              :ok

            {:error, :disk_full} ->
              Logger.warning(
                "TaskRegistry: disk full — pending task #{task_id} could not " <>
                  "be marked :cancelled"
              )

              {:error, :disk_full}
          end

        :running ->
          # 1. Transition to :cancelling via the normal status-update path so
          #    handle_update_status broadcasts {:task_updated, task_id,
          #    :cancelling, node()} (dashboard sees the change immediately).
          #    :cancelling is NON-terminal, so finished_at stays
          #    nil, the lease stays valid, and the task_refs entry stays. The
          #    returned state is discarded (unchanged for non-terminal).
          handle_update_status(state, task_id, :cancelling, nil, [], {:cancel_request, nil})

          # 2. Notify the scheduler: append the cancel message + set
          #    cancel_requested for every agent of the task, and register the
          #    task in the cancelling marker (blocks new root agents and puts
          #    late registrations into grace).
          #
          # Justified catch :exit — cross-GenServer boundary (TaskRegistry →
          # AgentScheduler). If the scheduler is down, the graceful path can't
          # proceed; the task is left :cancelling (a subsequent force_kill or
          # restart reconciliation resolves it).
          try do
            EvoGit.AgentScheduler.begin_graceful_cancel(task_id)
          catch
            :exit, reason ->
              Logger.warning(
                "TaskRegistry: AgentScheduler begin_graceful_cancel failed (exit): #{inspect(reason)}"
              )
          end

          :ok

        :cancelling ->
          # Idempotent — a graceful cancel is already in flight. Do NOT re-send
          # the cancel message (agents already have it).
          :ok

        nil ->
          {:error, :not_found}

        _status ->
          # :finalizing / :completed / :failed / :cancelled
          {:error, :not_running}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tasks_by_path, path}, from, state) do
    # Push filtering to SQL via safe_select_paginated_tasks with project_path filter.
    # This avoids decoding ALL tasks — only matching tasks are decoded by SQLite.
    # Use a high limit since path-filtered results are typically manageable.
    offload(from, state, fn ->
      {tasks, _total} =
        EvoGit.Store.safe_select_paginated_tasks(
          state.task_store,
          filters: [project_path: path],
          limit: 5000
        )

      tasks
    end)
  end

  @impl true
  def handle_call(:get_unique_paths, _from, state) do
    # select_task_paths now returns distinct non-nil project_path values
    # directly from the denormalized column — no per-row decode needed.
    paths = EvoGit.Store.select_task_paths(state.task_store)

    {:reply, paths, state}
  end

  @impl true
  def handle_call({:list_tasks_summary, statuses, since}, from, state) do
    offload(from, state, fn ->
      EvoGit.Store.select_tasks_summary(state.task_store, statuses, since)
    end)
  end

  @impl true
  def handle_call({:list_tasks_summary_by_path, path, statuses, since}, from, state) do
    offload(from, state, fn ->
      EvoGit.Store.select_tasks_summary_by_path(state.task_store, path, statuses, since)
    end)
  end

  @impl true
  def handle_call({:list_tasks_changed_since, since_iso}, from, state) do
    offload(from, state, fn ->
      EvoGit.Store.select_tasks_changed_since(state.task_store, since_iso)
    end)
  end

  @impl true
  def handle_call({:list_task_ids, statuses}, _from, state) do
    # Tiny projection (id, status, updated_at) — no heavy decode, so reply
    # synchronously without the Task-start offload.
    tasks = EvoGit.Store.select_task_ids(state.task_store, statuses)
    {:reply, tasks, state}
  end

  @impl true
  def handle_call(:clear_finished_tasks, _from, state) do
    task_ids = EvoGit.Store.select_finished_task_ids(state.task_store)

    # On disk-full the finished rows remain and {:error, :disk_full} is
    # returned (a later clear retry would succeed once space is freed).
    reply =
      case EvoGit.Store.delete_tasks(state.task_store, task_ids) do
        :ok ->
          Cleanup.cleanup_expired_tasks(state.task_store)

          # One event per deleted row — the dashboard needs the id to drop
          # the task from its UI. Broadcast only on the successful write (on
          # disk-full the rows remain and nothing was deleted).
          Enum.each(task_ids, fn task_id ->
            Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, task_id, node()})
          end)

          :ok

        {:error, :disk_full} ->
          Logger.warning(
            "TaskRegistry: disk full — #{length(task_ids)} finished tasks could not be deleted"
          )

          {:error, :disk_full}
      end

    {:reply, reply, state}
  end

  ## Recent Projects Handlers

  @impl true
  def handle_call({:add_recent_project, path, name}, _from, state) do
    now = DateTime.utc_now()

    # On disk-full the project simply isn't persisted — log and continue
    # (recent projects are a convenience, never worth crashing the registry).
    case EvoGit.Store.put_project(
           state.task_store,
           %EvoGit.RecentProject{path: path, name: name, last_opened_at: now}
         ) do
      :ok ->
        :ok

      {:error, :disk_full} ->
        Logger.warning("TaskRegistry: disk full — recent project #{inspect(path)} not persisted")
    end

    # Enforce max limit
    trim_recent_projects(state)

    Phoenix.PubSub.broadcast(EvoGit.PubSub, "recent_projects", {:recent_projects_updated})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_recent_projects, _from, state) do
    reply =
      select_all_projects(state)
      |> sort_projects_by_recency()

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:remove_recent_project, path}, _from, state) do
    # On disk-full the project row simply remains — log and continue.
    case EvoGit.Store.delete_project(state.task_store, path) do
      :ok ->
        :ok

      {:error, :disk_full} ->
        Logger.warning(
          "TaskRegistry: disk full — recent project #{inspect(path)} could not be deleted"
        )
    end

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
    # Narrow-column read: only the logs column is fetched (no full 18-column
    # task_get decode) just to read the existing logs.
    case EvoGit.Store.select_task_logs(state.task_store, task_id) do
      logs when is_list(logs) ->
        updated_logs = [log_entry | logs] |> Enum.take(@max_log_entries)

        case EvoGit.Store.update_task_columns(state.task_store, task_id, logs: updated_logs) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Log-loss is acceptable on disk-full (this is a hot path during
            # runs) — log a warning and continue; never crash the registry.
            Logger.warning(
              "TaskRegistry: disk full — log entry for task #{task_id} not persisted"
            )
        end

      nil ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete_task, task_id}, state) do
    case EvoGit.Store.delete_task(state.task_store, task_id) do
      :ok ->
        # Broadcast only on the successful write — on disk-full the row
        # remains and nothing was deleted.
        Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, task_id, node()})
        :ok

      {:error, :disk_full} ->
        # Fire-and-forget delete (cast): swallow + log — the task row simply
        # remains until disk space is freed and a later delete/cleanup retries.
        Logger.warning("TaskRegistry: disk full — task #{task_id} could not be deleted")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_status, task_id, status}, state) do
    # Narrow-column existence check: reads only the status column.
    case EvoGit.Store.get_task_status(state.task_store, task_id) do
      nil ->
        :ok

      _status ->
        case EvoGit.Store.update_task_columns(state.task_store, task_id, review_status: status) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Fire-and-forget review-status write (cast): swallow + log — the
            # review status stays as-is in the DB until a retry succeeds.
            Logger.warning(
              "TaskRegistry: disk full — review status for task #{task_id} not persisted"
            )
        end
    end

    # Review-status mutations don't change the task status — broadcast nil.
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, task_id, nil, node()})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_review_metadata, task_id, base_sha, commit_sha}, state) do
    # Narrow-column existence check: reads only the status column.
    case EvoGit.Store.get_task_status(state.task_store, task_id) do
      nil ->
        :ok

      _status ->
        case EvoGit.Store.update_task_columns(state.task_store, task_id,
               base_sha: base_sha,
               commit_sha: commit_sha
             ) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Fire-and-forget review-metadata write (cast): swallow + log — the
            # review SHAs stay as-is in the DB until a retry succeeds.
            Logger.warning(
              "TaskRegistry: disk full — review metadata for task #{task_id} not persisted"
            )
        end
    end

    # Review-metadata mutations don't change the task status — broadcast nil.
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, task_id, nil, node()})
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

    # Narrow-column read: only status, opts, finished_at, lease_expires_at are
    # fetched (no full 18-column task_get decode) — exactly the fields this
    # handler needs for the stale-guard, preservation, and project_path.
    state =
      case EvoGit.Store.select_task_update_info(state.task_store, task_id) do
        %{
          status: task_status,
          opts: task_opts,
          finished_at: task_finished_at,
          lease_expires_at: task_lease_expires_at
        } ->
          # Final-result force-mapping for graceful cancellation: a task whose
          # CURRENT stored status is :cancelling that reaches a terminal phase
          # (the wrapper completed/failed during the grace period) must always
          # be persisted as :cancelled — never :completed/:failed. Everything
          # else (result/usage/archive write, terminal bookkeeping) flows
          # through untouched, so intermediate result data is PRESERVED.
          status =
            if task_status == :cancelling and status in [:completed, :failed],
              do: :cancelled,
              else: status

          if task_status in [:completed, :failed, :cancelled] and
               status in [:completed, :failed, :cancelled] and
               task_status != status and
               status != :completed do
            Logger.warning(
              "TaskRegistry: Ignoring stale status update for task #{task_id}: " <>
                "already #{task_status}, ignoring #{status}"
            )

            state
          else
            # Log any transition INTO :failed that isn't already :failed.
            if status == :failed and task_status != :failed do
              Diagnostics.log_failed_transition(task_id, :update_status_cast, task_status,
                result: result,
                caller_info: caller_info
              )
            end

            finished_at =
              if status in [:completed, :failed, :cancelled],
                do: DateTime.utc_now(),
                else: task_finished_at

            lease_expires_at =
              if status in [:completed, :failed, :cancelled],
                do: nil,
                else: task_lease_expires_at

            project_path = Keyword.get(task_opts, :path)

            branch_name =
              case result do
                {:ok, data} when is_map(data) -> Map.get(data, :branch_name)
                _ -> nil
              end

            # Build a keyword list of exactly what changed — only these columns
            # are written, avoiding re-encoding opts/logs/json blobs.
            update_cols =
              [
                status: status,
                result: result,
                finished_at: finished_at,
                lease_expires_at: lease_expires_at,
                project_path: project_path,
                branch_name: branch_name
              ] ++
                if(usage, do: [usage: usage], else: []) ++
                if(agent_count, do: [agent_count: agent_count], else: []) ++
                if(commit_sha, do: [commit_sha: commit_sha], else: []) ++
                if(archive_records, do: [archive_metadata: archive_records], else: [])

            case EvoGit.Store.update_task_columns(state.task_store, task_id, update_cols) do
              :ok ->
                # Broadcast the persisted status only when it actually changed.
                # A missing row or a stale/no-op update never reaches here, and
                # a disk-full write leaves the row untouched — so this is the
                # single place where the write is known to have happened.
                if status != task_status do
                  Phoenix.PubSub.broadcast(
                    EvoGit.PubSub,
                    "tasks",
                    {:task_updated, task_id, status, node()}
                  )
                end

                :ok

              {:error, :disk_full} ->
                # The terminal write is lost, but the in-memory cleanup below
                # still runs so the task is not stuck: the task_refs entry is
                # removed and the cancelling marker cleared. The persisted row
                # keeps its old status until disk space is freed.
                Logger.warning(
                  "TaskRegistry: disk full — status write for task #{task_id} " <>
                    "not persisted (status #{inspect(status)})"
                )
            end

            if status in [:completed, :failed, :cancelled] do
              # Terminal state — clean up the graceful-cancel marker (guarded:
              # the scheduler may be down during startup reconciliation).
              clear_cancelling_marker(task_id)

              %{state | task_refs: Map.delete(state.task_refs, task_id)}
            else
              state
            end
          end

        nil ->
          # Missing row — no write, no broadcast.
          state
      end

    state
  end

  # --- TaskStore Read Helpers ---

  defp task_get(state, task_id) do
    EvoGit.Store.get_task(state.task_store, task_id)
  end

  defp select_all_projects(state) do
    EvoGit.Store.safe_select_all_projects(state.task_store)
  end

  # Removes a task_id from the :evogit_cancelling_tasks marker once the task
  # reaches a terminal state. Safe and idempotent: prefers the scheduler
  # GenServer (serialized, so it can't race begin_graceful_cancel), but when
  # the scheduler is down (e.g. startup reconciliation — TaskRegistry starts
  # BEFORE the AgentScheduler in the supervision tree) falls back to deleting
  # directly from the public ETS table. Never crashes the caller.
  defp clear_cancelling_marker(task_id) do
    if Process.whereis(EvoGit.AgentScheduler) do
      try do
        EvoGit.AgentScheduler.clear_cancelling_task(task_id)
      catch
        :exit, reason ->
          Logger.warning(
            "TaskRegistry: AgentScheduler clear_cancelling_task failed (exit): #{inspect(reason)}"
          )

          delete_cancelling_marker_ets(task_id)
      end
    else
      delete_cancelling_marker_ets(task_id)
    end

    :ok
  end

  defp delete_cancelling_marker_ets(task_id) do
    case :ets.whereis(:evogit_cancelling_tasks) do
      :undefined -> :ok
      _tid -> :ets.delete(:evogit_cancelling_tasks, task_id)
    end

    :ok
  end

  # --- Shared Private Helpers ---

  # Delegates a heavy Store decode to a short-lived Task process so the large
  # decoded terms are allocated and discarded on that process's heap rather
  # than ratcheting up this GenServer's heap. `fun` returns the value to reply
  # with; it captures the caller's bindings (incl. `state`) before the reply is
  # sent — `state` is never moved into the Task.
  defp offload(from, state, fun) do
    {:ok, _task_pid} =
      Task.start(fn ->
        GenServer.reply(from, fun.())
      end)

    {:noreply, state}
  end

  # Reverse lookup: finds the task id whose in-memory %Task{} ref matches `ref`.
  defp task_id_for_ref(state, ref) do
    Enum.find_value(state.task_refs, fn {id, %Task{ref: task_ref}} ->
      if task_ref == ref, do: id
    end)
  end

  # Reads the task's currently persisted status (nil when the task is unknown),
  # used to log failed transitions with the previous status.
  defp prev_status(state, task_id) do
    case task_get(state, task_id) do
      %TaskInfo{status: s} -> s
      nil -> nil
    end
  end

  # Extracts an optional typed field from a `{:ok, map}` task result. `validator`
  # mirrors the original case-arm TYPE GUARD (e.g.
  # `&match?(%EvoGit.Agent.Usage{}, &1)`), so a wrong-typed or absent value
  # still yields nil and never flows into the DB write.
  defp result_field(result, key, validator) do
    case result do
      {:ok, data} when is_map(data) ->
        case Map.fetch(data, key) do
          {:ok, value} -> if validator.(value), do: value, else: nil
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # Shared result-recovery logic used by handle_info({:recheck_task, _}). The
  # wrapper process is dead so the runtime result was lost (delivered via
  # GenServer.reply to a dead process). We try a best-effort result lookup from
  # the sched_meta ETS table. If nothing definitive is found, we mark the task
  # :completed — agents finished without a recorded failure, so treating it as
  # completed is the least surprising outcome.
  defp resolve_recheck_task(state, task_id, %TaskInfo{} = task) do
    result = Lease.lookup_sched_meta_result(task_id)

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
      Diagnostics.log_failed_transition(task_id, :recheck_resolve, task.status,
        result: final_result
      )
    end

    finished_at = DateTime.utc_now()

    # Mirror handle_update_status/6's extraction: pull branch_name from tuple
    # results when present. Included in the write only when non-nil — writing
    # nil would clobber an existing branch_name persisted earlier.
    branch_name =
      case final_result do
        {:ok, data} when is_map(data) -> Map.get(data, :branch_name)
        _ -> nil
      end

    update_cols =
      [
        status: final_status,
        result: final_result,
        finished_at: finished_at,
        lease_expires_at: nil
      ] ++ if(branch_name, do: [branch_name: branch_name], else: [])

    # Targeted write — only the changed columns; `ref` is runtime-only and
    # never persisted. On disk-full the task stays in its previous persisted
    # state — log and continue (the in-memory resolution is complete).
    # Broadcast only when the write actually happened (status after resolve).
    case EvoGit.Store.update_task_columns(state.task_store, task_id, update_cols) do
      :ok ->
        Phoenix.PubSub.broadcast(
          EvoGit.PubSub,
          "tasks",
          {:task_updated, task_id, final_status, node()}
        )

        :ok

      {:error, :disk_full} ->
        Logger.warning(
          "TaskRegistry: disk full — recheck resolution for task #{task_id} " <>
            "(#{final_status}) not persisted"
        )
    end

    Logger.info("TaskRegistry: recheck resolved task #{task_id} to #{final_status}")

    {:noreply, state}
  end

  # --- Stuck-:finalizing grace watchdog ---
  #
  # Hardens the :finalizing stage against a wrapper that stays ALIVE but blocks
  # forever in an uninterruptible git call (e.g. merge_and_report/3 on an
  # NFS-mounted home — no timeout, no in-process resolution while the BEAM stays
  # up). When a task enters :finalizing we schedule a ONE-SHOT watchdog timer
  # (reusing the {:recheck_task, task_id} message shape); when it fires while
  # the task is STILL :finalizing, the task is resolved to :failed regardless of
  # scheduler/agent state — the whole point is that the wrapper is
  # alive-but-blocked, so the grace expiry resolves the task.

  # Reads the app-env seam `Application.get_env(:evo_git,
  # :finalizing_watchdog_grace_minutes)` and normalizes it to
  # `:disabled | {:ok, minutes}`:
  #   - false        -> :disabled (no timer scheduled; zero behavioral change)
  #   - nil / unset  -> default 60 minutes
  #   - numeric >= 0 -> that many minutes (0 = fire immediately; float/fractional
  #                     values tolerated)
  #   - any other    -> default 60 (defensive)
  defp finalizing_watchdog_grace do
    case Application.get_env(:evo_git, :finalizing_watchdog_grace_minutes) do
      false -> :disabled
      nil -> {:ok, @finalizing_watchdog_default_minutes}
      minutes when is_number(minutes) and minutes >= 0 -> {:ok, minutes}
      _ -> {:ok, @finalizing_watchdog_default_minutes}
    end
  end

  # The minutes named in the watchdog's result message, re-read at RESOLUTION
  # time so a mid-flight env change is reflected. :disabled here is only
  # possible if the env flipped to false after scheduling (a fire implies it was
  # enabled at schedule time) — fall back to the default.
  defp finalizing_watchdog_result_minutes do
    case finalizing_watchdog_grace() do
      :disabled -> @finalizing_watchdog_default_minutes
      {:ok, minutes} -> minutes
    end
  end

  # Schedules the one-shot watchdog for a task that just entered :finalizing
  # (called from the :ok arm of the :finalizing PubSub handler's put_task).
  # Delay = trunc(minutes * 60_000) — always an INTEGER (Process.send_after
  # rejects floats); minutes = 0 fires immediately. :disabled -> no timer.
  defp schedule_finalizing_watchdog(task_id) do
    case finalizing_watchdog_grace() do
      :disabled ->
        :ok

      {:ok, minutes} ->
        delay = trunc(minutes * 60_000)
        Process.send_after(self(), {:recheck_task, task_id}, delay)

        Logger.debug(
          "TaskRegistry: scheduled :finalizing watchdog for task #{task_id} in #{delay}ms"
        )

        :ok
    end
  end

  # Watchdog resolution: the task is STILL :finalizing past the grace period.
  # Resolve to :failed via the shared handle_update_status/6 — mirroring the
  # startup-reconcile call style ({:startup_reconcile, :finalizing}), which
  # gives Diagnostics failed-transition logging, finished_at/lease handling, the
  # {:task_updated, task_id, :failed, node()} broadcast (only on a successful
  # write), clear_cancelling_marker, and the task_refs deletion. Deliberately
  # does NOT check Lease.sched_meta_has_active_agents? and does NOT reschedule —
  # the wrapper is alive-but-blocked; the grace expiry resolves the task. No git
  # timeouts added, nothing killed (residual sched_meta/agent state is left
  # untouched, mirroring startup reconciliation).
  defp resolve_finalizing_watchdog(state, task_id, %TaskInfo{}) do
    minutes = finalizing_watchdog_result_minutes()
    result = "Finalization did not complete within #{minutes} minutes"

    Logger.warning(
      "TaskRegistry: :finalizing watchdog fired for task #{task_id} — " <>
        "finalization did not complete within #{minutes} minutes; resolving to :failed"
    )

    state =
      handle_update_status(state, task_id, :failed, result, [], {:finalizing_watchdog, task_id})

    {:noreply, state}
  end

  # --- Recent Projects ---

  defp trim_recent_projects(state) do
    projects =
      select_all_projects(state)
      |> sort_projects_by_recency()

    case Enum.split(projects, @max_recent_projects) do
      {_kept, []} ->
        :ok

      {_kept, to_remove} ->
        paths = Enum.map(to_remove, fn project -> project.path end)

        Enum.each(paths, fn path ->
          case EvoGit.Store.delete_project(state.task_store, path) do
            :ok ->
              :ok

            {:error, :disk_full} ->
              # Over-limit project rows simply remain until space is freed —
              # log and continue (recent projects are a convenience).
              Logger.warning(
                "TaskRegistry: disk full — recent project #{inspect(path)} could not be trimmed"
              )
          end
        end)

        :ok
    end
  end

  # Sorts projects by last_opened_at descending (most recent first), handling nil
  # timestamps safely. A nil last_opened_at sorts LAST (oldest). This avoids the
  # ArgumentError that DateTime.compare/2 raises when comparing against nil.
  defp sort_projects_by_recency(projects) do
    Enum.sort(projects, fn a, b ->
      cond do
        a.last_opened_at == nil -> false
        b.last_opened_at == nil -> true
        true -> DateTime.after?(a.last_opened_at, b.last_opened_at)
      end
    end)
  end

  ## GenServer Info Handlers

  @impl true
  def handle_info({:task_updated, task_id, :finalizing, node}, state) when node == node() do
    # :finalizing is the ONLY status acted on here — other statuses in
    # {:task_updated, ...} are persisted locally by TaskRegistry itself and
    # must not be reprocessed. A broadcast from a remote node (node !=
    # node()) is ignored by the no-op clause below: task ids are per-node,
    # so a cross-node collision would corrupt local rows.
    state =
      case task_get(state, task_id) do
        %TaskInfo{} = task ->
          # Ignore stale :finalizing updates for tasks already terminal AND
          # for tasks in graceful cancel (:cancelling) — a cancelling task
          # that reaches phase finalization keeps :cancelling (the more
          # informative state; the final mapping to :cancelled happens at
          # result time in handle_update_status/6).
          if task.status in [:completed, :cancelled, :cancelling] do
            Logger.debug(
              "TaskRegistry: Ignoring stale :task_updated finalizing update for task #{task_id}: " <>
                "already #{task.status}, ignoring :finalizing"
            )

            state
          else
            # :finalizing is NON-terminal — finished_at and the lease stay as
            # they are; the final terminal mapping happens at result time in
            # handle_update_status/6.
            updated = %{task | status: :finalizing}

            # On disk-full the persisted row keeps its old status — log and
            # continue.
            case EvoGit.Store.put_task(state.task_store, updated) do
              :ok ->
                # The row is now :finalizing — schedule the ONE-SHOT stuck-
                # :finalizing grace watchdog (only here, NOT on the disk-full
                # path where the row never became :finalizing and the existing
                # mechanisms stay as-is). :disabled -> no timer.
                schedule_finalizing_watchdog(task_id)
                :ok

              {:error, :disk_full} ->
                Logger.warning(
                  "TaskRegistry: disk full — :task_updated finalizing update for task #{task_id} " <>
                    "not persisted (status :finalizing)"
                )
            end

            state
          end

        nil ->
          state
      end

    {:noreply, state}
  end

  # A remote node's :finalizing broadcast must NEVER be persisted into the
  # local store — task ids are per-node, so a cross-node collision would
  # corrupt local rows.
  def handle_info({:task_updated, _task_id, :finalizing, _other_node}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Search the in-memory task_refs map for the matching task reference
    task_id = task_id_for_ref(state, ref)

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
        Diagnostics.log_failed_transition(
          task_id,
          :result_handler,
          prev_status(state, task_id),
          result: result
        )
      end

      update_task_status_with_caller(task_id, status, result,
        usage: result_field(result, :usage, &match?(%EvoGit.Agent.Usage{}, &1)),
        agent_count: result_field(result, :agent_count, &is_integer/1),
        commit_sha: result_field(result, :commit_sha, &is_binary/1),
        archive_records: result_field(result, :archive_records, &is_list/1)
      )
    end

    Process.demonitor(ref, [:flush])

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    task_id = task_id_for_ref(state, ref)

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
          if Lease.sched_meta_has_active_agents?(task_id) do
            Logger.info(
              "TaskRegistry: Task #{task_id} still has active agents in AgentScheduler — keeping as :running despite wrapper crash"
            )

            # Do NOT update status — leave as :running
          else
            # No active agents — genuine failure
            Diagnostics.log_failed_transition(task_id, :down_handler, prev_status(state, task_id),
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

    # Renew leases for owned tasks using lightweight queries — avoids full
    # decode (task_get) + full re-encode (put_task) for every owned task on
    # every heartbeat. :cancelling is included so a long graceful-cancel keeps
    # its lease valid while the wrapper is still alive.
    Enum.each(state.task_refs, fn {task_id, _ref} ->
      status = EvoGit.Store.get_task_status(state.task_store, task_id)

      if status in [:running, :pending, :cancelling] do
        case EvoGit.Store.update_lease_expires_at(
               state.task_store,
               task_id,
               now + @lease_duration
             ) do
          :ok ->
            :ok

          {:error, :disk_full} ->
            # Fire-and-forget heartbeat renewal: swallow + log. The lease
            # simply expires on schedule if it cannot be renewed; the sweep
            # then treats the task as orphaned (correct degradation).
            Logger.warning(
              "TaskRegistry: disk full — lease renewal for task #{task_id} not persisted"
            )
        end
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

    # Use the lightweight query — only id, status, and lease_expires_at are
    # decoded, avoiding the full struct decode for every task in the table.
    # We only need to task_get (full decode) for the very few tasks (usually
    # 0-1) that actually need to be marked :failed.
    {changed, failed_ids} =
      EvoGit.Store.select_running_lease_info(state.task_store)
      |> Enum.filter(fn %{id: id, status: status, lease_expires_at: lease} ->
        status == :running and
          id not in owned_ids and
          not Lease.lease_valid?(lease)
      end)
      |> Enum.reduce({false, []}, fn %{id: id, lease_expires_at: lease}, {changed, failed_ids} ->
        if Lease.sched_meta_has_active_agents?(id) do
          # Same VM, agents still active — skip (handled by :recheck_task)
          {changed, failed_ids}
        else
          Diagnostics.log_failed_transition(id, :lease_sweep, :running,
            result: "Lease expired; owning instance no longer renewing",
            extra: [lease_expires_at: inspect(lease)]
          )

          # Full decode only for this specific task (to build the write-back
          # struct) — there should be very few of these (0-1 in normal use).
          case task_get(state, id) do
            %TaskInfo{} = task ->
              updated = %{
                task
                | status: :failed,
                  lease_expires_at: nil,
                  finished_at: DateTime.utc_now(),
                  result: "Lease expired; owning instance no longer renewing"
              }

              case EvoGit.Store.put_task(state.task_store, updated) do
                :ok ->
                  {true, [id | failed_ids]}

                {:error, :disk_full} ->
                  # The sweep result is still "changed" (in-memory state and
                  # diagnostics updated) — log and continue, but the row was
                  # not persisted so no broadcast fires for it.
                  Logger.warning(
                    "TaskRegistry: disk full — lease-expired task #{id} could not be " <>
                      "persisted as :failed"
                  )

                  {true, failed_ids}
              end

            nil ->
              {changed, failed_ids}
          end
        end
      end)

    if changed do
      Cleanup.cleanup_expired_tasks(state.task_store)
    end

    # One event per successfully-persisted sweep — the dashboard needs the id
    # to attribute the :failed status to the specific task.
    Enum.each(failed_ids, fn id ->
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, :failed, node()})
    end)

    {:noreply, state}
  end

  # Periodic cleanup handler: sweeps expired finished tasks to enforce
  # max_age_days and max_tasks limits. Reschedules itself every 5 minutes.
  @impl true
  def handle_info(:periodic_cleanup, state) do
    Cleanup.cleanup_expired_tasks(state.task_store)
    Process.send_after(self(), :periodic_cleanup, 300_000)
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

      %TaskInfo{status: :finalizing} = task ->
        # Stuck-:finalizing grace watchdog fired while the task is STILL
        # :finalizing — the wrapper is alive but blocked past the grace period
        # (e.g. uninterruptible git I/O in merge_and_report/3). Resolve to
        # :failed regardless of scheduler state; do NOT reschedule.
        resolve_finalizing_watchdog(state, task_id, task)

      %TaskInfo{} = task ->
        if Lease.sched_meta_has_active_agents?(task_id) do
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
