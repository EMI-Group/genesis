defmodule EvoDash.MarkdownRenderTest do
  use ExUnit.Case, async: true

  alias EvoDash.MarkdownRender

  describe "render/1" do
    test "renders nil as empty string" do
      assert MarkdownRender.render(nil) == ""
    end

    test "handles empty string" do
      result = MarkdownRender.render("")
      assert is_binary(result)
    end

    test "renders simple markdown to html" do
      html = MarkdownRender.render("# Hello")

      assert html =~ "<h1"
      assert html =~ "Hello"
    end

    test "renders markdown with code block" do
      html = MarkdownRender.render("```elixir\ncode\n```")

      assert html =~ "<code"
    end

    test "renders markdown table" do
      md = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      html = MarkdownRender.render(md)

      assert html =~ "<table"
    end

    test "returns a binary string for normal input" do
      html = MarkdownRender.render("This is **bold** text.")

      assert is_binary(html)
    end
  end
end
