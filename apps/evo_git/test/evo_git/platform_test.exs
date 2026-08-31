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

    test "returns true for forward-slash UNC paths" do
      assert Platform.absolute_path?("//wsl.localhost/Ubuntu-22.04/x")
      assert Platform.absolute_path?("//server/share")
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

  describe "unc?/1" do
    test "returns true for forward-slash UNC paths" do
      assert Platform.unc?("//wsl.localhost/Ubuntu-22.04/x")
      assert Platform.unc?("//server/share")
    end

    test "returns true for backslash UNC paths" do
      assert Platform.unc?("\\\\server\\share\\x")
    end

    test "returns true for mixed double-separator prefixes" do
      assert Platform.unc?("/\\/foo")
      assert Platform.unc?("\\//x")
    end

    test "returns false for non-UNC paths" do
      refute Platform.unc?("/foo")
      refute Platform.unc?("foo/bar")
      refute Platform.unc?("C:\\x")
    end

    test "returns false for nil and non-binary values" do
      refute Platform.unc?(nil)
      refute Platform.unc?(123)
    end
  end

  describe "unc_path?/1" do
    test "returns true for forward-slash UNC share paths" do
      assert Platform.unc_path?("//wsl.localhost/Ubuntu-22.04/home/user/proj")
      assert Platform.unc_path?("//server/share")
      assert Platform.unc_path?("//server/share/x")
    end

    test "returns true for backslash UNC share paths" do
      assert Platform.unc_path?("\\\\server\\share\\x")
      assert Platform.unc_path?("\\\\server\\share")
    end

    test "returns false for bare UNC markers without a share component" do
      refute Platform.unc_path?("//foo")
      refute Platform.unc_path?("\\\\server")
    end

    test "returns false for non-UNC and relative paths" do
      refute Platform.unc_path?("/foo/bar")
      refute Platform.unc_path?("foo/bar")
      refute Platform.unc_path?("C:\\x")
    end

    test "returns false for nil and non-binary values" do
      refute Platform.unc_path?(nil)
      refute Platform.unc_path?(123)
    end
  end

  describe "safe_expand/1" do
    test "preserves the UNC marker on non-UNC-collapsing inputs" do
      # Holds on every host: Windows `Path.expand` keeps the `//` root,
      # non-Windows `safe_expand` re-attaches it.
      assert Platform.safe_expand("//wsl.localhost/Ubuntu-22.04/x") ==
               "//wsl.localhost/Ubuntu-22.04/x"

      assert Platform.safe_expand("\\\\server\\share\\x") == "\\\\server\\share\\x"
    end

    test "resolves dot segments while preserving the UNC marker" do
      assert Platform.safe_expand("//wsl.localhost/Ubuntu-22.04/home/../proj") ==
               "//wsl.localhost/Ubuntu-22.04/proj"

      assert Platform.safe_expand("//wsl.localhost/Ubuntu-22.04/proj/./src") ==
               "//wsl.localhost/Ubuntu-22.04/proj/src"
    end

    test "strips trailing separators while preserving the UNC marker" do
      assert Platform.safe_expand("//wsl.localhost/Ubuntu-22.04/proj/") ==
               "//wsl.localhost/Ubuntu-22.04/proj"
    end

    test "behaves like Path.expand/1 for non-UNC paths" do
      assert Platform.safe_expand("/tmp/foo/") == "/tmp/foo"
      assert Platform.safe_expand("/a/../b") == "/b"
    end
  end

  describe "safe_expand/2" do
    test "resolves a relative path against a UNC base preserving the marker" do
      assert Platform.safe_expand("x", "//wsl.localhost/Ubuntu-22.04/home") ==
               "//wsl.localhost/Ubuntu-22.04/home/x"

      assert Platform.safe_expand("../x", "//wsl.localhost/Ubuntu-22.04/home") ==
               "//wsl.localhost/Ubuntu-22.04/x"
    end

    test "expands an absolute path on its own, ignoring the base" do
      assert Platform.safe_expand("//wsl.localhost/other", "/base") == "//wsl.localhost/other"
      assert Platform.safe_expand("/abs/x", "/base") == "/abs/x"
    end

    test "behaves like Path.expand/2 for non-UNC bases" do
      assert Platform.safe_expand("x", "/tmp/base") == "/tmp/base/x"
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

    test "preserves the double-separator marker for mixed leading separators" do
      # `/\/foo` normalizes to `///foo` — a double-separator UNC marker — so
      # the first two separators survive and only the rest are trimmed.
      assert Platform.trim_leading_separators("/\\/foo") == "/\\foo"
    end

    test "preserves a forward-slash UNC marker" do
      assert Platform.trim_leading_separators("//wsl.localhost/x") == "//wsl.localhost/x"
    end

    test "trims separators beyond the preserved UNC marker" do
      assert Platform.trim_leading_separators("///x") == "//x"
    end

    test "preserves a backslash UNC marker" do
      assert Platform.trim_leading_separators("\\\\server\\share\\x") == "\\\\server\\share\\x"
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

    test "preserves the double-separator marker with mixed separators on both ends" do
      assert Platform.trim_separators("/\\foo/bar\\/") == "/\\foo/bar"
    end

    test "preserves a UNC marker while trimming trailing separators" do
      assert Platform.trim_separators("//wsl/x/") == "//wsl/x"
      assert Platform.trim_separators("\\\\server\\share\\x\\") == "\\\\server\\share\\x"
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

    test "drops the UNC marker so the share host is the first element" do
      assert Platform.split_path("//wsl.localhost/Ubuntu-22.04/x", []) ==
               ["wsl.localhost", "Ubuntu-22.04", "x"]

      assert Platform.split_path("//wsl.localhost/Ubuntu-22.04/x", parts: 2) ==
               ["wsl.localhost", "Ubuntu-22.04/x"]
    end

    test "splits backslash UNC paths like their forward-slash form" do
      assert Platform.split_path("\\\\wsl.localhost\\Ubuntu-22.04\\x", []) ==
               ["wsl.localhost", "Ubuntu-22.04", "x"]
    end

    test "parts: 2 on a backslash UNC form keeps the share host as the first element" do
      # The first element is the share host — never a bogus "" segment.
      assert Platform.split_path("\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\proj", parts: 2) ==
               ["wsl.localhost", "Ubuntu-22.04/home/user/proj"]
    end

    test "leaves non-UNC absolute paths unchanged" do
      assert Platform.split_path("/foo", []) == ["", "foo"]
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

  describe "bwrap_available?/0" do
    test "returns a boolean" do
      assert is_boolean(Platform.bwrap_available?())
    end

    test "when true, the platform is Linux" do
      # bwrap is Linux-only by definition — a true result implies linux?().
      if Platform.bwrap_available?() do
        assert Platform.linux?()
      end
    end
  end

  describe "sandbox_backend/0" do
    # Host-dependent by design (availability probing); never assert a specific
    # backend. Pin the environment-agnostic decision chain instead.
    test "returns one of the known backend atoms" do
      assert Platform.sandbox_backend() in [:systemd_run, :bwrap, :sandbox_exec, :none]
    end

    test "follows the availability priority chain" do
      backend = Platform.sandbox_backend()

      cond do
        Platform.systemd_available?() -> assert backend == :systemd_run
        Platform.bwrap_available?() -> assert backend == :bwrap
        Platform.sandbox_exec_available?() -> assert backend == :sandbox_exec
        true -> assert backend == :none
      end
    end
  end
end
