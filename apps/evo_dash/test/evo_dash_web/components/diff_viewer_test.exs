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

  # ---------------------------------------------------------------------------
  # Hunk header parsing
  # ---------------------------------------------------------------------------

  describe "parse_hunk_header/1" do
    test "extracts old_start and new_start with counts" do
      assert DiffViewer.parse_hunk_header("@@ -10,7 +12,9 @@ def foo") == {10, 12}
    end

    test "extracts old_start and new_start without counts" do
      assert DiffViewer.parse_hunk_header("@@ -5 +7 @@") == {5, 7}
    end

    test "handles hunk header for a new file (old starts at 0)" do
      assert DiffViewer.parse_hunk_header("@@ -0,0 +1,5 @@") == {0, 1}
    end

    test "handles hunk header for a deleted file (new starts at 0)" do
      assert DiffViewer.parse_hunk_header("@@ -1,5 +0,0 @@") == {1, 0}
    end

    test "returns {0, 0} for malformed header" do
      assert DiffViewer.parse_hunk_header("not a header") == {0, 0}
    end
  end

  # ---------------------------------------------------------------------------
  # File-level highlighting
  #
  # These tests verify the line-mapping logic independent of Lumis by using a
  # nil language. With a nil language, highlight_code_block/2 returns the raw
  # content split by newline — so the highlighted array equals the source lines
  # verbatim. This makes the diff-line → file-line mapping deterministic and
  # testable without the Tree-sitter NIF.
  # ---------------------------------------------------------------------------

  describe "precompute_highlights/4 — file-level mapping" do
    # Helper: build a "file" map that parse_diff_lines/1 can consume.
    # parse_diff_lines/1 reads `file.diff`, so we build a minimal struct/map.
    defp diff_file(diff) do
      %{diff: diff}
    end

    test "maps context and addition lines to the new file's highlighting" do
      # New file has 5 lines; line 2 is a new addition.
      full_new = "line1\nline2_new\nline3\nline4\nline5"
      full_old = "line1\nline3\nline4\nline5"

      diff = """
      @@ -1,4 +1,5 @@
       line1
      +line2_new
       line3
       line4
       line5
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, nil, full_new, full_old)

      # The addition (line2_new) and context (line1, line3, line4, line5) all
      # come from the new file → they should equal the raw new-file lines.
      addition_line = Enum.find(lines, &(&1.type == :addition))
      assert unwrap(Map.get(result, addition_line.line_number)) == "line2_new"

      context_line3 = Enum.find(lines, &(&1.type == :context and &1.content == "line3"))
      assert unwrap(Map.get(result, context_line3.line_number)) == "line3"
    end

    test "maps deletion lines to the old file's highlighting" do
      full_new = "line1\nline3"
      full_old = "line1\nline2_old\nline3"

      diff = """
      @@ -1,3 +1,2 @@
       line1
      -line2_old
       line3
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, nil, full_new, full_old)

      deletion_line = Enum.find(lines, &(&1.type == :deletion))
      # Deletion should come from the old file's highlighting.
      assert unwrap(Map.get(result, deletion_line.line_number)) == "line2_old"
    end

    test "handles added file (full_old_content is nil)" do
      full_new = "line1\nline2\nline3"

      diff = """
      @@ -0,0 +1,3 @@
      +line1
      +line2
      +line3
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, nil, full_new, nil)

      # All three additions should be mapped to new-file highlighting.
      additions = Enum.filter(lines, &(&1.type == :addition))
      assert length(additions) == 3

      for addition <- additions do
        assert unwrap(Map.get(result, addition.line_number)) == addition.content
      end
    end

    test "handles deleted file (full_new_content is nil)" do
      full_old = "line1\nline2\nline3"

      diff = """
      @@ -1,3 +0,0 @@
      -line1
      -line2
      -line3
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, nil, nil, full_old)

      deletions = Enum.filter(lines, &(&1.type == :deletion))
      assert length(deletions) == 3

      for deletion <- deletions do
        assert unwrap(Map.get(result, deletion.line_number)) == deletion.content
      end
    end

    test "out-of-bounds line index falls back to raw line content" do
      # The hunk header claims old_start=100, new_start=100 but the full files
      # are tiny — so all lookups are out of bounds.
      full_new = "only_one_line"
      full_old = "only_one_line"

      diff = """
      @@ -100,2 +100,2 @@
       context_a
      +addition_a
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, nil, full_new, full_old)

      context_line = Enum.find(lines, &(&1.type == :context))
      addition_line = Enum.find(lines, &(&1.type == :addition))

      # Out-of-bounds → fall back to raw content (not empty string).
      assert unwrap(Map.get(result, context_line.line_number)) == "context_a"
      assert unwrap(Map.get(result, addition_line.line_number)) == "addition_a"
    end

    test "multi-hunk offsets are tracked independently" do
      full_new = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10"
      full_old = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10"

      # Two hunks: first changes line 2, second changes line 7.
      diff = """
      @@ -1,3 +1,3 @@
       l1
      -l2
      +l2_mod
       l3
      @@ -6,3 +6,3 @@
       l6
      -l7
      +l7_mod
       l8
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, nil, full_new, full_old)

      deletions = Enum.filter(lines, &(&1.type == :deletion))
      additions = Enum.filter(lines, &(&1.type == :addition))

      assert length(deletions) == 2
      assert length(additions) == 2

      # The second hunk's addition should map to "l7_mod" (new file line 7).
      second_addition = Enum.find(additions, &(&1.content == "l7_mod"))
      assert unwrap(Map.get(result, second_addition.line_number)) == "l7_mod"

      # The second hunk's deletion should map to "l7" (old file line 7).
      second_deletion = Enum.find(deletions, &(&1.content == "l7"))
      assert unwrap(Map.get(result, second_deletion.line_number)) == "l7"
    end
  end

  # ---------------------------------------------------------------------------
  # Fallback to hunk-level highlighting
  # ---------------------------------------------------------------------------

  describe "precompute_highlights/4 — fallback to hunk-level" do
    test "falls back to hunk-level when both full contents are nil" do
      diff = """
      @@ -1,2 +1,2 @@
       line1
      -line2_old
      """

      lines = DiffViewer.parse_diff_lines(%{diff: diff})
      result = DiffViewer.precompute_highlights(lines, nil, nil, nil)

      # With nil language, hunk-level highlighting returns raw lines.
      deletion_line = Enum.find(lines, &(&1.type == :deletion))
      assert unwrap(Map.get(result, deletion_line.line_number)) == "line2_old"
    end

    test "falls back to hunk-level when file exceeds byte-size threshold" do
      # Generate ~600KB of content to genuinely exceed the
      # @max_full_file_bytes (500_000 = 500KB) byte-size threshold.
      big_content = Enum.map_join(1..10, "\n", fn _ -> String.duplicate("x", 60_000) end)

      diff = """
      @@ -1,2 +1,2 @@
       line1
      +line2_new
      """

      lines = DiffViewer.parse_diff_lines(%{diff: diff})
      result = DiffViewer.precompute_highlights(lines, nil, big_content, big_content)

      # The big file exceeds @max_full_file_bytes (500_000), so file-level is
      # skipped and hunk-level is used. With nil language the result is raw.
      addition_line = Enum.find(lines, &(&1.type == :addition))
      assert unwrap(Map.get(result, addition_line.line_number)) == "line2_new"
    end

    test "falls back to hunk-level for binary content (null bytes)" do
      binary_content = "line1\n\0binary data here\nline3"

      diff = """
      @@ -1,2 +1,2 @@
       line1
      +line2_new
      """

      lines = DiffViewer.parse_diff_lines(%{diff: diff})
      result = DiffViewer.precompute_highlights(lines, nil, binary_content, binary_content)

      # Binary content (null byte) is detected by maybe_highlight_full/2, so
      # file-level is skipped and hunk-level fallback is used.
      addition_line = Enum.find(lines, &(&1.type == :addition))
      assert unwrap(Map.get(result, addition_line.line_number)) == "line2_new"
    end
  end

  # Helper: a span-balanced fragment has an equal number of opening and
  # closing <span> tags.
  defp balanced_spans?(html) do
    open = count_occurrences(html, "<span")
    close = count_occurrences(html, "</span>")
    open == close
  end

  # Helper: unwrap {:safe, html} that raw/1 wraps around highlighted values.
  defp unwrap({:safe, html}), do: html
  defp unwrap(other), do: other

  defp count_occurrences(html, needle) do
    html
    |> String.split(needle, parts: :infinity)
    |> length()
    |> Kernel.-(1)
  end
end
