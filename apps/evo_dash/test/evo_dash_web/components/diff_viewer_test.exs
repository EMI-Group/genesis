defmodule EvoDashWeb.DiffViewerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ReviewComponents.DiffViewer

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

    test "omits the data-language attribute entirely when the language is nil" do
      html =
        render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff, language: nil)])

      [section] = Floki.find(parse(html), ".diff-file-section")
      # A nil language must OMIT the attribute (not render data-language="") —
      # the JS hook skips sections without a data-language value.
      assert Floki.attribute(section, "data-language") == []
      refute html =~ "data-language"
    end

    test "derives the per-file section id from the sanitized path" do
      html =
        render_diff_viewer([
          file_fixture("lib/sub/Foo.bar.ex", @basic_diff, language: nil)
        ])

      # file_path_to_id/1 replaces every non [a-zA-Z0-9_-] char with "-".
      [section] = Floki.find(parse(html), ".diff-file-section")
      assert Floki.attribute(section, "id") == ["file-section-lib-sub-Foo-bar-ex"]
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
      # (This exact-value assert pins the single-hook contract; a regression
      # reintroducing the old two-hook form fails it.)
    end

    test "per-file header button fires toggle_file_expansion with the file path" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff)])

      [header] = Floki.find(parse(html), ".diff-file-header")

      assert Floki.attribute(header, "phx-click") == ["toggle_file_expansion"]
      assert Floki.attribute(header, "phx-value-path") == ["lib/foo.ex"]
    end

    test "context expansion bars fire expand_context with the file path" do
      html = render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff)])

      # One expand bar above and one below the hunk (context level 3 default).
      bars = Floki.find(parse(html), ".diff-expand-btn")
      assert length(bars) == 2

      assert Enum.map(bars, &Floki.attribute(&1, "phx-click")) == [
               ["expand_context"],
               ["expand_context"]
             ]

      assert Enum.map(bars, &Floki.attribute(&1, "phx-value-path")) == [
               ["lib/foo.ex"],
               ["lib/foo.ex"]
             ]
    end

    test "context level :all disables the expansion bars" do
      html =
        render_diff_viewer([file_fixture("lib/foo.ex", @basic_diff)],
          file_context_levels: %{"lib/foo.ex" => :all}
        )

      assert Floki.find(parse(html), ".diff-expand-btn") == []
      # The diff itself still renders.
      assert Floki.find(parse(html), ".diff-split-row") |> length() == 3
    end
  end

  # ---------------------------------------------------------------------------
  # diff_viewer/1 — LAZY diff loading
  #
  # The review page fetches diff text per-file on demand: headers/stats render
  # from FileInfo metadata alone, and only EXPANDED files whose diff has been
  # fetched render diff content. A nil diff on an expanded file is the
  # in-flight fetch state.
  # ---------------------------------------------------------------------------

  describe "diff_viewer/1 — lazy diff loading" do
    test "an unexpanded file renders only its header (no body, no expand bars)" do
      files = [file_fixture("lib/foo.ex", @basic_diff, additions: 1, deletions: 1)]

      html =
        render_component(&DiffViewer.diff_viewer/1,
          files: files,
          expanded_files: %{},
          selected_file: nil,
          file_context_levels: %{}
        )

      doc = parse(html)

      # Header still renders from metadata alone (lazy contract)…
      assert Floki.find(doc, ".diff-file-header") |> length() == 1
      assert Floki.attribute(doc, ".diff-file-header", "phx-value-path") == ["lib/foo.ex"]
      assert html =~ "lib/foo.ex"

      # …but no body content at all.
      assert Floki.find(doc, ".diff-split-row") == []
      assert Floki.find(doc, ".diff-expand-btn") == []
      assert Floki.find(doc, ".diff-split-hunk") == []
    end

    test "an expanded file with a nil diff shows the Loading diff… spinner" do
      files = [file_fixture("lib/foo.ex", nil, additions: 1, deletions: 1)]

      html =
        render_component(&DiffViewer.diff_viewer/1,
          files: files,
          expanded_files: %{"lib/foo.ex" => true},
          selected_file: nil,
          file_context_levels: %{}
        )

      doc = parse(html)

      assert Floki.find(doc, ".diff-file-header") |> length() == 1
      assert html =~ "Loading diff..."
      assert Floki.find(doc, ".loading") |> length() == 1
      # No split rows yet — the diff has not been fetched.
      assert Floki.find(doc, ".diff-split-row") == []
    end

    test "an expanded file with a fetched diff renders its split rows" do
      files = [file_fixture("lib/foo.ex", @basic_diff, additions: 1, deletions: 1)]

      html =
        render_component(&DiffViewer.diff_viewer/1,
          files: files,
          expanded_files: %{"lib/foo.ex" => true},
          selected_file: nil,
          file_context_levels: %{}
        )

      assert Floki.find(parse(html), ".diff-split-row") |> length() == 3
      refute html =~ "Loading diff..."
    end
  end

  # ---------------------------------------------------------------------------
  # file_tree_sidebar/1 — server-driven tree state
  #
  # The redesign removed every <details> element from the tree: directory
  # expansion is 100% server-driven through the `expanded_dirs` map (dir FULL
  # path => boolean, collapsed by default), with dir rows as plain <button>s
  # firing `toggle_dir` with the FULL accumulated dir path.
  # ---------------------------------------------------------------------------

  describe "file_tree_sidebar/1 — server-driven tree state" do
    test "directories are collapsed by default: file rows stay hidden until the dir is open" do
      html = render_sidebar(sidebar_files())

      # The dir button itself renders…
      [lib_btn] = dir_buttons(parse(html))
      assert lib_btn.path == "lib"
      assert lib_btn.aria == "false"

      # …but its nested file does NOT (children render only while open).
      assert file_paths(parse(html)) == ["README.md"]
    end

    test "opening a directory in expanded_dirs renders its children and flips aria-expanded" do
      html = render_sidebar(sidebar_files(), expanded_dirs: %{"lib" => true})
      doc = parse(html)

      # Two dir buttons now visible: the root "lib" (open) and the nested
      # "lib/bar" (still collapsed). Nested dir paths are the FULL accumulated
      # path — that is the phx-value-dir payload of `toggle_dir`.
      assert Enum.map(dir_buttons(doc), & &1.path) == ["lib", "lib/bar"]
      assert Enum.map(dir_buttons(doc), & &1.aria) == ["true", "false"]

      # The nested file row of "lib" renders; "lib/bar"'s child stays hidden.
      assert file_paths(doc) == ["lib/foo.ex", "README.md"]
    end

    test "a nested dir open while its parent is closed still renders nothing beneath the parent" do
      html =
        render_sidebar([file_fixture("lib/bar/baz.ex", @basic_diff)],
          expanded_dirs: %{"lib/bar" => true}
        )

      doc = parse(html)

      # Only the root "lib" dir row is visible (closed) — the open "lib/bar"
      # state is inert until its parent renders it.
      assert Enum.map(dir_buttons(doc), & &1.path) == ["lib"]
      assert Enum.map(dir_buttons(doc), & &1.aria) == ["false"]
      assert file_paths(doc) == []
    end

    test "the tree contains no <details> elements (no client-side disclosure)" do
      html = render_sidebar(sidebar_files(), expanded_dirs: %{"lib" => true, "lib/bar" => true})

      assert Floki.find(parse(html), "details") == []
    end

    test "dir rows carry subtree aggregate stats (file count + summed adds/dels)" do
      html = render_sidebar(sidebar_files())

      [lib_btn] = Floki.find(parse(html), ~s(button[phx-click="toggle_dir"]))

      # sidebar_files(): lib/foo.ex (+1/-2) and lib/bar/baz.ex (+5/-0) → 2
      # files, +6, -2 aggregated onto the "lib" row.
      text = Floki.text(lib_btn)
      assert text =~ "lib"
      assert text =~ "2 files"
      assert text =~ "+6"
      assert text =~ "-2"
    end

    test "siblings sort directories first, then files, case-insensitively" do
      files = [
        file_fixture("README.md", @basic_diff),
        file_fixture("Zeta/x.txt", @basic_diff),
        file_fixture("alpha/y.txt", @basic_diff),
        file_fixture("aardvark.txt", @basic_diff),
        file_fixture("Zebra/z.txt", @basic_diff)
      ]

      html = render_sidebar(files)
      doc = parse(html)

      # Directories first, case-insensitive alphabetical: alpha < Zebra < Zeta.
      assert Enum.map(dir_buttons(doc), & &1.path) == ["alpha", "Zebra", "Zeta"]
      # Then files, case-insensitive alphabetical: aardvark < README.
      assert file_paths(doc) == ["aardvark.txt", "README.md"]
    end

    test "file rows fire select_file with the full path and highlight the selected one" do
      html =
        render_sidebar(sidebar_files(),
          expanded_dirs: %{"lib" => true},
          selected_file: "lib/foo.ex"
        )

      doc = parse(html)
      buttons = Floki.find(doc, ~s(button[phx-click="select_file"]))

      assert Enum.map(buttons, &Floki.attribute(&1, "phx-value-path")) == [
               ["lib/foo.ex"],
               ["README.md"]
             ]

      # Only the selected row carries the highlight classes.
      assert Enum.map(buttons, &Floki.attribute(&1, "class")) == [
               [
                 ~s(w-full flex items-center gap-1.5 px-2 py-1.5 rounded-md text-xs transition-colors bg-primary/10 text-primary)
               ],
               [
                 "w-full flex items-center gap-1.5 px-2 py-1.5 rounded-md text-xs transition-colors hover:bg-base-200/60"
               ]
             ]
    end

    test "header carries the file count, the debounced filter input and the collapse/expand-all buttons" do
      files = sidebar_files()
      html = render_sidebar(files)
      doc = parse(html)

      # Filter input: name="filter", fires filter_files, 200ms debounce, and
      # is pre-filled with the server-owned filter value.
      assert Floki.attribute(doc, "input", "name") == ["filter"]
      assert Floki.attribute(doc, "input", "phx-change") == ["filter_files"]
      assert Floki.attribute(doc, "input", "phx-debounce") == ["200"]
      assert Floki.attribute(doc, "input", "value") == [""]

      # Whole-tree actions.
      assert Floki.find(doc, ~s(button[phx-click="collapse_all_dirs"])) |> length() == 1
      assert Floki.find(doc, ~s(button[phx-click="expand_all_dirs"])) |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # file_tree_sidebar/1 — flat filter mode
  #
  # A non-blank (trimmed) file_filter switches the sidebar from the tree to a
  # FLAT case-insensitive full-path match (no directory nodes); blank/absent
  # keeps tree mode.
  # ---------------------------------------------------------------------------

  describe "file_tree_sidebar/1 — flat filter mode" do
    test "a non-blank filter renders a flat case-insensitive full-path match with no dir nodes" do
      html = render_sidebar(sidebar_files(), file_filter: "BAZ")

      doc = parse(html)

      # Matched by full path (case-insensitive): the filter matches the
      # "lib/bar/baz.ex" path segment, not the basename-only "baz" dir row.
      assert file_paths(doc) == ["lib/bar/baz.ex"]
      # No directory nodes in filter mode — even with expanded_dirs set.
      assert dir_buttons(doc) == []
      # The input reflects the filter value back.
      assert Floki.attribute(doc, "input", "value") == ["BAZ"]
    end

    test "filtering is case-insensitive and matches anywhere in the path" do
      html = render_sidebar(sidebar_files(), file_filter: "lib/")

      # Filter mode preserves the @files order (Enum.filter — no re-sorting).
      assert file_paths(parse(html)) == ["lib/foo.ex", "lib/bar/baz.ex"]
    end

    test "a filter with no matches renders the 'No matching files' empty state" do
      html = render_sidebar(sidebar_files(), file_filter: "zzz")
      doc = parse(html)

      assert Floki.find(doc, ~s(button[phx-click="select_file"])) == []
      assert Floki.find(doc, ~s(button[phx-click="toggle_dir"])) == []
      assert html =~ "No matching files"
    end

    test "a whitespace-only filter falls back to tree mode" do
      html = render_sidebar(sidebar_files(), file_filter: "   ")

      # Trimmed-blank filter ≠ filter mode: the tree (with its dir buttons)
      # renders as usual.
      assert Enum.map(dir_buttons(parse(html)), & &1.path) == ["lib"]
    end
  end

  # ---------------------------------------------------------------------------
  # split_diff_layout/1 — multi-repo toolbar
  # ---------------------------------------------------------------------------

  describe "split_diff_layout/1 — multi-repo toolbar" do
    test "renders the repo toolbar only when more than one repo is configured" do
      files = sidebar_files()

      multi =
        render_component(&DiffViewer.split_diff_layout/1,
          files: files,
          expanded_files: %{},
          selected_file: nil,
          file_context_levels: %{},
          expanded_dirs: %{},
          file_filter: "",
          repos: [
            %{repo_id: "primary", repo_path: "/dev/repo-a"},
            %{repo_id: "r2", repo_path: "/dev/repo-b"}
          ],
          active_repo_id: "primary"
        )

      assert Floki.find(parse(multi), ~s(select[name="repo_id"])) |> length() == 1

      for html <- [
            # single repo
            render_component(&DiffViewer.split_diff_layout/1,
              files: files,
              expanded_files: %{},
              repos: [%{repo_id: "primary", repo_path: "/dev/repo-a"}],
              active_repo_id: "primary"
            ),
            # no repos at all (default [])
            render_component(&DiffViewer.split_diff_layout/1, files: files, expanded_files: %{})
          ] do
        assert Floki.find(parse(html), ~s(select[name="repo_id"])) == []
        refute html =~ "switch_repo"
      end
    end

    test "the repo select fires switch_repo, labels each option 'id — path' and preselects the active repo" do
      html =
        render_component(&DiffViewer.split_diff_layout/1,
          files: sidebar_files(),
          expanded_files: %{},
          selected_file: nil,
          file_context_levels: %{},
          expanded_dirs: %{},
          file_filter: "",
          repos: [
            %{repo_id: "primary", repo_path: "/home/dev/repo-a"},
            %{repo_id: "r2", repo_path: "/home/dev/repo-b"}
          ],
          active_repo_id: "r2"
        )

      doc = parse(html)

      [select] = Floki.find(doc, ~s(select[name="repo_id"]))
      assert Floki.attribute(select, "phx-change") == ["switch_repo"]

      options = Floki.find(select, "option")
      assert Enum.map(options, &Floki.attribute(&1, "value")) == [["primary"], ["r2"]]

      assert Enum.map(options, &String.trim(Floki.text(&1))) == [
               "primary — /home/dev/repo-a",
               "r2 — /home/dev/repo-b"
             ]

      # Only the active repo's option is preselected.
      assert Enum.map(options, &Floki.attribute(&1, "selected")) == [[], ["selected"]]

      # The toolbar carries the Repository label.
      assert html =~ "Repository"
    end

    test "a repo without a usable path renders a bare-id option label" do
      html =
        render_component(&DiffViewer.split_diff_layout/1,
          files: sidebar_files(),
          expanded_files: %{},
          repos: [
            %{repo_id: "primary", repo_path: "/dev/repo-a"},
            %{repo_id: "external", repo_path: nil}
          ],
          active_repo_id: "primary"
        )

      [external] =
        parse(html)
        |> Floki.find("option")
        |> Enum.filter(&(Floki.attribute(&1, "value") == ["external"]))

      assert String.trim(Floki.text(external)) == "external"
    end

    test "long repo paths are truncated to ~30 chars in the option label" do
      long_path = "/home/dev/" <> String.duplicate("x", 40)

      html =
        render_component(&DiffViewer.split_diff_layout/1,
          files: sidebar_files(),
          expanded_files: %{},
          repos: [%{repo_id: "primary", repo_path: long_path}, %{repo_id: "r2", repo_path: "/b"}],
          active_repo_id: "primary"
        )

      [primary] =
        parse(html)
        |> Floki.find("option")
        |> Enum.filter(&(Floki.attribute(&1, "value") == ["primary"]))

      label = String.trim(Floki.text(primary))
      assert label == "primary — #{String.slice(long_path, 0, 30)}..."
    end

    test "the toolbar sums additions/deletions across ALL files of the repo" do
      # sidebar_files(): lib/foo.ex (+1/-2), lib/bar/baz.ex (+5/-0), README.md
      # (+3/-1) → toolbar sums +9 / -3.
      html =
        render_component(&DiffViewer.split_diff_layout/1,
          files: sidebar_files(),
          expanded_files: %{},
          repos: [
            %{repo_id: "primary", repo_path: "/dev/repo-a"},
            %{repo_id: "r2", repo_path: "/dev/repo-b"}
          ],
          active_repo_id: "primary"
        )

      # div.ml-auto is the toolbar's right-aligned sums container (a
      # DIFFERENT container from the per-file header stats).
      sums =
        parse(html)
        |> Floki.find("div.ml-auto span")
        |> Enum.map(&String.trim(Floki.text(&1)))

      assert sums == ["+9", "-3"]
    end

    test "composes the file-tree sidebar and the diff viewer underneath the toolbar" do
      html =
        render_component(&DiffViewer.split_diff_layout/1,
          files: sidebar_files(),
          expanded_files: %{"lib/foo.ex" => true},
          selected_file: nil,
          file_context_levels: %{},
          expanded_dirs: %{"lib" => true},
          file_filter: "",
          repos: [
            %{repo_id: "primary", repo_path: "/dev/repo-a"},
            %{repo_id: "r2", repo_path: "/dev/repo-b"}
          ],
          active_repo_id: "primary"
        )

      doc = parse(html)

      # Sidebar drives through the same server-driven contract…
      assert Enum.map(dir_buttons(doc), & &1.path) == ["lib", "lib/bar"]
      assert file_paths(doc) == ["lib/foo.ex", "README.md"]
      # …and the diff viewer renders with the expanded file.
      assert Floki.find(doc, "#diff-viewer") |> length() == 1
      assert Floki.find(doc, ".diff-file-header") |> length() == 3
      assert Floki.find(doc, ".diff-split-row") |> length() == 3
    end
  end

  # ---------------------------------------------------------------------------
  # commit_diff_layout/1 — commit-inspection variant
  # ---------------------------------------------------------------------------

  describe "commit_diff_layout/1" do
    test "renders the sidebar + diff viewer pair with NO repo toolbar" do
      html =
        render_component(&DiffViewer.commit_diff_layout/1,
          files: sidebar_files(),
          expanded_files: %{},
          selected_file: nil,
          file_context_levels: %{},
          expanded_dirs: %{"lib" => true},
          file_filter: ""
        )

      doc = parse(html)

      # No repo select anywhere in the commit layout.
      assert Floki.find(doc, ~s(select[name="repo_id"])) == []
      refute html =~ "switch_repo"
      refute html =~ "Repository"

      # But the same sidebar + viewer pair as the split layout.
      assert Floki.attribute(doc, "input", "phx-change") == ["filter_files"]
      assert Enum.map(dir_buttons(doc), & &1.path) == ["lib", "lib/bar"]
      assert Floki.find(doc, "#diff-viewer") |> length() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # commit_detail_header/1
  # ---------------------------------------------------------------------------

  describe "commit_detail_header/1" do
    test "renders a plain back link, truncated message, short sha, author and date" do
      commit = %{
        message: "Fix the frobnicator",
        sha: "abcdef1234567890abcdef",
        author_name: "Ada Lovelace",
        date: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      }

      html =
        render_component(&DiffViewer.commit_detail_header/1,
          commit: commit,
          back_url: "/review/t1/commit/abcdef12",
          task_title: "Fix the bug"
        )

      doc = parse(html)

      # Plain <a href> back link (no phx navigation — full page load).
      [back] = Floki.find(doc, "a[href=\"/review/t1/commit/abcdef12\"]")
      assert Floki.attribute(back, "aria-label") == ["Back to review"]
      assert Floki.attribute(back, "title") == ["Back to review"]
      refute Floki.attribute(back, "phx-click") == [""]

      # Truncated message with a title attr carrying the full message.
      [h1] = Floki.find(doc, "h1")
      assert Floki.attribute(h1, "title") == ["Fix the frobnicator"]
      assert String.trim(Floki.text(h1)) == "Fix the frobnicator"

      # SHA sliced to 8 chars in a mono ghost badge.
      [sha_badge] = Floki.find(doc, "div > span.badge")
      assert String.trim(Floki.text(sha_badge)) == "abcdef12"

      assert html =~ "Ada Lovelace"
      assert html =~ "1h ago"
      assert html =~ "Fix the bug"
    end

    test "omits the task_title breadcrumb when not given" do
      html =
        render_component(&DiffViewer.commit_detail_header/1,
          commit: %{message: "m", sha: "1234567890", author_name: "A", date: DateTime.utc_now()},
          back_url: "/review/t1"
        )

      refute html =~ "Fix the bug"
    end
  end

  # --- fixtures & helpers ---

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
      diff: diff && String.trim_trailing(diff, "\n"),
      language: Keyword.get(opts, :language, "text"),
      full_new_content: Keyword.get(opts, :full_new_content),
      full_old_content: Keyword.get(opts, :full_old_content)
    }
  end

  # A small tree: lib/foo.ex (+1/-2), lib/bar/baz.ex (+5/-0), README.md
  # (+3/-1). Root children: the "lib" dir and the "README.md" file.
  defp sidebar_files do
    [
      file_fixture("lib/foo.ex", @basic_diff, additions: 1, deletions: 2),
      file_fixture("lib/bar/baz.ex", @basic_diff, additions: 5, deletions: 0),
      file_fixture("README.md", @basic_diff, additions: 3, deletions: 1)
    ]
  end

  # Render the diff_viewer/1 component with every file expanded (so the diff
  # content actually renders) and default context levels.
  defp render_diff_viewer(files, opts \\ []) do
    defaults = [
      files: files,
      expanded_files: Map.new(files, &{&1.path, true}),
      selected_file: nil,
      file_context_levels: %{}
    ]

    render_component(&DiffViewer.diff_viewer/1, Keyword.merge(defaults, opts))
  end

  defp render_sidebar(files, opts \\ []) do
    defaults = [
      files: files,
      selected_file: nil,
      expanded_dirs: %{},
      file_filter: ""
    ]

    render_component(&DiffViewer.file_tree_sidebar/1, Keyword.merge(defaults, opts))
  end

  # Directory rows of the sidebar: %{path: phx-value-dir, aria: aria-expanded}
  # — only the currently-visible ones (children of closed dirs are not in the
  # DOM at all, which is exactly the server-driven contract).
  defp dir_buttons(doc) do
    doc
    |> Floki.find(~s(button[phx-click="toggle_dir"]))
    |> Enum.map(fn btn ->
      %{
        path: Floki.attribute(btn, "phx-value-dir") |> List.first(),
        aria: Floki.attribute(btn, "aria-expanded") |> List.first()
      }
    end)
  end

  # Visible file rows of the sidebar (their phx-value-path payloads), in DOM
  # order — pins both the visibility and the sibling sort.
  defp file_paths(doc) do
    doc
    |> Floki.find(~s(button[phx-click="select_file"]))
    |> Enum.map(&Floki.attribute(&1, "phx-value-path"))
    |> Enum.map(&List.first/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
