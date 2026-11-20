defmodule EvoGit.Util.Strings do
  @moduledoc """
  Small pure string helpers shared across the application.

  Every function here is total and side-effect free — no I/O, no processes, no
  ETS and no `try/rescue` — so any layer may call them without pulling in
  Agent, Scheduler or Store code.

  Two truncation semantics live here and they are deliberately NOT
  interchangeable:

    * `truncate/2,3` is CHARACTER based: it keeps a head and appends a marker,
      which is right for model-facing text (objectives, tool snippets).
    * `truncate_bytes/2` is BYTE based: it keeps a head AND a tail around an
      omitted-bytes notice, which is right for raw command output whose tail
      carries the failure.
  """

  @truncation_marker "...[truncated]"

  # Slug rules shared by every derived-id site: non-alphanumeric runs collapse
  # to a single underscore and leading/trailing underscores are dropped.
  @non_alnum_re ~r/[^a-z0-9]+/
  @trim_underscore_re ~r/(?:^_+|_+$)/
  @slug_max_length 40

  # When truncating large output, keep this many bytes total (first half +
  # last half). Matches OutputSanitizer's truncation window.
  @truncate_size 8192

  @doc """
  Returns `true` for `nil` and for a binary that is empty or only whitespace,
  and `false` for every other term.

  The total predicate every caller can use on an optional string without a
  guard: a non-binary value is NOT blank (it may be a meaningful struct or
  number).
  """
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true

  def blank?(value) when is_binary(value) do
    String.trim(value) == ""
  end

  def blank?(_value), do: false

  @doc """
  The negation of `blank?/1`: `true` exactly when the value is a non-`nil`,
  non-whitespace binary.
  """
  @spec present?(term()) :: boolean()
  def present?(value), do: not blank?(value)

  @doc """
  Truncates a binary to at most `max` CHARACTERS, appending the house marker
  `"...[truncated]"` only when the binary is actually longer than `max`.

  A binary at or below the cap is returned unchanged (byte-identical), so a
  caller can apply the same call unconditionally.
  """
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(string, max) when is_binary(string) do
    truncate(string, max, @truncation_marker)
  end

  @doc """
  Same as `truncate/2` with an explicit `marker` after the kept characters.

  `marker` is appended ONLY when truncation happens; it may be `""` for a
  caller that wants a bare cut, and it may be any house style (the marker
  carries no newline of its own).
  """
  @spec truncate(String.t(), non_neg_integer(), String.t()) :: String.t()
  def truncate(string, max, marker) when is_binary(string) and is_binary(marker) do
    if String.length(string) <= max do
      string
    else
      String.slice(string, 0, max) <> marker
    end
  end

  @doc """
  Truncates a binary to fit within `max_bytes`, keeping the FIRST and LAST
  portions so both the beginning and the end of the output remain visible.

  - When `max_bytes` is `nil`, the binary is returned unchanged.
  - When the binary is at most `max_bytes` bytes, it is returned unchanged.
  - When the binary exceeds `max_bytes` but is at most `#{@truncate_size}`
    bytes, it is returned unchanged (truncating so little would only lose
    information).
  - Otherwise the first and last `#{div(@truncate_size, 2)}` bytes are kept
    with a truncation notice in between.

  This is a HEAD+TAIL elision, NOT the character-based head-only cut of
  `truncate/2`: use it for raw command output (`max_bytes` from the
  truncation config), and `truncate/2` for model-facing prose.
  """
  @spec truncate_bytes(binary(), non_neg_integer() | nil) :: binary()
  def truncate_bytes(output, max_bytes) do
    size = byte_size(output)

    cond do
      is_nil(max_bytes) or size <= max_bytes ->
        output

      size <= @truncate_size ->
        output

      true ->
        half_size = div(@truncate_size, 2)
        # UTF-8-safe truncation via String.byte_slice/3: the stdlib works on
        # bytes and then adjusts to eliminate truncated codepoints, avoiding
        # invalid UTF-8 that crashes Jason.encode! downstream.
        first_part = String.byte_slice(output, 0, half_size)
        last_part = String.byte_slice(output, -half_size, half_size)
        omitted = size - @truncate_size
        format_truncation_notice(first_part, last_part, omitted, max_bytes)
    end
  end

  @doc """
  Derives a stable slug from a name: lowercased, non-alphanumeric runs
  collapsed to a single `"_"`, leading/trailing underscores removed, then
  capped at #{@slug_max_length} characters.

  May return `""` (a name with no alphanumeric characters at all) — callers
  that need an id must supply their own fallback.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(string) when is_binary(string) do
    string
    |> String.downcase()
    |> String.replace(@non_alnum_re, "_")
    |> String.replace(@trim_underscore_re, "")
    |> String.slice(0, @slug_max_length)
  end

  @doc """
  Extracts the text of an LLM message `content`, joining the text parts with
  `""` (see `content_text/2` for a different joiner).
  """
  @spec content_text(term()) :: String.t()
  def content_text(content), do: content_text(content, "")

  @doc """
  Extracts the TEXT of an LLM message `content`, joining every text part with
  `joiner`.

  - a binary is returned as-is;
  - a list maps each part matching `%{type: :text, text: text}` (with a binary
    `text`) to its text and every other part to `""`, then joins with
    `joiner`;
  - anything else is `""`.

  The function is total over the message-content domain (binary, parts list,
  `nil`), so a caller inspecting an arbitrary message can never crash on it.
  Callers legitimately join differently: `""` for prompt text, `"\\n"` for
  recency inspection.
  """
  @spec content_text(term(), String.t()) :: String.t()
  def content_text(content, _joiner) when is_binary(content), do: content

  def content_text(content, joiner) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join(joiner)
  end

  def content_text(_content, _joiner), do: ""

  @doc """
  Renders a byte count in binary units.

  `nil`, any non-number and any negative count render as `"unknown"` (a
  negative size is not representable); `0`..`1023` as whole `"B"`; then KiB
  with one decimal and a trailing `".0"` trimmed; MiB and GiB always with one
  decimal.
  """
  @spec human_size(term()) :: String.t()
  def human_size(bytes) when is_number(bytes) and bytes >= 0 and bytes < 1024 do
    "#{round(bytes)} B"
  end

  def human_size(bytes) when is_number(bytes) and bytes >= 0 and bytes < 1_048_576 do
    trim_zero(one_decimal(bytes / 1024)) <> " KiB"
  end

  def human_size(bytes) when is_number(bytes) and bytes >= 0 and bytes < 1_073_741_824 do
    one_decimal(bytes / 1_048_576) <> " MiB"
  end

  def human_size(bytes) when is_number(bytes) and bytes >= 0 do
    one_decimal(bytes / 1_073_741_824) <> " GiB"
  end

  def human_size(_bytes), do: "unknown"

  # Shared truncation message formatting, kept with the head+tail elision so
  # the notice text has exactly one definition.
  defp format_truncation_notice(first_part, last_part, omitted, max_bytes) do
    """
    [WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{@truncate_size} bytes]
    The output was too large. Consider using more specific arguments
    or alternative tools to retrieve only the needed portion of data.
    #{first_part}
    ... [#{omitted} bytes omitted] ...
    #{last_part}
    """
    |> String.trim()
  end

  defp one_decimal(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 1)
  end

  defp trim_zero(string) do
    case String.split(string, ".", parts: 2) do
      [whole, "0"] -> whole
      _other -> string
    end
  end
end
