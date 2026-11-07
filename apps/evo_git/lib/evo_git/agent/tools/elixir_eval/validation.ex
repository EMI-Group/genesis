defmodule EvoGit.Agent.Tools.ElixirEval.Validation do
  @moduledoc false

  alias EvoGit.Config
  alias EvoGit.Config.Schema

  @start_keys [:path, :mode, :objective, :prompt, :model_id, :model_spec]
  @model_spec_keys ["provider_profile_id", "model", "reasoning_effort"]
  @types %{
    "genesis" => :genesis,
    "evolve" => :evolve,
    "reflect" => :reflect,
    "extract_skills" => :extract_skills
  }
  @pages [nil, "/", "/help", "/projects", "/tasks", "/agents", "/settings", "/system"]

  @scheduler_keys [
    :default_llm_max_concurrency,
    :max_tool_concurrency,
    :max_turns,
    :max_turns_root,
    :paused
  ]

  # Scheduler.update_config trusts its callers. Validate here before dispatch;
  # literal keys/ranges exclude credentials, model/provider options and paths.
  def scheduler_options(options) do
    with {:ok, opts} <- normalize(options, @scheduler_keys),
         true <- opts != [],
         true <- Enum.all?(opts, &valid_scheduler_option?/1),
         true <- not Keyword.has_key?(opts, :paused) or length(opts) == 1 do
      {:ok, opts}
    else
      _ ->
        {:error,
         "Expected concurrency integers 1..256, turn-cap integers 1..10000, or a standalone boolean paused option; unknown, duplicate and empty options are refused."}
    end
  end

  defp valid_scheduler_option?({:paused, value}), do: is_boolean(value)

  defp valid_scheduler_option?({key, value})
       when key in [:default_llm_max_concurrency, :max_tool_concurrency],
       do: is_integer(value) and value in 1..256

  defp valid_scheduler_option?({key, value}) when key in [:max_turns, :max_turns_root],
    do: is_integer(value) and value in 1..10_000

  def start_options(type, options) when is_binary(type) and is_map(options) do
    task_type = Map.get(@types, type)

    with true <- task_type != nil,
         {:ok, opts} <- normalize(options, @start_keys),
         true <- Enum.all?(opts, &valid_start_option?/1),
         {:ok, opts} <- validate_mode(task_type, opts),
         {:ok, opts} <- validate_path(task_type, opts),
         {:ok, opts} <- validate_text(task_type, opts),
         {:ok, opts} <- validate_model(opts) do
      {:ok, task_type, opts}
    else
      {:error, _} = error -> error
      _ -> {:error, "Invalid task type or task options."}
    end
  end

  def start_options(_, _), do: {:error, "Expected a task type string and options map."}

  def guide(message, options) do
    with true <- valid_string?(message, 2_000),
         {:ok, opts} <- normalize(options, [:page, :selector, :dismissible]),
         page <- Keyword.get(opts, :page),
         selector <- Keyword.get(opts, :selector),
         dismissible <- Keyword.get(opts, :dismissible, true),
         true <- page in @pages,
         true <- is_boolean(dismissible),
         true <- valid_selector?(selector) do
      {:ok, %{message: message, page: page, selector: selector, dismissible: dismissible}}
    else
      _ ->
        {:error,
         "Guide requires a short message, a known local page and an optional simple #id selector."}
    end
  end

  defp validate_path(:reflect, opts) do
    if Keyword.has_key?(opts, :path),
      do: {:error, "Reflect tasks do not accept a source path."},
      else: {:ok, opts}
  end

  defp validate_path(type, opts) do
    path = Keyword.get(opts, :path)
    new_repo? = type == :genesis and Keyword.get(opts, :mode) == "new"

    if valid_string?(path, 1_024) and Path.type(path) == :absolute and
         (new_repo? or File.dir?(path)) do
      {:ok, Keyword.put(opts, :path, Path.expand(path))}
    else
      {:error, "This task type requires an absolute path (at most 1024 bytes)."}
    end
  end

  defp validate_mode(type, opts) do
    {default, allowed} =
      case type do
        :genesis -> {"new", ["new", "existing"]}
        :evolve -> {"simple", ["simple"]}
        :reflect -> {"reflect", ["reflect"]}
        :extract_skills -> {nil, [nil]}
      end

    mode = Keyword.get(opts, :mode, default)

    cond do
      mode not in allowed ->
        {:error, "Unsupported mode; custom and merge/resume modes are not exposed."}

      mode == nil ->
        {:ok, opts}

      true ->
        {:ok, Keyword.put(opts, :mode, mode)}
    end
  end

  defp validate_text(:extract_skills, opts) do
    if Keyword.has_key?(opts, :objective) or Keyword.has_key?(opts, :prompt),
      do: {:error, "Skill extraction accepts only path and model options."},
      else: {:ok, opts}
  end

  defp validate_text(type, opts) do
    objective = Keyword.get(opts, :objective)
    prompt = Keyword.get(opts, :prompt)

    cond do
      type == :genesis and (prompt != nil or objective != nil) ->
        text = prompt || objective
        {:ok, opts |> Keyword.put(:prompt, text) |> Keyword.put(:objective, text)}

      type != :genesis and prompt != nil ->
        {:error, "Only genesis tasks accept prompt."}

      objective != nil ->
        {:ok, opts}

      true ->
        {:error, "Provide a nonblank objective (or a genesis prompt)."}
    end
  end

  # Bound the wire shape without normalizing or resolving its fields here.
  # The shared resolver owns provider/profile/model compatibility decisions.
  defp valid_start_option?({:model_spec, spec}) when is_map(spec) and map_size(spec) <= 3 do
    Enum.all?(spec, fn {key, value} ->
      key in @model_spec_keys and valid_string?(value, 8_000)
    end)
  end

  defp valid_start_option?({:model_spec, _}), do: false
  defp valid_start_option?({_key, value}), do: valid_string?(value, 8_000)

  defp validate_model(opts) do
    cond do
      Keyword.has_key?(opts, :model_spec) and Keyword.has_key?(opts, :model_id) ->
        {:error, "Provide only one of model_spec or model_id, not both."}

      Keyword.has_key?(opts, :model_spec) ->
        validate_model_selector(opts, Keyword.fetch!(opts, :model_spec))

      Keyword.has_key?(opts, :model_id) ->
        validate_model_selector(opts, Keyword.fetch!(opts, :model_id))

      true ->
        {:ok, opts}
    end
  end

  defp validate_model_selector(opts, selector) do
    case Schema.resolve_model_spec(Config.resolve(), selector) do
      {:ok, _resolved} -> {:ok, Keyword.put(opts, :model_id_locked, true)}
      {:error, _reason} -> {:error, "Invalid model selector for the configured profiles."}
    end
  end

  # Literal key mapping, never atomize input, and reject duplicate atom/string
  # spellings so there is only one interpretation of each capability argument.
  defp normalize(map, keys) when is_map(map) and map_size(map) <= 5 do
    Enum.reduce_while(map, {:ok, []}, fn {input, value}, {:ok, acc} ->
      key = Enum.find(keys, fn key -> input == key or input == Atom.to_string(key) end)

      if key != nil and not Keyword.has_key?(acc, key),
        do: {:cont, {:ok, [{key, value} | acc]}},
        else: {:halt, {:error, "Unsupported or duplicate option."}}
    end)
  end

  defp normalize(_, _), do: {:error, "Expected a small options map."}

  defp valid_selector?(nil), do: true

  defp valid_selector?(selector) when is_binary(selector) and byte_size(selector) <= 80,
    do: Regex.match?(~r/\A#[a-zA-Z][a-zA-Z0-9_-]*\z/, selector)

  defp valid_selector?(_), do: false

  defp valid_string?(value, max) when is_binary(value) and byte_size(value) <= max do
    String.valid?(value) and String.trim(value) != "" and
      not String.contains?(value, <<0>>)
  end

  defp valid_string?(_, _), do: false
end
