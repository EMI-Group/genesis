defmodule EvoGit.CommandApprovalTest do
  @moduledoc """
  Tests for `EvoGit.CommandApproval` — the human-in-the-loop approval gate for
  the self-reflective agent's command shell — and for the shell-level security
  gating of level-2/3 commands (`EvoGit.CommandShell` + `EvoGit.CommandApproval`).

  The pure approval-service tests (request/respond/timeout/task-lifecycle
  broadcasts) exercise the supervised GenServer directly through spawned caller
  processes (the caller BLOCKS inside `CommandApproval.request/5`, so it can
  never run in the test process itself). The shell-gating tests run real
  level-2/3 commands through `CommandShell.execute/1` while a separate
  responder process approves or denies the request.

  `EvoGit.TaskRegistryCase` provides the isolated TaskRegistry/Store the
  shell-gating tests need (cancel a seeded task); `EvoGit.CommandApproval` and
  `EvoGit.PubSub` are app-booted supervision children that stay running.

  The `setup` below shrinks the approval window (app env
  `[:evo_git, :command_approval_timeout]`, default 120_000 ms) so any request
  that is never resolved times out in seconds instead of minutes.
  """

  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.CommandApproval
  alias EvoGit.CommandShell

  setup do
    Application.put_env(:evo_git, :command_approval_timeout, 5_000)
    on_exit(fn -> Application.delete_env(:evo_git, :command_approval_timeout) end)
    :ok
  end

  describe "shell-level gating" do
    test "L3 CancelTask with an approving responder executes the handler" do
      task = seed_task!()

      assert {:ok, output} = execute_approved!("CancelTask.cancel_task #{task.id}")
      assert output == "Task #{task.id} cancellation requested (graceful)."
      assert TaskRegistry.get_task(task.id).status == :cancelled
    end

    test "L2 GuideUser with an approving responder executes the handler and guides" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "guides")

      assert {:ok, output} = execute_approved!("GuideUser.guide_user hello")
      assert output == "Guide shown to user: hello"

      assert_receive {:guide_updated, _guide_id, guide_map, node}
      assert guide_map.message == "hello"
      assert node == node()
    end

    test "a denied L3 command fails closed and the handler never runs" do
      task = seed_task!()
      responder = start_approval_responder(:deny)

      try do
        assert {:error, message} = CommandShell.execute("CancelTask.cancel_task #{task.id}")
        assert message =~ "Action denied by the user"
      after
        Process.exit(responder, :kill)
      end

      # The handler never ran — the task is still pending, not cancelled.
      assert TaskRegistry.get_task(task.id).status == :pending
    end

    test "an unresponded L3 command times out and the handler never runs" do
      # Per-request window is read at request time, so shrinking it before
      # execute makes this test fail fast instead of waiting the 5s setup window.
      Application.put_env(:evo_git, :command_approval_timeout, 100)
      on_exit(fn -> Application.delete_env(:evo_git, :command_approval_timeout) end)

      task = seed_task!()

      assert {:error, message} = CommandShell.execute("CancelTask.cancel_task #{task.id}")
      assert message =~ "did not confirm"
      assert message =~ "in time"

      # Handler never ran.
      assert TaskRegistry.get_task(task.id).status == :pending
    end

    test "level-1 commands never open an approval request" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      assert {:ok, _output} = CommandShell.execute("ListTasks.list_tasks")
      assert {:ok, _output} = CommandShell.execute("SystemInfo.system_info")

      refute_receive {:approval_requested, _}, 200
    end
  end

  describe "request/respond" do
    test "respond/2 resolves a pending request once and is idempotent afterwards" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("StartTask.start_task", "(no arguments)", 3, nil, nil)

      assert_receive {:approval_requested, request}
      request_id = request.request_id
      assert String.starts_with?(request_id, "aprv-")

      assert CommandApproval.respond(request_id, :approve) == :ok
      # Second response to the same id is a no-op.
      assert CommandApproval.respond(request_id, :deny) == {:error, :not_found}

      assert_receive {:approval_resolved, ^request_id, :approve}
      assert_receive {:call_result, :approved}
    end

    test "respond/2 to an unknown id returns {:error, :not_found}" do
      assert CommandApproval.respond("aprv-does-not-exist", :approve) ==
               {:error, :not_found}

      assert CommandApproval.respond("aprv-does-not-exist", :deny) ==
               {:error, :not_found}
    end

    test "request/5 returns :timeout when the approval service is not running" do
      approval = Process.whereis(EvoGit.CommandApproval)
      assert is_pid(approval)

      Process.unregister(EvoGit.CommandApproval)

      try do
        assert CommandApproval.request("StartTask.start_task", "(no arguments)", 3, nil, nil) ==
                 :timeout
      after
        assert Process.register(approval, EvoGit.CommandApproval) == true
      end

      assert Process.whereis(EvoGit.CommandApproval) == approval
    end
  end

  describe "timeout resolution" do
    test "an unresponded request times out and broadcasts :timed_out" do
      Application.put_env(:evo_git, :command_approval_timeout, 100)
      on_exit(fn -> Application.delete_env(:evo_git, :command_approval_timeout) end)

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("CancelTask.cancel_task", "task_id=\"T1\"", 3, nil, "T123")

      assert_receive {:approval_requested, request}
      request_id = request.request_id

      # The window is 100ms from request registration; give the assertions
      # generous headroom over the default 100ms receive timeout.
      assert_receive {:call_result, :timeout}, 2_000
      assert_receive {:approval_resolved, ^request_id, :timed_out}, 2_000
    end
  end

  describe "task-lifecycle auto-resolution" do
    test ":cancelling and terminal task updates auto-deny the task's pending approvals" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("StartTask.start_task", "(no arguments)", 3, nil, "T123")

      assert_receive {:approval_requested, request}
      request_id = request.request_id
      assert request.task_id == "T123"

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "T123", :cancelling, node()}
      )

      assert_receive {:call_result, :denied}
      assert_receive {:approval_resolved, ^request_id, :deny}
    end

    test "non-denying task statuses leave the request pending" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("StartTask.start_task", "(no arguments)", 3, nil, "T123")

      assert_receive {:approval_requested, request}
      request_id = request.request_id

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "T123", :running, node()}
      )

      # Still waiting: no resolved broadcast, caller still blocked.
      refute_receive {:approval_resolved, ^request_id, _}, 200
      refute_receive {:call_result, _}, 100

      # Cleanup: resolve the request ourselves so nothing leaks.
      assert CommandApproval.respond(request_id, :approve) == :ok
      assert_receive {:call_result, :approved}
      assert_receive {:approval_resolved, ^request_id, :approve}
    end

    test "task updates from other nodes never auto-resolve local approvals" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("StartTask.start_task", "(no arguments)", 3, nil, "T123")

      assert_receive {:approval_requested, request}
      request_id = request.request_id

      # A foreign node's task update carries the same task_id but a different
      # node element — it must NOT resolve the local request.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "T123", :cancelled, :some_other_node@host}
      )

      refute_receive {:approval_resolved, ^request_id, _}, 200
      refute_receive {:call_result, _}, 100

      assert CommandApproval.respond(request_id, :approve) == :ok
      assert_receive {:call_result, :approved}
      assert_receive {:approval_resolved, ^request_id, :approve}
    end
  end

  describe "request-map broadcast shape" do
    test "the approval_requested payload carries the documented keys and values" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("GuideUser.guide_user", "message=\"m\"", 2, "agent-7", "task-9")

      assert_receive {:approval_requested, request}
      assert request.request_id =~ "aprv-"
      assert request.command == "GuideUser.guide_user"
      assert is_binary(request.args)
      assert request.level == 2
      assert request.agent_id == "agent-7"
      assert request.task_id == "task-9"
      assert request.node == node()

      assert Map.keys(request) |> Enum.sort() ==
               [:agent_id, :args, :command, :level, :node, :request_id, :task_id]

      assert CommandApproval.respond(request.request_id, :approve) == :ok
      assert_receive {:call_result, :approved}
    end

    test "integer agent/task ids are normalized to strings at the boundary" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")

      spawn_request_caller("StartTask.start_task", "(no arguments)", 3, 42, 7)

      assert_receive {:approval_requested, request}
      assert request.agent_id == "42"
      assert request.task_id == "7"

      assert CommandApproval.respond(request.request_id, :deny) == :ok
      assert_receive {:call_result, :denied}
    end
  end

  # --- Helpers -------------------------------------------------------------

  # Runs CommandShell.execute/1 while a background responder approves every
  # approval request. The shell call blocks the TEST process, so the responder
  # must be a SEPARATE process subscribed to "approvals".
  defp execute_approved!(command) do
    responder = start_approval_responder(:approve)

    try do
      CommandShell.execute(command)
    after
      Process.exit(responder, :kill)
    end
  end

  # Spawns a responder that subscribes to "approvals" and replies `decision` to
  # every request it observes. Signals readiness with a handshake message so the
  # caller never races the subscription. Returns the responder pid.
  defp start_approval_responder(decision) do
    parent = self()

    pid =
      spawn(fn ->
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")
        send(parent, {:approval_responder_ready, self()})
        approval_responder_loop(decision)
      end)

    receive do
      {:approval_responder_ready, ^pid} -> :ok
    after
      2_000 -> flunk("approval responder failed to subscribe in time")
    end

    pid
  end

  defp approval_responder_loop(decision) do
    receive do
      {:approval_requested, %{request_id: request_id}} ->
        EvoGit.CommandApproval.respond(request_id, decision)
        approval_responder_loop(decision)

      _other ->
        approval_responder_loop(decision)
    end
  end

  # Spawns a process that BLOCKS in CommandApproval.request/5 and reports the
  # outcome to the test process (which cannot block on request/5 itself).
  defp spawn_request_caller(command, args, level, agent_id, task_id) do
    parent = self()

    spawn(fn ->
      result = EvoGit.CommandApproval.request(command, args, level, agent_id, task_id)
      send(parent, {:call_result, result})
    end)
  end

  # Seeds a task row directly into the isolated Store (bypassing the registry).
  defp seed_task!(attrs \\ []) do
    task =
      struct(
        TaskInfo,
        Keyword.merge(
          [
            id: "approval_task_#{System.unique_integer([:positive])}",
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
end
