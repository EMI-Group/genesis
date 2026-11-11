defmodule EvoDashWeb.AgentsLiveTaskBroadcastTest do
  # `async: false` — the ONE assertion here is NEGATIVE and global-quiet: a
  # foreign-node `{:task_updated, ...}` must never schedule NodeAware's
  # debounce, i.e. NO `"tasks"` broadcast may reach this socket for the whole
  # sampling window. `EvoDashWeb.LiveHooks.NodeAware.on_mount/4` (registered by
  # `use EvoDashWeb, :live_view`) subscribes every mounted page to the SHARED
  # `"tasks"` PubSub topic, so in an `async: true` cohort ANY concurrent
  # module's local-node broadcast arms this view's debounce and the sample
  # intermittently fails — reproduced in full-suite runs while the file alone
  # passed 5/5.
  #
  # Forcing global: the shared `"tasks"` PubSub topic (the root test-runtime
  # policy lists "a shared PubSub topic it asserts on" as a legitimate reason to
  # run sync). Running alone in the serial tail makes "nothing ever arms it"
  # TRUE. Never widen the 40ms sampling window to hide a real re-arm.
  #
  # The matching-node half of this contract (every task-broadcast shape crashes
  # nothing and schedules a debounced reload) stays in the ASYNC
  # `agents_live_test.exs`: a positive assertion is immune to a foreign
  # broadcast.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Exit-safe `:sys.get_state/2` timeout for `assigns/1`: the LiveView can be
  # starved for seconds on a loaded host, where the 5 s default would turn a
  # state read into an `(EXIT) time out` failure.
  @assigns_timeout_ms 30_000

  setup do
    # ActiveTasks is a process-less public ETS table shared by the whole run.
    # This module is sync, but clearing only the local `{nil, node()}` context
    # keeps the established shape (never a whole-table reset).
    EvoDash.ActiveTasks.invalidate(nil, node())
    :ok
  end

  test "foreign-node {:task_updated, _, :finalizing, remote} is ignored (no crash, no reload)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agents")
    flush_agents_load(view)

    # Event from a DIFFERENT BEAM node: the node filter must drop it BEFORE
    # the debounce is scheduled.
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      "tasks",
      {:task_updated, "test-finalizing", :finalizing, :remote@elsewhere}
    )

    # The :sys.get_state read behind assigns/1 is a mailbox round-trip, so it
    # returns only AFTER the LiveView processed the broadcast above — the
    # event was definitely handled, not still in flight.
    assert assigns(view)[:tasks_reload_pending] == false

    # Then sample across the debounce window (:node_aware_reload_debounce_ms,
    # 10ms in tests): the reload-pending flag must never become TRUE. 40ms is
    # 4x the debounce — the whole window in which a spurious schedule could
    # fire — where the previous 400ms window made this the slowest test in the
    # file without strengthening the assertion.
    deadline = System.monotonic_time(:millisecond) + 40

    check_no_reload = fn check_no_reload ->
      assert assigns(view)[:tasks_reload_pending] == false

      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        check_no_reload.(check_no_reload)
      end
    end

    check_no_reload.(check_no_reload)

    html = render(view)
    assert is_binary(html)
    assert html =~ "Agent Tree"
  end

  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  # Waits for the async page load to finish (the shared helper the async module
  # uses too).
  defp flush_agents_load(view, timeout \\ 30_000),
    do:
      EvoDashWeb.TestHelpers.flush_loading(
        view,
        "Loading agents…",
        "timed out waiting for the async agents load to finish",
        timeout
      )
end
