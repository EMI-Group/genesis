defmodule EvoDashWeb.DiffViewerTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ReviewComponents.DiffViewer

  # These tests cover the `parse_lumis_lines/1` function, which parses
  # Lumis's per-line `<div class="l-line" data-line="N">...</div>` output
  # (wrapped in `<pre><code>...</code></pre>`) into a map of
  # `%{line_number => inner_html}`.

  describe "parse_lumis_lines/1" do
    test "parses a simple highlighted code block into a line-number map" do
      html =
        ~s(<pre class="lumis"><code class="lang-elixir"><div class="l-line" data-line="1"><span style="color:#keyword">def</span> foo</div>\n<div class="l-line" data-line="2"><span style="color:#string">"bar"</span></div></code></pre>)

      result = DiffViewer.parse_lumis_lines(html)

      assert map_size(result) == 2
      assert result[1] == ~s(<span style="color:#keyword">def</span> foo)
      # Floki's raw_html/1 HTML-encodes quotes in text content as &quot;
      assert result[2] == ~s(<span style="color:#string">&quot;bar&quot;</span>)
    end

    test "preserves inner span tags (syntax highlighting)" do
      html =
        ~s(<pre class="lumis"><code><div class="l-line" data-line="1"><span style="color:#keyword">def</span> foo</div></code></pre>)

      result = DiffViewer.parse_lumis_lines(html)

      assert String.contains?(result[1], "<span")
      assert String.contains?(result[1], "</span>")
      assert String.contains?(result[1], "def")
      assert String.contains?(result[1], "foo")
      # No div wrappers should survive
      refute String.contains?(result[1], "<div")
      refute String.contains?(result[1], "</div>")
    end

    test "handles multi-line input returning multiple entries" do
      html =
        ~s(<pre class="lumis"><code><div class="l-line" data-line="10"><span>a</span></div>\n<div class="l-line" data-line="11"><span>b</span></div>\n<div class="l-line" data-line="12"><span>c</span></div></code></pre>)

      result = DiffViewer.parse_lumis_lines(html)

      assert map_size(result) == 3
      assert result[10] == "<span>a</span>"
      assert result[11] == "<span>b</span>"
      assert result[12] == "<span>c</span>"
    end

    test "returns empty map for empty input" do
      assert DiffViewer.parse_lumis_lines("") == %{}
    end

    test "returns empty map for HTML without l-line divs" do
      html = ~s(<pre><code>plain text</code></pre>)

      assert DiffViewer.parse_lumis_lines(html) == %{}
    end

    test "handles <pre> without <code> gracefully" do
      html = ~s(<pre><div class="l-line" data-line="1"><span>hello</span></div></pre>)

      result = DiffViewer.parse_lumis_lines(html)

      assert result[1] == "<span>hello</span>"
    end
  end

  describe "end-to-end: parse_lumis_lines/1 — realistic Lumis output" do
    @lumis_output ~s(<pre class="lumis"><code class="lang-elixir"><div class="l-line" data-line="1"><span style="color:#keyword">def</span> foo</div>\n<div class="l-line" data-line="2"><span style="color:#string">"bar"</span></div></code></pre>)

    test "produces a map with correct line numbers and no div wrappers" do
      result = DiffViewer.parse_lumis_lines(@lumis_output)

      assert map_size(result) == 2
      assert result[1] == ~s(<span style="color:#keyword">def</span> foo)
      # Floki's raw_html/1 HTML-encodes quotes in text content as &quot;
      assert result[2] == ~s(<span style="color:#string">&quot;bar&quot;</span>)
    end

    test "content is preserved" do
      result = DiffViewer.parse_lumis_lines(@lumis_output)

      assert String.contains?(result[1], "def")
      assert String.contains?(result[1], "foo")
      assert String.contains?(result[2], "bar")
    end

    test "multi-line content parsed correctly" do
      lumis_output =
        ~s(<pre class="lumis"><code><div class="l-line" data-line="1"><span style="color:#string">\"\"\"line1</span></div>\n<div class="l-line" data-line="2"><span style="color:#string">line2\"\"\"</span></div></code></pre>)

      result = DiffViewer.parse_lumis_lines(lumis_output)

      assert map_size(result) == 2
      # Floki's raw_html/1 HTML-encodes quotes in text content as &quot;
      assert result[1] == ~s(<span style="color:#string">&quot;&quot;&quot;line1</span>)
      assert result[2] == ~s(<span style="color:#string">line2&quot;&quot;&quot;</span>)
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
      # full_new reflects the modifications: l2->l2_mod (line 2), l7->l7_mod (line 7)
      full_new = "l1\nl2_mod\nl3\nl4\nl5\nl6\nl7_mod\nl8\nl9\nl10"
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

    test "file-level highlighting applies syntax highlighting with a real language" do
      full_new = "def foo do\n  :bar\nend\n"
      full_old = "def foo do\n  :old\nend\n"

      diff = """
      @@ -1,3 +1,3 @@
       def foo do
      -:old
      +:bar
       end
      """

      lines = DiffViewer.parse_diff_lines(diff_file(diff))
      result = DiffViewer.precompute_highlights(lines, "elixir", full_new, full_old)

      # The addition line should have syntax highlighting (spans).
      addition_line = Enum.find(lines, &(&1.type == :addition))
      addition_hl = unwrap(Map.get(result, addition_line.line_number))

      assert String.contains?(addition_hl, "<span"),
             "expected highlighted HTML, got: #{inspect(addition_hl)}"

      # Context lines should also be highlighted.
      context_line = Enum.find(lines, &(&1.type == :context and &1.content == "def foo do"))
      context_hl = unwrap(Map.get(result, context_line.line_number))

      assert String.contains?(context_hl, "<span"),
             "expected highlighted HTML, got: #{inspect(context_hl)}"

      # Deletion lines should be highlighted from the old file's highlighting.
      deletion_line = Enum.find(lines, &(&1.type == :deletion))
      deletion_hl = unwrap(Map.get(result, deletion_line.line_number))

      assert String.contains?(deletion_hl, "<span"),
             "expected highlighted HTML, got: #{inspect(deletion_hl)}"
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

  # ---------------------------------------------------------------------------
  # Split-view pairing: build_split_pairs/1
  #
  # Tests the algorithm that converts hunk body lines into side-by-side pairs
  # for the GitHub-style split diff view.
  # ---------------------------------------------------------------------------

  describe "build_split_pairs/1" do
    # Helper: build a parsed diff line map.
    defp line(idx, prefix, content, type) do
      %{line_number: idx, prefix: prefix, content: content, type: type}
    end

    test "context lines appear on both sides with advancing line numbers" do
      # @@ -1,3 +1,3 @@
      #  line1
      #  line2
      #  line3
      body = [
        line(2, " ", "line1", :context),
        line(3, " ", "line2", :context),
        line(4, " ", "line3", :context)
      ]

      pairs = DiffViewer.build_split_pairs(body, 1, 1)

      assert length(pairs) == 3

      for {{pair, _exp_num}, i} <- Enum.with_index(pairs, 1) do
        assert pair.type == :context
        assert pair.left.line_num == i
        assert pair.right.line_num == i
        assert pair.left.line.content == "line#{i}"
        assert pair.right.line.content == "line#{i}"
      end
    end

    test "deletion lines appear only on the left (right is nil)" do
      # @@ -1,2 +1,1 @@
      #  ctx
      # -del
      body = [
        line(2, " ", "ctx", :context),
        line(3, "-", "del", :deletion)
      ]

      pairs = DiffViewer.build_split_pairs(body, 1, 1)

      assert length(pairs) == 2

      # First pair: context on both sides
      [p1, p2] = pairs
      assert p1.type == :context
      assert p1.left.line_num == 1
      assert p1.right.line_num == 1

      # Second pair: deletion on left, nil on right
      assert p2.type == :deletion
      assert p2.left.line_num == 2
      assert p2.left.line.content == "del"
      assert p2.right == nil
    end

    test "addition lines appear only on the right (left is nil)" do
      # @@ -1,1 +1,2 @@
      #  ctx
      # +add
      body = [
        line(2, " ", "ctx", :context),
        line(3, "+", "add", :addition)
      ]

      pairs = DiffViewer.build_split_pairs(body, 1, 1)

      assert length(pairs) == 2

      [p1, p2] = pairs
      assert p1.type == :context
      assert p1.left.line_num == 1
      assert p1.right.line_num == 1

      assert p2.type == :addition
      assert p2.right.line_num == 2
      assert p2.right.line.content == "add"
      assert p2.left == nil
    end

    test "consecutive deletions followed by additions are zipped together" do
      # 3 deletions then 2 additions → 3 paired rows (del+add, del+add, del+blank)
      body = [
        line(2, "-", "del1", :deletion),
        line(3, "-", "del2", :deletion),
        line(4, "-", "del3", :deletion),
        line(5, "+", "add1", :addition),
        line(6, "+", "add2", :addition)
      ]

      pairs = DiffViewer.build_split_pairs(body, 1, 1)

      assert length(pairs) == 3

      [p1, p2, p3] = pairs

      # First two pairs: mixed (deletion on left, addition on right)
      assert p1.type == :mixed
      assert p1.left.line.content == "del1"
      assert p1.right.line.content == "add1"

      assert p2.type == :mixed
      assert p2.left.line.content == "del2"
      assert p2.right.line.content == "add2"

      # Third pair: deletion only (right is nil — extra deletion)
      assert p3.type == :deletion
      assert p3.left.line.content == "del3"
      assert p3.right == nil
    end

    test "more additions than deletions pads left with nil" do
      # 2 deletions then 3 additions → 3 paired rows
      body = [
        line(2, "-", "del1", :deletion),
        line(3, "-", "del2", :deletion),
        line(4, "+", "add1", :addition),
        line(5, "+", "add2", :addition),
        line(6, "+", "add3", :addition)
      ]

      pairs = DiffViewer.build_split_pairs(body, 1, 1)

      assert length(pairs) == 3

      [p1, p2, p3] = pairs

      assert p1.type == :mixed
      assert p1.left.line.content == "del1"
      assert p1.right.line.content == "add1"

      assert p2.type == :mixed
      assert p2.left.line.content == "del2"
      assert p2.right.line.content == "add2"

      # Third pair: addition only (left is nil)
      assert p3.type == :addition
      assert p3.left == nil
      assert p3.right.line.content == "add3"
    end

    test "line numbers advance correctly for context + addition + deletion" do
      # @@ -5,3 +5,4 @@
      #  ctx          (old:5, new:5)
      # -del          (old:6)
      # +add1         (     new:6)
      # +add2         (     new:7)
      body = [
        line(2, " ", "ctx", :context),
        line(3, "-", "del", :deletion),
        line(4, "+", "add1", :addition),
        line(5, "+", "add2", :addition)
      ]

      pairs = DiffViewer.build_split_pairs(body, 5, 5)

      assert length(pairs) == 3

      [p1, p2, p3] = pairs

      # Context: both sides at line 5
      assert p1.type == :context
      assert p1.left.line_num == 5
      assert p1.right.line_num == 5

      # Deletion + addition zipped: old line 6, new line 6
      assert p2.type == :mixed
      assert p2.left.line_num == 6
      assert p2.right.line_num == 6

      # Extra addition: new line 7, left is nil
      assert p3.type == :addition
      assert p3.left == nil
      assert p3.right.line_num == 7
    end

    test "returns empty list for empty body" do
      assert DiffViewer.build_split_pairs([], 1, 1) == []
    end

    test "deletions only (deleted file)" do
      # @@ -1,3 +0,0 @@
      # -line1
      # -line2
      # -line3
      body = [
        line(2, "-", "line1", :deletion),
        line(3, "-", "line2", :deletion),
        line(4, "-", "line3", :deletion)
      ]

      pairs = DiffViewer.build_split_pairs(body, 1, 0)

      assert length(pairs) == 3

      for {{pair, i}, exp_num} <- Enum.with_index(pairs, 1) do
        assert pair.type == :deletion
        assert pair.left.line_num == exp_num
        assert pair.left.line.content == "line#{i}"
        assert pair.right == nil
      end
    end

    test "additions only (new file)" do
      # @@ -0,0 +1,3 @@
      # +line1
      # +line2
      # +line3
      body = [
        line(2, "+", "line1", :addition),
        line(3, "+", "line2", :addition),
        line(4, "+", "line3", :addition)
      ]

      pairs = DiffViewer.build_split_pairs(body, 0, 1)

      assert length(pairs) == 3

      for {{pair, i}, exp_num} <- Enum.with_index(pairs, 1) do
        assert pair.type == :addition
        assert pair.right.line_num == exp_num
        assert pair.right.line.content == "line#{i}"
        assert pair.left == nil
      end
    end
  end

  # Helper: unwrap {:safe, html} that raw/1 wraps around highlighted values.
  defp unwrap({:safe, html}), do: html
  defp unwrap(other), do: other
end
