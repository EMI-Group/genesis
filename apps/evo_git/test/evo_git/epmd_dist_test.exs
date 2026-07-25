defmodule EvoGit.EpmdDistTest do
  use ExUnit.Case, async: true

  alias EvoGit.EpmdDist

  describe "port_please/2 and register_target/2 round-trip" do
    test "returns noport for unregistered node" do
      assert :noport = EpmdDist.port_please(:unregistered, ~c"127.0.0.1")
      assert :noport = EpmdDist.port_please(:"unregistered@127.0.0.1", ~c"127.0.0.1")
    end

    test "returns registered port when VM passes only the short name" do
      # The VM splits the node name at @ and calls port_please with just the
      # name part. This is the core scenario the fix addresses.
      node_str = "test_epmd_node@127.0.0.1"
      assert :ok = EpmdDist.register_target(node_str, 12345)

      # VM passes just the name part as a string — primary case
      assert {:port, 12345, 5} = EpmdDist.port_please("test_epmd_node", "127.0.0.1")
    after
      EpmdDist.unregister_target("test_epmd_node@127.0.0.1")
    end

    test "returns registered port when VM passes the full node atom" do
      node_str = "test_full_atom@127.0.0.1"
      assert :ok = EpmdDist.register_target(node_str, 12345)
      assert {:port, 12345, 5} = EpmdDist.port_please(:"test_full_atom@127.0.0.1", ~c"127.0.0.1")
    after
      EpmdDist.unregister_target("test_full_atom@127.0.0.1")
    end

    test "returns registered port when VM passes the short name as an atom" do
      node_str = "test_short_atom@127.0.0.1"
      assert :ok = EpmdDist.register_target(node_str, 12345)
      # Atom form of just the name part (before @)
      assert {:port, 12345, 5} = EpmdDist.port_please(:test_short_atom, "127.0.0.1")
    after
      EpmdDist.unregister_target("test_short_atom@127.0.0.1")
    end

    test "returns registered port when VM passes the short name as a charlist" do
      node_str = "test_charlist@127.0.0.1"
      assert :ok = EpmdDist.register_target(node_str, 12345)
      # Charlist form of just the name part — this simulates what the Erlang
      # VM actually passes to the port_please callback.
      assert {:port, 12345, 5} = EpmdDist.port_please(~c"test_charlist", "127.0.0.1")
    after
      EpmdDist.unregister_target("test_charlist@127.0.0.1")
    end

    test "returns registered port when VM passes the full node name as a charlist" do
      node_str = "test_full_charlist@127.0.0.1"
      assert :ok = EpmdDist.register_target(node_str, 12345)
      assert {:port, 12345, 5} = EpmdDist.port_please(~c"test_full_charlist@127.0.0.1", "127.0.0.1")
    after
      EpmdDist.unregister_target("test_full_charlist@127.0.0.1")
    end
  end

  describe "unregister_target/1" do
    test "removes the registration so port_please returns noport" do
      node_str = "test_unregister@127.0.0.1"
      EpmdDist.register_target(node_str, 54321)

      # Both short and full name forms resolve before unregister
      assert {:port, 54321, 5} = EpmdDist.port_please(:test_unregister, ~c"127.0.0.1")
      assert {:port, 54321, 5} = EpmdDist.port_please(:"test_unregister@127.0.0.1", ~c"127.0.0.1")

      assert :ok = EpmdDist.unregister_target(node_str)

      # After unregister, both forms return noport
      assert :noport = EpmdDist.port_please(:test_unregister, ~c"127.0.0.1")
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
