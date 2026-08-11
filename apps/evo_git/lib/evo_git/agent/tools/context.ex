defmodule EvoGit.Agent.Tools.Context do
  @moduledoc """
  Tools for reading and writing directory CONTEXT.md files.
  """

  alias EvoGit.Agent.Tools.Shared

  @co_author_trailer "\n\nCo-Authored-By: Genesis <noreply@evogit.ai>"

  @doc """
  Returns the tool schema for reading directory context.
  """
  def read_schema do
    ReqLLM.tool(
      name: "read_context",
      description:
        "Reads a CONTEXT.md file from a directory. CONTEXT.md files serve two purposes: " <>
          "1) Documentation - describe the directory's purpose (Intent), what it exposes (API Surface), " <>
          "and rules for code within it (Constraints). " <>
          "2) Routing Table - a simple markdown list mapping areas/modules/features to child subdirectories " <>
          "(may also include sibling paths for cross-references like related test directories), " <>
          "so parent agents know where to delegate work. " <>
          "Use this to read the context to understand the semantic meaning and expectations for a directory. " <>
          "IMPORTANT: Prefer spawning a subagent (subagent_manager or subagent_codebase_investigator) at " <>
          "the target path instead of manually calling read_context on it. The subagent automatically " <>
          "inherits that path's CONTEXT.md and can do work or investigation directly — it's far more " <>
          "efficient than reading context yourself and then re-communicating findings. Only use read_context " <>
          "for quick lookups when you need routing information to decide where to delegate.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory to read CONTEXT.md from (e.g., './', './lib', './src/components')"
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
      name: "write_context",
      description:
        "Creates or updates a CONTEXT.md file for a directory. CONTEXT.md serves two purposes: " <>
          "1) Documentation - describe the directory's purpose (Intent), what it exposes (API Surface), " <>
          "and rules for code within it (Constraints). " <>
          "2) Routing Table - a simple markdown list mapping areas/modules/features to child subdirectories " <>
          "(may also include sibling paths for cross-references like related test directories), " <>
          "so parent agents know where to delegate work. " <>
          "The context should be simple, concise, and clear. " <>
          "Use this to document a directory after analyzing its contents or establishing its design, or update existing context. " <>
          "By default, the tool will create a git commit for the new or updated CONTEXT.md file (only this file), " <>
          "and you should consider committing it as an important part of your workflow to ensure the context is preserved in the repository history.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory where CONTEXT.md should be created/updated (e.g., './', './lib', './src/components')"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "The full markdown content for the CONTEXT.md file. Common sections: Intent (purpose), API Surface (what it exposes), Constraints (rules for code), and Routing Table (areas → child subdirectories; may include sibling paths for cross-references). Additional sections may be included as appropriate — Design Decisions (why choices were made), Known Issues (gotchas/problems future agents should know), Notes for Agents (hints to prevent wasted investigation), Dependencies (external system packages, services, tool versions), Test Strategy (how to test, known gaps), See Also (cross-references to related modules), and Status (what's complete vs pending). The goal: capture all knowledge future agents will need to work effectively in this directory."
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
  Returns the tool schema for editing directory context.
  """
  def edit_schema do
    ReqLLM.tool(
      name: "edit_context",
      description:
        "Creates or updates a CONTEXT.md file for a directory via exact string replacement. " <>
          "Similar to edit_file but specifically for CONTEXT.md files. " <>
          "The old_string must match exactly (including whitespace and indentation). " <>
          "The edit will FAIL if old_string is not unique in the file. " <>
          "Either provide a larger string with more surrounding context to make it unique " <>
          "or use replace_all to change every instance of old_string. " <>
          "By default, the tool will create a git commit for the updated CONTEXT.md file.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory containing the CONTEXT.md file (e.g., './', './lib', './src/components')"
          },
          "old_string" => %{
            "type" => "string",
            "description" => "The exact text to find in CONTEXT.md"
          },
          "new_string" => %{
            "type" => "string",
            "description" => "The replacement text"
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace all occurrences of old_string (default: false)",
            "default" => false
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create a git commit after editing the CONTEXT.md file. Defaults to true.",
            "default" => true
          }
        },
        "required" => ["dir_path", "old_string", "new_string"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the read_context tool.
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

  @doc """
  Executes the edit_context tool.
  """
  def execute_edit(args, repo_path, repo_root) do
    with {:ok, dir_path} <- Shared.fetch_string_arg(args, "dir_path"),
         {:ok, old_string} <- Shared.fetch_string_arg(args, "old_string"),
         {:ok, new_string} <- Shared.fetch_string_arg(args, "new_string"),
         {:ok, replace_all} <- Shared.validate_replace_all(Map.get(args, "replace_all", false)),
         {:ok, commit} <- validate_commit(Map.get(args, "commit", true)),
         full_dir = Shared.expand_path(dir_path, repo_path) do
      do_context_edit(
        full_dir,
        dir_path,
        old_string,
        new_string,
        replace_all,
        commit,
        repo_path,
        repo_root
      )
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

  defp do_context_edit(
         full_dir,
         dir_path,
         old_string,
         new_string,
         replace_all,
         commit,
         repo_path,
         repo_root
       ) do
    cond do
      not File.exists?(full_dir) ->
        "Error: directory '#{dir_path}' does not exist"

      not File.dir?(full_dir) ->
        "Error: '#{dir_path}' is a file, not a directory. CONTEXT.md is only for directories."

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        if not File.exists?(context_path) do
          "Error: No CONTEXT.md found in directory '#{dir_path}'"
        else
          relative_path = Path.join(dir_path, "CONTEXT.md")

          result =
            Shared.perform_string_replace(
              context_path,
              relative_path,
              old_string,
              new_string,
              replace_all
            )

          if String.starts_with?(result, "Error:") do
            result
          else
            if commit do
              trailer =
                if EvoGit.Config.resolve([:git, :co_authored_by_enabled]) != false,
                  do: @co_author_trailer,
                  else: ""

              case EvoGit.sandbox_run(repo_path, "git", ["add", relative_path], repo_root) do
                {add_output, 0} ->
                  case commit_with_message_file(
                         repo_path,
                         repo_root,
                         "Update CONTEXT.md for #{dir_path}#{trailer}"
                       ) do
                    {commit_output, 0} ->
                      result <>
                        "\n\nCommitted:\n#{add_output}#{commit_output}"

                    {commit_output, code} ->
                      "Error: git commit failed (exit #{code}):\n#{commit_output}"
                  end

                {add_output, code} ->
                  "Error: git add failed (exit #{code}):\n#{add_output}"
              end
            else
              result
            end
          end
        end
    end
  end

  @doc """
  Executes the write_context tool.
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
                  trailer =
                    if EvoGit.Config.resolve([:git, :co_authored_by_enabled]) != false,
                      do: @co_author_trailer,
                      else: ""

                  relative_path = Path.join(dir_path, "CONTEXT.md")

                  case EvoGit.sandbox_run(repo_path, "git", ["add", relative_path], repo_root) do
                    {add_output, 0} ->
                      case commit_with_message_file(
                             repo_path,
                             repo_root,
                             "Update CONTEXT.md for #{dir_path}#{trailer}"
                           ) do
                        {commit_output, 0} ->
                          result_msg <>
                            "\n\nCommitted:\n#{add_output}#{commit_output}"

                        {commit_output, code} ->
                          "Error: git commit failed (exit #{code}):\n#{commit_output}"
                      end

                    {add_output, code} ->
                      "Error: git add failed (exit #{code}):\n#{add_output}"
                  end
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

  # Runs `git commit` with the message read from a temporary file (`-F`) instead
  # of passing it as a `-m <message>` argv element. Content-bearing git args must
  # never be passed as argv elements: git-for-Windows re-tokenizes elements
  # containing double quotes (the Co-Authored-By trailer contains `<>`), which
  # produced "unknown switch `>'` / "too many arguments" failures under MSYS2.
  # The temp file lives under `EvoGit.Sandbox.resolve_tmpdir/0` (the sandbox-
  # readable temp dir), with backslashes normalized to forward slashes on
  # Windows, and is removed in an `after` block (no rescued errors).
  defp commit_with_message_file(repo_path, repo_root, message) do
    temp_path =
      Path.join(
        EvoGit.Sandbox.resolve_tmpdir(),
        "genesis_ctx_msg_#{System.unique_integer([:positive, :monotonic])}.txt"
      )

    try do
      case File.write(temp_path, message) do
        :ok ->
          normalized =
            if EvoGit.Platform.windows?(),
              do: String.replace(temp_path, "\\", "/"),
              else: temp_path

          EvoGit.sandbox_run(repo_path, "git", ["commit", "-F", normalized], repo_root)

        {:error, reason} ->
          {"Error: could not write temporary commit message file: #{:file.format_error(reason)}",
           1}
      end
    after
      File.rm(temp_path)
    end
  end
end
