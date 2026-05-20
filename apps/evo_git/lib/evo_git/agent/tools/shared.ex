defmodule EvoGit.Agent.Tools.Shared do
  @moduledoc """
  Shared utility functions for tool implementations.
  """

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

  def fetch_string_arg(_args, _key), do: {:error, "Arguments must be a map/object"}

  @doc """
  Safely fetches a required array argument from the args map.
  Returns {:ok, value} or {:error, message} with a helpful error message.
  """
  def fetch_array_arg(args, key) when is_map(args) do
    case Map.fetch(args, key) do
      {:ok, value} when is_list(value) ->
        validate_string_array(value)

      {:ok, value} ->
        {:error, "Argument '#{key}' must be an array, got: #{inspect(value)}"}

      :error ->
        {:error, "Missing required argument '#{key}'. Please provide a valid array."}
    end
  end

  def fetch_array_arg(_args, _key), do: {:error, "Arguments must be a map/object"}

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

  def validate_string_array(_), do: {:error, "The arguments must be an array"}

  @doc """
  Converts a value to a string binary if possible.
  """
  def to_string_binary(value) when is_binary(value), do: {:ok, value}
  def to_string_binary(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def to_string_binary(value) when is_float(value), do: {:ok, Float.to_string(value)}
  def to_string_binary(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def to_string_binary(_), do: :error

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
    str
    |> String.replace("\u2018", "'")
    |> String.replace("\u2019", "'")
    |> String.replace("\u201C", "\"")
    |> String.replace("\u201D", "\"")
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
  Normalizes a path for comparison by trimming leading/trailing slashes
  and ensuring all paths start with `./` (root is `./`).
  """
  def normalize_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> then(fn
      "" -> "./"
      "." -> "./"
      p -> 
        if String.starts_with?(p, "./") do
          p
        else
          "./" <> p
        end
    end)
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
  Returns :ok if valid, {:error, message} if the path is outside the scope.
  """
  def validate_file_scope(expanded_path, node_path, repo_path) when is_binary(node_path) do
    # Get the relative path from repo_path
    relative_path = Path.relative_to(expanded_path, repo_path)

    # Normalize for comparison
    normalized_target = normalize_path(relative_path)
    normalized_node = normalize_path(node_path)

    if is_child_or_same_node?(normalized_node, normalized_target) do
      :ok
    else
      {:error, format_scope_error(relative_path, node_path)}
    end
  end

  def validate_file_scope(_expanded_path, _node_path, _repo_path) do
    # If no node_path assigned, allow all (backward compatibility)
    :ok
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
end
