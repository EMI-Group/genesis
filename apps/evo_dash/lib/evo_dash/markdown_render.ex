defmodule EvoDash.MarkdownRender do
  @moduledoc """
  Markdown rendering using MDEx for agent summary output.

  Uses the non-crashing `MDEx.to_html/1` variant. If rendering fails for any
  reason, the function falls back to HTML-escaped text so the caller always
  receives safe HTML (never a crash, never raw/unescaped markdown).
  """

  require Logger

  @md_extensions [
    table: true,
    strikethrough: true,
    autolink: true,
    tasklist: true,
    superscript: true,
    shortcodes: true
  ]

  @doc """
  Renders markdown text to HTML.

  Returns an empty string for `nil` input. For binary input, uses `MDEx.to_html/1`
  (the non-crashing variant). On success returns the rendered HTML; on failure,
  logs a warning and falls back to HTML-escaped text so the result is always safe.

  Raw HTML inside the markdown is escaped (MDEx's default — `unsafe_` is NOT
  enabled): the summary is LLM-generated content, and rendering raw HTML would
  be a stored-XSS vector (a prompt-injected repo could make the agent emit
  markup that executes in the reviewer's browser).
  """
  def render(nil), do: ""

  def render(text) when is_binary(text) do
    MDEx.new(markdown: text, extension: @md_extensions)
    |> MDEx.to_html()
    |> case do
      {:ok, html} ->
        html

      {:error, reason} ->
        Logger.warning("MarkdownRender failed: #{inspect(reason)}")
        # Fallback: return escaped text so the caller always gets safe HTML.
        Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
    end
  end
end
