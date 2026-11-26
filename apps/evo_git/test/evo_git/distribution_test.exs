defmodule EvoGit.DistributionTest do
  # Only the bare peer changes node identity, kernel env or cookies.
  use ExUnit.Case, async: true

  alias EvoGit.Distribution
  alias EvoGit.TestSupport.ConfigDir

  test "maybe_enable/0 is a no-op with the default config" do
    ConfigDir.isolate!("evogit-distribution")
    before = Distribution.active()

    assert :ok = Distribution.maybe_enable()
    assert Distribution.active() == before
  end

  test "enable_runtime/3 rejects invalid inputs before starting distribution" do
    assert {:error, {:invalid_node_name, "no-at-sign"}} =
             Distribution.enable_runtime("no-at-sign", "cookie", 9123)

    assert {:error, {:invalid_node_name, ""}} =
             Distribution.enable_runtime("", "cookie", 9123)

    assert {:error, {:invalid_dist_port, 0}} =
             Distribution.enable_runtime("genesis_runtime_test@127.0.0.1", "cookie", 0)
  end

  test "runtime distribution starts, updates the cookie, and stops in an isolated BEAM" do
    paths =
      for app <- [:elixir, :ex_unit, :logger, :evo_git] do
        app |> Application.app_dir("ebin") |> String.to_charlist()
      end

    args = [~c"+S", ~c"1:1", ~c"-start_epmd", ~c"false", ~c"-pa" | paths]

    # A stdio control channel survives the peer's node-name changes. Never
    # start distribution in the suite VM, even in an async: false test: the
    # umbrella's test-file compiler can still be using its original identity.
    assert {:ok, peer, :nonode@nohost} =
             :peer.start_link(%{connection: :standard_io, args: args, wait_boot: 10_000})

    smoke =
      quote do
        import ExUnit.Assertions

        assert Distribution.active() == %{enabled: false, node: "nonode@nohost", dist_port: nil}

        # The API requires a nonzero port; ask the OS for a free one rather
        # than compete with other suites or services for a fixed port.
        loopback = {127, 0, 0, 1}
        Application.put_env(:kernel, :inet_dist_use_interface, loopback)
        assert {:ok, socket} = :gen_tcp.listen(0, ip: loopback)
        assert {:ok, port} = :inet.port(socket)
        assert :ok = :gen_tcp.close(socket)

        name = "genesis_runtime_test@127.0.0.1"

        assert {:ok, %{node: ^name, dist_port: ^port}} =
                 Distribution.enable_runtime(name, "runtime_test_cookie", port)

        assert node() == :"genesis_runtime_test@127.0.0.1"
        assert Distribution.active() == %{enabled: true, node: name, dist_port: port}
        assert Application.get_env(:kernel, :inet_dist_listen_max) == port
        assert Node.get_cookie() == :runtime_test_cookie

        assert :ok = Distribution.set_cookie(%{})
        assert Node.get_cookie() == :runtime_test_cookie
        assert :ok = Distribution.set_cookie(%{cookie: "custom_test_cookie"})
        assert Node.get_cookie() == :custom_test_cookie

        assert {:ok, %{node: ^name, dist_port: ^port}} =
                 Distribution.enable_runtime(name, "runtime_test_cookie", port)

        assert Node.get_cookie() == :runtime_test_cookie

        # The already-distributed remote connect must switch the EPMD
        # module even when it does not need to start distribution (490958058).
        Application.put_env(:kernel, :epmd_module, :erl_epmd)
        assert :ok = Distribution.enable_for_remote(%{})
        assert Application.get_env(:kernel, :epmd_module) == EvoGit.EpmdDist

        assert :ok = Distribution.disable_runtime()
        assert :ok = Distribution.disable_runtime()
        assert Distribution.active() == %{enabled: false, node: "nonode@nohost", dist_port: port}
        :ok
      end

    try do
      assert {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:ex_unit], 10_000)
      assert {:ok, _} = :peer.call(peer, Code, :eval_quoted, [smoke], 10_000)
    after
      :peer.stop(peer)
    end
  end
end
