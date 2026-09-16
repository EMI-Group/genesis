defmodule EvoGit.AgentScheduler.PubSubTest do
  @moduledoc """
  Tests for the supervised broadcast throttle `EvoGit.AgentScheduler.PubSub.Throttle`.

  The throttle coalesces rapid `:schedule` casts into ONE `{:agents_updated, node}`
  broadcast on the `"agents"` topic at most 200ms after the last cast — the
  trailing element is the emitting BEAM node (`node()`). It runs
  as a standard child of the application's `EvoGit.Supervisor` (declared in
  `EvoGit.Application`'s children after `Phoenix.PubSub`, `:permanent`
  restart).

  Waits for the flush are **event-driven**: the throttle clears its pending
  timer reference exactly when it flushes, so `await_flush/0` polls the
  throttle's own GenServer state (`nil` == flushed) instead of guessing `2x`
  the 200ms debounce with a fixed wall-clock window. The 200ms debounce is
  best-effort — under CPU load the timer and its delivery drift well past any
  fixed multiple of it — so a fixed window is inherently racy while polling the
  actual flush event is not.

  Uses `async: false` because the throttle process and the `EvoGit.PubSub`
  topic are global — shared with the running application and other test
  modules. Mailbox drains before each measurement window keep the assertions
  deterministic even if other (serialized) tests broadcast to the same topic.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.PubSub.Throttle

  @topic PubSub.agent_topic()

  # Liveness ceiling for the event-driven flush wait. This is NOT a debounce
  # budget: `await_flush/0` returns as soon as the throttle's own state shows
  # the flush happened, so this only trips if the throttle is genuinely wedged
  # (never flushes) — not merely slow.
  @flush_liveness_ms 15_000

  setup do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)
    # The :evo_git app is started by Mix in test mode
    # (mod: {EvoGit.Application, []} in mix.exs), so the Throttle is already
    # running under EvoGit.Supervisor — no manual start needed here.
    # Flush any messages broadcast before this test subscribed
    drain_mailbox()

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(EvoGit.PubSub, @topic)
    end)

    :ok
  end

  defp drain_mailbox do
    receive do
      _msg -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  # Waits until the throttle has performed its trailing flush, observed on the
  # throttle's OWN state rather than a fixed wall-clock multiple of the 200ms
  # debounce. `handle_info(:flush, _)` clears the stored timer ref, so a `nil`
  # state means the flush has run and its `{:agents_updated, node}` broadcast
  # has already been enqueued into every subscriber's mailbox.
  #
  # The `:sys.get_state/1` message is FIFO-ordered after the
  # `broadcast_agents_updated/0` casts issued earlier by this same process, so
  # the first read reflects those casts (a timer ref) and the wait ends exactly
  # when the flush clears it. This is immune to the CPU-load-induced timer and
  # delivery drift that makes a fixed `assert_receive` window flaky.
  defp await_flush do
    deadline = System.monotonic_time(:millisecond) + @flush_liveness_ms
    do_await_flush(deadline)
  end

  defp do_await_flush(deadline) do
    case :sys.get_state(Throttle) do
      nil ->
        :ok

      ref when is_reference(ref) ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("throttle did not flush within #{@flush_liveness_ms}ms — is it wedged?")
        else
          Process.sleep(2)
          do_await_flush(deadline)
        end
    end
  end

  test "rapid broadcasts collapse into a single {:agents_updated, node} message" do
    PubSub.broadcast_agents_updated()
    PubSub.broadcast_agents_updated()
    PubSub.broadcast_agents_updated()

    # Wait for the throttle's own trailing flush (event-driven) instead of
    # guessing `2x` the @throttle_ms floor: under load the 200ms timer expires
    # late (measured well past 400ms), so a fixed window sits on the boundary.
    await_flush()

    # The single coalesced broadcast is already enqueued by the time the flush
    # cleared the throttle's timer, so this matches immediately.
    assert_receive {:agents_updated, bcast_node}, 1_000
    assert bcast_node == node()

    # The three back-to-back casts must not produce a second flush. A duplicate
    # flush from OUR casts would have been armed alongside the first (they were
    # issued back-to-back, each cancelling and re-arming the pending timer) and
    # delivered ~@throttle_ms later, so any duplicate is already in the mailbox
    # by now — `refute_receive` fails on an already-delivered match.
    refute_receive {:agents_updated, _node}, 100
  end

  test "broadcast without a throttle process falls back to immediate dispatch with the node element" do
    throttle_pid = Process.whereis(Throttle)
    assert is_pid(throttle_pid)

    # Temporarily unregister the name so broadcast_agents_updated/0 sees a nil
    # throttle and dispatches immediately (the fallback path). The supervisor
    # tracks the child by pid, so unregistering the NAME is supervision-safe.
    Process.unregister(Throttle)
    on_exit(fn -> Process.register(throttle_pid, Throttle) end)

    PubSub.broadcast_agents_updated()

    # The fallback broadcasts synchronously in the caller, so the message is in
    # our mailbox before this returns — the short timeout just pins that the
    # throttled path was not taken (a throttle flush would take ≥@throttle_ms).
    assert_receive {:agents_updated, bcast_node}, 100
    assert bcast_node == node()
  end

  test "throttle process is restarted by its supervisor and broadcasts resume" do
    old_pid = Process.whereis(Throttle)
    assert is_pid(old_pid)

    Process.exit(old_pid, :kill)

    # EvoGit.Supervisor (one_for_one) restarts the child (:permanent restart)
    new_pid = wait_for_restart(old_pid, 100)
    assert is_pid(new_pid)
    assert new_pid != old_pid

    # The restarted throttle must serve broadcasts again. Wait on its own state
    # (event-driven) rather than a fixed `2x` debounce window.
    drain_mailbox()
    PubSub.broadcast_agents_updated()
    await_flush()
    assert_receive {:agents_updated, bcast_node}, 1_000
    assert bcast_node == node()
  end

  test "throttle is a supervised child of EvoGit.Supervisor" do
    throttle_pid = Process.whereis(Throttle)
    assert is_pid(throttle_pid)

    # The Throttle must appear in EvoGit.Supervisor's child list with its
    # module as child id and :worker type.
    assert Enum.any?(Supervisor.which_children(EvoGit.Supervisor), fn
             {EvoGit.AgentScheduler.PubSub.Throttle, pid, :worker, _} ->
               is_pid(pid) and pid == throttle_pid

             _ ->
               false
           end)
  end

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(Throttle) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)

      _ ->
        nil
    end
  end
end
