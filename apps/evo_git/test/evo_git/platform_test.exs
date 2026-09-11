defmodule EvoGit.PlatformTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
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

  describe "cpu_threads/0" do
    # Contract test against the OTP primitive itself — deliberately NOT
    # derived from EvoGit.Platform.cpu_threads via any schema default, so a
    # silent regression to a constant cannot pass both.
    test "equals System.schedulers_online/0 clamped to a minimum of 1" do
      assert Platform.cpu_threads() == max(System.schedulers_online(), 1)
    end

    test "is always a positive integer" do
      threads = Platform.cpu_threads()
      assert is_integer(threads)
      assert threads >= 1
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

  describe "data_dir/0 with [data] dir config" do
    # These tests flip XDG_CONFIG_HOME / XDG_DATA_HOME and write tmp
    # config.toml files, so this module is async: false. Each tmp dir is
    # unique, and the Config file cache is keyed per path, so env flips
    # isolate cleanly.

    # Points XDG_CONFIG_HOME at a fresh tmp dir and (optionally) writes a
    # config.toml there; restores the environment and cleans up afterwards.
    defp with_tmp_config(nil, fun), do: with_tmp_config("", fun)

    defp with_tmp_config(contents, fun) when is_binary(contents) do
      original_xdg = System.get_env("XDG_CONFIG_HOME")

      tmp_xdg =
        Path.join(
          System.tmp_dir!(),
          "evogit-platform-config-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp_xdg, "genesis"))

      if contents != "" do
        File.write!(Path.join([tmp_xdg, "genesis", "config.toml"]), contents)
      end

      System.put_env("XDG_CONFIG_HOME", tmp_xdg)

      try do
        fun.()
      after
        if original_xdg do
          System.put_env("XDG_CONFIG_HOME", original_xdg)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf!(tmp_xdg)
      end
    end

    # Temporarily points XDG_DATA_HOME at a fresh tmp dir (the fallback
    # default's source on Linux) and restores it afterwards.
    defp with_tmp_data_home(fun) do
      original_data = System.get_env("XDG_DATA_HOME")

      tmp_data =
        Path.join(
          System.tmp_dir!(),
          "evogit-platform-data-#{System.unique_integer([:positive])}"
        )

      System.put_env("XDG_DATA_HOME", tmp_data)

      try do
        fun.(tmp_data)
      after
        if original_data do
          System.put_env("XDG_DATA_HOME", original_data)
        else
          System.delete_env("XDG_DATA_HOME")
        end
      end
    end

    # The platform-default data dir formula for the CURRENT OS, mirroring
    # `base_dir/3` semantics (data_dir("genesis") is pure OS + env).
    defp default_data_dir do
      case Platform.os() do
        os when os in [:linux, :unknown] ->
          Path.join(
            System.get_env("XDG_DATA_HOME", Path.join(System.user_home!(), ".local/share")),
            "genesis"
          )

        :macos ->
          Path.join([System.user_home!(), "Library", "Application Support", "genesis"])

        :windows ->
          appdata = System.get_env("APPDATA")
          base = if appdata && appdata != "", do: appdata, else: System.user_home!()
          Path.join(base, "genesis")
      end
    end

    test "returns the configured [data] dir absolute path" do
      target =
        Path.join(
          System.tmp_dir!(),
          "evogit-relocated-#{System.unique_integer([:positive])}"
        )

      # Forward slashes keep the TOML basic string valid on every OS
      # (a Windows backslash would be an invalid escape).
      toml_dir = String.replace(target, "\\", "/")

      with_tmp_config("[data]\ndir = \"#{toml_dir}\"\n", fn ->
        assert Platform.data_dir() == Path.expand(target)
      end)
    end

    test "returns the platform default when no [data] dir key is set" do
      # A config.toml exists but carries no [data] section.
      with_tmp_config("[user]\ngithub_username = \"test\"\n", fn ->
        with_tmp_data_home(fn _tmp_data ->
          # XDG_DATA_HOME must not influence macOS/Windows defaults; the
          # formula below mirrors base_dir/3 per OS.
          assert Platform.data_dir() == default_data_dir()
        end)
      end)
    end

    test "expands a ~/ home-relative [data] dir" do
      with_tmp_config("[data]\ndir = \"~/some/subdir\"\n", fn ->
        dir = Platform.data_dir()
        normalized = String.replace(dir, "\\", "/")
        assert String.ends_with?(normalized, "/some/subdir")
        refute String.starts_with?(normalized, "~")
      end)
    end

    test "ignores an invalid relative [data] dir, logs a warning, and falls back" do
      with_tmp_config("[data]\ndir = \"relative/path\"\n", fn ->
        with_tmp_data_home(fn _tmp_data ->
          log =
            capture_log(fn ->
              assert Platform.data_dir() == default_data_dir()
            end)

          assert log =~ "[data] dir"
        end)
      end)
    end

    test "treats an empty-string [data] dir as unset (platform default)" do
      with_tmp_config("[data]\ndir = \"\"\n", fn ->
        with_tmp_data_home(fn _tmp_data ->
          assert Platform.data_dir() == default_data_dir()
        end)
      end)
    end
  end
end
