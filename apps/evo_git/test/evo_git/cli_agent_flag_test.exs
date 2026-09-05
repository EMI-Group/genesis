defmodule EvoGit.CLI.AgentFlagTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Observable-contract regexes from the CLI + task data-plane refactor.
  @started_re ~r/^Task ([0-9a-f]{16}) started \(type: (genesis|evolve|reflect)\)$/m
  @failed_re ~r/^Task [0-9a-f]{16} failed\./

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

    test "valid agent id enqueues a task that fails fast without LLM profiles" do
      {:ok, saved} =
        EvoGit.CustomAgents.save(%{name: "Code Reviewer", prompt: "You review code."})

      repo_path =
        Path.join(System.tmp_dir!(), "evogit-cli-custom-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(repo_path) end)

      # New data-plane model: the CLI enqueues through
      # TaskRegistry.start_task/2 and main/1 only returns after the task
      # reaches a terminal status. Force no model profiles so the enqueued
      # task fails fast at run_agent ({:error, :llm_not_configured}) instead
      # of dispatching a real LLM-backed agent.
      {output, result} =
        without_model_profiles(fn ->
          run_cli([
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

      # Pre-enqueue validation passed (the agent id exists): no "Error:"
      # appears before the enqueue line.
      id = started_task_id!(output)
      {idx, _len} = hd(Regex.run(@started_re, output, return: :index))
      prefix = binary_part(output, 0, idx)
      refute prefix =~ "Error:"

      # main/1 returns {:error, "Task <id> failed."} — the task ran to a
      # terminal :failed status before main/1 returned.
      assert {:error, msg} = result
      assert msg =~ @failed_re
      assert msg =~ id

      # The wrapper's Evolution.run ensured the repo before the agent failed
      # (verified empirically against the data plane).
      assert File.dir?(Path.join(repo_path, ".git"))

      # The task row carries the enqueued opts. Keys outside the Store
      # codec's atomization whitelist (e.g. "agent") survive as STRING keys.
      task = EvoGit.TaskRegistry.get_task(id)
      assert task != nil
      assert task.type == :evolve
      assert task_opt(task.opts, :mode) == "custom"
      assert task_opt(task.opts, "agent") == saved.id
      assert task_opt(task.opts, :objective) == "fix x"
      assert Path.expand(task_opt(task.opts, :path)) == Path.expand(repo_path)

      # This file is NOT a TaskRegistryCase, so the row persists in the shared
      # test Store — clean it up (delete is a cast; the following synchronous
      # call from the same process orders it).
      on_exit(fn -> cleanup_task!(id) end)
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
  # Store codec's atomization whitelist survive as STRING keys, so look up
  # both spellings.
  defp task_opt(opts, key) when is_atom(key) do
    case Keyword.fetch(opts || [], key) do
      {:ok, value} -> value
      :error -> task_opt_string(opts, Atom.to_string(key))
    end
  end

  defp task_opt(opts, key) when is_binary(key), do: task_opt_string(opts, key)

  defp task_opt_string(nil, _key), do: nil

  defp task_opt_string(opts, key) do
    Enum.find_value(opts, fn
      {k, value} when k == key -> value
      _ -> nil
    end)
  end

  defp cleanup_task!(task_id) do
    if Process.whereis(EvoGit.TaskRegistry) do
      EvoGit.TaskRegistry.delete_task(task_id)
      EvoGit.TaskRegistry.list_tasks()
    end

    :ok
  end
end
