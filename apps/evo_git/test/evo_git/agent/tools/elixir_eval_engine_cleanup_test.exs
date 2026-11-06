Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.EngineCleanupTest do
  @moduledoc """
  Real-Dune companion to the handshake-held WorkerTree regressions.

  Each case has genuine assistant owner/tool ancestry and an isolated registry.
  A private OTP trace session observes the real Engine tree without replacing
  Custodian's legacy trace ownership or installing VM-global function patterns.
  Dune, its nested helpers, the broker and authorization are never mocked.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @deadline 15_000
  @limits %{timeout_ms: 10_000, max_output_bytes: 4_096}

  setup %{store: store, registry: registry} do
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  test "Dune nested facade discovery succeeds and every traced Engine descendant exits", %{
    fixture: fixture
  } do
    # Do not preload the facade or ReadAllowlist.Base here: a cold Engine must
    # initialize Dune's alias atoms before parsing fully qualified facade names.
    # Running this test alone also guards that real first-use path.
    code = "EvoGit.Agent.Tools.ElixirEval.Read.get_task(#{inspect(fixture.task_id)}).id"
    {result, events} = run_engine(fixture, code)

    assert result == {:ok, "Result: " <> inspect(fixture.task_id)},
           "real Dune results: #{inspect(events.dune_results)}"

    # This is a real broker request from a nested Dune helper, not a direct
    # facade call from the fixture's tool process or the root worker.
    assert Enum.any?(events.operations, fn {pid, :get_task, [id]} ->
             id == fixture.task_id and pid != events.root and
               descendant?(pid, events.root, events.parents)
           end)
  end

  test "Dune runtime failure also leaves no traced helper or Engine infrastructure alive", %{
    fixture: fixture
  } do
    {result, _events} = run_engine(fixture, "1 / 0")
    assert result == {:error, "Evaluation failed (invalid code or runtime exception)."}
  end

  defp run_engine(fixture, code) do
    test_pid = self()
    tag = make_ref()

    handle =
      Fixture.call_async(fixture, fn ->
        send(test_pid, {tag, :ready})

        receive do
          {^tag, :run} ->
            {:ok, context} = Authorization.authorize()
            Engine.run(code, :read, context, @limits)
        end
      end)

    assert_receive {^tag, :ready}, @deadline
    session = :trace.session_create(:elixir_eval_engine_cleanup, self(), [])

    try do
      assert 1 ==
               :trace.process(session, handle.tool_pid, true, [
                 :procs,
                 :set_on_spawn,
                 :send,
                 :call
               ])

      :trace.function(session, {Dune, :eval_string, 2}, [{:_, [], [{:return_trace}]}], [:local])
      send(handle.tool_pid, {tag, :run})
      result = Fixture.await(handle)

      # Flush this observer's own trace session as well as asserting the actual
      # custody barrier/ack (via its send trace). No quiet window guesses when
      # the spawn and exit messages have finished arriving.
      barrier = :trace.delivered(session, :all)

      events =
        collect_events(barrier, %{
          parents: %{},
          exits: %{},
          monitors: %{},
          operations: [],
          dune_results: []
        })

      assert_tree_stopped(events)
      {result, events}
    after
      :trace.session_destroy(session)
    end
  end

  defp collect_events(barrier, events) do
    receive do
      {:trace_delivered, :all, ^barrier} ->
        events

      {:trace, parent, :spawn, child, _} ->
        monitor = Process.monitor(child)
        on_exit(fn -> Process.exit(child, :kill) end)

        collect_events(barrier, %{
          events
          | parents: Map.put(events.parents, child, parent),
            monitors: Map.put(events.monitors, child, monitor)
        })

      {:trace, pid, :exit, reason} ->
        collect_events(barrier, %{events | exits: Map.put(events.exits, pid, reason)})

      {:trace, custodian, :send, {_, :custodian, custodian}, guardian} ->
        collect_events(barrier, Map.merge(events, %{custodian: custodian, guardian: guardian}))

      {:trace, root, :send, {:worker_ready, _, root}, guardian} ->
        collect_events(barrier, Map.merge(events, %{root: root, root_guardian: guardian}))

      {:trace, custodian, :send, {_, :cleaned, :ok}, guardian} ->
        collect_events(barrier, Map.put(events, :cleanup_ack, {custodian, guardian}))

      {:trace, pid, :send, {:"$gen_call", _, {:operation, operation, args}}, _} ->
        collect_events(barrier, %{
          events
          | operations: [{pid, operation, args} | events.operations]
        })

      {:trace, _, :return_from, {Dune, :eval_string, 2}, result} ->
        collect_events(barrier, %{events | dune_results: [result | events.dune_results]})

      {:trace, _, _, _} ->
        collect_events(barrier, events)

      {:trace, _, _, _, _} ->
        collect_events(barrier, events)
    after
      @deadline -> flunk("Engine trace session did not deliver its completion barrier")
    end
  end

  defp assert_tree_stopped(events) do
    assert events.root_guardian == events.guardian
    assert events.cleanup_ack == {events.custodian, events.guardian}
    assert events.parents[events.root] == events.guardian

    descendants =
      Enum.filter(Map.keys(events.parents), &descendant?(&1, events.root, events.parents))

    # BoundedIO and real Dune parser/interpreter helpers must actually exist;
    # an Engine refusal before evaluation is not a cleanup test.
    assert length(descendants) >= 2

    # Include the broker and its pending facade Task, not just the root's
    # descendants: every process spawned by this tool's Engine run must stop.
    for pid <- Map.keys(events.parents) do
      unless Map.has_key?(events.exits, pid) do
        # Guardian/broker termination may be scheduled just after the Engine
        # returns. Await the actual exit event, never a quiet time window.
        assert_receive {:trace, ^pid, :exit, _}, @deadline
      end

      monitor = Map.fetch!(events.monitors, pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @deadline
      # Engine execution is intentionally not held inside the Dune interpreter:
      # its short-lived helpers may exit before this observer receives :spawn.
      # The real exit trace AND DOWN are required even in that case.
      refute Process.alive?(pid)
    end
  end

  defp descendant?(pid, ancestor, parents) do
    case Map.get(parents, pid) do
      ^ancestor -> true
      nil -> false
      parent -> descendant?(parent, ancestor, parents)
    end
  end
end
