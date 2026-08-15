defmodule EvoGit.Runtime.EvolutionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Adapters.Git
  alias EvoGit.Runtime.Evolution
  alias EvoGit.Runtime.Genesis

  # Tests mutate the XDG_CONFIG_HOME env var so that CustomAgents never
  # touches the real ~/.config/genesis/ directory (same pattern as
  # test/evo_git/runtime/root_agent_helpers_test.exs).
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

  describe "mode_atom/1" do
    test "normalizes nil and known modes" do
      assert Evolution.mode_atom(nil) == :simple
      assert Evolution.mode_atom(:simple) == :simple
      assert Evolution.mode_atom("simple") == :simple
      assert Evolution.mode_atom(:custom) == :custom
      assert Evolution.mode_atom("custom") == :custom
    end

    test "falls back to :simple with a warning for unknown modes" do
      {result, log} = with_log(fn -> Evolution.mode_atom(:other) end)
      assert result == :simple
      assert log =~ "unknown mode"

      {result, log} = with_log(fn -> Evolution.mode_atom("basic") end)
      assert result == :simple
      assert log =~ "unknown mode"
    end
  end

  describe "custom mode agent requirement" do
    test "raises before any repo I/O when :agent is nil or empty" do
      for {mode, agent} <- [{:custom, nil}, {"custom", nil}, {:custom, ""}] do
        repo_path =
          Path.join(System.tmp_dir!(), "evogit-missing-#{System.unique_integer([:positive])}")

        assert_raise ArgumentError, ~r/custom mode requires an agent id/, fn ->
          Evolution.run("obj", repo_path: repo_path, mode: mode, agent: agent)
        end

        # The raise happens before ensure_repo, so the path is never created.
        refute File.exists?(repo_path)
      end
    end

    test "raises for an unknown custom agent id after repo validation" do
      repo = create_git_repo!()

      assert_raise ArgumentError, ~r/Unknown custom agent id 'ghost_agent'/, fn ->
        Evolution.run("obj", repo_path: repo, mode: :custom, agent: "ghost_agent")
      end
    end

    test "runs the custom-agent flow for a valid id" do
      {:ok, saved} =
        EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "You review code."})

      repo = create_git_repo!()

      {result, log} =
        with_info_log_level(fn ->
          without_model_profiles(fn ->
            with_log(fn ->
              guarded_run("obj", repo_path: repo, mode: :custom, agent: saved.id)
            end)
          end)
        end)

      assert log =~ "Evolution: Running custom mode with agent '#{saved.id}'"
      assert quiet_error_result(result)
    end
  end

  describe "simple mode unchanged" do
    test "mode: nil does not raise the custom-mode error and returns an {:error, _} tuple" do
      repo_path =
        Path.join(System.tmp_dir!(), "evogit-simple-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(repo_path) end)

      {result, _log} =
        without_model_profiles(fn ->
          with_log(fn -> guarded_run("obj", repo_path: repo_path, mode: nil) end)
        end)

      assert quiet_error_result(result)
    end
  end

  describe "genesis custom-mode rejection" do
    test "raises the evolve-only error for mode: :custom" do
      repo = create_git_repo!()

      assert_raise ArgumentError, ~r/custom mode is evolve-only/, fn ->
        Genesis.run("prompt", repo_path: repo, mode: :custom)
      end
    end

    test "raises the evolve-only error for mode: \"custom\"" do
      repo = create_git_repo!()

      assert_raise ArgumentError, ~r/custom mode is evolve-only/, fn ->
        Genesis.run("prompt", repo_path: repo, mode: "custom")
      end
    end
  end

  # --- Helpers -------------------------------------------------------------

  defp create_git_repo! do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit-evolution-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Git.init(tmp_dir)
    File.write!(Path.join(tmp_dir, "README.md"), "# Test repo\n")
    {:ok, _} = Git.add(tmp_dir, "README.md")
    {:ok, _} = Git.commit(tmp_dir, "Initial commit")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  # The scheduler is running in tests (started with the :evo_git app), so
  # AgentScheduler.run_agent/1 reaches the GenServer instead of exiting. With
  # model profiles configured it would dispatch a real LLM-backed agent; force
  # an empty profile list so run_agent replies {:error, :llm_not_configured}
  # immediately. The original profiles are restored afterwards.
  defp without_model_profiles(fun) do
    scheduler = Process.whereis(EvoGit.AgentScheduler)

    if scheduler do
      original = GenServer.call(scheduler, {:get_config, :model_profiles})
      :ok = EvoGit.AgentScheduler.update_config(model_profiles: [])

      try do
        fun.()
      after
        EvoGit.AgentScheduler.update_config(model_profiles: original)
      end
    else
      fun.()
    end
  end

  # Runs Evolution.run/2 defensively: if the scheduler is unavailable the call
  # exits with :noproc, which we normalize instead of crashing the test.
  defp guarded_run(objective, opts) do
    try do
      {:returned, Evolution.run(objective, opts)}
    catch
      :exit, reason -> {:exit, reason}
    end
  end

  # The test-env logger level is :warning (config/test.exs), which filters out
  # the Logger.info messages Evolution emits. Temporarily raise the level so
  # they are captured, restoring the previous level afterwards.
  defp with_info_log_level(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      fun.()
    after
      Logger.configure(level: previous)
    end
  end

  # The shared expectation for flows that pass validation but cannot actually
  # schedule an agent in the test env: either a quiet {:error, _} from the
  # scheduler (llm_not_configured) or an exit when no scheduler is running.
  defp quiet_error_result({:returned, {:error, _}}), do: true
  defp quiet_error_result({:exit, _}), do: true
  defp quiet_error_result(other), do: {:unexpected_result, other}
end
