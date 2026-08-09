defmodule EvoDashWeb.SystemLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as dashboard_live_test.exs / welcome_live_test.exs).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Waits until the async self-check task spawned on mount has processed its
  # real `{:system_checks_result, _}` (i.e. `system_checks_status` leaves
  # `:checking`). The handler simply assigns, so the LAST such message
  # processed wins — awaiting the real result first guarantees an injected
  # result below is deterministically processed last (FIFO mailbox), no matter
  # how fast/slow the real check completes on the host.
  defp await_checks_done(view, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_checks_done(view, deadline)
  end

  defp do_await_checks_done(view, deadline) do
    cond do
      assigns(view)[:system_checks_status] == :done ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("system self-check did not complete within the test timeout")

      true ->
        Process.sleep(10)
        do_await_checks_done(view, deadline)
    end
  end

  # Injects a system-checks result directly into the LiveView mailbox and
  # renders. The self-check rows only render once `system_checks_status` leaves
  # `:checking`; the injected result is processed after the real async one, so
  # it is what the assertions see (same send+render pattern as the
  # "LLM Test in Settings link" test, made deterministic by `await_checks_done`).
  defp render_with_checks(view, result) do
    await_checks_done(view)
    send(view.pid, {:system_checks_result, result})
    render(view)
  end

  # Builds a full checks result with the given nix check map (all other checks
  # come from the real host, so the nix row assertions are independent of host
  # config).
  defp render_with_nix_check(view, nix_check) do
    render_with_checks(view, %{EvoGit.SystemCheck.run_all_checks() | nix: nix_check})
  end

  # Deterministic all-OK checks map for the self-check grid/banner assertions.
  # Every check passes, so the merged health light is green regardless of the
  # host (a real `run_all_checks/0` on CI may legitimately report failing
  # tools/config/sandbox). The sandbox map is a safe `:none` backend — with the
  # :windows platform override the cell is hidden and the map is never read by
  # the template, but supplying it keeps the assign well-formed.
  defp all_ok_checks do
    %{
      config: %{ok?: true, missing: [], warnings: [], validation_errors: []},
      tools: %{
        git: %{available: true, path: "/usr/bin/git", version: "git version 2.0.0", error: nil},
        rg: %{available: true, path: "/usr/bin/rg", version: "ripgrep 14.1.0", error: nil}
      },
      sandbox: %{
        backend: :none,
        enabled: false,
        capabilities: %{filesystem_isolation: false, resource_limits: false, backend: :none},
        systemd_available: false,
        sandbox_exec_available: false
      },
      supervisor: %{healthy: true, evo_git: [], evo_dash: []},
      nix: %{
        enabled: false,
        available: false,
        flake_present: false,
        dev_env_built: false,
        error: nil
      }
    }
  end

  # `:platform_os_override` is the injection seam for `os_for_node/1` (checked
  # BEFORE host detection): set to :windows it hides the Sandbox cell, so the
  # merged health banner never depends on the host's sandbox state (on Linux CI
  # the real sandbox check can be :error, which would hard-fail the banner).
  # Safe only in `async: false` files; cleaned up via `on_exit`.
  defp set_windows_platform do
    Application.put_env(:evo_dash, :platform_os_override, :windows)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :platform_os_override)
    end)
  end

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

  describe "platform gating" do
    # These tests use the `:platform_os_override` injection seam in
    # `EvoDashWeb.PlatformInfo.os_for_node/1` (checked BEFORE host detection),
    # which is only safe in `async: false` files. The overrides are cleaned up
    # via `on_exit`. The injected `{:system_checks_result, _}` messages make the
    # nix/sandbox row assertions independent of host config.
    #
    # NOTE on markers: the HEEx template keeps its HTML comments in the rendered
    # output (`<!-- Nix Environment Row ... -->`, `<!-- Sandbox Row ... -->`),
    # so plain "Nix Environment"/"Sandbox" substrings are present even when the
    # rows are hidden. Assertions therefore use row-only markers: the title span
    # (`>Nix Environment</span>` / `>Sandbox</span>`) and row-only detail
    # strings / icons ("flake.nix", "Flake valid", "hero-lock-closed").

    test "Nix Environment row is hidden when nix is disabled in config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      html =
        render_with_nix_check(view, %{
          enabled: false,
          available: true,
          flake_present: false,
          dev_env_built: false,
          error: nil
        })

      refute html =~ ">Nix Environment</span>"
      # Row-only detail strings — never rendered when the row is hidden.
      refute html =~ "flake.nix"
      refute html =~ "Flake valid"
    end

    test "Nix Environment row is hidden when the nix binary is unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/system")

      html =
        render_with_nix_check(view, %{
          enabled: true,
          available: false,
          flake_present: false,
          dev_env_built: false,
          error: nil
        })

      refute html =~ ">Nix Environment</span>"
      refute html =~ "flake.nix"
      refute html =~ "Flake valid"
    end

    test "Nix Environment row is shown when nix is enabled and the binary is available", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/system")

      html =
        render_with_nix_check(view, %{
          enabled: true,
          available: true,
          flake_present: true,
          dev_env_built: true,
          error: nil
        })

      assert html =~ ">Nix Environment</span>"
      # Nix-specific detail strings from the row template (the generic
      # "Enabled"/"Disabled" strings also appear in the Sandbox row, so assert
      # on strings unique to the Nix row).
      assert html =~ "flake.nix"
      assert html =~ "Flake valid"
    end

    test "Sandbox row is hidden when the platform is Windows", %{conn: conn} do
      # `:platform_os_override` is the injection seam for `os_for_node/1`: set
      # to :windows it gates the Sandbox row off regardless of the host OS (on
      # CI the host is Linux, which would normally show the row).
      Application.put_env(:evo_dash, :platform_os_override, :windows)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert assigns(view)[:platform_os] == :windows

      # Checks must complete for any row to render at all — inject the real
      # result so `system_checks_status` leaves `:checking` (same pattern as
      # the "LLM Test in Settings link" test).
      html = render_with_checks(view, EvoGit.SystemCheck.run_all_checks())

      # The check grid renders the "Sandbox" row title only when the row is
      # shown; the `hero-lock-closed` icon is unique to that row.
      refute html =~ ">Sandbox</span>"
      refute html =~ "hero-lock-closed"
    end

    test "Sandbox row is shown when the platform is macOS", %{conn: conn} do
      Application.put_env(:evo_dash, :platform_os_override, :macos)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert assigns(view)[:platform_os] == :macos

      # Core assertion: row visibility. NOTE (behavior-vs-plan discrepancy):
      # the :macos override only gates row VISIBILITY — the backend badge text
      # (`Status.format_backend/1`) comes from the REAL host check result, so
      # on a Linux CI host it shows "systemd-run (Linux)" even under the
      # override. Only a second injected :sandbox_exec check map makes the
      # badge deterministic.
      html = render_with_checks(view, EvoGit.SystemCheck.run_all_checks())

      assert html =~ ">Sandbox</span>"
      assert html =~ "hero-lock-closed"

      # Deterministic badge assertion: inject a macOS-style sandbox check result
      # so the "sandbox-exec (macOS)" badge does not depend on the host OS.
      html =
        render_with_checks(view, %{
          EvoGit.SystemCheck.run_all_checks()
          | sandbox: %{
              backend: :sandbox_exec,
              enabled: true,
              capabilities: %{filesystem_isolation: true, resource_limits: false},
              sandbox_exec_available: true,
              systemd_available: false
            }
        })

      assert html =~ ">Sandbox</span>"
      assert html =~ "sandbox-exec (macOS)"
    end
  end

  describe "system self-check" do
    # The self-check grid/banner tests inject a deterministic
    # `{:system_checks_result, _}` via `render_with_checks/2` after the real
    # async check completes (see the helper's comment for the send+render
    # determinism pattern). All tests set the :windows platform override via
    # `set_windows_platform/0` so the Sandbox cell is hidden and the banner
    # depends only on the injected checks.

    test "Genesis Process Tree row markers are no longer rendered", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html = render_with_checks(view, all_ok_checks())

      # The health-banner redesign removed the old "Genesis Process Tree" row
      # and its `supervisor_status/1` component entirely: the row title, the
      # "All healthy" fallback, and the `EvoGit:` / `EvoDash:` sub-status
      # labels (`<span ...>EvoGit:</span>`) must never reappear.
      refute html =~ "Genesis Process Tree"
      refute html =~ "All healthy"
      refute html =~ ">EvoGit:</span>"
      refute html =~ ">EvoDash:</span>"
    end

    test "merged health light is green when every check passes", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html = render_with_checks(view, all_ok_checks())

      assert html =~ "System running correctly"
      assert html =~ "All self-checks passed."
    end

    test "merged health light is red with a config failure reason", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html =
        render_with_checks(view, %{
          all_ok_checks()
          | config: %{ok?: false, missing: [:llm_model], warnings: [], validation_errors: []}
        })

      assert html =~ "System needs attention"
      assert html =~ "Required settings are missing or invalid"
    end

    test "merged health light is red with a missing-tool reason", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html =
        render_with_checks(view, %{
          all_ok_checks()
          | tools: %{
              git: %{available: false, path: nil, version: nil, error: "not found"},
              rg: %{available: true, path: "/usr/bin/rg", version: "ripgrep 14.1.0", error: nil}
            }
        })

      assert html =~ "System needs attention"
      assert html =~ "A required tool (git or ripgrep) is missing"
    end

    test "merged health light is red with a supervisor failure reason", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html =
        render_with_checks(view, %{
          all_ok_checks()
          | supervisor: %{
              healthy: false,
              evo_git: [%{id: :evo_git, status: :error, pid: nil}],
              evo_dash: []
            }
        })

      assert html =~ "System needs attention"
      assert html =~ "System processes are not running correctly"
    end

    test "check terms render in the responsive 2D grid", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html = render_with_checks(view, all_ok_checks())

      assert html =~ ~s(grid grid-cols-1 md:grid-cols-2 gap-3)
    end

    test "check terms are expandable details cards with fix hints on failure", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      # Every term renders as a <details>/<summary> disclosure card.
      html = render_with_checks(view, all_ok_checks())

      assert html =~ "<details"
      assert html =~ "<summary"

      # Failing rg → the Required Tools cell shows the per-tool fix hint
      # ("Install git ..." is NOT shown because git is still available).
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | tools: %{
              git: %{
                available: true,
                path: "/usr/bin/git",
                version: "git version 2.0.0",
                error: nil
              },
              rg: %{available: false, path: nil, version: nil, error: "not found"}
            }
        })

      assert html =~ "Install ripgrep and make sure it is available on your PATH."

      # Failing config → the Configuration cell shows the Settings fix hint
      # with its "Open Settings" link.
      html =
        render_with_checks(view, %{
          all_ok_checks()
          | config: %{ok?: false, missing: [:llm_model], warnings: [], validation_errors: []}
        })

      assert html =~ "Fix the missing or invalid settings in Settings."
      assert html =~ "Open Settings"
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
