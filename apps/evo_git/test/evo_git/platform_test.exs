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
end
