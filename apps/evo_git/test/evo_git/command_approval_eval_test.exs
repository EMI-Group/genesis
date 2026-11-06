defmodule EvoGit.CommandApproval.EvalTest do
  @moduledoc """
  Exact-code approval registration and resolution, without running evaluated code.

  Each test owns an isolated TaskRegistry/Store, explicitly selected inside every
  monitored caller: raw spawn does not inherit the registry process dictionary.
  These tests do not claim to exercise Dune or the evaluator's authorization and
  post-approval lifecycle revalidation.
  """

  # async: false is forced by the app-booted EvoGit.CommandApproval singleton,
  # its shared "approvals" subscription/pending roster, temporarily unregistering
  # its name, and the BEAM-global :command_approval_timeout app-env key (both a
  # generous safety window and a zero-window real timer test).
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.CommandApproval

  @receive_timeout 5_000
  @denying_statuses [:cancelling, :completed, :failed, :cancelled]
  @public_keys Enum.sort([
                 :agent_id,
                 :args,
                 :code,
                 :command,
                 :kind,
                 :level,
                 :node,
                 :request_id,
                 :target_node,
                 :task_id,
                 :tier,
                 :warning
               ])
  @sudo_warning "Unrestricted live-BEAM privileges: this code can access the OS, files, " <>
                  "network and processes with the Genesis server's permissions. " <>
                  "This is not OS root elevation. Side effects have no rollback."

  setup context do
    previous = Application.fetch_env(:evo_git, :command_approval_timeout)
    Application.put_env(:evo_git, :command_approval_timeout, context[:approval_timeout] || 30_000)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:evo_git, :command_approval_timeout, value)
        :error -> Application.delete_env(:evo_git, :command_approval_timeout)
      end
    end)

    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())
    :ok
  end

  describe "exact-code public metadata" do
    for tier <- [:write, :sudo] do
      test "#{tier} retains every code byte and exposes only public pending metadata" do
        tier = unquote(tier)
        task = seed_task!(:running)
        # Leading/trailing whitespace, CRLF, quotes and Unicode must survive.
        # Approval must NOT execute even code that would immediately raise.
        code = " \t# 原样审核\r\nraise \"approval is not execution\"\n\n  "
        caller = start_caller(code, tier, task.id, 42)
        request = requested!(task.id, tier)
        request_id = request.request_id

        assert Map.keys(request) |> Enum.sort() == @public_keys
        assert String.starts_with?(request_id, "aprv-")
        assert request.kind == :elixir_eval
        assert request.tier == tier
        assert request.code === code
        assert request.args === code
        assert request.agent_id == "42"
        assert request.task_id == task.id
        assert request.target_node == node()
        assert request.node == node()

        assert_tier_metadata(request, tier)

        assert request in CommandApproval.pending()
        assert CommandApproval.respond(request_id, :approve) == :ok
        result!(caller, :approved)
        assert_receive {:approval_resolved, ^request_id, :approve}, @receive_timeout
        closed!(request_id)
      end
    end

    test "the maximum byte-sized code is not truncated or normalized" do
      code = String.duplicate("界", 5_461) <> "\n"
      assert byte_size(code) == 16_384
      caller = start_caller(code, :write, nil)
      request = requested!(nil, :write)
      request_id = request.request_id
      assert request.code === code
      assert request.args === code
      assert request in CommandApproval.pending()

      assert CommandApproval.respond(request_id, :deny) == :ok
      result!(caller, :denied)
      assert_receive {:approval_resolved, ^request_id, :deny}, @receive_timeout
      closed!(request_id)
    end

    test "integer task identity is normalized before the isolated active-task lookup" do
      task = seed_task!(:running, Integer.to_string(System.unique_integer([:positive])))
      caller = start_caller("1 + 1", :sudo, String.to_integer(task.id))
      request = requested!(task.id, :sudo)
      request_id = request.request_id

      assert CommandApproval.respond(request_id, :deny) == :ok
      result!(caller, :denied)
      assert_receive {:approval_resolved, ^request_id, :deny}, @receive_timeout
      closed!(request_id)
    end
  end

  describe "validation and active-task precheck" do
    test "invalid code, tier and node shapes fail closed without opening a request" do
      for {code, tier, target_node} <- [
            {"", :write, node()},
            {String.duplicate("x", 16_385), :write, node()},
            {String.duplicate("界", 5_462), :sudo, node()},
            {nil, :write, node()},
            {~c"1 + 1", :write, node()},
            {"1 + 1", :read, node()},
            {"1 + 1", "sudo", node()},
            {"1 + 1", :write, Atom.to_string(node())}
          ] do
        assert CommandApproval.request_eval(code, tier, target_node, nil, nil) == :denied
      end

      refute_received {:approval_requested, %{kind: :elixir_eval}}
    end

    for status <- [:pending, :running, :finalizing] do
      test "#{status} tasks in the explicitly selected registry may request approval" do
        task = seed_task!(unquote(status))
        caller = start_caller("1 + 1", :write, task.id)
        request = requested!(task.id, :write)
        request_id = request.request_id

        assert CommandApproval.respond(request_id, :deny) == :ok
        result!(caller, :denied)
        assert_receive {:approval_resolved, ^request_id, :deny}, @receive_timeout
        closed!(request_id)
      end
    end

    for status <- @denying_statuses do
      test "already #{status} tasks are denied before registration" do
        task = seed_task!(unquote(status))
        caller = start_caller("1 + 1", :sudo, task.id)
        result!(caller, :denied)
        task_id = task.id
        refute_received {:approval_requested, %{task_id: ^task_id}}
      end
    end

    test "missing tasks and an unavailable registry fail closed before registration" do
      missing_id = "missing_eval_#{System.unique_integer([:positive])}"
      caller = start_caller("1 + 1", :write, missing_id)
      result!(caller, :denied)
      refute_received {:approval_requested, %{task_id: ^missing_id}}

      task = seed_task!(:running)
      caller = start_caller("1 + 1", :sudo, task.id, nil, :absent_eval_test_registry)
      result!(caller, :denied)
      task_id = task.id
      refute_received {:approval_requested, %{task_id: ^task_id}}
    end
  end

  describe "resolution and caller monitoring" do
    test "explicit denial is final and a late approval cannot reopen the request" do
      caller = start_caller("raise \"must not execute\"", :write, nil)
      request = requested!(nil, :write)
      request_id = request.request_id

      assert CommandApproval.respond(request_id, :deny) == :ok
      result!(caller, :denied)
      assert_receive {:approval_resolved, ^request_id, :deny}, @receive_timeout
      closed!(request_id)
    end

    @tag approval_timeout: 0
    test "the real deadline timer returns timeout and publishes timed_out" do
      caller = start_caller("1 + 1", :sudo, nil)
      request = requested!(nil, :sudo)
      request_id = request.request_id

      result!(caller, :timeout)
      assert_receive {:approval_resolved, ^request_id, :timed_out}, @receive_timeout
      closed!(request_id)
    end

    test "caller death removes only its request and publishes timed_out exactly once" do
      {pid, monitor} = start_caller("1 + 1", :write, nil)
      request = requested!(nil, :write)
      request_id = request.request_id
      survivor = start_caller("2 + 2", :sudo, nil)
      surviving_request = requested!(nil, :sudo)
      surviving_id = surviving_request.request_id

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @receive_timeout
      assert_receive {:approval_resolved, ^request_id, :timed_out}, @receive_timeout
      closed!(request_id)
      refute_received {:eval_result, ^pid, _}
      assert surviving_request in CommandApproval.pending()
      refute_received {:approval_resolved, ^surviving_id, _}

      assert CommandApproval.respond(surviving_id, :approve) == :ok
      result!(survivor, :approved)
      assert_receive {:approval_resolved, ^surviving_id, :approve}, @receive_timeout
      closed!(surviving_id)
    end

    test "an unavailable approval service fails closed and exposes no pending metadata" do
      approval = Process.whereis(CommandApproval)
      assert is_pid(approval)
      Process.unregister(CommandApproval)

      try do
        assert CommandApproval.request_eval("1 + 1", :sudo, node(), nil, nil) == :timeout
        assert CommandApproval.pending() == []
        assert CommandApproval.respond("aprv-missing", :approve) == {:error, :not_found}
      after
        assert Process.register(approval, CommandApproval)
      end
    end
  end

  describe "task lifecycle" do
    for status <- @denying_statuses do
      test "local #{status} denies both tiers but leaves another task's request pending" do
        task = seed_task!(:running)
        other_task = seed_task!(:running)
        write = start_caller("1 + 1", :write, task.id)
        write_request = requested!(task.id, :write)
        sudo = start_caller("2 + 2", :sudo, task.id)
        sudo_request = requested!(task.id, :sudo)
        other = start_caller("3 + 3", :write, other_task.id)
        other_request = requested!(other_task.id, :write)
        other_id = other_request.request_id

        broadcast_task!(task.id, unquote(status), node())

        for {caller, request} <- [{write, write_request}, {sudo, sudo_request}] do
          result!(caller, :denied)
          request_id = request.request_id
          assert_receive {:approval_resolved, ^request_id, :deny}, @receive_timeout
          closed!(request_id)
        end

        assert other_request in CommandApproval.pending()
        refute_received {:approval_resolved, ^other_id, _}
        assert CommandApproval.respond(other_id, :approve) == :ok
        result!(other, :approved)
        assert_receive {:approval_resolved, ^other_id, :approve}, @receive_timeout
        closed!(other_id)
      end
    end

    test "all foreign denying updates and local non-denying updates leave approval pending" do
      task = seed_task!(:running)
      {pid, _monitor} = caller = start_caller("1 + 1", :sudo, task.id)
      request = requested!(task.id, :sudo)
      request_id = request.request_id

      for status <- @denying_statuses do
        broadcast_task!(task.id, status, :approval_remote@host)
        assert request in CommandApproval.pending()
        refute_received {:approval_resolved, ^request_id, _}
        refute_received {:eval_result, ^pid, _}
      end

      for status <- [:pending, :running, :finalizing, nil] do
        broadcast_task!(task.id, status, node())
        assert request in CommandApproval.pending()
        refute_received {:approval_resolved, ^request_id, _}
        refute_received {:eval_result, ^pid, _}
      end

      assert CommandApproval.respond(request_id, :approve) == :ok
      result!(caller, :approved)
      assert_receive {:approval_resolved, ^request_id, :approve}, @receive_timeout
      closed!(request_id)
    end
  end

  defp assert_tier_metadata(request, tier) do
    case tier do
      :write ->
        assert request.command == "elixir_eval"
        assert request.level == 2
        assert request.warning == nil

      :sudo ->
        assert request.command == "elixir_eval sudo"
        assert request.level == 3
        assert request.warning == @sudo_warning
    end
  end

  defp seed_task!(status, id \\ nil) do
    task = %TaskInfo{
      id: id || "eval_approval_#{System.unique_integer([:positive])}",
      type: :reflect,
      status: status,
      opts: [objective: "Approval test; no evaluator runs"],
      started_at: DateTime.utc_now()
    }

    assert :ok = EvoGit.Store.put_task(store(), task)
    task
  end

  defp start_caller(code, tier, task_id, agent_id \\ nil, registry \\ TaskRegistry.server()) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :start -> :ok
        end

        Process.put(:evogit_task_registry_server, registry)
        result = CommandApproval.request_eval(code, tier, node(), agent_id, task_id)
        send(parent, {:eval_result, self(), result})

        # Keep the caller alive until the assertion consumes its result, so
        # request resolution is never confused with caller-death cleanup.
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    send(pid, :start)
    {pid, monitor}
  end

  defp requested!(task_id, tier) do
    assert_receive {:approval_requested,
                    %{kind: :elixir_eval, task_id: ^task_id, tier: ^tier} = request},
                   @receive_timeout

    request
  end

  defp result!({pid, monitor}, result) do
    assert_receive {:eval_result, ^pid, ^result}, @receive_timeout
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @receive_timeout
  end

  defp broadcast_task!(task_id, status, emitting_node) do
    assert :ok =
             Phoenix.PubSub.broadcast(
               EvoGit.PubSub,
               "tasks",
               {:task_updated, task_id, status, emitting_node}
             )

    # Local PubSub delivers before broadcast returns; this same-sender call
    # drains the approval server after its task update, without a quiet sleep.
    _ = CommandApproval.pending()
  end

  defp closed!(request_id) do
    refute Enum.any?(CommandApproval.pending(), &(&1.request_id == request_id))
    assert CommandApproval.respond(request_id, :approve) == {:error, :not_found}
    assert CommandApproval.respond(request_id, :deny) == {:error, :not_found}

    # A timer already queued during resolution must not publish a second
    # outcome. The synchronous roster read is a same-sender processing barrier.
    send(Process.whereis(CommandApproval), {:approval_timeout, request_id})
    _ = CommandApproval.pending()
    refute_received {:approval_resolved, ^request_id, _}
  end
end
