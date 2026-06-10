defmodule EvoDash.MarkdownRender do
  @moduledoc """
  Markdown rendering using MDEx for agent summary output.
  """

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
  Returns an empty string for nil input, falls back to escaped text on error.
  """
  def render(nil), do: ""

  def render(text) when is_binary(text) do
    MDEx.new(
      markdown: text,
      extension: @md_extensions,
      render: [unsafe_: true]
    )
    |> MDEx.to_html!()
  rescue
    e ->
      require Logger
      Logger.warning("MarkdownRender failed: #{inspect(e)}")
      Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
  end
end
