defmodule EvoGit.Agent.Tools.FileCreate do
  @moduledoc """
  Tool for creating empty files and auto-committing them.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "create_files",
      description: """
      Creates one or more empty files and automatically commits them for git tracking.
      This tool is useful for creating empty files to spawn subagents on, because subagents need a concrete path to work with, and using empty files is the idiomatic way to do this.

      ## Default Behavior

      By default, this tool:
      1. Creates all specified empty files (and their parent directories if needed).
      2. Automatically commits these changes with a descriptive commit message (only the new files are staged/committed, other dirty files are unaffected).
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "List of file paths to create. Paths are relative to git repo path. Example: ['./src/index.js', './docs/README.md']."
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to automatically commit the created files. When true, only the newly created files are committed, other files won't be affected. Default: true.",
            "default" => true
          },
          "parents" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create parent directories recursively if they don't exist. Default: true.",
            "default" => true
          }
        },
        "required" => ["paths"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the create_files tool.
  """
  def execute(args, repo_path, _repo_root, node_path \\ nil) do
    with {:ok, paths} <- Shared.fetch_array_arg(args, "paths"),
         {:ok, commit?} <- fetch_commit(args),
         {:ok, parents?} <- fetch_parents(args) do
      do_create_files(paths, commit?, parents?, repo_path, node_path)
    end
  end

  defp fetch_commit(args) do
    commit? = Map.get(args, "commit", true)
    if is_boolean(commit?), do: {:ok, commit?}, else: {:error, "commit must be a boolean"}
  end

  defp fetch_parents(args) do
    parents? = Map.get(args, "parents", true)
    if is_boolean(parents?), do: {:ok, parents?}, else: {:error, "parents must be a boolean"}
  end

  defp do_create_files(paths, commit?, parents?, repo_path, node_path) do
    results =
      Enum.map(paths, fn path ->
        expanded_path = Shared.expand_path(path, repo_path)
        create_file(expanded_path, path, parents?, repo_path, node_path)
      end)

    {successes, failures} = Enum.split_with(results, &(&1 == :ok))

    base_message =
      if length(successes) > 0 do
        if failures == [] do
          "Successfully created #{length(successes)} file#{if(length(successes) == 1, do: "", else: "s")}: #{Enum.join(paths, ", ")}"
        else
          "Created #{length(successes)} file#{if(length(successes) == 1, do: "", else: "s")}: #{Enum.join(paths, ", ")}. Some files had errors."
        end
      else
        "Failed to create files: #{Enum.join(paths, ", ")}"
      end

    message =
      if failures != [] do
        error_details =
          Enum.map(failures, fn
            {:error, path, reason} -> "  - #{path}: #{reason}"
          end)
          |> Enum.join("\n")

        base_message <> "\nErrors:\n" <> error_details
      else
        base_message
      end

    # Auto-commit if requested and at least one file was created successfully
    final_message =
      if commit? and successes != [] do
        case do_commit(repo_path, paths) do
          {:ok, output} -> message <> "\n\nChanges committed.\n" <> output
          {:error, reason} -> message <> "\n\nWarning: Failed to commit: #{reason}"
        end
      else
        message
      end

    final_message
  end

  defp create_file(full_path, display_path, parents?, repo_path, node_path) do
    case Shared.validate_file_scope(full_path, node_path, repo_path) do
      :ok ->
        do_create_file(full_path, display_path, parents?)

      {:error, message} ->
        {:error, display_path, message}
    end
  end

  defp do_create_file(full_path, display_path, parents?) do
    with :ok <- mkdir_if_needed(Path.dirname(full_path), parents?),
         :ok <- perform_create_file(full_path) do
      :ok
    else
      {:error, reason} ->
        {:error, display_path, :file.format_error(reason)}
    end
  end

  defp mkdir_if_needed(path, parents), do: Shared.mkdir_if_needed(path, parents)

  defp perform_create_file(path) do
    case File.write(path, "") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_commit(repo_path, paths) do
    files_to_add = paths
    commit_message =
      "Create file#{if(length(paths) == 1, do: "", else: "s")}: #{Enum.join(paths, ", ")}"

    Shared.do_git_commit(repo_path, files_to_add, commit_message)
  end
end
