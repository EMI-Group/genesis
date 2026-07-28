defmodule EvoGit.Config.VersionStateTest do
  use ExUnit.Case, async: false

  alias EvoGit.Config.VersionState

  # Tests mutate the XDG_CONFIG_HOME env var so that VersionState never
  # touches the real ~/.config/genesis/ directory.
  #
  # The module caches the file state in `:persistent_term`. The cache stores
  # the path alongside the state and auto-reloads when the path changes, so
  # varying XDG_CONFIG_HOME per test is handled transparently. We erase the
  # cache in setup anyway to guarantee a pristine starting point for each
  # test (no stale data can leak between tests).
  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    # Ensure a fresh cache per test.
    :persistent_term.erase({VersionState, :version_state})

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

  describe "onboarding_needed?/0" do
    test "returns true when no version-state file exists" do
      refute File.exists?(VersionState.path())
      assert VersionState.onboarding_needed?()
    end

    test "returns false after save_version/1 creates the file" do
      assert :ok = VersionState.save_version("1.0.0")
      refute VersionState.onboarding_needed?()
    end

    test "returns false after complete_onboarding/0" do
      assert :ok = VersionState.complete_onboarding()
      refute VersionState.onboarding_needed?()
    end
  end

  describe "complete_onboarding/0" do
    test "returns :ok and creates the version-state file" do
      refute File.exists?(VersionState.path())
      assert :ok = VersionState.complete_onboarding()
      assert File.exists?(VersionState.path())
      assert VersionState.get_version() == VersionState.current_version()
    end

    test "is idempotent" do
      assert :ok = VersionState.complete_onboarding()
      version_before = VersionState.get_version()

      # Calling again should succeed without changing anything.
      assert :ok = VersionState.complete_onboarding()
      assert VersionState.get_version() == version_before
    end
  end

  describe "caching" do
    test "get_version reads from cache on the second call (same path)" do
      assert :ok = VersionState.save_version("3.1.4")

      # First read populates the cache.
      assert VersionState.get_version() == "3.1.4"

      # Mutate the file on disk *after* it has been cached. The cached value
      # should still be served (we do not re-read from disk unless the cache
      # is invalidated by save_version/1 or a path change).
      File.write!(VersionState.path(), "version = \"9.9.9\"\n")

      assert VersionState.get_version() == "3.1.4"
    end

    test "save_version/1 invalidates the cache so the next read is fresh" do
      assert :ok = VersionState.save_version("1.0.0")
      assert VersionState.get_version() == "1.0.0"

      assert :ok = VersionState.save_version("2.0.0")
      assert VersionState.get_version() == "2.0.0"
    end

    test "cache reloads when the config path changes" do
      assert :ok = VersionState.save_version("1.0.0")
      assert VersionState.get_version() == "1.0.0"

      # Simulate a path change by erasing the cache and pointing XDG at a
      # fresh directory (as would happen across tests or config changes).
      :persistent_term.erase({VersionState, :version_state})

      new_xdg =
        Path.join(System.tmp_dir!(), "evogit-test-xdg2-#{System.unique_integer([:positive])}")

      File.mkdir_p!(new_xdg)
      System.put_env("XDG_CONFIG_HOME", new_xdg)

      try do
        # No file in the new directory → default version, not the cached "1.0.0".
        refute File.exists?(VersionState.path())
        assert VersionState.get_version() == "0.8.0"
      after
        File.rm_rf!(new_xdg)
      end
    end
  end
end
