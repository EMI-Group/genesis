defmodule EvoGit.VCT.PathTest do
  @moduledoc """
  Pure, BEAM-global-free: exercises the canonical VCT URL value object only, so
  `async: true`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.VCT.Path

  describe "root/0 and projects/0" do
    test "root is the empty segment list" do
      assert Path.root() == %Path{segments: []}
      assert Path.format(Path.root()) == "vct:///"
    end

    test "projects is the projects folder" do
      assert Path.projects() == %Path{segments: ["projects"]}
      assert Path.format(Path.projects()) == "vct:///projects"
    end
  end

  describe "parse/1" do
    test "parses the canonical forms" do
      assert {:ok, %Path{segments: []}} = Path.parse("vct:///")
      assert {:ok, %Path{segments: ["projects"]}} = Path.parse("vct:///projects")
      assert {:ok, %Path{segments: ["projects", "foo"]}} = Path.parse("vct:///projects/foo")

      assert {:ok, %Path{segments: ["projects", "foo", "bar", "baz"]}} =
               Path.parse("vct:///projects/foo/bar/baz")
    end

    test "normalizes duplicate and trailing slashes" do
      assert {:ok, %Path{segments: ["projects", "foo"]}} = Path.parse("vct:////projects//foo/")
      assert {:ok, %Path{segments: ["projects", "foo"]}} = Path.parse("vct:///projects/foo/")
      assert {:ok, %Path{segments: []}} = Path.parse("vct:////")
      assert {:ok, %Path{segments: ["projects"]}} = Path.parse("vct://///projects")
    end

    test "rejects a non-local authority" do
      assert {:error, :non_local_authority} = Path.parse("vct://host/projects/foo")
      assert {:error, :non_local_authority} = Path.parse("vct://host")
      assert {:error, :non_local_authority} = Path.parse("vct://localhost/")
      assert {:error, :non_local_authority} = Path.parse("vct://projects")
    end

    test "rejects inputs without the vct:// scheme" do
      assert {:error, :invalid_scheme} = Path.parse("projects/foo")
      assert {:error, :invalid_scheme} = Path.parse("/projects/foo")
      assert {:error, :invalid_scheme} = Path.parse("")
      assert {:error, :invalid_scheme} = Path.parse("file:///projects/foo")
      assert {:error, :invalid_scheme} = Path.parse("vct:/projects")
    end

    test "rejects a URL carrying no path" do
      assert {:error, :invalid_path} = Path.parse("vct://")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_path} = Path.parse(nil)
      assert {:error, :invalid_path} = Path.parse(123)
    end

    test "rejects dot segments" do
      assert {:error, {:invalid_segment, "."}} = Path.parse("vct:///projects/./foo")
      assert {:error, {:invalid_segment, ".."}} = Path.parse("vct:///projects/../foo")
      assert {:error, {:invalid_segment, ".."}} = Path.parse("vct:///..")
    end

    test "rejects segments containing control characters" do
      assert {:error, {:invalid_segment, _}} = Path.parse("vct:///pro\0jects")
      assert {:error, {:invalid_segment, _}} = Path.parse("vct:///pro" <> <<0x07>> <> "jects")

      assert {:error, {:invalid_segment, _}} =
               Path.parse("vct:///projects/foo" <> <<0x7F>>)
    end
  end

  describe "parse!/1" do
    test "returns the parsed path" do
      assert Path.parse!("vct:///projects/foo") == %Path{segments: ["projects", "foo"]}
    end

    test "raises ArgumentError on invalid input" do
      message =
        "invalid VCT URL: \"vct://host/projects\" (only local VCT URLs (vct:///) are supported)"

      assert_raise ArgumentError, message, fn -> Path.parse!("vct://host/projects") end

      assert_raise ArgumentError, fn -> Path.parse!("projects") end
      assert_raise ArgumentError, fn -> Path.parse!("vct:///a/../b") end
    end
  end

  describe "format/1" do
    test "formats structs and plain segment lists canonically" do
      assert Path.format(%Path{segments: []}) == "vct:///"
      assert Path.format(%Path{segments: ["projects"]}) == "vct:///projects"
      assert Path.format(%Path{segments: ["projects", "foo"]}) == "vct:///projects/foo"
      assert Path.format([]) == "vct:///"
      assert Path.format(["projects", "foo"]) == "vct:///projects/foo"
    end

    test "raises ArgumentError on invalid segments" do
      for segments <- [[""], ["projects", ""], ["."], [".."], ["a/b"], ["a" <> <<0>>]] do
        assert_raise ArgumentError, fn -> Path.format(segments) end
      end

      assert_raise ArgumentError, fn -> Path.format(["ok", 123]) end
    end
  end

  describe "join/2" do
    test "appends one segment to a struct or a URL string" do
      assert Path.join(Path.root(), "projects") == %Path{segments: ["projects"]}
      assert Path.join("vct:///projects", "foo") == %Path{segments: ["projects", "foo"]}
    end

    test "appends several segments from a list" do
      assert Path.join(Path.projects(), ["foo", "bar"]) ==
               %Path{segments: ["projects", "foo", "bar"]}

      assert Path.join(Path.root(), []) == Path.root()
    end

    test "raises ArgumentError on invalid right-hand segments" do
      for segment <- ["", ".", "..", "a/b", "a" <> <<0x1F>>] do
        assert_raise ArgumentError, fn -> Path.join(Path.root(), segment) end
        assert_raise ArgumentError, fn -> Path.join(Path.root(), [segment]) end
      end
    end

    test "raises ArgumentError when the left-hand URL is invalid" do
      assert_raise ArgumentError, fn -> Path.join("nope", "foo") end
    end
  end

  describe "segments/1 and name/1" do
    test "segments/1 accepts structs and URL strings" do
      assert Path.segments(Path.root()) == []
      assert Path.segments("vct:///projects/foo") == ["projects", "foo"]
      assert Path.segments(Path.parse!("vct:///projects")) == ["projects"]
    end

    test "segments/1 raises on an invalid URL string" do
      assert_raise ArgumentError, fn -> Path.segments("vct://host/foo") end
    end

    test "name/1 is the last segment, nil for the root" do
      assert Path.name(Path.root()) == nil
      assert Path.name(Path.projects()) == "projects"
      assert Path.name("vct:///projects/foo") == "foo"
    end
  end

  describe "ancestor?/2 and under?/2" do
    test "ancestor?/2 is a strict segment prefix" do
      assert Path.ancestor?(Path.root(), Path.projects())
      assert Path.ancestor?(Path.root(), "vct:///projects/foo")
      assert Path.ancestor?("vct:///projects", "vct:///projects/foo")
    end

    test "ancestor?/2 is false for equality and for unrelated/sibling paths" do
      refute Path.ancestor?(Path.root(), Path.root())
      refute Path.ancestor?(Path.projects(), Path.projects())
      refute Path.ancestor?("vct:///projects/foo", "vct:///projects")
      refute Path.ancestor?("vct:///projects/foo", "vct:///projects/bar")
      refute Path.ancestor?("vct:///projects/foo", "vct:///other/foo")
    end

    test "under?/2 includes equality" do
      assert Path.under?(Path.root(), Path.projects())
      assert Path.under?(Path.root(), Path.root())
      assert Path.under?(Path.projects(), Path.projects())
      assert Path.under?("vct:///projects", "vct:///projects/foo/bar")
    end

    test "under?/2 is false when the prefix does not match" do
      refute Path.under?(Path.projects(), Path.root())
      refute Path.under?("vct:///projects/foo", "vct:///projects")
      refute Path.under?("vct:///projects/foo", "vct:///projects/bar")
      refute Path.under?("vct:///projects", "vct:///project")
    end
  end

  describe "relative_to/2" do
    test "returns the segments below the base" do
      assert Path.relative_to("vct:///projects/foo/bar", "vct:///projects") ==
               {:ok, ["foo", "bar"]}

      assert Path.relative_to("vct:///projects/foo", Path.root()) == {:ok, ["projects", "foo"]}
    end

    test "returns an empty list for equality" do
      assert Path.relative_to(Path.projects(), Path.projects()) == {:ok, []}
      assert Path.relative_to(Path.root(), Path.root()) == {:ok, []}
    end

    test "returns an error when the path is not under the base" do
      assert Path.relative_to(Path.projects(), "vct:///projects/foo") == {:error, :not_under}

      assert Path.relative_to("vct:///projects/bar", "vct:///projects/foo") ==
               {:error, :not_under}
    end
  end

  describe "String.Chars" do
    test "renders the canonical URL" do
      assert to_string(Path.root()) == "vct:///"
      assert to_string(Path.projects()) == "vct:///projects"
      assert "#{Path.parse!("vct:///projects/foo")}" == "vct:///projects/foo"
    end
  end

  describe "round-trip invariant" do
    @urls [
      "vct:///",
      "vct:///projects",
      "vct:///projects/foo",
      "vct:///projects/foo/bar",
      "vct:///projects/foo/bar/baz",
      "vct:////projects//foo/",
      "vct:///a",
      "vct:///a/b/c/d/e/f"
    ]

    test "parse(format(p)) == {:ok, p} for every successfully parsed URL" do
      for url <- @urls do
        assert {:ok, path} = Path.parse(url)
        assert {:ok, ^path} = Path.parse(Path.format(path))
        assert Path.format(Path.parse!(Path.format(path))) == Path.format(path)
      end
    end

    test "round-trips every prefix of a nested path" do
      path = Path.parse!("vct:///projects/foo/bar/baz")
      segments = Path.segments(path)

      for count <- 0..length(segments) do
        prefix = %Path{segments: Enum.take(segments, count)}
        assert {:ok, ^prefix} = Path.parse(Path.format(prefix))
      end
    end
  end
end
