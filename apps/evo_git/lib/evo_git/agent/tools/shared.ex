defmodule EvoGit.Agent.Tools.Shared do
  @moduledoc """
  Shared utility functions for tool implementations.
  """

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
end
