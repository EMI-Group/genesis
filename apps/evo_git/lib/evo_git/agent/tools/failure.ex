defmodule EvoGit.Agent.Tools.Failure do
  @moduledoc """
  The shared tool-message SHAPE helper: one place that renders tool FAILURES and
  trailing GUIDANCE blocks in the conventions models are trained on.

  ## The convention

  Models key "is this a failure" off the `Error:` prefix (both providers'
  training — see `docs/harness-alignment.md` §1.3). Every failure text this
  helper renders therefore

    * STARTS with the literal `"Error: "`,
    * is idempotent — a message that already starts with `"Error: "` is returned
      unchanged,
    * contains NO emoji / marker prefix — a leading `⚠️`, `💡`, `[NOTICE]` or
      `[WARNING]` marker is stripped (these markers read as prose, not as
      failures, and they are no longer used to signal an error).

  Guidance meant to accompany a SUCCESSFUL payload stays a TRAILING block after a
  blank line (`notice/1`), and guidance accompanying a failure sits after the
  error line, also blank-line separated (`error/2`).

  Every function is TOTAL and never raises: binary input goes straight through
  the text transformation, while any other input is FIRST rendered to a string
  by `format_reason/1` — binaries verbatim, a real exception (any struct
  implementing the `Exception` behaviour) via `Exception.message/1`, everything
  else (tuples, keywords, atoms, numbers, plain maps, non-exception structs) via
  `inspect/1` — and then transformed the same way. A struct reason such as a
  `%YamlElixir.ParsingError{}` therefore can never raise out of this module
  (deliberately no `try/rescue`).
  """

  @error_prefix "Error: "
  @blank_line "\n\n"

  # Leading markers this helper strips. The `[NOTICE]` / `[WARNING]` forms are
  # matched with or without a trailing space (the space is trimmed after).
  @markers ["⚠️", "💡", "[NOTICE]", "[WARNING]"]

  @doc """
  Renders an arbitrary REASON term as display text — the total formatter every
  error path shares.

    * a binary passes through VERBATIM (already-human prose is never quoted);
    * an exception struct (`is_exception/1`) renders its
      `Exception.message/1`, so e.g. a `%YamlElixir.ParsingError{}` reason reads
      as the parser's own message instead of crashing on `String.Chars`;
    * everything else — tuples, keywords, atoms, numbers, plain maps, a
      non-exception struct — goes through `inspect/1`.

  TOTAL: never raises, deliberately no `try/rescue`.
  """
  @spec format_reason(term()) :: String.t()
  def format_reason(reason) when is_binary(reason), do: reason

  def format_reason(%_struct{} = reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end

  def format_reason(reason), do: inspect(reason)

  @doc """
  Renders a failure message: `"Error: <message>"`.

  Idempotent (an input already starting with `"Error: "` — or with the
  unspaced `"Error:"` — comes back unchanged apart from the canonical single
  space), leading markers stripped, and an empty message falls back to
  `"Error: the tool call failed."` so the result always leads with the literal
  prefix.
  """
  @spec error(term()) :: String.t()
  def error(message) when is_binary(message) do
    text = message |> strip_leading_markers() |> String.trim_leading()

    cond do
      String.starts_with?(text, @error_prefix) ->
        text

      String.starts_with?(text, "Error:") ->
        @error_prefix <>
          (text |> String.replace_prefix("Error:", "") |> String.trim_leading())

      text == "" ->
        @error_prefix <> "the tool call failed."

      true ->
        @error_prefix <> text
    end
  end

  def error(message), do: error(format_reason(message))

  @doc """
  Renders a failure message plus a blank-line-separated trailing guidance block:
  `error/1` <> `notice/1` (which itself carries the blank line). A blank/empty
  guidance renders just the error line.
  """
  @spec error(term(), term()) :: String.t()
  def error(message, guidance), do: error(message) <> notice(guidance)

  @doc """
  Renders a trailing guidance block for a SUCCESSFUL payload: a blank line
  followed by the guidance text, with any leading `⚠️` / `💡` / `[NOTICE]` /
  `[WARNING]` marker stripped.

  Returns `""` for empty guidance, so a caller can concatenate it unconditionally.
  """
  @spec notice(term()) :: String.t()
  def notice(guidance) when is_binary(guidance) do
    case guidance |> strip_leading_markers() do
      "" -> ""
      text -> @blank_line <> text
    end
  end

  def notice(guidance), do: notice(format_reason(guidance))

  # Strips leading markers, repeatedly (an input may carry several, in any
  # order) together with the whitespace/newlines they were padded with. Only
  # LEADING markers are stripped — a marker inside the message body is left
  # alone.
  defp strip_leading_markers(text) do
    stripped = text |> String.trim_leading() |> strip_one_marker()
    if stripped == text, do: stripped, else: strip_leading_markers(stripped)
  end

  defp strip_one_marker(text) do
    Enum.reduce(@markers, text, fn marker, acc ->
      if String.starts_with?(acc, marker) do
        acc |> String.replace_prefix(marker, "") |> String.trim_leading()
      else
        acc
      end
    end)
  end
end
