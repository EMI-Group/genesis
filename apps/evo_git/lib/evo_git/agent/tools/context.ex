defmodule EvoGit.Agent.Tools.Context do
  @moduledoc """
  Tools for reading and writing directory CONTEXT.md files.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for reading directory context.
  """
  def read_schema do
    ReqLLM.tool(
      name: "context_read",
      description:
        "Reads a CONTEXT.md file from a directory. CONTEXT.md files are human-readable documentation " <>
          "files that describe a directory's purpose and structure. They typically contain: " <>
          "1) Intent - what the directory is for and its role in the codebase, " <>
          "2) API Surface - what modules/functions the directory exports or provides, " <>
          "3) Constraints - rules or guidelines for code within this directory. " <>
          "Use this to read the context to understand the semantic meaning and expectations for a directory",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory to read CONTEXT.md from (e.g., '.', 'lib', 'src/components')"
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
      name: "context_write",
      description:
        "Creates or updates a CONTEXT.md file for a directory. CONTEXT.md is a human-readable documentation file " <>
          "that describes a directory's purpose and structure to help future developers (and AI) understand the codebase. " <>
          "The context should be simple, concise, and clear. It typically contains: " <>
          "1) Intent - what the directory is for and its role in the codebase, " <>
          "2) API Surface - what modules/functions the directory exports or provides, " <>
          "3) Constraints - rules or guidelines for code within this directory. " <>
          "Use this to document a directory after analyzing its contents or establishing its design, or update existing context. " <>
          "By default, the tool will create a git commit for the new or updated CONTEXT.md file (only this file), " <>
          "and you should consider committing it as an important part of your workflow to ensure the context is preserved in the repository history.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory where CONTEXT.md should be created/updated (e.g., '.', 'lib', 'src/components')"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "The full markdown content for the CONTEXT.md file. Should include sections for Intent, API Surface, and Constraints."
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create a git commit after writing the CONTEXT.md file. Defaults to true.",
            "default" => true
          }
        },
        "required" => ["dir_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the context_read tool.
  """
  def execute_read(args, repo_path, _repo_root) do
    case Shared.fetch_string_arg(args, "dir_path") do
      {:ok, dir_path} ->
        full_dir = Shared.expand_path(dir_path, repo_path)
        do_context_read(full_dir, dir_path)

      {:error, message} ->
        message
    end
  end

  defp do_context_read(full_dir, dir_path) do
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
  Executes the context_write tool.
  """
  def execute_write(args, repo_path, repo_root) do
    with {:ok, dir_path} <- Shared.fetch_string_arg(args, "dir_path"),
         {:ok, content} <- Shared.fetch_string_arg(args, "content"),
         {:ok, commit} <- validate_commit(Map.get(args, "commit", true)),
         full_dir = Shared.expand_path(dir_path, repo_path) do
      do_context_write(full_dir, dir_path, content, commit, repo_path, repo_root)
    end
  end

  defp validate_commit(value) when is_boolean(value), do: {:ok, value}

  defp validate_commit(value),
    do: {:error, "Argument 'commit' must be a boolean, got: #{inspect(value)}"}

  defp do_context_write(full_dir, dir_path, content, commit, repo_path, repo_root) do
    case File.mkdir_p(full_dir) do
      :ok ->
        cond do
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
                    elem(
                      System.cmd("systemd-run", systemd_commit_args, stderr_to_stdout: true),
                      0
                    )

                  result_msg <>
                    "\n\nCommitted:\n#{add_output}#{commit_output}"
                else
                  result_msg
                end

              {:error, reason} ->
                "Error writing CONTEXT.md: #{:file.format_error(reason)}"
            end
        end

      {:error, reason} ->
        "Error creating directory '#{dir_path}': #{:file.format_error(reason)}"
    end
  end
end
