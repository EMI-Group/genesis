defmodule EvoGit.RemoteConnectionsTest do
  # `async: true` — every case is isolated on all three axes these cases observe:
  #
  #   1. FILES: each case works in its own per-test config directory, whose name
  #      `EvoGit.TestSupport.ConfigDir` makes unique across BEAMs AND processes
  #      (`<prefix>-<os pid>-<unique int>-<random>`), so no case can read, create
  #      or clobber another's file (nor the real `~/.config/genesis/`).
  #   2. LOGS: `ExUnit.CaptureLog`'s handler sees the WHOLE node, so no assertion
  #      here is an "any log at all" count — every one matches THIS test's own
  #      unique path (`.../<unique dir>/remote_connections.toml`), which a
  #      concurrently running module can neither produce nor suppress.
  #   3. The once-per-failure memo in `:persistent_term` is keyed per
  #      `{file_path, reason}` IDENTITY, so a concurrent module can only ever
  #      touch its own entry; this module additionally resets the whole memo
  #      before and after every case.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TestSupport.ConfigDir

  # Mirrors the production memo key (see `EvoGit.RemoteConnections`), whose value
  # is the MAP of already-logged `{file_path, reason}` identities: it is
  # BEAM-global, so it is cleared before AND after every case.
  @failure_memo_key {EvoGit.RemoteConnections, :ensure_file_failure}

  setup do
    ConfigDir.isolate!("evogit-remote-connections")
    clear_failure_memo()
    on_exit(fn -> clear_failure_memo() end)
    :ok
  end

  describe "list/0" do
    test "returns [] when no file exists" do
      assert EvoGit.RemoteConnections.list() == []
    end
  end

  describe "ensure_file/0" do
    test "creates the skeleton file on a clean config dir and logs nothing" do
      toml_path = Path.join(EvoGit.Config.config_dir(), "remote_connections.toml")

      log = capture_log(fn -> assert :ok = EvoGit.RemoteConnections.ensure_file() end)

      # Path-scoped (never `log == ""`): the capture is node-wide, so another
      # module's warning is irrelevant — ours must simply be absent.
      refute log =~ failure_prefix(toml_path)
      assert File.exists?(toml_path)
      assert File.read!(toml_path) =~ "Genesis Remote Connections"
    end

    test "is idempotent — an existing file is neither rewritten nor clobbered" do
      config_dir = EvoGit.Config.config_dir()
      toml_path = Path.join(config_dir, "remote_connections.toml")
      File.mkdir_p!(config_dir)

      existing = """
      [[connections]]
      id = "keep-me"
      ssh_target = "keep.example.com"
      """

      File.write!(toml_path, existing)

      log = capture_log(fn -> assert :ok = EvoGit.RemoteConnections.ensure_file() end)

      refute log =~ failure_prefix(toml_path)
      assert File.read!(toml_path) == existing
      assert [%{id: "keep-me"}] = EvoGit.RemoteConnections.list()
    end

    test "returns the primitive error reason (total, non-raising) when the config dir is unusable" do
      config_dir = block_config_dir!()
      toml_path = Path.join(config_dir, "remote_connections.toml")

      log =
        capture_log(fn ->
          # `File.mkdir_p/1` normalizes "path exists but is not a directory" to
          # `:enotdir`; the caller must see that reason, not a collapsed atom.
          assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file()
        end)

      assert log =~ "Failed to create remote connections file at #{toml_path}"
      assert log =~ ":enotdir"
      refute File.exists?(toml_path)
    end

    test "list/0 still returns [] when the file cannot be created" do
      config_dir = block_config_dir!()
      toml_path = Path.join(config_dir, "remote_connections.toml")

      log = capture_log(fn -> assert EvoGit.RemoteConnections.list() == [] end)

      assert log =~ failure_prefix(toml_path)
    end
  end

  describe "ensure_file/0 failure logging" do
    test "warns exactly once per failure identity across repeated calls" do
      config_dir = block_config_dir!()

      message = failure_prefix(Path.join(config_dir, "remote_connections.toml"))

      log =
        capture_log(fn ->
          assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file()
          assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file()
          # The dashboard's `list/0` caller hits the same identity — still silent.
          assert EvoGit.RemoteConnections.list() == []
        end)

      assert count_occurrences(log, message) == 1
    end

    test "a changed failure identity logs a fresh warning" do
      first_config_dir = block_config_dir!()
      first_path = Path.join(first_config_dir, "remote_connections.toml")

      first_log =
        capture_log(fn -> assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file() end)

      assert count_occurrences(first_log, "at #{first_path}:") == 1

      # Identical repeat: the memo suppresses it.
      repeat_log =
        capture_log(fn -> assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file() end)

      assert count_occurrences(repeat_log, "at #{first_path}:") == 0

      # A different config dir means a different PATH — a new failure identity.
      second_override = ConfigDir.isolate!("evogit-remote-connections-second")
      second_config_dir = Path.join(second_override, "genesis")
      File.write!(second_config_dir, "not a directory")
      second_path = Path.join(second_config_dir, "remote_connections.toml")

      second_log =
        capture_log(fn -> assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file() end)

      assert count_occurrences(second_log, "at #{second_path}:") == 1
    end

    test "interleaved distinct identities each warn exactly once (A -> B -> A warns twice)" do
      first_base = ConfigDir.isolate!("evogit-remote-connections-interleaved-a")
      second_base = ConfigDir.isolate!("evogit-remote-connections-interleaved-b")

      first_message =
        failure_prefix(Path.join(block_config_dir!(first_base), "remote_connections.toml"))

      second_message =
        failure_prefix(Path.join(block_config_dir!(second_base), "remote_connections.toml"))

      log =
        capture_log(fn ->
          use_config_dir!(first_base)
          assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file()

          use_config_dir!(second_base)
          assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file()

          # A again. A single last-value slot forgets A as soon as B is logged, so
          # this third call used to warn for A a SECOND time (three warnings in
          # total). Per-identity memoization logs A once and B once: 2, not 3.
          use_config_dir!(first_base)
          assert {:error, :enotdir} = EvoGit.RemoteConnections.ensure_file()
        end)

      assert count_occurrences(log, first_message) == 1
      assert count_occurrences(log, second_message) == 1
    end
  end

  describe "save/1" do
    test "succeeds with just an ssh_target, auto-generating id and name, applying defaults" do
      assert {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: "example.com"})

      assert target.ssh_target == "example.com"
      assert target.name == "example.com"
      assert is_binary(target.id)
      # dots are non-alphanumeric, so slugified to underscores
      assert target.id == "example_com"
      assert target.dist_port == 9000
      assert target.remote_path == "/tmp/genesis_server"
      assert is_nil(target.local_binary_path)
      assert is_nil(target.last_connected)
    end

    test "accepts user@host ssh_target" do
      assert {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: "alice@example.com"})

      assert target.ssh_target == "alice@example.com"
      assert target.name == "alice@example.com"
    end

    test "uses provided name over ssh_target for name and id" do
      assert {:ok, target} =
               EvoGit.RemoteConnections.save(%{ssh_target: "example.com", name: "Prod Server"})

      assert target.name == "Prod Server"
      assert target.id == "prod_server"
    end

    test "preserves local_binary_path" do
      assert {:ok, target} =
               EvoGit.RemoteConnections.save(%{
                 ssh_target: "example.com",
                 local_binary_path: "_build/prod/rel/genesis_server.tar.xz"
               })

      assert target.local_binary_path == "_build/prod/rel/genesis_server.tar.xz"
    end

    test "returns {:error, :missing_ssh_target} when ssh_target is absent" do
      assert {:error, :missing_ssh_target} = EvoGit.RemoteConnections.save(%{name: "no target"})
    end

    test "returns {:error, :missing_ssh_target} when ssh_target is empty" do
      assert {:error, :missing_ssh_target} = EvoGit.RemoteConnections.save(%{ssh_target: ""})
    end

    test "updates an existing target when the same id is saved again" do
      assert {:ok, _target} =
               EvoGit.RemoteConnections.save(%{ssh_target: "example.com", name: "Prod"})

      assert {:ok, updated} =
               EvoGit.RemoteConnections.save(%{
                 ssh_target: "example.com",
                 name: "Prod",
                 dist_port: 9100
               })

      assert updated.name == "Prod"
      assert updated.dist_port == 9100

      list = EvoGit.RemoteConnections.list()
      assert length(list) == 1
      assert hd(list).name == "Prod"
    end

    test "appends a new target when the id does not exist" do
      assert {:ok, _t1} = EvoGit.RemoteConnections.save(%{ssh_target: "a.com"})
      assert {:ok, _t2} = EvoGit.RemoteConnections.save(%{ssh_target: "b.com"})

      list = EvoGit.RemoteConnections.list()
      assert length(list) == 2
    end
  end

  describe "platform field" do
    test "platform is preserved on save" do
      assert {:ok, target} =
               EvoGit.RemoteConnections.save(%{ssh_target: "example.com", platform: "linux_x64"})

      assert target.platform == "linux_x64"
    end

    test "platform is nil by default" do
      assert {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: "example.com"})
      assert is_nil(target.platform)
    end

    test "platform round-trips through the TOML file" do
      assert {:ok, _target} =
               EvoGit.RemoteConnections.save(%{
                 ssh_target: "example.com",
                 platform: "darwin_arm64"
               })

      list = EvoGit.RemoteConnections.list()
      assert length(list) == 1
      assert hd(list).platform == "darwin_arm64"
    end

    test "invalid platform strings are stored as-is (no format validation here)" do
      assert {:ok, target} =
               EvoGit.RemoteConnections.save(%{ssh_target: "example.com", platform: "bogus"})

      assert target.platform == "bogus"
    end
  end

  describe "get/1" do
    test "returns the target when found" do
      assert {:ok, saved} = EvoGit.RemoteConnections.save(%{ssh_target: "example.com"})
      assert {:ok, fetched} = EvoGit.RemoteConnections.get(saved.id)
      assert fetched.ssh_target == "example.com"
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = EvoGit.RemoteConnections.get("does-not-exist")
    end
  end

  describe "delete/1" do
    test "removes the target and returns :ok" do
      assert {:ok, saved} = EvoGit.RemoteConnections.save(%{ssh_target: "example.com"})
      assert :ok = EvoGit.RemoteConnections.delete(saved.id)
      assert EvoGit.RemoteConnections.list() == []
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = EvoGit.RemoteConnections.delete("nope")
    end
  end

  describe "touch/1" do
    test "sets the last_connected timestamp and returns :ok" do
      assert {:ok, saved} = EvoGit.RemoteConnections.save(%{ssh_target: "example.com"})
      assert is_nil(saved.last_connected)

      assert :ok = EvoGit.RemoteConnections.touch(saved.id)

      assert {:ok, updated} = EvoGit.RemoteConnections.get(saved.id)
      assert updated.last_connected != nil

      # Should be a parseable ISO8601 timestamp.
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(updated.last_connected)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = EvoGit.RemoteConnections.touch("nope")
    end
  end

  describe "old field rejection" do
    test "rejects old host field — requires ssh_target" do
      assert {:error, :missing_ssh_target} =
               EvoGit.RemoteConnections.save(%{host: "example.com"})
    end

    test "rejects old host+user fields — requires ssh_target" do
      assert {:error, :missing_ssh_target} =
               EvoGit.RemoteConnections.save(%{host: "example.com", user: "alice"})
    end

    test "rejects old host+user+port fields — requires ssh_target" do
      assert {:error, :missing_ssh_target} =
               EvoGit.RemoteConnections.save(%{host: "example.com", user: "bob", port: 2222})
    end

    test "ignores old host/user fields when ssh_target is present" do
      assert {:ok, target} =
               EvoGit.RemoteConnections.save(%{
                 ssh_target: "new@example.com",
                 host: "old.example.com",
                 user: "olduser"
               })

      assert target.ssh_target == "new@example.com"
    end
  end

  describe "persistence round-trip" do
    test "writes [[connections]] TOML and re-reads it via list/0" do
      assert {:ok, _t1} =
               EvoGit.RemoteConnections.save(%{
                 ssh_target: "deploy@prod.example.com",
                 local_binary_path: "_build/prod/rel/genesis_server.tar.xz",
                 dist_port: 9100
               })

      assert {:ok, _t2} =
               EvoGit.RemoteConnections.save(%{ssh_target: "staging.example.com"})

      # The TOML file should exist on disk with array-of-tables format.
      config_dir = EvoGit.Config.config_dir()
      toml_path = Path.join(config_dir, "remote_connections.toml")
      assert File.exists?(toml_path)

      contents = File.read!(toml_path)
      assert contents =~ "[[connections]]"

      # Re-read via the public API and verify the data round-trips.
      list = EvoGit.RemoteConnections.list()
      assert length(list) == 2

      prod =
        Enum.find(list, fn c -> String.contains?(c.ssh_target, "prod.example.com") end)

      assert prod != nil
      assert prod.ssh_target == "deploy@prod.example.com"
      assert prod.dist_port == 9100
      assert prod.local_binary_path == "_build/prod/rel/genesis_server.tar.xz"

      staging = Enum.find(list, fn c -> c.ssh_target == "staging.example.com" end)
      assert staging != nil
    end

    test "survives reading string-keyed data with fields in any order" do
      config_dir = EvoGit.Config.config_dir()
      File.mkdir_p!(config_dir)

      toml = """
      [[connections]]
      id = "manual-id"
      ssh_target = "manual.example.com"
      dist_port = 9022
      name = "Manual Box"
      remote_path = "/opt/genesis"
      """

      toml_path = Path.join(config_dir, "remote_connections.toml")
      File.write!(toml_path, toml)

      list = EvoGit.RemoteConnections.list()
      assert length(list) == 1

      conn = hd(list)
      assert conn.id == "manual-id"
      assert conn.ssh_target == "manual.example.com"
      assert conn.dist_port == 9022
      assert conn.name == "Manual Box"
      assert conn.remote_path == "/opt/genesis"
    end
  end

  # --- Helpers ---

  # The exact warning PREFIX the module emits for one file path. Every log
  # assertion goes through this so it can only ever match THIS test's own
  # (unique) directory — the capture handler is node-wide and shared with every
  # concurrently running module.
  defp failure_prefix(toml_path), do: "Failed to create remote connections file at #{toml_path}"

  # Clears the BEAM-global once-per-failure memo (a `:persistent_term` key), so
  # no case inherits suppression and no other module inherits ours.
  defp clear_failure_memo do
    case :persistent_term.get(@failure_memo_key, nil) do
      nil -> :ok
      _ -> :persistent_term.erase(@failure_memo_key)
    end
  end

  # Points this process' config-dir seam at `base` (the directory
  # `EvoGit.Platform.config_dir("genesis")` joins `"genesis"` onto).
  # `ConfigDir.activate/1` is not usable here: it records an ownership marker
  # INSIDE the directory, and these directories are deliberately occupied by a
  # regular FILE so `File.mkdir_p/1` must fail.
  defp use_config_dir!(base), do: Process.put(:evogit_config_dir, base)

  # Occupies `<config_dir>` with a REGULAR FILE, so `File.mkdir_p/1` must fail:
  # Elixir normalizes "path exists but is not a directory" to `{:error, :enotdir}`
  # (deterministic on every OS). `base` selects which isolated config directory to
  # block (default: the current process' override). Returns the config dir path.
  defp block_config_dir!(base \\ nil) do
    config_dir = if base, do: Path.join(base, "genesis"), else: EvoGit.Config.config_dir()
    File.mkdir_p!(Path.dirname(config_dir))
    File.write!(config_dir, "not a directory")
    config_dir
  end

  defp count_occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
