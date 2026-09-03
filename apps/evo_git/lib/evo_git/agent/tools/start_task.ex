defmodule EvoGit.Agent.Tools.StartTask do
  @moduledoc """
  Command handler for the `StartTask.start_task` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Starts a new background
  task (genesis / evolve / reflect / extract_skills) in the task registry.
  """

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

  @truncate_length 2000

  @doc """
  Executes the start_task tool.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, task_type} <- fetch_task_type(args),
         {:ok, objective} <- Shared.fetch_optional_string_arg(args, "objective", ""),
         {:ok, path} <- Shared.fetch_optional_string_arg(args, "path"),
         {:ok, mode} <- Shared.fetch_optional_string_arg(args, "mode"),
         {:ok, resume_from} <- Shared.fetch_optional_string_arg(args, "resume_from"),
         {:ok, starting_commit} <- Shared.fetch_optional_string_arg(args, "starting_commit"),
         {:ok, model_id} <- Shared.fetch_optional_string_arg(args, "model_id") do
      opts =
        []
        |> maybe_put(:objective, objective)
        |> maybe_put(:path, path)
        |> maybe_put(:mode, mode)
        |> maybe_put(:resume_from, resume_from)
        |> maybe_put(:starting_commit, starting_commit)
        |> maybe_put(:model_id, model_id)

      case safe_start_task(task_type, opts) do
        {:ok, task} -> format_success(task, task_type, objective)
        {:error, reason} -> "Task could not be started: #{inspect(reason)}"
      end
    else
      {:error, message} -> message
    end
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

  # --- Task registry call ---

  defp safe_start_task(task_type, opts) do
    EvoGit.TaskRegistry.start_task(task_type, opts)
  rescue
    e ->
      # Tool boundary: the task system (TaskRegistry GenServer / SQLite store)
      # may be down, or the 30s GenServer.call timeout may fire. A crash must
      # never kill the agent loop — the LLM gets a readable error string it can
      # act on instead.
      {:error, Exception.message(e)}
  catch
    :exit, reason ->
      {:error, inspect(reason)}
  end

  # --- Formatting ---

  defp format_success(task, task_type, objective) do
    base = "Task #{task.id} started (type: #{task_type})"

    case String.trim(objective) do
      "" -> base
      obj -> base <> ". Objective: #{Shared.truncate(obj, @truncate_length)}"
    end
  end
end
