defmodule EvoGit.UTF8 do
  @moduledoc """
  Shared UTF-8-safe binary utilities.

  Centralizes UTF-8 boundary-aware truncation and repair logic so that multiple
  call sites (context building, tool-output sanitization, sandbox output
  truncation) never split a multi-byte UTF-8 codepoint. Splitting a codepoint
  produces invalid UTF-8 that crashes downstream `Jason.encode!` calls (e.g.
  `invalid byte 0xE2`), which can throw the LLM request pipeline into an
  infinite retry loop.

  ## Extracted from

  The implementations here were originally private functions in
  `EvoGit.Agent.OutputSanitizer` (`safe_binary_part/3`,
  `safe_binary_part_from_end/2`, and `ensure_utf8/1`). They are extracted to a
  shared module so the same bug class cannot recur in other truncation paths.
  """

  @doc """
  Extracts `len` bytes starting at `start` from `binary`, backing up 1-3 bytes
  from the end if needed so the result does not split a multi-byte UTF-8
  codepoint.

  If `start + len >= byte_size(binary)`, takes whatever bytes are available
  (still ensuring a valid UTF-8 boundary).
  """
  @spec safe_binary_part(binary(), non_neg_integer(), non_neg_integer()) :: binary()
  def safe_binary_part(binary, start, len) do
    if start + len >= byte_size(binary) do
      # Requested range exceeds the binary; just take what's available
      part = binary_part(binary, start, byte_size(binary) - start)
      if String.valid?(part), do: part, else: adjust_boundary(binary, start, byte_size(binary) - start)
    else
      part = binary_part(binary, start, len)
      if String.valid?(part), do: part, else: adjust_boundary(binary, start, len)
    end
  end

  @doc """
  Extracts the last `len` bytes from `binary`, trimming 1-3 bytes from the
  START if needed to produce valid UTF-8 (so the leading partial codepoint is
  dropped rather than splitting a trailing one).
  """
  @spec safe_binary_part_from_end(binary(), non_neg_integer()) :: binary()
  def safe_binary_part_from_end(binary, len) do
    total = byte_size(binary)
    start = total - len

    start = max(start, 0)
    available = total - start

    part = binary_part(binary, start, available)
    if String.valid?(part), do: part, else: adjust_boundary_from_end(binary, start, available)
  end

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
           %{reason: :invalid_utf8, original_size: original_size, truncated_size: byte_size(valid) + byte_size(warning)}}

        {:incomplete, valid, _} ->
          warning = "\n[WARNING: Output truncated due to invalid UTF-8 binary data]"

          {valid <> warning,
           %{reason: :invalid_utf8, original_size: original_size, truncated_size: byte_size(valid) + byte_size(warning)}}

        valid when is_binary(valid) ->
          {valid, nil}
      end
    end
  end

  def ensure_utf8(result) when not is_binary(result), do: {result, nil}

  # --- Private Helpers ---

  # Backs up 1-3 bytes from the end until the result is valid UTF-8.
  defp adjust_boundary(binary, start, len) when len > 0 do
    adjusted_len = len - 1
    part = binary_part(binary, start, adjusted_len)

    if String.valid?(part) do
      part
    else
      adjust_boundary(binary, start, adjusted_len)
    end
  end

  defp adjust_boundary(_binary, _start, 0), do: ""

  # Trims 1-3 bytes from the start until the result is valid UTF-8.
  defp adjust_boundary_from_end(binary, start, len) when len > 0 do
    adjusted_start = start + 1
    adjusted_len = len - 1
    part = binary_part(binary, adjusted_start, adjusted_len)

    if String.valid?(part) do
      part
    else
      adjust_boundary_from_end(binary, adjusted_start, adjusted_len)
    end
  end

  defp adjust_boundary_from_end(_binary, _start, 0), do: ""
end
