defmodule EvoGit.RemoteConnectionTest do
  @moduledoc """
  Tests for `EvoGit.RemoteConnection` — the GenServer managing a single SSH
  remote connection's lifecycle.

  Uses `async: false` because the tests interact with the Registry /
  DynamicSupervisor that are part of the application supervision tree.
  """

  use ExUnit.Case, async: false

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
      target_id = save_test_target(local_binary_path: tmp)

      assert {:error, {:scp_failed, _}} = EvoGit.RemoteConnection.bootstrap(target_id)

      File.rm!(tmp)
      cleanup_connections()
    end
  end

  describe "connect/1" do
    test "does not return :local_node_not_distributed (auto-enables distribution)" do
      ensure_registry_and_supervisor()
      target_id = save_test_target()

      # With the fix, do_connect auto-enables distribution instead of
      # returning :local_node_not_distributed. The actual SSH connection
      # will fail (no real remote), but the error should be something else
      # (e.g. :distribution_failed or :node_connect_failed).
      result = EvoGit.RemoteConnection.connect(target_id)
      refute match?({:error, :local_node_not_distributed}, result)

      cleanup_connections()
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
      # file: `systemd-run` / `launchctl load` touch it, while
      # `systemctl --user is-active` / `launchctl list` report active /
      # non-empty only when it exists — so the post-start health check
      # succeeds after the daemon is "started". Options: :os (default Linux),
      # :detect ("yes"/"no" for the NixOS detection command), :patch_exit,
      # :patch_output, :daemon_active? (pre-create the marker).
      defp with_fake_ssh_tools(opts, fun) do
        tmp =
          Path.join(
            System.tmp_dir!(),
            "evogit-test-ssh-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(tmp)

        log = Path.join(tmp, "ssh.log")
        marker = Path.join(tmp, "daemon.marker")

        if Keyword.get(opts, :daemon_active?, false) do
          File.touch!(marker)
        end

        script =
          ~S"""
          #!/bin/sh
          log="__LOG__"
          marker="__MARKER__"
          printf '%s\n' "$2" >> "$log"
          case "$2" in
            *"uname -s && uname -m"*) printf 'Linux\nx86_64\n'; exit 0 ;;
            *"uname -s"*) printf '__OS__\n'; exit 0 ;;
            *"systemctl --user is-active"*) if [ -f "$marker" ]; then printf 'active\n'; else printf 'inactive\n'; fi; exit 0 ;;
            *"systemctl --user show"*) if [ -n "$FAKE_UNIT_RELEASE_NODE" ] || [ -n "$FAKE_UNIT_RELEASE_COOKIE" ]; then printf 'RELEASE_NODE=%s RELEASE_COOKIE=%s\n' "$FAKE_UNIT_RELEASE_NODE" "$FAKE_UNIT_RELEASE_COOKIE"; fi; exit 0 ;;
            *"systemctl --user reset-failed"*) exit 0 ;;
            *"systemd-run"*) touch "$marker"; exit 0 ;;
            *"launchctl unload"*) touch "$marker"; exit 0 ;;
            *"launchctl list"*) if [ -f "$marker" ]; then printf '1234\t0\tcom.genesis.remote.test\n'; fi; exit 0 ;;
            *"cat ~/Library/LaunchAgents"*) if [ -n "$FAKE_UNIT_RELEASE_NODE" ] || [ -n "$FAKE_UNIT_RELEASE_COOKIE" ]; then printf '<plist><dict><key>RELEASE_NODE</key><string>%s</string><key>RELEASE_COOKIE</key><string>%s</string></dict></plist>\n' "$FAKE_UNIT_RELEASE_NODE" "$FAKE_UNIT_RELEASE_COOKIE"; fi; exit 0 ;;
            *"launchctl"*) exit 0 ;;
            *"test -d /etc/nixos"*) printf '__DETECT__\n'; exit 0 ;;
            *nix-build*) printf '%s\n' '__PATCH_OUTPUT__'; exit __PATCH_EXIT__ ;;
            *"curl"*|*"wget"*) exit 0 ;;
            *"mkdir"*|*"tar"*|*"chmod"*|*"test -f"*) exit 0 ;;
            *) exit 0 ;;
          esac
          """
          |> String.replace("__LOG__", log)
          |> String.replace("__MARKER__", marker)
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

        ssh_path = Path.join(tmp, "ssh")
        scp_path = Path.join(tmp, "scp")

        File.write!(ssh_path, script)
        File.chmod!(ssh_path, 0o755)

        # The local-tarball path shells out to real `scp` via run_cmd
        # ({:spawn, "scp ..."} → /bin/sh -c) — a fake scp on PATH intercepts it.
        File.write!(scp_path, "#!/bin/sh\nexit 0\n")
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
          # (set via set_fake_unit_env/2) so they don't leak into sibling tests.
          System.delete_env("FAKE_UNIT_RELEASE_NODE")
          System.delete_env("FAKE_UNIT_RELEASE_COOKIE")

          File.rm_rf!(tmp)
        end)

        tarball = Path.join(tmp, "local.tar.xz")
        File.write!(tarball, "fake tarball")

        fun.(%{log: log, marker: marker, tarball: tarball})
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

      # Makes the fake ssh echo a MATCHING unit Environment (RELEASE_NODE +
      # RELEASE_COOKIE) for the daemon-identity verification. Must be called
      # before bootstrap; the values are inherited by Port.open children at
      # spawn time. Cleaned up in with_fake_ssh_tools' on_exit.
      defp set_fake_unit_env(target_id, cookie) do
        System.put_env("FAKE_UNIT_RELEASE_NODE", "genesis_remote_#{target_id}@127.0.0.1")
        System.put_env("FAKE_UNIT_RELEASE_COOKIE", cookie)
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

      test "daemon already running + matching identity → no detection, no patch" do
        ensure_registry_and_supervisor()

        cookie = "test-cookie-matching-daemon"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Linux", daemon_active?: true], fn %{
                                                                      log: log,
                                                                      tarball: tarball
                                                                    } ->
          target_id = save_test_target(local_binary_path: tarball)
          set_fake_unit_env(target_id, cookie)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          log_content = File.read!(log)
          refute log_content =~ "test -d /etc/nixos"
          refute log_content =~ "nix-build"

          # the identity verification ran against the running unit
          assert log_content =~ "systemctl --user show"

          stages = collect_stages(target_id)
          refute :patching_binaries in stages
          refute :starting_daemon in stages

          cleanup_connections()
        end)
      end

      test "daemon already running but env is STALE (different cookie) → identity mismatch with remediation" do
        ensure_registry_and_supervisor()

        cookie = "current-contract-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Linux", daemon_active?: true], fn %{tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          # Fake ssh echoes the CORRECT node but a STALE cookie — like a daemon
          # launched by an older bootstrap whose cookie differs from the local
          # config.toml [node] cookie.
          System.put_env("FAKE_UNIT_RELEASE_NODE", "genesis_remote_#{target_id}@127.0.0.1")
          System.put_env("FAKE_UNIT_RELEASE_COOKIE", "old-stale-cookie")
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:error, {:daemon_identity_mismatch, details}} =
                   EvoGit.RemoteConnection.bootstrap(target_id)

          assert details =~ "systemctl --user stop genesis-remote-#{target_id}"
          assert details =~ "old-stale-cookie"
          assert details =~ "current-contract-cookie"

          # the running daemon was never touched — no :starting_daemon broadcast
          stages = collect_stages(target_id)
          refute :starting_daemon in stages

          cleanup_connections()
        end)
      end

      test "daemon already running with NO RELEASE_COOKIE (pre-cookie-era daemon) → identity mismatch" do
        ensure_registry_and_supervisor()

        cookie = "current-contract-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Linux", daemon_active?: true], fn %{tarball: tarball} ->
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

      test "macOS daemon already running + matching plist → :ok, no :starting_daemon" do
        ensure_registry_and_supervisor()

        cookie = "macos-test-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Darwin", daemon_active?: true], fn %{tarball: tarball} ->
          target_id = save_test_target(local_binary_path: tarball)
          set_fake_unit_env(target_id, cookie)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          stages = collect_stages(target_id)
          refute :starting_daemon in stages

          cleanup_connections()
        end)
      end

      test "macOS daemon already running but plist is stale → identity mismatch with launchctl remediation" do
        ensure_registry_and_supervisor()

        cookie = "macos-test-cookie"
        write_test_config_cookie(cookie)

        with_fake_ssh_tools([os: "Darwin", daemon_active?: true], fn %{tarball: tarball} ->
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
    end
  end
end
