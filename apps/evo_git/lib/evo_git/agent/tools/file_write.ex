defmodule EvoGit.Agent.Tools.FileWrite do
  @moduledoc """
  Tool for writing file contents.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "write_file",
      description:
        "Writes a file to the local filesystem. " <>
          "Usage: " <>
          "- This tool will overwrite the existing file if there is one at the provided path. " <>
          "- Prefer the edit_file tool for modifying existing files — it only sends the diff. " <>
          "Only use this tool to create new files or for complete rewrites.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "The path to the file to write (relative to git repo path, e.g., './src/index.js')"},
          "content" => %{"type" => "string", "description" => "The content to write to the file"}
        },
        "required" => ["file_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the write_file tool.
  """
  def execute(args, repo_path, _repo_root, node_path \\ nil) do
    with {:ok, file_path} <- Shared.fetch_string_arg(args, "file_path"),
         {:ok, content} <- Shared.fetch_string_arg(args, "content"),
         expanded_path = Shared.expand_path(file_path, repo_path) do
      do_write(expanded_path, file_path, content, repo_path, node_path)
    end
  end

  defp do_write(file_path, display_path, content, repo_path, node_path) do
    case Shared.validate_file_scope(file_path, node_path, repo_path) do
      :ok ->
        perform_write(file_path, display_path, content)

      {:error, message} ->
        message
    end
  end

  defp perform_write(file_path, display_path, content) do
    case File.mkdir_p(Path.dirname(file_path)) do
      :ok ->
        case File.write(file_path, content) do
          :ok -> "Successfully wrote to #{display_path}"
          {:error, reason} -> "Error writing file #{display_path}: #{:file.format_error(reason)}"
        end

      {:error, reason} ->
        "Error creating directory for #{display_path}: #{:file.format_error(reason)}"
    end
  end
end
