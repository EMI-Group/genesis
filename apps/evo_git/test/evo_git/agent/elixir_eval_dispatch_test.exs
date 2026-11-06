defmodule EvoGit.Agent.ElixirEvalDispatchTest do
  @moduledoc """
  Real ToolDispatch -> tool Task -> authorization -> approval -> evaluator tests.

  Serialized because CommandApproval is an app-global singleton, its approval
  timeout is app-env, and these tests subscribe to its shared PubSub topic.
  Scheduler rows and persisted tasks have unique ids and are individually removed.
  No scheduler configuration, tool registry or evaluator implementation is replaced.

  TaskRegistryCase supplies an isolated registry for the negative seam regression.
  Positive cases seed the GLOBAL store deliberately: fresh dispatch tool tasks do
  not inherit :evogit_task_registry_server, so an isolated-only owner is refused.
  Seeding a matching global task is not a substitute for testing that seam; the
  separate regression below records its current fail-closed behavior explicitly.
  """

  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.{CommandApproval, Store}

  @deadline 10_000
  @denied "requires a live root reflective assistant"

  setup %{data_dir: root} do
    previous = Application.fetch_env(:evo_git, :command_approval_timeout)
    Application.put_env(:evo_git, :command_approval_timeout, @deadline)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "guides")

    task_id = unique_task_id()
    task = %TaskInfo{id: task_id, type: :reflect, status: :running, opts: []}
    :ok = Store.put_task(Store, task)

    on_exit(fn ->
      :ok = Store.delete_task(Store, task_id)

      case previous do
        {:ok, value} -> Application.put_env(:evo_git, :command_approval_timeout, value)
        :error -> Application.delete_env(:evo_git, :command_approval_timeout)
      end
    end)

    %{owner_task: task, repo_root: root}
  end

  test "fresh tool tasks receive the actual batch owner, not stale dictionary identities", ctx do
    code = "  6 * 7\n"
    owner = start_batch(ctx, [eval(code, "sudo", %{"timeout" => "1ms"})])
    request = approval!(ctx, code, :sudo)
    assert request.level == 3
    assert request.command == "elixir_eval sudo"
    assert request.args == code
    assert request.target_node == node()
    assert request.warning =~ "Unrestricted live-BEAM privileges"
    assert request.warning =~ "no rollback"

    assert request.agent_id == Integer.to_string(owner.agent_id)
    tool_pid = assert_tool_identity(request, owner, ctx)

    assert :ok = CommandApproval.respond(request.request_id, :approve)
    assert [{0, _, "elixir_eval", "Result: 42"}] = finish(owner)
    refute Process.alive?(tool_pid)
    refute Enum.any?(CommandApproval.pending(), &(&1.request_id == request.request_id))
  end

  test "read facade reaches the live reflect task through the real evaluator without approval",
       ctx do
    code = "EvoGit.Agent.Tools.ElixirEval.Read.get_task(#{inspect(ctx.owner_task.id)})"
    owner = start_batch(ctx, [eval(code)])
    assert [{0, _, "elixir_eval", output}] = finish(owner)
    assert output =~ "Result:"
    assert output =~ ctx.owner_task.id
    assert output =~ ":running"
    refute output =~ "Error:"
    refute_owner_approvals(ctx)
  end

  test "isolated-only reflect owners fail closed because tool tasks lose the registry seam",
       ctx do
    :ok = Store.delete_task(Store, ctx.owner_task.id)
    :ok = Store.put_task(ctx.store, ctx.owner_task)
    assert %{status: :running} = TaskRegistry.get_task_lite(ctx.owner_task.id)
    assert nil == global_task(ctx.owner_task.id)
    owner = start_batch(ctx, [eval("42")])
    assert [{0, _, "elixir_eval", output}] = finish(owner)
    assert output =~ @denied
    refute_owner_approvals(ctx)
  end

  test "authorization checks actual caller PID, root built-in spec and live task state", ctx do
    changes = [
      fn %SchedMeta{task_ref: %Task{} = task} = meta ->
        %{meta | task_ref: %{task | pid: self()}}
      end,
      fn meta -> %{meta | depth: 1, parent_id: 123} end,
      fn meta -> %{meta | status: :waiting} end,
      fn meta -> %{meta | result_sent: true} end,
      fn meta -> %{meta | spec: %{meta.spec | agent_module: EvoGit.Agents.Custom}} end,
      fn meta ->
        %{meta | spec: %{meta.spec | opts: [repo_less: false, task_id: meta.task_id]}}
      end
    ]

    for change <- changes do
      owner = start_batch(ctx, [eval("42", "sudo")], meta: change)
      assert [{0, _, "elixir_eval", output}] = finish(owner)
      assert output =~ @denied
    end

    for task <- [
          %{ctx.owner_task | type: :evolve},
          %{ctx.owner_task | status: :completed}
        ] do
      :ok = Store.put_task(Store, task)
      owner = start_batch(ctx, [eval("42", "write")])
      assert [{0, _, "elixir_eval", output}] = finish(owner)
      assert output =~ @denied
    end

    refute_owner_approvals(ctx)
  end

  test "all evaluator tiers serialize approval/effects before earlier-indexed parallel reads",
       ctx do
    target = seed_target(:pending)
    path = Path.join(ctx.repo_root, "after-sudo.txt")
    write = "EvoGit.Agent.Tools.ElixirEval.Write.cancel_task(#{inspect(target)})"
    read = "EvoGit.Agent.Tools.ElixirEval.Read.get_task(#{inspect(target)})"
    # Reset the target AFTER the intervening read: if read-tier evaluation
    # accidentally joins the parallel phase, that read sees :completed instead
    # of :cancelled. This pins ALL tiers as serial, not just approved ones.
    sudo = """
    File.write!(#{inspect(path)}, "serial effects finished")
    EvoGit.Store.put_task(EvoGit.Store, %EvoGit.TaskInfo{
      id: #{inspect(target)}, type: :reflect, status: :completed, opts: []
    })
    :finished
    """

    calls = [
      call("read", %{"file_path" => path}),
      eval(write, "write"),
      eval(read),
      eval(sudo, "sudo")
    ]

    owner = start_batch(ctx, calls)
    first = approval!(ctx, write, :write)
    assert first.level == 2
    assert first.command == "elixir_eval"
    assert first.warning == nil
    assert global_task(target).status == :pending
    refute File.exists?(path)
    assert owner_pending(ctx) == [first]
    first_tool = assert_tool_identity(first, owner, ctx)
    assert :ok = CommandApproval.respond(first.request_id, :approve)

    second = approval!(ctx, sudo, :sudo)
    second_tool = assert_tool_identity(second, owner, ctx)
    refute first_tool == second_tool
    refute Process.alive?(first_tool)
    assert second.request_id != first.request_id
    assert global_task(target).status == :cancelled
    refute File.exists?(path)
    assert owner_pending(ctx) == [second]
    assert :ok = CommandApproval.respond(second.request_id, :approve)

    results = finish(owner)
    assert Enum.map(results, &elem(&1, 0)) == [0, 1, 2, 3]
    assert Enum.map(results, &elem(&1, 1)) == Enum.map(calls, & &1.id)
    assert output(results, 0) =~ "serial effects finished"
    assert output(results, 1) =~ ":requested"
    assert output(results, 2) =~ ":cancelled"
    assert output(results, 3) == "Result: :finished"
    assert File.read!(path) == "serial effects finished"
    assert global_task(target).status == :completed
  end

  for tier <- ["write", "sudo"] do
    test "#{tier} approval survives a tiny explicit outer timeout", ctx do
      tier = unquote(tier)
      message = "approved-#{unique_task_id()}"
      # Do not preload WriteAllowlist.Base or the Write facade here: first-use
      # dispatch must work too. The wrapper must initialize Dune's alias atoms
      # before safe parsing, rather than depending on earlier write evaluations.
      code = effect_code(tier, ctx, message)
      owner = start_batch(ctx, [eval(code, tier, %{"timeout" => 1, "timeout_ms" => 2_000})])
      request = approval!(ctx, code, String.to_existing_atom(tier))

      # Deliberately exceed the explicit 1ms outer timeout while the real
      # approval is held. A timer event, not polling a transient alive window.
      token = make_ref()
      Process.send_after(self(), {:held_approval, token}, 30)
      assert_receive {:held_approval, ^token}, @deadline
      assert Process.alive?(owner.pid)
      assert owner_pending(ctx) == [request]
      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert [{0, _, "elixir_eval", output}] = finish(owner)
      assert output =~ "Result:"
      refute output =~ "Error:"
      assert_effect(tier, ctx, message)
    end
  end

  test "max_timeout still caps the approval floor and cleans the dead tool's request", ctx do
    path = Path.join(ctx.repo_root, "must-not-run.txt")
    code = "File.write!(#{inspect(path)}, \"unexpected\")"
    owner = start_batch(ctx, [eval(code, "sudo", %{"timeout" => 1})], max_timeout: 1_000)
    request = approval!(ctx, code, :sudo)
    id = request.request_id
    assert [{0, _, "elixir_eval", output}] = finish(owner)
    assert output =~ "Tool execution timed out after 1000ms"
    assert_receive {:approval_resolved, ^id, :timed_out}, @deadline

    refute Enum.any?(CommandApproval.pending(), &(&1.request_id == id))

    assert {:error, :not_found} = CommandApproval.respond(id, :approve)
    refute File.exists?(path)
  end

  test "cancellation flag invalidated during pending approval prevents evaluation after approval",
       ctx do
    path = Path.join(ctx.repo_root, "cancelled-before-eval.txt")
    code = "File.write!(#{inspect(path)}, \"unexpected\")"
    owner = start_batch(ctx, [eval(code, "sudo"), eval("42")])
    request = approval!(ctx, code, :sudo)
    [{id, state}] = :ets.lookup(:evogit_agent_state, owner.agent_id)
    :ets.insert(:evogit_agent_state, {id, %{state | cancel_requested: true}})
    assert :ok = CommandApproval.respond(request.request_id, :approve)
    results = finish(owner)
    assert output(results, 0) =~ @denied
    assert output(results, 1) =~ @denied
    refute File.exists?(path)
  end

  test "persisted lifecycle invalidation is rechecked even without an approval-service broadcast",
       ctx do
    path = Path.join(ctx.repo_root, "stale-approved-owner.txt")
    code = "File.write!(#{inspect(path)}, \"unexpected\")"
    owner = start_batch(ctx, [eval(code, "sudo")])
    request = approval!(ctx, code, :sudo)

    # Store writes do not publish lifecycle events. The approval service still
    # accepts this decision, so only the evaluator's post-approval revalidation
    # can prevent the otherwise-approved side effect.
    :ok = Store.put_task(Store, %{ctx.owner_task | status: :cancelling})
    assert owner_pending(ctx) == [request]
    assert :ok = CommandApproval.respond(request.request_id, :approve)
    assert [{0, _, "elixir_eval", output}] = finish(owner)
    assert output =~ @denied
    refute File.exists?(path)
  end

  test "task lifecycle broadcast closes pending approval and never executes its code", ctx do
    path = Path.join(ctx.repo_root, "terminal-before-eval.txt")
    code = "File.write!(#{inspect(path)}, \"unexpected\")"
    owner = start_batch(ctx, [eval(code, "sudo")])
    request = approval!(ctx, code, :sudo)
    :ok = Store.put_task(Store, %{ctx.owner_task | status: :cancelled})

    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      "tasks",
      {:task_updated, ctx.owner_task.id, :cancelled, node()}
    )

    id = request.request_id
    assert_receive {:approval_resolved, ^id, :deny}, @deadline
    assert [{0, _, "elixir_eval", output}] = finish(owner)
    assert output =~ "denied by the user"
    assert {:error, :not_found} = CommandApproval.respond(id, :approve)
    refute File.exists?(path)
  end

  for decision <- [:deny, :timeout] do
    @tag approval_decision: decision
    test "#{decision} of an evaluator request leaves effects absent and the batch continues",
         ctx do
      decision = ctx.approval_decision

      if decision == :timeout,
        do: Application.put_env(:evo_git, :command_approval_timeout, 100)

      path = Path.join(ctx.repo_root, "unapproved.txt")
      code = "File.write!(#{inspect(path)}, \"unexpected\")"
      owner = start_batch(ctx, [eval(code, "sudo"), eval("21 * 2")])
      request = approval!(ctx, code, :sudo)
      id = request.request_id

      if decision == :deny do
        assert :ok = CommandApproval.respond(id, :deny)
      else
        assert_receive {:approval_resolved, ^id, :timed_out}, @deadline
      end

      results = finish(owner)
      expected = if decision == :deny, do: "denied by the user", else: "approval timed out"
      assert output(results, 0) =~ expected
      assert output(results, 1) == "Result: 42"
      refute File.exists?(path)
      assert {:error, :not_found} = CommandApproval.respond(id, :approve)
    end
  end

  test "authorized owners cannot bypass exact-code approval with legacy run_command", ctx do
    target = seed_target(:pending)

    owner =
      start_batch(ctx, [
        call("run_command", %{"command" => "CancelTask.cancel_task #{target}"}),
        eval("42")
      ])

    results = finish(owner)
    assert output(results, 0) =~ "use elixir_eval exact-code approval path"
    assert output(results, 1) == "Result: 42"
    assert global_task(target).status == :pending
    refute_owner_approvals(ctx)
  end

  defp start_batch(ctx, calls, opts \\ []) do
    id = 9_900_000 + System.unique_integer([:positive])
    parent = self()

    task =
      Task.async(fn ->
        receive do
          :run ->
            Process.put(:evogit_agent_id, id)
            # These are deliberately wrong: dispatch must derive task/PID from
            # the registered owner rather than reuse stale caller dictionary keys.
            Process.put(:evogit_task_id, "stale-task")
            Process.put(:evogit_agent_pid, parent)
            Process.put(:evogit_task_registry_server, ctx.registry)
            Process.put(:repo_path, ctx.repo_root)
            Process.put(:genesis_repo_root, ctx.repo_root)

            ToolDispatch.batch_execute_tools(
              Enum.with_index(calls),
              Keyword.get(opts, :max_timeout, 60_000),
              ctx.repo_root,
              :low,
              EvoGit.Agents.SelfReflective
            )
        end
      end)

    spec =
      EvoGit.Runtime.SelfReflective.build_spec("dispatch integration",
        source_root: ctx.repo_root,
        task_id: ctx.owner_task.id
      )

    state = %AgentState{
      context_node: spec.context_node,
      llm_model: "test:model",
      max_retries: 0,
      max_depth: 1
    }

    meta = %SchedMeta{
      id: id,
      depth: 0,
      spec: spec,
      status: :running,
      task_id: ctx.owner_task.id,
      task_ref: task
    }

    meta = Keyword.get(opts, :meta, &Function.identity/1).(meta)
    :ets.insert(:evogit_agent_state, {id, state})
    :ets.insert(:evogit_sched_meta, {id, meta})

    on_exit(fn ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
      :ets.delete(:evogit_agent_state, id)
      :ets.delete(:evogit_sched_meta, id)
    end)

    send(task.pid, :run)
    %{task: task, pid: task.pid, agent_id: id}
  end

  defp finish(owner), do: Task.await(owner.task, @deadline)

  defp approval!(ctx, code, tier) do
    task_id = ctx.owner_task.id
    assert_receive {:approval_requested, %{task_id: ^task_id} = request}, @deadline
    assert request.code == code
    assert request.args == code
    assert request.tier == tier
    assert request.kind == :elixir_eval
    assert request.node == node()
    assert request.agent_id =~ ~r/^\d+$/
    request
  end

  defp assert_tool_identity(request, owner, ctx) do
    assert request.agent_id == Integer.to_string(owner.agent_id)
    entry = Map.fetch!(:sys.get_state(CommandApproval).pending, request.request_id)
    {tool_pid, _reply_tag} = entry.from
    refute tool_pid == owner.pid
    refute tool_pid == self()
    {:dictionary, dictionary} = Process.info(tool_pid, :dictionary)
    assert dictionary[:evogit_agent_id] == owner.agent_id
    assert dictionary[:evogit_task_id] == ctx.owner_task.id
    assert dictionary[:evogit_agent_pid] == owner.pid
    assert hd(dictionary[:"$callers"]) == owner.pid

    assert [{_, %SchedMeta{task_ref: %Task{pid: pid}}}] =
             :ets.lookup(:evogit_sched_meta, owner.agent_id)

    assert pid == owner.pid
    tool_pid
  end

  defp owner_pending(ctx),
    do: Enum.filter(CommandApproval.pending(), &(&1.task_id == ctx.owner_task.id))

  defp refute_owner_approvals(ctx) do
    id = ctx.owner_task.id
    # The service's synchronous reply orders all earlier approval broadcasts
    # to this subscriber before the zero-window mailbox assertion.
    assert owner_pending(ctx) == []
    refute_receive {:approval_requested, %{task_id: ^id}}, 0
  end

  defp eval(code, tier \\ "read", extra \\ %{}),
    do: call("elixir_eval", Map.merge(%{"code" => code, "tier" => tier}, extra))

  defp call(name, args) do
    %ReqLLM.ToolCall{
      id: "dispatch-#{System.unique_integer([:positive])}",
      type: "function",
      function: %{name: name, arguments: Jason.encode!(args)}
    }
  end

  defp output(results, index) do
    {^index, _, _, text} = Enum.find(results, &(elem(&1, 0) == index))
    text
  end

  defp unique_task_id, do: "eval_dispatch_#{System.unique_integer([:positive])}"

  defp seed_target(status) do
    id = unique_task_id()
    :ok = Store.put_task(Store, %TaskInfo{id: id, type: :reflect, status: status, opts: []})
    on_exit(fn -> :ok = Store.delete_task(Store, id) end)
    id
  end

  defp global_task(id), do: GenServer.call(EvoGit.TaskRegistry, {:get_task_lite, id})

  defp effect_code("write", _ctx, message),
    do: "EvoGit.Agent.Tools.ElixirEval.Write.guide(#{inspect(message)})"

  defp effect_code("sudo", ctx, message),
    do: "File.write!(#{inspect(Path.join(ctx.repo_root, message))}, \"approved\"); :ok"

  defp assert_effect("write", _ctx, message) do
    local_node = node()
    assert_receive {:guide_updated, _, %{message: ^message}, ^local_node}, @deadline
  end

  defp assert_effect("sudo", ctx, message),
    do: assert(File.read!(Path.join(ctx.repo_root, message)) == "approved")
end
