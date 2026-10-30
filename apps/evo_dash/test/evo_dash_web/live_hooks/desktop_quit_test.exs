defmodule EvoDashWeb.LiveHooks.DesktopQuitTest do
  # Tests the desktop tray-quit confirm dialog end to end: the
  # EvoDashWeb.LiveHooks.DesktopQuit on-mount hook intercepts the three
  # desktop-quit events (before the LiveView's own handle_event/3) and drives
  # the shared app layout's `@desktop_quit_confirm` modal on any page.
  #
  # async: true — every test injects a global fake stop function via
  # Application.put_env(:evo_dash, :desktop_quit_stop_fun, ...) so the REAL
  # System.stop/0 (which would shut down the test VM) is NEVER invoked. The
  # prior value is SAVED and RESTORED in on_exit (never a blind delete_env) so
  # a sibling suite relying on that seam is unaffected. This file does NOT
  # isolate TaskRegistry/Store nor the config dir, so it may run concurrently.
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup do
    # The fake messages the TEST process (captured at setup time) — the seam
    # function runs inside the LiveView process, so self() there would be wrong.
    test_pid = self()

    # Save the prior seam value so we RESTORE it (a blind delete_env could
    # leave the VM-killing default in place for a sibling suite).
    original_stop_fun = Application.get_env(:evo_dash, :desktop_quit_stop_fun)

    Application.put_env(:evo_dash, :desktop_quit_stop_fun, fn ->
      send(test_pid, :desktop_stopped)
    end)

    # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
    # terminated by the per-test isolation above — reset it so one test's
    # sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    on_exit(fn ->
      if is_nil(original_stop_fun) do
        Application.delete_env(:evo_dash, :desktop_quit_stop_fun)
      else
        Application.put_env(:evo_dash, :desktop_quit_stop_fun, original_stop_fun)
      end
    end)

    :ok
  end

  describe "desktop quit confirm dialog" do
    test "full open/cancel/re-open/confirm cycle on the System page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/system")

      # The modal is not visible on initial render
      refute html =~ "Quit Genesis?"

      html = render_click(view, "desktop_quit_requested")

      assert html =~ "Quit Genesis?"
      assert html =~ "Running tasks will be interrupted and may lose progress"
      assert html =~ ~s(phx-click="desktop_quit_cancelled")
      assert html =~ ~s(phx-hook="DesktopQuitConfirm")

      # Regression pin for Rust re-emitting quit-requested (e.g. while the
      # dialog is already open): the second event must not error the view.
      assert render_click(view, "desktop_quit_requested") =~ "Quit Genesis?"

      # Cancel closes the modal and RE-ARMS the JS latch so a FUTURE tray Quit
      # is honored (see the DesktopQuit hook's dedup in assets/js/app.js).
      html = render_click(view, "desktop_quit_cancelled")
      refute html =~ "Quit Genesis?"
      assert_push_event(view, "desktop_quit_closed", %{})

      # A second tray quit must therefore open the dialog again.
      assert render_click(view, "desktop_quit_requested") =~ "Quit Genesis?"

      html = render_click(view, "desktop_quit_confirmed")

      # The injected fake ran (the REAL System.stop/0 was never invoked —
      # had it been, the test VM would be gone and this assertion unreachable).
      assert_received :desktop_stopped
      refute html =~ "Quit Genesis?"
      # Same re-arm contract as the cancel handler.
      assert_push_event(view, "desktop_quit_closed", %{})
    end

    test "passes unrelated events through and works on pages other than System", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      # The System page's own event still produces its own response (its stop
      # confirm modal), proving the hook passes unrelated events through.
      html = render_click(view, "request_stop")

      assert html =~ "Stop System?"
      refute html =~ "Quit Genesis?"
      refute_received :desktop_stopped

      # The dialog lives in the shared app layout, so it works on Welcome too.
      {:ok, welcome_view, html} = live(conn, ~p"/welcome")
      refute html =~ "Quit Genesis?"

      html = render_click(welcome_view, "desktop_quit_requested")
      assert html =~ "Quit Genesis?"
      assert html =~ ~s(phx-hook="DesktopQuitConfirm")

      refute render_click(welcome_view, "desktop_quit_cancelled") =~ "Quit Genesis?"
    end
  end
end
