defmodule EvoDashWeb.TestHelpers do
  @moduledoc """
  Shared helpers for the EvoDash test suite.

  Test support modules should not contain test logic — only setup, helpers,
  and shared configuration (see `test/support/CONTEXT.md`).

  The `flush_loading/4` poll interval is a CALL-TIME app-env seam
  (`:evo_dash, :flush_loading_poll_ms`, default 10 ms); the suite boots it at
  1 ms in `test_helper.exs` so the poll loop stops dominating the wall clock.
  """

  @doc """
  Waits for an async `Task.Supervisor`-backed LiveView load to finish and
  returns the rendered HTML.

  The load runs in a `Task.Supervisor` child — NOT a LiveView `start_async`
  task — so `render_async/2` returns immediately without waiting; polling the
  test proxy's cached tree (updated by channel diffs as they arrive) until
  `marker` disappears from the rendered HTML is the deterministic flush.

  If `marker` is still present when the timeout elapses, `flunk_message` is
  reported as an ExUnit failure.
  """
  def flush_loading(view, marker, flunk_message, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    flush_loop = fn flush_loop ->
      html = Phoenix.LiveViewTest.render(view)

      if html =~ marker do
        if System.monotonic_time(:millisecond) >= deadline do
          ExUnit.Assertions.flunk(flunk_message)
        else
          # Call-time app-env seam (default 10 ms; the suite boots it at 1 ms).
          Process.sleep(Application.get_env(:evo_dash, :flush_loading_poll_ms, 10))
          flush_loop.(flush_loop)
        end
      else
        html
      end
    end

    flush_loop.(flush_loop)
  end
end
