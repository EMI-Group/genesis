defmodule EvoGit.Agent.Tools.Shared do
  @moduledoc """
  Shared utility functions for tool implementations.
  """

  @curly_quotes ~r/\x{2018}|\x{2019}|\x{201C}|\x{201D}/u

  alias EvoGit.Platform

  @doc """
  Safely fetches a required string argument from the args map.
  Returns {:ok, value} or {:error, message} with a helpful error message.
  """
  def fetch_string_arg(args, key) when is_map(args) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, value} ->
        case to_string_binary(value) do
          {:ok, binary} -> {:ok, binary}
          :error -> {:error, "Argument '#{key}' must be a string, got: #{inspect(value)}"}
        end

      :error ->
        {:error, "Missing required argument '#{key}'. Please provide a valid value."}
    end
  end

  def fetch_string_arg(args, _key) when not is_map(args),
    do: {:error, "Arguments must be a map/object"}

  @doc """
  Safely fetches a required array argument from the args map.
  Returns {:ok, value} or {:error, message} with a helpful error message.
  """
  def fetch_array_arg(args, key) when is_map(args) do
    case Map.fetch(args, key) do
      {:ok, value} when is_list(value) ->
        validate_string_array(value)

      # Recovery: some LLMs (e.g. DeepSeek) double-encode an array argument as a
      # JSON string like "[\"-n\", \"foo\", \".\"]" instead of a real array. Try
      # to transparently decode it before failing.
      {:ok, value} when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_list(decoded) ->
            validate_string_array(decoded)

          _ ->
            {:error, format_array_arg_error(key, value)}
        end

      {:ok, value} ->
        {:error, "Argument '#{key}' must be an array, got: #{inspect(value)}"}

      :error ->
        {:error, "Missing required argument '#{key}'. Please provide a valid array."}
    end
  end

  def fetch_array_arg(args, _key) when not is_map(args),
    do: {:error, "Arguments must be a map/object"}

  @doc """
  Safely fetches an optional string argument from the args map.
  Returns {:ok, value} or {:ok, default} if not present.
  """
  def fetch_optional_string_arg(args, key, default \\ nil) when is_map(args) do
    if Map.has_key?(args, key) do
      fetch_string_arg(args, key)
    else
      {:ok, default}
    end
  end

  @doc """
  Fetches an optional boolean argument from the args map with a default.

  Returns `{:ok, boolean}` when the value is a boolean (or absent — the default
  is returned). Returns `{:error, message}` when the key is present but not a
  boolean, so the caller can surface a clear error rather than silently coercing.

  Shared by tools that expose a `commit` / `parents` flag (MakeDir, FileCreate,
  Context, etc.) — previously each tool carried a byte-identical private copy.
  """
  def fetch_optional_boolean_arg(args, key, default) when is_map(args) do
    case Map.get(args, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a boolean"}
    end
  end

  @doc """
  Leniently fetches an optional argument and coerces it to a string.

  Returns the value directly when it is already a binary; otherwise coerces
  with `to_string/1`. Used by the search tools where optional params arrive
  from the LLM and a graceful coercion is preferable to a hard error.
  """
  def get_optional_string(args, key, default) do
    case Map.get(args, key, default) do
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end

  @doc """
  Leniently fetches an optional argument and coerces it to an integer.

  Returns the value directly when it is already an integer. A binary value is
  parsed with `Integer.parse/1` (the safe, non-crashing variant) and falls back
  to `default` when it cannot be parsed. Any other type also falls back to
  `default`.
  """
  def get_optional_integer(args, key, default) do
    case Map.get(args, key, default) do
      val when is_integer(val) ->
        val

      val when is_binary(val) ->
        case Integer.parse(val) do
          {int, _} -> int
          :error -> default
        end

      _ ->
        default
    end
  end

  @doc """
  Leniently fetches an optional argument and coerces it to a boolean.

  Returns the value directly when it is already a boolean. A binary value is
  interpreted truthily ("true"/"True"/"TRUE"/"1"). Any other type falls back
  to `default`.
  """
  def get_optional_boolean(args, key, default) do
    case Map.get(args, key, default) do
      val when is_boolean(val) -> val
      val when is_binary(val) -> val in ["true", "True", "TRUE", "1"]
      _ -> default
    end
  end

  @doc """
  Validates and sanitizes an array argument to ensure all elements are binaries.
  Returns {:ok, sanitized_list} or :error with a descriptive message.
  """
  def validate_string_array(array) when is_list(array) do
    Enum.reduce_while(array, {:ok, []}, fn item, {:ok, acc} ->
      case to_string_binary(item) do
        {:ok, binary} -> {:cont, {:ok, [binary | acc]}}
        :error -> {:halt, {:error, "Arguments contains non-string value: #{inspect(item)}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  def validate_string_array(array) when not is_list(array),
    do: {:error, "The arguments must be an array"}

  @doc """
  Converts a value to a string binary if possible.
  """
  def to_string_binary(value) when is_binary(value), do: {:ok, value}
  def to_string_binary(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def to_string_binary(value) when is_float(value), do: {:ok, Float.to_string(value)}
  def to_string_binary(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def to_string_binary(_), do: :error

  defp format_array_arg_error(key, value) do
    "Argument '#{key}' must be an array. " <>
      "It was received as a JSON-encoded string (\"[...]\"), which cannot be used directly. " <>
      "Pass a real JSON array of strings instead, " <>
      "e.g. [\"-n\", \"pattern\", \"path\"], not \"[\\\"-n\\\", \\\"pattern\\\", \\\"path\\\"]\". " <>
      "Received: #{inspect(value)}"
  end

  @doc """
  Expands a file path relative to a repository path.
  """
  def expand_path(file_path, repo_path) when is_binary(file_path) do
    Platform.safe_expand(file_path, repo_path)
  end

  def expand_path(file_path, repo_path) do
    file_path
    |> to_string()
    |> then(&Platform.safe_expand(&1, repo_path))
  end

  @doc """
  Normalizes curly quotes to straight quotes for matching.
  U+2018 ' → ', U+2019 ' → ', U+201C " → ", U+201D " → "
  """
  def normalize_quotes(str) do
    String.replace(str, @curly_quotes, fn
      "\u2018" -> "'"
      "\u2019" -> "'"
      "\u201C" -> "\""
      "\u201D" -> "\""
    end)
  end

  @doc """
  Finds the actual string in file content, handling quote normalization.
  LLMs output straight quotes, but files may contain curly quotes.
  """
  def find_actual_string(file_content, search_string) do
    if String.contains?(file_content, search_string) do
      search_string
    else
      normalized_search = normalize_quotes(search_string)
      normalized_file = normalize_quotes(file_content)

      if String.contains?(normalized_file, normalized_search) do
        case :binary.match(normalized_file, normalized_search) do
          {start_pos, _length} ->
            byte_len = byte_size(search_string)
            binary_part(file_content, start_pos, byte_len)

          :nomatch ->
            nil
        end
      else
        nil
      end
    end
  end

  @doc """
  Counts occurrences of a pattern in content.
  """
  def count_occurrences(content, pattern) do
    content
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  # --- Path Validation for Spatial Contract ---

  @doc """
  Normalizes a relative path for comparison by trimming leading/trailing slashes
  and ensuring all paths start with `./` (root is `./`).

  Returns the normalized path as a string for valid relative paths.
  Returns `{:error, message}` if given an absolute path (Unix: /foo, Windows: C:\\foo)
  instead of raising, so callers can surface a graceful error message.
  """
  def normalize_relpath(path) when is_binary(path) do
    if EvoGit.Platform.absolute_path?(path) do
      {:error,
       "Path #{inspect(path)} is absolute. All file paths must be relative to the repository root (e.g. './src/main.ex'), not absolute."}
    else
      path
      |> Platform.normalize_separators()
      |> Platform.trim_leading_separators()
      |> Platform.trim_trailing_separators()
      |> then(fn
        "" ->
          "./"

        "." ->
          "./"

        p ->
          if String.starts_with?(p, "./") do
            p
          else
            "./" <> p
          end
      end)
    end
  end

  @doc """
  Checks if a child path is within or equal to a parent path.
  Both paths should be normalized before calling.
  """
  def is_child_or_same_node?(parent_path, child_path) do
    # "./" represents root, everything is a child
    if parent_path == "./" do
      true
    else
      if parent_path == child_path do
        true
      else
        EvoGit.Platform.path_under?(child_path, parent_path)
      end
    end
  end

  @doc """
  Validates that a file path is within the agent's assigned node scope.
  Returns :ok if valid, {:error, message} if the path is outside the scope
  or is an absolute path outside the repository root.

  Also rejects (defense-in-depth, behind the dispatch-level gate in
  `EvoGit.Agent.Tools`) any path that resolves to a READ-ONLY foreign repo —
  read-only foreign repos are for investigation only.
  """
  def validate_file_scope(expanded_path, node_path, repo_path) when is_binary(node_path) do
    case read_only_foreign_repo_error(expanded_path) do
      nil ->
        # Get the relative path from repo_path.
        # If expanded_path is outside repo_path, Path.relative_to/2 returns it
        # unchanged (still absolute) — detect that and return a clear error.
        relative_path = Path.relative_to(expanded_path, repo_path)

        cond do
          # Path is outside the repository root (Path.relative_to returned it
          # unchanged and it's still absolute).
          EvoGit.Platform.absolute_path?(relative_path) ->
            {:error, format_outside_repo_error(expanded_path)}

          true ->
            # Normalize for comparison. normalize_relpath may return {:error, _}
            # for any remaining absolute path edge cases — propagate it.
            with normalized_target when is_binary(normalized_target) <-
                   normalize_relpath(relative_path),
                 normalized_node when is_binary(normalized_node) <-
                   normalize_relpath(node_path) do
              if is_child_or_same_node?(normalized_node, normalized_target) do
                :ok
              else
                {:error, format_scope_error(relative_path, node_path)}
              end
            else
              {:error, _message} = error -> error
            end
        end

      message ->
        {:error, message}
    end
  end

  def validate_file_scope(_expanded_path, node_path, _repo_path) when not is_binary(node_path) do
    # If no node_path assigned, allow all (backward compatibility)
    :ok
  end

  # Returns an error message string when `path` resolves to a READ-ONLY foreign
  # repo, or nil otherwise (primary repo, writable foreign repo, or no repo
  # match). Defense-in-depth behind the dispatch-level write gate in
  # `EvoGit.Agent.Tools` — the target of a file write must never live inside a
  # read-only foreign repo (investigation only). Foreign repos take precedence
  # over the primary repo in `resolve_path/2` (paths overlap is unlikely but
  # possible), matching the resolve order used everywhere else.
  defp read_only_foreign_repo_error(path) when is_binary(path) do
    foreign_repos =
      Process.get(:foreign_repos, [])
      |> Enum.map(&EvoGit.Core.ForeignRepo.normalize/1)
      |> Enum.reject(&is_nil/1)

    case EvoGit.Core.ForeignRepo.resolve_path(foreign_repos, path) do
      {:ok, repo_id, _rel} ->
        case Enum.find(foreign_repos, fn repo -> repo.id == repo_id end) do
          %EvoGit.Core.ForeignRepo{writable: false, root: root} ->
            "Path '#{path}' is inside a read-only foreign repository ('#{root}'). " <>
              "Read-only foreign repos are for investigation only — modifications are not permitted."

          _ ->
            nil
        end

      {:error, :not_in_any_repo} ->
        nil
    end
  end

  defp read_only_foreign_repo_error(_path), do: nil

  defp format_outside_repo_error(path) do
    display = if is_binary(path), do: path, else: inspect(path)

    "Path '#{display}' is outside the repository root. " <>
      "All file paths must be relative to the repository root " <>
      "(e.g. './src/main.ex'), not absolute."
  end

  defp format_scope_error(target_path, node_path) do
    """
    Cannot modify '#{target_path}'. You are assigned to work within '#{node_path}' and this path is outside your scope.

    You can still complete work within your assigned node, and remember you don't need to complete the entire task, do what you can and let the user guide the next steps.
    Once finished, report back to the user explaining:
    1. What you have accomplished within '#{node_path}'
    2. What work remains at '#{target_path}' that requires attention at a higher level or different scope

    This allows the user to make an informed decision about how to proceed.
    """
    |> String.trim()
  end

  # --- Edit Utilities ---

  @doc """
  Validates the replace_all argument.
  Returns {:ok, boolean} or {:error, message}.
  """
  def validate_replace_all(value) when is_boolean(value), do: {:ok, value}

  def validate_replace_all(value),
    do: {:error, "Argument 'replace_all' must be a boolean, got: #{inspect(value)}"}

  @doc """
  Applies a string replacement edit to file content.
  Trims trailing whitespace from new_string before applying.
  If replace_all is true, replaces all occurrences; otherwise just the first.
  """
  def apply_string_edit(content, old_string, new_string, replace_all) do
    trimmed_new = String.trim_trailing(new_string)

    if replace_all do
      String.replace(content, old_string, trimmed_new)
    else
      String.replace(content, old_string, trimmed_new, global: false)
    end
  end

  # --- Common File/Directory Operations ---

  @doc """
  Creates a directory, optionally with parents.
  """
  def mkdir_if_needed(path, true), do: File.mkdir_p(path)
  def mkdir_if_needed(path, false), do: File.mkdir(path)

  @doc """
  Stages and commits the given files with a message.
  Handles all git add/commit error cases uniformly.
  """
  def do_git_commit(repo_path, files_to_add, commit_message) do
    if files_to_add == [] do
      {:ok, "No files to commit"}
    else
      case EvoGit.Adapters.Git.run(["add" | files_to_add], repo_path) do
        {:ok, _output} ->
          case EvoGit.Adapters.Git.commit(repo_path, commit_message) do
            {:ok, _} -> {:ok, "Commit successful"}
            {:error, _} = error -> error
          end

        {:error, {:conflict, output}} ->
          {:error, "git add conflict: #{output}"}

        {:error, {_, _}} = error ->
          {:error, "git add failed: #{inspect(error)}"}
      end
    end
  end

  @doc """
  Performs a string replacement edit on a file.
  Reads the file, finds the old_string (with quote normalization),
  validates uniqueness unless replace_all is true, applies the edit, and writes the result.
  Returns a result string (success message or error message).
  """
  def perform_string_replace(file_path, display_path, old_string, new_string, replace_all) do
    case File.read(file_path) do
      {:ok, content} ->
        actual_old = find_actual_string(content, old_string)

        if is_nil(actual_old) do
          "Error: old_string not found in file #{display_path}"
        else
          match_count = count_occurrences(content, actual_old)

          if match_count > 1 and not replace_all do
            "Error: Found #{match_count} matches of old_string in file. Set replace_all=true or provide more context."
          else
            updated_content = apply_string_edit(content, actual_old, new_string, replace_all)

            case File.write(file_path, updated_content) do
              :ok ->
                if replace_all do
                  "The file #{display_path} has been updated. All occurrences were successfully replaced."
                else
                  "The file #{display_path} has been updated successfully."
                end

              {:error, reason} ->
                "Error writing file #{display_path}: #{:file.format_error(reason)}"
            end
          end
        end

      {:error, reason} ->
        "Error reading file #{display_path}: #{:file.format_error(reason)}"
    end
  end

  # --- Display Formatting ---

  @doc """
  Formats a datetime value for display in tool output.

  `nil` renders as "unknown"; `%DateTime{}` and `%NaiveDateTime{}` render via
  their canonical ISO-8601 forms; any other value is stringified. Shared by
  the task-control command handlers (GetTask, ListTasks, ListRecentProjects,
  SystemInfo) — previously each carried a private copy.
  """
  def format_datetime(nil), do: "unknown"
  def format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def format_datetime(other), do: to_string(other)

  @doc """
  Truncates a string to `max` characters, appending the "...[truncated]"
  marker when it exceeds the cap.
  """
  def truncate(string, max) when is_binary(string) do
    if String.length(string) <= max do
      string
    else
      String.slice(string, 0, max) <> "...[truncated]"
    end
  end

  @doc """
  Builds a single-line objective snippet from a task's opts, truncated to
  `max` characters.

  Missing/blank objectives render as "(no objective)". Shared by GetTask and
  ListTasks, which differ only in the snippet length cap.
  """
  def objective_snippet(opts, max) do
    case objective_from_opts(opts) do
      nil ->
        "(no objective)"

      obj when is_binary(obj) ->
        case String.trim(obj) do
          "" -> "(no objective)"
          trimmed -> truncate(trimmed, max)
        end

      obj ->
        truncate(inspect(obj), max)
    end
  end

  # `opts` may be a keyword list (%TaskInfo{}) or a STRING-keyed map (store
  # summary rows). Checks both key shapes defensively.
  defp objective_from_opts(opts) when is_map(opts),
    do: Map.get(opts, "objective") || Map.get(opts, :objective)

  defp objective_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :objective)
  defp objective_from_opts(_opts), do: nil

  @doc """
  Returns the standard `max_bytes` tool-output truncation description shared
  by every tool schema that exposes a `max_bytes` parameter.
  """
  def tool_output_limit_description do
    "Maximum output size in bytes before truncation. " <>
      "Default: 16384 (16KB). Increase up to 131072 (128KB) if you need more output."
  end

  # --- Task-Control Error Formatting ---

  @doc """
  Formats a task-control error reason for display.

  The `:not_running` message differs per command (graceful cancel vs
  force-kill), so each handler passes its own literal. `:not_found` and
  `{:registry_unavailable, reason}` render identically across handlers;
  unknown reasons fall back to `inspect/1` so the formatter never crashes.
  """
  def describe_error(:not_found, _not_running_msg), do: "task not found"

  def describe_error(:not_running, not_running_msg), do: not_running_msg

  def describe_error({:registry_unavailable, reason}, _not_running_msg),
    do: "task registry unavailable: #{inspect(reason)}"

  def describe_error(other, _not_running_msg), do: inspect(other)
end
