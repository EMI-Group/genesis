defmodule EvoDashWeb.DiffViewerTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ReviewComponents.DiffViewer

  # These tests cover the bug fix where Lumis's per-line
  # `<div class="l-line" data-line="N">...</div>` wrappers were never stripped,
  # causing extra whitespace and misaligned DOM in the diff viewer.
  #
  # The functions under test are pure helpers:
  #   - strip_lumis_wrappers/1 — strips <pre>, <code>, and <div> wrappers
  #   - split_html_by_newline/1 — splits highlighted HTML by newline while
  #     keeping <span> tags balanced per line.

  describe "strip_lumis_wrappers/1" do
    test "strips <pre>, <code>, and <div> wrappers, leaving spans and text" do
      html =
        ~s(<pre class="lumis"><code class="lang-elixir"><div class="l-line" data-line="1"><span style="color:#keyword">def</span> foo</div>\n<div class="l-line" data-line="2"><span style="color:#string">"bar"</span></div></code></pre>)

      result = DiffViewer.strip_lumis_wrappers(html)

      refute String.contains?(result, "<pre")
      refute String.contains?(result, "<code")
      refute String.contains?(result, "<div")
      refute String.contains?(result, "</div>")
      refute String.contains?(result, "</code>")
      refute String.contains?(result, "</pre>")
      # spans and text content are preserved
      assert String.contains?(result, "<span")
      assert String.contains?(result, "</span>")
      assert String.contains?(result, "def")
      assert String.contains?(result, "bar")
    end

    test "strips opening and closing div tags with attributes" do
      html =
        ~s(<div class="l-line" data-line="42">hello</div>)

      result = DiffViewer.strip_lumis_wrappers(html)

      refute String.contains?(result, "<div")
      refute String.contains?(result, "</div>")
      assert String.contains?(result, "hello")
    end

    test "returns empty string unchanged" do
      assert DiffViewer.strip_lumis_wrappers("") == ""
    end

    test "leaves plain span-only content untouched (no wrappers to strip)" do
      html = ~s(<span style="color:#keyword">def</span>)

      result = DiffViewer.strip_lumis_wrappers(html)

      assert result == html
    end

    test "handles wrappers with no inner divs" do
      html =
        ~s(<pre class="lumis"><code><span style="color:#keyword">def</span> foo</code></pre>)

      result = DiffViewer.strip_lumis_wrappers(html)

      assert result == ~s(<span style="color:#keyword">def</span> foo)
    end
  end

  describe "split_html_by_newline/1" do
    test "splits single line (no newline) returning a one-element list" do
      html = ~s(<span style="color:#keyword">def</span> foo)

      result = DiffViewer.split_html_by_newline(html)

      assert length(result) == 1
      assert List.first(result) == html
    end

    test "splits multiple lines with balanced spans per line" do
      html =
        ~s(<span style="color:#keyword">def</span> foo\n<span style="color:#string">"bar"</span>)

      result = DiffViewer.split_html_by_newline(html)

      assert length(result) == 2
      [line1, line2] = result
      assert line1 == ~s(<span style="color:#keyword">def</span> foo)
      assert line2 == ~s(<span style="color:#string">"bar"</span>)
    end

    test "each split line has balanced spans (open count == close count)" do
      html =
        ~s(<span style="color:#keyword">def</span> foo\n<span style="color:#string">"bar"</span>)

      for line <- DiffViewer.split_html_by_newline(html) do
        assert balanced_spans?(line)
      end
    end

    test "multi-line span (e.g. triple-quoted string) is closed and reopened" do
      # A span whose \n falls *inside* it — simulating a multi-line string.
      html =
        ~s(<span style="color:#string">\"\"\"multi\nline\"\"\"</span>)

      result = DiffViewer.split_html_by_newline(html)

      assert length(result) == 2
      [line1, line2] = result

      # Line 1: the span is opened and then closed at the newline.
      assert String.starts_with?(line1, "<span")
      assert String.ends_with?(line1, "</span>")
      assert balanced_spans?(line1)

      # Line 2: the span is reopened and then closed at end of input.
      assert String.starts_with?(line2, "<span")
      assert String.ends_with?(line2, "</span>")
      assert balanced_spans?(line2)
    end

    test "returns a single empty string for empty input" do
      result = DiffViewer.split_html_by_newline("")

      assert result == [""]
    end

    test "handles nested spans that span newlines" do
      # Simulates nested highlighting (e.g. interpolation inside a string)
      # where the outer span spans two lines.
      html =
        ~s(<span style="color:#string">prefix<span style="color:#interp">\#{</span>\n<span style="color:#interp">}</span>suffix</span>)

      result = DiffViewer.split_html_by_newline(html)

      assert length(result) == 2

      for line <- result do
        assert balanced_spans?(line)
      end
    end
  end

  describe "end-to-end: strip_lumis_wrappers then split_html_by_newline" do
    # Simulated Lumis output exactly as described in the bug report.
    @lumis_output ~s(<pre class="lumis"><code class="lang-elixir"><div class="l-line" data-line="1"><span style="color:#keyword">def</span> foo</div>\n<div class="l-line" data-line="2"><span style="color:#string">"bar"</span></div></code></pre>)

    test "produces clean lines with no div wrappers" do
      lines =
        @lumis_output
        |> DiffViewer.strip_lumis_wrappers()
        |> DiffViewer.split_html_by_newline()

      # No div wrappers should survive in any line.
      for line <- lines do
        refute String.contains?(line, "<div")
        refute String.contains?(line, "</div>")
      end

      assert length(lines) == 2
    end

    test "each resulting line is a valid balanced HTML fragment" do
      lines =
        @lumis_output
        |> DiffViewer.strip_lumis_wrappers()
        |> DiffViewer.split_html_by_newline()

      for line <- lines do
        assert balanced_spans?(line)
      end
    end

    test "content is preserved through the pipeline" do
      lines =
        @lumis_output
        |> DiffViewer.strip_lumis_wrappers()
        |> DiffViewer.split_html_by_newline()

      joined = Enum.join(lines, "\n")
      assert String.contains?(joined, "def")
      assert String.contains?(joined, "foo")
      assert String.contains?(joined, "bar")
    end

    test "multi-line span through the full pipeline stays balanced and div-free" do
      # A triple-quoted-style multi-line string where the highlighting span
      # crosses newlines, wrapped in per-line divs (as Lumis emits).
      lumis_output =
        ~s(<pre class="lumis"><code><div class="l-line" data-line="1"><span style="color:#string">\"\"\"line1</div>\n<div class="l-line" data-line="2">line2\"\"\"</span></div></code></pre>)

      lines =
        lumis_output
        |> DiffViewer.strip_lumis_wrappers()
        |> DiffViewer.split_html_by_newline()

      assert length(lines) == 2

      for line <- lines do
        refute String.contains?(line, "<div")
        assert balanced_spans?(line)
      end
    end
  end

  # Helper: a span-balanced fragment has an equal number of opening and
  # closing <span> tags.
  defp balanced_spans?(html) do
    open = count_occurrences(html, "<span")
    close = count_occurrences(html, "</span>")
    open == close
  end

  defp count_occurrences(html, needle) do
    html
    |> String.split(needle, parts: :infinity)
    |> length()
    |> Kernel.-(1)
  end
end
