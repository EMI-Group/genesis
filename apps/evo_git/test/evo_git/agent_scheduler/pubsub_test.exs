defmodule EvoGit.AgentScheduler.PubSubTest do
  @moduledoc """
  Tests for the supervised broadcast throttle `EvoGit.AgentScheduler.PubSub.Throttle`.

  The throttle coalesces rapid `:schedule` casts into ONE `{:agents_updated, node}`
  broadcast on the `"agents"` topic at most 200ms after the last cast — the
  trailing element is the emitting BEAM node (`node()`). It runs
  as a standard child of the application's `EvoGit.Supervisor` (declared in
  `EvoGit.Application`'s children after `Phoenix.PubSub`, `:permanent`
  restart).

  Flushes are driven **synchronously** instead of being awaited: the
  `:schedule` casts are FIFO-ordered ahead of a `:sys.get_state/1` system
  message, so the state read after N casts already shows the ONE pending
  debounce timer (each cast cancels and re-arms the previous one).
  `drive_pending_flush/0` cancels that single timer and delivers the `:flush`
  it was going to send — the exact debounce event, without waiting out the
  real 200ms window. The coalescing contract is unchanged: N casts must yield
  ONE pending timer and therefore exactly ONE `{:agents_updated, node}`
  broadcast (three per-cast broadcasts would arrive as three messages), and
  the cancelled timer can never produce a second one.

  This also removes the wall-clock dependency the old `2x`-debounce polling
  had: under CPU load a timer and its delivery drift well past any fixed
  multiple of 200ms, while the synchronous flush has no window to miss.

  Uses `async: false` because the throttle process and the `EvoGit.PubSub`
  topic are global — shared with the running application and other test
  modules. Mailbox drains before each measurement window keep the assertions
  deterministic even if other (serialized) tests broadcast to the same topic.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.PubSub.Throttle

  @topic PubSub.agent_topic()

  # Liveness ceiling for the negative assertions below. It is NOT a debounce
  # budget: the pending timer is CANCELLED by `drive_pending_flush/0` before
  # it can fire, so nothing legitimate can broadcast here at all — this only
  # catches a duplicate/bugged flush, delivered from the same node (a local
  # message delivery takes microseconds).
  @no_duplicate_ms 25

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

  # Drives the throttle's ONE pending trailing flush synchronously.
  #
  # The caller's `broadcast_agents_updated/0` calls are `GenServer.cast`s from
  # THIS process and the `:sys.get_state/1` below is FIFO-ordered behind them,
  # so the state read already reflects every cast: a single timer reference
  # (`handle_cast(:schedule, _)` cancels the previous timer and re-arms it).
  # Cancelling that one reference and delivering the `:flush` it was going to
  # send reproduces the debounce event immediately, and the cancelled timer can
  # no longer deliver a second one.
  #
  # If the debounce already elapsed on its own (a very slow host stalled this
  # process for >200ms between the cast and the state read), the state is `nil`
  # and the natural flush has already broadcast — nothing to drive.
  defp drive_pending_flush do
    pid = Process.whereis(Throttle)
    assert is_pid(pid)

    case :sys.get_state(pid) do
      nil ->
        :already_flushed

      ref when is_reference(ref) ->
        # `false` == the timer already fired; its flush is then in the queue.
        if Process.cancel_timer(ref), do: send(pid, :flush)
        :driven
    end
  end

  test "rapid broadcasts collapse into a single {:agents_updated, node} message" do
    PubSub.broadcast_agents_updated()
    PubSub.broadcast_agents_updated()
    PubSub.broadcast_agents_updated()

    # Drive the ONE collapsing flush now instead of waiting out the 200ms
    # debounce (see drive_pending_flush/0).
    drive_pending_flush()

    # The single coalesced broadcast is already enqueued by the time the flush
    # ran, so this matches immediately.
    assert_receive {:agents_updated, bcast_node}, 1_000
    assert bcast_node == node()

    # The flush cleared the pending timer reference, and it was the ONLY one:
    # the three back-to-back casts each cancelled + re-armed the same pending
    # timer instead of arming one timer each.
    assert :sys.get_state(Throttle) == nil

    # ... so no second flush can follow. Any duplicate would already be in the
    # mailbox by now (`refute_receive` fails on an already-delivered match),
    # and the cancelled timer can no longer fire.
    refute_receive {:agents_updated, _node}, @no_duplicate_ms
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
    # throttled path was not taken (a throttled flush would take ≥ the 200ms
    # debounce).
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

    # The restarted throttle must serve broadcasts again. Drive its pending
    # flush synchronously rather than waiting a fixed debounce window.
    drain_mailbox()
    PubSub.broadcast_agents_updated()
    drive_pending_flush()
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
