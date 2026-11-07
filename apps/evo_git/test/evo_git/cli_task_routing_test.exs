defmodule EvoGit.CLI.TaskRoutingFixture do
  @moduledoc false

  def isolate_config!(registry) do
    dir = EvoGit.TestSupport.ConfigDir.isolate!("evogit-cli-task-routing")

    # start_supervised!/1 starts this private registry outside the test's
    # $callers chain. Bind its config explicitly: admission runs in the
    # registry, and execution inherits the registry through $callers.
    :sys.replace_state(registry, fn state ->
      EvoGit.TestSupport.ConfigDir.activate(dir)
      state
    end)

    :ok
  end

  def save_provider_config! do
    config = %{
      llm: %{
        default_provider_profile: "myprofile",
        providers: [
          %{
            id: "myprofile",
            provider: "openai",
            concurrency: 5,
            api_key_env_var: "EVOGIT_CLI_ROUTING_KEY",
            base_url: "https://routing.example/v1",
            temperature: 0.6,
            default_model: "test-model",
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "low",
            models: [
              %{model: "test-model", context_window: 128_000},
              %{
                model: "review-model",
                context_window: 64_000,
                temperature: 0.3,
                reasoning_efforts: ["high"],
                default_reasoning_effort: "high"
              }
            ]
          }
        ]
      }
    }

    :ok = EvoGit.Config.save_user_config(config)
    config
  end
end

defmodule EvoGit.CLI.TaskRoutingTest do
  @moduledoc """
  CLI → isolated TaskRegistry/Store routing with real task admission and execution.
  The scheduler's model profiles are temporarily emptied so admitted tasks fail
  at run_agent/1 without a real LLM request.
  """

  # async: false is FORCED by ONE remaining piece of BEAM-global state:
  # `without_model_profiles/1` rewrites the global `EvoGit.AgentScheduler`'s
  # `model_profiles` so the enqueued task fails fast at `run_agent/1`. The `-m`
  # config resolution is isolated PER PROCESS (`EvoGit.TestSupport.ConfigDir`),
  # so no process-wide env var is touched.
  use EvoGit.TaskRegistryCase, async: false

  @moduletag :tmp_dir

  import ExUnit.CaptureIO

  import EvoGit.CLI.TaskRoutingFixture

  # Observable-contract regexes from the CLI + task data-plane refactor.
  @started_re ~r/^Task ([0-9a-f]{16}) started \(type: (genesis|evolve|reflect)\)$/m
  @failed_re ~r/^Task [0-9a-f]{16} failed\./

  # Bind CLI, registry admission and task execution to one per-test config.
  setup %{registry: registry} do
    isolate_config!(registry)
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
      # Auto leaves selection rules in control: no spec, legacy id or lock.
      assert task_opt(task.opts, :model_spec) == nil
      assert task_opt(task.opts, :model_id) == nil
      assert task_opt(task.opts, :model_id_locked) == nil
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

  describe "model selection routing" do
    test "legacy -m forms persist a canonical selection and lock, not a model id", %{
      tmp_dir: tmp_dir
    } do
      save_provider_config!()

      for {value, index} <-
            Enum.with_index([
              "myprofile",
              "myprofile:ignored:ignored",
              "openai:test-model",
              "test-model"
            ]) do
        repo = Path.join(tmp_dir, "evolve_m_#{index}")

        {output, result} =
          without_model_profiles(fn ->
            run_cli(["evolve", "fix x", "-m", value, "--mode", "simple", "--path", repo])
          end)

        task = TaskRegistry.get_task(started_task_id!(output))
        assert {:error, msg} = result
        assert msg =~ @failed_re
        assert task.type == :evolve
        assert task.status == :failed
        assert inspect(task.result) =~ "llm_not_configured"
        assert task_opt(task.opts, :mode) == "simple"

        assert task_opt(task.opts, :model_spec) == %{
                 "provider_profile_id" => "myprofile",
                 "model" => "test-model",
                 "reasoning_effort" => "low"
               }

        assert task_opt(task.opts, :model_id_locked) == true
        assert task_opt(task.opts, :model_id) == nil
        assert task.model_id == nil
      end
    end

    test "explicit account/model/effort selections survive every CLI task entry point", %{
      tmp_dir: tmp_dir
    } do
      config = save_provider_config!()
      assert :ok = EvoGit.Config.save_credentials(%{"EVOGIT_CLI_ROUTING_KEY" => "secret-key"})

      selection = %{
        "provider_profile_id" => "myprofile",
        "model" => "review-model",
        "reasoning_effort" => "high"
      }

      assert {:ok, resolved} = EvoGit.Config.Schema.resolve_model_spec(config, selection)
      assert resolved.generation_params[:api_key] == "secret-key"

      assert resolved.model_spec == %{
               provider: :openai,
               id: "review-model",
               base_url: "https://routing.example/v1"
             }

      for {command, mode} <- [{"genesis", "new"}, {"evolve", "simple"}, {"reflect", nil}] do
        path_flags =
          if mode do
            dir = Path.join(tmp_dir, command)
            File.mkdir_p!(dir)
            ["--mode", mode, "--path", dir]
          else
            []
          end

        {output, result} =
          without_model_profiles(fn ->
            run_cli(
              [
                command,
                "selected task",
                "--provider-profile",
                "myprofile",
                "--model",
                "review-model",
                "--reasoning-effort",
                "high"
              ] ++ path_flags
            )
          end)

        task = TaskRegistry.get_task(started_task_id!(output))
        assert {:error, msg} = result
        assert msg =~ @failed_re
        assert task.status == :failed
        assert inspect(task.result) =~ "llm_not_configured"
        assert Atom.to_string(task.type) == command
        assert task_opt(task.opts, :model_spec) == selection
        assert task_opt(task.opts, :model_id_locked) == true
        assert task_opt(task.opts, :model_id) == nil
        assert task.model_id == nil
        refute inspect(task.opts) =~ "secret-key"
        refute inspect(task.opts) =~ "https://routing.example"
        if command == "reflect", do: assert(task_opt(task.opts, :path) == nil)
      end
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

    test "run still performs real legacy mutations after assistant run_command is retired" do
      id = "cli_legacy_#{System.unique_integer([:positive])}"
      :ok = EvoGit.Store.put_task(store(), %TaskInfo{id: id, type: :reflect, status: :pending})

      command = "CancelTask.cancel_task #{id}"

      assert EvoGit.Agent.Tools.execute("run_command", %{"command" => command}, nil, nil, nil) ==
               "Error: use elixir_eval exact-code approval path"

      assert TaskRegistry.get_task(id).status == :pending

      {output, result} = run_cli(["run", command])

      assert result == :ok
      assert output =~ "Task #{id} cancellation requested (graceful)."
      assert TaskRegistry.get_task(id).status == :cancelled
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

