defmodule EvoGit.Agent.Tools.Context do
  @moduledoc """
  Tools for reading and writing directory CONTEXT.md files.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for reading directory context.
  """
  def read_schema do
    ReqLLM.tool(
      name: "read_context",
      description:
        "Use the read_context tool to read the CONTEXT.md of one directory. " <>
          "Read it before delegating work into a child directory. " <>
          "Prefer spawning a subagent at the target path over reading it yourself — the subagent inherits that CONTEXT.md.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The path of the directory to read CONTEXT.md from, relative to the repo root (e.g. './', './lib')."
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
        "Use the write_context tool to create or replace a directory's CONTEXT.md. " <>
          "Describe the current state — what the directory is for, what it exposes, and the rules for code in it — never a changelog. " <>
          "Write one sentence per line so git diffs stay granular. " <>
          "The directory must stay inside the agent's assigned node.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The path of the directory whose CONTEXT.md is created or replaced, relative to the repo root (e.g. './lib')."
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "The full markdown content: Intent (purpose), API Surface, Constraints, and a Routing Table of child subdirectories. One sentence per line."
          },
          "commit" => %{
            "type" => "boolean",
            "description" => "Whether to commit only this CONTEXT.md file. Default: true.",
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
        "Use the edit_context tool to change part of a directory's CONTEXT.md by exact string replacement. " <>
          "Delete stale text instead of annotating it — CONTEXT.md describes the current state, not its history. " <>
          "Write one sentence per line so git diffs stay granular. " <>
          "The edit fails when old_string is not unique; add surrounding context or set replace_all.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The path of the directory holding the CONTEXT.md to edit, relative to the repo root (e.g. './lib')."
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
            "description" => "Whether to replace every occurrence of old_string. Default: false.",
            "default" => false
          },
          "commit" => %{
            "type" => "boolean",
            "description" => "Whether to commit only this CONTEXT.md file. Default: true.",
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
        Failure.error(message)
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
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)),
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
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp do_context_read(full_dir, dir_path) do
    cond do
      not File.exists?(full_dir) ->
        missing_dir_error(dir_path)

      not File.dir?(full_dir) ->
        not_a_dir_error(dir_path)

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        case File.read(context_path) do
          {:ok, content} ->
            content

          {:error, :enoent} ->
            Failure.error("No CONTEXT.md found in directory '#{dir_path}'")

          {:error, reason} ->
            Failure.error("reading CONTEXT.md failed: #{:file.format_error(reason)}")
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
        missing_dir_error(dir_path)

      not File.dir?(full_dir) ->
        not_a_dir_error(dir_path)

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        if not File.exists?(context_path) do
          Failure.error("No CONTEXT.md found in directory '#{dir_path}'")
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
            maybe_commit_context(result, dir_path, commit, repo_path, repo_root)
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
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)),
         full_dir = Shared.expand_path(dir_path, repo_path) do
      do_context_write(full_dir, dir_path, content, commit, repo_path, repo_root)
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp do_context_write(full_dir, dir_path, content, commit, repo_path, repo_root) do
    case File.mkdir_p(full_dir) do
      :ok ->
        cond do
          not File.dir?(full_dir) ->
            not_a_dir_error(dir_path)

          true ->
            context_path = Path.join(full_dir, "CONTEXT.md")

            case File.write(context_path, content) do
              :ok ->
                result_msg = "Successfully updated CONTEXT.md for directory '#{dir_path}'"
                maybe_commit_context(result_msg, dir_path, commit, repo_path, repo_root)

              {:error, reason} ->
                Failure.error("writing CONTEXT.md failed: #{:file.format_error(reason)}")
            end
        end

      {:error, reason} ->
        Failure.error("creating directory '#{dir_path}' failed: #{:file.format_error(reason)}")
    end
  end

  defp missing_dir_error(dir_path) do
    Failure.error("directory '#{dir_path}' does not exist")
  end

  defp not_a_dir_error(dir_path) do
    Failure.error("'#{dir_path}' is a file, not a directory. CONTEXT.md is only for directories.")
  end

  # Optionally stages and commits the CONTEXT.md for the given directory.
  # Shared by write_context and edit_context. When `commit` is false (or the
  # file was not modified), returns `result_msg` unchanged. The actual staging +
  # `git commit -F <tmpfile>` work (incl. the co-author trailer) lives in the
  # single shared helper `Shared.commit_files/4`.
  defp maybe_commit_context(result_msg, _dir_path, false, _repo_path, _repo_root), do: result_msg

  defp maybe_commit_context(result_msg, dir_path, true, repo_path, repo_root) do
    relative_path = Path.join(dir_path, "CONTEXT.md")
    message = "Update CONTEXT.md for #{dir_path}"

    case Shared.commit_files(repo_path, repo_root, [relative_path], message) do
      {:ok, output} -> result_msg <> "\n\nCommitted:\n" <> output
      {:error, reason} -> reason
    end
  end
end
