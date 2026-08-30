defmodule EvoGit.CommandShellTest do
  @moduledoc """
  Tests for the `EvoGit.CommandShell` command-shell dispatcher — the single
  entry point behind the self-reflective agent's `run_command` tool.

  The pure parser/validation/guardrail tests in the "parsing" and "security"
  describe blocks have no registry side effects. The dispatch tests exercise
  every registered command against the real TaskRegistry (isolated via
  `EvoGit.TaskRegistryCase`), asserting the same handler outputs the old
  per-tool tests asserted.
  """

  use EvoGit.TaskRegistryCase, async: false

  @moduletag :tmp_dir

  alias EvoGit.CommandShell

  # The full registered command catalog (sorted, as returned by list_commands/0).
  @all_commands ~w(
    guide.show
    project.list
    system.info
    task.cancel
    task.delete
    task.force_kill
    task.get
    task.investigate
    task.list
    task.start
  )

  describe "execute/1 - parsing" do
    test "positional tokens bind to declared positional args" do
      task = seed_task!()

      assert {:ok, output} = CommandShell.execute("task.get #{task.id}")
      assert output =~ task.id
      assert output =~ "status: pending"
      assert output =~ "objective: hello"
    end

    test "key=value tokens bind to declared kv args" do
      task = seed_task!()

      assert {:ok, output} = CommandShell.execute("task.get task_id=#{task.id}")
      assert output =~ task.id
      assert output =~ "status: pending"
    end

    test "double-quoted tokens preserve spaces" do
      # Quoted tokens with spaces (and an escaped quote) parse as one argument.
      assert {:ok, output} = CommandShell.execute(~s(task.get "some id"))
      assert output == "Task some id not found."

      assert {:ok, output} =
               CommandShell.execute(~s(task.investigate "./path with spaces" "objective here"))

      assert output =~ "not available in this release"
    end

    test "unknown keys are treated as positional tokens, not kv pairs" do
      # `hello` is not a declared arg key for task.get, so `hello=world` stays a
      # positional token and binds to task_id verbatim.
      assert {:ok, output} = CommandShell.execute("task.get hello=world")
      assert output == "Task hello=world not found."
    end

    test "duplicate key=value arguments are rejected" do
      assert CommandShell.execute("task.get task_id=a task_id=b") ==
               {:error, "Duplicate argument 'task_id' for 'task.get'."}
    end

    test "extra positional arguments are rejected" do
      assert CommandShell.execute("task.get a b") ==
               {:error, "Too many positional arguments for 'task.get': expected at most 1."}
    end

    test "missing required arguments are rejected" do
      assert CommandShell.execute("task.get") ==
               {:error, "Missing required argument 'task_id' for 'task.get'."}
    end

    test "unknown commands are rejected with a help hint" do
      assert CommandShell.execute("task.nonexistent") ==
               {:error,
                "Unknown command 'task.nonexistent'. Run 'help' to list available commands."}
    end

    test "empty and whitespace-only commands are rejected" do
      assert CommandShell.execute("") ==
               {:error, "Empty command. Run 'help' to list available commands."}

      assert CommandShell.execute("   ") ==
               {:error, "Empty command. Run 'help' to list available commands."}
    end

    test "unterminated double quotes are rejected" do
      assert CommandShell.execute(~s(task.get "abc)) ==
               {:error, "Unterminated double quote in command."}
    end

    test "non-string input is rejected" do
      assert CommandShell.execute(123) == {:error, "Command must be a string."}
      assert CommandShell.execute(nil) == {:error, "Command must be a string."}
      assert CommandShell.execute(%{}) == {:error, "Command must be a string."}
    end
  end

  describe "execute/1 - guardrails" do
    test "commands longer than 4000 characters are rejected" do
      command = String.duplicate("a", 4001)

      assert CommandShell.execute(command) ==
               {:error, "Command exceeds the maximum length of 4000 characters."}
    end

    test "commands with more than 40 tokens are rejected" do
      command = Enum.join(List.duplicate("a", 41), " ")

      assert CommandShell.execute(command) ==
               {:error, "Command has too many tokens (maximum 40)."}
    end

    test "tokens longer than 2000 characters are rejected" do
      command = String.duplicate("a", 2001)

      assert CommandShell.execute(command) ==
               {:error, "Command token exceeds the maximum length of 2000 characters."}
    end

    test "exact boundary values pass the guardrails and reach dispatch" do
      # 2000-char single token: at the exact token-length cap the check passes
      # and dispatch runs — the unknown path is rejected by the registry, not
      # the guardrail.
      command = String.duplicate("a", 2000)

      assert {:error, message} = CommandShell.execute(command)
      assert message =~ "Unknown command"

      # Exactly 40 tokens: at the exact token-count cap the check passes and
      # dispatch runs — the command's own argument validation rejects the extra
      # positionals.
      command = Enum.join(["task.get" | List.duplicate("a", 39)], " ")

      assert {:error, message} = CommandShell.execute(command)
      assert message =~ "Too many positional arguments"
    end
  end

  describe "execute/1 - help" do
    test "help returns the catalog listing all 10 commands" do
      assert {:ok, output} = CommandShell.execute("help")
      assert output =~ "Available commands:"

      for command <- @all_commands do
        assert output =~ command, "expected help catalog to list #{inspect(command)}"
      end

      assert output =~ "help [command]"
    end

    test "help <command> returns the per-command detail" do
      assert {:ok, output} = CommandShell.execute("help task.get")
      assert output =~ "task.get"
      assert output =~ "Usage: task.get <task_id>"

      assert {:ok, output} = CommandShell.execute("help task.start")
      assert output =~ "Usage: task.start <task_type>"
    end

    test "help with an unknown command path returns an error" do
      assert CommandShell.execute("help task.nonexistent") ==
               {:error,
                "Unknown command 'task.nonexistent'. Run 'help' to list available commands."}
    end

    test "help accepts at most one command path" do
      assert CommandShell.execute("help task.get task.list") ==
               {:error, "help accepts at most one command path argument."}
    end
  end

  describe "list_commands/0 and help/1" do
    test "list_commands/0 returns the 10 registered paths sorted" do
      assert CommandShell.list_commands() == @all_commands
      assert length(CommandShell.list_commands()) == 10
    end

    test "help/1 returns a detail tuple or an error tuple" do
      assert {:ok, detail} = CommandShell.help("task.list")
      assert detail =~ "statuses"

      assert CommandShell.help("nope") ==
               {:error, "Unknown command 'nope'. Run 'help' to list available commands."}
    end
  end

  describe "execute/1 - security" do
    test "code evaluation strings are rejected as unknown commands" do
      assert {:error, message} = CommandShell.execute(~s|Code.eval_string("1+1")|)
      assert message =~ "Unknown command"

      assert {:error, message} = CommandShell.execute(~s|String.to_atom("x")|)
      assert message =~ "Unknown command"
    end

    test "dynamic-dispatch-looking paths are rejected" do
      for command <- ["elixir.apply", "apply", "Code.eval", "System.cmd", "task.nonexistent"] do
        assert {:error, message} = CommandShell.execute(command)
        assert message =~ "Unknown command '#{command}'"
      end
    end

    test "enum arguments reject invalid values listing the valid ones" do
      assert CommandShell.execute("task.start bogus") ==
               {:error,
                "Invalid value 'bogus' for argument 'task_type' of 'task.start'; valid values: genesis, evolve, reflect, extract_skills."}

      assert CommandShell.execute("task.list statuses=bogus") ==
               {:error,
                "Invalid value 'bogus' for argument 'statuses' of 'task.list'; valid values: pending, running, finalizing, completed, failed, cancelled, cancelling."}
    end

    test "bool arguments reject invalid values" do
      assert CommandShell.execute("guide.show m dismissible=maybe") ==
               {:error,
                "Invalid boolean value 'maybe' for argument 'dismissible' of 'guide.show'; use 'true' or 'false'."}
    end
  end

  describe "execute/1 - task.list" do
    test "lists seeded tasks with id, status, type, project path, and objective" do
      task = seed_task!(opts: [path: "/tmp/test", objective: "hello"], project_path: "/tmp/test")

      assert {:ok, output} = CommandShell.execute("task.list")
      assert output =~ task.id
      assert output =~ "status: pending"
      assert output =~ "type: genesis"
      assert output =~ "project: /tmp/test"
      assert output =~ "objective: hello"
    end

    test "filters by statuses= key=value argument" do
      task = seed_task!()

      assert {:ok, output} = CommandShell.execute("task.list statuses=pending")
      assert output =~ task.id

      assert {:ok, output} = CommandShell.execute("task.list statuses=completed,failed")
      assert output == "No tasks found."
    end

    test "returns No tasks found for an empty registry" do
      assert {:ok, output} = CommandShell.execute("task.list")
      assert output == "No tasks found."
    end
  end

  describe "execute/1 - task.get" do
    test "returns formatted task details" do
      task = seed_task!(opts: [path: "/tmp/test", objective: "hello"])

      assert {:ok, output} = CommandShell.execute("task.get #{task.id}")
      assert output =~ task.id
      assert output =~ "status: pending"
      assert output =~ "type: genesis"
      assert output =~ "objective: hello"
    end

    test "returns not found for an unknown id" do
      assert {:ok, output} = CommandShell.execute("task.get ghost")
      assert output == "Task ghost not found."
    end
  end

  describe "execute/1 - task.start" do
    test "starts a reflect task and returns the new task id" do
      without_model_profiles(fn ->
        assert {:ok, output} = CommandShell.execute(~s(task.start reflect "hi"))

        assert output =~ "started (type: reflect)"
        assert output =~ "Objective: hi"

        # The handler embeds the new task id in the success message.
        [task_id] = Regex.run(~r/^Task (\S+) started/, output, capture: :all_but_first)
        assert task_id != ""

        task = TaskRegistry.get_task(task_id)
        assert task != nil
        assert task.type == :reflect
      end)
    end

    test "rejects an unknown task type before calling the registry" do
      assert {:error, message} = CommandShell.execute("task.start bogus")
      assert message =~ "valid values: genesis, evolve, reflect, extract_skills"
    end
  end

  describe "execute/1 - task.cancel" do
    test "gracefully cancels a pending task and returns the confirmation" do
      task = seed_task!()

      assert {:ok, output} = CommandShell.execute("task.cancel #{task.id}")
      assert output == "Task #{task.id} cancellation requested (graceful)."
      assert TaskRegistry.get_task(task.id).status == :cancelled
    end

    test "returns an error for an unknown id" do
      assert {:ok, output} = CommandShell.execute("task.cancel ghost")
      assert output == "Error cancelling task ghost: task not found"
    end
  end

  describe "execute/1 - task.force_kill" do
    test "force-kills a running task and returns the confirmation" do
      {task_id, _wrapper} = seed_running_task_with_wrapper!()

      assert {:ok, output} = CommandShell.execute("task.force_kill #{task_id}")
      assert output == "Task #{task_id} force-killed."
      assert TaskRegistry.get_task(task_id).status == :failed
    end

    test "returns an error for an unknown id" do
      assert {:ok, output} = CommandShell.execute("task.force_kill ghost")
      assert output == "Error force-killing task ghost: task not found"
    end
  end

  describe "execute/1 - task.delete" do
    test "deletes a task and returns the confirmation" do
      task = seed_task!()

      assert {:ok, output} = CommandShell.execute("task.delete #{task.id}")
      assert output == "Task #{task.id} deleted."

      # delete_task/1 is a fire-and-forget cast; a call syncs the mailbox so the
      # cast is guaranteed processed before the row read.
      TaskRegistry.list_tasks()
      assert TaskRegistry.get_task(task.id) == nil
    end

    test "delete_task is a cast, so it reports deleted even for an unknown id" do
      assert {:ok, output} = CommandShell.execute("task.delete ghost")
      assert output == "Task ghost deleted."
    end
  end

  describe "execute/1 - guide.show" do
    test "broadcasts a guide on the guides topic and returns a confirmation" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "guides")

      assert {:ok, output} =
               CommandShell.execute("guide.show \"m\" page=/tasks selector=#x dismissible=true")

      assert output == "Guide shown to user: m"

      assert_receive {:guide_updated, guide_id, guide_map, node}
      assert is_binary(guide_id)
      assert String.starts_with?(guide_id, "guide-")
      assert guide_map.message == "m"
      assert guide_map.page == "/tasks"
      assert guide_map.selector == "#x"
      assert guide_map.dismissible == true
      assert node == node()
    end

    test "dismissible defaults to true when absent" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "guides")

      assert {:ok, _output} = CommandShell.execute("guide.show hello")

      assert_receive {:guide_updated, _guide_id, guide_map, _node}
      assert guide_map.dismissible == true
    end
  end

  describe "execute/1 - task.investigate" do
    test "returns the v1 placeholder message (does NOT spawn)" do
      assert {:ok, output} = CommandShell.execute("task.investigate ./ investigate")
      assert output =~ "not available in this release"
      assert output =~ "future release"
      assert output =~ "read-only"
      assert output =~ "read_file"
    end
  end

  describe "execute/1 - project.list" do
    test "returns No recent projects found for an empty registry" do
      assert {:ok, output} = CommandShell.execute("project.list")
      assert output == "No recent projects found."
    end

    test "lists seeded recent projects with name, path, and last opened time" do
      # Truncate to millisecond precision so the ISO string survives the Store
      # round-trip (Codec.encode_datetime truncates to milliseconds).
      last_opened = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      :ok =
        EvoGit.Store.put_project(EvoGit.Store, %EvoGit.RecentProject{
          path: "/proj/a",
          name: "Project A",
          last_opened_at: last_opened
        })

      # list_recent_projects/0 reads LIVE from the Store, so direct Store
      # seeding is visible — same idiom as seed_task!.
      assert {:ok, output} = CommandShell.execute("project.list")
      assert output =~ "Project A"
      assert output =~ "/proj/a"
      assert output =~ DateTime.to_iso8601(last_opened)
    end
  end

  describe "execute/1 - system.info" do
    test "returns a multi-line key: value report with all expected fields" do
      assert {:ok, output} = CommandShell.execute("system.info")

      assert output =~ "os:"
      assert output =~ "architecture:"
      assert output =~ "hostname:"
      assert output =~ "local time:"
      assert output =~ "utc time:"
      assert output =~ "elixir version:"
      assert output =~ "otp version:"
      assert output =~ "data directory:"
      assert output =~ System.version()
      assert output =~ System.otp_release()
      assert output =~ EvoGit.Platform.data_dir()
    end
  end

  # --- Helpers -------------------------------------------------------------

  # Seeds a task row directly into the isolated Store (bypassing the registry).
  # Returns the %TaskInfo{} so callers can use task.id. Defaults to a pending
  # :genesis task; pass keyword overrides to customize.
  defp seed_task!(attrs \\ []) do
    task =
      struct(
        TaskInfo,
        Keyword.merge(
          [
            id: "reflect_tool_#{System.unique_integer([:positive])}",
            type: :genesis,
            status: :pending,
            opts: [path: "/tmp/test", objective: "hello"],
            project_path: "/tmp/test",
            started_at: DateTime.utc_now()
          ],
          attrs
        )
      )

    :ok = EvoGit.Store.put_task(EvoGit.Store, task)
    task
  end

  # Seeds a :running task and injects a live wrapper process into the registry's
  # task_refs (the only way force_kill_task sees a genuinely killable task — a
  # bare seeded row has no ref). Returns {task_id, wrapper_pid}.
  defp seed_running_task_with_wrapper! do
    task_id = "reflect_kill_#{System.unique_integer([:positive])}"
    wrapper = spawn(fn -> Process.sleep(:infinity) end)

    :ok =
      EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
        id: task_id,
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) + 300
      })

    :sys.replace_state(EvoGit.TaskRegistry, fn state ->
      %{state | task_refs: Map.put(state.task_refs, task_id, fake_task_ref(wrapper))}
    end)

    {task_id, wrapper}
  end

  # A %Task{} wrapper entry for the task_refs map (content beyond pid is
  # irrelevant to the force-kill path).
  defp fake_task_ref(pid) do
    %Task{
      pid: pid,
      ref: make_ref(),
      owner: self(),
      mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:genesis, [], "test"]}
    }
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
end
