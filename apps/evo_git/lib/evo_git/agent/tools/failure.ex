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

  Every function is TOTAL and never raises: binary input is transformed, any
  other input is routed through `to_string/1` (a plain clause, deliberately no
  `try/rescue`).
  """

  @error_prefix "Error: "
  @blank_line "\n\n"

  # Leading markers this helper strips. The `[NOTICE]` / `[WARNING]` forms are
  # matched with or without a trailing space (the space is trimmed after).
  @markers ["⚠️", "💡", "[NOTICE]", "[WARNING]"]

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

  def error(message), do: error(to_string(message))

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

  def notice(guidance), do: notice(to_string(guidance))

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
