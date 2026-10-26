defmodule EvoDash.MarkdownRenderTest do
  use ExUnit.Case, async: true

  alias EvoDash.MarkdownRender

  describe "render/1" do
    test "nil renders as the empty string" do
      assert MarkdownRender.render(nil) == ""
    end

    test "empty and inline input always yields a binary" do
      assert is_binary(MarkdownRender.render(""))
      assert is_binary(MarkdownRender.render("This is **bold** text."))
    end

    test "renders headings, code blocks and tables to html" do
      heading = MarkdownRender.render("# Hello")
      assert heading =~ "<h1"
      assert heading =~ "Hello"

      assert MarkdownRender.render("```elixir\ncode\n```") =~ "<code"

      assert MarkdownRender.render("| A | B |\n|---|---|\n| 1 | 2 |\n") =~ "<table"
    end
  end
end
