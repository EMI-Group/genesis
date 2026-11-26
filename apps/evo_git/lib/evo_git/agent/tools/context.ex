defmodule EvoGit.Agent.Tools.Context do
  @moduledoc """
  Tools for reading and writing directory CONTEXT.md files.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Core.ContextScope

  @scope_description_suffix "Another node's Local text is readable here, but it only reaches agents assigned to that directory."

  @doc """
  Returns the tool schema for reading directory context.
  """
  def read_schema do
    ReqLLM.tool(
      name: "read_context",
      description:
        "Use the read_context tool to read the CONTEXT.md of one directory. " <>
          "Read it before delegating work into a child directory. " <>
          "Prefer spawning a subagent at the target path over reading it yourself — the subagent inherits that CONTEXT.md. " <>
          "A CONTEXT.md may carry ONE divider line, the literal '<!-- genesis:local -->'. " <>
          "Text before it is Shared (this node and all of its descendants); text after it is Local (only agents assigned to that directory). " <>
          @scope_description_suffix,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The path of the directory to read CONTEXT.md from, relative to the repo root (e.g. './', './lib')."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["all", "shared", "local"],
            "description" =>
              "'all' (default) returns the whole file; 'shared' returns only the text before the '<!-- genesis:local -->' divider line; 'local' returns only the text after it.",
            "default" => "all"
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
          "The directory must stay inside the agent's assigned node. " <>
          "Out-of-scope findings belong in your report.",
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
              "The full markdown content: Intent (purpose), API Surface, Constraints, and a Routing Table of child subdirectories. One sentence per line. " <>
                "It is the FULL file and MAY include the divider line '<!-- genesis:local -->': write the Shared part first, then that line on its own line, then the Local part (read only by agents assigned to this directory)."
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
          "The directory must stay inside the agent's assigned node. " <>
          "Out-of-scope findings belong in your report. " <>
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
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["shared", "local", "all"],
            "description" =>
              "Matching and replace_all are restricted to the selected scope. 'shared' (default) matches text before the '<!-- genesis:local -->' divider line; 'local' matches text after it; 'all' edits across the whole file. The divider line and the untouched region survive unchanged.",
            "default" => "shared"
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
        case ContextScope.parse_scope(Map.get(args, "scope", "all")) do
          {:ok, scope} ->
            full_dir = Shared.expand_path(dir_path, repo_path)
            do_context_read(full_dir, dir_path, scope)

          {:error, message} ->
            Failure.error(message)
        end

      {:error, message} ->
        Failure.error(message)
    end
  end

  @doc """
  Executes the edit_context tool.

  `node_path` is the agent's assigned node; `nil` means unrestricted (kept for
  direct callers/tests). The target directory is scope-checked BEFORE any
  existence check, read or string replacement, so an out-of-node path leaves
  both the filesystem and the repository untouched.
  """
  def execute_edit(args, repo_path, repo_root, node_path \\ nil) do
    with {:ok, dir_path} <- Shared.fetch_string_arg(args, "dir_path"),
         {:ok, old_string} <- Shared.fetch_string_arg(args, "old_string"),
         {:ok, new_string} <- Shared.fetch_string_arg(args, "new_string"),
         {:ok, replace_all} <- Shared.validate_replace_all(Map.get(args, "replace_all", false)),
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)),
         {:ok, scope} <- ContextScope.parse_scope(Map.get(args, "scope", "shared")),
         full_dir = Shared.expand_path(dir_path, repo_path),
         :ok <-
           Shared.validate_file_scope(
             full_dir,
             node_path,
             repo_path,
             &Shared.format_context_scope_error/2
           ) do
      do_context_edit(
        full_dir,
        dir_path,
        old_string,
        new_string,
        replace_all,
        commit,
        scope,
        repo_path,
        repo_root
      )
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp do_context_read(full_dir, dir_path, scope) do
    cond do
      not File.exists?(full_dir) ->
        missing_dir_error(dir_path)

      not File.dir?(full_dir) ->
        not_a_dir_error(dir_path)

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        case File.read(context_path) do
          {:ok, content} ->
            scoped_read_content(content, dir_path, scope)

          {:error, :enoent} ->
            Failure.error("No CONTEXT.md found in directory '#{dir_path}'")

          {:error, reason} ->
            Failure.error("reading CONTEXT.md failed: #{:file.format_error(reason)}")
        end
    end
  end

  # `:all` is the RAW file, byte-identical to a pre-scope read (the divider line
  # is content for a whole-file read, so it is NOT stripped here).
  defp scoped_read_content(content, _dir_path, :all), do: content

  defp scoped_read_content(content, _dir_path, :shared),
    do: ContextScope.scope_content(content, :shared)

  defp scoped_read_content(content, dir_path, :local) do
    if ContextScope.has_local?(content) do
      ContextScope.scope_content(content, :local)
    else
      no_local_section_error(dir_path)
    end
  end

  defp do_context_edit(
         full_dir,
         dir_path,
         old_string,
         new_string,
         replace_all,
         commit,
         scope,
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
            scoped_string_replace(
              context_path,
              relative_path,
              dir_path,
              old_string,
              new_string,
              replace_all,
              scope
            )

          if String.starts_with?(result, "Error:") do
            result
          else
            maybe_commit_context(result, dir_path, commit, repo_path, repo_root)
          end
        end
    end
  end

  # Region-restricted string replacement: matching, occurrence counting and
  # `replace_all` all run on the SELECTED scope only, and `ContextScope.splice/3`
  # puts the edited region back so the divider line and the untouched region are
  # preserved byte-for-byte. All divider/split/splice logic lives in
  # `EvoGit.Core.ContextScope` — never re-implemented here.
  defp scoped_string_replace(
         context_path,
         relative_path,
         dir_path,
         old_string,
         new_string,
         replace_all,
         scope
       ) do
    case File.read(context_path) do
      {:ok, content} ->
        if scope == :local and not ContextScope.has_local?(content) do
          no_local_section_error(dir_path)
        else
          region = ContextScope.scope_content(content, scope)

          replace_in_region(
            content,
            region,
            context_path,
            relative_path,
            old_string,
            new_string,
            replace_all,
            scope
          )
        end

      {:error, reason} ->
        Failure.error("failed to read #{relative_path}: #{:file.format_error(reason)}")
    end
  end

  defp replace_in_region(
         content,
         region,
         context_path,
         relative_path,
         old_string,
         new_string,
         replace_all,
         scope
       ) do
    case Shared.find_actual_string(region, old_string) do
      nil ->
        Failure.error("old_string not found in file #{relative_path}")

      actual_old ->
        count = Shared.count_occurrences(region, actual_old)

        if count > 1 and not replace_all do
          Failure.error(
            "Found #{count} matches of old_string in file. Set replace_all=true or provide more context."
          )
        else
          new_region = Shared.apply_string_edit(region, actual_old, new_string, replace_all)
          write_spliced(context_path, relative_path, content, scope, new_region, replace_all)
        end
    end
  end

  defp write_spliced(context_path, relative_path, content, scope, new_region, replace_all) do
    case File.write(context_path, ContextScope.splice(content, scope, new_region)) do
      :ok ->
        if replace_all do
          "The file #{relative_path} has been updated. All occurrences were successfully replaced."
        else
          "The file #{relative_path} has been updated successfully."
        end

      {:error, reason} ->
        Failure.error("failed to write #{relative_path}: #{:file.format_error(reason)}")
    end
  end

  @doc """
  Executes the write_context tool.

  `node_path` is the agent's assigned node; `nil` means unrestricted (kept for
  direct callers/tests). The target directory is scope-checked BEFORE
  `File.mkdir_p`, so an out-of-node path creates nothing and commits nothing.
  """
  def execute_write(args, repo_path, repo_root, node_path \\ nil) do
    with {:ok, dir_path} <- Shared.fetch_string_arg(args, "dir_path"),
         {:ok, content} <- Shared.fetch_string_arg(args, "content"),
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)),
         full_dir = Shared.expand_path(dir_path, repo_path),
         :ok <-
           Shared.validate_file_scope(
             full_dir,
             node_path,
             repo_path,
             &Shared.format_context_scope_error/2
           ) do
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

  # Shared by read_context (`scope: "local"`) and edit_context (`scope: "local"`):
  # a Local-only operation needs the divider line to know where Local text starts.
  defp no_local_section_error(dir_path) do
    Failure.error(
      "CONTEXT.md in directory '#{dir_path}' has no Local section. " <>
        "Add a '#{ContextScope.marker()}' line on its own line to separate Shared text (before it) from Local text (after it)."
    )
  end

  # Optionally stages and commits the CONTEXT.md for the given directory.
  # Shared by write_context and edit_context. When `commit` is false (or the
  # file was not modified), returns `result_msg` unchanged. The actual staging +
  # `git commit -F <tmpfile>` work (incl. the co-author trailer) lives in the
  # single shared helper `Shared.commit_files/4`.
  #
  # `amend: true` opts into squashing: consecutive CONTEXT.md edits amend the
  # previous auto context commit instead of stacking one-file commits (`Shared`
  # decides — HEAD must be this tool's own commit touching only CONTEXT.md files
  # and private to the current branch, else it falls back to a new commit).
  # `amend_message_fun` owns the message spelling: the subject always stays
  # `"Update CONTEXT.md for <dir>"`, plus a file list once several CONTEXT.md
  # files end up in the same amended commit.
  defp maybe_commit_context(result_msg, _dir_path, false, _repo_path, _repo_root), do: result_msg

  defp maybe_commit_context(result_msg, dir_path, true, repo_path, repo_root) do
    relative_path = Path.join(dir_path, "CONTEXT.md")
    message = context_commit_message(dir_path)

    options = [amend: true, amend_message_fun: &amend_context_message(message, &1)]

    case Shared.commit_files(repo_path, repo_root, [relative_path], message, options) do
      {:ok, output} -> result_msg <> "\n\nCommitted:\n" <> output
      {:error, reason} -> reason
    end
  end

  defp context_commit_message(dir_path), do: "Update CONTEXT.md for #{dir_path}"

  # A single-file squash keeps the bare subject; several files in one amended
  # commit are listed under it, in the (already sorted/deduped) given order.
  defp amend_context_message(message, [_single]), do: message

  defp amend_context_message(message, paths) do
    message <> "\n\nFiles in this commit:\n" <> Enum.map_join(paths, "\n", &"- #{&1}")
  end
end
