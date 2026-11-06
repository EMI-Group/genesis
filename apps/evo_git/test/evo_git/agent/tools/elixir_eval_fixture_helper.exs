defmodule EvoGit.TestSupport.ElixirEvalFixture do
  @moduledoc """
  Genuine, LLM-free reflective-assistant authority for evaluator tests.

  Require this file before defining the test module:

      Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

      # Inside a test using EvoGit.TaskRegistryCase:
      fixture = ElixirEvalFixture.start!(self(), store, registry)
      on_exit(fn -> ElixirEvalFixture.stop(fixture) end)
      handle = ElixirEvalFixture.call_async(fixture, fn -> Authorization.authorize() end)
      assert {:ok, context} = ElixirEvalFixture.await(handle)
      assert context.tool_pid == handle.tool_pid

  `start!/3` takes the explicitly isolated Store and TaskRegistry from the case
  context, not their process-dictionary defaults. It returns a map with
  `owner` (the real `%Task{}`), `owner_pid`, `agent_id`, `task_id`, `spec`,
  `store`, `registry`, `test_pid` and `supervisor`. The held owner starts every
  tool as a real Task; Task itself supplies ancestry, never fixture-written
  `$callers` or `$ancestors` values. No scheduler configuration is changed.

  `call_async/2` accepts a zero-arity function and returns a handle containing
  `tool_pid`, `owner_pid`, `request_ref` and `owner_monitor`. The function runs
  in the tool process with the exact fixture identity and registry. Results
  are forwarded through the still-live owner. `await/1,2` returns the function's
  value, or `{:exit, reason}` for a crashed/killed tool (and
  `{:exit, {:owner_down, reason}}` if the owner dies). Its default timeout is
  15 seconds; callers testing longer approval windows may pass a larger one.
  A test needing a held tool should make its function send a readiness message
  and wait for a test-controlled release. The handle's `tool_pid` can be
  monitored or killed directly; no tool failure takes the owner down.

  `update_state/2`, `update_meta/2` and `update_task/2` accept a unary transform
  and return the stored struct, for cancellation/staleness/role regressions.
  IDs are also exposed for tests requiring deletion or deliberately bad rows.
  Transforms must preserve their struct type and own row ID.

  Always call `stop/1` from `on_exit` (capture the fixture explicitly). The private
  supervisor is a temporary child of ExUnit's test supervisor, not linked to the
  test process. Cleanup monitors its termination before removing only its own
  ETS rows and deleting its task if the isolated Store is still alive. It is safe
  after owner/tool death, ExUnit shutdown or repeated cleanup; unexpected stop
  errors still fail. This fixture needs no global mutations and supports async
  tests; suites changing approval/scheduler globals need their own sync policy.
  """

  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.Core.ContextNode
  alias EvoGit.{AgentSpec, Store, TaskInfo}

  @timeout 15_000

  def start!(test_pid, store, registry) when is_pid(test_pid) do
    agent_id = 90_000_000 + System.unique_integer([:positive])
    task_id = "eval_fixture_#{agent_id}"
    context_node = %ContextNode{path: "./", repo: "[system]"}

    spec = %AgentSpec{
      context_node: context_node,
      phylo_node: nil,
      agent_module: EvoGit.Agents.SelfReflective,
      objective: "Evaluator test fixture",
      opts: [repo_less: true, task_id: task_id]
    }

    task = %TaskInfo{
      id: task_id,
      type: :reflect,
      status: :running,
      opts: [mode: "reflect", objective: spec.objective],
      started_at: DateTime.utc_now(),
      agent_count: 1
    }

    :ok = Store.put_task(store, task)
    # The ExUnit supervisor, not the short-lived test process, owns this tree.
    # Temporary children stay stopped after an explicit cleanup or death test.
    supervisor =
      ExUnit.Callbacks.start_supervised!({Task.Supervisor, []},
        id: {__MODULE__, agent_id},
        restart: :temporary
      )

    identity = %{
      test_pid: test_pid,
      store: store,
      registry: registry,
      agent_id: agent_id,
      task_id: task_id,
      spec: spec,
      supervisor: supervisor,
      config_dir: Process.get(:evogit_config_dir)
    }

    owner =
      Task.Supervisor.async_nolink(supervisor, fn ->
        put_identity(identity, self())
        owner_loop(identity, %{})
      end)

    fixture = identity |> Map.put(:owner, owner) |> Map.put(:owner_pid, owner.pid)

    state = %AgentState{
      context_node: context_node,
      llm_model: nil,
      max_retries: 0,
      max_depth: 0,
      objective: spec.objective,
      task_local_id: 1,
      cancel_requested: false
    }

    meta = %SchedMeta{
      id: agent_id,
      depth: 0,
      spec: spec,
      task_id: task_id,
      task_ref: owner,
      status: :running
    }

    true = :ets.insert(:evogit_agent_state, {agent_id, state})
    true = :ets.insert(:evogit_sched_meta, {agent_id, meta})
    fixture
  end

  def call_async(fixture, fun) when is_function(fun, 0) do
    request_ref = make_ref()
    owner_monitor = Process.monitor(fixture.owner_pid)
    send(fixture.owner_pid, {:call, self(), request_ref, fun})

    receive do
      {^request_ref, :started, tool_pid} ->
        %{
          tool_pid: tool_pid,
          owner_pid: fixture.owner_pid,
          request_ref: request_ref,
          owner_monitor: owner_monitor
        }

      {:DOWN, ^owner_monitor, :process, _, reason} ->
        raise "evaluator fixture owner died before starting tool: #{inspect(reason)}"
    after
      @timeout ->
        Process.demonitor(owner_monitor, [:flush])
        raise "evaluator fixture tool did not start"
    end
  end

  def await(handle, timeout \\ @timeout) do
    %{request_ref: request_ref, owner_monitor: owner_monitor} = handle

    receive do
      {^request_ref, :result, result} ->
        Process.demonitor(owner_monitor, [:flush])
        result

      {^request_ref, :exit, reason} ->
        Process.demonitor(owner_monitor, [:flush])
        {:exit, reason}

      {:DOWN, ^owner_monitor, :process, _, reason} ->
        {:exit, {:owner_down, reason}}
    after
      timeout ->
        raise "evaluator fixture tool result timed out"
    end
  end

  def update_state(fixture, fun) when is_function(fun, 1) do
    [{id, current}] = :ets.lookup(:evogit_agent_state, fixture.agent_id)
    %AgentState{} = updated = fun.(current)
    true = :ets.insert(:evogit_agent_state, {id, updated})
    updated
  end

  def update_meta(fixture, fun) when is_function(fun, 1) do
    [{id, current}] = :ets.lookup(:evogit_sched_meta, fixture.agent_id)
    %SchedMeta{id: ^id} = updated = fun.(current)
    true = :ets.insert(:evogit_sched_meta, {id, updated})
    updated
  end

  def update_task(fixture, fun) when is_function(fun, 1) do
    id = fixture.task_id
    %TaskInfo{id: ^id} = updated = fixture.store |> Store.get_task(id) |> fun.()
    :ok = Store.put_task(fixture.store, updated)
    updated
  end

  def stop(fixture) do
    stop_supervisor(fixture.supervisor)
    Process.demonitor(fixture.owner.ref, [:flush])
    delete_row(:evogit_agent_state, fixture.agent_id)
    delete_row(:evogit_sched_meta, fixture.agent_id)

    if GenServer.whereis(fixture.store) do
      :ok = Store.delete_task(fixture.store, fixture.task_id)
    end

    :ok
  end

  defp stop_supervisor(supervisor) do
    monitor = Process.monitor(supervisor)

    # ExUnit shuts supervised children down before on_exit. A concurrent shutdown
    # can end either the GenServer wrapper or its underlying :sys request; accept
    # only those expected death races, and still require the actual DOWN below.
    try do
      Supervisor.stop(supervisor)
    catch
      :exit, {reason, {GenServer, :stop, [^supervisor, :normal, :infinity]}}
      when reason in [:noproc, :normal, :shutdown] ->
        :ok

      :exit,
      {{reason, {:sys, :terminate, [^supervisor, :normal, :infinity]}},
       {GenServer, :stop, [^supervisor, :normal, :infinity]}}
      when reason in [:noproc, :normal, :shutdown] ->
        :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^supervisor, _reason} -> :ok
    after
      @timeout -> raise "evaluator fixture supervisor did not terminate"
    end
  end

  defp put_identity(fixture, owner_pid) do
    Process.put(:evogit_agent_id, fixture.agent_id)
    Process.put(:evogit_task_id, fixture.task_id)
    Process.put(:evogit_agent_pid, owner_pid)
    Process.put(:evogit_task_registry_server, fixture.registry)
    Process.put(:evogit_test_store, fixture.store)
    Process.put(:repo_less, true)
    Process.put(:evogit_config_dir, fixture.config_dir)
  end

  defp owner_loop(fixture, pending) do
    receive do
      {:call, caller, request_ref, fun} ->
        owner_pid = self()

        tool =
          Task.Supervisor.async_nolink(fixture.supervisor, fn ->
            put_identity(fixture, owner_pid)
            fun.()
          end)

        send(caller, {request_ref, :started, tool.pid})
        owner_loop(fixture, Map.put(pending, tool.ref, {caller, request_ref}))

      {ref, result} when is_reference(ref) ->
        {{caller, request_ref}, pending} = Map.pop!(pending, ref)
        Process.demonitor(ref, [:flush])
        send(caller, {request_ref, :result, result})
        owner_loop(fixture, pending)

      {:DOWN, ref, :process, _, reason} ->
        {{caller, request_ref}, pending} = Map.pop!(pending, ref)
        send(caller, {request_ref, :exit, reason})
        owner_loop(fixture, pending)
    end
  end

  defp delete_row(table, id) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table, id)
  end
end
