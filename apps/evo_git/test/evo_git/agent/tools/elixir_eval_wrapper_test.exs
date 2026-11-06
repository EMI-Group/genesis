Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.WrapperTest do
  @moduledoc """
  Public wrapper approval contracts through genuine SelfReflective tool Tasks.

  Synchronous because these tests use the app-global EvoGit.CommandApproval
  service and mutate :evo_git, :command_approval_timeout (restored on exit).
  The Store/TaskRegistry, owner/descendant Tasks, files and scheduler ETS keys
  remain isolated per test. No authorization or Dune implementation is mocked.
  """
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.{CommandApproval, Store, TaskInfo}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @read "EvoGit.Agent.Tools.ElixirEval.Read"
  @write "EvoGit.Agent.Tools.ElixirEval.Write"
  @denied "Error: Elixir evaluation requires a live root reflective assistant on the local node."
  @deadline 15_000

  setup %{store: store, registry: registry} do
    previous = Application.fetch_env(:evo_git, :command_approval_timeout)
    Application.put_env(:evo_git, :command_approval_timeout, 30_000)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:evo_git, :command_approval_timeout, value)
        :error -> Application.delete_env(:evo_git, :command_approval_timeout)
      end
    end)

    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())
    EvoGit.TestSupport.ConfigDir.isolate!("eval_wrapper")
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  describe "public evaluation and exact-code manual approval" do
    test "default interpreted read discovers the facade without opening approval", ctx do
      # No facade/allowlist warm-up: first use must work on a cold BEAM too.
      code = "#{@read}.system_info().elixir"
      handle = start_eval(ctx.fixture, %{"code" => code})

      assert Fixture.await(handle) == "Result: #{inspect(System.version())}"
      assert_no_approval(ctx.fixture)
    end

    test "approved write preserves every code byte and actually cancels another task", ctx do
      target = pending_task(ctx)
      code = "  # exact write: 中文\n#{@write}.cancel_task(#{inspect(target.id)})\n  "
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => "write"})
      request = await_request(ctx.fixture, :write, code)
      assert_request(request, ctx.fixture, :write, code)

      # The approval is persistently pending, not a timing window in which the
      # test hopes to beat execution. No user decision has been submitted yet.
      assert request in CommandApproval.pending()
      assert Store.get_task(ctx.store, target.id).status == :pending
      assert :ok = CommandApproval.respond(request.request_id, :approve)
      output = Fixture.await(handle)
      assert output =~ "status: :requested"
      assert output =~ target.id
      assert Store.get_task(ctx.store, target.id).status == :cancelled
      assert Store.get_task(ctx.store, ctx.fixture.task_id).status == :running
      assert_resolved(request, :approve)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
    end

    test "approved sudo carries the unrestricted warning and executes native code", ctx do
      path = Path.join(ctx.data_dir, "approved-native")
      code = native_code(path)
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => "sudo"})
      request = await_request(ctx.fixture, :sudo, code)
      assert_request(request, ctx.fixture, :sudo, code)
      assert request in CommandApproval.pending()
      refute File.exists?(path)

      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == "Result: :native_done"
      assert File.read!(path) == "native effect 中文"
      assert_resolved(request, :approve)
    end

    test "read cannot use the write facade and does not auto-escalate", ctx do
      target = pending_task(ctx)
      code = "#{@write}.cancel_task(#{inspect(target.id)})"
      handle = start_eval(ctx.fixture, %{"code" => code})

      assert Fixture.await(handle) ==
               "Error: Evaluation rejected a restricted operation. Use admitted APIs such as EvoGit.TaskRegistry.list_tasks_page/0,1 or EvoGit.AgentScheduler.get_config/1; Read/Write facade APIs remain available. Call EvoGit.Agent.Tools.ElixirEval.Read.help() for exact MFAs and limits. Writes require the write tier and exact-code approval; no automatic escalation."

      assert Store.get_task(ctx.store, target.id).status == :pending
      assert_no_approval(ctx.fixture)
    end
  end

  for tier <- [:write, :sudo] do
    test "denying #{tier} prevents effects and late approval cannot execute it", ctx do
      {code, effect} = effect_code(ctx, unquote(tier))
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => Atom.to_string(unquote(tier))})
      request = await_request(ctx.fixture, unquote(tier), code)
      assert_no_effect(ctx, effect)
      assert :ok = CommandApproval.respond(request.request_id, :deny)

      assert Fixture.await(handle) ==
               "Error: Elixir evaluation denied by the user; code was not executed."

      assert_resolved(request, :deny)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert_no_effect(ctx, effect)
    end

    test "approval timeout for #{tier} prevents effects and rejects late approval", ctx do
      # Only expiry matters here; no assertion races the 100ms window. The
      # requested/resolved broadcasts and joined wrapper supply the barriers.
      Application.put_env(:evo_git, :command_approval_timeout, 100)
      {code, effect} = effect_code(ctx, unquote(tier))
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => Atom.to_string(unquote(tier))})
      request = await_request(ctx.fixture, unquote(tier), code)

      assert Fixture.await(handle) ==
               "Error: Elixir evaluation approval timed out; code was not executed."

      assert_resolved(request, :timed_out)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert_no_effect(ctx, effect)
    end
  end

  describe "held approval revalidates original authority before executing" do
    for change <- [:task_status, :task_type, :cancel_flag, :meta_status, :result_sent, :spec] do
      test "#{change} invalidated while approval is held fails closed after approval", ctx do
        # Exercise both a broker-backed mutation and an unrestricted native
        # side effect. Neither may run merely because approval was granted.
        for tier <- [:write, :sudo] do
          {code, effect} = effect_code(ctx, tier)
          handle = start_eval(ctx.fixture, %{"code" => code, "tier" => Atom.to_string(tier)})
          request = await_request(ctx.fixture, tier, code)
          assert request in CommandApproval.pending()
          assert_no_effect(ctx, effect)
          restore = invalidate(ctx.fixture, unquote(change))

          # Store/ETS updates deliberately do not publish task lifecycle events:
          # this proves the wrapper rechecks, not just service auto-denial.
          assert :ok = CommandApproval.respond(request.request_id, :approve)
          assert Fixture.await(handle) == @denied
          assert_resolved(request, :approve)
          assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
          assert_no_effect(ctx, effect)
          restore.()
        end
      end
    end

    test "replacing the owner Task while approval is held cannot transfer authority", ctx do
      replacement = Fixture.start!(self(), ctx.store, ctx.registry)
      on_exit(fn -> Fixture.stop(replacement) end)
      {code, effect} = effect_code(ctx, :sudo)
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => "sudo"})
      request = await_request(ctx.fixture, :sudo, code)
      Fixture.update_meta(ctx.fixture, &%{&1 | task_ref: replacement.owner})

      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == @denied
      assert_resolved(request, :approve)
      assert_no_effect(ctx, effect)
    end

    test "changing the embedded scheduler id under the same lookup key revokes authority", ctx do
      {code, effect} = effect_code(ctx, :sudo)
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => "sudo"})
      request = await_request(ctx.fixture, :sudo, code)
      [{id, meta}] = :ets.lookup(:evogit_sched_meta, ctx.fixture.agent_id)

      # Intentionally malformed identity: update_meta rightly forbids this, so
      # retain the production struct under OUR key with a different embedded id.
      true = :ets.insert(:evogit_sched_meta, {id, %{meta | id: id + 1}})
      assert :ok = CommandApproval.respond(request.request_id, :approve)
      assert Fixture.await(handle) == @denied
      assert_resolved(request, :approve)
      assert_no_effect(ctx, effect)
    end

    test "owner death while approval is held prevents execution even after approval", ctx do
      {code, effect} = effect_code(ctx, :sudo)
      test_pid = self()
      finished = make_ref()

      handle =
        Fixture.call_async(ctx.fixture, fn ->
          result = ElixirEval.execute(%{"code" => code, "tier" => "sudo"}, "[system]", "[system]")
          send(test_pid, {finished, result})
          result
        end)

      request = await_request(ctx.fixture, :sudo, code)
      tool_monitor = Process.monitor(handle.tool_pid)
      Process.exit(ctx.fixture.owner_pid, :kill)
      owner_monitor = handle.owner_monitor
      owner = ctx.fixture.owner_pid
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, @deadline

      assert :ok = CommandApproval.respond(request.request_id, :approve)
      # The dead owner can no longer forward Fixture.await; the tool sends its
      # wrapper result directly, then its monitor establishes no late execution.
      assert_receive {^finished, @denied}, @deadline
      tool = handle.tool_pid
      assert_receive {:DOWN, ^tool_monitor, :process, ^tool, :normal}, @deadline
      assert_resolved(request, :approve)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert_no_effect(ctx, effect)
    end

    test "tool death while waiting removes approval and cannot execute late", ctx do
      {code, effect} = effect_code(ctx, :sudo)
      handle = start_eval(ctx.fixture, %{"code" => code, "tier" => "sudo"})
      request = await_request(ctx.fixture, :sudo, code)
      monitor = Process.monitor(handle.tool_pid)
      Process.exit(handle.tool_pid, :kill)
      tool = handle.tool_pid
      assert_receive {:DOWN, ^monitor, :process, ^tool, :killed}, @deadline
      assert Fixture.await(handle) == {:exit, :killed}
      assert_resolved(request, :timed_out)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert_no_effect(ctx, effect)
    end
  end

  describe "public validation precedes approval and evaluation" do
    test "invalid arguments cannot request approval or run native side effects", ctx do
      path = Path.join(ctx.data_dir, "invalid-input")
      valid = %{"code" => native_code(path), "tier" => "sudo"}

      for {args, message} <- [
            {nil, "elixir_eval arguments must be an object."},
            {%{}, "code is required and must be a string."},
            {%{valid | "code" => " \n\t"}, "code must be a nonblank string."},
            {%{valid | "code" => <<255>>}, "code must be valid UTF-8."},
            {%{valid | "code" => String.duplicate("a", 16_001)},
             "code exceeds the 16000-byte limit."},
            {%{valid | "tier" => "SUDO"}, "tier must be read, write or sudo."},
            {Map.put(valid, "target_node", "other@remote"),
             "target_node must name the current/local node; remote evaluation is disabled."},
            {Map.put(valid, "target_node", nil),
             "target_node must be a string naming the current/local node."},
            {Map.put(valid, "timeout_ms", 0), "timeout_ms must be a positive integer."},
            {Map.put(valid, "timeout_ms", "2000"), "timeout_ms must be a positive integer."},
            {Map.put(valid, "max_output_bytes", -1),
             "max_output_bytes must be a positive integer."}
          ] do
        assert ctx.fixture |> start_eval(args) |> Fixture.await() == "Error: " <> message
        refute File.exists?(path)
        assert_no_approval(ctx.fixture)
      end
    end

    test "a forged repo-less flag does not authorize the public wrapper", ctx do
      path = Path.join(ctx.data_dir, "forged-authority")
      Process.put(:repo_less, true)
      Process.put(:evogit_agent_id, ctx.fixture.agent_id)
      Process.put(:evogit_task_id, ctx.fixture.task_id)
      Process.put(:evogit_agent_pid, ctx.fixture.owner_pid)

      assert ElixirEval.execute(%{"code" => native_code(path), "tier" => "sudo"}, "", "") ==
               @denied

      refute File.exists?(path)
      assert_no_approval(ctx.fixture)
    end
  end

  defp start_eval(fixture, args) do
    Fixture.call_async(fixture, fn -> ElixirEval.execute(args, "[system]", "[system]") end)
  end

  defp await_request(fixture, tier, code) do
    task_id = fixture.task_id
    agent_id = Integer.to_string(fixture.agent_id)

    # Respond ONLY to this fixture's exact request. Never approve unrelated
    # requests observed on the global topic, even if they have the same tier.
    assert_receive {:approval_requested,
                    %{task_id: ^task_id, agent_id: ^agent_id, tier: ^tier, code: ^code} = request},
                   @deadline

    request
  end

  defp assert_request(request, fixture, tier, code) do
    assert request.kind == :elixir_eval
    assert request.code === code
    assert request.args === code
    assert request.task_id == fixture.task_id
    assert request.agent_id == Integer.to_string(fixture.agent_id)
    assert request.target_node == node()
    assert request.node == node()
    assert is_binary(request.request_id) and byte_size(request.request_id) > 0

    case tier do
      :write ->
        assert request.command == "elixir_eval"
        assert request.level == 2
        assert request.warning == nil

      :sudo ->
        assert request.command == "elixir_eval sudo"
        assert request.level == 3
        assert request.warning =~ "Unrestricted live-BEAM privileges"
        assert request.warning =~ "OS, files, network and processes"
        assert request.warning =~ "not OS root elevation"
        assert request.warning =~ "no rollback"
    end
  end

  defp assert_resolved(request, decision) do
    request_id = request.request_id
    assert_receive {:approval_resolved, ^request_id, ^decision}, @deadline
    refute Enum.any?(CommandApproval.pending(), &(&1.request_id == request_id))
  end

  defp assert_no_approval(fixture) do
    task_id = fixture.task_id
    agent_id = Integer.to_string(fixture.agent_id)
    refute Enum.any?(CommandApproval.pending(), &(&1.task_id == task_id))
    # Invoked only after a joined wrapper; no possible future request from it.
    refute_received {:approval_requested, %{task_id: ^task_id, agent_id: ^agent_id}}
  end

  defp pending_task(ctx) do
    task = %TaskInfo{
      id: "wrapper_target_#{System.unique_integer([:positive])}",
      type: :reflect,
      status: :pending,
      opts: [mode: "reflect", objective: "Public wrapper cancellation target"]
    }

    assert task.id != ctx.fixture.task_id
    :ok = Store.put_task(ctx.store, task)
    task
  end

  defp native_code(path) do
    "  # exact sudo: 中文\nFile.write!(#{inspect(path)}, \"native effect 中文\")\n:native_done\n  "
  end

  defp effect_code(ctx, :write) do
    target = pending_task(ctx)
    {"#{@write}.cancel_task(#{inspect(target.id)})", {:task, target.id}}
  end

  defp effect_code(ctx, :sudo) do
    path = Path.join(ctx.data_dir, "native_#{System.unique_integer([:positive])}")
    {native_code(path), {:file, path}}
  end

  defp assert_no_effect(ctx, {:task, id}),
    do: assert(Store.get_task(ctx.store, id).status == :pending)

  defp assert_no_effect(_ctx, {:file, path}), do: refute(File.exists?(path))

  defp invalidate(fixture, change) when change in [:task_status, :task_type] do
    original = Store.get_task(fixture.store, fixture.task_id)

    Fixture.update_task(fixture, fn task ->
      case change do
        :task_status -> %{task | status: :cancelled}
        :task_type -> %{task | type: :evolve}
      end
    end)

    fn -> :ok = Store.put_task(fixture.store, original) end
  end

  defp invalidate(fixture, :cancel_flag) do
    Fixture.update_state(fixture, &%{&1 | cancel_requested: true})
    fn -> Fixture.update_state(fixture, &%{&1 | cancel_requested: false}) end
  end

  defp invalidate(fixture, change) do
    [{id, original}] = :ets.lookup(:evogit_sched_meta, fixture.agent_id)

    Fixture.update_meta(fixture, fn meta ->
      case change do
        :meta_status -> %{meta | status: :completed}
        :result_sent -> %{meta | result_sent: true}
        :spec -> %{meta | spec: %{meta.spec | agent_module: EvoGit.Agents.Executor}}
      end
    end)

    fn -> true = :ets.insert(:evogit_sched_meta, {id, original}) end
  end
end
