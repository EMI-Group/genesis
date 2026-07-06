defmodule EvoDash.TaskRegistry.RuntimeOpts do
  @moduledoc """
  Runtime options builder for `EvoDash.TaskRegistry`.

  Builds the `runtime_opts` keyword list passed to `EvoGit.Runtime.*` modules
  when executing genesis, evolve, or skill extraction tasks.
  """

  @doc """
  Builds common runtime options for genesis and evolve tasks.

  Returns `{nil, runtime_opts}` — the first element is `nil` (the input arg,
  unused for genesis/evolve; resume-from tasks prepend context to the objective
  separately).
  """
  def build_common_runtime_opts(opts, task_id, task_type) do
    repo_path = Keyword.fetch!(opts, :path)
    mode = Keyword.get(opts, :mode, "simple")
    node_path = Keyword.get(opts, :node_path)

    Application.ensure_all_started(:evo_git)

    runtime_opts = [
      repo_path: repo_path,
      mode: mode_atom(task_type, mode),
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

    # Per-task model selection: threads the selected model profile id into
    # the runtime opts so the scheduler uses that profile for this task.
    # If nil/empty, the runtime falls back to the default (first) profile.
    model_id = Keyword.get(opts, :model_id)

    runtime_opts =
      if model_id && model_id != "",
        do: Keyword.put(runtime_opts, :model_id, model_id),
        else: runtime_opts

    {nil, runtime_opts}
  end

  @doc """
  Converts an evolution mode string to its atom form.
  """
  def evolution_mode_atom("simple"), do: :simple
  def evolution_mode_atom("complex"), do: :complex

  def evolution_mode_atom(other),
    do: raise(ArgumentError, "invalid evolution mode: #{inspect(other)}")

  @doc """
  Converts a genesis mode string to its atom form.
  """
  def genesis_mode_atom("new"), do: :new
  def genesis_mode_atom("existing"), do: :existing

  def genesis_mode_atom(other),
    do: raise(ArgumentError, "invalid genesis mode: #{inspect(other)}")

  @doc """
  Dispatches to the correct mode resolver based on the task type, mirroring
  the core CLI (`apps/evo_git/lib/evo_git/cli.ex`) which has separate
  `genesis_mode_atom/1` (new/existing) and `evolution_mode_atom/1` (simple/complex)
  functions.
  """
  def mode_atom(:genesis, mode), do: genesis_mode_atom(mode)
  def mode_atom(:evolve, mode), do: evolution_mode_atom(mode)
end
