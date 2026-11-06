Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.DirectAPITest do
  @moduledoc """
  Genuine-Dune direct API admission and public tier-2 task lifecycle contracts.

  Synchronous because public writes use the app-global CommandApproval service
  and its pending roster/topic, and direct runtime reads inspect the global
  scheduler and RemoteAPI agent roster. No scheduler settings, approval timeout,
  environment variables or config files are changed. Every authority/task row,
  registry and held wrapper belongs to this test. Configuration mutation and
  persistence contracts are intentionally owned by a separate suite.
  """
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.{CommandApproval, Store, TaskInfo, TaskRegistry}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @limits %{timeout_ms: 5_000, max_output_bytes: 16_384}
  @deadline 15_000
  @restricted "Evaluation rejected a restricted operation. Use admitted APIs such as EvoGit.TaskRegistry.list_tasks_page/0,1 or EvoGit.AgentScheduler.get_config/1; Read/Write facade APIs remain available. Call EvoGit.Agent.Tools.ElixirEval.Read.help() for exact MFAs and limits. Writes require the write tier and exact-code approval; no automatic escalation."

  setup %{store: store, registry: registry} do
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())
    %{fixture: fixture}
  end

  describe "direct read values and real TaskRegistry arguments" do
    test "get_task and get_task_lite return the actual TaskInfo, not facade projections", ctx do
      target = seed_task(ctx, :completed)
      stored = Store.get_task(ctx.store, target.id)
      assert %TaskInfo{} = stored
      assert stored.opts[:objective] == "direct API objective"
      assert stored.result == {:ok, %{"report" => "unprojected result"}}

      for function <- ["get_task", "get_task_lite"] do
        code = "EvoGit.TaskRegistry.#{function}(#{inspect(target.id)})"
        assert_read_value(ctx.fixture, code, stored)
      end

      code = """
      task = EvoGit.TaskRegistry.get_task(#{inspect(target.id)})
      {task.__struct__ == EvoGit.TaskInfo,
       task.opts[:objective], task.logs, task.result, task.error}
      """

      assert_read_value(
        ctx.fixture,
        code,
        {true, stored.opts[:objective], stored.logs, stored.result, stored.error}
      )

      assert_no_approval(ctx.fixture)
    end

    test "both single-task reads preserve the real nil result for unknown ids", ctx do
      code = """
      {EvoGit.TaskRegistry.get_task("missing_direct_task"),
       EvoGit.TaskRegistry.get_task_lite("missing_direct_task")}
      """

      assert read(ctx.fixture, code) == "Result: {nil, nil}"
      assert_no_approval(ctx.fixture)
    end

    test "list_tasks_page/0 returns the real two-key page and unprojected summary rows", ctx do
      target = seed_task(ctx, :pending)
      expected = TaskRegistry.list_tasks_page()
      assert Enum.sort(Map.keys(expected)) == [:rows, :total]
      assert expected.total == 2
      assert Enum.any?(expected.rows, &(&1.id == target.id))
      assert_read_value(ctx.fixture, "EvoGit.TaskRegistry.list_tasks_page()", expected)
      assert_no_approval(ctx.fixture)
    end

    test "keyword filters, precedence, offset and last-page clamping reach the actual API", ctx do
      older = seed_task(ctx, :pending, ~U[2026-01-01 00:00:00Z])
      newer = seed_task(ctx, :pending, ~U[2026-01-02 00:00:00Z])
      _completed = seed_task(ctx, :completed, ~U[2026-01-03 00:00:00Z])

      for {offset, expected_id} <- [{0, newer.id}, {1, older.id}, {999, older.id}] do
        opts = [limit: 1, offset: offset, filters: [status: "completed"], status: "pending"]
        expected = TaskRegistry.list_tasks_page(opts)
        assert %{rows: [%{id: ^expected_id}], total: 2} = expected

        assert_read_value(
          ctx.fixture,
          "EvoGit.TaskRegistry.list_tasks_page(#{inspect(opts)})",
          expected
        )
      end

      assert_read_value(
        ctx.fixture,
        "EvoGit.TaskRegistry.list_tasks_page(search: \"no such task\")",
        %{rows: [], total: 0}
      )

      assert_no_approval(ctx.fixture)
    end

    test "invalid atom status is passed through to the real API's degraded read", ctx do
      seed_task(ctx, :pending)

      # The real API accepts persisted status strings, not atoms. Direct calls
      # must not silently apply the convenience facade's atom normalization.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert TaskRegistry.list_tasks_page(status: :pending) == %{rows: [], total: 0}

          assert_read_value(
            ctx.fixture,
            "EvoGit.TaskRegistry.list_tasks_page(status: :pending)",
            %{rows: [], total: 0}
          )
        end)

      assert log =~ "Store: read select_tasks_page failed"
      assert log =~ "Ecto.Query.CastError"
      assert_no_approval(ctx.fixture)
    end

    test "nested interpreted callbacks retain captured registry routing for direct reads", ctx do
      first = seed_task(ctx, :pending)
      second = seed_task(ctx, :completed)
      ids = [first.id, second.id]

      code = """
      Enum.map(#{inspect(ids)}, fn id ->
        Enum.map([id], fn nested_id ->
          task = EvoGit.TaskRegistry.get_task(nested_id)
          lite = EvoGit.TaskRegistry.get_task_lite(nested_id)
          {task.__struct__ == EvoGit.TaskInfo, task == lite, task.id, task.status}
        end)
      end)
      """

      assert_read_value(ctx.fixture, code, [
        [{true, true, first.id, :pending}],
        [{true, true, second.id, :completed}]
      ])

      assert_no_approval(ctx.fixture)
    end
  end

  describe "runtime read admission without runtime mutation" do
    test "RemoteAPI.list_agents returns the actual full summary for the genuine owner", ctx do
      expected = Enum.find(RemoteAPI.list_agents(), &(&1.id == ctx.fixture.agent_id))
      assert is_map(expected)
      assert expected.task_id == ctx.fixture.task_id

      # Compare every field and the exact usage struct module, without asking
      # Dune to synthesize an unadmitted Usage alias from a source-code literal.
      # Its parser deliberately pools alias atoms it has never loaded.
      code = """
      agent = EvoGit.AgentScheduler.RemoteAPI.list_agents()
              |> Enum.find(fn agent -> agent.id == #{ctx.fixture.agent_id} end)
      {Map.delete(agent, :usage), Atom.to_string(agent.usage.__struct__),
       Map.from_struct(agent.usage)}
      """

      assert_read_value(
        ctx.fixture,
        code,
        {Map.delete(expected, :usage), Atom.to_string(expected.usage.__struct__),
         Map.from_struct(expected.usage)}
      )

      assert_no_approval(ctx.fixture)
    end

    test "get_config/1, paused?/0 and slot status preserve real scheduler returns", ctx do
      expected = {
        EvoGit.AgentScheduler.get_config(:model_profiles),
        EvoGit.AgentScheduler.get_config(:max_tool_concurrency),
        EvoGit.AgentScheduler.get_config(:unlisted_direct_config_key),
        EvoGit.AgentScheduler.paused?(),
        EvoGit.AgentScheduler.get_llm_slot_status()
      }

      code = """
      {EvoGit.AgentScheduler.get_config(:model_profiles),
       EvoGit.AgentScheduler.get_config(:max_tool_concurrency),
       EvoGit.AgentScheduler.get_config(:unlisted_direct_config_key),
       EvoGit.AgentScheduler.paused?(),
       EvoGit.AgentScheduler.get_llm_slot_status()}
      """

      assert elem(expected, 2) == nil
      assert is_boolean(elem(expected, 3))
      assert is_map(elem(expected, 4))
      assert_read_value(ctx.fixture, code, expected)
      assert_no_approval(ctx.fixture)
    end

    test "Config.resolve/0,1 accept an atom or nested key path, not facade-only keys", ctx do
      # These are relational assertions on the same resolved configuration, not
      # assumptions about the developer's config or live scheduler overrides.
      code = """
      config = EvoGit.Config.resolve()
      scheduler = EvoGit.Config.resolve(:scheduler)
      nested = EvoGit.Config.resolve([:scheduler, :max_tool_concurrency])
      {is_map(config), is_map(scheduler),
       scheduler == config.scheduler,
       nested == scheduler.max_tool_concurrency,
       EvoGit.Config.resolve(:unlisted_direct_config_key)}
      """

      assert read(ctx.fixture, code) == "Result: {true, true, true, true, nil}"
      assert_no_approval(ctx.fixture)
    end
  end

  describe "exact MFA and tier admission through genuine Dune" do
    test "read refuses every admitted write MFA without approval or automatic escalation", ctx do
      target = seed_task(ctx, :pending)
      id = inspect(target.id)

      for code <- [
            "EvoGit.TaskRegistry.start_task(:reflect, [])",
            "EvoGit.TaskRegistry.cancel_task(#{id})",
            "EvoGit.TaskRegistry.force_kill_task(#{id})",
            "EvoGit.TaskRegistry.delete_task(#{id})",
            "EvoGit.AgentScheduler.update_config([])",
            "EvoGit.AgentScheduler.pause()",
            "EvoGit.AgentScheduler.resume()",
            "EvoGit.Config.save_user_config(%{})",
            "EvoGit.AgentScheduler.RemoteAPI.reload_config()"
          ] do
        assert read(ctx.fixture, code) == "Error: " <> @restricted
        assert Store.get_task(ctx.store, target.id).status == :pending
        assert_no_approval(ctx.fixture)
      end
    end

    test "another arity and unlisted runtime functions stay restricted in both interpreted tiers",
         ctx do
      # Existing real functions and known alias atoms ensure a failure is about
      # exact admission, not an absent module or a native undefined-function error.
      for code <- [
            "EvoGit.TaskRegistry.list_tasks_page([], [])",
            "EvoGit.TaskRegistry.get_task()",
            "EvoGit.TaskRegistry.get_task_lite()",
            "EvoGit.TaskRegistry.start_task(:reflect)",
            "EvoGit.TaskRegistry.cancel_task()",
            "EvoGit.TaskRegistry.force_kill_task()",
            "EvoGit.TaskRegistry.delete_task()",
            "EvoGit.AgentScheduler.get_config()",
            "EvoGit.AgentScheduler.paused?(true)",
            "EvoGit.AgentScheduler.get_llm_slot_status(nil)",
            "EvoGit.AgentScheduler.update_config()",
            "EvoGit.AgentScheduler.pause(true)",
            "EvoGit.AgentScheduler.resume(true)",
            "EvoGit.Config.resolve(:scheduler, nil)",
            "EvoGit.Config.save_user_config()",
            "EvoGit.AgentScheduler.RemoteAPI.list_agents(nil)",
            "EvoGit.AgentScheduler.RemoteAPI.reload_config(nil)",
            "EvoGit.TaskRegistry.list_tasks()",
            "EvoGit.TaskRegistry.server()",
            "EvoGit.AgentScheduler.RemoteAPI.get_config()"
          ],
          tier <- [:read, :write] do
        assert engine(ctx.fixture, code, tier) == {:error, @restricted}
      end

      assert_no_approval(ctx.fixture)
    end
  end

  describe "public approved tier-2 direct task lifecycle" do
    test "start_task returns real submission data, not a facade map or execution success", ctx do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      objective = "direct enqueue #{ctx.fixture.agent_id}"

      code = """
      {:ok, task} = EvoGit.TaskRegistry.start_task(:evolve, objective: #{inspect(objective)})
      {task.__struct__ == EvoGit.TaskInfo, task.type, task.status,
       task.opts == [objective: #{inspect(objective)}],
       is_binary(task.id) and byte_size(task.id) == 16,
       task.ref.__struct__ == Task and Map.has_key?(task.ref, :pid) and Map.has_key?(task.ref, :ref)}
      """

      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert TaskRegistry.list_tasks_page().total == 1

      # Missing :path deterministically fails BEFORE Evolution or any LLM runs.
      # Enqueue still returns the actual running TaskInfo including runtime ref;
      # its later failure is deliberately distinct from submission acceptance.
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = CommandApproval.respond(request.request_id, :approve)
        assert Fixture.await(handle) == "Result: {true, :evolve, :running, true, true, true}"
        [target] = Enum.reject(TaskRegistry.list_tasks(), &(&1.id == ctx.fixture.task_id))
        id = target.id
        local_node = node()
        assert target.type == :evolve
        assert target.opts[:objective] == objective
        assert_receive {:task_updated, ^id, :failed, ^local_node}, @deadline
        assert TaskRegistry.get_task(id).status == :failed
      end)

      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end

    test "exact approved code cancels a pending task with the real :ok acknowledgement", ctx do
      target = seed_task(ctx, :pending)

      code =
        "  # direct cancel: 中文\ntarget = EvoGit.TaskRegistry.get_task(#{inspect(target.id)})\nEvoGit.TaskRegistry.cancel_task(target.id)\n  "

      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert Store.get_task(ctx.store, target.id).status == :pending

      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == "Result: :ok"
      assert Store.get_task(ctx.store, target.id).status == :cancelled
      assert Store.get_task(ctx.store, ctx.fixture.task_id).status == :running
      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end

    test "delete returns only the real cast acknowledgement and eventually removes the row",
         ctx do
      target = seed_task(ctx, :completed)
      code = "EvoGit.TaskRegistry.delete_task(#{inspect(target.id)})"
      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert Store.get_task(ctx.store, target.id).status == :completed

      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == "Result: :ok"
      # A registry call after the joined wrapper is a mailbox barrier for the
      # queued cast; :ok alone is explicitly NOT evidence of persisted deletion.
      assert TaskRegistry.get_task(target.id) == nil
      assert Store.get_task(ctx.store, target.id) == nil
      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end

    test "force kill actually kills a held wrapper and persists failed rather than cancelled",
         ctx do
      target = seed_task(ctx, :running)
      wrapper = held_wrapper(ctx, target.id)
      monitor = Process.monitor(wrapper.pid)
      code = "EvoGit.TaskRegistry.force_kill_task(#{inspect(target.id)})"
      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert Process.alive?(wrapper.pid)
      assert Store.get_task(ctx.store, target.id).status == :running

      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == "Result: :ok"
      pid = wrapper.pid
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @deadline
      refute Process.alive?(pid)
      stored = Store.get_task(ctx.store, target.id)
      assert stored.status == :failed
      assert stored.result == nil
      assert stored.lease_expires_at == nil
      assert %DateTime{} = stored.finished_at
      refute Map.has_key?(:sys.get_state(ctx.registry).task_refs, target.id)
      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end

    test "real missing-task and terminal-state errors are not facade acknowledgements", ctx do
      target = seed_task(ctx, :completed)

      code = """
      {EvoGit.TaskRegistry.cancel_task("missing_direct_task"),
       EvoGit.TaskRegistry.force_kill_task("missing_direct_task"),
       EvoGit.TaskRegistry.cancel_task(#{inspect(target.id)}),
       EvoGit.TaskRegistry.force_kill_task(#{inspect(target.id)}),
       EvoGit.TaskRegistry.delete_task("missing_direct_task")}
      """

      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert :ok = CommandApproval.respond(request.request_id, :approve)

      assert Fixture.await(handle) ==
               result(
                 {{:error, :not_found}, {:error, :not_found}, {:error, :not_running},
                  {:error, :not_running}, :ok}
               )

      assert TaskRegistry.get_task(target.id).status == :completed
      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end

    test "denying direct write prevents execution and late approval cannot replay it", ctx do
      target = seed_task(ctx, :pending)
      code = "EvoGit.TaskRegistry.cancel_task(#{inspect(target.id)})"
      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert :ok = CommandApproval.respond(request.request_id, :deny)

      assert Fixture.await(handle) ==
               "Error: Elixir evaluation denied by the user; code was not executed."

      assert_resolved(request, :deny)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert Store.get_task(ctx.store, target.id).status == :pending
      assert_no_escalation(ctx.fixture)
    end

    test "approval does not bypass lifecycle revalidation for a direct mutation", ctx do
      target = seed_task(ctx, :pending)
      code = "EvoGit.TaskRegistry.cancel_task(#{inspect(target.id)})"
      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      # No lifecycle broadcast: the wrapper itself must re-read its authenticated
      # task, not rely on approval-service event-driven denial.
      Fixture.update_task(ctx.fixture, &%{&1 | status: :cancelled})
      assert :ok = CommandApproval.respond(request.request_id, :approve)

      assert Fixture.await(handle) ==
               "Error: Elixir evaluation requires a live root reflective assistant on the local node."

      assert Store.get_task(ctx.store, target.id).status == :pending
      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end

    test "approving tier 2 does not grant native filesystem authority or escalate to sudo", ctx do
      path = Path.join(ctx.data_dir, "must-not-be-written")
      code = "File.write!(#{inspect(path)}, \"not allowed\")"
      handle = start_eval(ctx.fixture, code, "write")
      request = await_write_request(ctx.fixture, code)
      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == "Error: " <> @restricted
      refute File.exists?(path)
      assert_resolved(request, :approve)
      assert_no_escalation(ctx.fixture)
    end
  end

  defp read(fixture, code), do: fixture |> start_eval(code, "read") |> Fixture.await()

  defp start_eval(fixture, code, tier) do
    Fixture.call_async(fixture, fn ->
      ElixirEval.execute(%{"code" => code, "tier" => tier}, "[system]", "[system]")
    end)
  end

  defp engine(fixture, code, tier) do
    fixture
    |> Fixture.call_async(fn ->
      {:ok, authority} = Authorization.authorize()
      Engine.run(code, tier, authority, @limits)
    end)
    |> Fixture.await()
  end

  defp result(value), do: "Result: " <> inspect(value)

  defp assert_read_value(fixture, code, expected) do
    # Compare the complete native term INSIDE genuine Dune. Its safe inspection
    # deliberately differs from native Inspect for structs; matching only a
    # pretty-printed projection would miss changes to the actual API return.
    literal = inspect(expected, structs: false, limit: :infinity, printable_limit: :infinity)
    assert read(fixture, "(#{code}) == #{literal}") == "Result: true"
  end

  defp seed_task(ctx, status, started_at \\ ~U[2026-01-01 00:00:00Z]) do
    task = %TaskInfo{
      id: "direct_target_#{System.unique_integer([:positive])}",
      type: :reflect,
      status: status,
      opts: [mode: "reflect", objective: "direct API objective"],
      started_at: started_at,
      logs: ["direct API log"],
      result: {:ok, %{"report" => "unprojected result"}},
      error: %{reason: "direct API error"},
      lease_expires_at: System.system_time(:second) + 300
    }

    :ok = Store.put_task(ctx.store, task)
    task
  end

  defp held_wrapper(ctx, task_id) do
    test_pid = self()
    token = make_ref()

    :sys.replace_state(ctx.registry, fn state ->
      # Create a genuine Task owned/monitored by the isolated registry, held
      # until shutdown. It never runs an LLM or touches a repository.
      task =
        Task.Supervisor.async_nolink(ctx.fixture.supervisor, fn ->
          receive do
            :release -> :released
          end
        end)

      send(test_pid, {token, task})
      %{state | task_refs: Map.put(state.task_refs, task_id, task)}
    end)

    assert_receive {^token, task}, @deadline
    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    task
  end

  defp await_write_request(fixture, code) do
    task_id = fixture.task_id
    agent_id = Integer.to_string(fixture.agent_id)

    assert_receive {:approval_requested,
                    %{task_id: ^task_id, agent_id: ^agent_id, tier: :write, code: ^code} = request},
                   @deadline

    assert request.kind == :elixir_eval
    assert request.args === code
    assert request.code === code
    assert request.level == 2
    assert request.command == "elixir_eval"
    assert request.warning == nil
    assert request.target_node == node()
    assert request.node == node()
    assert request in CommandApproval.pending()
    request
  end

  defp assert_resolved(request, decision) do
    id = request.request_id
    assert_receive {:approval_resolved, ^id, ^decision}, @deadline
    refute Enum.any?(CommandApproval.pending(), &(&1.request_id == id))
    assert {:error, :not_found} = CommandApproval.respond(id, :approve)
  end

  defp assert_no_approval(fixture) do
    refute Enum.any?(CommandApproval.pending(), &(&1.task_id == fixture.task_id))
    assert_no_escalation(fixture)
  end

  defp assert_no_escalation(fixture) do
    task_id = fixture.task_id
    agent_id = Integer.to_string(fixture.agent_id)
    # Every tool has joined; no request from this invocation can arrive later.
    refute_received {:approval_requested, %{task_id: ^task_id, agent_id: ^agent_id}}
  end
end
