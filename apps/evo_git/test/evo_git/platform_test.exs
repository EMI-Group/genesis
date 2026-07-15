defmodule EvoGit.PlatformTest do
  use ExUnit.Case, async: true
  alias EvoGit.Platform

  describe "absolute_path?/1" do
    test "returns true for Unix absolute paths" do
      assert Platform.absolute_path?("/home/user/project")
      assert Platform.absolute_path?("/")
    end

    test "returns true for Windows absolute paths with backslashes" do
      assert Platform.absolute_path?("C:\\Users\\project")
      assert Platform.absolute_path?("D:\\")
    end

    test "returns true for Windows absolute paths with forward slashes" do
      assert Platform.absolute_path?("C:/Users/project")
      assert Platform.absolute_path?("D:/")
    end

    test "returns true for UNC paths" do
      assert Platform.absolute_path?("\\\\server\\share\\file")
      assert Platform.absolute_path?("\\\\server\\share")
    end

    test "returns false for relative paths" do
      refute Platform.absolute_path?("./src/main.ex")
      refute Platform.absolute_path?("src/main.ex")
      refute Platform.absolute_path?("foo/bar")
    end

    test "returns false for nil and non-binary values" do
      refute Platform.absolute_path?(nil)
      refute Platform.absolute_path?(123)
    end
  end

  describe "path_under?/2" do
    test "returns true when child equals parent" do
      assert Platform.path_under?("/foo/bar", "/foo/bar")
      assert Platform.path_under?("C:\\foo\\bar", "C:\\foo\\bar")
    end

    test "returns true when child is a direct sub-path" do
      assert Platform.path_under?("/foo/bar/baz", "/foo/bar")
      assert Platform.path_under?("C:\\foo\\bar\\baz", "C:\\foo\\bar")
    end

    test "returns true with mixed separators" do
      assert Platform.path_under?("C:\\foo\\bar\\baz", "C:/foo/bar")
      assert Platform.path_under?("C:/foo/bar/baz", "C:\\foo\\bar")
    end

    test "returns false when child is not under parent" do
      refute Platform.path_under?("/other/bar", "/foo/bar")
      refute Platform.path_under?("/foo/bart", "/foo/bar")
      refute Platform.path_under?("C:\\other\\bar", "C:\\foo\\bar")
    end
  end

  describe "path_next_is_separator?/2" do
    test "returns true when next char is /" do
      assert Platform.path_next_is_separator?("/foo/bar", 0)
      assert Platform.path_next_is_separator?("base/child", 4)
    end

    test "returns true when next char is backslash" do
      assert Platform.path_next_is_separator?("C:\\foo", 2)
    end

    test "returns false when next char is not a separator" do
      refute Platform.path_next_is_separator?("basechild", 4)
    end

    test "returns false when prefix_len is at end of string" do
      refute Platform.path_next_is_separator?("foo", 3)
    end

    test "returns false when prefix_len exceeds string length" do
      refute Platform.path_next_is_separator?("foo", 10)
    end
  end

  describe "normalize_separators/1" do
    test "converts Windows backslash to forward slash" do
      assert Platform.normalize_separators("src\\lib\\app.ex") == "src/lib/app.ex"
    end

    test "handles mixed separators" do
      assert Platform.normalize_separators("src\\lib/app.ex") == "src/lib/app.ex"
    end

    test "passes through already-normalized paths" do
      assert Platform.normalize_separators("src/lib/app.ex") == "src/lib/app.ex"
    end

    test "returns nil for nil" do
      assert Platform.normalize_separators(nil) == nil
    end
  end

  describe "trim_leading_separators/1" do
    test "strips leading forward slash" do
      assert Platform.trim_leading_separators("/foo/bar") == "foo/bar"
    end

    test "strips leading backslash" do
      assert Platform.trim_leading_separators("\\foo\\bar") == "foo\\bar"
    end

    test "strips multiple mixed leading separators" do
      assert Platform.trim_leading_separators("/\\/foo") == "foo"
    end

    test "returns unchanged when no leading separator" do
      assert Platform.trim_leading_separators("foo/bar") == "foo/bar"
    end

    test "returns nil for nil" do
      assert Platform.trim_leading_separators(nil) == nil
    end
  end

  describe "trim_trailing_separators/1" do
    test "strips trailing forward slash" do
      assert Platform.trim_trailing_separators("foo/bar/") == "foo/bar"
    end

    test "strips trailing backslash" do
      assert Platform.trim_trailing_separators("foo\\bar\\") == "foo\\bar"
    end

    test "strips multiple mixed trailing separators" do
      assert Platform.trim_trailing_separators("foo/\\/") == "foo"
    end

    test "returns unchanged when no trailing separator" do
      assert Platform.trim_trailing_separators("foo/bar") == "foo/bar"
    end

    test "returns nil for nil" do
      assert Platform.trim_trailing_separators(nil) == nil
    end
  end

  describe "trim_separators/1" do
    test "strips both leading and trailing separators" do
      assert Platform.trim_separators("/foo/bar/") == "foo/bar"
    end

    test "strips backslashes on both ends" do
      assert Platform.trim_separators("\\foo\\bar\\") == "foo\\bar"
    end

    test "strips mixed separators on both ends" do
      assert Platform.trim_separators("/\\foo/bar\\/") == "foo/bar"
    end

    test "returns unchanged when no separators on either end" do
      assert Platform.trim_separators("foo/bar") == "foo/bar"
    end

    test "returns nil for nil" do
      assert Platform.trim_separators(nil) == nil
    end
  end

  describe "split_path/2" do
    test "splits on forward slash" do
      assert Platform.split_path("foo/bar/baz", []) == ["foo", "bar", "baz"]
    end

    test "splits on backslash after normalization" do
      assert Platform.split_path("foo\\bar\\baz", []) == ["foo", "bar", "baz"]
    end

    test "splits on mixed separators" do
      assert Platform.split_path("foo/bar\\baz", []) == ["foo", "bar", "baz"]
    end

    test "respects parts option" do
      assert Platform.split_path("foo/bar/baz", parts: 2) == ["foo", "bar/baz"]
    end

    test "returns nil for nil" do
      assert Platform.split_path(nil, []) == nil
    end

    test "returns empty list for empty string" do
      assert Platform.split_path("", []) == []
    end
  end

  describe "trailing_separator?/1" do
    test "returns true for trailing forward slash" do
      assert Platform.trailing_separator?("foo/")
    end

    test "returns true for trailing backslash" do
      assert Platform.trailing_separator?("foo\\")
    end

    test "returns false for path without trailing separator" do
      refute Platform.trailing_separator?("foo/bar")
    end

    test "returns false for nil" do
      refute Platform.trailing_separator?(nil)
    end
  end
end
