defmodule EvoGit.TaskControl do
  @moduledoc """
  Structured access to local development tasks for external callers.

  The registry owns execution and persistence. This boundary validates the
  deliberately small public input surface and projects JSON-safe task results;
  it does not maintain a second task lifecycle or change Git delivery behavior.
  """
  alias EvoGit.{Config, TaskRegistry}
  alias EvoGit.Store.Codec

  @terminal [:completed, :failed, :cancelled]
  @start_keys ~w(path objective task_type mode resume_from model_id persistent_state)

  # The caller-facing FILTER vocabulary for `list/1` (`"all"` plus one value per
  # persisted task status, so a paused task is listable/filterable like any
  # other). `:pausing` and `:paused` are task-level statuses and belong here;
  # this is a QUERY vocabulary, not a liveness/admission set (see the exemption
  # recorded in `test/evo_git/status_admission_totality_test.exs`).
  @status_filters ~w(all pending running pausing paused finalizing completed failed cancelled cancelling)

  @doc false
  # The `list/1` status filter vocabulary (STRING values, `"all"` first).
  # Exposed for the table-driven status-admission totality test.
  @spec status_filters() :: [String.t()]
  def status_filters, do: @status_filters

  def check(args) do
    with :ok <- keys(args, ~w(path)),
         {:ok, path} <- optional_path(args) do
      config = Config.config_status()
      model_ready = config.ok? and config.validation_errors == []
      project = if path, do: project_readiness(path), else: nil

      {:ok,
       %{
         version: to_string(Application.spec(:evo_git, :vsn)),
         ready: model_ready and (is_nil(project) or project.ready),
         model_ready: model_ready,
         provider_connection_tested: false,
         config_files: %{config: Config.config_path(), credentials: Config.credentials_path()},
         warnings:
           config.warnings ++
             Enum.map(config.validation_errors, fn e ->
               "Invalid configuration key: #{Enum.join(e.key_path, ".")}."
             end),
         project: project
       }}
    end
  end

  def reload_config(args) do
    with :ok <- keys(args, []) do
      safe(fn ->
        case EvoGit.AgentScheduler.RemoteAPI.reload_config() do
          :ok ->
            with {:ok, status} <- check(%{}) do
              {:ok, Map.put(status, :configuration_reloaded, true)}
            end

          {:error, reason} ->
            error("configuration_not_applied", reason)
        end
      end)
    end
  end

  def start(args) do
    with :ok <- keys(args, @start_keys),
         {:ok, path} <- required_path(args),
         :ok <- ready_project(path),
         {:ok, _} <- required_string(args, "objective"),
         :ok <- optional_strings(args, ~w(task_type mode resume_from model_id)),
         :ok <- model_profile(args),
         :ok <- optional_boolean(args, "persistent_state"),
         {:ok, args} <- task_mode(args),
         :ok <- resume(args, path),
         {type, opts} = start_options(Map.put(args, "path", path)) do
      safe(fn ->
        case TaskRegistry.start_task(type, opts) do
          {:ok, task} -> {:ok, project(task)}
          {:error, reason} -> error("start_failed", inspect(reason))
        end
      end)
    end
  end

  defp start_options(args) do
    type = if args["task_type"] == "genesis", do: :genesis, else: :evolve
    opts = [path: args["path"], objective: args["objective"], mode: args["mode"]]
    opts = if type == :genesis, do: Keyword.put(opts, :prompt, args["objective"]), else: opts

    opts =
      Enum.reduce(~w(resume_from model_id persistent_state)a, opts, fn key, acc ->
        case Map.get(args, Atom.to_string(key)) do
          nil -> acc
          value -> Keyword.put(acc, key, value)
        end
      end)

    {type, opts}
  end

  def get(args) do
    with :ok <- keys(args, ~w(task_id since wait_seconds include_result include_objective)),
         {:ok, id} <- required_string(args, "task_id"),
         :ok <- optional_strings(args, ~w(since)),
         {:ok, wait} <- integer(args, "wait_seconds", 0, 0, 20),
         true <-
           is_boolean(Map.get(args, "include_result", true)) and
             is_boolean(Map.get(args, "include_objective", false)) do
      deadline = System.monotonic_time(:millisecond) + wait * 1000
      safe(fn -> observe(id, args, deadline) end)
    else
      false ->
        error("invalid_arguments", "include_result and include_objective must be booleans.")

      other ->
        other
    end
  end

  defp observe(id, args, deadline) do
    case TaskRegistry.get_task_lite(id) do
      nil ->
        error("not_found", "Task not found: #{id}")

      task ->
        progress = EvoGit.TaskControl.Observation.snapshot(task)
        changed = Map.get(args, "since") != progress.change_token
        remaining = deadline - System.monotonic_time(:millisecond)

        if not changed and task.status not in @terminal and remaining > 0 do
          Process.sleep(min(remaining, 500))
          observe(id, args, deadline)
        else
          data = project(task) |> Map.put(:progress, progress) |> Map.put(:changed, changed)

          data =
            if Map.get(args, "include_objective", false),
              do: Map.put(data, :objective, task_objective(task)),
              else: data

          data =
            if Map.get(args, "include_result", true), do: data, else: Map.delete(data, :result)

          {:ok, data}
        end
    end
  end

  def result(args) do
    with :ok <- keys(args, ~w(task_id)),
         {:ok, data} <- get(args) do
      if data.status in ~w(completed failed cancelled) do
        summary = get_in(data, [:result, "data", "result"])
        {:ok, Map.merge(data, %{summary: summary, verification: "not_independently_verified"})}
      else
        error("not_ready", "Task is #{data.status}; use genesis_get_task to follow progress.")
      end
    end
  end

  def models(args) do
    with :ok <- keys(args, []) do
      config = Config.resolve()
      profiles = EvoGit.Config.Schema.model_profiles(config)
      configured_default = get_in(config, [:llm, :default_provider_profile])

      models =
        Enum.with_index(profiles)
        |> Enum.map(fn {profile, index} ->
          model = profile[:model]
          model = if is_map(model), do: Map.take(model, [:provider, :id]), else: model

          %{
            id: profile[:id],
            model: model,
            default:
              if(configured_default, do: profile[:id] == configured_default, else: index == 0)
          }
        end)

      {:ok, %{models: models}}
    end
  end

  def message(args) do
    with :ok <- keys(args, ~w(task_id message agent_id)),
         {:ok, id} <- required_string(args, "task_id"),
         {:ok, message} <- required_string(args, "message") do
      safe(fn -> EvoGit.TaskControl.Messaging.send(id, message, Map.get(args, "agent_id")) end)
    end
  end

  def list(args) do
    with :ok <- keys(args, ~w(path limit offset status search)),
         {:ok, path} <- optional_path(args),
         :ok <- optional_strings(args, ~w(status search)),
         :ok <- status_filter(args),
         {:ok, limit} <- integer(args, "limit", 20, 1, 50),
         {:ok, offset} <- integer(args, "offset", 0, 0, 1_000_000) do
      safe(fn ->
        %{rows: rows, total: total} =
          TaskRegistry.list_tasks_page(
            limit: limit,
            offset: offset,
            project_path: path || "all",
            status: Map.get(args, "status", "all"),
            search: args["search"]
          )

        tasks =
          Enum.map(
            rows,
            &Map.take(&1, [
              :id,
              :type,
              :status,
              :project_path,
              :objective,
              :started_at,
              :finished_at,
              :branch_name,
              :commit_sha,
              :review_status
            ])
          )

        {:ok,
         %{
           tasks: tasks,
           total: total,
           next_offset: if(offset + length(rows) < total, do: offset + length(rows))
         }}
      end)
    end
  end

  def cancel(args) do
    with :ok <- keys(args, ~w(task_id force)),
         {:ok, id} <- required_string(args, "task_id"),
         true <- is_boolean(Map.get(args, "force", false)) do
      safe(fn ->
        result =
          if Map.get(args, "force", false),
            do: TaskRegistry.force_kill_task(id),
            else: TaskRegistry.cancel_task(id)

        case result do
          :ok -> cancellation_state(id, true)
          {:error, :not_running} -> cancellation_state(id, false)
          {:error, :not_found} -> error("not_found", "Task not found: #{id}")
          {:error, reason} -> error("cancel_failed", inspect(reason))
        end
      end)
    else
      false -> error("invalid_arguments", "force must be a boolean.")
      other -> other
    end
  end

  defp cancellation_state(id, accepted) do
    with {:ok, data} <- get(%{"task_id" => id, "include_result" => false}) do
      if accepted or data.status in ~w(completed failed cancelled),
        do: {:ok, Map.put(data, :cancel_requested, accepted)},
        else: error("cancel_failed", "The service did not accept cancellation for this task.")
    end
  end

  @doc """
  Requests a TASK-LEVEL PAUSE for a running task (`docs/task-pause.md`).

  A pause only ACCEPTS the request: the task moves to `:pausing` while its
  agents stop at their next turn boundary, and reaches the `:paused` resting
  state later, so `status` is the SAVED status at this instant. Repeating the
  request on a `:pausing`/`:paused` task is idempotent. An interactive-session
  task is refused (`not_pausable`) and a task whose durable agent state is
  disabled is refused (`not_resumable`), because there would be nothing to
  resume.
  """
  def pause(args) do
    with :ok <- keys(args, ~w(task_id)),
         {:ok, id} <- required_string(args, "task_id") do
      safe(fn ->
        case TaskRegistry.pause_task(id) do
          :ok -> pause_state(id)
          {:error, reason} -> pause_error(id, reason, "pause_failed")
        end
      end)
    end
  end

  @doc """
  RESUMES a `:paused` task in place: the SAME task id is re-enqueued from its
  durable run state (`docs/task-pause.md`).

  Returns the saved state (`%{task_id:, status:, pause_kind:}`) with `status`
  back to `running`; `pause_kind` is `nil` unless the row is still paused, and
  never `"clean"`/`"dirty"` for a running task. Only a paused task is accepted
  (`not_paused` otherwise), and a task with no durable run is `not_resumable`.
  """
  def resume(args) do
    with :ok <- keys(args, ~w(task_id)),
         {:ok, id} <- required_string(args, "task_id") do
      safe(fn ->
        case TaskRegistry.resume_task(id) do
          :ok -> pause_state(id)
          {:error, reason} -> pause_error(id, reason, "resume_failed")
        end
      end)
    end
  end

  # The saved pause facts for `id`, read AFTER the registry accepted the request
  # (the registry owns validation and persistence, exactly like cancellation).
  # `nil` is only possible when the row vanished, which is reported like any
  # other missing task.
  defp pause_state(id) do
    case TaskRegistry.get_task(id) do
      nil ->
        error("not_found", "Task not found: #{id}")

      task ->
        {:ok,
         %{
           task_id: id,
           status: to_string(task.status),
           pause_kind: pause_kind(task.pause_kind)
         }}
    end
  end

  defp pause_kind(kind) when is_atom(kind) and not is_nil(kind), do: to_string(kind)
  defp pause_kind(_none), do: nil

  defp pause_error(id, reason, fallback) do
    case reason do
      :not_found ->
        error("not_found", "Task not found: #{id}")

      :not_running ->
        error("not_running", "The task is not running.")

      :not_paused ->
        error("not_paused", "The task is not paused.")

      :not_pausable ->
        error("not_pausable", "An interactive session cannot be paused.")

      :not_resumable ->
        error("not_resumable", "Durable agent state is disabled for the task.")

      :scheduler_unavailable ->
        error("scheduler_unavailable", "The task scheduler is unavailable.")

      other ->
        error(fallback, inspect(other))
    end
  end

  defp status_filter(args) do
    if Map.get(args, "status", "all") in @status_filters,
      do: :ok,
      else: error("invalid_arguments", "Unknown task status.")
  end

  defp model_profile(%{"model_id" => id}) do
    profiles = Config.resolve() |> EvoGit.Config.Schema.model_profiles()

    if Enum.any?(profiles, &(&1[:id] == id)),
      do: :ok,
      else: error("invalid_arguments", "Unknown Genesis model profile: #{id}")
  end

  defp model_profile(_), do: :ok

  defp task_mode(args) do
    type = Map.get(args, "task_type", "evolve")
    mode = Map.get(args, "mode", if(type == "genesis", do: "new", else: "simple"))

    if {type, mode} in [{"genesis", "new"}, {"genesis", "existing"}, {"evolve", "simple"}] do
      {:ok, args |> Map.put("task_type", type) |> Map.put("mode", mode)}
    else
      error("invalid_arguments", "Use evolve/simple or genesis/new or genesis/existing.")
    end
  end

  defp resume(%{"resume_from" => id} = args, path) do
    safe(fn ->
      case TaskRegistry.get_task_lite(id) do
        nil ->
          error("not_found", "Previous task not found: #{id}")

        task ->
          cond do
            args["task_type"] != "evolve" ->
              error("invalid_arguments", "resume_from requires an evolve task.")

            task.status not in @terminal ->
              error("invalid_arguments", "Previous task must be finished before continuing.")

            task_path(task) != path ->
              error("invalid_arguments", "Previous task belongs to a different project.")

            true ->
              :ok
          end
      end
    end)
  end

  defp resume(_, _), do: :ok

  defp project(task) do
    %{
      id: task.id,
      type: to_string(task.type),
      status: to_string(task.status),
      project_path: task_path(task),
      objective_summary: String.slice(task_objective(task) || "", 0, 200),
      objective_length: String.length(task_objective(task) || ""),
      started_at: Codec.encode_datetime(task.started_at),
      finished_at: Codec.encode_datetime(task.finished_at),
      base_sha: task.base_sha,
      commit_sha: task.commit_sha,
      branch_name: task.branch_name,
      review_status: task.review_status,
      result: if(task.result, do: task.result |> Codec.encode_result() |> Jason.decode!()),
      error: task.error
    }
  end

  defp task_objective(task),
    do: Keyword.get(task.opts || [], :objective) || Keyword.get(task.opts || [], :prompt)

  defp task_path(task) do
    case task.project_path || Keyword.get(task.opts || [], :path) do
      path when is_binary(path) -> Path.expand(path)
      _ -> nil
    end
  end

  defp keys(args, allowed) when is_map(args) do
    if Enum.all?(Map.keys(args), &(&1 in allowed)),
      do: :ok,
      else:
        error(
          "invalid_arguments",
          "Unknown argument; supported keys: #{Enum.join(allowed, ", ")}"
        )
  end

  defp keys(_, _), do: error("invalid_arguments", "Arguments must be an object.")

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        if String.trim(value) != "",
          do: {:ok, value},
          else: error("invalid_arguments", "#{key} must not be empty.")

      _ ->
        error("invalid_arguments", "#{key} must be a string.")
    end
  end

  defp optional_strings(args, names) do
    Enum.reduce_while(names, :ok, fn key, :ok ->
      case if(Map.has_key?(args, key), do: required_string(args, key), else: {:ok, nil}) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # An OPTIONAL boolean flag: absent is fine (the core default applies), any
  # present non-boolean is refused before a task is enqueued.
  defp optional_boolean(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> error("invalid_arguments", "#{key} must be a boolean.")
      :error -> :ok
    end
  end

  defp required_path(args) do
    with {:ok, path} <- required_string(args, "path") do
      if Path.type(path) == :absolute,
        do: {:ok, Path.expand(path)},
        else: error("invalid_arguments", "path must be an absolute local project path.")
    end
  end

  defp optional_path(%{"path" => _} = args), do: required_path(args)
  defp optional_path(_), do: {:ok, nil}

  defp ready_project(path) do
    case project_readiness(path) do
      %{ready: true} -> :ok
      %{reason: reason} -> error("invalid_arguments", reason)
    end
  end

  # Match Runtime.ensure_repo/1: new directories are initialized by the runtime,
  # whereas an existing primary checkout must already have a resolvable HEAD.
  # This probe never initializes, stages, commits, or changes project files.
  defp project_readiness(path) do
    git_dir = Path.join(path, ".git")

    {ready, action, reason} =
      cond do
        not File.dir?(path) ->
          {false, nil, "Project directory does not exist: #{path}"}

        File.dir?(git_dir) ->
          case EvoGit.Adapters.Git.rev_parse(path, "HEAD^{commit}") do
            {:ok, _} ->
              {true, "use_repository", nil}

            _ ->
              {false, "use_repository",
               "Existing repository needs a valid HEAD. Make an initial commit before starting Genesis."}
          end

        File.exists?(git_dir) ->
          {false, nil,
           "Genesis requires a primary checkout with a .git directory; linked worktree and submodule roots are not supported by this entry point."}

        true ->
          {true, "initialize_repository", nil}
      end

    %{path: path, exists: File.dir?(path), ready: ready, git_action: action, reason: reason}
  end

  defp integer(args, key, default, min, max) do
    value = Map.get(args, key, default)

    if is_integer(value) and value >= min and value <= max,
      do: {:ok, value},
      else: error("invalid_arguments", "#{key} must be an integer between #{min} and #{max}.")
  end

  defp safe(fun) do
    fun.()
  rescue
    # Transport boundary: existing service calls can raise while restarting or
    # reading malformed records; return no internal call arguments or data.
    _error -> error("unavailable", "Task service is unavailable.")
  catch
    :exit, {:timeout, _call} -> error("unavailable", "Task service did not respond in time.")
    :exit, _reason -> error("unavailable", "Task service is unavailable.")
  end

  defp error(code, message), do: {:error, %{code: code, message: message}}
end
