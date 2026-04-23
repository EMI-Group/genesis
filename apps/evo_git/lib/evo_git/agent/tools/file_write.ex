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
      name: "file_write",
      description:
        "Writes a file to the local filesystem. " <>
          "Usage: " <>
          "- This tool will overwrite the existing file if there is one at the provided path. " <>
          "- Prefer the file_edit tool for modifying existing files — it only sends the diff. " <>
          "Only use this tool to create new files or for complete rewrites.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "The path to the file to write"},
          "content" => %{"type" => "string", "description" => "The content to write to the file"}
        },
        "required" => ["file_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the file_write tool.
  """
  def execute(args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> Shared.expand_path(repo_path)
    content = Map.fetch!(args, "content")

    case File.mkdir_p(Path.dirname(file_path)) do
      :ok ->
        case File.write(file_path, content) do
          :ok -> "Successfully wrote to #{file_path}"
          {:error, reason} -> "Error writing file #{file_path}: #{:file.format_error(reason)}"
        end

      {:error, reason} ->
        "Error creating directory for #{file_path}: #{:file.format_error(reason)}"
    end
  end
end
