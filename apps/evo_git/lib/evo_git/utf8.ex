defmodule EvoGit.UTF8 do
  @moduledoc """
  Shared UTF-8 binary repair utility.

  Provides `ensure_utf8/1`, which fixes arbitrary invalid byte sequences via
  `:unicode.characters_to_binary/3`. This is distinct from UTF-8 *boundary-safe
  truncation*, which is now handled directly by the Elixir stdlib
  `String.byte_slice/3` function (available since Elixir 1.17).

  Invalid UTF-8 in tool output can crash downstream `Jason.encode!` calls
  (e.g. `invalid byte 0xE2`), throwing the LLM request pipeline into an
  infinite retry loop.
  """

  @doc """
  Ensures `result` is valid UTF-8. Repairs or truncates invalid sequences.

  - If `result` is a valid UTF-8 binary, returns `{result, nil}`.
  - If invalid, attempts repair via `:unicode.characters_to_binary/3`.
  - On repair failure (error or incomplete), appends a warning and returns
    `{repaired_result, truncation_info}`.
  - Non-binary results pass through as `{result, nil}`.

  `truncation_info` is `nil` when no repair was needed, or a map:
  `%{reason: :invalid_utf8, original_size: pos_integer, truncated_size: pos_integer}`
  """
  @spec ensure_utf8(binary()) :: {binary(), map() | nil}
  @spec ensure_utf8(term()) :: {term(), nil}
  def ensure_utf8(result) when is_binary(result) do
    if String.valid?(result) do
      {result, nil}
    else
      original_size = byte_size(result)

      case :unicode.characters_to_binary(result, :utf8, :utf8) do
        {:error, valid, _} ->
          warning = "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

          {valid <> warning,
           %{
             reason: :invalid_utf8,
             original_size: original_size,
             truncated_size: byte_size(valid) + byte_size(warning)
           }}

        {:incomplete, valid, _} ->
          warning = "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

          {valid <> warning,
           %{
             reason: :invalid_utf8,
             original_size: original_size,
             truncated_size: byte_size(valid) + byte_size(warning)
           }}

        valid when is_binary(valid) ->
          {valid, nil}
      end
    end
  end

  def ensure_utf8(result) when not is_binary(result), do: {result, nil}
end
