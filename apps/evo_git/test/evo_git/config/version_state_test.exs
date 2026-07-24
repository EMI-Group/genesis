defmodule EvoGit.Config.VersionStateTest do
  use ExUnit.Case, async: false

  alias EvoGit.Config.VersionState

  # Tests mutate the XDG_CONFIG_HOME env var so that VersionState never
  # touches the real ~/.config/genesis/ directory.
  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  describe "get_version/0" do
    test "returns default \"0.8.0\" when the file does not exist" do
      refute File.exists?(VersionState.path())
      assert VersionState.get_version() == "0.8.0"
    end

    test "returns the recorded version after saving" do
      assert :ok = VersionState.save_version("1.2.3")
      assert VersionState.get_version() == "1.2.3"
    end
  end

  describe "current_version/0" do
    test "returns a non-empty version string from Application.spec" do
      version = VersionState.current_version()
      assert is_binary(version)
      assert version != ""
    end
  end

  describe "save_version/1" do
    test "persists the given version and returns :ok" do
      assert :ok = VersionState.save_version("2.0.0")
      assert VersionState.get_version() == "2.0.0"
    end

    test "round-trips with get_version/0" do
      versions = ["0.8.0", "0.9.1", "1.0.0", "10.20.30"]

      for version <- versions do
        assert :ok = VersionState.save_version(version)
        assert VersionState.get_version() == version
      end
    end

    test "overwrites a previously-saved version" do
      assert :ok = VersionState.save_version("1.0.0")
      assert VersionState.get_version() == "1.0.0"

      assert :ok = VersionState.save_version("2.0.0")
      assert VersionState.get_version() == "2.0.0"
    end
  end

  describe "save_version/0 (no argument)" do
    test "persists current_version/0" do
      assert :ok = VersionState.save_version()
      assert VersionState.get_version() == VersionState.current_version()
    end
  end

  describe "upgraded?/0" do
    test "returns false when recorded version equals current version" do
      assert :ok = VersionState.save_version(VersionState.current_version())
      refute VersionState.upgraded?()
    end

    test "returns true when recorded version differs from current" do
      assert :ok = VersionState.save_version("0.0.1-sentinel")
      assert VersionState.upgraded?()
    end

    test "returns false when no file exists and current version is the default" do
      # When the file is absent, get_version defaults to "0.8.0".
      # If the runtime version also happens to be "0.8.0", upgraded? is false.
      current = VersionState.current_version()

      if current == "0.8.0" do
        refute VersionState.upgraded?()
      else
        assert VersionState.upgraded?()
      end
    end
  end

  describe "record_current_version/0" do
    test "persists the current version and returns :ok" do
      assert :ok = VersionState.record_current_version()
      assert VersionState.get_version() == VersionState.current_version()
    end

    test "after recording, upgraded? is false" do
      assert :ok = VersionState.record_current_version()
      refute VersionState.upgraded?()
    end
  end
end
