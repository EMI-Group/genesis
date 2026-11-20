defmodule EvoGit.Agent.Tools.ListDirectory do
  @moduledoc """
  Tool for listing directory contents.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "list_dir",
      description:
        "Use the list_dir tool to list the immediate entries of a directory. " <>
          "Only the direct children are returned, one per line, relative to the repository root.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The path of the directory to list, relative to the repo root (e.g. './', './lib', './test')."
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
        full_path = EvoGit.Platform.safe_expand(dir_path, repo_path)

        case File.ls(full_path) do
          {:ok, files} -> Enum.join(files, "\n")
          {:error, reason} -> list_error(dir_path, reason)
        end

      {:error, message} ->
        Failure.error(message)
    end
  end

  defp list_error(dir_path, reason) do
    Failure.error("listing directory '#{dir_path}' failed: #{:file.format_error(reason)}")
  end
end
