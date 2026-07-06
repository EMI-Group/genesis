defmodule EvoGit.Agent.Tools.Shared do
  @moduledoc """
  Shared utility functions for tool implementations.
  """

  @curly_quotes ~r/\x{2018}|\x{2019}|\x{201C}|\x{201D}/u

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
  Wraps execution with argument validation. Returns error message on failure.
  """
  def with_valid_args(args, required_keys, fun) when is_list(required_keys) do
    Enum.reduce_while(required_keys, {:ok, %{}}, fn key_spec, {:ok, acc} ->
      {key, type} = parse_key_spec(key_spec)

      result =
        case type do
          :string -> fetch_string_arg(args, key)
          :array -> fetch_array_arg(args, key)
        end

      case result do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fetched} -> fun.(fetched)
      {:error, message} -> message
    end
  end

  defp parse_key_spec(key) when is_atom(key), do: {key, :string}
  defp parse_key_spec({key, :string}), do: {key, :string}
  defp parse_key_spec({key, :array}), do: {key, :array}
  defp parse_key_spec(key) when is_binary(key), do: {key, :string}

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
    Path.expand(file_path, repo_path)
  end

  def expand_path(file_path, repo_path) do
    file_path
    |> to_string()
    |> then(&Path.expand(&1, repo_path))
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
  Returns `{:error, message}` if given an absolute path (starts with "/")
  instead of raising, so callers can surface a graceful error message.
  """
  def normalize_relpath(path) when is_binary(path) do
    if String.starts_with?(path, "/") do
      {:error,
       "Path #{inspect(path)} is absolute. All file paths must be relative to the repository root (e.g. './src/main.ex'), not absolute."}
    else
      path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")
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
        String.starts_with?(child_path, parent_path <> "/")
      end
    end
  end

  @doc """
  Validates that a file path is within the agent's assigned node scope.
  Returns :ok if valid, {:error, message} if the path is outside the scope
  or is an absolute path outside the repository root.
  """
  def validate_file_scope(expanded_path, node_path, repo_path) when is_binary(node_path) do
    # Get the relative path from repo_path.
    # If expanded_path is outside repo_path, Path.relative_to/2 returns it
    # unchanged (still absolute) — detect that and return a clear error.
    relative_path = Path.relative_to(expanded_path, repo_path)

    cond do
      # Path is outside the repository root (Path.relative_to returned it
      # unchanged and it's still absolute).
      is_absolute_outside_repo?(relative_path) ->
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
  end

  def validate_file_scope(_expanded_path, node_path, _repo_path) when not is_binary(node_path) do
    # If no node_path assigned, allow all (backward compatibility)
    :ok
  end

  # Path.relative_to/2 returns the path unchanged when it is not under the
  # base. If the result still starts with "/", the original expanded path was
  # outside the repository root.
  defp is_absolute_outside_repo?(relative_path) when is_binary(relative_path) do
    String.starts_with?(relative_path, "/")
  end

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
end
