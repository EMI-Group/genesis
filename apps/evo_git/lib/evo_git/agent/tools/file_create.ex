defmodule EvoGit.Agent.Tools.FileCreate do
  @moduledoc """
  Tool for creating empty files and auto-committing them.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "create_files",
      description:
        "Use the create_files tool to create several empty files in one call. " <>
          "Each listed path is written as an EMPTY file, so an existing file at that path is truncated to empty. " <>
          "Only the listed paths are staged and committed; other dirty files are left alone. " <>
          "The paths must stay inside the agent's assigned node — anything outside it is rejected.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The file paths to create, relative to the repo root (e.g. ['./src/index.js', './docs/README.md'])."
          },
          "commit" => %{
            "type" => "boolean",
            "description" => "Whether to commit the created files. Default: true.",
            "default" => true
          },
          "parents" => %{
            "type" => "boolean",
            "description" => "Whether to create missing parent directories. Default: true.",
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
  def execute(args, repo_path, repo_root, node_path \\ nil) do
    with {:ok, paths} <- Shared.fetch_array_arg(args, "paths"),
         {:ok, commit?} <- Shared.fetch_optional_boolean_arg(args, "commit", true),
         {:ok, parents?} <- Shared.fetch_optional_boolean_arg(args, "parents", true) do
      do_create_files(paths, commit?, parents?, repo_path, repo_root, node_path)
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp do_create_files(paths, commit?, parents?, repo_path, repo_root, node_path) do
    results =
      Enum.map(paths, fn path ->
        expanded_path = Shared.expand_path(path, repo_path)
        create_file(expanded_path, path, parents?, repo_path, node_path)
      end)

    {successes, failures} = Enum.split_with(results, &(&1 == :ok))

    base_message =
      if successes != [] do
        if failures == [] do
          "Successfully created #{length(successes)} file#{if(length(successes) == 1, do: "", else: "s")}: #{Enum.join(paths, ", ")}"
        else
          "Created #{length(successes)} file#{if(length(successes) == 1, do: "", else: "s")}: #{Enum.join(paths, ", ")}. Some files had errors."
        end
      else
        Failure.error("failed to create files: #{Enum.join(paths, ", ")}")
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
        case do_commit(repo_path, repo_root, paths) do
          {:ok, output} -> message <> "\n\nChanges committed.\n" <> output
          {:error, reason} -> message <> Failure.notice("Failed to commit: #{reason}")
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
         :ok <- File.write(full_path, "") do
      :ok
    else
      {:error, reason} ->
        {:error, display_path, :file.format_error(reason)}
    end
  end

  defp mkdir_if_needed(path, parents), do: Shared.mkdir_if_needed(path, parents)

  defp do_commit(repo_path, repo_root, paths) do
    files_to_add = paths

    commit_message =
      "Create file#{if(length(paths) == 1, do: "", else: "s")}: #{Enum.join(paths, ", ")}"

    Shared.commit_files(repo_path, repo_root, files_to_add, commit_message)
  end
end
