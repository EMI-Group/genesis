defmodule EvoDashWeb.LiveHooks.GuideTest do
  # LiveView integration tests for the global Guide on-mount hook
  # (EvoDashWeb.LiveHooks.Guide) on the Tasks page (one of the 7 owned pages
  # that pass `guide={@guide}` to `Layouts.app`): the floating "Genesis Guide"
  # panel renders from `{:guide_updated, ...}` broadcasts, foreign-node
  # broadcasts are dropped, the `guide_highlight` push carries EXACTLY
  # `%{selector: selector}` (assert_push_event pins the payload), dismissal
  # clears the panel and pushes `guide_cleared`, and the Go link renders
  # only when `page` is set.
  #
  # The pure `normalize_guide/2` + `relevant?/2` unit tests live in the
  # `async: true` EvoDashWeb.LiveHooks.GuidePureTest module.
  #
  # TasksLive is used because it is the stated preference and its isolated
  # Store/TaskRegistry setup is the established convention in
  # tasks_live_test.exs. The hook itself holds no state — the persistent_term
  # retention store is keyed by the per-tab `guide_client_id` from the
  # LiveSocket connect params, which bare test sockets never carry, so
  # stored_guide/store_guide/clear_guide all no-op and `@guide` is seeded nil.
  #
  # async: false — the integration setup terminates the production
  # TaskRegistry/Store children and starts isolated ones (global mutation,
  # same justification as tasks_live_test.exs).
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "Genesis Guide panel (Tasks page integration)" do
    setup do
      # Isolated Store + TaskRegistry (same pattern as tasks_live_test). The
      # helper owns teardown: it stops the isolated pair FIRST, then restores
      # and VERIFIES the production children.
      :ok = EvoDash.Test.IsolatedTaskStore.isolate!("guide")

      # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
      # terminated by the Store/TaskRegistry isolation above — reset it so one
      # test's sidebar snapshot never leaks into the next.
      EvoDash.ActiveTasks.reset()

      :ok
    end

    # Mounts `/tasks` and registers the load drain that keeps this suite's
    # teardown leak-free (see `await_view_async_loads/2`).
    defp mount_tasks!(conn) do
      {:ok, view, html} = live(conn, ~p"/tasks")

      # `on_exit` callbacks run in REVERSE registration order, so this one runs
      # BEFORE `isolate!/1`'s stop/restore teardown (registered earlier, in
      # setup) — and it is registered here rather than in the test body so a
      # FAILING test still drains.
      on_exit(fn -> await_view_async_loads(view.pid, 5_000) end)

      {view, html}
    end

    # Leaves no async load in flight before the isolated Store is stopped.
    #
    # A `/tasks` mount spawns `EvoDash.TaskSupervisor` children: TasksLive's
    # page load plus NodeAware's sidebar and node-context loads, and each drives
    # an offloaded `EvoGit.Store` read. A read still in flight when this suite's
    # per-test isolated Store stops (isolate!/1's `on_exit`) crashes on the
    # store's vanished Ecto query-cache ETS table and leaks an `[error]` crash
    # report into the between-test gap — outside ExUnit's capture_log window.
    #
    # ExUnit terminates the test supervisor (and with it the LiveView) before
    # ANY `on_exit` callback runs, so this never talks to the view: it only
    # monitors the children the view spawned. `Task.Supervisor` records the
    # spawning process in each child's `:"$callers"` entry, so matching against
    # the view pid targets exactly this view's work. A task's result is sent
    # (and its store read therefore already replied) BEFORE the process exits,
    # so a fired monitor means nothing is in flight anymore. The bound keeps a
    # child stuck on a store call from wedging teardown.
    defp await_view_async_loads(view_pid, timeout) do
      view_pid
      |> view_async_task_pids()
      |> Enum.map(&Process.monitor/1)
      |> Enum.each(fn ref ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          timeout -> :ok
        end
      end)

      :ok
    end

    defp view_async_task_pids(view_pid) do
      EvoDash.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.filter(fn
        pid when is_pid(pid) ->
          case Process.info(pid, :dictionary) do
            {:dictionary, dict} -> view_pid in Keyword.get(dict, :"$callers", [])
            nil -> false
          end

        _other ->
          false
      end)
    end

    # Delivers a guide broadcast and SYNCHRONIZES with the view before returning
    # (a `:sys.get_state/1` round-trip handles every already-queued message —
    # including this broadcast, and therefore its `push_event` — before it
    # replies). That is what lets the negative push assertion below run with a
    # 0 ms window instead of a fixed wait.
    defp broadcast_guide!(view, payload) do
      send(view.pid, {:guide_updated, "g1", payload, node()})
      _ = :sys.get_state(view.pid)
      :ok
    end

    test "no guide panel on initial render", %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      # The panel container class is unique to the floating guide panel. (A
      # literal "Genesis Guide" assertion would false-positive here — the
      # layout's `<!-- Floating "Genesis Guide" panel -->` HTML comment always
      # renders regardless of @guide.)
      refute render(view) =~ "fixed top-4 right-4 z-50"
    end

    test "guide broadcast renders the floating panel", %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{
        message: "hello guide",
        page: nil,
        selector: nil,
        dismissible: true
      })

      html = render(view)
      assert html =~ "Genesis Guide"
      assert html =~ "hello guide"
      # The floating container classes are part of the same render.
      assert html =~ "fixed top-4 right-4 z-50"
    end

    test "foreign-node guide broadcast is dropped, previous guide stays", %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{
        message: "hello guide",
        page: nil,
        selector: nil,
        dismissible: true
      })

      assert render(view) =~ "hello guide"

      send(
        view.pid,
        {:guide_updated, "g2",
         %{message: "foreign guide", page: nil, selector: nil, dismissible: true},
         :guide_foreign_node}
      )

      html = render(view)
      refute html =~ "foreign guide"
      assert html =~ "hello guide"
    end

    test "guide with selector pushes guide_highlight with exactly %{selector: selector}",
         %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{
        message: "m",
        page: nil,
        selector: "#main-content",
        dismissible: false
      })

      # assert_push_event pins the payload (exact match) — the hook pushes
      # %{selector: selector} with no extra keys.
      assert_push_event(view, "guide_highlight", %{selector: "#main-content"})
    end

    test "guide without selector pushes no guide_highlight", %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{message: "m", page: nil, selector: nil, dismissible: false})

      # The round-trip inside broadcast_guide!/2 proves the broadcast was fully
      # handled before this runs, so a 0 ms window is conclusive: no push was
      # sent at all (the hook only pushes when a selector is present).
      refute_push_event(view, "guide_highlight", %{selector: _}, 0)
    end

    test "dismissing a dismissible guide clears the panel and pushes guide_cleared",
         %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{
        message: "hello guide",
        page: nil,
        selector: nil,
        dismissible: true
      })

      assert render(view) =~ "hello guide"

      html = render_click(view, "guide_dismissed")

      refute html =~ "hello guide"
      refute html =~ "fixed top-4 right-4 z-50"
      assert_push_event(view, "guide_cleared", %{})
    end

    test "guide with a page renders the Go link pointing at that page", %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{message: "m", page: "/system", selector: nil, dismissible: false})

      html = render(view)
      assert html =~ "Go"

      # Scoped to the guide panel — the sidebar System nav link also carries
      # href="/system" but is a different element.
      assert view
             |> element(".fixed.top-4.right-4.z-50 a[href='/system']")
             |> render() =~ "Go"
    end

    test "guide without a page renders no Go link", %{conn: conn} do
      {view, _html} = mount_tasks!(conn)

      broadcast_guide!(view, %{message: "m", page: nil, selector: nil, dismissible: false})

      refute view |> has_element?("a", "Go")
    end
  end
end
