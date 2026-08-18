defmodule EvoDashWeb.LiveHooks.DesktopQuitTest do
  # Tests the desktop tray-quit confirm dialog end to end: the
  # EvoDashWeb.LiveHooks.DesktopQuit on-mount hook intercepts the three
  # desktop-quit events (before the LiveView's own handle_event/3) and drives
  # the shared app layout's `@desktop_quit_confirm` modal on any page.
  #
  # async: false — every test injects a global fake stop function via
  # Application.put_env(:evo_dash, :desktop_quit_stop_fun, ...) so the REAL
  # System.stop/0 (which would shut down the test VM) is NEVER invoked.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # The fake messages the TEST process (captured at setup time) — the seam
    # function runs inside the LiveView process, so self() there would be wrong.
    test_pid = self()

    Application.put_env(:evo_dash, :desktop_quit_stop_fun, fn ->
      send(test_pid, :desktop_stopped)
    end)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :desktop_quit_stop_fun)
    end)

    :ok
  end

  describe "desktop quit confirm dialog" do
    test "desktop_quit_requested opens the modal on the System page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/system")

      # The modal is not visible on initial render
      refute html =~ "Quit Genesis?"

      html = render_click(view, "desktop_quit_requested")

      assert html =~ "Quit Genesis?"
      assert html =~ "Running tasks will be interrupted and may lose progress"
      assert html =~ ~s(phx-click="desktop_quit_cancelled")
      assert html =~ ~s(phx-hook="DesktopQuitConfirm")
    end

    test "desktop_quit_cancelled closes the modal and pushes desktop_quit_closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      # Open the modal first
      _html = render_click(view, "desktop_quit_requested")

      html = render_click(view, "desktop_quit_cancelled")

      refute html =~ "Quit Genesis?"
      # Re-arms the JS latch so a FUTURE tray Quit is honored (see the
      # DesktopQuit hook's dedup in assets/js/app.js).
      assert_push_event(view, "desktop_quit_closed", %{})
    end

    test "desktop_quit_confirmed calls the injected stop seam and closes the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      _html = render_click(view, "desktop_quit_requested")

      html = render_click(view, "desktop_quit_confirmed")

      # The injected fake ran (the REAL System.stop/0 was never invoked —
      # had it been, the test VM would be gone and this assertion unreachable).
      assert_received :desktop_stopped
      refute html =~ "Quit Genesis?"
      # Same re-arm contract as the cancel handler.
      assert_push_event(view, "desktop_quit_closed", %{})
    end

    test "duplicate desktop_quit_requested events are idempotent", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      # Regression pin for Rust re-emitting quit-requested (e.g. while the
      # dialog is already open): the second event must not error the view.
      _html = render_click(view, "desktop_quit_requested")
      html = render_click(view, "desktop_quit_requested")

      assert html =~ "Quit Genesis?"
    end

    test "requested → cancelled → requested re-opens the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      html = render_click(view, "desktop_quit_requested")
      assert html =~ "Quit Genesis?"

      html = render_click(view, "desktop_quit_cancelled")
      refute html =~ "Quit Genesis?"

      # The desktop_quit_closed push re-arms the JS latch — a second tray quit
      # must open the dialog again (documents why the JS dedup/latch exists).
      html = render_click(view, "desktop_quit_requested")
      assert html =~ "Quit Genesis?"
    end

    test "unrelated events still reach the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      # The System page's own event still produces its own response (its stop
      # confirm modal), proving the hook passes unrelated events through.
      html = render_click(view, "request_stop")

      assert html =~ "Stop System?"
      refute html =~ "Quit Genesis?"
      refute_received :desktop_stopped
    end

    test "modal can be opened on a page other than System", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/welcome")

      refute html =~ "Quit Genesis?"

      html = render_click(view, "desktop_quit_requested")

      # The dialog lives in the shared app layout, so it works on Welcome too.
      assert html =~ "Quit Genesis?"
      assert html =~ ~s(phx-hook="DesktopQuitConfirm")

      html = render_click(view, "desktop_quit_cancelled")

      refute html =~ "Quit Genesis?"
    end
  end
end
