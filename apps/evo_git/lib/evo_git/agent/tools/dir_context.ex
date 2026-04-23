defmodule EvoGit.Agent.Tools.DirContext do
  @moduledoc """
  Tools for reading and writing directory CONTEXT.md files.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for reading directory context.
  """
  def read_schema do
    ReqLLM.tool(
      name: "read_dir_context",
      description:
        "Reads the CONTEXT.md file of a directory node. " <>
          "CONTEXT.md defines the directory's semantic contract (Intent, API Surface, Constraints). " <>
          "Returns the content if it exists, or a message indicating no CONTEXT.md was found.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory whose CONTEXT.md should be read (e.g., '.', 'lib', 'src/foo')"
          }
        },
        "required" => ["dir_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Returns the tool schema for writing directory context.
  """
  def write_schema do
    ReqLLM.tool(
      name: "rewrite_dir_context",
      description:
        "Creates or updates the CONTEXT.md file for a directory node. " <>
          "CONTEXT.md defines the directory's semantic contract: its Intent (purpose), " <>
          "API Surface (exports), and Constraints (rules for children). " <>
          "Use this tool whenever you need to establish or revise a directory's context. " <>
          "For file-level context (header/module comments), use normal code editing tools instead.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory whose CONTEXT.md should be updated (e.g., '.', 'lib', 'src/foo')"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "The full markdown content for the CONTEXT.md file. Should include Intent, API Surface, and Constraints sections."
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to commit the CONTEXT.md file after writing. Defaults to true. When true, only the CONTEXT.md file is committed.",
            "default" => true
          }
        },
        "required" => ["dir_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the read_dir_context tool.
  """
  def execute_read(args, repo_path, _repo_root) do
    dir_path = Map.fetch!(args, "dir_path")
    full_dir = Shared.expand_path(dir_path, repo_path)

    cond do
      not File.exists?(full_dir) ->
        "Error: directory '#{dir_path}' does not exist"

      not File.dir?(full_dir) ->
        "Error: '#{dir_path}' is a file, not a directory. CONTEXT.md is only for directories."

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        case File.read(context_path) do
          {:ok, content} -> content
          {:error, :enoent} -> "No CONTEXT.md found in directory '#{dir_path}'"
          {:error, reason} -> "Error reading CONTEXT.md: #{:file.format_error(reason)}"
        end
    end
  end

  @doc """
  Executes the rewrite_dir_context tool.
  """
  def execute_write(args, repo_path, repo_root) do
    dir_path = Map.fetch!(args, "dir_path")
    content = Map.fetch!(args, "content")
    commit = Map.get(args, "commit", true)
    full_dir = Shared.expand_path(dir_path, repo_path)

    cond do
      not File.exists?(full_dir) ->
        "Error: directory '#{dir_path}' does not exist"

      not File.dir?(full_dir) ->
        "Error: '#{dir_path}' is a file, not a directory. CONTEXT.md is only for directories."

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        case File.write(context_path, content) do
          :ok ->
            result_msg = "Successfully updated CONTEXT.md for directory '#{dir_path}'"

            if commit do
              relative_path = Path.join(dir_path, "CONTEXT.md")

              systemd_add_args =
                EvoGit.sandbox_args(repo_path, "git", ["add", relative_path], repo_root)

              systemd_commit_args =
                EvoGit.sandbox_args(
                  repo_path,
                  "git",
                  [
                    "commit",
                    "-m",
                    "Update CONTEXT.md for #{dir_path}"
                  ],
                  repo_root
                )

              add_output =
                elem(System.cmd("systemd-run", systemd_add_args, stderr_to_stdout: true), 0)

              commit_output =
                elem(System.cmd("systemd-run", systemd_commit_args, stderr_to_stdout: true), 0)

              result_msg <>
                "\n\nCommitted:\n#{add_output}#{commit_output}"
            else
              result_msg
            end

          {:error, reason} ->
            "Error writing CONTEXT.md: #{:file.format_error(reason)}"
        end
    end
  end
end
