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
          assert output =~ "arg2=#{remote_cmd}\n"
          refute output =~ "arg3="
        end)
      end

      test "shell metacharacters are not interpreted locally (arrive as one arg)" do
        with_fake_ssh(fn ->
          remote_cmd = "echo hi | cat; test -f /tmp/x && echo yes || echo no"

          assert {:ok, output, 0} =
                   EvoGit.RemoteConnection.run_ssh_command("fake@example.com", remote_cmd, 5_000)

          assert output =~ "argv=2\n"
          assert output =~ "arg2=#{remote_cmd}\n"
        end)
      end
    end

    describe "bootstrap/1 with fake ssh" do
      # Writes a fake `ssh` + fake `scp` onto PATH and returns
      # %{log:, marker:, tarball:}. The fake ssh receives $1 = ssh_target and
      # $2 = the remote command (ONE argv element), logs every command to the
      # log file, and dispatches on $2. Daemon state is emulated via a marker
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
            "uname -s && uname -m"*) printf 'Linux\nx86_64\n'; exit 0 ;;
            "uname -s"*) printf '__OS__\n'; exit 0 ;;
            "systemctl --user is-active"*) if [ -f "$marker" ]; then printf 'active\n'; else printf 'inactive\n'; fi; exit 0 ;;
            "systemctl --user reset-failed"*) exit 0 ;;
            "systemd-run"*) touch "$marker"; exit 0 ;;
            "launchctl unload"*) touch "$marker"; exit 0 ;;
            "launchctl list"*) if [ -f "$marker" ]; then printf '1234\t0\tcom.genesis.remote.test\n'; fi; exit 0 ;;
            "launchctl"*) exit 0 ;;
            "test -d /etc/nixos"*) printf '__DETECT__\n'; exit 0 ;;
            *nix-build*) printf '%s\n' '__PATCH_OUTPUT__'; exit __PATCH_EXIT__ ;;
            "curl"*|"wget"*) exit 0 ;;
            "mkdir"*|"tar"*|"chmod"*|"test -f"*) exit 0 ;;
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

      test "daemon already running → no detection, no patch" do
        ensure_registry_and_supervisor()

        with_fake_ssh_tools([os: "Linux", daemon_active?: true], fn %{
                                                                      log: log,
                                                                      tarball: tarball
                                                                    } ->
          target_id = save_test_target(local_binary_path: tarball)
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "remote_connections")

          assert {:ok, :daemon_started} = EvoGit.RemoteConnection.bootstrap(target_id)

          log_content = File.read!(log)
          refute log_content =~ "test -d /etc/nixos"
          refute log_content =~ "nix-build"

          stages = collect_stages(target_id)
          refute :patching_binaries in stages
          refute :starting_daemon in stages

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