defmodule EvoGit.CLI.ModelSelectionRejectionTest do
  # All failures precede dispatch; only private registry/store processes and
  # per-process config are touched, so no global scheduler mutation is needed.
  use EvoGit.TaskRegistryCase, async: true

  import ExUnit.CaptureIO
  import EvoGit.CLI.TaskRoutingFixture

  @moduletag :tmp_dir

  setup %{registry: registry} do
    isolate_config!(registry)
  end

  test "unknown legacy selection with no accounts creates no task row", %{tmp_dir: dir} do
    output =
      capture_io(fn ->
        assert :ok = EvoGit.CLI.main(["evolve", "fix x", "-m", "unknown", "--path", dir])
      end)

    assert output =~ "no LLM models are configured"
    refute output =~ "started (type:"
    assert TaskRegistry.list_tasks() == []
  end

  test "invalid CLI selections fail before enqueue across all task entry points", %{tmp_dir: dir} do
    save_provider_config!()

    for command <- ["genesis", "evolve", "reflect"],
        flags <- [
          ["-m", "unknown"],
          ["--provider-profile", "missing", "--model", "test-model"],
          ["--provider-profile", "myprofile", "--model", "missing"],
          [
            "--provider-profile",
            "myprofile",
            "--model",
            "review-model",
            "--reasoning-effort",
            "low"
          ],
          ["--provider-profile", "myprofile"],
          ["--model", "test-model", "--reasoning-effort", "high"]
        ] do
      path = Path.join(dir, "not-created")

      output =
        capture_io(fn ->
          assert :ok = EvoGit.CLI.main([command, "invalid selection", "--path", path] ++ flags)
        end)

      assert output =~ "Error:"
      refute output =~ "started (type:"
      assert TaskRegistry.list_tasks() == []
      refute File.exists?(path)
    end
  end

  test "registry admission rejects an invalid explicit spec even with a valid legacy id" do
    save_provider_config!()

    for {spec, reason} <- [
          {"openai:test-model", :invalid_model_spec},
          {%{"provider_profile_id" => "missing", "model" => "test-model"},
           {:provider_profile_not_found, "missing"}},
          {%{"provider_profile_id" => "myprofile", "model" => "missing"},
           {:model_not_found, "myprofile", "missing"}},
          {%{
             "provider_profile_id" => "myprofile",
             "model" => "review-model",
             "reasoning_effort" => "low"
           }, {:unsupported_reasoning_effort, "low", ["high"]}}
        ] do
      assert {:error, ^reason} =
               TaskRegistry.start_task(:reflect,
                 objective: "invalid spec",
                 model_spec: spec,
                 model_id: "myprofile"
               )

      assert TaskRegistry.list_tasks() == []
    end
  end
end
