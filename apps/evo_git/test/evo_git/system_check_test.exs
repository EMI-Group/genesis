defmodule EvoGit.SystemCheckTest do
  use ExUnit.Case, async: false

  alias EvoGit.{Nix, SystemCheck}

  # Expected tool_result keys
  @tool_keys [:available, :path, :version, :error]

  # Expected nix_check keys
  @nix_keys [:available, :enabled, :flake_present, :dev_env_built, :error]

  setup do
    Nix.reset_state()
    on_exit(fn -> Nix.reset_state() end)
    :ok
  end

  describe "tool_check/0" do
    test "returns a map with :git and :rg keys" do
      result = SystemCheck.tool_check()

      assert is_map(result)
      assert Map.has_key?(result, :git)
      assert Map.has_key?(result, :rg)
    end

    test "git result has expected keys with correct types" do
      git = SystemCheck.tool_check()[:git]

      assert is_map(git)

      for key <- @tool_keys do
        assert Map.has_key?(git, key), "git result missing key: #{inspect(key)}"
      end

      assert is_boolean(git.available)
      # path is nil or a string
      assert git.path == nil or is_binary(git.path)
      # version is nil or a string
      assert git.version == nil or is_binary(git.version)
      # error is nil or a string
      assert git.error == nil or is_binary(git.error)
    end

    test "rg result has expected keys with correct types" do
      rg = SystemCheck.tool_check()[:rg]

      assert is_map(rg)

      for key <- @tool_keys do
        assert Map.has_key?(rg, key), "rg result missing key: #{inspect(key)}"
      end

      assert is_boolean(rg.available)
      assert rg.path == nil or is_binary(rg.path)
      assert rg.version == nil or is_binary(rg.version)
      assert rg.error == nil or is_binary(rg.error)
    end

    test "detects git since it is a required tool" do
      git = SystemCheck.tool_check()[:git]

      assert git.available == true, "git should be available in the test environment"
      assert is_binary(git.path), "git path should be a string when available"
      assert git.error == nil, "git error should be nil when available"
    end

    test "detects rg since it is a required tool" do
      rg = SystemCheck.tool_check()[:rg]

      assert rg.available == true, "rg should be available in the test environment"
      assert is_binary(rg.path), "rg path should be a string when available"
      assert rg.error == nil, "rg error should be nil when available"
    end

    test "git version is a non-empty string when available" do
      git = SystemCheck.tool_check()[:git]

      assert git.available == true
      assert is_binary(git.version)
      assert git.version != "", "git version should be a non-empty string when available"
    end

    test "rg version is a non-empty string when available" do
      rg = SystemCheck.tool_check()[:rg]

      assert rg.available == true
      assert is_binary(rg.version)
      assert rg.version != "", "rg version should be a non-empty string when available"
    end
  end

  describe "config_check/0" do
    test "returns a map with expected keys" do
      result = SystemCheck.config_check()

      assert is_map(result)
      assert Map.has_key?(result, :missing)
      assert Map.has_key?(result, :warnings)
      assert Map.has_key?(result, :ok?)
      assert Map.has_key?(result, :validation_errors)
    end

    test ":ok? is a boolean" do
      result = SystemCheck.config_check()
      assert is_boolean(result.ok?)
    end

    test ":missing is a list" do
      result = SystemCheck.config_check()
      assert is_list(result.missing)
    end

    test ":warnings is a list" do
      result = SystemCheck.config_check()
      assert is_list(result.warnings)
    end

    test ":validation_errors is a list" do
      result = SystemCheck.config_check()
      assert is_list(result.validation_errors)
    end

    test "does not raise even if config is incomplete" do
      # config_check/0 is wrapped in a rescue clause and must always return a map
      result = SystemCheck.config_check()
      assert is_map(result)
      assert Map.has_key?(result, :ok?)
    end
  end

  describe "sandbox_check/0" do
    test "returns a map with expected keys" do
      result = SystemCheck.sandbox_check()

      assert is_map(result)
      assert Map.has_key?(result, :backend)
      assert Map.has_key?(result, :enabled)
      assert Map.has_key?(result, :capabilities)
      assert Map.has_key?(result, :systemd_available)
      assert Map.has_key?(result, :sandbox_exec_available)
    end

    test ":backend is an atom" do
      result = SystemCheck.sandbox_check()
      assert is_atom(result.backend)
    end

    test ":backend is one of the known sandbox backends" do
      result = SystemCheck.sandbox_check()
      assert result.backend in [:systemd_run, :sandbox_exec, :none]
    end

    test ":enabled is a boolean" do
      result = SystemCheck.sandbox_check()
      assert is_boolean(result.enabled)
    end

    test ":capabilities is a map" do
      result = SystemCheck.sandbox_check()
      assert is_map(result.capabilities)
    end

    test ":systemd_available is a boolean" do
      result = SystemCheck.sandbox_check()
      assert is_boolean(result.systemd_available)
    end

    test ":sandbox_exec_available is a boolean" do
      result = SystemCheck.sandbox_check()
      assert is_boolean(result.sandbox_exec_available)
    end

    test "does not raise" do
      # sandbox_check/0 is wrapped in a rescue clause and must always return a map
      result = SystemCheck.sandbox_check()
      assert is_map(result)
    end
  end

  describe "supervisor_check/0" do
    test "returns a map with expected keys" do
      result = SystemCheck.supervisor_check()

      assert is_map(result)
      assert Map.has_key?(result, :evo_git)
      assert Map.has_key?(result, :evo_dash)
      assert Map.has_key?(result, :healthy)
    end

    test ":evo_git is a list" do
      result = SystemCheck.supervisor_check()
      assert is_list(result.evo_git)
    end

    test ":evo_dash is a list" do
      result = SystemCheck.supervisor_check()
      assert is_list(result.evo_dash)
    end

    test ":healthy is a boolean" do
      result = SystemCheck.supervisor_check()
      assert is_boolean(result.healthy)
    end

    test "does not raise even if supervisors are not running" do
      # supervisor_check/0 is wrapped in a rescue clause and must always return a map
      result = SystemCheck.supervisor_check()
      assert is_map(result)
      assert Map.has_key?(result, :healthy)
    end

    test "each element in :evo_git list has :id, :status, :pid keys" do
      children = SystemCheck.supervisor_check().evo_git

      for child <- children do
        assert is_map(child), "each child must be a map"
        assert Map.has_key?(child, :id), "child missing :id key"
        assert Map.has_key?(child, :status), "child missing :status key"
        assert Map.has_key?(child, :pid), "child missing :pid key"
      end
    end

    test "each element in :evo_dash list has :id, :status, :pid keys" do
      children = SystemCheck.supervisor_check().evo_dash

      for child <- children do
        assert is_map(child), "each child must be a map"
        assert Map.has_key?(child, :id), "child missing :id key"
        assert Map.has_key?(child, :status), "child missing :status key"
        assert Map.has_key?(child, :pid), "child missing :pid key"
      end
    end

    test "non-empty :evo_git list contains valid status atoms" do
      children = SystemCheck.supervisor_check().evo_git

      if children != [] do
        for child <- children do
          assert child.status in [:running, :restarting, :undefined, :error],
                 "unexpected status: #{inspect(child.status)}"
        end
      end
    end

    test "non-empty :evo_dash list contains valid status atoms" do
      children = SystemCheck.supervisor_check().evo_dash

      if children != [] do
        for child <- children do
          assert child.status in [:running, :restarting, :undefined, :error],
                 "unexpected status: #{inspect(child.status)}"
        end
      end
    end
  end

  describe "nix_check/0" do
    test "returns a map with expected keys" do
      result = SystemCheck.nix_check()

      assert is_map(result)

      for key <- @nix_keys do
        assert Map.has_key?(result, key), "nix result missing key: #{inspect(key)}"
      end
    end

    test ":available is a boolean" do
      result = SystemCheck.nix_check()
      assert is_boolean(result.available)
    end

    test ":enabled is a boolean" do
      result = SystemCheck.nix_check()
      assert is_boolean(result.enabled)
    end

    test ":flake_present is a boolean" do
      result = SystemCheck.nix_check()
      assert is_boolean(result.flake_present)
    end

    test ":dev_env_built is a boolean" do
      result = SystemCheck.nix_check()
      assert is_boolean(result.dev_env_built)
    end

    test ":error is nil or a string" do
      result = SystemCheck.nix_check()
      assert result.error == nil or is_binary(result.error)
    end

    test "does not raise" do
      # nix_check/0 is wrapped in a rescue clause and must always return a map
      result = SystemCheck.nix_check()
      assert is_map(result)
    end

    test "when nix is not enabled, returns all-false map with nil error" do
      result = SystemCheck.nix_check()

      if result.enabled == false do
        assert result.dev_env_built == false
        assert result.error == nil
      end
    end
  end

  describe "run_all_checks/0" do
    test "returns a map with expected keys" do
      result = SystemCheck.run_all_checks()

      assert is_map(result)
      assert Map.has_key?(result, :config)
      assert Map.has_key?(result, :tools)
      assert Map.has_key?(result, :sandbox)
      assert Map.has_key?(result, :supervisor)
      assert Map.has_key?(result, :nix)
    end

    test "does not raise" do
      # run_all_checks/0 is wrapped in a rescue clause and must always return a map
      result = SystemCheck.run_all_checks()
      assert is_map(result)
    end

    test ":config value matches config_check/0 structure" do
      config = SystemCheck.run_all_checks()[:config]

      assert is_map(config)
      assert Map.has_key?(config, :ok?)
      assert Map.has_key?(config, :missing)
      assert Map.has_key?(config, :warnings)
      assert Map.has_key?(config, :validation_errors)
    end

    test ":tools value matches tool_check/0 structure" do
      tools = SystemCheck.run_all_checks()[:tools]

      assert is_map(tools)
      assert Map.has_key?(tools, :git)
      assert Map.has_key?(tools, :rg)

      for key <- @tool_keys do
        assert Map.has_key?(tools.git, key), "git result missing key: #{inspect(key)}"
        assert Map.has_key?(tools.rg, key), "rg result missing key: #{inspect(key)}"
      end
    end

    test ":sandbox value matches sandbox_check/0 structure" do
      sandbox = SystemCheck.run_all_checks()[:sandbox]

      assert is_map(sandbox)
      assert Map.has_key?(sandbox, :backend)
      assert Map.has_key?(sandbox, :enabled)
      assert Map.has_key?(sandbox, :capabilities)
      assert Map.has_key?(sandbox, :systemd_available)
      assert Map.has_key?(sandbox, :sandbox_exec_available)
    end

    test ":supervisor value matches supervisor_check/0 structure" do
      supervisor = SystemCheck.run_all_checks()[:supervisor]

      assert is_map(supervisor)
      assert Map.has_key?(supervisor, :evo_git)
      assert Map.has_key?(supervisor, :evo_dash)
      assert Map.has_key?(supervisor, :healthy)
    end

    test ":nix value matches nix_check/0 structure" do
      nix = SystemCheck.run_all_checks()[:nix]

      assert is_map(nix)

      for key <- @nix_keys do
        assert Map.has_key?(nix, key), "nix result missing key: #{inspect(key)}"
      end
    end
  end
end
