defmodule EvoGit.Agent.Tools.MakeDir do
  @moduledoc """
  Tool for creating directories with optional placeholder files.
  """

  alias EvoGit.Agent.Tools.Shared

  @keep_file_options ~w(CONTEXT.md .gitkeep none)

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "make_dir",
      description: """
      Creates one or more directories with optional placeholder files for git tracking.

      ## Why Placeholder Files Are Needed

      Git does NOT track empty directories.
      If you create a directory without adding any files to it, git will ignore it completely.
      To make a directory visible in the repository, you need to add at least one file (typically a placeholder file like CONTEXT.md or .gitkeep).

      ## Default Behavior

      By default, this tool:
      1. Creates all specified directories (with parent directories if needed)
      2. Creates an empty CONTEXT.md file in each directory (so git tracks them)
      3. Automatically commits these changes with a descriptive commit message (only the new directories and their keep files are staged/committed, other dirty files are unaffected)

      IMPORTANT: Unless you have a specific reason, it's recommended to keep the default settings to ensure directories are immediately tracked.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of directory paths to create. Paths are relative to git repo path. Example: ['./src/components', './lib/utils']."
          },
          "keep_file" => %{
            "type" => "string",
            "enum" => @keep_file_options,
            "description" =>
              "Type of placeholder file to create in each directory so git tracks them. " <>
                "CONTEXT.md: Creates an empty CONTEXT.md file (default, recommended). " <>
                ".gitkeep: Creates a .gitkeep file (standard convention but less descriptive). " <>
                "none: No placeholder file created. Directory won't be tracked by git until you add actual files. " <>
                "Only use 'none' if you plan to write files to the directory immediately.",
            "default" => "CONTEXT.md"
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to automatically commit the created directories. When true, the keep files are committed, other files won't be affected. Default: true.",
            "default" => true
          },
          "parents" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create parent directories recursively (like 'mkdir -p'). Default: true.",
            "default" => true
          }
        },
        "required" => ["paths"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the make_dir tool.
  """
  def execute(args, repo_path, _repo_root, node_path \\ nil) do
    with {:ok, paths} <- Shared.fetch_array_arg(args, "paths"),
         {:ok, keep_file} <- fetch_keep_file(args),
         {:ok, commit?} <- fetch_commit(args),
         {:ok, parents?} <- fetch_parents(args) do
      do_make_dir(paths, keep_file, commit?, parents?, repo_path, node_path)
    end
  end

  defp fetch_keep_file(args) do
    case Map.get(args, "keep_file") do
      nil -> {:ok, "CONTEXT.md"}
      value when value in @keep_file_options -> {:ok, value}
      other -> {:error, "Invalid keep_file value: #{other}. Must be one of: #{inspect(@keep_file_options)}"}
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

  defp do_make_dir(paths, keep_file, commit?, parents?, repo_path, node_path) do
    results =
      Enum.map(paths, fn path ->
        expanded_path = Shared.expand_path(path, repo_path)
        create_dir(expanded_path, path, keep_file, parents?, repo_path, node_path)
      end)

    {successes, failures} = Enum.split_with(results, &(&1 == :ok))

    base_message =
      if length(successes) > 0 do
        if failures == [] do
          "Successfully created #{length(successes)} director#{if(length(successes) == 1, do: "y", else: "ies")}: #{Enum.join(paths, ", ")}"
        else
          "Created #{length(successes)} director#{if(length(successes) == 1, do: "y", else: "ies")}: #{Enum.join(paths, ", ")}. Some directories had errors."
        end
      else
        "Failed to create directories: #{Enum.join(paths, ", ")}"
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

    # Auto-commit if requested and at least one directory was created successfully
    final_message =
      if commit? and successes != [] do
        case do_commit(repo_path, paths, keep_file) do
          {:ok, output} -> message <> "\n\nChanges committed.\n" <> output
          {:error, reason} -> message <> "\n\nWarning: Failed to commit: #{reason}"
        end
      else
        message
      end

    final_message
  end

  defp create_dir(full_path, display_path, keep_file, parents?, repo_path, node_path) do
    case Shared.validate_file_scope(full_path, node_path, repo_path) do
      :ok ->
        do_create_dir(full_path, display_path, keep_file, parents?)

      {:error, message} ->
        {:error, display_path, message}
    end
  end

  defp do_create_dir(full_path, display_path, keep_file, parents?) do
    with :ok <- mkdir_if_needed(full_path, parents?),
         :ok <- create_keep_file(full_path, keep_file) do
      :ok
    else
      {:error, reason} ->
        {:error, display_path, :file.format_error(reason)}
    end
  end

  defp mkdir_if_needed(path, parents), do: Shared.mkdir_if_needed(path, parents)

  defp create_keep_file(_path, "none"), do: :ok

  defp create_keep_file(path, filename) do
    keep_path = Path.join(path, filename)
    case File.write(keep_path, "") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_commit(repo_path, paths, keep_file) do
    # Only stage the keep files we created, not any other dirty files in the workspace
    files_to_add =
      Enum.flat_map(paths, fn path ->
        case keep_file do
          "none" -> []
          filename -> [Path.join([path, filename])]
        end
      end)

    commit_message = "Create director#{if(length(paths) == 1, do: "y", else: "ies")}: #{Enum.join(paths, ", ")}"
    Shared.do_git_commit(repo_path, files_to_add, commit_message)
  end
end
