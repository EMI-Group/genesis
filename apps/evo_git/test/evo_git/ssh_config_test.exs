defmodule EvoGit.SSHConfigTest do
  use ExUnit.Case, async: true

  # ── Helpers ────────────────────────────────────────────────────────────

  defp with_ssh_config(contents, callback) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit-ssh-config-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    config_path = Path.join(tmp_dir, "config")
    File.write!(config_path, contents)

    result = callback.(config_path, tmp_dir)
    File.rm_rf!(tmp_dir)
    result
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "parse/1" do
    test "returns empty list for missing file" do
      assert EvoGit.SSHConfig.parse("/nonexistent/path/ssh_config_xyz") == []
    end

    test "returns empty list for empty file" do
      with_ssh_config("", fn config_path, _tmp_dir ->
        assert EvoGit.SSHConfig.parse(config_path) == []
      end)
    end

    test "returns empty list for file with only comments and blank lines" do
      config = """
      # This is a comment

      # Another comment
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        assert EvoGit.SSHConfig.parse(config_path) == []
      end)
    end

    test "parses Host blocks with key-value pairs" do
      config = """
      Host myserver
          HostName example.com
          User myuser
          Port 2222
          IdentityFile ~/.ssh/id_ed25519
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1

        {patterns, entries} = hd(blocks)
        assert patterns == ["myserver"]
        assert entries[:hostname] == "example.com"
        assert entries[:user] == "myuser"
        assert entries[:port] == "2222"
        assert entries[:identityfile] =~ "id_ed25519"
      end)
    end

    test "parses multiple Host blocks" do
      config = """
      Host server1
          User user1
          Port 2201

      Host server2
          User user2
          Port 2202
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 2

        {patterns1, entries1} = Enum.at(blocks, 0)
        assert patterns1 == ["server1"]
        assert entries1[:user] == "user1"

        {patterns2, entries2} = Enum.at(blocks, 1)
        assert patterns2 == ["server2"]
        assert entries2[:user] == "user2"
      end)
    end

    test "parses Host with multiple space-separated patterns" do
      config = """
      Host server1 server2 server3
          User shareduser
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1
        {patterns, _entries} = hd(blocks)
        assert patterns == ["server1", "server2", "server3"]
      end)
    end

    test "parses Host * wildcard block" do
      config = """
      Host *
          User defaultuser
          IdentityFile ~/.ssh/id_rsa
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1
        {patterns, entries} = hd(blocks)
        assert patterns == ["*"]
        assert entries[:user] == "defaultuser"
      end)
    end

    test "ignores directives outside Host blocks" do
      config = """
      User orphan_user
      Port 9999

      Host myserver
          User real_user
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1
        {_patterns, entries} = hd(blocks)
        assert entries[:user] == "real_user"
        # orphan directives are ignored
      end)
    end

    test "handles case-insensitive directive names" do
      config = """
      HOST myserver
          hostname Example.COM
          USER MyUser
          port 2222
          identityfile ~/.ssh/key
          proxyjump jump.example.com
          proxycommand ssh -W %h:%p gateway
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1
        {patterns, entries} = hd(blocks)
        assert patterns == ["myserver"]
        assert entries[:hostname] == "Example.COM"
        assert entries[:user] == "MyUser"
        assert entries[:port] == "2222"
        assert entries[:identityfile] =~ "key"
        assert entries[:proxyjump] == "jump.example.com"
        assert entries[:proxycommand] == "ssh -W %h:%p gateway"
      end)
    end

    test "handles inline comments" do
      config = """
      Host myserver # this is my server
          User myuser # my user
          Port 2222   # non-standard port
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1
        {_patterns, entries} = hd(blocks)
        assert entries[:user] == "myuser"
        assert entries[:port] == "2222"
      end)
    end

    test "expands tilde in IdentityFile paths" do
      home = System.user_home!()

      config = """
      Host myserver
          IdentityFile ~/.ssh/id_custom
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        {_patterns, entries} = hd(blocks)
        assert entries[:identityfile] == Path.join(home, ".ssh/id_custom")
      end)
    end

    test "parses Include directive with a single file" do
      with_ssh_config("", fn config_path, tmp_dir ->
        # Write an included file
        included_path = Path.join(tmp_dir, "included.conf")
        File.write!(included_path, """
        Host extra
            User extrauser
            Port 2223
        """)

        config_with_include = """
        Host main
            User mainuser

        Include #{included_path}
        """

        File.write!(config_path, config_with_include)

        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 2

        {patterns1, entries1} = Enum.at(blocks, 0)
        assert patterns1 == ["main"]
        assert entries1[:user] == "mainuser"

        {patterns2, entries2} = Enum.at(blocks, 1)
        assert patterns2 == ["extra"]
        assert entries2[:user] == "extrauser"
      end)
    end

    test "handles missing included file silently" do
      with_ssh_config("", fn config_path, tmp_dir ->
        config_with_include = """
        Host main
            User mainuser

        Include #{tmp_dir}/nonexistent.conf
        """

        File.write!(config_path, config_with_include)

        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1
        {patterns, _entries} = hd(blocks)
        assert patterns == ["main"]
      end)
    end

    test "guards against infinite recursion via Include cycle" do
      with_ssh_config("", fn config_path, tmp_dir ->
        included_path = Path.join(tmp_dir, "included.conf")
        File.write!(included_path, """
        Include #{config_path}
        Host extra
            User extrauser
        """)

        config_with_include = """
        Host main
            User mainuser

        Include #{included_path}
        """

        File.write!(config_path, config_with_include)

        # Should not hang — visited set prevents re-parsing the same file
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) >= 1
      end)
    end

    test "silently ignores unknown directives inside Host blocks" do
      config = """
      Host myserver
          HostName example.com
          User myuser
          IdentitiesOnly yes
          ForwardAgent no
          ServerAliveInterval 60
          Port 2222
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1

        {_patterns, entries} = hd(blocks)
        # Known directives are still parsed
        assert entries[:hostname] == "example.com"
        assert entries[:user] == "myuser"
        assert entries[:port] == "2222"
        # Unknown directives are NOT in the entries
        refute Keyword.has_key?(entries, :identitiesonly)
        refute Keyword.has_key?(entries, :forwardagent)
        refute Keyword.has_key?(entries, :serveraliveinterval)
      end)
    end

    test "handles Key=Value syntax for directives" do
      config = """
      Host myserver
          HostName=example.com
          User=myuser
          Port=2222
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1

        {_patterns, entries} = hd(blocks)
        assert entries[:hostname] == "example.com"
        assert entries[:user] == "myuser"
        assert entries[:port] == "2222"
      end)
    end

    test "handles Key=Value syntax for unknown directives without crashing" do
      config = """
      Host myserver
          HostName example.com
          IdentitiesOnly=yes
          ForwardAgent=no
          User myuser
      """

      with_ssh_config(config, fn config_path, _tmp_dir ->
        blocks = EvoGit.SSHConfig.parse(config_path)
        assert length(blocks) == 1

        {_patterns, entries} = hd(blocks)
        assert entries[:hostname] == "example.com"
        assert entries[:user] == "myuser"
        # Unknown directives are not stored
        refute Keyword.has_key?(entries, :identitiesonly)
        refute Keyword.has_key?(entries, :forwardagent)
      end)
    end
  end

  describe "lookup/2" do
    test "returns empty map when no blocks match" do
      blocks = parse_config("Host myserver\n    User myuser\n")
      assert EvoGit.SSHConfig.lookup("otherserver", blocks) == %{}
    end

    test "returns empty map when blocks list is empty" do
      assert EvoGit.SSHConfig.lookup("example.com", []) == %{}
    end

    test "looks up user, port, and identity_file from matching block" do
      blocks =
        parse_config("""
        Host myserver
            User myuser
            Port 2222
            IdentityFile ~/.ssh/id_ed
        """)

      result = EvoGit.SSHConfig.lookup("myserver", blocks)
      assert result[:user] == "myuser"
      assert result[:port] == 2222
      assert result[:identity_file] =~ "id_ed"
    end

    test "lookup is case-insensitive for hostnames" do
      blocks =
        parse_config("""
        Host MyServer
            User myuser
        """)

      result = EvoGit.SSHConfig.lookup("myserver", blocks)
      assert result[:user] == "myuser"
    end

    test "first match wins for overlapping keys" do
      blocks =
        parse_config("""
        Host myserver
            User first_user
            Port 2201

        Host myserver
            User second_user
            Port 2202
        """)

      result = EvoGit.SSHConfig.lookup("myserver", blocks)
      assert result[:user] == "first_user"
      assert result[:port] == 2201
    end

    test "Host * is applied last as fallback" do
      blocks =
        parse_config("""
        Host myserver
            User explicit_user

        Host *
            User fallback_user
            Port 2222
            IdentityFile ~/.ssh/id_fallback
        """)

      # matching host gets its own values plus wildcard fallbacks for missing keys
      result = EvoGit.SSHConfig.lookup("myserver", blocks)
      assert result[:user] == "explicit_user"
      assert result[:port] == 2222
      assert result[:identity_file] =~ "id_fallback"
    end

    test "wildcard applies to unmatched hosts" do
      blocks =
        parse_config("""
        Host myserver
            User explicit_user

        Host *
            User fallback_user
            Port 2222
        """)

      result = EvoGit.SSHConfig.lookup("otherserver", blocks)
      assert result[:user] == "fallback_user"
      assert result[:port] == 2222
    end

    test "lookup with HostName directive" do
      blocks =
        parse_config("""
        Host myserver
            HostName actual.example.com
            User myuser
        """)

      result = EvoGit.SSHConfig.lookup("myserver", blocks)
      assert result[:hostname] == "actual.example.com"
      assert result[:user] == "myuser"
    end

    test "lookup with ProxyJump and ProxyCommand" do
      blocks =
        parse_config("""
        Host behind-gateway
            ProxyJump jump.example.com
            ProxyCommand ssh -W %h:%p gateway
        """)

      result = EvoGit.SSHConfig.lookup("behind-gateway", blocks)
      assert result[:proxy_jump] == "jump.example.com"
      assert result[:proxy_command] == "ssh -W %h:%p gateway"
    end

    test "Host with multiple patterns matches any of them" do
      blocks =
        parse_config("""
        Host server1 server2 server3
            User shareduser
        """)

      assert EvoGit.SSHConfig.lookup("server1", blocks)[:user] == "shareduser"
      assert EvoGit.SSHConfig.lookup("server2", blocks)[:user] == "shareduser"
      assert EvoGit.SSHConfig.lookup("server3", blocks)[:user] == "shareduser"
      assert EvoGit.SSHConfig.lookup("other", blocks) == %{}
    end
  end

  describe "lookup/1 (integration with default path)" do
    test "returns empty map when ~/.ssh/config does not exist" do
      # In CI / test environments there's typically no ~/.ssh/config.
      # If there IS one, the test still passes — it just won't return %{}.
      result = EvoGit.SSHConfig.lookup("some-host-that-wont-match-any-block-xyz")
      # Best we can assert: it returns a map and doesn't crash.
      assert is_map(result)
    end
  end

  # ── Private test helpers ───────────────────────────────────────────────

  defp parse_config(contents) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit-ssh-lkup-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    config_path = Path.join(tmp_dir, "config")
    File.write!(config_path, contents)

    blocks = EvoGit.SSHConfig.parse(config_path)
    File.rm_rf!(tmp_dir)
    blocks
  end
end
