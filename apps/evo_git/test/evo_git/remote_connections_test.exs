defmodule EvoGit.RemoteConnectionsTest do
  use ExUnit.Case, async: false

  # Tests mutate the XDG_CONFIG_HOME env var so that RemoteConnections never
  # touches the real ~/.config/genesis/ directory.
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

  describe "list/0" do
    test "returns [] when no file exists" do
      assert EvoGit.RemoteConnections.list() == []
    end
  end

  describe "save/1" do
    test "succeeds with just a host, auto-generating id and name, applying defaults" do
      assert {:ok, target} = EvoGit.RemoteConnections.save(%{host: "example.com"})

      assert target.host == "example.com"
      assert target.name == "example.com"
      assert is_binary(target.id)
      # dots are non-alphanumeric, so slugified to underscores
      assert target.id == "example_com"
      assert target.port == 22
      assert target.dist_port == 9000
      assert target.remote_path == "/tmp/genesis_engine"
      assert is_nil(target.identity_file)
      assert is_nil(target.last_connected)
    end

    test "extracts user from user@host.com when user not provided" do
      assert {:ok, target} = EvoGit.RemoteConnections.save(%{host: "alice@example.com"})

      assert target.host == "alice@example.com"
      assert target.user == "alice"
      assert target.name == "alice@example.com"
    end

    test "preserves an explicit user over the host-derived one" do
      assert {:ok, target} =
               EvoGit.RemoteConnections.save(%{host: "alice@example.com", user: "bob"})

      assert target.user == "bob"
    end

    test "returns {:error, :missing_host} when host is absent" do
      assert {:error, :missing_host} = EvoGit.RemoteConnections.save(%{name: "no host"})
    end

    test "returns {:error, :missing_host} when host is empty" do
      assert {:error, :missing_host} = EvoGit.RemoteConnections.save(%{host: ""})
    end

    test "updates an existing target when the same id is saved again" do
      assert {:ok, _target} = EvoGit.RemoteConnections.save(%{host: "example.com", port: 2222})

      assert {:ok, updated} =
               EvoGit.RemoteConnections.save(%{host: "example.com", port: 2222, name: "Prod"})

      assert updated.name == "Prod"
      assert updated.port == 2222

      list = EvoGit.RemoteConnections.list()
      assert length(list) == 1
      assert hd(list).name == "Prod"
    end

    test "appends a new target when the id does not exist" do
      assert {:ok, _t1} = EvoGit.RemoteConnections.save(%{host: "a.com"})
      assert {:ok, _t2} = EvoGit.RemoteConnections.save(%{host: "b.com"})

      list = EvoGit.RemoteConnections.list()
      assert length(list) == 2
    end
  end

  describe "get/1" do
    test "returns the target when found" do
      assert {:ok, saved} = EvoGit.RemoteConnections.save(%{host: "example.com"})
      assert {:ok, fetched} = EvoGit.RemoteConnections.get(saved.id)
      assert fetched.host == "example.com"
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = EvoGit.RemoteConnections.get("does-not-exist")
    end
  end

  describe "delete/1" do
    test "removes the target and returns :ok" do
      assert {:ok, saved} = EvoGit.RemoteConnections.save(%{host: "example.com"})
      assert :ok = EvoGit.RemoteConnections.delete(saved.id)
      assert EvoGit.RemoteConnections.list() == []
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = EvoGit.RemoteConnections.delete("nope")
    end
  end

  describe "touch/1" do
    test "sets the last_connected timestamp and returns :ok" do
      assert {:ok, saved} = EvoGit.RemoteConnections.save(%{host: "example.com"})
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

  describe "persistence round-trip" do
    test "writes [[connections]] TOML and re-reads it via list/0" do
      assert {:ok, _t1} =
               EvoGit.RemoteConnections.save(%{
                 host: "deploy@prod.example.com",
                 port: 2222,
                 dist_port: 9100,
                 identity_file: "/home/user/.ssh/id_ed25519"
               })

      assert {:ok, _t2} =
               EvoGit.RemoteConnections.save(%{host: "staging.example.com", user: "ci"})

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
        Enum.find(list, fn c -> String.contains?(c.host, "prod.example.com") end)

      assert prod != nil
      assert prod.host == "deploy@prod.example.com"
      assert prod.user == "deploy"
      assert prod.port == 2222
      assert prod.dist_port == 9100
      assert prod.identity_file == "/home/user/.ssh/id_ed25519"

      staging = Enum.find(list, fn c -> c.host == "staging.example.com" end)
      assert staging != nil
      assert staging.user == "ci"
    end

    test "survives reading string-keyed data with fields in any order" do
      config_dir = EvoGit.Config.config_dir()
      File.mkdir_p!(config_dir)

      toml = """
      [[connections]]
      id = "manual-id"
      host = "manual.example.com"
      port = 2200
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
      assert conn.host == "manual.example.com"
      assert conn.port == 2200
      assert conn.dist_port == 9022
      assert conn.name == "Manual Box"
      assert conn.remote_path == "/opt/genesis"
    end
  end
end
