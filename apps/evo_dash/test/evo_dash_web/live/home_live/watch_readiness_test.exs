defmodule EvoDashWeb.HomeLive.WatchReadinessTest.Agent do
  use EvoGit.Agent
  def system_prompt, do: "Watch readiness fixture"
  def available_tools, do: []
end

defmodule EvoDashWeb.HomeLive.WatchReadinessTest do
  use ExUnit.Case, async: false

  alias EvoDash.NodeContext
  alias EvoDashWeb.HomeLive.Watch
  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta, Store}
  alias EvoGit.Core.{ContextNode, PhyloGraphNode}

  # Every wait below synchronizes with REAL process work (session start, the
  # exchange worker, stream readiness, scheduler teardown). The shared host
  # swings 10-30x under load (see test/CONTEXT.md), so a fixed 1-3 s budget
  # exits on a loaded machine; the suite convention is the standard async
  # budget instead (e.g. `home_live_test.exs`'s `@async_wait_budget_ms`).
  @async_wait_budget_ms 30_000

  # Poll interval of `await_session_phase/3` — non-zero so the loop never spins
  # hot, tight enough that the residual wait is invisible.
  @poll_interval_ms 2

  # The fixture's OWN hold guard. Deliberately LARGER than the outer waits it
  # backs (the setup-held wait PLUS the readiness wait that runs while setup is
  # still held): a fixture that gave up first would answer
  # `{:error, :fixture_timeout}` and the test would report a misleading setup
  # error instead of the real failing assertion.
  @fixture_hold_timeout_ms @async_wait_budget_ms * 3

  # The worktree-manager release poll (teardown).
  @manager_release_poll_ms 10

  setup do
    old =
      for key <- [
            :home_agent_watch_runner,
            :home_agent_unwatch_runner,
            :home_agent_watch_start_timeout_ms
          ],
          into: %{},
          do: {key, Application.get_env(:evo_dash, key)}

    on_exit(fn ->
      for {key, value} <- old do
        if value == nil,
          do: Application.delete_env(:evo_dash, key),
          else: Application.put_env(:evo_dash, key, value)
      end
    end)

    :ok
  end

  test "a new real Session can finish slow setup before its first Watch snapshot" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "watch_readiness_#{id}")
    worktree = Path.join(root, "worker")
    File.mkdir_p!(worktree)
    {_, 0} = System.cmd("git", ["init", "--quiet", root])
    context = %ContextNode{path: "./", repo: root}

    spec = %EvoGit.AgentSpec{
      context_node: context,
      phylo_node: %PhyloGraphNode{repo: root, base_commit: nil, current_commit: nil},
      agent_module: __MODULE__.Agent,
      objective: "first input",
      opts: [task_tmpdir: root]
    }

    meta = %SchedMeta{id: id, depth: 0, spec: spec, task_id: "watch-#{id}", task_number: 1}
    Store.put_sched_meta(id, meta)

    Store.put_agent_state(id, %AgentState{
      context_node: context,
      repo_root: root,
      parent_id: nil,
      archive: false,
      llm_model: nil,
      max_depth: nil,
      max_turns: 128,
      max_retries: 0,
      task_local_id: 1,
      llm_context_window: 200_000
    })

    original_create = Application.get_env(:evo_git, :worktree_create_fun)

    Application.put_env(:evo_git, :worktree_create_fun, fn ^id, _, ^worktree, _, _ ->
      send(parent, {:setup_held, self()})

      receive do
        :release_setup -> {:ok, worktree}
      after
        @fixture_hold_timeout_ms -> {:error, :fixture_timeout}
      end
    end)

    ctx = [
      agent_id: id,
      depth: 0,
      repo_root: root,
      repo_id: "primary",
      worktree_path: worktree,
      retries: 0,
      spec: spec,
      meta: meta,
      scheduler: parent,
      session_mode: :interactive,
      exchange_opts: [
        llm_call: fn context, _, _, _, _ ->
          send(parent, {:model_entered, self()})

          receive do
            :finish_fixture ->
              answer = "Which project directory and task objective should I use?"

              message = %ReqLLM.Message{
                role: :assistant,
                content: [ReqLLM.Message.ContentPart.text(answer)]
              }

              response = %ReqLLM.Response{
                id: "watch-ready-answer",
                model: "test:model",
                context: ReqLLM.Context.append(context, message),
                message: message,
                usage: %{input_tokens: 10, output_tokens: 10, total_tokens: 20}
              }

              {:implicit_completion, response, answer}
          end
        end
      ]
    ]

    {:ok, session} = Session.start_link(ctx)
    Process.unlink(session)

    on_exit(fn ->
      Session.cancel(session, :force)
      await_manager_release(id)

      if original_create == nil,
        do: Application.delete_env(:evo_git, :worktree_create_fun),
        else: Application.put_env(:evo_git, :worktree_create_fun, original_create)

      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
      File.rm_rf(root)
    end)

    assert_receive {:setup_held, setup_worker}, @async_wait_budget_ms
    on_exit(fn -> send(setup_worker, :release_setup) end)

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn target, ^id, consumer ->
      result = NodeContext.register_agent_watcher(target, id, consumer)
      if result == {:error, {:bad_state, :starting}}, do: send(parent, :watch_observed_starting)
      result
    end)

    socket = socket(id) |> Watch.attach()

    on_exit(fn ->
      if Process.alive?(socket.assigns.chat_stream_worker),
        do: Process.exit(socket.assigns.chat_stream_worker, :kill)
    end)

    # The session answers a `:starting` watch with its pre-state snapshot and keeps
    # the registration, so a slow setup no longer defers the dashboard's first cut.
    assert_receive {:chat_stream_ready, target, token, ^id, result}, @async_wait_budget_ms
    # Both this attempt's notifications and the readiness reply are sent by the
    # ONE serial worker (the runner runs inline in it), so per-sender signal
    # order already proves no `:watch_observed_starting` is in flight; the exact
    # `phase: :starting` snapshot below is the same claim from the result side.
    refute_receive :watch_observed_starting, 0

    assert {:ok,
            {:ok,
             %EvoGit.Agent.Stream.Snapshot{
               phase: :starting,
               status: nil,
               seq: 0,
               messages: [],
               activity: %{phase: :idle, current_call: nil}
             }, 0}} = result

    assert {:noreply, ready} =
             EvoDashWeb.HomeLive.handle_info(
               {:chat_stream_ready, target, token, id, result},
               socket
             )

    # The admitted pre-state cut owns the stream: still setup-held, nothing else arrives.
    assert ready.assigns.chat_stream.delta.seq == 0
    assert ready.assigns.chat_status == :running
    await_worker_idle(socket.assigns.chat_stream_worker)
    refute_receive {:chat_stream_ready, _, _, ^id, _}, 0

    send(setup_worker, :release_setup)
    assert_receive {:model_entered, model_worker}, @async_wait_budget_ms
    # One registration, one readiness reply: the run continues on the SAME stream.
    await_worker_idle(socket.assigns.chat_stream_worker)
    refute_receive {:chat_stream_ready, _, _, ^id, _}, 0

    assert ready.assigns.chat_status == :running
    assert Watch.failure(ready.assigns) == nil
    assert Session.watching?(session)
    send(model_worker, :finish_fixture)
    settled = consume_until_idle(ready, id)
    assert settled.assigns.chat_stream.delta.seq > 0
    assert settled.assigns.chat_status == :idle
    assert settled.assigns.chat_task_status == :awaiting_input

    assert Enum.any?(
             settled.assigns.transcript,
             &(&1.role == :assistant and
                 &1.text == "Which project directory and task objective should I use?")
           )

    refute Enum.any?(settled.assigns.transcript, &Map.get(&1, :streaming, false))
    # The page parks on the yield DELTA, which the exchange worker publishes
    # BEFORE it refreshes the commit sha and sends its `{:exchange_finished, …}`
    # outcome, so the session can legitimately still answer `:running` for a
    # moment afterwards (a real git read, and a long one under load). Wait for
    # the outcome with the standard budget, then assert the EXACT snapshot.
    assert {:ok, %{phase: :awaiting_input}} = await_session_phase(session, :awaiting_input)
    Watch.detach(settled)
  end

  test "detaching during setup cancels readiness retries without a late result" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    counter = :atomics.new(1, [])

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      :atomics.add(counter, 1, 1)
      send(parent, :starting_attempt)
      {:error, {:bad_state, :starting}}
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)
    socket = socket(id) |> Watch.attach()
    on_exit(fn -> Process.exit(socket.assigns.chat_stream_worker, :kill) end)
    assert_receive :starting_attempt, @async_wait_budget_ms
    Watch.detach(socket)
    # `detach/1` queues `:unregister` into the serial worker, which serves it on
    # the spot (it is parked in the retry `receive`): once the worker is back in
    # its idle receive the readiness loop is GONE, so no further attempt can
    # even be emitted. That makes the probes below conclusive, where the two
    # fixed 100 ms observation windows could only ever have caught two absent
    # 50 ms-haps — a window is a bet on wall clock, a parked worker is a proof.
    await_worker_idle(socket.assigns.chat_stream_worker)
    # Drop the attempts the loop emitted before the unregister landed.
    flush_starting_attempts()
    count = :atomics.get(counter, 1)
    refute_receive :starting_attempt, 0
    assert :atomics.get(counter, 1) == count
    refute_receive {:chat_stream_ready, _, _, ^id, _}, 0
  end

  test "ordinary errors fail once and diagnostic logs contain only the error category" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      send(parent, :failed_watch_attempt)
      {:error, {:transport_failure, "private provider detail"}}
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        socket = socket(id) |> Watch.attach()
        assert_receive {:chat_stream_ready, _, _, ^id, _}, @async_wait_budget_ms
        assert_receive :failed_watch_attempt, @async_wait_budget_ms
        # The reply is sent by the serial worker AFTER the last attempt, so a
        # parked worker proves the transport failure was never retried.
        await_worker_idle(socket.assigns.chat_stream_worker)
        refute_receive :failed_watch_attempt, 0
        Process.exit(socket.assigns.chat_stream_worker, :kill)
      end)

    assert logs =~ "agent_id=#{id} reason=call_failed"
    refute logs =~ "private provider detail"
  end

  test "a session that stays starting reaches the deadline without an extra retry" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    Application.put_env(:evo_dash, :home_agent_watch_start_timeout_ms, 20)

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      send(parent, :deadline_watch_attempt)
      {:error, {:bad_state, :starting}}
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        socket = socket(id) |> Watch.attach()
        assert_receive :deadline_watch_attempt, @async_wait_budget_ms

        assert_receive {:chat_stream_ready, _, _, ^id, {:ok, {:error, {:bad_state, :starting}}}},
                       @async_wait_budget_ms

        # The deadline answer is the loop's LAST word; a parked worker means it
        # did not re-arm past the deadline.
        await_worker_idle(socket.assigns.chat_stream_worker)
        refute_receive :deadline_watch_attempt, 0
        Process.exit(socket.assigns.chat_stream_worker, :kill)
      end)

    assert logs =~ "reason=starting_timeout"
  end

  test "changing sessions cancels a pending startup registration" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    next_id = id + 1

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, target, _ ->
      if target == id do
        send(parent, :old_session_starting)
        {:error, {:bad_state, :starting}}
      else
        {:ok, %EvoGit.Agent.Stream.Snapshot{agent_id: target, phase: :running}, 0}
      end
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)
    socket = socket(id) |> Watch.attach()
    assert_receive :old_session_starting, @async_wait_budget_ms
    changed = socket |> Phoenix.Component.assign(session_id: next_id) |> Watch.attach()

    assert_receive {:chat_stream_ready, _, _, ^next_id, {:ok, {:ok, _, 0}}},
                   @async_wait_budget_ms

    # The retired registration never reaches its reply on the ONE serial worker
    # (its retry was abandoned for the queued unregister/re-register), so the
    # parked worker makes this conclusive with no observation window.
    await_worker_idle(socket.assigns.chat_stream_worker)
    refute_receive {:chat_stream_ready, _, _, ^id, _}, 0
    Watch.detach(changed)
    Process.exit(socket.assigns.chat_stream_worker, :kill)
  end

  test "consumer death stops readiness retries and the serial registration worker" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      send(parent, :consumer_starting_attempt)
      {:error, {:bad_state, :starting}}
    end)

    consumer =
      spawn(fn ->
        socket = socket(id) |> Watch.attach()
        send(parent, {:readiness_worker, socket.assigns.chat_stream_worker})

        receive do
          :leave -> :ok
        end
      end)

    assert_receive {:readiness_worker, worker}, @async_wait_budget_ms
    assert_receive :consumer_starting_attempt, @async_wait_budget_ms
    monitor = Process.monitor(worker)
    send(consumer, :leave)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @async_wait_budget_ms
  end

  defp consume_until_idle(socket, id) do
    if socket.assigns.chat_status == :idle do
      socket
    else
      receive do
        {:agent_delta, ^id, _, _} = delta ->
          {:noreply, updated} = EvoDashWeb.HomeLive.handle_info(delta, socket)
          consume_until_idle(updated, id)
      after
        @async_wait_budget_ms ->
          flunk("the real session yield did not settle the assistant spinner")
      end
    end
  end

  # Waits until the serial registration worker has finished the command it was
  # given and is parked in its idle `receive`.
  #
  # This is the suite's deterministic replacement for the fixed observation
  # windows that used to police "nothing else arrives": the worker is the ONLY
  # sender of `{:chat_stream_ready, …}` and of every readiness-attempt
  # notification, it serves commands strictly serially, and it can emit nothing
  # while parked — so a `refute_receive …, 0` AFTER this helper is conclusive
  # (no pending message, and none possible later), where a 100–200 ms window was
  # only ever a bet that the absent message would have shown up by then.
  # A dead worker is equally conclusive: it can never send again.
  defp await_worker_idle(worker, timeout \\ @async_wait_budget_ms) do
    await_worker_idle_loop(worker, System.monotonic_time(:millisecond) + timeout)
  end

  defp await_worker_idle_loop(worker, deadline) do
    idle? =
      case Process.info(worker, :current_function) do
        # parked in `worker/3`'s receive (`register_when_ready/5` while retrying)
        {:current_function, {EvoDashWeb.HomeLive.Watch, :worker, 3}} -> true
        {:current_function, _busy} -> false
        nil -> true
      end

    cond do
      idle? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the serial registration worker never went idle: #{inspect(worker)}")

      true ->
        Process.sleep(@poll_interval_ms)
        await_worker_idle_loop(worker, deadline)
    end
  end

  # Drops readiness attempts that the retry loop emitted before detach landed,
  # so a later zero-timeout refute observes only post-detach activity.
  defp flush_starting_attempts do
    receive do
      :starting_attempt -> flush_starting_attempts()
    after
      0 -> :ok
    end
  end

  # Polls the session's OWN snapshot (`Session.inspect/2` is a gen_statem call)
  # until it reports `phase`, and RETURNS that answer — the caller keeps its
  # exact-match assertion, so this only removes the "has the outcome landed
  # yet?" race, never the strictness. On timeout the LAST answer is returned and
  # the assertion fails against it (with the real snapshot in the message).
  defp await_session_phase(session, phase, timeout \\ @async_wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_session_phase_loop(session, phase, deadline)
  end

  defp await_session_phase_loop(session, phase, deadline) do
    result = Session.inspect(session)

    cond do
      match?({:ok, %{phase: ^phase}}, result) ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        result

      true ->
        Process.sleep(@poll_interval_ms)
        await_session_phase_loop(session, phase, deadline)
    end
  end

  defp await_manager_release(id) do
    await_manager_release(id, div(@async_wait_budget_ms, @manager_release_poll_ms))
  end

  defp await_manager_release(id, attempts) when attempts > 0 do
    if Map.has_key?(
         :sys.get_state(EvoGit.AgentScheduler.WorktreeManager, @async_wait_budget_ms).agents,
         id
       ) do
      Process.sleep(@manager_release_poll_ms)
      await_manager_release(id, attempts - 1)
    end
  end

  defp await_manager_release(_, _), do: :ok

  defp socket(id) do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        session_id: id,
        current_node: node(),
        current_node_id: nil,
        chat_stream: nil,
        stream_attach_seq: 0,
        chat_stream_worker: nil
      }
    }
  end
end
