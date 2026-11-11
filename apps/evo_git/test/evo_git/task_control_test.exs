defmodule EvoGit.TaskControlTest do
  use EvoGit.TaskRegistryCase, async: true

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

  test "cancellation distinguishes an accepted request from stopped work" do
    seed!("pending-stop", :pending, "/tmp/project", nil)
    assert {:ok, data} = TaskControl.cancel(%{"task_id" => "pending-stop", "wait_seconds" => 1})
    assert data.status == "cancelled"
    assert data.stop_requested
    assert data.stopped in [true, nil]

    assert {:error, %{code: "invalid_arguments"}} =
             TaskControl.cancel(%{"task_id" => "pending-stop", "force" => "yes"})
  end

  test "a reconnect can confirm cleanup after a previous cancellation finished" do
    seed!("reconnected-stop", :pending, "/tmp/project", nil)
    assert {:ok, _} = TaskControl.cancel(%{"task_id" => "reconnected-stop"})

    for force <- [false, true] do
      assert {:ok, data} =
               TaskControl.cancel(%{"task_id" => "reconnected-stop", "force" => force})

      assert data.status == "cancelled"
      assert data.stopped
      assert data.remaining_agents == 0
      assert data.pending_cleanup == 0
      assert data.active_jobs == 0
    end
  end

  test "retained foreign work stays discoverable after the task and project configuration change",
       %{tmp_dir: root} do
    primary = Path.join(root, "primary")
    foreign = Path.join(root, "foreign")
    File.mkdir_p!(primary)
    File.mkdir_p!(foreign)

    for repo <- [primary, foreign] do
      {_, 0} = System.cmd("git", ["init", "-q", repo])

      {_, 0} =
        System.cmd("git", [
          "-C",
          repo,
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.com",
          "commit",
          "-q",
          "--allow-empty",
          "-m",
          "Initial fixture"
        ])
    end

    seed!("foreign-recovery", :cancelled, primary, nil)

    File.write!(
      Path.join(primary, "genesis.toml"),
      "[foreign_repos.other]\npath = #{Jason.encode!(foreign)}\nwritable = true\n"
    )

    repos = EvoGit.Runtime.Helpers.load_foreign_repos(primary, task_id: "foreign-recovery")
    assert [%{root: ^foreign}] = repos

    worker = Path.join(foreign, ".genesis/workers/worker_T1_A1")
    branch = "evogit-agent-T1-A1"
    {:ok, _} = EvoGit.Adapters.Git.add_worktree(foreign, worker, "HEAD", branch)
    File.write!(Path.join(worker, "unfinished.txt"), "Preserve foreign work")

    :ok =
      EvoGit.AgentScheduler.WorktreeRetention.record(foreign, worker, branch, %{
        task_id: "foreign-recovery",
        agent_id: 123
      })

    :ok =
      EvoGit.AgentScheduler.WorktreeRetention.retain(
        foreign,
        worker,
        branch,
        "uncommitted_changes"
      )

    # The task has no live scheduler entry and the project no longer names this repo.
    File.write!(Path.join(primary, "genesis.toml"), "")
    EvoGit.Runtime.Helpers.load_foreign_repos(primary, task_id: "foreign-recovery")

    assert {:ok, data} = TaskControl.get(%{"task_id" => "foreign-recovery"})
    assert [%{"path" => ^worker, "repo_root" => ^foreign}] = data.recoverable_work
    assert {:ok, result} = TaskControl.result(%{"task_id" => "foreign-recovery"})
    assert result.recoverable_work == data.recoverable_work
    assert {:ok, stopped} = TaskControl.cancel(%{"task_id" => "foreign-recovery"})
    assert stopped.recoverable_work == data.recoverable_work
    assert {:ok, check} = TaskControl.check(%{"path" => primary})
    assert check.recoverable_work == data.recoverable_work
    assert File.read!(Path.join(worker, "unfinished.txt")) == "Preserve foreign work"
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
end
