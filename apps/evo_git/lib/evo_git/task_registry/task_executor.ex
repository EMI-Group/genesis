defmodule EvoGit.TaskRegistry.TaskExecutor do
  @moduledoc """
  Task execution functions for `EvoGit.TaskRegistry`.

  These functions run in spawned processes under `Task.Supervisor` — NOT in the
  GenServer process. They call into `EvoGit.Runtime.*` modules to perform the
  actual genesis, evolution, or skill extraction work.
  """

  alias EvoGit.TaskRegistry.ResumeContext
  alias EvoGit.TaskRegistry.RuntimeOpts

  @process_registry EvoGit.TaskRegistry.ProcessRegistry

  @doc """
  Execute a genesis, evolve, or skill extraction task.

  Runs in a separate process under `Task.Supervisor`.
  """
  def execute_task(:genesis, opts, task_id) do
    register_task_process(task_id)
    {_input_arg, runtime_opts} = RuntimeOpts.build_common_runtime_opts(opts, task_id, :genesis)
    prompt = Keyword.get(opts, :prompt, "")
    EvoGit.Runtime.Genesis.run(prompt, runtime_opts)
  end

  def execute_task(:evolve, opts, task_id) do
    register_task_process(task_id)
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

  def execute_task(:extract_skills, opts, task_id) do
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
