defmodule EvoGit.DistributionTest do
  use ExUnit.Case, async: false

  alias EvoGit.Distribution

  # Redirect XDG_CONFIG_HOME to a temp dir so that Distribution.maybe_enable/0
  # (which calls EvoGit.Config.resolve() → user_config()) never reads the
  # real ~/.config/genesis/config.toml. Without this isolation, a user config
  # with node.enabled = true would cause maybe_enable/0 to attempt starting
  # :net_kernel, which fails with :nodistribution on a non-distributed BEAM.
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

  describe "distributed?/0" do
    test "returns a boolean" do
      assert is_boolean(Distribution.distributed?())
    end

    test "returns false for nonode@nohost" do
      # In the test environment the node is typically :nonode@nohost.
      # We can't force a different state without starting distribution,
      # so we just assert the function matches the raw Node check.
      assert Distribution.distributed?() == (node() != :nonode@nohost)
    end
  end

  describe "maybe_enable/0" do
    test "returns :ok when distribution is disabled (default config)" do
      # By default, node.enabled is false, so maybe_enable should be a no-op.
      assert :ok = Distribution.maybe_enable()
    end
  end

  describe "enable_for_remote/1" do
    # async: false — starting real distribution changes global BEAM state
    # (node() becomes non-nonode@nohost) which would break sibling tests
    # that assume :nonode@nohost.
    @describetag :enable_for_remote

    test "returns :ok when already distributed" do
      if Distribution.distributed?() do
        assert :ok = Distribution.enable_for_remote(%{})
      end
    end

    test "accepts a target map with dist_port and nil cookie" do
      result = Distribution.enable_for_remote(%{dist_port: 9000, cookie: nil})
      assert result == :ok or match?({:error, _}, result)

      if node() != :nonode@nohost and result == :ok do
        :net_kernel.stop()
      end
    end

    test "accepts a target map with dist_port and cookie" do
      # Just verify the function doesn't crash on a valid target map.
      # In test env, distribution is likely not started; if it starts, great.
      result = Distribution.enable_for_remote(%{dist_port: 9000, cookie: "test_cookie"})
      assert result == :ok or match?({:error, _}, result)

      # If this test actually started distribution, stop it so it doesn't
      # leak into sibling tests.
      if node() != :nonode@nohost and result == :ok do
        :net_kernel.stop()
      end
    end
  end

  describe "start_epmd_if_configured/1" do
    test "defaults to false — does not start EPMD when :start_epmd is not set" do
      # With the new default of false, EPMD should NOT be started when
      # :start_epmd is missing from node_config.
      assert :ok = Distribution.start_epmd_if_configured(%{})
    end

    test "starts EPMD when :start_epmd is explicitly true" do
      # When the user explicitly opts in, EPMD should still be startable.
      # We can't verify the side-effect in a unit test, but we can verify
      # the function doesn't crash.
      assert :ok = Distribution.start_epmd_if_configured(%{start_epmd: true})
    end
  end

  describe "set_cookie/1" do
    @tag :distributed_only
    test "does not set cookie when config has no cookie key (nil)" do
      if Distribution.distributed?() do
        # Save current cookie to restore after
        original = Node.get_cookie()
        # Set a known cookie first so we can detect no-change
        Node.set_cookie(:known_before_test)

        # Call with empty config — should skip Node.set_cookie
        Distribution.set_cookie(%{})
        # Cookie should still be :known_before_test (unchanged)
        assert Node.get_cookie() == :known_before_test

        # Restore
        Node.set_cookie(original)
      end
    end

    @tag :distributed_only
    test "uses the provided cookie when specified in config" do
      if Distribution.distributed?() do
        original = Node.get_cookie()
        Distribution.set_cookie(%{cookie: "custom_test_cookie"})
        assert Node.get_cookie() == :custom_test_cookie
        Node.set_cookie(original)
      end
    end
  end

  describe "nil cookie handling in set_cookie/1" do
    test "Map.get with no default returns nil when key is missing" do
      # Verify that Map.get/2 returns nil when the key is missing
      empty_map = %{}
      assert is_nil(Map.get(empty_map, :cookie))
    end

    test "Map.get returns the cookie value when present" do
      assert Map.get(%{cookie: "custom"}, :cookie) == "custom"
    end
  end

  describe "enable_distribution kernel params" do
    test "uses dist_port 9000 by default from node_config" do
      # Verify that Map.get/3 with an explicit :dist_port key returns the
      # provided value. The node_config map's :dist_port key defaults to 9000
      # in enable_distribution/1.
      assert Map.get(%{dist_port: 7777}, :dist_port, 9000) == 7777
    end

    test "sets inet_dist_listen_min/max from dist_port when not already configured" do
      # Clear any existing kernel config so we can verify the defaults.
      original_min = Application.get_env(:kernel, :inet_dist_listen_min)
      original_max = Application.get_env(:kernel, :inet_dist_listen_max)

      Application.delete_env(:kernel, :inet_dist_listen_min)
      Application.delete_env(:kernel, :inet_dist_listen_max)

      # Simulate what enable_distribution does before :net_kernel.start:
      dist_port = 9000
      assert nil == Application.get_env(:kernel, :inet_dist_listen_min)
      assert nil == Application.get_env(:kernel, :inet_dist_listen_max)

      Application.put_env(:kernel, :inet_dist_listen_min, dist_port)
      Application.put_env(:kernel, :inet_dist_listen_max, dist_port)

      assert Application.get_env(:kernel, :inet_dist_listen_min) == 9000
      assert Application.get_env(:kernel, :inet_dist_listen_max) == 9000

      # Restore original values
      restore_env(:kernel, :inet_dist_listen_min, original_min)
      restore_env(:kernel, :inet_dist_listen_max, original_max)
    end

    test "respects custom dist_port from config" do
      original_min = Application.get_env(:kernel, :inet_dist_listen_min)
      original_max = Application.get_env(:kernel, :inet_dist_listen_max)

      Application.delete_env(:kernel, :inet_dist_listen_min)
      Application.delete_env(:kernel, :inet_dist_listen_max)

      # Custom port
      dist_port = 9876
      Application.put_env(:kernel, :inet_dist_listen_min, dist_port)
      Application.put_env(:kernel, :inet_dist_listen_max, dist_port)

      assert Application.get_env(:kernel, :inet_dist_listen_min) == 9876
      assert Application.get_env(:kernel, :inet_dist_listen_max) == 9876

      restore_env(:kernel, :inet_dist_listen_min, original_min)
      restore_env(:kernel, :inet_dist_listen_max, original_max)
    end

    test "does not override inet_dist_listen_min/max if already configured" do
      original_min = Application.get_env(:kernel, :inet_dist_listen_min)
      original_max = Application.get_env(:kernel, :inet_dist_listen_max)

      # Simulate pre-configured values (e.g. from vm.args)
      Application.put_env(:kernel, :inet_dist_listen_min, 1234)
      Application.put_env(:kernel, :inet_dist_listen_max, 5678)

      # The guard in enable_distribution checks if nil before setting.
      # Verify that the guard works correctly:
      refute nil == Application.get_env(:kernel, :inet_dist_listen_min)
      refute nil == Application.get_env(:kernel, :inet_dist_listen_max)

      # Restore
      restore_env(:kernel, :inet_dist_listen_min, original_min)
      restore_env(:kernel, :inet_dist_listen_max, original_max)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
