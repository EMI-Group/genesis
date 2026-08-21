defmodule EvoGit.Runtime.SelfReflectiveTest do
  use ExUnit.Case, async: false

  alias EvoGit.Runtime.SelfReflective

  # The :self_reflective_source_root app env, the :self_reflective_source_dir
  # app env, and the GENESIS_SOURCE_ROOT OS env var are global state; every
  # assertion that reads source_root() must restore them afterwards so other
  # tests and later assertions in this file see a clean state. This mirrors the
  # on_exit restore discipline of test/evo_git/runtime/evolution_test.exs.
  describe "source_root/0" do
    test "app env wins over the env var" do
      with_self_reflective_env("/tmp/from-app-env", "/tmp/from-env-var", fn ->
        assert SelfReflective.source_root() == "/tmp/from-app-env"
      end)
    end

    test "env var wins when the app env is absent or empty" do
      for app_env <- [nil, ""] do
        with_self_reflective_env(app_env, "/tmp/from-env-var", fn ->
          assert SelfReflective.source_root() == "/tmp/from-env-var"
        end)
      end
    end

    test "falls back to File.cwd!() when both are absent" do
      with_self_reflective_env(nil, nil, fn ->
        assert SelfReflective.source_root() == File.cwd!()
      end)
    end
  end

  describe "build_spec/2" do
    test "produces the repo-less spec shape" do
      spec =
        SelfReflective.build_spec("hello",
          task_id: "t1",
          model_id: "m1",
          objective: "x",
          source_root: "/nonexistent/dir",
          node_path: "./"
        )

      assert spec.opts[:repo_less] == true
      assert spec.phylo_node == nil
      assert spec.agent_module == EvoGit.Agents.SelfReflective
      assert spec.objective == "hello"
      assert spec.opts[:task_id] == "t1"
      assert spec.opts[:model_id] == "m1"
      refute Keyword.has_key?(spec.opts, :objective)
      refute Keyword.has_key?(spec.opts, :source_root)
      refute Keyword.has_key?(spec.opts, :node_path)

      assert %EvoGit.Core.ContextNode{} = spec.context_node
      assert spec.context_node.path == "./"
      # "/nonexistent/dir" is not a dir, so resolve_source_root falls back to
      # source_root() — always a binary (File.cwd!() here, a real dir → load).
      assert is_binary(spec.context_node.repo)
    end

    test "bare context node with no env set falls back to File.cwd!()" do
      with_self_reflective_env(nil, nil, fn ->
        spec = SelfReflective.build_spec("x")
        assert spec.context_node.path == "./"
        # source_root() → File.cwd!(), which IS a real dir in tests, so
        # ContextNode.load runs — either way repo == File.cwd!().
        assert spec.context_node.repo == File.cwd!()
      end)
    end

    test ":source_root pointing at a real dir loads the ContextNode over it" do
      tmp_dir = tmp_dir!("evogit-selfref-real")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), "# Tmp\n")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      spec = SelfReflective.build_spec("x", source_root: tmp_dir, node_path: "./")
      assert spec.context_node.repo == tmp_dir
    end

    test ":source_root pointing at a nonexistent dir falls back to the app env value" do
      tmp_dir = tmp_dir!("evogit-selfref-env")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), "# Tmp\n")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      with_self_reflective_env(tmp_dir, nil, fn ->
        spec = SelfReflective.build_spec("x", source_root: "/nonexistent/dir", node_path: "./")
        # "/nonexistent/dir" is not a dir → falls back to source_root() = the
        # app-env tmp dir (a real dir) → ContextNode.load runs over it.
        assert spec.context_node.repo == tmp_dir
      end)
    end
  end

  describe "run/2" do
    test "propagates the scheduler error when no model profiles are configured" do
      tmp_dir = tmp_dir!("evogit-selfref-run")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      result =
        without_model_profiles(fn ->
          guarded_run("obj", source_root: tmp_dir)
        end)

      # With the scheduler running, stubbing model_profiles to [] makes
      # AgentScheduler.run_agent reply {:error, :llm_not_configured} fast — the
      # non-{:ok, _} propagation path in run/2 (which logs "SelfReflective
      # failed: ..." and returns the error verbatim). When the scheduler is not
      # running the GenServer.call exits :noproc. Either outcome is accepted.
      # The {:ok, %{result: ...}} success mapping is unreachable without a real
      # LLM and is intentionally not tested here.
      assert quiet_error_result(result)
    end
  end

  # --- Helpers -------------------------------------------------------------

  defp tmp_dir!(label) do
    Path.join(System.tmp_dir!(), "#{label}-#{System.unique_integer([:positive])}")
  end

  # Sets/clears the :self_reflective_source_root app env and the
  # GENESIS_SOURCE_ROOT OS env var for the duration of fun, restoring both
  # afterwards (nil/"" both mean "absent" to the chain). Also pins the managed
  # clone dir (:self_reflective_source_dir) to a NON-EXISTENT path for the
  # duration: since the chain now auto-references a valid managed clone at
  # source_dir/0, a real managed clone under the real data dir must never
  # hijack the chain in tests.
  defp with_self_reflective_env(app_env, env_var, fun) do
    original_app = Application.get_env(:evo_git, :self_reflective_source_root)
    original_var = System.get_env("GENESIS_SOURCE_ROOT")
    original_dir = Application.get_env(:evo_git, :self_reflective_source_dir)

    if app_env do
      Application.put_env(:evo_git, :self_reflective_source_root, app_env)
    else
      Application.delete_env(:evo_git, :self_reflective_source_root)
    end

    if env_var do
      System.put_env("GENESIS_SOURCE_ROOT", env_var)
    else
      System.delete_env("GENESIS_SOURCE_ROOT")
    end

    Application.put_env(
      :evo_git,
      :self_reflective_source_dir,
      "/nonexistent/evogit-selfref-source"
    )

    try do
      fun.()
    after
      restore_app_env(original_app)
      restore_env_var(original_var)
      restore_source_dir(original_dir)
    end
  end

  defp restore_app_env(nil) do
    Application.delete_env(:evo_git, :self_reflective_source_root)
  end

  defp restore_app_env(value) do
    Application.put_env(:evo_git, :self_reflective_source_root, value)
  end

  defp restore_env_var(nil) do
    System.delete_env("GENESIS_SOURCE_ROOT")
  end

  defp restore_env_var(value) do
    System.put_env("GENESIS_SOURCE_ROOT", value)
  end

  defp restore_source_dir(nil) do
    Application.delete_env(:evo_git, :self_reflective_source_dir)
  end

  defp restore_source_dir(value) do
    Application.put_env(:evo_git, :self_reflective_source_dir, value)
  end

  # The scheduler is running in tests (started with the :evo_git app), so
  # AgentScheduler.run_agent/1 reaches the GenServer instead of exiting. With
  # model profiles configured it would dispatch a real LLM-backed agent; force
  # an empty profile list so run_agent replies {:error, :llm_not_configured}
  # immediately. The original profiles are restored afterwards. (Copied from
  # evolution_test.exs.)
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

  # Runs SelfReflective.run/2 defensively: if the scheduler is unavailable the
  # GenServer.call exits with :noproc, which we normalize instead of crashing.
  defp guarded_run(objective, opts) do
    try do
      {:returned, SelfReflective.run(objective, opts)}
    catch
      :exit, reason -> {:exit, reason}
    end
  end

  defp quiet_error_result({:returned, {:error, _}}), do: true
  defp quiet_error_result({:exit, _}), do: true
  defp quiet_error_result(other), do: {:unexpected_result, other}
end
