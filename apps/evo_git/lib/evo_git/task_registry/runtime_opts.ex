defmodule EvoGit.TaskRegistry.RuntimeOpts do
  @moduledoc """
  Runtime options builder for `EvoGit.TaskRegistry`.

  Builds the `runtime_opts` keyword list passed to `EvoGit.Runtime.*` modules
  when executing genesis, evolve, or skill extraction tasks.
  """

  @doc """
  Admits a task's explicit model selection against a configuration snapshot.

  A present `:model_spec` takes precedence over legacy `:model_id`, including
  when the spec is invalid; it must never silently fall back to the legacy id.
  The schema owns validation and resolution. Explicit specs retain only the
  resolved provider-profile/model/effort identity, never caller-supplied extra
  fields, runtime profiles or credentials. Call before persisting/enqueuing the
  task, and again at execution time in case configuration changed since admission.

  Auto (no spec and nil/empty legacy id) omits both selection keys and the lock.
  A model spec forces `model_id_locked: true`; a legacy id only keeps an existing
  truthy lock (normalized to true), so model-selection scripts still apply to
  unlocked legacy tasks. Unrelated task opts are preserved.
  """
  @spec admit_model_selection(keyword(), map()) :: {:ok, keyword()} | {:error, term()}
  def admit_model_selection(opts, config) do
    selection =
      if Keyword.has_key?(opts, :model_spec),
        do: {:model_spec, Keyword.get(opts, :model_spec)},
        else: legacy_selection(Keyword.get(opts, :model_id))

    case selection do
      :auto ->
        {:ok, Keyword.drop(opts, [:model_spec, :model_id, :model_id_locked])}

      {:model_spec, value} when not is_map(value) ->
        {:error, :invalid_model_spec}

      {kind, value} ->
        case EvoGit.Config.Schema.resolve_model_spec(config, value) do
          {:ok, resolved} ->
            source =
              if kind == :model_spec,
                do: Keyword.put(opts, :model_spec, canonical_model_spec(resolved)),
                else: opts

            {:ok, put_model_selection(opts, source)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp legacy_selection(value) when value in [nil, ""], do: :auto
  defp legacy_selection(value), do: {:explicit, value}

  @doc """
  Builds common runtime options for genesis and evolve tasks.

  Model selections must already have passed `admit_model_selection/2` at task
  admission/execution; this builder preserves the existing tuple-return API.

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

    # Custom agent selection: thread the agents.toml agent id through to the
    # runtime so genesis/evolve spawn the custom agent as the root agent.
    agent = Keyword.get(opts, :agent)

    # Per-task build system selection: threads the selected build system atom
    # into the runtime opts for genesis tasks.
    build_system = Keyword.get(opts, :build_system)

    # Multi-modal data input (images/audio) for the initial objective —
    # see EvoGit.Attachments. Validated here (spec-error style: malformed
    # payloads fail the task start with a descriptive ArgumentError, exactly
    # like the mode validation above). Deliberately NO model-capability
    # checking. The key is omitted when nil/[] (mirrors the :model_id
    # omit-when-absent pattern).
    attachments = Keyword.get(opts, :attachments)
    EvoGit.Attachments.validate(attachments)

    # Per-task quality level (SPEED ↔ QUALITY trade-off): normalised leniently
    # here (unknown value → warn + "balanced"). The key is omitted for the
    # default so every downstream path is unchanged when unset.
    quality_level = EvoGit.QualityLevel.normalize(Keyword.get(opts, :quality_level))

    runtime_opts =
      runtime_opts
      |> put_if(:budget, Keyword.get(opts, :budget))
      |> put_if(:node_path, node_path)
      |> put_if(:starting_commit, starting_commit)
      |> put_if(:foreign_repos, foreign_repos)
      |> put_if(:archive, archive)
      |> put_model_selection(opts)
      |> put_if(:agent, agent, fn value -> is_binary(value) and value != "" end)
      |> put_if(:build_system, build_system)
      |> put_if(:attachments, attachments, fn value -> value not in [nil, []] end)
      |> put_if(:quality_level, quality_level, fn value -> value != "balanced" end)

    {nil, runtime_opts}
  end

  # resolved.model_spec is a ReqLLM identifier, not the task's selection map.
  # Project only non-secret identity fields, including resolved defaults.
  defp canonical_model_spec(resolved) do
    spec = %{
      "provider_profile_id" => resolved.provider_profile_id,
      "model" => resolved.model
    }

    if is_nil(resolved.reasoning_effort),
      do: spec,
      else: Map.put(spec, "reasoning_effort", resolved.reasoning_effort)
  end

  # Admission canonicalizes specs and removes Auto locks; direct builders retain
  # the supplied selection and legacy truthy locks without resolving again.
  defp put_model_selection(target, source) do
    target = Keyword.drop(target, [:model_spec, :model_id, :model_id_locked])

    cond do
      Keyword.has_key?(source, :model_spec) ->
        target
        |> Keyword.put(:model_spec, Keyword.fetch!(source, :model_spec))
        |> Keyword.put(:model_id_locked, true)

      legacy_selection(Keyword.get(source, :model_id)) != :auto ->
        target
        |> Keyword.put(:model_id, Keyword.fetch!(source, :model_id))
        |> put_if_true(:model_id_locked, Keyword.get(source, :model_id_locked))

      true ->
        put_if_true(target, :model_id_locked, Keyword.get(source, :model_id_locked))
    end
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
