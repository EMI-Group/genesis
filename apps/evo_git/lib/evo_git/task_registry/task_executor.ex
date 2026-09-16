defmodule EvoGit.TaskRegistry.TaskExecutor do
  @moduledoc """
  Task execution functions for `EvoGit.TaskRegistry`.

  These functions run in spawned processes under `Task.Supervisor` — NOT in the
  GenServer process. They call into `EvoGit.Runtime.*` modules to perform the
  actual genesis, evolution, or skill extraction work.
  """

  alias EvoGit.TaskRegistry.MergeContext
  alias EvoGit.TaskRegistry.ResumeContext
  alias EvoGit.TaskRegistry.RuntimeOpts

  @process_registry EvoGit.TaskRegistry.ProcessRegistry

  @doc """
  Execute a genesis, evolve, skill extraction, or reflect task.

  Runs in a separate process under `Task.Supervisor`.

  `server` is the registered name of the `EvoGit.TaskRegistry` instance that
  owns this task. It is stored in the process dictionary under
  `:evogit_task_registry_server` BEFORE any per-type work runs, so callbacks
  made from inside this process (e.g. `MergeContext`/`ResumeContext` loading the
  previous task) resolve back to the SAME registry instance via
  `EvoGit.TaskRegistry.server/0`. Defaults to `__MODULE__` (the production
  singleton), so `execute_task/3` is unchanged for every existing caller.
  """
  def execute_task(task_type, opts, task_id, server \\ __MODULE__) do
    Process.put(:evogit_task_registry_server, server)
    ensure_task_tmpdir(task_id, opts)
    do_execute_task(task_type, opts, task_id)
  end

  # Creates the shared per-task scratch directory at the SINGLE catch-all choke
  # point (this public entry funnels every task type), AFTER the process-
  # dictionary seam is installed and BEFORE `do_execute_task/3`, so the dir
  # exists before any agent can spawn a tool regardless of task type.
  # `EvoGit.TaskTmpdir.ensure/2` is idempotent and NEVER raises (a filesystem
  # failure is logged and the path is still returned), so no try/rescue is
  # warranted. `opts[:path]` is the task's PRIMARY repo path — deliberately
  # `Keyword.get/3` so a nil/missing `:path` (repo-less/`:reflect` tasks) does
  # not crash the wrapper and correctly falls back to system mode.
  defp ensure_task_tmpdir(task_id, opts) do
    _ = EvoGit.TaskTmpdir.ensure(task_id, Keyword.get(opts, :path))
    :ok
  end

  defp do_execute_task(:genesis, opts, task_id) do
    register_task_process(task_id)
    {_input_arg, runtime_opts} = RuntimeOpts.build_common_runtime_opts(opts, task_id, :genesis)
    prompt = Keyword.get(opts, :prompt, "")
    EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
  end

  defp do_execute_task(:evolve, opts, task_id) do
    register_task_process(task_id)

    opts =
      case Keyword.get(opts, :merge_from) do
        merge_from when is_binary(merge_from) ->
          trimmed = String.trim(merge_from)

          if trimmed != "" do
            MergeContext.apply_merge_context(
              opts,
              task_id,
              trimmed,
              Keyword.get(opts, :merge_target)
            )
          else
            opts
          end

        _ ->
          opts
      end

    resume_from = Keyword.get(opts, :resume_from)

    {objective, runtime_opts} =
      if is_binary(resume_from) and String.trim(resume_from) != "" do
        ResumeContext.apply_resume_context(opts, task_id, String.trim(resume_from))
      else
        objective = Keyword.get(opts, :objective, "")
        {_input_arg, runtime_opts} = RuntimeOpts.build_common_runtime_opts(opts, task_id, :evolve)
        {objective, runtime_opts}
      end

    EvoGit.Runtime.Evolution.run(objective, runtime_opts)
  end

  defp do_execute_task(:extract_skills, opts, task_id) do
    register_task_process(task_id)
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

  defp do_execute_task(:reflect, opts, task_id) do
    register_task_process(task_id)

    # CRITICAL: do NOT call RuntimeOpts.build_common_runtime_opts here — it does
    # `Keyword.fetch!(opts, :path)` which raises KeyError (reflect tasks are
    # repo-less and have no :path). opts carries :objective, optional :model_id,
    # optional :source_root, optional :task_id-ish keys from the dashboard /
    # start_task tool.
    EvoGit.Runtime.SelfReflective.run(opts ++ [task_id: task_id])
  end

  @doc """
  Registers the current process (the spawned task process) in the
  `EvoGit.TaskRegistry.ProcessRegistry` under the `task_id` key. The Registry
  automatically monitors the registered process and removes the entry when it
  dies, providing O(1) lookup of "is this task's process alive?" by `task_id`.
  """
  def register_task_process(task_id) do
    Registry.register(@process_registry, task_id, :task)
  end

  @doc """
  Generates a random 16-character hex task ID.
  """
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
