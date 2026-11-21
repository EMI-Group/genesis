defmodule EvoGit.TaskControlTest do
  # `async: false` is FORCED by two app-global members: the pause/resume path
  # flags tasks in the app-global `EvoGit.AgentScheduler` (`TaskRegistry.Pause`
  # → `begin_task_pause`/`clear_task_pause`), and a resume restores a durable
  # run through the app-booted `EvoGit.AgentState` server.
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.TaskControl
  @moduletag :tmp_dir

  test "service failures do not expose GenServer call arguments" do
    Process.put(:evogit_task_registry_server, :missing_registry_during_control_test)

    assert {:error, %{code: "unavailable", message: message}} =
             TaskControl.get(%{"task_id" => "sensitive-internal-argument"})

    refute message =~ "sensitive-internal-argument"
    refute message =~ "GenServer"
  end

  test "rejects invalid submissions before creating a task", %{tmp_dir: path} do
    for args <- [
          %{"path" => "relative", "objective" => "work"},
          %{"path" => path, "objective" => " "},
          %{"path" => path, "objective" => "work", "task_type" => "reflect"},
          %{"path" => path, "objective" => "work", "mode" => "custom"},
          %{"path" => path, "objective" => "work", "budget" => %{"max_agents" => 0}},
          %{"path" => path, "objective" => "work", "unexpected" => true}
        ] do
      assert {:error, %{code: "invalid_arguments"}} = TaskControl.start(args)
    end

    assert TaskRegistry.list_tasks() == []
  end

  test "cancellation exposes request acceptance without claiming process cleanup" do
    seed!("pending-stop", :pending, "/tmp/project", nil)
    assert {:ok, data} = TaskControl.cancel(%{"task_id" => "pending-stop"})
    assert data.status == "cancelled"
    assert data.cancel_requested
    refute Map.has_key?(data, :stopped)
    refute Map.has_key?(data, :pending_cleanup)

    assert {:ok, %{cancel_requested: false, status: "cancelled"}} =
             TaskControl.cancel(%{"task_id" => "pending-stop"})

    assert {:error, %{code: "invalid_arguments"}} =
             TaskControl.cancel(%{"task_id" => "pending-stop", "force" => "yes"})
  end

  test "returns structured completed and failed results without exposing runtime opts" do
    seed!("done", :completed, "/tmp/project", {:ok, %{result: "Implemented", commit_sha: "abc"}})
    seed!("failed", :failed, "/tmp/project", {:error, {:provider, :offline}})
    assert {:ok, done} = TaskControl.get(%{"task_id" => "done"})
    assert done.status == "completed"
    assert done.result["data"]["result"] == "Implemented"
    assert done.result["data"]["commit_sha"] == "abc"
    refute Map.has_key?(done, :opts)
    assert {:ok, failed} = TaskControl.get(%{"task_id" => "failed"})
    assert failed.status == "failed"
    assert failed.result["reason"] =~ "offline"
    assert {:ok, _} = Jason.encode(failed)
    assert {:error, %{code: "not_found"}} = TaskControl.get(%{"task_id" => "missing"})
  end

  test "lists only the requested project with bounded pagination", %{tmp_dir: dir} do
    path = Path.join(dir, "a")
    seed!("a", :completed, path, nil)
    seed!("b", :completed, Path.join(dir, "b"), nil)

    assert {:ok, %{tasks: [%{id: "a"}], total: 1}} =
             TaskControl.list(%{"path" => path, "limit" => 1})

    assert {:error, %{code: "invalid_arguments"}} = TaskControl.list(%{"limit" => 10000})
  end

  test "rejects missing, active, or other-project resume before submission", %{tmp_dir: path} do
    seed!("active", :running, path, nil)
    seed!("other", :completed, "/tmp/other", nil)

    for id <- ["missing", "active", "other"] do
      assert {:error, _} =
               TaskControl.start(%{
                 "path" => path,
                 "objective" => "continue",
                 "resume_from" => id
               })
    end

    assert length(TaskRegistry.list_tasks()) == 2
  end

  test "cancels a pending task using the registry" do
    seed!("cancel", :pending, "/tmp/project", nil)

    assert {:ok, %{id: "cancel", status: "cancelled"}} =
             TaskControl.cancel(%{"task_id" => "cancel"})

    assert TaskRegistry.get_task("cancel").status == :cancelled
    assert {:error, %{code: "not_found"}} = TaskControl.cancel(%{"task_id" => "missing"})
  end

  test "submits through the existing registry with the expected prompt", %{tmp_dir: path} do
    assert {:ok, %{id: id}} =
             TaskControl.start(%{
               "path" => path,
               "objective" => "Build a tiny example",
               "task_type" => "genesis"
             })

    task = TaskRegistry.get_task(id)
    assert task.type == :genesis
    assert task.opts[:prompt] == "Build a tiny example"
    assert task.opts[:objective] == task.opts[:prompt]
    assert task.opts[:mode] == "new"
    assert task.opts[:path] == path
    TaskRegistry.cancel_task(id)
  end

  test "rejects an unknown model profile before submission", %{tmp_dir: path} do
    assert {:error, %{code: "invalid_arguments"}} =
             TaskControl.start(%{
               "path" => path,
               "objective" => "work",
               "model_id" => "missing-mcp-profile"
             })

    assert TaskRegistry.list_tasks() == []
  end

  test "check reports an unborn repository without changing it", %{tmp_dir: path} do
    {_, 0} = System.cmd("git", ["init", "-q", path])
    assert {:ok, status} = TaskControl.check(%{"path" => path})
    refute status.project.ready
    assert status.project.reason =~ "initial commit"

    assert {:error, %{code: "invalid_arguments"}} =
             TaskControl.start(%{"path" => path, "objective" => "work"})

    assert TaskRegistry.list_tasks() == []
    refute File.exists?(Path.join(path, ".gitignore"))
  end

  test "check preserves the runtime's ability to initialize a non-Git directory", %{tmp_dir: path} do
    assert {:ok, status} = TaskControl.check(%{"path" => path})
    assert status.project.ready
    assert status.project.git_action == "initialize_repository"
    refute File.exists?(Path.join(path, ".git"))
  end

  test "accepts a finished task in the same project as resume context", %{tmp_dir: path} do
    seed!("previous", :completed, path, {:ok, %{result: "Prior context"}})

    assert {:ok, %{id: id}} =
             TaskControl.start(%{
               "path" => path,
               "objective" => "Continue",
               "resume_from" => "previous"
             })

    task = TaskRegistry.get_task(id)
    assert task.type == :evolve
    assert task.opts[:resume_from] == "previous"
    TaskRegistry.cancel_task(id)
  end

  test "progress changes only when execution changes and terminal reads never wait" do
    seed!("observed", :completed, "/tmp/project", {:ok, %{result: "Done"}})
    assert {:ok, first} = TaskControl.get(%{"task_id" => "observed", "include_result" => false})
    refute Map.has_key?(first, :result)
    assert is_binary(first.progress.change_token)

    assert {:ok, second} =
             TaskControl.get(%{
               "task_id" => "observed",
               "since" => first.progress.change_token,
               "wait_seconds" => 20
             })

    refute second.changed
    assert second.progress.change_token == first.progress.change_token
    assert {:error, _} = TaskControl.get(%{"task_id" => "observed", "wait_seconds" => 21})
  end

  test "result distinguishes unfinished, failed and completed tasks" do
    seed!("working", :running, "/tmp/project", nil)
    seed!("failed-result", :failed, "/tmp/project", {:error, :offline})

    seed!(
      "finished-result",
      :completed,
      "/tmp/project",
      {:ok, %{result: "Done", commit_sha: "abc"}}
    )

    assert {:error, %{code: "not_ready"}} = TaskControl.result(%{"task_id" => "working"})

    assert {:ok, %{status: "failed", verification: "not_independently_verified"}} =
             TaskControl.result(%{"task_id" => "failed-result"})

    assert {:ok, %{summary: "Done"}} = TaskControl.result(%{"task_id" => "finished-result"})
  end

  test "model discovery returns sanitized configured profiles" do
    assert {:ok, %{models: models}} = TaskControl.models(%{})

    for model <- models do
      assert Map.keys(model) -- [:id, :model, :default] == []
    end

    assert {:error, _} = TaskControl.models(%{"secret" => true})
  end

  test "unfiltered task lookup works across projects and status/search narrow it" do
    seed!("lookup-done", :completed, "/tmp/lookup-a", nil)
    seed!("lookup-running", :running, "/tmp/lookup-b", nil)
    assert {:ok, %{total: 2}} = TaskControl.list(%{})

    assert {:ok, %{total: 1, tasks: [%{id: "lookup-running"}]}} =
             TaskControl.list(%{"status" => "running", "search" => "lookup-running"})
  end

  test "bounded wait returns a changed snapshot when the task finishes" do
    seed!("wait-change", :running, "/tmp/project", nil)
    assert {:ok, first} = TaskControl.get(%{"task_id" => "wait-change"})
    store_name = store()
    task = TaskRegistry.get_task("wait-change")

    writer =
      Task.async(fn ->
        Process.sleep(100)

        EvoGit.Store.put_task(store_name, %{
          task
          | status: :completed,
            finished_at: DateTime.utc_now()
        })
      end)

    assert {:ok, %{status: "completed", changed: true}} =
             TaskControl.get(%{
               "task_id" => "wait-change",
               "since" => first.progress.change_token,
               "wait_seconds" => 2
             })

    assert :ok = Task.await(writer)
  end

  test "threads persistent_state through start options", %{tmp_dir: path} do
    # ONE project dir per start: these runs are cancelled while their evolution
    # is still initializing, so sharing a repo would race git's index lock.
    start = fn name, extra ->
      dir = Path.join(path, name)
      File.mkdir_p!(dir)

      assert {:ok, %{id: id}} =
               TaskControl.start(Map.merge(%{"path" => dir, "objective" => "work"}, extra))

      {id, TaskRegistry.get_task(id).opts}
    end

    {id, opts} = start.("off", %{"persistent_state" => false})
    assert opts[:persistent_state] == false
    refute Map.has_key?(Map.new(opts), "persistent_state")
    TaskRegistry.cancel_task(id)

    {id2, opts2} = start.("on", %{"persistent_state" => true})
    assert opts2[:persistent_state] == true
    TaskRegistry.cancel_task(id2)

    {id3, opts3} = start.("omitted", %{})
    refute Keyword.has_key?(opts3, :persistent_state)
    assert Keyword.get(opts3, :persistent_state, true) == true
    TaskRegistry.cancel_task(id3)
  end

  describe "pause/1" do
    test "accepts a running task and reports its SAVED pause state" do
      id = unique_id("pause-ok")
      seed_pause_row!(id, :running)
      clear_pause_marker!(id)

      assert {:ok, %{task_id: ^id, status: "pausing", pause_kind: nil}} =
               TaskControl.pause(%{"task_id" => id})

      assert TaskRegistry.get_task(id).status == :pausing

      # Idempotent on a `:pausing` row, and a pause is never reported as a
      # cancellation or as a finished task.
      assert {:ok, again} = TaskControl.pause(%{"task_id" => id})
      assert again.status == "pausing"
      refute Map.has_key?(again, :cancel_requested)
    end

    test "reports the :clean pause kind of an already paused row" do
      id = unique_id("pause-paused")
      seed_pause_row!(id, :paused, pause_kind: :clean, lease_expires_at: nil)

      assert {:ok, %{task_id: ^id, status: "paused", pause_kind: "clean"}} =
               TaskControl.pause(%{"task_id" => id})
    end

    test "refuses interactive sessions, non-durable tasks and non-running tasks" do
      interactive = unique_id("pause-interactive")

      seed_pause_row!(interactive, :running,
        session_mode: "interactive",
        opts: [path: "/tmp/project", objective: "hello", session_mode: "interactive"]
      )

      assert {:error, %{code: "not_pausable", message: message}} =
               TaskControl.pause(%{"task_id" => interactive})

      assert message =~ "interactive"

      waiting = unique_id("pause-waiting")
      seed_pause_row!(waiting, :awaiting_input)
      assert {:error, %{code: "not_pausable"}} = TaskControl.pause(%{"task_id" => waiting})

      non_durable = unique_id("pause-non-durable")

      seed_pause_row!(non_durable, :running,
        opts: [path: "/tmp/project", objective: "hello", persistent_state: false]
      )

      assert {:error, %{code: "not_resumable", message: message}} =
               TaskControl.pause(%{"task_id" => non_durable})

      assert message =~ "Durable agent state"

      for status <- [:pending, :completed, :cancelled] do
        id = unique_id("pause-#{status}")
        seed_pause_row!(id, status)
        assert {:error, %{code: "not_running"}} = TaskControl.pause(%{"task_id" => id})
      end

      # Every refusal left its row exactly as it was.
      assert TaskRegistry.get_task(interactive).status == :running
      assert TaskRegistry.get_task(non_durable).status == :running
      assert TaskRegistry.get_task(waiting).status == :awaiting_input
    end

    test "an unknown task is not_found and a malformed request is refused" do
      assert {:error, %{code: "not_found"}} =
               TaskControl.pause(%{"task_id" => unique_id("pause-missing")})

      assert {:error, %{code: "invalid_arguments"}} = TaskControl.pause(%{"task_id" => ""})

      assert {:error, %{code: "invalid_arguments"}} =
               TaskControl.pause(%{"task_id" => "x", "f" => 1})
    end
  end

  describe "resume/1" do
    test "resumes a paused task in place and reports the running state" do
      id = unique_id("resume-ok")
      seed_pause_row!(id, :paused, pause_kind: :clean, lease_expires_at: nil)
      seed_durable_run!(id)
      start_registry_with_spawn_seam!(self())

      assert {:ok, %{task_id: ^id, status: "running", pause_kind: nil}} =
               TaskControl.resume(%{"task_id" => id})

      kill_wrapper_on_exit!(id)

      assert_receive {:wrapper_spawned, :evolve, spawn_opts, ^id, _server}, 1_000
      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause

      task = TaskRegistry.get_task(id)
      assert task.status == :running
      assert task.pause_kind == nil
      assert task.finished_at == nil
    end

    test "refuses a task that is not paused" do
      id = unique_id("resume-not-paused")
      seed_pause_row!(id, :running)

      assert {:error, %{code: "not_paused", message: message}} =
               TaskControl.resume(%{"task_id" => id})

      assert message =~ "not paused"
      assert TaskRegistry.get_task(id).status == :running
    end

    test "a paused task with no durable run is not_resumable" do
      id = unique_id("resume-no-state")
      seed_pause_row!(id, :paused, pause_kind: :clean, lease_expires_at: nil)
      start_registry_with_spawn_seam!(self())

      assert {:error, %{code: "not_resumable"}} = TaskControl.resume(%{"task_id" => id})
      assert TaskRegistry.get_task(id).status == :paused
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "an admission failure is reported as resume_failed" do
      id = unique_id("resume-bad-opts")

      seed_pause_row!(id, :paused,
        pause_kind: :clean,
        lease_expires_at: nil,
        opts: [path: "/tmp/project", objective: "hello", persistent_state: "yes"]
      )

      seed_durable_run!(id)
      start_registry_with_spawn_seam!(self())

      assert {:error, %{code: "resume_failed", message: message}} =
               TaskControl.resume(%{"task_id" => id})

      assert message =~ "invalid_persistent_state"
      assert TaskRegistry.get_task(id).status == :paused
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "an unknown task is not_found and a malformed request is refused" do
      assert {:error, %{code: "not_found"}} =
               TaskControl.resume(%{"task_id" => unique_id("resume-missing")})

      assert {:error, %{code: "invalid_arguments"}} = TaskControl.resume(%{"task_id" => ""})
      assert {:error, %{code: "invalid_arguments"}} = TaskControl.resume(%{})
    end
  end

  defp seed!(id, status, path, result) do
    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :evolve,
        status: status,
        project_path: path,
        opts: [path: path, objective: "hello", internal_secret: "not for callers"],
        started_at: DateTime.utc_now(),
        result: result
      })
  end

  ## Pause/resume helpers — the same isolated-store shapes as the cancellation
  ## tests, plus the durable run a resume restores and the registry's wrapper
  ## spawn seam (so no real runtime is started).

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp seed_pause_row!(id, status, extra \\ []) do
    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: id,
        type: :evolve,
        status: status,
        project_path: "/tmp/project",
        opts: Keyword.get(extra, :opts, path: "/tmp/project", objective: "hello"),
        started_at: DateTime.utc_now(),
        session_mode: Keyword.get(extra, :session_mode, "oneshot"),
        pause_kind: Keyword.get(extra, :pause_kind),
        lease_expires_at: Keyword.get(extra, :lease_expires_at, System.system_time(:second) + 300)
      })
  end

  # ONE durable root run through the app-booted agent-state server (the server
  # the registry resolves), so `EvoGit.AgentState.roster/1` holds a ROOT row.
  defp seed_durable_run!(task_id, agent_id \\ 1) do
    on_exit(fn -> EvoGit.AgentState.delete_task(task_id) end)

    :ok =
      EvoGit.AgentState.checkpoint(task_id, agent_id, %{
        kind: :rewrite,
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [ReqLLM.Message.ContentPart.text("paused run #{task_id}")]
          }
        ],
        fields: %{phase: "paused"}
      })

    :ok = EvoGit.AgentState.flush()
    assert {:ok, _record} = EvoGit.AgentState.load(task_id, agent_id)
    :ok
  end

  # A pause flags the task in the APP-GLOBAL scheduler, so the marker is cleared
  # for this test's own (unique) task id.
  defp clear_pause_marker!(task_id) do
    on_exit(fn -> EvoGit.AgentScheduler.clear_task_pause(task_id) end)
    :ok
  end

  # Starts a SECOND isolated registry over this test's store whose wrapper spawn
  # is the `:wrapper_spawn_fun` seam: it reports the spawn and returns a fake
  # (alive) `%Task{}` instead of running a real runtime.
  defp start_registry_with_spawn_seam!(test_pid) do
    unique = System.unique_integer([:positive])
    name = :"evogit_test_task_control_registry_#{unique}"

    spawn_fun = fn task_type, spawn_opts, task_id, server ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:wrapper_spawned, task_type, spawn_opts, task_id, server})

      %Task{
        pid: pid,
        ref: make_ref(),
        owner: test_pid,
        mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [task_type, spawn_opts, task_id]}
      }
    end

    start_supervised!(
      Supervisor.child_spec(
        {TaskRegistry,
         task_store: store(),
         data_dir: System.tmp_dir!(),
         name: name,
         wrapper_spawn_fun: spawn_fun},
        id: name
      )
    )

    Process.put(:evogit_task_registry_server, name)
    name
  end

  # The seam's fake wrapper pid is not linked, so the test kills it itself.
  defp kill_wrapper_on_exit!(task_id) do
    pid = :sys.get_state(TaskRegistry.server()).task_refs[task_id].pid
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    :ok
  end
end

defmodule EvoGit.TaskControlArgumentTest do
  # Pre-submission validation only: every case is rejected before
  # `TaskRegistry.start_task/2`, so no shared store/registry state is touched.
  use ExUnit.Case, async: true

  alias EvoGit.TaskControl
  @moduletag :tmp_dir

  test "rejects a non-boolean persistent_state before submission", %{tmp_dir: path} do
    for value <- ["yes", 1, 0, nil, [], %{}] do
      assert {:error, %{code: "invalid_arguments", message: message}} =
               TaskControl.start(%{
                 "path" => path,
                 "objective" => "work",
                 "persistent_state" => value
               })

      assert message =~ "persistent_state"
    end
  end
end
