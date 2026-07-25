defmodule EvoGit.EpmdDistTest do
  use ExUnit.Case, async: true

  alias EvoGit.EpmdDist

  describe "port_please/2 and register_target/2 round-trip" do
    test "returns noport for unregistered node" do
      assert :noport = EpmdDist.port_please(:"unregistered@127.0.0.1", ~c"127.0.0.1")
    end

    test "returns registered port after register_target" do
      node_str = "test_epmd_node@127.0.0.1"
      assert :ok = EpmdDist.register_target(node_str, 12345)
      assert {:port, 12345, 5} = EpmdDist.port_please(:"test_epmd_node@127.0.0.1", ~c"127.0.0.1")
    after
      EpmdDist.unregister_target("test_epmd_node@127.0.0.1")
    end
  end

  describe "unregister_target/1" do
    test "removes the registration" do
      node_str = "test_unregister@127.0.0.1"
      EpmdDist.register_target(node_str, 54321)
      assert {:port, 54321, 5} = EpmdDist.port_please(:"test_unregister@127.0.0.1", ~c"127.0.0.1")
      assert :ok = EpmdDist.unregister_target(node_str)
      assert :noport = EpmdDist.port_please(:"test_unregister@127.0.0.1", ~c"127.0.0.1")
    end

    test "is safe to call for unregistered node" do
      assert :ok = EpmdDist.unregister_target("never_registered@127.0.0.1")
    end
  end

  describe "names/1" do
    test "returns empty list" do
      assert {:ok, []} = EpmdDist.names(~c"127.0.0.1")
    end
  end

  describe "start_link/0" do
    test "returns ignore" do
      assert :ignore = EpmdDist.start_link()
    end
  end
end
