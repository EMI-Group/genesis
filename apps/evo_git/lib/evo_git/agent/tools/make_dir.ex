defmodule EvoGit.Agent.Tools.MakeDir do
  @moduledoc """
  Tool for creating directories with optional placeholder files.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @keep_file_options ~w(CONTEXT.md .gitkeep none)

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "make_dir",
      description:
        "Use the make_dir tool to create a directory (parents included). " <>
          "Git does NOT track empty directories, so each directory gets a placeholder file (CONTEXT.md by default) and is committed. " <>
          "The paths must stay inside the agent's assigned node — anything outside it is rejected.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The directory paths to create, relative to the repo root (e.g. ['./src/components', './lib/utils'])."
          },
          "keep_file" => %{
            "type" => "string",
            "enum" => @keep_file_options,
            "description" =>
              "The placeholder file that makes the directory tracked: CONTEXT.md (default), .gitkeep, or none.",
            "default" => "CONTEXT.md"
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to commit the keep files. Only those files are staged. Default: true.",
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
  Executes the make_dir tool.
  """
  def execute(args, repo_path, repo_root, node_path \\ nil) do
    with {:ok, paths} <- Shared.fetch_array_arg(args, "paths"),
         {:ok, keep_file} <- fetch_keep_file(args),
         {:ok, commit?} <- Shared.fetch_optional_boolean_arg(args, "commit", true),
         {:ok, parents?} <- Shared.fetch_optional_boolean_arg(args, "parents", true) do
      do_make_dir(paths, keep_file, commit?, parents?, repo_path, repo_root, node_path)
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp fetch_keep_file(args) do
    case Map.get(args, "keep_file") do
      nil ->
        {:ok, "CONTEXT.md"}

      value when value in @keep_file_options ->
        {:ok, value}

      other ->
        {:error,
         "Invalid keep_file value: #{other}. Must be one of: #{inspect(@keep_file_options)}"}
    end
  end

  defp do_make_dir(paths, keep_file, commit?, parents?, repo_path, repo_root, node_path) do
    results =
      Enum.map(paths, fn path ->
        expanded_path = Shared.expand_path(path, repo_path)
        create_dir(expanded_path, path, keep_file, parents?, repo_path, node_path)
      end)

    {successes, failures} = Enum.split_with(results, &(&1 == :ok))

    base_message =
      if successes != [] do
        if failures == [] do
          "Successfully created #{length(successes)} director#{if(length(successes) == 1, do: "y", else: "ies")}: #{Enum.join(paths, ", ")}"
        else
          "Created #{length(successes)} director#{if(length(successes) == 1, do: "y", else: "ies")}: #{Enum.join(paths, ", ")}. Some directories had errors."
        end
      else
        Failure.error("failed to create directories: #{Enum.join(paths, ", ")}")
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
        case do_commit(repo_path, repo_root, paths, keep_file) do
          {:ok, output} -> message <> "\n\nChanges committed.\n" <> output
          {:error, reason} -> message <> Failure.notice("Failed to commit: #{reason}")
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

  defp do_commit(repo_path, repo_root, paths, keep_file) do
    # Only stage the keep files we created, not any other dirty files in the workspace
    files_to_add =
      Enum.flat_map(paths, fn path ->
        case keep_file do
          "none" -> []
          filename -> [Path.join([path, filename])]
        end
      end)

    commit_message =
      "Create director#{if(length(paths) == 1, do: "y", else: "ies")}: #{Enum.join(paths, ", ")}"

    Shared.commit_files(repo_path, repo_root, files_to_add, commit_message)
  end
end
