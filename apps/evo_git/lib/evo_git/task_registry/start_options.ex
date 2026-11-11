defmodule EvoGit.TaskRegistry.StartOptions do
  @moduledoc "Validates and translates public command arguments into task options."
  alias EvoGit.Agent.Tools.Shared

  @supported_types ~w(genesis evolve reflect extract_skills)

  # Validated against the fixed literal list above before conversion — never
  # String.to_atom on unvalidated LLM input.
  @task_type_map %{
    "genesis" => :genesis,
    "evolve" => :evolve,
    "reflect" => :reflect,
    "extract_skills" => :extract_skills
  }

  @doc "Builds validated task options shared by the command shell and structured callers."
  def build(args) do
    with {:ok, task_type} <- fetch_task_type(args),
         {:ok, objective} <- Shared.fetch_optional_string_arg(args, "objective", ""),
         {:ok, path} <- Shared.fetch_optional_string_arg(args, "path"),
         {:ok, mode} <- Shared.fetch_optional_string_arg(args, "mode"),
         {:ok, resume_from} <- Shared.fetch_optional_string_arg(args, "resume_from"),
         {:ok, starting_commit} <- Shared.fetch_optional_string_arg(args, "starting_commit"),
         {:ok, model_id} <- Shared.fetch_optional_string_arg(args, "model_id"),
         {:ok, budget} <- budget(args) do
      opts =
        []
        |> maybe_put(:budget, budget)
        |> maybe_put(:objective, objective)
        # Data-plane routing: TaskExecutor.execute_task(:genesis, ...) reads the
        # genesis prompt from opts[:prompt] (Keyword.get(opts, :prompt, "") ->
        # EvoGit.Runtime.Genesis.run) — NOT :objective — so a shell-started
        # genesis task must carry its text under :prompt too, or the prompt
        # would enqueue silently empty. The text is kept under BOTH keys for
        # genesis (the shell's own ListTasks/GetTask displays read :objective);
        # evolve/reflect/extract_skills forward :objective only (they never
        # read :prompt).
        |> maybe_put(:prompt, if(task_type == :genesis, do: objective))
        |> maybe_put(:path, path)
        |> maybe_put(:mode, mode)
        |> maybe_put(:resume_from, resume_from)
        |> maybe_put(:starting_commit, starting_commit)
        |> maybe_put(:model_id, model_id)

      {:ok, task_type, opts}
    end
  end

  defp budget(args) do
    if Map.has_key?(args, "budget"),
      do: EvoGit.TaskBudget.normalize(args["budget"]),
      else: {:ok, nil}
  end

  # --- Argument handling ---

  defp fetch_task_type(args) do
    case Shared.fetch_string_arg(args, "task_type") do
      {:ok, type} ->
        case Map.fetch(@task_type_map, type) do
          {:ok, atom} ->
            {:ok, atom}

          :error ->
            {:error,
             "Unknown task type #{inspect(type)}; supported types: " <>
               Enum.join(@supported_types, ", ")}
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
