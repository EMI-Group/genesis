defmodule EvoGit.RemoteConnectionTest do
  @moduledoc """
  Tests for `EvoGit.RemoteConnection` — the GenServer managing a single SSH
  remote connection's lifecycle.

  Uses `async: false` because the tests interact with the Registry /
  DynamicSupervisor that are part of the application supervision tree.
  """

  use ExUnit.Case, async: false

  # Mirrors `EvoGit.RemoteConnection`'s private accent palette (which in turn
  # mirrors the `[appearance] accent_color` `in:` list in the config schema —
  # `EvoGit.Config.Schema.Definitions`), used to assert remote accents are
  # valid members that always differ from the local accent.
  @accent_palette ~w(blue teal green yellow orange red pink purple brown slate)

  # --- Setup: isolate config dir ---

  setup do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      # Terminate any connection managers started during this test so they
      # don't leak into sibling tests (the DynamicSupervisor is app-level).
      # Uses cleanup_connections/0 (terminate_child) — see its comment for
      # why not disconnect/1.
      cleanup_connections()

      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  # Ensure the Registry + DynamicSupervisor are running (they are started by
  # EvoGit.Application, but other serial tests may have interfered).
  defp ensure_registry_and_supervisor do
    if Process.whereis(EvoGit.RemoteConnection.Registry) == nil do
      start_supervised!({Registry, keys: :unique, name: EvoGit.RemoteConnection.Registry})
    end

    if Process.whereis(EvoGit.RemoteConnection.Supervisor) == nil do
      start_supervised!(
        {DynamicSupervisor, name: EvoGit.RemoteConnection.Supervisor, strategy: :one_for_one}
      )
    end
  end

  # Saves a test target and returns its id.
  # Uses a unique ssh_target so each test gets a distinct target_id, avoiding
  # stale GenServer lookups from prior tests sharing the same id.
  defp save_test_target(opts \\ []) do
    unique = System.unique_integer([:positive])
    base = %{ssh_target: "test#{unique}@example.com", dist_port: 9999}
    {:ok, target} = EvoGit.RemoteConnections.save(Map.merge(base, Map.new(opts)))
    target.id
  end

  # Terminates manager children directly via the DynamicSupervisor instead of
  # `EvoGit.RemoteConnection.disconnect/1`. disconnect/1 stops the manager with
  # `:normal`, and because managers are started as `:permanent` children (default
  # `use GenServer` child spec), OTP restarts them on ANY exit — including
  # `:normal` — and each restart counts toward the DynamicSupervisor's restart
  # intensity (default 3 in 5s). Churning through several disconnect cycles
  # exhausts the intensity and the supervisor dies with `:shutdown`, cascading
  # into intermittent `unknown registry` teardown failures. terminate_child
  # removes the child without restarting it. (The lib-side fix — restart:
  # :transient on the child spec or a true terminate_child-based disconnect —
  # belongs in lib/evo_git/remote_connection.ex, out of test scope.)
  defp cleanup_connections do
    if sup = Process.whereis(EvoGit.RemoteConnection.Supervisor) do
      for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end
    end

    :ok
  end

  describe "list_connections/0" do
    test "returns %{} with no active connections" do
      ensure_registry_and_supervisor()
      cleanup_connections()

      assert EvoGit.RemoteConnection.list_connections() == %{}
    end
  end

  describe "status/1" do
    test "returns disconnected default for a non-existent target_id" do
      ensure_registry_and_supervisor()

      assert EvoGit.RemoteConnection.status("does-not-exist") == %{
               phase: :disconnected,
               node: nil,
               last_error: nil,
               target: nil
             }
    end
  end

  describe "connected?/1" do
    test "returns false for a non-existent target_id" do
      ensure_registry_and_supervisor()

      assert EvoGit.RemoteConnection.connected?("does-not-exist") == false
    end
  end

  describe "disconnect/1" do
    test "returns :ok for a non-existent target_id (graceful no-op)" do
      ensure_registry_and_supervisor()

      assert EvoGit.RemoteConnection.disconnect("does-not-exist") == :ok
    end
  end

  describe "bootstrap/1" do
    test "auto-download path: no local_binary_path probes the remote (fails on unreachable host)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      assert {:error, {:probe_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "set-but-missing local_binary_path falls back to auto-download (probe fails)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(local_binary_path: "/nonexistent/path/to/tarball.tar.xz")

      assert {:error, {:probe_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "platform override skips the probe and fails at download" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(platform: "linux_x64")

      # download_url/1 is deterministic (direct Cloudflare-worker "smart
      # download" URL, no API query), so the remote download (curl first, wget
      # fallback) always
      # fails at the ssh level ({:download_failed, {:exit_status, _}}) — the
      # release asset doesn't exist — and the local curl fallback also fails
      # ({:download_failed, {:local, _}}). Keep the assertion broad.
      assert {:error, {:download_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "invalid platform override fails fast" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(platform: "bogus")

      assert {:error, {:invalid_platform, "bogus"}} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "unsupported platform override (windows) fails fast" do
      ensure_registry_and_supervisor()
      target_id = save_test_target(platform: "windows_x64")

      assert {:error, :unsupported_platform} = EvoGit.RemoteConnection.bootstrap(target_id)

      cleanup_connections()
    end

    test "local_binary_path that exists still uploads (scp fails on unreachable host)" do
      ensure_registry_and_supervisor()

      tmp =
        Path.join(
          System.tmp_dir!(),
          "evogit-test-tarball-#{System.unique_integer([:positive])}.tar.xz"
        )

      File.write!(tmp, "fake tarball")
      # platform override skips the pre-flight SSH probe (which would fail
      # first on the unreachable host) so the flow reaches the scp stage.
      target_id = save_test_target(local_binary_path: tmp, platform: "linux_x64")

      assert {:error, {:scp_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      File.rm!(tmp)
      cleanup_connections()
    end
  end

  describe "connect/1 (async, event-driven)" do
    test "returns a prompt {:ok, :connecting} reply and never :local_node_not_distributed (auto-enables distribution on demand)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      # Auto-enable distribution only applies when node() == :nonode@nohost;
      # if an earlier test in this VM already started distribution the worker
      # takes the already-distributed branch — both end in a terminal :error
      # broadcast (the fake ssh exits before the tunnel is ready).
      if not match?({:win32, _}, :os.type()) do
        original_epmd = Application.get_env(:kernel, :epmd_module)
        original_min = Application.get_env(:kernel, :inet_dist_listen_min)
        original_max = Application.get_env(:kernel, :inet_dist_listen_max)
        was_distributed = node() != :nonode@nohost

        on_exit(fn ->
          # The worker auto-enables distribution on demand; stop it again when
          # THIS test's connect caused the start so it doesn't leak VM-wide.
          if not was_distributed and node() != :nonode@nohost do
            :net_kernel.stop()
          end

          if not was_distributed and
               :persistent_term.get({:evogit_epmd, :genesis}, :absent) != :absent do
            :persistent_term.erase({:evogit_epmd, :genesis})
          end

          restore_env(:kernel, :epmd_module, original_epmd)
          restore_env(:kernel, :inet_dist_listen_min, original_min)
          restore_env(:kernel, :inet_dist_listen_max, original_max)
        end)

        Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

        with_fake_ssh_connect([mode: :exit], fn _log ->
          {elapsed, result} = :timer.tc(fn -> EvoGit.RemoteConnection.connect(target_id) end)

          # Old synchronous connect blocked for the full ~25s budget; the async
          # connect must ack immediately with :connecting (never the historical
          # :local_node_not_distributed error — auto-enable is now internal to
          # the connect worker).
          assert result == {:ok, :connecting}
          assert elapsed < 5_000_000

          # :connecting is broadcast when the connect starts.
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          # Terminal outcome arrives as a broadcast — the fake ssh exits, so the
          # worker reports a failure and the manager broadcasts :error with the
          # detail populated (successful auto-enable reaches the tunnel; a
          # distribution-start failure reports distribution_failed — both are
          # :error phases, neither is :local_node_not_distributed).
          assert_receive {:remote_connection_status, ^target_id, %{phase: phase, last_error: le}},
                         10_000

          assert phase == :error
          assert is_binary(le) and le != ""
        end)

        cleanup_connections()
      end
    end

    test "on an already-distributed node, flips epmd_module to EpmdDist before connecting (regression: 490958058)" do
      ensure_registry_and_supervisor()

      original_epmd = Application.get_env(:kernel, :epmd_module)
      original_min = Application.get_env(:kernel, :inet_dist_listen_min)
      original_max = Application.get_env(:kernel, :inet_dist_listen_max)
      was_distributed = node() != :nonode@nohost

      # The connect path that hit the bug — connect taking the already-
      # distributed branch into the tunnel flow — requires node() !=
      # :nonode@nohost. The test BEAM boots non-distributed and cannot start
      # distribution with the default erl_epmd (no epmd daemon is running), so
      # start an EPMD-less distribution the same way the app does: listen range
      # + EpmdDist epmd_module, then :net_kernel.start. `started` is true only
      # when THIS test actually started distribution (a node already
      # distributed on entry is not ours to stop).
      started =
        if was_distributed do
          false
        else
          Application.put_env(:kernel, :inet_dist_listen_min, 9100)
          Application.put_env(:kernel, :inet_dist_listen_max, 9200)
          Application.put_env(:kernel, :epmd_module, Elixir.EvoGit.EpmdDist)

          case :net_kernel.start([:"genesis@127.0.0.1", :longnames]) do
            {:ok, _pid} -> true
            # Environment cannot run distribution — the distributed connect
            # path is unreachable; skip the assertions below (mirrors the
            # existing non-distributed connect test's tolerance).
            _other -> false
          end
        end

      on_exit(fn ->
        if started and node() != :nonode@nohost do
          :net_kernel.stop()
        end

        # EpmdDist.register_node/3 persists the local name in its
        # persistent-term registry at net_kernel start; erase the entry this
        # test created (erase/1 raises on a missing key, hence the guard).
        if started and :persistent_term.get({:evogit_epmd, :genesis}, :absent) != :absent do
          :persistent_term.erase({:evogit_epmd, :genesis})
        end

        restore_env(:kernel, :epmd_module, original_epmd)
        restore_env(:kernel, :inet_dist_listen_min, original_min)
        restore_env(:kernel, :inet_dist_listen_max, original_max)
      end)

      if node() != :nonode@nohost and not match?({:win32, _}, :os.type()) do
        # Deliberately reset the env to the default erl_epmd first, so the
        # assertion below proves the connect worker (not our setup) performed
        # the flip back to EpmdDist before the tunnel/Node.connect.
        Application.put_env(:kernel, :epmd_module, :erl_epmd)

        # Fake `ssh` exits immediately instead of hanging on a real network
        # connect — the tunnel dies fast and deterministically (real ssh to
        # example.com can hang for the full 10s tunnel budget offline).
        with_fake_ssh_connect([mode: :exit], fn _log ->
          target_id = save_test_target()
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)

          # :connecting start broadcast, then the terminal broadcast.
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          # The fake ssh exits before the tunnel opens, so connect errors with
          # a tunnel_not_ready failure broadcast — but NOT distribution_failed
          # (that would mean the worker never reached the already-distributed
          # branch).
          assert_receive {:remote_connection_status, ^target_id, %{phase: :error, last_error: le}},
                         5_000

          assert is_binary(le) and le != ""
          assert le =~ "tunnel_not_ready"

          # The worker runs ensure_epmd_module() before opening the tunnel, so
          # even a failed connect must leave the env at EpmdDist.
          assert Application.get_env(:kernel, :epmd_module) == EvoGit.EpmdDist
        end)

        cleanup_connections()
      end
    end

    test "connect/1 replies promptly (does not block ~25s) and broadcasts :connecting on start" do
      ensure_registry_and_supervisor()

      # Deterministic async-contract tests need a distributed test node so the
      # connect worker reaches the tunnel flow; start one (EPMD-less, like the
      # app does) and skip when the environment cannot run distribution.
      if not match?({:win32, _}, :os.type()) and start_distributed_test_node() == :ok do
        with_fake_ssh_connect([mode: :sleep], fn _log ->
          target_id = save_test_target()
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          {elapsed, result} = :timer.tc(fn -> EvoGit.RemoteConnection.connect(target_id) end)

          # The fake ssh sleeps 30s; under the old synchronous behavior this
          # call blocked for the full tunnel budget (~10s+) — now it acks
          # immediately with :connecting.
          assert result == {:ok, :connecting}
          assert elapsed < 5_000_000

          # :connecting is broadcast when the connect starts (fired in
          # handle_call before the worker is spawned).
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          cleanup_connections()
        end)
      end
    end

    test "GenServer stays responsive while a connect is in flight (status/connected?/list_connections/disconnect)" do
      ensure_registry_and_supervisor()

      if not match?({:win32, _}, :os.type()) and start_distributed_test_node() == :ok do
        with_fake_ssh_connect([mode: :sleep], fn _log ->
          target_id = save_test_target()
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          # The tunnel fake sleeps 30s, so the manager would be busy for the
          # whole wait budget under the old in-process connect; now status/1
          # must answer promptly with the in-flight phase.
          {elapsed, status} = :timer.tc(fn -> EvoGit.RemoteConnection.status(target_id) end)
          assert status.phase == :connecting
          assert elapsed < 5_000_000

          refute EvoGit.RemoteConnection.connected?(target_id)
          assert %{^target_id => %{phase: :connecting}} = EvoGit.RemoteConnection.list_connections()

          # disconnect/1 during the in-flight connect: prompt, kills the worker
          # (closing its ssh port) and ends with a terminal :disconnected
          # broadcast reflecting the intent.
          {elapsed_disc, disc} = :timer.tc(fn -> EvoGit.RemoteConnection.disconnect(target_id) end)
          assert disc == :ok
          assert elapsed_disc < 5_000_000

          assert_receive {:remote_connection_status, ^target_id, %{phase: :disconnected}}

          # The manager is stopped with :normal + restart: :transient → NOT
          # restarted: no stale state, no live manager child, no worker left.
          assert EvoGit.RemoteConnection.status(target_id).phase == :disconnected
          assert DynamicSupervisor.which_children(EvoGit.RemoteConnection.Supervisor) == []
        end)
      end
    end

    test "duplicate connect while :connecting is an idempotent no-op (one tunnel only)" do
      ensure_registry_and_supervisor()

      if not match?({:win32, _}, :os.type()) and start_distributed_test_node() == :ok do
        with_fake_ssh_connect([mode: :sleep], fn log ->
          target_id = save_test_target()
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          # Second connect while the first is in flight: prompt ack of the
          # CURRENT phase, no second worker/tunnel spawned, no state clobber.
          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)

          # Give a wrongly-spawned second worker time to write its invocation,
          # then prove exactly one ssh was spawned.
          Process.sleep(300)
          assert ssh_invocation_count(log) == 1

          cleanup_connections()
        end)
      end
    end

    test "connect failure (ssh exits before the tunnel is ready) broadcasts :error with last_error populated" do
      ensure_registry_and_supervisor()

      if not match?({:win32, _}, :os.type()) and start_distributed_test_node() == :ok do
        with_fake_ssh_connect([mode: :exit], fn _log ->
          target_id = save_test_target()
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          # The fake ssh exits immediately → wait_for_tunnel fails fast → the
          # worker reports the failure → the manager BROADCASTS :error with the
          # detail populated (this failure arm was silent before the refactor).
          assert_receive {:remote_connection_status, ^target_id, %{phase: :error, last_error: le}},
                         5_000

          assert is_binary(le) and le != ""
          assert le =~ "tunnel_not_ready"

          # The manager survives in :error phase (no crash/restart) and a
          # status read exposes the failure.
          assert %{phase: :error, last_error: ^le} = EvoGit.RemoteConnection.status(target_id)

          cleanup_connections()
        end)
      end
    end

    test "node-connect failure broadcasts :error with last_error populated" do
      ensure_registry_and_supervisor()

      if not match?({:win32, _}, :os.type()) and start_distributed_test_node() == :ok do
        port_file =
          Path.join(
            System.tmp_dir!(),
            "evogit-test-tunnel-port-#{System.unique_integer([:positive])}"
          )

        with_fake_ssh_connect([mode: :sleep, write_port_to: port_file], fn _log ->
          target_id = save_test_target()
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)
          assert_receive {:remote_connection_status, ^target_id, %{phase: :connecting}}

          # The fake ssh keeps running but never forwards: it reports the
          # tunnel's local port, which this test then serves with an
          # accept-and-close listener — wait_for_tunnel passes and Node.connect
          # runs against a peer that closes the handshake → node_connect_failed.
          local_port = await_tunnel_port_file(port_file)
          listener_pid = spawn_link(fn -> accept_close_loop(open_listener(local_port)) end)
          on_exit(fn -> send(listener_pid, :stop) end)

          assert_receive {:remote_connection_status, ^target_id, %{phase: :error, last_error: le}},
                         10_000

          assert is_binary(le) and le != ""
          assert le =~ "Could not connect"

          cleanup_connections()
        end)
      end
    end

    test "the ssh tunnel command carries -o ConnectTimeout (bounded ssh connect)" do
      ensure_registry_and_supervisor()

      if not match?({:win32, _}, :os.type()) and start_distributed_test_node() == :ok do
        with_fake_ssh_connect([mode: :sleep], fn log ->
          target_id = save_test_target()

          assert {:ok, :connecting} = EvoGit.RemoteConnection.connect(target_id)

          # The fake ssh logs its full argv; the tunnel command must include
          # the bounded ConnectTimeout so an unreachable/dead host fails inside
          # the @tunnel_wait_timeout_ms budget instead of hanging on the OS TCP
          # timeout.
          argv = await_ssh_argv_line(log)
          assert argv =~ "-o ConnectTimeout=8"

          cleanup_connections()
        end)
      end
    end
  end

  describe "find_free_port/0" do
    test "returns a valid port number on loopback" do
      assert {:ok, port} = EvoGit.RemoteConnection.find_free_port()
      assert is_integer(port)
      assert port > 0
      assert port <= 65535
    end

    test "returns a different port when called twice in sequence" do
      {:ok, port1} = EvoGit.RemoteConnection.find_free_port()
      {:ok, port2} = EvoGit.RemoteConnection.find_free_port()
      # Ports should differ since we close the socket between calls
      assert port1 != port2
    end
  end

  describe "remote_accent_for/2 — accent-variant picker" do
    # Distinct ssh_target shapes: user@host, host:port, dotted/internal hosts,
    # an IPv6 literal and a non-ASCII user — the picker must be stable across
    # all of them.
    @ssh_targets [
      "dev@example.com",
      "ops@10.0.0.5",
      "staging@genesis.internal",
      "user@[2001:db8::1]",
      "üñïçødé@täst.de"
    ]

    test "always returns a palette member that differs from the local accent" do
      for local_accent <- @accent_palette, ssh_target <- @ssh_targets do
        result = EvoGit.RemoteConnection.remote_accent_for(ssh_target, local_accent)

        assert result in @accent_palette,
               "expected #{result} (target #{ssh_target}, local #{local_accent}) " <>
                 "to be a palette member"

        refute result == local_accent,
               "expected the remote accent for #{ssh_target} to differ from local #{local_accent}"
      end
    end

    test "is deterministic for the same (ssh_target, local_accent) pair" do
      for local_accent <- @accent_palette, ssh_target <- @ssh_targets do
        first = EvoGit.RemoteConnection.remote_accent_for(ssh_target, local_accent)
        second = EvoGit.RemoteConnection.remote_accent_for(ssh_target, local_accent)

        assert first == second,
               "expected a stable pick for target #{ssh_target}, local #{local_accent} " <>
                 "(got #{first} then #{second})"
      end
    end

    test "never returns a non-palette local_accent (still yields a valid palette member)" do
      # A local accent outside the palette is not removed from the candidates,
      # but the result must still be a palette color — and can never equal the
      # non-palette local accent.
      for local_accent <- ["chartreuse", "neon", "midnight"], ssh_target <- @ssh_targets do
        result = EvoGit.RemoteConnection.remote_accent_for(ssh_target, local_accent)

        assert result in @accent_palette,
               "expected #{result} (target #{ssh_target}, local #{local_accent}) " <>
                 "to be a palette member"

        refute result == local_accent
      end
    end
  end

  describe "rewrite_config_accent/2 — [appearance] accent rewrite" do
    test "replaces an existing accent_color value inside [appearance], preserving everything else verbatim" do
      input = """
      # Genesis user configuration

      [node]
      cookie = "abc123"

      [appearance]
      accent_color = "blue"
      # UI density preference
      ui_density = "comfortable"

      [[llm.models]]
      id = "deepseek"
      provider = "deepseek"
      model = "deepseek-chat"
      concurrency = 3

      [sandbox]
      backend = "auto"
      """

      expected = """
      # Genesis user configuration

      [node]
      cookie = "abc123"

      [appearance]
      accent_color = "teal"
      # UI density preference
      ui_density = "comfortable"

      [[llm.models]]
      id = "deepseek"
      provider = "deepseek"
      model = "deepseek-chat"
      concurrency = 3

      [sandbox]
      backend = "auto"
      """

      assert EvoGit.RemoteConnection.rewrite_config_accent(input, "teal") == expected
    end

    test "inserts an accent_color line right after an [appearance] header that lacks one" do
      input = """
      [node]
      cookie = "abc123"

      [appearance]
      # picked by the dashboard at first run
      ui_density = "comfortable"

      [data]
      dir = "/tmp/genesis-data"
      """

      expected = """
      [node]
      cookie = "abc123"

      [appearance]
      accent_color = "teal"
      # picked by the dashboard at first run
      ui_density = "comfortable"

      [data]
      dir = "/tmp/genesis-data"
      """

      assert EvoGit.RemoteConnection.rewrite_config_accent(input, "teal") == expected
    end

    test "appends a new [appearance] section at EOF (blank separator) when none exists" do
      input = """
      [node]
      cookie = "abc123"

      [[llm.models]]
      id = "deepseek"
      provider = "deepseek"
      model = "deepseek-chat"
      """

      expected = """
      [node]
      cookie = "abc123"

      [[llm.models]]
      id = "deepseek"
      provider = "deepseek"
      model = "deepseek-chat"

      [appearance]
      accent_color = "teal"
      """

      result = EvoGit.RemoteConnection.rewrite_config_accent(input, "teal")

      # The appended section terminates the file (no trailing newline is added
      # after the new accent_color line), so the heredoc expected (which always
      # ends with a newline) is compared trimmed.
      assert result == String.trim_trailing(expected, "\n")
    end

    test "never touches an accent_color line inside a different section" do
      input = """
      [some.other]
      accent_color = "blue"

      [node]
      cookie = "abc123"
      """

      expected = """
      [some.other]
      accent_color = "blue"

      [node]
      cookie = "abc123"

      [appearance]
      accent_color = "teal"
      """

      result = EvoGit.RemoteConnection.rewrite_config_accent(input, "teal")

      # Same trailing-newline note as the append test above.
      assert result == String.trim_trailing(expected, "\n")
      assert result =~ "[some.other]\naccent_color = \"blue\""
    end
  end

  # The dummy live/dying Port commands (`sleep`, `false`) are POSIX — Windows
  # has no equivalent `sh -c` builtins, so these unit tests of the tunnel
  # readiness helper are skipped there.
  if not match?({:win32, _}, :os.type()) do
    describe "wait_for_tunnel/4 — tunnel readiness helper" do
      # A long-running dummy process standing in for the `ssh -L` tunnel Port.
      defp open_live_dummy_port do
        port = Port.open({:spawn, "sleep 30"}, [:binary, :exit_status, :stream])
        on_exit(fn -> if Port.info(port) != nil, do: Port.close(port) end)
        port
      end

      # Opens a TCP listener on the given 127.0.0.1 port, retrying briefly —
      # the port was reserved-then-closed right before, so a sibling test
      # could in theory have grabbed it.
      defp listen_with_retry(local_port, attempts \\ 50) do
        case :gen_tcp.listen(local_port, [:inet, {:ip, {127, 0, 0, 1}}, {:reuseaddr, true}]) do
          {:ok, socket} ->
            {:ok, socket}

          {:error, :eaddrinuse} when attempts > 0 ->
            Process.sleep(20)
            listen_with_retry(local_port, attempts - 1)

          {:error, reason} ->
            flunk("could not bind listener on 127.0.0.1:#{local_port}: #{inspect(reason)}")
        end
      end

      test "returns :ok when the local port is TCP-ready" do
        # Bind a real listener first to obtain a free 127.0.0.1 port.
        {:ok, listener} =
          :gen_tcp.listen(0, [:inet, {:ip, {127, 0, 0, 1}}, {:reuseaddr, true}])

        {:ok, local_port} = :inet.port(listener)
        on_exit(fn -> :gen_tcp.close(listener) end)

        port = open_live_dummy_port()

        assert :ok =
                 EvoGit.RemoteConnection.wait_for_tunnel(port, local_port, 2_000,
                   poll_interval: 25
                 )
      end

      test "keeps polling until a listener appears on the port" do
        # Reserve a free port, then close it again — the real listener only
        # appears after a short delay, so the helper's first probes must fail
        # and the poll loop is actually exercised.
        {:ok, probe} = :gen_tcp.listen(0, [:inet, {:ip, {127, 0, 0, 1}}, {:reuseaddr, true}])
        {:ok, local_port} = :inet.port(probe)
        :gen_tcp.close(probe)

        test_pid = self()

        # spawn_link: the delayed listener dies with the test process even if
        # it crashes mid-test. `:stop` is sent from on_exit only (an
        # on_exit callback runs in the OnExitHandler process, where
        # Task.await/2 is forbidden — the listener must not be a Task).
        listener_pid =
          spawn_link(fn ->
            Process.sleep(150)
            {:ok, listener} = listen_with_retry(local_port)
            send(test_pid, {:listener_up, listener})

            receive do
              :stop -> :gen_tcp.close(listener)
            end
          end)

        on_exit(fn -> send(listener_pid, :stop) end)

        port = open_live_dummy_port()

        assert :ok =
                 EvoGit.RemoteConnection.wait_for_tunnel(port, local_port, 2_000,
                   poll_interval: 25
                 )
      end

      test "returns {:error, {:timeout, _}} when nothing listens before the budget" do
        port = open_live_dummy_port()
        {:ok, free_port} = EvoGit.RemoteConnection.find_free_port()

        assert {:error, {:timeout, output}} =
                 EvoGit.RemoteConnection.wait_for_tunnel(port, free_port, 200, poll_interval: 25)

        # The dummy `sleep` process prints nothing, so the drained ssh output
        # (surfaced for diagnosability) is empty.
        assert output == ""
      end

      test "fails fast when the ssh port dies before readiness" do
        # `false` exits immediately with status 1 — standing in for an ssh
        # that died before the tunnel came up.
        port = Port.open({:spawn, "false"}, [:binary, :exit_status, :stream])
        on_exit(fn -> if Port.info(port) != nil, do: Port.close(port) end)

        {:ok, free_port} = EvoGit.RemoteConnection.find_free_port()

        assert {:error, {:ssh_exited, status_or_reason, output}} =
                 EvoGit.RemoteConnection.wait_for_tunnel(port, free_port, 2_000,
                   poll_interval: 25
                 )

        assert output == ""
        # Death is detected either via the exit-status message (status 1) or
        # via Port.info/1 going nil (:port_info_nil) — both are valid
        # depending on the race between port death and the first poll.
        assert status_or_reason in [1, :port_info_nil]
      end
    end
  end

  describe "build_tunnel_command/1 — internal behavior" do
    # The function is private, but we can test the port-separation logic
    # by verifying the GenServer's connection flow doesn't produce port conflicts.
    # For now, verify that find_free_port is used and tested independently.
  end

  # The fake ssh below is a POSIX shell script on PATH, which cannot emulate
  # ssh.exe on Windows — the argv contract is covered on the platforms where
  # this runs.
  if not match?({:win32, _}, :os.type()) do
    describe "run_ssh_command/3" do
      # Writes a fake `ssh` executable that prints its argv one element per
      # line and exits 0, puts its dir first on PATH, and restores both on
      # exit.
      defp with_fake_ssh(fun) do
        tmp =
          Path.join(
            System.tmp_dir!(),
            "evogit-test-ssh-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(tmp)

        ssh_path = Path.join(tmp, "ssh")

        File.write!(
          ssh_path,
          ~S"""
          #!/bin/sh
          printf 'argv=%s\n' "$#"
          i=1
          for a in "$@"; do
            printf 'arg%s=%s\n' "$i" "$a"
            i=$((i + 1))
          done
          exit 0
          """
        )

        File.chmod!(ssh_path, 0o755)

        original_path = System.get_env("PATH")
        new_path = if original_path, do: tmp <> ":" <> original_path, else: tmp
        System.put_env("PATH", new_path)

        on_exit(fn ->
          if original_path do
            System.put_env("PATH", original_path)
          else
            System.delete_env("PATH")
          end

          File.rm_rf!(tmp)
        end)

        fun.()
      end

      test "passes the remote command as one argv element (no quotes, no local shell)" do
        with_fake_ssh(fn ->
          remote_cmd = "mkdir -p /tmp/g && tar -xJf /tmp/g.tar.xz -C /tmp/g"

          assert {:ok, output, 0} =
                   EvoGit.RemoteConnection.run_ssh_command("fake@example.com", remote_cmd, 5_000)

          assert output =~ "argv=2\n"
          assert output =~ "arg1=fake@example.com\n"
          assert output =~ "arg2=#{EvoGit.RemoteBootstrap.bash_wrap(remote_cmd)}\n"
          refute output =~ "arg3="
        end)
      end

      test "shell metacharacters are not interpreted locally (arrive as one arg)" do
        with_fake_ssh(fn ->
          remote_cmd = "echo hi | cat; test -f /tmp/x && echo yes || echo no"

          assert {:ok, output, 0} =
                   EvoGit.RemoteConnection.run_ssh_command("fake@example.com", remote_cmd, 5_000)

          assert output =~ "argv=2\n"
          assert output =~ "arg2=#{EvoGit.RemoteBootstrap.bash_wrap(remote_cmd)}\n"
        end)
      end

      test "embedded single quotes round-trip through the bash-wrap escaping" do
        with_fake_ssh(fn ->
          remote_cmd =
            "test -d /etc/nixos && echo yes || grep -qi '^ID=nixos' /etc/os-release 2>/dev/null && echo yes || echo no"

          assert {:ok, output, 0} =
                   EvoGit.RemoteConnection.run_ssh_command("fake@example.com", remote_cmd, 5_000)

          # Exact pinned form of the wrapped command: every `'` in the raw
          # command becomes `'\''` (close-quote / escaped-quote / reopen-quote).
          expected_arg2 =
            "/usr/bin/env bash -c 'test -d /etc/nixos && echo yes || grep -qi '\\''^ID=nixos'\\'' /etc/os-release 2>/dev/null && echo yes || echo no'"

          assert output == "argv=2\narg1=fake@example.com\narg2=#{expected_arg2}\n"
        end)
      end
    end

    describe "bootstrap/1 with fake ssh" do
      # Writes a fake `ssh` + fake `scp` onto PATH and returns
      # %{log:, marker:, tarball:}. The fake ssh receives $1 = ssh_target and
      # $2 = the bash-wrapped remote command (ONE argv element —
      # `/usr/bin/env bash -c '<cmd>'`; the wrapping preserves the command
      # text verbatim), logs every command to the log file, and dispatches on
      # $2 via CONTAINS patterns. Daemon state is emulated via a marker
      # file: `systemd-run` / the deploy `launchctl load` touch it, the stop
      # commands (`systemctl --user stop` / pure `launchctl unload`) remove
      # it, and `systemctl --user is-active` / `launchctl list` report
      # active / non-empty only when it exists — so the post-start health
      # check succeeds after the daemon is "started". Options: :os (default
      # Linux), :detect ("yes"/"no" for the NixOS detection command),
      # :patch_exit, :patch_output, :daemon_active? (pre-create the marker),
      # :daemon_active_after (N — the fake reports the daemon active only
      # once the is-active / launchctl-list call count exceeds N; used to
      # simulate the race where a daemon starts between the pre-flight check
      # and the launch point), :remote_config_exists? (the fake reports the
      # remote config.toml/credentials.toml as already present, so the
      # :copying_config stage skips their upload). The fake `scp` captures
      # every uploaded payload into the tmp dir under its DESTINATION basename
      # (config.toml / credentials.toml / genesis_remote.tar.xz) — the tmp dir
      # is returned as `:scp_dir` — so tests can assert what actually "landed
      # on the remote" (e.g. the accent-variant config.toml content).
      defp with_fake_ssh_tools(opts, fun) do
        tmp =
          Path.join(
            System.tmp_dir!(),
            "evogit-test-ssh-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(tmp)

        log = Path.join(tmp, "ssh.log")
        marker = Path.join(tmp, "daemon.marker")
        counter = Path.join(tmp, "is-active.count")

        if Keyword.get(opts, :daemon_active?, false) do
          File.touch!(marker)
        end

        script =
          ~S"""
          #!/bin/sh
          log="__LOG__"
          marker="__MARKER__"
          counter="__COUNTER__"
          printf '%s\n' "$2" >> "$log"
          case "$2" in
            *"uname -s && uname -m"*) printf '__OS__\nx86_64\n'; exit 0 ;;
            *"uname -s"*) printf '__OS__\n'; exit 0 ;;
            *"systemctl --user stop"*) rm -f "$marker"; exit 0 ;;
            *"systemctl --user is-active"*) if [ -n "__DAEMON_ACTIVE_AFTER__" ]; then count=$(cat "$counter" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" > "$counter"; if [ "$count" -gt __DAEMON_ACTIVE_AFTER__ ]; then printf 'active\n'; else printf 'inactive\n'; fi; elif [ -f "$marker" ]; then printf 'active\n'; else printf 'inactive\n'; fi; exit 0 ;;
            *"systemctl --user show"*) if [ -n "$FAKE_UNIT_RELEASE_NODE" ] || [ -n "$FAKE_UNIT_RELEASE_COOKIE" ]; then printf 'RELEASE_NODE=%s RELEASE_COOKIE=%s\n' "$FAKE_UNIT_RELEASE_NODE" "$FAKE_UNIT_RELEASE_COOKIE"; fi; exit 0 ;;
            *"systemctl --user reset-failed"*) exit 0 ;;
            *"systemd-run"*) touch "$marker"; exit 0 ;;
            *"launchctl load"*) touch "$marker"; exit 0 ;;
            *"launchctl unload"*) rm -f "$marker"; exit 0 ;;
            *"launchctl list"*) if [ -n "__DAEMON_ACTIVE_AFTER__" ]; then count=$(cat "$counter" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" > "$counter"; if [ "$count" -gt __DAEMON_ACTIVE_AFTER__ ]; then printf '1234\t0\tcom.genesis.remote.test\n'; fi; elif [ -f "$marker" ]; then printf '1234\t0\tcom.genesis.remote.test\n'; fi; exit 0 ;;
            *"cat ~/Library/LaunchAgents"*) if [ -n "$FAKE_UNIT_RELEASE_NODE" ] || [ -n "$FAKE_UNIT_RELEASE_COOKIE" ]; then printf '<plist><dict><key>RELEASE_NODE</key><string>%s</string><key>RELEASE_COOKIE</key><string>%s</string></dict></plist>\n' "$FAKE_UNIT_RELEASE_NODE" "$FAKE_UNIT_RELEASE_COOKIE"; fi; exit 0 ;;
            *"launchctl"*) exit 0 ;;
            *"test -d /etc/nixos"*) printf '__DETECT__\n'; exit 0 ;;
            *nix-build*) printf '%s\n' '__PATCH_OUTPUT__'; exit __PATCH_EXIT__ ;;
            *"curl"*|*"wget"*) exit 0 ;;
            # The only `test -f` command issued is the config-existence check
            # (remote_file_exists?) — :remote_config_exists? makes the fake
            # report the remote already has the file.
            *"test -f"*) printf '__CONFIG_EXISTS__\n'; exit 0 ;;
            *"mkdir"*|*"tar"*|*"chmod"*) exit 0 ;;
            *) exit 0 ;;
          esac
          """
          |> String.replace("__LOG__", log)
          |> String.replace("__MARKER__", marker)
          |> String.replace("__COUNTER__", counter)
          |> String.replace(
            "__DAEMON_ACTIVE_AFTER__",
            case Keyword.get(opts, :daemon_active_after) do
              nil -> ""
              n -> Integer.to_string(n)
            end
          )
          |> String.replace("__OS__", Keyword.get(opts, :os, "Linux"))
          |> String.replace("__DETECT__", Keyword.get(opts, :detect, "no"))
          |> String.replace(
            "__PATCH_OUTPUT__",
            Keyword.get(opts, :patch_output, "nixos-patch: patched 0 ELF files")
          )
          |> String.replace(
            "__PATCH_EXIT__",
            Integer.to_string(Keyword.get(opts, :patch_exit, 0))
          )
          |> String.replace(
            "__CONFIG_EXISTS__",
            if(Keyword.get(opts, :remote_config_exists?, false), do: "yes", else: "no")
          )

        ssh_path = Path.join(tmp, "ssh")
        scp_path = Path.join(tmp, "scp")

        File.write!(ssh_path, script)
        File.chmod!(ssh_path, 0o755)

        # The local-tarball path shells out to real `scp` via run_cmd
        # ({:spawn, "scp ..."} → /bin/sh -c) — a fake scp on PATH intercepts it.
        # It also copies the uploaded source into the shared tmp dir, named by
        # the DESTINATION basename, so tests can inspect what was uploaded.
        scp_script =
          ~S"""
          #!/bin/sh
          cp "$1" "__SCP_DIR__/$(basename "$2")"
          exit 0
          """
          |> String.replace("__SCP_DIR__", tmp)

        File.write!(scp_path, scp_script)
        File.chmod!(scp_path, 0o755)

        original_path = System.get_env("PATH")
        new_path = if original_path, do: tmp <> ":" <> original_path, else: tmp
        System.put_env("PATH", new_path)

        on_exit(fn ->
          if original_path do
            System.put_env("PATH", original_path)
          else
            System.delete_env("PATH")
          end

          # Clear the fake-unit env vars the daemon-identity verification reads
          # (set directly in the race tests) so they don't leak into sibling tests.
          System.delete_env("FAKE_UNIT_RELEASE_NODE")
          System.delete_env("FAKE_UNIT_RELEASE_COOKIE")

          File.rm_rf!(tmp)
        end)

        tarball = Path.join(tmp, "local.tar.xz")
        File.write!(tarball, "fake tarball")

        fun.(%{log: log, marker: marker, tarball: tarball, scp_dir: tmp})
      end

      # Drains all {:remote_connection_status, target_id, status} broadcasts
      # received so far and returns their bootstrap_stage values in order.
      defp collect_stages(target_id) do
        collect_stages(target_id, [])
      end

      defp collect_stages(target_id, acc) do
        receive do
          {:remote_connection_status, ^target_id, %{bootstrap_stage: stage}} ->
            collect_stages(target_id, [stage | acc])
        after
          0 ->
            Enum.reverse(acc)
        end
      end

      # Asserts that `expected` stages all appear in `stages`, in that order
      # (other stages may interleave).
      defp assert_stage_subsequence(stages, expected) do
        indices =
          Enum.map(expected, fn stage ->
            Enum.find_index(stages, &(&1 == stage))
          end)

        assert Enum.all?(indices, &is_integer/1),
               "expected stages #{inspect(expected)} present in #{inspect(stages)}"

        assert indices == Enum.sort(indices), "stages out of order: #{inspect(stages)}"
      end

      # Writes a config.toml with a known [node] cookie into the isolated XDG
      # config dir so `ensure_cookie!` returns the known value during bootstrap
      # (instead of generating a random one) — making the fake unit env
      # deterministic.
      defp write_test_config_cookie(cookie) do
        config_dir = EvoGit.Config.config_dir()
        File.mkdir_p!(config_dir)
        File.write!(Path.join(config_dir, "config.toml"), "[node]\ncookie = \"#{cookie}\"\n")
      end

      # Like write_test_config_cookie/1 but additionally carries an
      # [appearance] accent_color (plus a representative [[llm.models]] body) —
      # the accent-variant copy tests need a local config.toml that EXISTS and
      # carries an accent at the :copying_config stage so the variant path
      # triggers and the local accent is well-defined.
      defp write_config_with_accent(cookie, accent) do
        config_dir = EvoGit.Config.config_dir()
        File.mkdir_p!(config_dir)

        File.write!(
          Path.join(config_dir, "config.toml"),
          """
          [node]
          cookie = "#{cookie}"

          [appearance]
          accent_color = "#{accent}"

          [[llm.models]]
          id = "deepseek"
          provider = "deepseek"
          model = "deepseek-chat"
          """
        )
      end

      # Extracts the value of the first `accent_color = "..."` line.
      defp fetch_accent_from(contents) do
        case Regex.run(~r/^accent_color = "([^"]*)"/m, contents) do
          [_, accent] -> {:ok, accent}
          _ -> :error
        end
      end

      test "NixOS detected → patch issued + :patching_binaries broadcast before :starting_daemon" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([detect: "yes", os: "Linux"], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          log_content = File.read!(log)

          # detection command issued
          assert log_content =~ "test -d /etc/nixos"

          # patch script issued as one argv element with all four nix-build lines
          assert log_content =~ ~S|nix-build "$NIXPKGS" -A patchelf|
          assert log_content =~ ~S|nix-build "$NIXPKGS" -A bintools|
          assert log_content =~ ~S|nix-build "$NIXPKGS" -A stdenv.cc.cc.lib|
          assert log_content =~ ~S|nix-build "$NIXPKGS" -A openssl|

          stages = collect_stages(target_id)

          assert_stage_subsequence(stages, [
            :generating_cookie,
            :patching_binaries,
            :starting_daemon
          ])

          cleanup_connections()
        end)
      end

      test "non-NixOS Linux → detection issued but no patch" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([detect: "no", os: "Linux"], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          log_content = File.read!(log)
          assert log_content =~ "test -d /etc/nixos"
          refute log_content =~ "nix-build"

          stages = collect_stages(target_id)
          refute :patching_binaries in stages

          cleanup_connections()
        end)
      end

      test "macOS → no detection, no patch, no :patching_binaries broadcast" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([os: "Darwin"], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          log_content = File.read!(log)
          refute log_content =~ "test -d /etc/nixos"
          refute log_content =~ "nix-build"

          stages = collect_stages(target_id)
          refute :patching_binaries in stages

          cleanup_connections()
        end)
      end

      test "daemon already running (Linux) + default on_running → refuses, no staging, no broadcast" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([os: "Linux", daemon_active?: true], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:error, {:daemon_running, details}} =
                   EvoGit.RemoteConnection.bootstrap(target_id)

          assert details =~ "genesis-remote-#{target_id}"
          assert details =~ "on_running: :restart"

          # the pre-flight probe + is-active check are expected...
          log_content = File.read!(log)
          assert log_content =~ "uname -s && uname -m"
          assert log_content =~ "systemctl --user is-active"

          # ...but NO staging commands at all (the refusal happens before any staging)
          refute log_content =~ "tar -xJf"
          refute log_content =~ "chmod +x"
          refute log_content =~ "scp "
          refute log_content =~ "curl"
          refute log_content =~ "systemd-run"
          refute log_content =~ "launchctl load"
          refute log_content =~ "test -d /etc/nixos"
          refute log_content =~ "nix-build"

          # and NO broadcasts at all
          assert collect_stages(target_id) == []

          cleanup_connections()
        end)
      end

      test "daemon already running (macOS) + default on_running → refuses, no staging, no broadcast" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([os: "Darwin", daemon_active?: true], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:error, {:daemon_running, details}} =
                   EvoGit.RemoteConnection.bootstrap(target_id)

          assert details =~ "genesis-remote-#{target_id}"
          assert details =~ "on_running: :restart"

          log_content = File.read!(log)
          assert log_content =~ "uname -s && uname -m"
          assert log_content =~ "launchctl list"

          refute log_content =~ "tar -xJf"
          refute log_content =~ "chmod +x"
          refute log_content =~ "scp "
          refute log_content =~ "curl"
          refute log_content =~ "systemd-run"
          refute log_content =~ "launchctl load"
          refute log_content =~ "launchctl unload"
          refute log_content =~ "test -d /etc/nixos"
          refute log_content =~ "nix-build"

          assert collect_stages(target_id) == []

          cleanup_connections()
        end)
      end

      test "daemon already running (Linux) + on_running: :restart → stops it before starting fresh" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([os: "Linux", daemon_active?: true], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} =
                   EvoGit.RemoteConnection.bootstrap(target_id, on_running: :restart)

          log_content = File.read!(log)

          stop_idx =
            case :binary.match(log_content, "systemctl --user stop genesis-remote-#{target_id}") do
              {pos, _len} -> pos
              :nomatch -> nil
            end

          start_idx =
            case :binary.match(log_content, "systemd-run") do
              {pos, _len} -> pos
              :nomatch -> nil
            end

          assert is_integer(stop_idx), "expected a systemctl --user stop in the log"
          assert is_integer(start_idx), "expected a systemd-run in the log"
          assert stop_idx < start_idx

          stages = collect_stages(target_id)
          assert_stage_subsequence(stages, [:stopping_daemon, :starting_daemon])

          cleanup_connections()
        end)
      end

      test "daemon already running (macOS) + on_running: :restart → stops it before starting fresh" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([os: "Darwin", daemon_active?: true], fn %{log: log, tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} =
                   EvoGit.RemoteConnection.bootstrap(target_id, on_running: :restart)

          log_content = File.read!(log)

          stop_idx =
            case :binary.match(
                   log_content,
                   "launchctl unload ~/Library/LaunchAgents/com.genesis.remote.#{target_id}.plist"
                 ) do
              {pos, _len} -> pos
              :nomatch -> nil
            end

          load_idx =
            case :binary.match(log_content, "launchctl load") do
              {pos, _len} -> pos
              :nomatch -> nil
            end

          assert is_integer(stop_idx), "expected the stop launchctl unload in the log"
          assert is_integer(load_idx), "expected a launchctl load in the log"
          assert stop_idx < load_idx

          stages = collect_stages(target_id)
          assert_stage_subsequence(stages, [:stopping_daemon, :starting_daemon])

          cleanup_connections()
        end)
      end

      test "daemon appears after pre-flight (Linux, STALE cookie) → identity mismatch with remediation" do
        ensure_registry_and_supervisor()

        cookie = "current-contract-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Linux", daemon_active_after: 1], fn %{tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          # Fake ssh echoes the CORRECT node but a STALE cookie — like a daemon
          # launched by an older bootstrap whose cookie differs from the local
          # config.toml [node] cookie. With daemon_active_after: 1 the pre-flight
          # check (#1) sees the daemon inactive so staging proceeds; the
          # maybe_patch_nixos (#2) and maybe_start_daemon (#3) checks see it
          # active, so verify_daemon_identity runs and reports the mismatch.
          System.put_env("FAKE_UNIT_RELEASE_NODE", "genesis_remote_#{target_id}@127.0.0.1")
          System.put_env("FAKE_UNIT_RELEASE_COOKIE", "old-stale-cookie")
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:error, {:daemon_identity_mismatch, details}} =
                   EvoGit.RemoteConnection.bootstrap(target_id)

          assert details =~ "systemctl --user stop genesis-remote-#{target_id}"
          assert details =~ "old-stale-cookie"
          assert details =~ "current-contract-cookie"

          # the daemon was never started by us — no :starting_daemon broadcast
          stages = collect_stages(target_id)
          refute :starting_daemon in stages

          cleanup_connections()
        end)
      end

      test "daemon appears after pre-flight (Linux, NO RELEASE_COOKIE) → identity mismatch" do
        ensure_registry_and_supervisor()

        cookie = "current-contract-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Linux", daemon_active_after: 1], fn %{tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          # Only RELEASE_NODE is echoed — RELEASE_COOKIE is absent, like a
          # daemon launched before bootstrap passed --setenv=RELEASE_COOKIE.
          System.put_env("FAKE_UNIT_RELEASE_NODE", "genesis_remote_#{target_id}@127.0.0.1")
          System.delete_env("FAKE_UNIT_RELEASE_COOKIE")
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:error, {:daemon_identity_mismatch, details}} =
                   EvoGit.RemoteConnection.bootstrap(target_id)

          assert details =~ "RELEASE_COOKIE"
          assert details =~ "(empty)"
          assert details =~ "systemctl --user stop genesis-remote-#{target_id}"

          cleanup_connections()
        end)
      end

      test "daemon appears after pre-flight (macOS, stale plist) → identity mismatch with launchctl remediation" do
        ensure_registry_and_supervisor()

        cookie = "macos-test-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Darwin", daemon_active_after: 1], fn %{tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          # No FAKE_UNIT_RELEASE_* set — the fake ssh `cat` echoes an empty
          # plist, so the containment check fails.
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:error, {:daemon_identity_mismatch, details}} =
                   EvoGit.RemoteConnection.bootstrap(target_id)

          assert details =~ "launchctl unload"
          assert details =~ "com.genesis.remote.#{target_id}"

          cleanup_connections()
        end)
      end

      test "patch script failure propagates {:nixos_patch_failed, details}" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools(
          [
            detect: "yes",
            os: "Linux",
            patch_exit: 1,
            patch_output: "nixos-patch: nix-build failed: error: patchelf build broken"
          ],
          fn %{log: log, tarball: tarball} ->
            target_id = save_test_target(local_binary_path: tarball)
            Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

            assert {:error, {:nixos_patch_failed, details}} =
                     EvoGit.RemoteConnection.bootstrap(target_id)

            # details carries the failing step's stdout tail
            assert details =~ "patch script failed (exit 1)"
            assert details =~ "nix-build failed"

            # the patch script was actually issued
            assert File.read!(log) =~ "nix-build"

            cleanup_connections()
          end
        )
      end

      test "auto-download path also patches (platform override, single insertion point)" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([detect: "yes", os: "Linux"], fn %{log: log} ->
          target_id = save_test_target(platform: "linux_x64")
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          log_content = File.read!(log)
          assert log_content =~ "curl -fL -o"
          assert log_content =~ ~S|nix-build "$NIXPKGS" -A patchelf|

          stages = collect_stages(target_id)
          refute :detecting_os in stages

          assert_stage_subsequence(stages, [
            :generating_cookie,
            :patching_binaries,
            :starting_daemon
          ])

          cleanup_connections()
        end)
      end

      test "existing remote config.toml is never overwritten by bootstrap" do
        ensure_registry_and_supervisor()

        # A local config.toml must exist for the :copying_config stage to reach
        # the remote-existence check; the fake reports the remote ALREADY has
        # config.toml (and credentials.toml), so no config upload may happen.
        write_test_config_cookie("known-cookie")

        with_fake_ssh_tools(
          [os: "Linux", remote_config_exists?: true],
          fn %{log: log, tarball: tarball, scp_dir: scp_dir} ->
            target_id = save_test_target(local_binary_path: tarball)
            Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

            assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

            # The remote-existence probe was actually issued for the config...
            assert File.read!(log) =~ "test -f ~/.config/genesis/config.toml"

            # ...but the ONLY scp payload that landed is the tarball: the
            # remote keeps its existing config file untouched.
            assert File.exists?(Path.join(scp_dir, "genesis_remote.tar.xz"))
            refute File.exists?(Path.join(scp_dir, "config.toml"))
            refute File.exists?(Path.join(scp_dir, "credentials.toml"))

            cleanup_connections()
          end
        )
      end

      test "fresh remote without config.toml receives an accent variant differing from the local accent" do
        ensure_registry_and_supervisor()

        write_config_with_accent("fresh-remote-cookie", "red")
        local_contents = File.read!(EvoGit.Config.config_path())

        with_fake_ssh_tools([os: "Linux"], fn %{tarball: tarball, scp_dir: scp_dir} ->
          unique = System.unique_integer([:positive])
          ssh_target = "accent#{unique}@example.com"

          {:ok, target} =
            EvoGit.RemoteConnections.save(%{
              ssh_target: ssh_target,
              dist_port: 9999,
              local_binary_path: tarball
            })

          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target.id)

          # The accent variant was uploaded in place of the plain config.toml.
          captured = Path.join(scp_dir, "config.toml")
          assert File.exists?(captured), "expected an accent-variant config.toml on the remote"

          uploaded = File.read!(captured)

          local_accent = EvoGit.Config.resolve([:appearance, :accent_color])
          assert local_accent == "red"

          # The uploaded content is exactly the deterministic rewrite: local
          # file re-accented with remote_accent_for(ssh_target, local_accent).
          expected =
            EvoGit.RemoteConnection.rewrite_config_accent(
              local_contents,
              EvoGit.RemoteConnection.remote_accent_for(ssh_target, local_accent)
            )

          assert uploaded == expected

          # ...and the accent it carries is a palette member != the local one.
          assert {:ok, remote_accent} = fetch_accent_from(uploaded)
          refute remote_accent == local_accent
          assert remote_accent in @accent_palette

          cleanup_connections()
        end)
      end
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # Puts a fake `ssh` executable that exits immediately (no tunnel, no network)
  # first on PATH, restoring both on exit. Used by the already-distributed
  # connect test so the tunnel Port dies fast and deterministically — a real
  # ssh to the fake target (example.com) can hang for the whole tunnel budget
  # in offline environments. POSIX-only (`#!/bin/sh`); callers must gate on
  # non-Windows.
  defp with_fake_ssh_immediate_exit(fun) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "evogit-test-ssh-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    ssh_path = Path.join(tmp, "ssh")
    File.write!(ssh_path, "#!/bin/sh\nexit 0\n")
    File.chmod!(ssh_path, 0o755)

    original_path = System.get_env("PATH")
    new_path = if original_path, do: tmp <> ":" <> original_path, else: tmp
    System.put_env("PATH", new_path)

    on_exit(fn ->
      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end

      File.rm_rf!(tmp)
    end)

    fun.()
  end
end
