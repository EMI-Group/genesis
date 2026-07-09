defmodule EvoDashWeb.SystemLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "system page" do
    test "renders the system page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "System"
    end

    test "shows configuration guidance section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Example Configuration"
      assert html =~ "config.toml"
    end

    test "shows CLI usage examples", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Example Usage"
      assert html =~ "genesis"
      assert html =~ "evolve"
    end

    test "shows FAQ section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Frequently Asked Questions"
      assert html =~ "How do I set my API key?"
    end

    test "shows credentials reference", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Credentials Reference"
      assert html =~ "credentials.toml"
    end
  end

  # NOTE: The "confirm_restart" event handler is intentionally NOT unit-tested.
  # It calls System.restart/0, which tears down and restarts the entire BEAM VM
  # and would crash the ExUnit test run (killing all other tests along with it).
  # Likewise, "confirm_stop" calls System.stop/0 which shuts down the VM and is
  # also not unit-tested. We only test the surrounding modal open/cancel flows,
  # which are safe.
  describe "scheduler and system controls" do
    test "scheduler control renders with the pause button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ ~s(phx-click="toggle_pause")
    end

    test "System Control section renders with the Restart System button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "System Control"
      assert html =~ "Restart System"
      assert html =~ ~s(phx-click="request_restart")
    end

    test "request_restart opens the confirmation modal", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/system")

      # The modal is not visible on initial render
      refute html =~ "Restart System?"

      html = render_click(view, "request_restart")

      assert html =~ "Restart System?"
    end

    test "cancel_restart closes the confirmation modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      # Open the modal first
      _html = render_click(view, "request_restart")

      html = render_click(view, "cancel_restart")

      refute html =~ "Restart System?"
    end

    test "System Control section renders with the Stop System button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Stop System"
      assert html =~ ~s(phx-click="request_stop")
    end

    test "request_stop opens the confirmation modal", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/system")

      # The modal is not visible on initial render
      refute html =~ "Stop System?"

      html = render_click(view, "request_stop")

      assert html =~ "Stop System?"
    end

    test "cancel_stop closes the confirmation modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      # Open the modal first
      _html = render_click(view, "request_stop")

      html = render_click(view, "cancel_stop")

      refute html =~ "Stop System?"
    end

    test "confirm_restart handler is guarded when remote (no System.restart called)" do
      # BUG 1 fix: confirm_restart must NOT call System.restart/0 when remote.
      # The entry handler (request_restart) guards, the template disables the
      # button, and handle_params clears the flag on node switch — but the
      # confirm handler itself MUST also guard as defense-in-depth (a stale
      # modal or crafted event could bypass the UI guards).
      #
      # We test the guard directly by invoking the handle_event/3 callback with
      # a socket that has remote?: true. This avoids both booting a real remote
      # node AND calling System.restart/0 (which would tear down the test VM).
      # The handler should return a flash error and close the modal.
      alias EvoDashWeb.SystemLive

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: nil, flash: %{}, remote?: true, show_restart_confirm: true}
      }

      assert {:noreply, result_socket} =
               SystemLive.handle_event("confirm_restart", %{}, socket)

      # Modal closed
      refute result_socket.assigns.show_restart_confirm
    end

    test "confirm_stop handler is guarded when remote (no System.stop called)" do
      # BUG 1 fix: same defense-in-depth guard for confirm_stop.
      alias EvoDashWeb.SystemLive

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: nil, flash: %{}, remote?: true, show_stop_confirm: true}
      }

      assert {:noreply, result_socket} =
               SystemLive.handle_event("confirm_stop", %{}, socket)

      # Modal closed
      refute result_socket.assigns.show_stop_confirm
    end
  end
end
