defmodule EvoGit.CLI.AgentFlagTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Tests mutate the XDG_CONFIG_HOME env var so that --agent validation never
  # touches the real ~/.config/genesis/ directory (agents.toml lives there).
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

  describe "validate_custom_agent/1" do
    test "nil agent id is always valid" do
      assert EvoGit.CLI.do_validate_custom_agent(nil) == :ok
    end

    test "unknown agent id returns an error mentioning the id and agents.toml" do
      assert {:error, msg} = EvoGit.CLI.do_validate_custom_agent("does-not-exist")
      assert msg =~ "Unknown custom agent id 'does-not-exist'"
      assert msg =~ "agents.toml"
    end
  end

  describe "genesis dispatch with --agent" do
    test "unknown agent id prints an error and does not run genesis" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "evogit-test-genesis-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      output =
        capture_io(fn ->
          EvoGit.CLI.main([
            "genesis",
            "make a thing",
            "--agent",
            "bogus-agent",
            "--path",
            tmp_dir
          ])
        end)

      assert output =~ "Error: Unknown custom agent id 'bogus-agent'"
      assert output =~ "agents.toml"
      # Genesis must never have started: the target dir stays untouched.
      assert File.ls!(tmp_dir) == []
    end
  end

  describe "evolve dispatch with --agent" do
    test "unknown agent id prints an error and does not run evolution" do
      output =
        capture_io(fn ->
          EvoGit.CLI.main(["evolve", "fix x", "--agent", "bogus-agent"])
        end)

      assert output =~ "Error: Unknown custom agent id 'bogus-agent'"
      assert output =~ "agents.toml"
    end
  end

  describe "evolve dispatch with --mode custom" do
    test "unknown agent id prints an error and does not run evolution" do
      output =
        capture_io(fn ->
          EvoGit.CLI.main(["evolve", "fix x", "--mode", "custom", "--agent", "ghost_agent"])
        end)

      assert output =~ "Error: Unknown custom agent id 'ghost_agent'"
      assert output =~ "agents.toml"
    end

    test "valid agent id is accepted and fails quietly on a nonexistent repo" do
      {:ok, saved} =
        EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "You review code."})

      repo_path =
        Path.join(System.tmp_dir!(), "evogit-cli-custom-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(repo_path) end)

      # Force no model profiles so AgentScheduler.run_agent replies
      # {:error, :llm_not_configured} instead of dispatching a real LLM agent.
      scheduler = Process.whereis(EvoGit.AgentScheduler)

      if scheduler do
        original_profiles = GenServer.call(scheduler, {:get_config, :model_profiles})
        :ok = EvoGit.AgentScheduler.update_config(model_profiles: [])

        on_exit(fn ->
          EvoGit.AgentScheduler.update_config(model_profiles: original_profiles)
        end)
      end

      output =
        capture_io(fn ->
          EvoGit.CLI.main([
            "evolve",
            "fix x",
            "--mode",
            "custom",
            "--agent",
            saved.id,
            "--path",
            repo_path
          ])
        end)

      # The command was accepted (agent validation passed): no error output, no
      # crash. Evolution.run created the repo via ensure_repo and then stopped
      # quietly at run_agent with llm_not_configured.
      refute output =~ "Error:"
      assert File.dir?(Path.join(repo_path, ".git"))
    end
  end
end
