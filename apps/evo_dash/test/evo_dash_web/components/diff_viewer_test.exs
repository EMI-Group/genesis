defmodule EvoDashWeb.DiffViewerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ReviewComponents.DiffViewer

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

  # ---------------------------------------------------------------------------
  # Split-view rendering
  #
  # Server-side syntax highlighting was REMOVED from the diff viewer: the
  # backend renders ESCAPED PLAIN TEXT (no Lumis/highlight.js markup) and
  # emits a `data-language` attribute on each per-file section div so a
  # client-side highlight.js hook can highlight the code in the browser.
  # These tests pin that contract.
  # ---------------------------------------------------------------------------

  describe "split-view rendering" do
    # Helper: build a file map in the shape of %EvoGit.Review.FileInfo{} that
    # the diff_viewer component consumes (path/status/additions/deletions/diff/
    # language/full_new_content/full_old_content). The trailing newline is
    # trimmed so parse_diff_lines does not synthesize a phantom empty context
    # line at the end of the diff.
    defp file_fixture(path, diff, opts \\ []) do
      %{
        path: path,
        status: Keyword.get(opts, :status, "modified"),
        additions: Keyword.get(opts, :additions, 0),
        deletions: Keyword.get(opts, :deletions, 0),
        diff: String.trim_trailing(diff, "\n"),
        language: Keyword.get(opts, :language, "text"),
        full_new_content: Keyword.get(opts, :full_new_content),
        full_old_content: Keyword.get(opts, :full_old_content)
      }
    end

    # Render the diff_viewer/1 component with every file expanded (so the diff
    # content actually renders) and default context levels.
    defp render_diff_viewer(files) do
      expanded_files = Map.new(files, &{&1.path, true})

      render_component(&DiffViewer.diff_viewer/1,
        files: files,
        expanded_files: expanded_files,
        selected_file: nil,
        file_context_levels: %{}
      )
    end

    @basic_diff """
    diff --git a/lib/foo.ex b/lib/foo.ex
    index 1234567..89abcde 100644
    --- a/lib/foo.ex
    +++ b/lib/foo.ex
    @@ -1,3 +1,3 @@
     defmodule Foo do
    -  :old
    +  :new
     end
    """

    test "renders diff content as escaped plain text (no HTML injection)" do
      diff = """
      diff --git a/lib/inject.ex b/lib/inject.ex
      index 1234567..89abcde 100644
      --- a/lib/inject.ex
      +++ b/lib/inject.ex
      @@ -1,1 +1,1 @@
      -<script>alert(1)</script>
      +<div>nested</div>
      """

      html =
        render_diff_viewer([
          file_fixture("lib/inject.ex", diff, additions: 1, deletions: 1)
        ])

      # HTML in the diff content is escaped — never injected as live elements.
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script"
      assert html =~ "&lt;div&gt;nested&lt;/div&gt;"
      refute html =~ "<div>nested</div>"
    end

    test "renders no server-side highlight markup (plain text only)" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff, language: "elixir")])

      # No highlight.js classes, no Lumis output classes, no inline-style spans
      # from a server-side highlighter.
      refute html =~ "hljs-"
      refute html =~ "lumis"
      refute html =~ "l-line"
      refute html =~ ~s(<span style=)
    end

    test "emits a data-language attribute on the per-file section div" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff, language: "elixir")])

      [section] = Floki.find(parse(html), ".diff-file-section")
      assert Floki.attribute(section, "data-language") == ["elixir"]
    end

    test "renders hunk headers as plain text" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff)])

      assert html =~ "@@ -1,3 +1,3 @@"

      [hunk] = Floki.find(parse(html), ".diff-split-hunk")
      assert Floki.text(hunk) =~ "@@ -1,3 +1,3 @@"
    end

    test "renders split-view pairs with gutters and content on both sides" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff)])

      rows = Floki.find(parse(html), ".diff-split-row")
      assert length(rows) == 3

      [ctx1, mixed, ctx2] = rows

      # Context row: same content on both sides, gutters at line 1.
      assert Floki.find(ctx1, ".diff-split-cell-left") |> Floki.text() =~ "defmodule Foo do"
      assert Floki.find(ctx1, ".diff-split-cell-right") |> Floki.text() =~ "defmodule Foo do"
      assert Floki.find(ctx1, ".diff-split-gutter-left") |> Floki.text() == "1"
      assert Floki.find(ctx1, ".diff-split-gutter-right") |> Floki.text() == "1"

      # Mixed row: deletion on the left, addition on the right, gutters advance.
      assert Floki.find(mixed, ".diff-split-cell-left") |> Floki.text() =~ ":old"
      assert Floki.find(mixed, ".diff-split-cell-right") |> Floki.text() =~ ":new"
      assert Floki.find(mixed, ".diff-split-gutter-left") |> Floki.text() == "2"
      assert Floki.find(mixed, ".diff-split-gutter-right") |> Floki.text() == "2"

      # Trailing context row.
      assert Floki.find(ctx2, ".diff-split-cell-left") |> Floki.text() =~ "end"
      assert Floki.find(ctx2, ".diff-split-cell-right") |> Floki.text() =~ "end"
    end

    test "renders the file header with path and diff stats" do
      html =
        render_diff_viewer([
          file_fixture("lib/foo.ex", @basic_diff, additions: 1, deletions: 1)
        ])

      assert html =~ "lib/foo.ex"
      assert html =~ "+1"
      assert html =~ "-1"
    end

    test "attaches the single DiffViewer hook to #diff-viewer (LiveView 1.2: one hook name per element)" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff)])

      [viewer] = Floki.find(parse(html), "#diff-viewer")
      assert Floki.attribute(viewer, "phx-hook") == ["DiffViewer"]

      # LiveView 1.2 looks up the WHOLE attribute value as one hook name —
      # a space-separated multi-hook list would silently attach nothing.
      refute html =~ "ScrollToFile"
      refute html =~ "DiffHighlight"
    end
  end

  # --- helpers ---

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
