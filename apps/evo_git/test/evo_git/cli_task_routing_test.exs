defmodule EvoGit.CLI.TaskRoutingTest do
  @moduledoc """
  End-to-end tests for the CLI → task data-plane routing (objective F).

  These tests drive `EvoGit.CLI.main/1` through `capture_io` against the real
  scheduler plus an isolated TaskRegistry/Store (`EvoGit.TaskRegistryCase`)
  and assert the task rows the CLI enqueues. They are written against the NEW
  CLI contract (post-refactor): genesis/evolve/reflect no longer run inline —
  they enqueue through `TaskRegistry.start_task/2` and `main/1` blocks until
  the task reaches a terminal status.

  Against the PRE-refactor cli.ex these tests fail BEHAVIORALLY (the old CLI
  runs inline, never prints "Task <id> started ...", and returns `:ok`) —
  that is expected; they pass once the parallel CLI refactor merges.

  Enqueued tasks are forced to fail fast with the established no-LLM idiom:
  emptying the scheduler's model profiles makes `run_agent/1` reply
  `{:error, :llm_not_configured}` immediately (see `without_model_profiles/1`).
  """

  use EvoGit.TaskRegistryCase, async: false

  @moduletag :tmp_dir

  import ExUnit.CaptureIO

  # Observable-contract regexes from the CLI + task data-plane refactor.
  @started_re ~r/^Task ([0-9a-f]{16}) started \(type: (genesis|evolve|reflect)\)$/m
  @failed_re ~r/^Task [0-9a-f]{16} failed\./

  # Isolate XDG_CONFIG_HOME so the -m tests can write a config.toml without
  # touching the real user config, and so -m resolution is deterministic (no
  # models configured unless a test saves one).
  setup %{tmp_dir: tmp_dir} do
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    xdg = Path.join(tmp_dir, "xdg")
    File.mkdir_p!(xdg)
    System.put_env("XDG_CONFIG_HOME", xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end
    end)

    :ok
  end

  describe "genesis routing" do
    test "--mode new enqueues with mode \"new\", prompt and build_system", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "gen_new")
      # EMPTY dir — avoids the interactive non-empty-dir confirm; the
      # build-system prompt is TTY-gated and skipped under capture_io,
      # resolving to :none.
      File.mkdir_p!(dir)

      {output, result} =
        without_model_profiles(fn ->
          run_cli(["genesis", "create a thing", "--mode", "new", "--path", dir])
        end)

      id = started_task_id!(output)
      assert {:error, msg} = result
      assert msg =~ @failed_re

      task = TaskRegistry.get_task(id)
      assert task != nil
      assert task.type == :genesis
      assert task.status == :failed
      assert task_opt(task.opts, :mode) == "new"
      assert task_opt(task.opts, :prompt) == "create a thing"
      assert Path.expand(task_opt(task.opts, :path)) == Path.expand(dir)
      # genesis 'new' resolves a build system. The Store codec keeps keys
      # outside its atomization whitelist as STRINGS, so the :none atom
      # round-trips as the string "none".
      assert task_opt(task.opts, :build_system) in ["none", :none]
      # genesis tasks carry the prompt under :prompt, never :objective.
      assert task_opt(task.opts, :objective) == nil
    end

    test "--mode existing enqueues with mode \"existing\" and prompt", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "gen_existing")
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)

      {output, result} =
        without_model_profiles(fn ->
          run_cli(["genesis", "analyze me", "--mode", "existing", "--path", dir])
        end)

      id = started_task_id!(output)
      assert {:error, msg} = result
      assert msg =~ @failed_re

      task = TaskRegistry.get_task(id)
      assert task != nil
      assert task.type == :genesis
      assert task.status == :failed
      assert task_opt(task.opts, :mode) == "existing"
      assert task_opt(task.opts, :prompt) == "analyze me"
      assert Path.expand(task_opt(task.opts, :path)) == Path.expand(dir)
      assert task_opt(task.opts, :objective) == nil
    end
  end

  describe "evolve routing" do
    test "--mode simple enqueues with mode \"simple\" and objective", %{tmp_dir: tmp_dir} do
      # A nonexistent path is fine: the wrapper's Evolution.run ensures the
      # repo (mkdir + git init) before the agent runs — verified empirically
      # against the data plane.
      repo = Path.join(tmp_dir, "evolve_simple")

      {output, result} =
        without_model_profiles(fn ->
          run_cli(["evolve", "fix the bug", "--mode", "simple", "--path", repo])
        end)

      id = started_task_id!(output)
      assert {:error, msg} = result
      assert msg =~ @failed_re

      task = TaskRegistry.get_task(id)
      assert task != nil
      assert task.type == :evolve
      assert task.status == :failed
      assert task_opt(task.opts, :mode) == "simple"
      assert task_opt(task.opts, :objective) == "fix the bug"
      assert Path.expand(task_opt(task.opts, :path)) == Path.expand(repo)
      # evolve tasks carry the objective under :objective, never :prompt.
      assert task_opt(task.opts, :prompt) == nil
    end
  end

  describe "reflect routing" do
    test "reflect enqueues a repo-less task with no :path" do
      {output, result} =
        without_model_profiles(fn ->
          run_cli(["reflect", "explain the system"])
        end)

      id = started_task_id!(output)
      assert {:error, msg} = result
      assert msg =~ @failed_re

      task = TaskRegistry.get_task(id)
      assert task != nil
      assert task.type == :reflect
      assert task.status == :failed
      assert task_opt(task.opts, :objective) == "explain the system"
      # repo-less: reflect task opts deliberately carry no :path.
      assert task_opt(task.opts, :path) == nil
    end
  end

  describe "model flag (-m) routing" do
    test "an unknown profile prints an Error and does not enqueue", %{tmp_dir: tmp_dir} do
      # XDG is isolated per test and no config.toml exists here, so no models
      # are configured — resolution must fail pre-enqueue. (Wrapped in
      # without_model_profiles only so a pre-merge inline run would also fail
      # fast; after the merge the failure happens before any enqueue.)
      #
      # A --path under tmp_dir is passed even though post-merge it is ignored
      # (the -m error short-circuits before any enqueue): against the
      # PRE-refactor cli.ex this test's args would otherwise dispatch an
      # inline evolve from the test process cwd (apps/evo_git), polluting the
      # worktree with a nested .git. The tmp --path keeps that inline run
      # safely inside the per-test tmp dir.
      {output, result} =
        without_model_profiles(fn ->
          run_cli([
            "evolve",
            "fix x",
            "-m",
            "no-such-profile",
            "--path",
            Path.join(tmp_dir, "m_unknown")
          ])
        end)

      assert output =~ "Error:"
      refute output =~ @started_re
      assert result == :ok
    end

    test "-m <profile id> lands model_id + model_id_locked in the enqueued opts",
         %{tmp_dir: tmp_dir} do
      # The -m resolution seam was verified empirically: save_user_config/1
      # under an isolated XDG is reflected immediately by
      # Config.resolve([:llm, :models]) (the file cache is invalidated on
      # save), so a clean happy-path e2e is possible.
      :ok =
        EvoGit.Config.save_user_config(%{
          llm: %{models: [%{id: "myprofile", model: "anthropic:test-model"}]}
        })

      assert [%{id: "myprofile"} | _] = EvoGit.Config.resolve([:llm, :models])

      repo = Path.join(tmp_dir, "evolve_m")

      {output, result} =
        without_model_profiles(fn ->
          run_cli(["evolve", "fix x", "-m", "myprofile", "--mode", "simple", "--path", repo])
        end)

      id = started_task_id!(output)
      assert {:error, msg} = result
      assert msg =~ @failed_re

      task = TaskRegistry.get_task(id)
      assert task != nil
      assert task.type == :evolve
      assert task_opt(task.opts, :mode) == "simple"
      # The resolved profile id is locked into the task opts ("model_id" and
      # "model_id_locked" are outside the codec whitelist → string keys).
      assert task_opt(task.opts, :model_id) == "myprofile"
      assert task_opt(task.opts, :model_id_locked) == true
    end
  end

  describe "removed scheduler flags" do
    test "each prints a 'was removed' notice and the command still enqueues", %{
      tmp_dir: tmp_dir
    } do
      removed = [
        {"-c", "4"},
        {"--concurrency", "4"},
        {"-r", "2"},
        {"-t", "3"},
        {"--tool-concurrency", "2"}
      ]

      for {flag, value} <- removed do
        # A fresh EMPTY dir per flag so repeated runs never trip the
        # non-empty-dir confirm.
        dir = Path.join(tmp_dir, "gen_flags_" <> String.trim_leading(flag, "-"))
        File.mkdir_p!(dir)

        {output, result} =
          without_model_profiles(fn ->
            run_cli(["genesis", "make a thing", "--mode", "new", "--path", dir, flag, value])
          end)

        assert output =~ "was removed", "expected a 'was removed' notice for #{flag}"
        id = started_task_id!(output)
        assert {:error, msg} = result
        assert msg =~ @failed_re

        task = TaskRegistry.get_task(id)
        assert task != nil
        assert task.type == :genesis
        assert task.status == :failed
      end
    end
  end

  describe "run subcommand" do
    test "run help lists the command catalog" do
      {output, result} = run_cli(["run", "help"])

      assert output =~ "Available commands:"
      assert output =~ "StartTask.start_task"
      assert result == :ok
    end

    test "run executes a level-3 handler directly, bypassing the chat approval gate" do
      {output, result} = run_cli(["run", ~s(CancelTask.cancel_task ghost)])

      # Verified handler output (CommandShell.execute/2 with approval: :auto)
      # — NOT an approval-denied message, proving the gate is bypassed.
      assert output =~ "Error cancelling task ghost: task not found"
      assert result == :ok
    end

    test "run with no command string prints a helpful error and returns :ok" do
      {output, result} = run_cli(["run"])

      assert output =~ "Error: run requires a command string"
      assert result == :ok
    end

    test "run with an invalid shell command prints Error and returns {:error, _}" do
      {output, result} = run_cli(["run", "bogus.cmd"])

      assert output =~ "Error: Unknown command 'bogus.cmd'"
      assert match?({:error, _}, result)
    end
  end

  describe "help text" do
    test "--help no longer lists removed scheduler flags and documents run" do
      {output, result} = run_cli(["--help"])
      assert result == :ok

      # The removed scheduler flags are gone from the Options listing — refute
      # their old option-line shapes (with the <n> placeholder), NOT the bare
      # flag names: the flags ARE still named in the removal note below.
      refute output =~ "-c, --concurrency <n>"
      refute output =~ "--tool-concurrency <n>"
      refute output =~ "-r, --retries <n>"
      refute output =~ "-t, --max-turns <n>"

      # The removal note itself is present and points users at config.toml.
      assert output =~ "were removed"
      assert output =~ "config.toml"
      assert output =~ "[scheduler]"

      # run is a command entry (its own line in the Commands section).
      assert output =~ ~r/^\s*run\b/m

      # reflect stays listed; -m remains documented as a task-level profile
      # selection.
      assert output =~ "reflect"
      assert output =~ "-m, --model"
      assert output =~ "profile"
    end
  end

  # --- helpers -------------------------------------------------------------

  # Runs EvoGit.CLI.main/1 under capture_io and returns {output, result}.
  defp run_cli(args) do
    output =
      capture_io(fn ->
        send(self(), {:cli_result, EvoGit.CLI.main(args)})
      end)

    result =
      receive do
        {:cli_result, r} -> r
      after
        30_000 -> flunk("EvoGit.CLI.main/1 did not return within 30s")
      end

    {output, result}
  end

  # The scheduler is running in tests (started with the :evo_git app). With
  # model profiles configured it would dispatch a real LLM-backed agent; force
  # an empty profile list so run_agent replies {:error, :llm_not_configured}
  # immediately. The original profiles are restored afterwards. main/1 blocks
  # until the enqueued task is terminal, so the restore happens only after the
  # wrapper has finished.
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

  # Extracts the task id from the contract "Task <id> started (type: ...)"
  # line, raising a descriptive error when the line is absent.
  defp started_task_id!(output) do
    case Regex.run(@started_re, output) do
      [_, id, _type] ->
        id

      _ ->
        flunk("""
        expected a "Task <id> started (type: ...)" line matching the contract, got:

        #{output}
        """)
    end
  end

  # Reads an opt value from a decoded task-opts keyword list. Keys outside the
  # Store codec's atomization whitelist (e.g. "agent", "build_system",
  # "model_id", "model_id_locked") survive as STRING keys, so look up both
  # spellings.
  defp task_opt(opts, key) when is_atom(key) do
    case Keyword.fetch(opts || [], key) do
      {:ok, value} -> value
      :error -> task_opt_string(opts, Atom.to_string(key))
    end
  end

  defp task_opt_string(nil, _key), do: nil

  defp task_opt_string(opts, key) do
    Enum.find_value(opts, fn
      {k, value} when k == key -> value
      _ -> nil
    end)
  end
end
