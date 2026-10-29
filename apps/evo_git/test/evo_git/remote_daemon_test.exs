defmodule EvoGit.RemoteDaemonTest do
  # Pure string builders — no I/O, no ports, no app env.
  use ExUnit.Case, async: true

  alias EvoGit.RemoteDaemon

  @unit "genesis-remote-abc123"
  @node "genesis_remote_abc123@127.0.0.1"
  @cookie "SECRETCOOKIE"
  @launcher "/home/bill/.genesis/remote/genesis_remote/bin/genesis_remote"

  describe "login_user_probe_command/0" do
    test "prints the login user and never fails the probe" do
      assert RemoteDaemon.login_user_probe_command() == "id -un 2>/dev/null || true"
    end
  end

  describe "scope_for/1" do
    test "root by name (with surrounding whitespace) is SYSTEM scope" do
      assert RemoteDaemon.scope_for("root") == :system
      assert RemoteDaemon.scope_for(" root ") == :system
      assert RemoteDaemon.scope_for("root\n") == :system
    end

    test "the numeric id 0 is SYSTEM scope" do
      assert RemoteDaemon.scope_for("0") == :system
      assert RemoteDaemon.scope_for(" 0 ") == :system
    end

    test "every other user keeps USER scope" do
      assert RemoteDaemon.scope_for("bill") == :user
      assert RemoteDaemon.scope_for("ubuntu") == :user
      assert RemoteDaemon.scope_for("rooted") == :user
      assert RemoteDaemon.scope_for("00") == :user
    end

    test "an unknown login user (nil / blank) defaults to USER scope" do
      assert RemoteDaemon.scope_for(nil) == :user
      assert RemoteDaemon.scope_for("") == :user
      assert RemoteDaemon.scope_for("   ") == :user
    end
  end

  describe "user scope commands (byte-identical to the historical form)" do
    test "is_active_command/2" do
      assert RemoteDaemon.is_active_command(:user, @unit) ==
               "systemctl --user is-active #{@unit} 2>/dev/null"
    end

    test "show_environment_command/2" do
      assert RemoteDaemon.show_environment_command(:user, @unit) ==
               "systemctl --user show #{@unit} -p Environment --value"
    end

    test "reset_failed_command/2 always exits 0" do
      assert RemoteDaemon.reset_failed_command(:user, @unit) ==
               "systemctl --user reset-failed #{@unit} 2>/dev/null; true"
    end

    test "stop_command/2" do
      assert RemoteDaemon.stop_command(:user, @unit) == "systemctl --user stop #{@unit}"
    end

    test "status_command/2 merges stderr and tails" do
      assert RemoteDaemon.status_command(:user, @unit) ==
               "systemctl --user status #{@unit} 2>&1 | tail -20"
    end

    test "start_command/5 runs in the user manager" do
      assert RemoteDaemon.start_command(:user, @unit, @node, @cookie, @launcher) ==
               "systemd-run --user --unit=#{@unit} " <>
                 "--setenv=RELEASE_NODE=#{@node} --setenv=RELEASE_COOKIE=#{@cookie} " <>
                 "#{@launcher} start"
    end

    test "hints" do
      assert RemoteDaemon.show_environment_hint(:user, @unit) ==
               "systemctl --user show #{@unit} -p Environment"

      assert RemoteDaemon.stop_hint(:user, @unit) == "systemctl --user stop #{@unit}"
    end
  end

  describe "system scope commands (root logins)" do
    test "is_active_command/2 is a plain systemctl call" do
      assert RemoteDaemon.is_active_command(:system, @unit) ==
               "systemctl is-active #{@unit} 2>/dev/null"
    end

    test "show_environment_command/2 is a plain systemctl call" do
      assert RemoteDaemon.show_environment_command(:system, @unit) ==
               "systemctl show #{@unit} -p Environment --value"
    end

    test "reset_failed_command/2 is a plain systemctl call" do
      assert RemoteDaemon.reset_failed_command(:system, @unit) ==
               "systemctl reset-failed #{@unit} 2>/dev/null; true"
    end

    test "stop_command/2 is a plain systemctl call" do
      assert RemoteDaemon.stop_command(:system, @unit) == "systemctl stop #{@unit}"
    end

    test "status_command/2 is a plain systemctl call" do
      assert RemoteDaemon.status_command(:system, @unit) ==
               "systemctl status #{@unit} 2>&1 | tail -20"
    end

    test "start_command/5 uses --system --collect and no --user" do
      command = RemoteDaemon.start_command(:system, @unit, @node, @cookie, @launcher)

      assert command ==
               "systemd-run --system --collect --unit=#{@unit} " <>
                 "--setenv=RELEASE_NODE=#{@node} --setenv=RELEASE_COOKIE=#{@cookie} " <>
                 "#{@launcher} start"

      refute command =~ "--user"
    end

    test "hints are plain systemctl calls" do
      assert RemoteDaemon.show_environment_hint(:system, @unit) ==
               "systemctl show #{@unit} -p Environment"

      assert RemoteDaemon.stop_hint(:system, @unit) == "systemctl stop #{@unit}"
    end
  end

  describe "scope invariants" do
    setup do
      unit = @unit
      node = @node
      cookie = @cookie
      launcher = @launcher

      per_scope = %{
        user: [
          RemoteDaemon.is_active_command(:user, unit),
          RemoteDaemon.show_environment_command(:user, unit),
          RemoteDaemon.reset_failed_command(:user, unit),
          RemoteDaemon.stop_command(:user, unit),
          RemoteDaemon.status_command(:user, unit),
          RemoteDaemon.start_command(:user, unit, node, cookie, launcher),
          RemoteDaemon.show_environment_hint(:user, unit),
          RemoteDaemon.stop_hint(:user, unit)
        ],
        system: [
          RemoteDaemon.is_active_command(:system, unit),
          RemoteDaemon.show_environment_command(:system, unit),
          RemoteDaemon.reset_failed_command(:system, unit),
          RemoteDaemon.stop_command(:system, unit),
          RemoteDaemon.status_command(:system, unit),
          RemoteDaemon.start_command(:system, unit, node, cookie, launcher),
          RemoteDaemon.show_environment_hint(:system, unit),
          RemoteDaemon.stop_hint(:system, unit)
        ]
      }

      {:ok, per_scope: per_scope, unit: unit}
    end

    test "every :system command omits --user and every :user command carries it", %{
      per_scope: per_scope
    } do
      for command <- per_scope.system, do: refute(command =~ "--user", command)
      for command <- per_scope.user, do: assert(command =~ "--user", command)
    end

    test "both scopes target the SAME per-target unit name", %{per_scope: per_scope, unit: unit} do
      for command <- per_scope.user ++ per_scope.system do
        assert command =~ unit, "expected the per-target unit name in: #{command}"
      end
    end
  end
end
