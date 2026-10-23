defmodule EvoGit.Agent.Tools.FileWrite do
  @moduledoc """
  Tool for writing file contents.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "write",
      description:
        "Use the write tool to create a new file or replace an entire file's contents. " <>
          "Prefer edit for a small change inside an existing file. " <>
          "The path must stay inside the agent's assigned node — anything outside it is rejected.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" =>
              "The path of the file to write, relative to the repo root (e.g. './src/index.js')"
          },
          "content" => %{
            "type" => "string",
            "description" => "The full content to write to the file"
          }
        },
        "required" => ["file_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the write tool (internal dispatch key: `write_file`).
  """
  def execute(args, repo_path, _repo_root, node_path \\ nil) do
    with {:ok, file_path} <- Shared.fetch_string_arg(args, "file_path"),
         {:ok, content} <- Shared.fetch_string_arg(args, "content"),
         expanded_path = Shared.expand_path(file_path, repo_path) do
      do_write(expanded_path, file_path, content, repo_path, node_path)
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp do_write(file_path, display_path, content, repo_path, node_path) do
    case Shared.validate_file_scope(file_path, node_path, repo_path) do
      :ok ->
        perform_write(file_path, display_path, content)

      {:error, message} ->
        Failure.error(message)
    end
  end

  defp perform_write(file_path, display_path, content) do
    case File.mkdir_p(Path.dirname(file_path)) do
      :ok ->
        case File.write(file_path, content) do
          :ok ->
            "Successfully wrote to #{display_path}"

          {:error, reason} ->
            Failure.error("writing file #{display_path} failed: #{:file.format_error(reason)}")
        end

      {:error, reason} ->
        Failure.error(
          "creating the parent directory for #{display_path} failed: #{:file.format_error(reason)}"
        )
    end
  end
end
