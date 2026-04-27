defmodule EvoGit.Agent.Tools.ListDirectory do
  @moduledoc """
  Tool for listing directory contents.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "list_dir",
      description:
        "Lists the names of files and subdirectories directly within a specified directory path.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" => "The path to the directory to list (e.g., '.', 'lib', 'test')"
          }
        },
        "required" => ["dir_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the list_dir tool.
  """
  def execute(args, repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "dir_path") do
      {:ok, dir_path} ->
        full_path = Path.expand(dir_path, repo_path)

        case File.ls(full_path) do
          {:ok, files} -> Enum.join(files, "\n")
          {:error, reason} -> "Error listing directory #{dir_path}: #{:file.format_error(reason)}"
        end

      {:error, message} ->
        message
    end
  end
end
