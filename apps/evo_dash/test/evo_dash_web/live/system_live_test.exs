defmodule EvoDashWeb.SystemLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as dashboard_live_test.exs / welcome_live_test.exs).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "system page" do
    test "renders the system page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "System"
    end

    test "LLM Test in Settings link carries &node=<id> when a remote node is active", %{
      conn: conn
    } do
      # The settings link already carries a query string (`?category=llm`), so
      # the node param must be appended with `&node=` — `with_node_param/2`
      # would append with `?` and the browser would silently drop the node
      # param (parsing it as part of the `category` value), landing the remote
      # user on the LOCAL settings page.
      #
      # Same pattern as dashboard_live_test.exs: isolate the config dir via
      # XDG_CONFIG_HOME so the saved target never touches the developer's real
      # ~/.config/genesis/, and register a fake connection manager so the
      # `?node=` param resolves to a connected remote context.
      original_xdg = System.get_env("XDG_CONFIG_HOME")

      tmp_xdg =
        Path.join(
          System.tmp_dir!(),
          "evogit_system_live_xdg_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_xdg)
      System.put_env("XDG_CONFIG_HOME", tmp_xdg)

      on_exit(fn ->
        if original_xdg do
          System.put_env("XDG_CONFIG_HOME", original_xdg)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf!(tmp_xdg)
      end)

      id = "test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: "Test Target"})

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.RemoteConnections.delete(id)
        rescue
          _ -> :ok
        end
      end)

      start_supervised!(
        {EvoDashWeb.SystemLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/system?node=" <> id)

      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:remote?] == true

      # The system self-check runs async and gates the LLM Test row on
      # completion; drive it deterministically so the link renders.
      send(view.pid, {:system_checks_result, EvoGit.SystemCheck.run_all_checks()})
      html = render(view)

      # The `~p` sigil percent-encodes the interpolated query suffix:
      # `%26node%3D` decodes to `&node=` in the browser, so the node param is
      # preserved alongside the existing `category=llm` query — unlike the old
      # `?node=` form, which the browser parsed into the `category` value and
      # silently dropped.
      assert html =~ ~s(href="/settings?category=llm%26node%3D#{id}")
      # The old (would-be-dropped) `?node=` form must never be emitted
      refute html =~ ~s(href="/settings?category=llm?node=)
    end
  end

  # NOTE: The LOCAL "confirm_restart"/"confirm_stop" event handlers are
  # intentionally NOT unit-tested. They call System.restart/0 / System.stop/0,
  # which tears down / shuts down the entire BEAM VM and would crash the ExUnit
  # test run (killing all other tests along with it). The REMOTE variants are
  # tested via direct handle_event/3 invocation with a non-local current_node —
  # the erpc call to a non-existent remote node fails gracefully inside
  # restart_remote/stop_remote (which always returns :ok), so it's safe to run.
  # We also test the surrounding modal open/cancel flows, which are safe.
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

    test "confirm_restart restarts the remote node via RPC when remote" do
      # ISSUE 2 fix: confirm_restart now operates on the REMOTE node via
      # EvoDash.NodeContext.restart_remote/1 (erpc RPC) instead of refusing.
      #
      # We test by invoking the handle_event/3 callback with a socket that has
      # remote?: true and a non-local current_node. This avoids calling
      # System.restart/0 on the LOCAL test VM (which would tear it down). The
      # erpc call to the non-existent remote node fails gracefully inside
      # restart_remote/1 (it normalizes the node-down error and always returns
      # :ok), so this is safe to run. The handler should close the modal and
      # show an info flash about the remote node restarting.
      alias EvoDashWeb.SystemLive

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote?: true,
          current_node: :nonexistent_remote@host,
          show_restart_confirm: true
        }
      }

      assert {:noreply, result_socket} =
               SystemLive.handle_event("confirm_restart", %{}, socket)

      # Modal closed
      refute result_socket.assigns.show_restart_confirm
      # Info flash about remote restart (not an error flash)
      assert %{"info" => _} = result_socket.assigns.flash
    end

    test "confirm_stop stops the remote node via RPC when remote" do
      # ISSUE 2 fix: confirm_stop now operates on the REMOTE node via
      # EvoDash.NodeContext.stop_remote/1 (erpc RPC) instead of refusing.
      alias EvoDashWeb.SystemLive

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote?: true,
          current_node: :nonexistent_remote@host,
          show_stop_confirm: true
        }
      }

      assert {:noreply, result_socket} =
               SystemLive.handle_event("confirm_stop", %{}, socket)

      # Modal closed
      refute result_socket.assigns.show_stop_confirm
      # Info flash about remote stop (not an error flash)
      assert %{"info" => _} = result_socket.assigns.flash
    end
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.DashboardLiveTest.ConnectionManager). Registers a status so
# `EvoDash.NodeContext.connection_status/1` resolves the `?node=` param to a
# connected remote context without any real SSH/distribution machinery. The
# process dies (and its Registry entry is auto-removed) at test end via
# `start_supervised!`.
defmodule EvoDashWeb.SystemLiveTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end
