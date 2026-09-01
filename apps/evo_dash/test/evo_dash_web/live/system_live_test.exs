defmodule EvoDashWeb.SystemLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    # Software Update card tests share the global `EvoDash.UpdateStatus` hub —
    # reset it so tests are independent, and pin the notify-only seam to false
    # so the full download flow is testable regardless of the host platform
    # (Linux CI without APPIMAGE would otherwise be notify-only). Capture the
    # original values of every update-related env key so test-body mutations
    # are restored (same restore_env_value/2 pattern as
    # test/evo_dash/update_status_test.exs, handling a stored `false`
    # correctly).
    keys = [
      :update_notify_only_override,
      :desktop_release,
      :update_check_runner,
      :update_check_timeout,
      :update_active_task_ids,
      :update_winddown_timeout,
      :update_winddown_poll_ms,
      :system_samples_runner,
      :source_status_runner,
      :source_clone_runner,
      :source_update_runner
    ]

    originals = Map.new(keys, fn key -> {key, Application.get_env(:evo_dash, key)} end)
    Application.put_env(:evo_dash, :update_notify_only_override, false)
    EvoDash.UpdateStatus.reset()

    on_exit(fn ->
      Enum.each(originals, fn {key, original} -> restore_env_value(key, original) end)
    end)

    :ok
  end

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as projects_live_test.exs / welcome_live_test.exs).
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

  # Waits until the chart ring buffer is non-empty (`chart_samples`). Samples
  # arrive either from a `{:system_sample, ...}` broadcast (applied
  # synchronously by the handler) or from the async seed RPC — poll until the
  # handler has applied one.
  defp await_chart_sample(view, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_chart_sample(view, deadline)
  end

  defp do_await_chart_sample(view, deadline) do
    cond do
      assigns(view)[:chart_samples] != [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("no chart sample appeared within the test timeout")

      true ->
        Process.sleep(10)
        do_await_chart_sample(view, deadline)
    end
  end

  # A full 12-key sample map as emitted by the evo_git system sampler (the
  # "system" topic contract). Overrides let tests vary individual keys.
  defp sample_map(overrides) do
    Map.merge(
      %{
        llm_used: 0,
        llm_waiting: 0,
        llm_capacity: 4,
        tool_used: 0,
        tool_waiting: 0,
        tool_capacity: 2,
        agents_total: 0,
        agents_running: 0,
        agents_blocked: 0,
        agents_waiting: 0,
        agents_pending: 0,
        scheduler_alive: true
      },
      Map.new(overrides)
    )
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
      # Same pattern as projects_live_test.exs: isolate the config dir via
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

    test "scheduler_config broadcast reloads the REMOTE paused state, not the local one", %{
      conn: conn
    } do
      # Regression for the async node-aware paused reload: the
      # {:scheduler_config_updated} handler must re-read the node being VIEWED
      # (degrading to false for the fake remote node, which has no scheduler
      # behind it), never the LOCAL scheduler's paused state — the old
      # local-only read showed "Scheduler Paused" on a remote view whenever the
      # local scheduler happened to be paused.
      #
      # Same remote scaffolding as the "LLM Test in Settings link" test:
      # isolate the config dir via XDG_CONFIG_HOME so the saved target never
      # touches the developer's real ~/.config/genesis/, and register a fake
      # connection manager so the `?node=` param resolves to a connected remote
      # context.
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

      # The initial async handle_params paused load settles on `false`: the
      # fake remote node has no scheduler behind it, so NodeContext.paused?/1
      # degrades to false. Await it so the broadcast path is what the final
      # assertion exercises.
      assert await_view_assign(view, :scheduler_paused, false) == :ok

      # Prove the paused-state channel works for the current (remote) node —
      # the node stale-guard accepts it, flipping the banner to paused. This
      # makes the post-broadcast flip back to `false` meaningful: it comes from
      # the broadcast-triggered node-aware reload, not a broken channel.
      remote_node = assigns(view)[:current_node]
      send(view.pid, {:paused_state, remote_node, true})
      render(view)
      assert assigns(view)[:scheduler_paused] == true

      # A FOREIGN node's scheduler broadcast must be ignored: no reload is
      # triggered, so the paused banner stays exactly as injected.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, :remote@elsewhere}
      )

      render(view)
      assert assigns(view)[:scheduler_paused] == true

      # Now pause the LOCAL scheduler and fire the broadcast for the VIEWED
      # node (topic "scheduler_config", message
      # {:scheduler_config_updated, node} — see EvoGit.AgentScheduler.PubSub;
      # `remote_node` is the viewed node's BEAM atom, resolved by NodeAware).
      EvoGit.AgentScheduler.pause()

      on_exit(fn ->
        # Resume in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.AgentScheduler.resume()
        rescue
          _ -> :ok
        end
      end)

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, remote_node}
      )

      # The reload is node-aware: it re-reads the REMOTE node's paused state
      # (degrading to false), NOT the local scheduler's now-paused state, so
      # the remote view flips back to `false`.
      assert await_view_assign(view, :scheduler_paused, false) == :ok
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

    test "Sandbox row shows a bwrap backend badge when the platform is Linux", %{conn: conn} do
      Application.put_env(:evo_dash, :platform_os_override, :linux)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert assigns(view)[:platform_os] == :linux

      # Inject a bwrap-style sandbox check result (Linux host with bwrap but no
      # systemd) so the badge text is deterministic regardless of the host OS.
      html =
        render_with_checks(view, %{
          EvoGit.SystemCheck.run_all_checks()
          | sandbox: %{
              backend: :bwrap,
              enabled: true,
              capabilities: %{filesystem_isolation: true, resource_limits: false},
              systemd_available: false,
              sandbox_exec_available: false
            }
        })

      assert html =~ ">Sandbox</span>"
      assert html =~ "bwrap (Linux)"
    end
  end

  describe "Status sandbox helpers — bwrap" do
    # Pure function calls into EvoDashWeb.SystemLive.Status — no LiveView
    # harness needed (same style as the other helper unit tests).
    alias EvoDashWeb.SystemLive.Status

    test "format_backend/1 maps :bwrap to its display name" do
      assert Status.format_backend(:bwrap) == "bwrap (Linux)"
    end

    test "sandbox_status/1 treats bwrap with filesystem isolation as ok" do
      assert Status.sandbox_status(%{
               backend: :bwrap,
               enabled: true,
               capabilities: %{filesystem_isolation: true}
             }) == :ok
    end

    test "sandbox_status/1 errors when bwrap lacks filesystem isolation" do
      assert Status.sandbox_status(%{
               backend: :bwrap,
               enabled: true,
               capabilities: %{filesystem_isolation: false}
             }) == :error
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

    test "check terms render in the responsive grid", %{conn: conn} do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      html = render_with_checks(view, all_ok_checks())

      assert html =~ ~s(grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3)
    end

    test "check terms render details inline with no disclosure and fix hints on failure", %{
      conn: conn
    } do
      set_windows_platform()

      {:ok, view, _html} = live(conn, ~p"/system")

      # Every term's detail content is ALWAYS rendered — the old
      # <details>/<summary> disclosure cards were removed. Scope the assertions
      # to the check grid with Floki: the app layout's sidebar theme dropdown
      # (layouts.ex) legitimately renders its own <details>/<summary>, so a
      # bare refute on the full page would be vacuous.
      html = render_with_checks(view, all_ok_checks())
      grid = check_grid(html)

      assert Floki.find(grid, "details") == []
      assert Floki.find(grid, "summary") == []

      # A check-cell description string is present in the scoped grid — proof
      # the detail content renders unconditionally, with no disclosure to open.
      assert Floki.text(grid) =~ "Checks that the git and ripgrep command-line tools"

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

  describe "scheduler status charts" do
    test "renders the Scheduler Status section with placeholder cards on initial render", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/system")

      assert html =~ "Scheduler Status"
      assert html =~ ~s(<h3 class="font-semibold text-sm">LLM Slots</h3>)
      assert html =~ ~s(<h3 class="font-semibold text-sm">Tool Slots</h3>)
      assert html =~ ~s(<h3 class="font-semibold text-sm">Agents</h3>)
      # The static mount has no samples yet — every card shows the
      # collecting-data placeholder and no SVG chart (the only <svg> elements
      # on the page come from the chart cards' SVG branch).
      assert html =~ "Collecting data…"
      refute html =~ "<svg"
    end

    test "a system sample broadcast appends to the chart buffer and renders", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/system")

      sample = sample_map(llm_used: 1, tool_used: 1, agents_total: 2, agents_running: 1)

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "system", {:system_sample, node(), 1, sample})

      assert await_chart_sample(view) == :ok
      assert List.last(assigns(view)[:chart_samples]) == sample

      html = render(view)

      assert html =~ "<svg"
      refute html =~ "Collecting data…"
    end

    test "a foreign-node system sample broadcast is ignored", %{conn: conn} do
      # Make the test hermetic: the mount's async seed RPC must not fill the
      # chart buffer. The default runner reads the real EvoGit.SystemSampler
      # ring buffer, which is non-empty whenever a sampler tick has occurred in
      # this VM (real user config, capacities 25/8) — stubbing it to fail makes
      # the assertion depend only on the foreign-sample filter. (The file-level
      # setup block restores this env in on_exit.)
      Application.put_env(:evo_dash, :system_samples_runner, fn _node ->
        {:error, :not_implemented}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "system",
        {:system_sample, :remote@elsewhere, 1, sample_map(llm_used: 9)}
      )

      render(view)

      assert assigns(view)[:chart_samples] == []
    end

    test "the seed RPC fills the chart buffer preserving order", %{conn: conn} do
      samples = [sample_map(llm_used: 1), sample_map(llm_used: 2)]

      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, samples} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert await_view_assign(view, :chart_samples, samples, 6_000) == :ok
    end

    test "the seed RPC caps the chart buffer at 60 samples", %{conn: conn} do
      samples = for i <- 1..65, do: sample_map(llm_used: i)

      Application.put_env(:evo_dash, :system_samples_runner, fn _node -> {:ok, samples} end)

      {:ok, view, _html} = live(conn, ~p"/system")

      assert await_view_assign(view, :chart_samples, Enum.take(samples, -60), 6_000) == :ok
    end

    test "a failed seed retries once and then gives up", %{conn: conn} do
      table = :ets.new(:seed_calls, [:public, :set])
      :ets.insert(table, {:calls, 0})

      Application.put_env(:evo_dash, :system_samples_runner, fn _node ->
        :ets.update_counter(table, :calls, 1)
        {:error, :not_implemented}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The initial seed failed — the one-shot retry is scheduled.
      assert await_view_assign(view, :chart_seed_retried, true) == :ok

      # The retry fires once (3s later), fails again, and gives up: no third
      # call is ever made and the buffer stays empty.
      assert await_ets_count(table, :calls, 2, 6_000) == :ok
      Process.sleep(200)
      assert :ets.lookup_element(table, :calls, 2) == 2
      assert assigns(view)[:chart_samples] == []
    end

    test "a failed seed retries and succeeds on the second attempt", %{conn: conn} do
      table = :ets.new(:seed_calls, [:public, :set])
      :ets.insert(table, {:calls, 0})
      sample = sample_map(llm_used: 3)

      Application.put_env(:evo_dash, :system_samples_runner, fn _node ->
        if :ets.update_counter(table, :calls, 1) == 1 do
          {:error, :not_implemented}
        else
          {:ok, [sample]}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The initial seed failed — the one-shot retry is scheduled. 6s budget:
      # the seed task queues behind the mount's async system-check loads in
      # the test env, so the failure result (and thus the retry scheduling)
      # can arrive late.
      assert await_view_assign(view, :chart_seed_retried, true, 6_000) == :ok

      # The retry succeeds and fills the buffer (3s later).
      assert await_view_assign(view, :chart_samples, [sample], 6_000) == :ok
    end

    test "node switch clears the chart buffer and re-seeds for the new node", %{conn: conn} do
      # Same remote scaffolding as the scheduler_config broadcast test: isolate
      # the config dir via XDG_CONFIG_HOME and register a fake connection
      # manager so the `?node=` param resolves to a connected remote context.
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

      local_sample = sample_map(llm_used: 1)
      remote_sample = sample_map(llm_used: 2)

      Application.put_env(:evo_dash, :system_samples_runner, fn node ->
        if node == node(), do: {:ok, [local_sample]}, else: {:ok, [remote_sample]}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The local node's seed fills the buffer.
      assert await_view_assign(view, :chart_samples, [local_sample], 6_000) == :ok

      # Switch to the remote node: buffer cleared + a fresh seed for the new
      # node (a stale local seed result, if any, is dropped by the node
      # stale-guard).
      render_patch(view, "/system?node=" <> id)

      assert await_view_assign(view, :chart_samples, [remote_sample], 6_000) == :ok
    end
  end

  describe "software update card" do
    # These tests drive the shared `EvoDash.UpdateStatus` hub (a global
    # GenServer), so this file must stay `async: false` (it already is). The
    # setup block resets the hub and captures/restores every update-related env
    # key; each test additionally re-syncs the hub to :idle before mounting.
    #
    # Timing helpers:
    #   * `await_hub_phase/2` — polls the hub directly. Used to synchronize hub
    #     state BEFORE mounting: a cast followed by a call from the same
    #     process is ordered, so once `phase()` reports the target the hub is
    #     there and the mount's `get()` cannot observe a stale phase.
    #   * `await_update_phase/2` — polls the LiveView's `@update_status` assign
    #     (the hub broadcast is assigned via the `{:update_status, state}`
    #     handle_info).
    #   * `await_view_assign/3` — polls any socket assign (modal flags).

    test "card is hidden when not running in the desktop shell", %{conn: conn} do
      Application.delete_env(:evo_dash, :desktop_release)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view)[:update_card_visible] == false
      refute html =~ "Software Update"
    end

    test "every update state renders in the card", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      # A no-op runner keeps the mount-triggered check's result from arriving
      # (the states below are driven directly via the hub); the huge timeout
      # makes the parallel never-wedge watchdog a harmless long sleep that
      # never fires during the suite.
      Application.put_env(:evo_dash, :update_check_runner, fn _ -> :ok end)
      Application.put_env(:evo_dash, :update_check_timeout, 2_000_000)

      {:ok, view, html} = live(conn, ~p"/system")

      # :idle — the initial render: the mount-triggered check's broadcast is
      # processed only after the initial render is sent, so the returned html
      # still shows the :idle branch. The current-version line is seeded from
      # the :evo_git app spec and visible in every phase.
      assert html =~ "Software Update"
      assert html =~ "Check now"
      assert html =~ "Current version:"
      assert html =~ "Update information will appear here after the first check."

      # :checking — the mount-triggered check left the hub at :checking
      await_update_phase(view, :checking)
      html = render(view)
      assert html =~ "Checking for updates…"

      # :up_to_date
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "up_to_date",
        "current_version" => "0.1.0"
      })

      await_update_phase(view, :up_to_date)
      html = render(view)
      assert html =~ "is up to date"
      assert html =~ "Last checked"

      # :available
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "body" => "release notes",
        "current_version" => "0.1.0"
      })

      await_update_phase(view, :available)
      html = render(view)
      assert html =~ "Version 1.2.3 is available"
      assert html =~ ~s(id="update-download")

      # :ready
      EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
      await_update_phase(view, :ready)
      html = render(view)
      assert html =~ "Update ready"
      assert html =~ ~s(id="update-restart")

      # :error (generic failure) — no Retry button (the always-visible
      # Check-now header button is the retry path from every phase)
      EvoDash.UpdateStatus.handle_check_result(%{"status" => "error", "error" => "boom"})
      await_update_phase(view, :error)
      html = render(view)
      assert html =~ "Check failed"
      refute html =~ ~s(id="update-retry")

      # :error with error == "not_configured" → friendly pre-key message
      EvoDash.UpdateStatus.handle_check_result(%{"status" => "not_configured"})
      await_update_error(view, "not_configured")
      html = render(view)
      assert html =~ "Automatic updates are not configured yet"
      refute html =~ "Check failed"

      # :error with error == "not_available" → friendly info-style message;
      # the latest_version from the earlier "available" check is preserved and
      # shown (the version-less rendering is covered in the dedicated test)
      EvoDash.UpdateStatus.handle_check_result(%{"status" => "not_available"})
      await_update_error(view, "not_available")
      html = render(view)
      assert html =~ "Latest version 1.2.3 — no auto-update for this platform"
      refute html =~ "Check failed"

      # :applying — the header Check-now button is disabled
      EvoDash.UpdateStatus.applying()
      await_update_phase(view, :applying)
      html = render(view)
      assert html =~ "Applying update…"

      [check_now_button] =
        Floki.find(Floki.parse_document!(html), ~s(button[id="update-check-now"]))

      assert Floki.attribute(check_now_button, "disabled") != []
    end

    test "not_available with a known latest version shows it in the card", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "not_available",
        "version" => "1.2.3",
        "body" => "notes",
        "date" => "2026-08-01T00:00:00Z"
      })

      await_hub_phase(:error)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.error == "not_available"
      assert assigns(view).update_status.latest_version == "1.2.3"
      assert html =~ "Latest version 1.2.3 — no auto-update for this platform"
      refute html =~ "No auto update on this platform"
      refute html =~ "Check failed"
    end

    test "not_available without a known version falls back to the generic message", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{"status" => "not_available"})
      await_hub_phase(:error)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.error == "not_available"
      assert assigns(view).update_status.latest_version == nil
      assert html =~ "No auto update on this platform"
      refute html =~ "Latest version"
      refute html =~ "Check failed"
    end

    test "generic check error shows Check failed and the raw error detail", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "error",
        "error" => "Update check failed: network unreachable"
      })

      await_hub_phase(:error)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.error == "Update check failed: network unreachable"
      assert html =~ "Check failed"
      assert html =~ "Update check failed: network unreachable"
      refute html =~ "No auto update on this platform"
    end

    test "notify-only mode shows the package-manager message instead of a Download button", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()
      Application.put_env(:evo_dash, :update_notify_only_override, true)

      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.2.3",
        "body" => "notes",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:available)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view).update_status.notify_only == true
      assert html =~ "Version 1.2.3 is available"
      assert html =~ "Update via your package manager"
      refute html =~ ~s(id="update-download")
    end

    test "Check now flow: the click triggers a check that resolves to up-to-date", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      # Drive the hub to :up_to_date BEFORE mounting so the mount-triggered
      # check does not fire — its :checking phase would disable the Check-now
      # button. The click below is therefore the only check in this test.
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "up_to_date",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:up_to_date)

      # The delayed result gives the :checking phase a deterministic observation
      # window.
      Application.put_env(:evo_dash, :update_check_runner, fn pid ->
        Process.sleep(300)

        send(
          pid,
          {:update_check_result, %{"status" => "up_to_date", "current_version" => "0.1.0"}}
        )
      end)

      # Timeout watchdog fires after the result landed (phase :up_to_date → no-op).
      Application.put_env(:evo_dash, :update_check_timeout, 400)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-check-now") |> render_click()

      await_update_phase(view, :checking)
      await_update_phase(view, :up_to_date)

      html = render(view)
      assert html =~ "is up to date"

      # Let the parallel timeout watchdog fire (no-op on :up_to_date) before
      # the test ends so no stray task mutates the shared hub later.
      Process.sleep(100)
    end

    test "a check that never resolves times out and shows the error state", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      # Count runner invocations in a public ETS table so the Check-now re-run
      # is provable without racing the short :checking observation window (the
      # 50ms timeout is too fast to await on the view assign reliably).
      :ets.new(:update_check_runs, [:named_table, :public, :set])
      :ets.insert(:update_check_runs, {:count, 0})

      Application.put_env(:evo_dash, :update_check_runner, fn _ ->
        :ets.update_counter(:update_check_runs, :count, 1)
        :ok
      end)

      Application.put_env(:evo_dash, :update_check_timeout, 50)

      on_exit(fn ->
        if :ets.info(:update_check_runs) != :undefined do
          :ets.delete(:update_check_runs)
        end
      end)

      # Drive the hub to :up_to_date BEFORE mounting so the mount-triggered
      # check does not fire (its :checking phase would disable the Check-now
      # button). The click below is therefore the only check in this test.
      EvoDash.UpdateStatus.handle_check_result(%{
        "status" => "up_to_date",
        "current_version" => "0.1.0"
      })

      await_hub_phase(:up_to_date)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-check-now") |> render_click()

      # The runner never reports, so only the timeout watchdog can end
      # :checking — the never-wedge invariant.
      await_update_phase(view, :error)

      html = render(view)
      assert html =~ "Check failed"
      refute html =~ ~s(id="update-retry")

      # The always-visible Check-now header button is the retry path: re-run
      # the check from :error (poll until the runner is invoked a second time —
      # deterministic, the short :checking window is not awaited), then the
      # 50ms watchdog bounds the retry too: the UI can never wedge on a spinner.
      view |> element("#update-check-now") |> render_click()

      await_ets_count(:update_check_runs, :count, 2)
      await_update_phase(view, :error)
    end

    test "mounting the page with an idle hub triggers a check automatically", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      Application.put_env(:evo_dash, :update_check_runner, fn pid ->
        send(
          pid,
          {:update_check_result, %{"status" => "up_to_date", "current_version" => "0.1.0"}}
        )
      end)

      Application.put_env(:evo_dash, :update_check_timeout, 500)

      {:ok, view, _html} = live(conn, ~p"/system")

      await_update_phase(view, :up_to_date)

      html = render(view)
      assert html =~ "is up to date"
    end

    test "Download pushes the download request and a ready result arms the apply button", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_available()

      {:ok, view, html} = live(conn, ~p"/system")
      assert html =~ "Version 1.2.3 is available"

      view |> element("#update-download") |> render_click()

      assert_push_event(view, "update_download_requested", %{}, 1_000)

      EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
      await_update_phase(view, :ready)

      html = render(view)
      # HTML-escaped `&` (HEEx renders `&` as `&amp;`).
      assert html =~ "Restart &amp; Update"
    end

    test "applying with no active tasks proceeds immediately", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      Application.put_env(:evo_dash, :update_active_task_ids, [])

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()

      await_update_phase(view, :applying)
      assert_push_event(view, "update_apply_requested", %{}, 1_000)
    end

    test "applying with active tasks shows the busy modal and Defer keeps the update ready", %{
      conn: conn
    } do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      Application.put_env(:evo_dash, :update_active_task_ids, ["task-1", "task-2"])

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()

      assert await_view_assign(view, :update_apply_busy_count, 2) == :ok
      html = render(view)
      assert html =~ "2 task(s) still running"

      render_click(view, "defer_apply_update")

      assert await_view_assign(view, :update_apply_busy_count, nil) == :ok
      assert EvoDash.UpdateStatus.phase() == :ready

      html = render(view)
      refute html =~ "task(s) still running"
    end

    test "applying with active tasks can gracefully stop them and then apply", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      # :gate sees one active task (busy modal); :winddown_poll sees none, so
      # the wind-down completes on its first poll and the update applies. The
      # graceful cancel of the fake id errors harmlessly.
      Application.put_env(:evo_dash, :update_active_task_ids, fn
        :gate -> ["task-1"]
        :winddown_poll -> []
      end)

      Application.put_env(:evo_dash, :update_winddown_poll_ms, 20)
      Application.put_env(:evo_dash, :update_winddown_timeout, 500)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()
      assert await_view_assign(view, :update_apply_busy_count, 1) == :ok

      render_click(view, "confirm_apply_graceful")

      await_update_phase(view, :applying)
    end

    test "a wind-down that times out offers the force-kill fallback", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()
      drive_hub_to_ready()
      Application.put_env(:evo_dash, :update_active_task_ids, fn _ -> ["task-1"] end)
      Application.put_env(:evo_dash, :update_winddown_poll_ms, 20)
      Application.put_env(:evo_dash, :update_winddown_timeout, 100)

      {:ok, view, _html} = live(conn, ~p"/system")

      view |> element("#update-restart") |> render_click()
      assert await_view_assign(view, :update_apply_busy_count, 1) == :ok

      render_click(view, "confirm_apply_graceful")

      assert await_view_assign(view, :update_force_kill_count, 1) == :ok
      html = render(view)
      # HTML-escaped `&` (HEEx renders `&` as `&amp;`).
      assert html =~ "Force Kill &amp; Update?"
      assert html =~ "1 task(s) still running after waiting"
      assert html =~ "In-flight work will be lost"

      render_click(view, "confirm_force_kill_update")

      await_update_phase(view, :applying)
    end

    test "card is hidden when viewing a remote node", %{conn: conn} do
      reset_hub_to_idle()
      set_desktop()

      # Isolate the config dir via XDG_CONFIG_HOME so the saved target never
      # touches the developer's real ~/.config/genesis/ (same pattern as the
      # "LLM Test in Settings link" test).
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

      {:ok, view, html} = live(conn, "/system?node=" <> id)

      assert assigns(view)[:remote?] == true
      assert assigns(view)[:update_card_visible] == false
      refute html =~ "Software Update"
    end
  end

  describe "genesis source card" do
    # The card is local-only and load-on-mount: every test that mounts a LOCAL
    # node spawns an async status load via `:source_status_runner` (resolved at
    # spawn time inside the spawned Task — the same send-pattern seam idiom as
    # the update card's `:update_check_runner`). Tests therefore inject it
    # BEFORE `live/3`; the default runner degrades to
    # `{:unavailable, :module_missing}` when the `EvoGit.SelfReflectiveSource`
    # backend module is absent (it is, in this worktree) and must never be hit.
    # Clone/update flows use the same seam pattern (`:source_clone_runner` /
    # `:source_update_runner`). The 300ms runner sleeps give the transient
    # busy states a deterministic observation window (same idiom as the update
    # card's "Check now flow" test). Async results are flushed by polling the
    # socket assigns (`await_view_assign/3`); `render_async/2` does not await
    # TaskSupervisor children.

    test "card renders on a local node", %{conn: conn} do
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> not_cloned_status() end)

      {:ok, view, html} = live(conn, ~p"/system")

      assert assigns(view)[:source_card_visible] == true
      assert html =~ ~s(id="genesis-source-card")
      assert html =~ "Genesis Source"
      assert html =~ "Genesis source checkout used by the self-reflective agent."
    end

    test "card is hidden when viewing a remote node", %{conn: conn} do
      {:ok, view, html} = mount_remote_system(conn)

      assert assigns(view)[:remote?] == true
      assert assigns(view)[:source_card_visible] == false
      refute html =~ ~s(id="genesis-source-card")
      refute html =~ "Genesis Source"
    end

    test "not-cloned status shows the Clone button and explanation, no Update button", %{
      conn: conn
    } do
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> not_cloned_status() end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, not_cloned_status())

      html = render(view)
      assert html =~ "The Genesis source has not been cloned yet."
      assert html =~ ~s(id="clone-source")
      assert html =~ "Clone"
      refute html =~ "Cloning…"
      refute html =~ ~s(id="update-source")
    end

    test "cloned status renders the checkout details, Update button, and reference line", %{
      conn: conn
    } do
      status = source_status()
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> status end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, status)

      html = render(view)
      assert html =~ "deadbeef"
      refute html =~ "feature/source"
      assert html =~ "9.9.9"
      refute html =~ "https://example.com/genesis.git"
      refute html =~ "Remote URL"
      refute html =~ ">Branch</span>"
      assert html =~ "The self-reflective agent reads: /tmp/genesis-source"
      assert html =~ ~s(id="update-source")
      assert html =~ "Update"
      refute html =~ ~s(id="clone-source")
      refute html =~ "in use"
      refute html =~ "An explicit override is in effect"
      assert html =~ ~s(id="system-self-check")
      assert html =~ ~s(id="runtime-controls")
      assert html =~ "System Control"
    end

    test "an explicit reference override shows the muted note and the in-use badge", %{
      conn: conn
    } do
      status = source_status(%{reference: "/custom/genesis-root", is_reference: true})
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> status end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, status)

      html = render(view)
      assert html =~ "An explicit override is in effect"
      assert html =~ "The self-reflective agent reads: /custom/genesis-root"
      assert html =~ "in use"
    end

    test "status load shows the loading spinner until the status lands", %{conn: conn} do
      test_pid = self()
      status = source_status()

      Application.put_env(:evo_dash, :source_status_runner, fn _ ->
        send(test_pid, :source_status_task_started)
        Process.sleep(500)
        status
      end)

      {:ok, view, _html} = live(conn, ~p"/system")

      # The runner signals it started, then sleeps — the loading spinner is
      # observable for a deterministic window.
      assert_receive :source_status_task_started, 1_000
      html = render(view)
      assert html =~ "Loading…"

      await_view_assign(view, :source_status, status)
      html = render(view)
      refute html =~ "Loading…"
      assert html =~ "The self-reflective agent reads: /tmp/genesis-source"
    end

    test "card shows the unavailable message when the backend module is missing", %{conn: conn} do
      Application.put_env(:evo_dash, :source_status_runner, fn _ ->
        {:unavailable, :module_missing}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, {:unavailable, :module_missing})

      html = render(view)
      assert html =~ "Genesis source is not available in this version"
      refute html =~ ~s(id="clone-source")
      refute html =~ ~s(id="update-source")
    end

    test "clone flow: busy state, then a successful clone flashes and refreshes the status", %{
      conn: conn
    } do
      cloned = source_status(%{commit: "cafebabe"})
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> not_cloned_status() end)

      Application.put_env(:evo_dash, :source_clone_runner, fn _ ->
        Process.sleep(300)
        {:ok, cloned}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, not_cloned_status())

      html = render_click(view, "clone_source")
      assert html =~ "Cloning…"

      [clone_button] = Floki.find(Floki.parse_document!(html), ~s(button[id="clone-source"]))
      assert Floki.attribute(clone_button, "disabled") != []

      # The mutation result clears the busy flag and assigns the fresh status.
      await_view_assign(view, :source_busy, nil)
      await_view_assign(view, :source_status, cloned)

      html = render(view)
      assert html =~ "Genesis source cloned."
      assert html =~ "cafebabe"
      assert html =~ ~s(id="update-source")
      refute html =~ ~s(id="clone-source")
    end

    test "clone flow: a failing clone shows the error flash and re-syncs the status", %{
      conn: conn
    } do
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> not_cloned_status() end)

      Application.put_env(:evo_dash, :source_clone_runner, fn _ ->
        Process.sleep(300)
        {:error, "clone failed"}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, not_cloned_status())

      html = render_click(view, "clone_source")
      assert html =~ "Cloning…"

      await_view_assign(view, :source_busy, nil)

      html = render(view)
      assert html =~ "Failed to clone the Genesis source."
    end

    test "update flow: busy state, then a successful update flashes and refreshes the status", %{
      conn: conn
    } do
      original = source_status(%{commit: "deadbeef"})
      updated = source_status(%{commit: "cafebabe"})

      Application.put_env(:evo_dash, :source_status_runner, fn _ -> original end)

      Application.put_env(:evo_dash, :source_update_runner, fn _ ->
        Process.sleep(300)
        {:ok, updated}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, original)

      html = render_click(view, "update_source")
      assert html =~ "Updating…"

      [update_button] = Floki.find(Floki.parse_document!(html), ~s(button[id="update-source"]))
      assert Floki.attribute(update_button, "disabled") != []

      await_view_assign(view, :source_busy, nil)
      await_view_assign(view, :source_status, updated)

      html = render(view)
      assert html =~ "Genesis source updated."
      assert html =~ "cafebabe"
    end

    test "update flow: a failing update shows the error flash", %{conn: conn} do
      status = source_status()
      Application.put_env(:evo_dash, :source_status_runner, fn _ -> status end)

      Application.put_env(:evo_dash, :source_update_runner, fn _ ->
        Process.sleep(300)
        {:error, "update failed"}
      end)

      {:ok, view, _html} = live(conn, ~p"/system")
      await_view_assign(view, :source_status, status)

      html = render_click(view, "update_source")
      assert html =~ "Updating…"

      await_view_assign(view, :source_busy, nil)

      html = render(view)
      assert html =~ "Failed to update the Genesis source."
    end

    test "clone/update events are no-ops when the card is hidden (remote node)", %{conn: conn} do
      test_pid = self()

      # Runners that would loudly fail if invoked — the hidden card must never
      # spawn them.
      Application.put_env(:evo_dash, :source_clone_runner, fn _ ->
        send(test_pid, :clone_runner_called)
        {:ok, source_status()}
      end)

      Application.put_env(:evo_dash, :source_update_runner, fn _ ->
        send(test_pid, :update_runner_called)
        {:ok, source_status()}
      end)

      {:ok, view, _html} = mount_remote_system(conn)

      assert assigns(view)[:source_card_visible] == false
      assert assigns(view)[:source_status] == nil

      render_click(view, "clone_source")
      render_click(view, "update_source")

      refute_receive :clone_runner_called, 200
      refute_receive :update_runner_called, 200

      assert assigns(view)[:source_busy] == nil
      assert assigns(view)[:source_status] == nil
    end
  end

  # Floki-scopes the self-check term grid so disclosure assertions never see
  # the app layout's sidebar `<details>` theme dropdown (layouts.ex). The grid
  # container is `<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">`
  # (system_live.ex); the charts grid uses the same classes plus `p-4`, so the
  # exact-match attribute selector matches only the check grid.
  defp check_grid(html) do
    [grid] =
      Floki.find(
        Floki.parse_document!(html),
        ~s(div[class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3"])
      )

    grid
  end

  # --- Software Update card test helpers ------------------------------------

  # Restores an Application env (handles a stored `false` value correctly —
  # `if value` would wrongly delete it). Mirrors update_status_test.exs.
  defp restore_env_value(key, original) do
    if original != nil do
      Application.put_env(:evo_dash, key, original)
    else
      Application.delete_env(:evo_dash, key)
    end
  end

  # The desktop-shell flag for the update card (restored by the setup on_exit).
  defp set_desktop do
    Application.put_env(:evo_dash, :desktop_release, true)
  end

  # --- Genesis Source card test helpers -------------------------------------

  # A full Genesis Source status map as emitted by the
  # `EvoGit.SelfReflectiveSource.status/0` backend contract (see SourceCard).
  # Overrides let tests vary individual keys.
  defp source_status, do: source_status(%{})

  defp source_status(overrides) do
    Map.merge(
      %{
        dir: "/tmp/genesis-source",
        exists: true,
        is_git_repo: true,
        valid: true,
        commit: "deadbeef",
        branch: "feature/source",
        version: "9.9.9",
        remote_url: "https://example.com/genesis.git",
        reference: nil,
        is_reference: false
      },
      Map.new(overrides)
    )
  end

  # The status of a checkout that has never been cloned (no commit/branch/etc.).
  defp not_cloned_status do
    source_status(%{exists: false, commit: nil, branch: nil, version: nil, remote_url: nil})
  end

  # Mounts the System page in a connected remote-node context (same pattern as
  # the update card's "card is hidden when viewing a remote node" test and the
  # "LLM Test in Settings link" test): isolates the config dir via XDG_CONFIG_HOME
  # so the saved target never touches the developer's real ~/.config/genesis/,
  # registers a fake connection manager so the `?node=` param resolves to a
  # connected remote context, and returns `{view, html}` from `live/3`.
  defp mount_remote_system(conn) do
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

    live(conn, "/system?node=" <> id)
  end

  # Resets the shared hub and synchronizes: the reset is a cast, so the
  # following `phase()` call (same process) is guaranteed to observe it.
  defp reset_hub_to_idle do
    EvoDash.UpdateStatus.reset()
    assert await_hub_phase(:idle) == :ok
  end

  # Polls the hub until it reaches the given phase. A cast followed by a call
  # from this process is ordered, so the first poll already reflects the cast.
  defp await_hub_phase(phase, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_hub_phase(phase, deadline)
  end

  defp do_await_hub_phase(phase, deadline) do
    if EvoDash.UpdateStatus.phase() == phase do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("update hub did not reach phase #{inspect(phase)} within the test timeout")
      else
        Process.sleep(10)
        do_await_hub_phase(phase, deadline)
      end
    end
  end

  # Polls the LiveView's `@update_status` assign until its phase matches (the
  # hub broadcast is assigned via the `{:update_status, state}` handle_info).
  defp await_update_phase(view, phase, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_update_phase(view, phase, deadline)
  end

  defp do_await_update_phase(view, phase, deadline) do
    if assigns(view).update_status.phase == phase do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = assigns(view).update_status.phase

        flunk(
          "update status did not reach phase #{inspect(phase)} within the test timeout (got #{inspect(got)})"
        )
      else
        Process.sleep(10)
        do_await_update_phase(view, phase, deadline)
      end
    end
  end

  # Polls the LiveView's `@update_status` assign until its error matches. Needed
  # for consecutive same-phase transitions (e.g. :error → :error): the
  # phase-only await above can return on the PREVIOUS state's broadcast, and
  # the following render would show stale HTML. Awaiting the error value
  # discriminates the two states.
  defp await_update_error(view, error, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_update_error(view, error, deadline)
  end

  defp do_await_update_error(view, error, deadline) do
    if assigns(view).update_status.error == error do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = assigns(view).update_status.error

        flunk(
          "update status did not reach error #{inspect(error)} within the test timeout (got #{inspect(got)})"
        )
      else
        Process.sleep(10)
        do_await_update_error(view, error, deadline)
      end
    end
  end

  # Polls any socket assign until it equals the expected value (modal flags).
  defp await_view_assign(view, key, value, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_view_assign(view, key, value, deadline)
  end

  # Polls an ETS integer counter until it reaches the expected value (used for
  # deterministic proofs where a transient phase window is too short to await).
  defp await_ets_count(table, key, expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_ets_count(table, key, expected, deadline)
  end

  defp do_await_ets_count(table, key, expected, deadline) do
    if :ets.lookup_element(table, key, 2) >= expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = :ets.lookup_element(table, key, 2)

        flunk(
          "ETS counter #{inspect(key)} did not reach #{expected} within the test timeout (got #{got})"
        )
      else
        Process.sleep(10)
        do_await_ets_count(table, key, expected, deadline)
      end
    end
  end

  defp do_await_view_assign(view, key, value, deadline) do
    if assigns(view)[key] == value do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        got = assigns(view)[key]

        flunk(
          "assign #{inspect(key)} did not reach #{inspect(value)} within the test timeout (got #{inspect(got)})"
        )
      else
        Process.sleep(10)
        do_await_view_assign(view, key, value, deadline)
      end
    end
  end

  # Drives the hub to :available (synchronized) — shared setup for the
  # download/apply tests.
  defp drive_hub_to_available do
    EvoDash.UpdateStatus.handle_check_result(%{
      "status" => "available",
      "version" => "1.2.3",
      "body" => "release notes",
      "current_version" => "0.1.0"
    })

    await_hub_phase(:available)
  end

  defp drive_hub_to_ready do
    drive_hub_to_available()
    EvoDash.UpdateStatus.handle_download_result(%{"status" => "ready"})
    await_hub_phase(:ready)
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.ProjectsLiveTest.ConnectionManager). Registers a status so
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
