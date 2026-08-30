defmodule EvoGit.Agent.Tools.ReflectToolsTest do
  @moduledoc """
  Tests for the self-reflective-agent tools: ListTasks, GetTask, StartTask,
  CancelTask, ForceKillTask, DeleteTask, GuideUser, SpawnInvestigator,
  ListRecentProjects, SystemInfo, plus the repo-less write guard in
  `EvoGit.Agent.Tools.execute/5`.
  """

  use EvoGit.TaskRegistryCase, async: false

  @moduletag :tmp_dir

  alias EvoGit.Agent.Tools.CancelTask
  alias EvoGit.Agent.Tools.DeleteTask
  alias EvoGit.Agent.Tools.ForceKillTask
  alias EvoGit.Agent.Tools.GetTask
  alias EvoGit.Agent.Tools.GuideUser
  alias EvoGit.Agent.Tools.ListRecentProjects
  alias EvoGit.Agent.Tools.ListTasks
  alias EvoGit.Agent.Tools.SpawnInvestigator
  alias EvoGit.Agent.Tools.StartTask
  alias EvoGit.Agent.Tools.SystemInfo

  describe "ListTasks" do
    test "lists seeded tasks with id, status, type, project path, and objective" do
      task = seed_task!(opts: [path: "/tmp/test", objective: "hello"], project_path: "/tmp/test")

      output = ListTasks.execute(%{}, nil, nil)

      assert output =~ task.id
      assert output =~ "status: pending"
      assert output =~ "type: genesis"
      assert output =~ "project: /tmp/test"
      assert output =~ "objective: hello"
    end

    test "shows <system> for tasks without a project path" do
      seed_task!(opts: [objective: "no path"], project_path: nil)

      output = ListTasks.execute(%{}, nil, nil)

      assert output =~ "<system>"
      assert output =~ "objective: no path"
    end

    test "returns No tasks found for an empty registry" do
      assert ListTasks.execute(%{}, nil, nil) == "No tasks found."
    end

    test "rejects unknown statuses with an error listing valid statuses" do
      output = ListTasks.execute(%{"statuses" => ["bogus"]}, nil, nil)

      assert output =~ "Unknown status"
      assert output =~ "valid statuses"
      assert output =~ "pending"
      assert output =~ "cancelling"
    end
  end

  describe "GetTask" do
    test "returns formatted task details" do
      task = seed_task!(opts: [path: "/tmp/test", objective: "hello"])

      output = GetTask.execute(%{"task_id" => task.id}, nil, nil)

      assert output =~ task.id
      assert output =~ "status: pending"
      assert output =~ "type: genesis"
      assert output =~ "objective: hello"
    end

    test "returns not found for an unknown id" do
      assert GetTask.execute(%{"task_id" => "ghost"}, nil, nil) == "Task ghost not found."
    end

    test "missing args return a descriptive error without raising" do
      assert GetTask.execute(%{}, nil, nil) ==
               "Missing required argument 'task_id'. Please provide a valid value."
    end

    test "non-map args return an error without raising" do
      assert GetTask.execute("not-a-map", nil, nil) == "Arguments must be a map/object"
    end
  end

  describe "StartTask" do
    test "starts a reflect task and returns the new task id" do
      without_model_profiles(fn ->
        output = StartTask.execute(%{"task_type" => "reflect", "objective" => "hi"}, nil, nil)

        assert output =~ "started (type: reflect)"
        assert output =~ "Objective: hi"

        # The tool embeds the new task id in the success message.
        [task_id] = Regex.run(~r/^Task (\S+) started/, output, capture: :all_but_first)
        assert task_id != ""

        task = TaskRegistry.get_task(task_id)
        assert task != nil
        assert task.type == :reflect
      end)
    end

    test "rejects an unknown task type before calling the registry" do
      output = StartTask.execute(%{"task_type" => "bogus"}, nil, nil)

      assert output =~ "Unknown task type"
      assert output =~ "supported types"
    end

    test "bad args return error strings without raising" do
      assert StartTask.execute(%{}, nil, nil) =~ "Missing required argument 'task_type'"
      assert StartTask.execute(%{"task_type" => 42}, nil, nil) =~ "Unknown task type"
      assert StartTask.execute("not-a-map", nil, nil) == "Arguments must be a map/object"
    end
  end

  describe "CancelTask" do
    test "gracefully cancels a pending task and returns the confirmation" do
      task = seed_task!()

      output = CancelTask.execute(%{"task_id" => task.id}, nil, nil)

      assert output == "Task #{task.id} cancellation requested (graceful)."
      assert TaskRegistry.get_task(task.id).status == :cancelled
    end

    test "returns an error for an unknown id" do
      assert CancelTask.execute(%{"task_id" => "ghost"}, nil, nil) ==
               "Error cancelling task ghost: task not found"
    end

    test "missing args return a descriptive error without raising" do
      assert CancelTask.execute(%{}, nil, nil) ==
               "Missing required argument 'task_id'. Please provide a valid value."
    end
  end

  describe "ForceKillTask" do
    test "force-kills a running task and returns the confirmation" do
      {task_id, _wrapper} = seed_running_task_with_wrapper!()

      output = ForceKillTask.execute(%{"task_id" => task_id}, nil, nil)

      assert output == "Task #{task_id} force-killed."
      assert TaskRegistry.get_task(task_id).status == :failed
    end

    test "returns an error for an unknown id" do
      assert ForceKillTask.execute(%{"task_id" => "ghost"}, nil, nil) ==
               "Error force-killing task ghost: task not found"
    end
  end

  describe "DeleteTask" do
    test "deletes a task and returns the confirmation" do
      task = seed_task!()

      output = DeleteTask.execute(%{"task_id" => task.id}, nil, nil)

      assert output == "Task #{task.id} deleted."

      # delete_task/1 is a fire-and-forget cast; a call syncs the mailbox so the
      # cast is guaranteed processed before the row read.
      TaskRegistry.list_tasks()
      assert TaskRegistry.get_task(task.id) == nil
    end

    test "delete_task is a cast, so it reports deleted even for an unknown id" do
      # delete_task/1 is a GenServer.cast that always returns :ok — the tool can
      # never produce an error for an unknown id (no registry call is made).
      assert DeleteTask.execute(%{"task_id" => "ghost"}, nil, nil) == "Task ghost deleted."
    end
  end

  describe "GuideUser" do
    test "broadcasts a guide on the guides topic and returns a confirmation" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "guides")

      output =
        GuideUser.execute(
          %{"message" => "m", "page" => "/tasks", "selector" => "#x", "dismissible" => true},
          nil,
          nil
        )

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

    test "missing message returns a descriptive error without raising" do
      # GuideUser's `with` has no else clause, so the error surfaces as a
      # {:error, message} tuple (still never raises).
      assert {:error, message} = GuideUser.execute(%{}, nil, nil)
      assert message == "Missing required argument 'message'. Please provide a valid value."
    end
  end

  describe "SpawnInvestigator" do
    test "returns the placeholder message mentioning the future release and read-only tools" do
      output =
        SpawnInvestigator.execute(%{"path" => "./", "objective" => "investigate"}, nil, nil)

      assert output =~ "not available in this release"
      assert output =~ "future release"
      assert output =~ "read-only"
      assert output =~ "read_file"
    end

    test "missing required args return a descriptive error without raising" do
      # SpawnInvestigator's `with` has no else clause, so the error surfaces as
      # a {:error, message} tuple (still never raises).
      assert {:error, message} = SpawnInvestigator.execute(%{"path" => "./"}, nil, nil)
      assert message == "Missing required argument 'objective'. Please provide a valid value."

      assert {:error, message} = SpawnInvestigator.execute(%{"objective" => "x"}, nil, nil)
      assert message == "Missing required argument 'path'. Please provide a valid value."
    end
  end

  describe "ListRecentProjects" do
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
      output = ListRecentProjects.execute(%{}, nil, nil)

      assert output =~ "Project A"
      assert output =~ "/proj/a"
      assert output =~ DateTime.to_iso8601(last_opened)
    end

    test "returns No recent projects found for an empty registry" do
      # The isolated TaskRegistryCase store is fresh per test (a new sqlite
      # file is created in setup), so no cleanup of happy-path seeds is needed
      # — same idiom as the ListTasks empty-registry test.
      assert ListRecentProjects.execute(%{}, nil, nil) == "No recent projects found."
    end

    test "reports task system unavailable when the registry is down" do
      registry = Process.whereis(EvoGit.TaskRegistry)
      assert is_pid(registry)

      # Unregistering only removes the name — the isolated registry process
      # stays alive, so it can be re-registered in the after block.
      Process.unregister(EvoGit.TaskRegistry)

      try do
        output = ListRecentProjects.execute(%{}, nil, nil)
        assert output =~ "task system unavailable"
      after
        assert Process.register(registry, EvoGit.TaskRegistry) == true
      end

      assert Process.whereis(EvoGit.TaskRegistry) == registry
    end

    test "dispatch path works while repo_less", %{tmp_dir: tmp_dir} do
      Process.put(:repo_less, true)

      try do
        # project.list (the old list_recent_projects tool) is a read/control
        # tool — it must not be blocked by the repo-less write guard. It is
        # routed through the single run_command shell tool, which is
        # deliberately NOT in @write_tools.
        assert EvoGit.Agent.Tools.execute("run_command", %{"command" => "project.list"}, tmp_dir) ==
                 "No recent projects found."
      after
        Process.delete(:repo_less)
      end
    end
  end

  describe "SystemInfo" do
    test "returns a multi-line key: value report with all expected fields" do
      output = SystemInfo.execute(%{}, nil, nil)

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

    test "dispatch path works while repo_less", %{tmp_dir: tmp_dir} do
      Process.put(:repo_less, true)

      try do
        # system.info (the old system_info tool) is a read-only,
        # dependency-free command — it must not be blocked by the repo-less
        # write guard. Routed through the run_command shell tool.
        output = EvoGit.Agent.Tools.execute("run_command", %{"command" => "system.info"}, tmp_dir)
        assert output =~ "os:"
        assert output =~ System.version()
      after
        Process.delete(:repo_less)
      end
    end

    test "never raises on empty args" do
      assert is_binary(SystemInfo.execute(%{}, nil, nil))
    end
  end

  describe "repo-less write guard (Tools.execute/5)" do
    test "blocks write tools with the disabled error while repo_less", %{tmp_dir: tmp_dir} do
      Process.put(:repo_less, true)

      try do
        # run_bash is intentionally NOT asserted — its tool name varies by OS
        # (run_powershell on Windows).
        for tool <- ["write_file", "edit_file", "skill_add"] do
          result = EvoGit.Agent.Tools.execute(tool, %{"file_path" => "x"}, tmp_dir)

          assert result ==
                   "Error: this agent has read-only access to the system — the #{tool} tool is disabled."
        end

        # The JSON-string-args path (LLM double-encode recovery) is blocked too.
        json_result =
          EvoGit.Agent.Tools.execute("write_file", Jason.encode!(%{"file_path" => "x"}), tmp_dir)

        assert json_result ==
                 "Error: this agent has read-only access to the system — the write_file tool is disabled."
      after
        Process.delete(:repo_less)
      end
    end

    test "read tools still work while repo_less", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello reflect")

      Process.put(:repo_less, true)

      try do
        result = EvoGit.Agent.Tools.execute("read_file", %{"file_path" => "test.txt"}, tmp_dir)
        assert result =~ "hello reflect"

        # task.list (the old list_tasks tool) is read-only and must not be
        # blocked — routed through the run_command shell tool.
        assert EvoGit.Agent.Tools.execute("run_command", %{"command" => "task.list"}, tmp_dir) ==
                 "No tasks found."
      after
        Process.delete(:repo_less)
      end
    end

    test "removing the repo_less key restores write_file to normal", %{tmp_dir: tmp_dir} do
      Process.put(:repo_less, true)
      Process.delete(:repo_less)

      result =
        EvoGit.Agent.Tools.execute("write_file", %{"file_path" => "x", "content" => "y"}, tmp_dir)

      assert result =~ "Successfully wrote"
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
