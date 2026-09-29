defmodule EvoDashWeb.TestHelpers do
  @moduledoc """
  Shared helpers for the EvoDash test suite.

  Test support modules should not contain test logic — only setup, helpers,
  and shared configuration (see `test/support/CONTEXT.md`).

  The `flush_loading/4` poll interval is a CALL-TIME app-env seam
  (`:evo_dash, :flush_loading_poll_ms`, default 10 ms); the suite boots it at
  1 ms in `test_helper.exs` so the poll loop stops dominating the wall clock.
  """

  # How many polls `flush_loading/4` may run between two renders while this
  # view's async load is still provably in flight (see `flush_loading/4`).
  @max_skipped_polls 8

  @doc """
  Waits for an async `Task.Supervisor`-backed LiveView load to finish and
  returns the rendered HTML.

  The load runs in a `Task.Supervisor` child — NOT a LiveView `start_async`
  task — so `render_async/2` returns immediately without waiting; polling the
  test proxy's cached tree (updated by channel diffs as they arrive) until
  `marker` disappears from the rendered HTML is the deterministic flush.

  A render is the expensive part of a poll iteration: `render/1` is a
  synchronous round-trip to the LiveView (which also lets it apply any queued
  diff) plus a full DOM-term copy and HTML build — measured ~0.2-2 ms per call
  on these pages, and the review page's long loads used to pay it once per
  millisecond-poll. While a child of `EvoDash.TaskSupervisor` spawned by THIS
  view is still alive the load is provably unfinished, so those iterations skip
  the render and only re-check the pending child: one supervisor children
  listing plus a `Process.info/2` read of `:"$callers"` (the entry
  `Task.Supervisor.start_child/2` records), i.e. tens of microseconds.

  The skip is BOUNDED to `@max_skipped_polls` polls in a row, and it never
  decides the outcome — the marker alone ends the wait (a load that clears it
  is observed on the next render, at most `@max_skipped_polls * poll interval`
  later; a marker that never clears still flunks at the deadline). The bound is
  load-bearing: a view can own children that outlive the load being waited for
  (e.g. `review_live_test.exs`'s deliberately blocking merge-check stubs, which
  live 30 s on the same supervisor), so an unbounded "some child is alive → keep
  sleeping" gate would stall such a flush for the whole timeout. With the
  bound, a wrong pending signal only costs a render — never a wrong `flunk`,
  never a hang, and never a change in the returned HTML.

  Measured effect (raw numbers in `test/support/CONTEXT.md`): the review
  suite's flush renders drop 1220 → 263 per run (~4% less BEAM user CPU) while
  the wall clock is unchanged — those renders were never on the critical path,
  which is the async load's own duration plus the poll cadence. This is a
  render/CPU-work reduction, not a wall-clock optimization.

  If `marker` is still present when the timeout elapses, `flunk_message` is
  reported as an ExUnit failure.
  """
  def flush_loading(view, marker, flunk_message, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    # Seeding `polls_since_render` at the bound forces the FIRST iteration to
    # render, so an already-finished load costs exactly the single render it
    # costs today and returns immediately.
    await_loading(view, marker, flunk_message, deadline, @max_skipped_polls)
  end

  defp await_loading(view, marker, flunk_message, deadline, polls_since_render) do
    if polls_since_render < @max_skipped_polls and load_pending?(view.pid) and
         System.monotonic_time(:millisecond) < deadline do
      # The load cannot have finished (its child is still alive) — no render.
      Process.sleep(poll_interval())
      await_loading(view, marker, flunk_message, deadline, polls_since_render + 1)
    else
      html = Phoenix.LiveViewTest.render(view)

      cond do
        not (html =~ marker) ->
          html

        System.monotonic_time(:millisecond) >= deadline ->
          ExUnit.Assertions.flunk(flunk_message)

        true ->
          Process.sleep(poll_interval())
          await_loading(view, marker, flunk_message, deadline, 1)
      end
    end
  end

  # Call-time app-env seam (default 10 ms; the suite boots it at 1 ms).
  defp poll_interval, do: Application.get_env(:evo_dash, :flush_loading_poll_ms, 10)

  # Whether any `EvoDash.TaskSupervisor` child was spawned by this view — true
  # while an async page load this view started is still running. Total: a child
  # that already exited (or any non-conforming entry) reports no `:"$callers"`
  # and is treated as "not pending" (fail open toward rendering), and a missing
  # supervisor yields no pending load at all.
  defp load_pending?(view_pid) when is_pid(view_pid) do
    case Process.whereis(EvoDash.TaskSupervisor) do
      nil -> false
      _ -> Enum.any?(Task.Supervisor.children(EvoDash.TaskSupervisor), &view_task?(&1, view_pid))
    end
  end

  defp view_task?(pid, view_pid) when is_pid(pid), do: view_pid in task_callers(pid)
  defp view_task?(_pid, _view_pid), do: false

  # `Task.Supervisor.start_child/2` (and `async_nolink/2`) records the spawning
  # process followed by ITS callers in the child's `:"$callers"` process
  # dictionary entry, so matching it against the view pid targets exactly this
  # view's tasks — a leftover task from another test is never mistaken for it.
  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      nil -> []
    end
  end
end
