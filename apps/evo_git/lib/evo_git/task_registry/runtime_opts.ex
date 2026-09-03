defmodule EvoGit.TaskRegistry.RuntimeOpts do
  @moduledoc """
  Runtime options builder for `EvoGit.TaskRegistry`.

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

    Application.ensure_all_started(:evo_git)

    runtime_opts = [
      repo_path: repo_path,
      mode: mode_atom(task_type, mode),
      task_id: task_id
    ]

    node_path = Keyword.get(opts, :node_path)
    starting_commit = Keyword.get(opts, :starting_commit)

    # Foreign repos are passed through opts from the dashboard (per-task scoping)
    foreign_repos = Keyword.get(opts, :foreign_repos)

    archive = Keyword.get(opts, :archive)

    # Per-task model selection: threads the selected model profile id into
    # the runtime opts so the scheduler uses that profile for this task.
    # If nil/empty, the runtime falls back to the default (first) profile.
    model_id = Keyword.get(opts, :model_id)

    # Custom agent selection: thread the agents.toml agent id through to the
    # runtime so genesis/evolve spawn the custom agent as the root agent.
    agent = Keyword.get(opts, :agent)

    # Explicit model-lock pass-through (see Helpers.model_id_locked?/1).
    # Note: dashboard tasks with an explicit model_id are locked implicitly
    # by Helpers.model_id_locked?/1 at the spawn site.
    model_id_locked = Keyword.get(opts, :model_id_locked)

    # Per-task build system selection: threads the selected build system atom
    # into the runtime opts for genesis tasks.
    build_system = Keyword.get(opts, :build_system)

    runtime_opts =
      runtime_opts
      |> put_if(:node_path, node_path)
      |> put_if(:starting_commit, starting_commit)
      |> put_if(:foreign_repos, foreign_repos)
      |> put_if(:archive, archive)
      |> put_if(:model_id, model_id, fn value -> value && value != "" end)
      |> put_if(:agent, agent, fn value -> is_binary(value) and value != "" end)
      |> put_if_true(:model_id_locked, model_id_locked)
      |> put_if(:build_system, build_system)

    {nil, runtime_opts}
  end

  # Puts `key => value` when `predicate.(value)` is truthy; the default
  # predicate is plain truthiness of the value, mirroring the original
  # `if value, do: Keyword.put(...)` conditionals.
  defp put_if(keywords, key, value, predicate \\ & &1) do
    if predicate.(value), do: Keyword.put(keywords, key, value), else: keywords
  end

  # Puts `key => true` (never the value itself) when `value` is truthy —
  # mirrors the model_id_locked pass-through, which only records that the
  # lock is on.
  defp put_if_true(keywords, key, value) do
    if value, do: Keyword.put(keywords, key, true), else: keywords
  end

  @doc """
  Converts an evolution mode string to its atom form.
  """
  def evolution_mode_atom("simple"), do: :simple
  def evolution_mode_atom("custom"), do: :custom

  def evolution_mode_atom(other),
    do: raise(ArgumentError, "invalid evolution mode: #{inspect(other)}")

  @doc """
  Converts a genesis mode string to its atom form.
  """
  def genesis_mode_atom("new"), do: :new
  def genesis_mode_atom("existing"), do: :existing

  def genesis_mode_atom("custom"),
    do:
      raise(ArgumentError, "custom mode is evolve-only; use an evolve task with mode \"custom\"")

  def genesis_mode_atom(other),
    do: raise(ArgumentError, "invalid genesis mode: #{inspect(other)}")

  @doc """
  Dispatches to the correct mode resolver based on the task type, mirroring
  the core CLI (`apps/evo_git/lib/evo_git/cli.ex`) which has separate
  `genesis_mode_atom/1` (new/existing) and `evolution_mode_atom/1`
  (simple/custom) functions. Note: genesis tasks with mode "custom" raise a
  specific evolve-only error instead of the generic invalid-mode error.
  """
  def mode_atom(:genesis, mode), do: genesis_mode_atom(mode)
  def mode_atom(:evolve, mode), do: evolution_mode_atom(mode)
end
