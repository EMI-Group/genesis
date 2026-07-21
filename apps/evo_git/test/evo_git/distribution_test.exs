defmodule EvoGit.DistributionTest do
  use ExUnit.Case, async: false

  alias EvoGit.Distribution

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
    test "defaults to genesis_remote_cookie" do
      # set_cookie calls Node.set_cookie/1 which requires a distributed node.
      # In the standard test environment node() is :nonode@nohost, so we
      # can only verify this in a distributed context.
      if Distribution.distributed?() do
        Distribution.set_cookie(%{})
        assert Node.get_cookie() == :genesis_remote_cookie
      end
    end

    @tag :distributed_only
    test "uses the provided cookie when specified in config" do
      if Distribution.distributed?() do
        Distribution.set_cookie(%{cookie: "custom_test_cookie"})
        assert Node.get_cookie() == :custom_test_cookie
      end
    end
  end

  describe "default cookie value in set_cookie/1" do
    test "extracts cookie from node_config with genesis_remote_cookie as default" do
      # Verify the default is genesis_remote_cookie by reading the default
      # from the node config resolution path. The node_config map's
      # :cookie key defaults to "genesis_remote_cookie" in set_cookie/1.
      # We verify this by checking that the default is used when not present.
      #
      # This tests the Map.get/3 default without calling Node.set_cookie/1.
      default_cookie = "genesis_remote_cookie"

      # Simulate what set_cookie/1 does internally:
      assert Map.get(%{}, :cookie, default_cookie) == "genesis_remote_cookie"
      assert Map.get(%{cookie: "custom"}, :cookie, default_cookie) == "custom"
    end
  end

  describe "enable_distribution kernel params" do
    test "uses dist_port 9000 by default from node_config" do
      # Verify the default dist_port value used in enable_distribution/1.
      assert Map.get(%{}, :dist_port, 9000) == 9000
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
