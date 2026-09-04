defmodule EvoDashWeb.LiveHooks.GuideTest do
  # Tests for the global Guide on-mount hook (EvoDashWeb.LiveHooks.Guide):
  #
  # 1. Unit tests for the pure `normalize_guide/2` + `relevant?/2` helpers —
  #    no LiveView needed.
  # 2. LiveView integration on the Tasks page (one of the 7 owned pages that
  #    pass `guide={@guide}` to `Layouts.app`): the floating "Genesis Guide"
  #    panel renders from `{:guide_updated, ...}` broadcasts, foreign-node
  #    broadcasts are dropped, the `guide_highlight` push carries EXACTLY
  #    `%{selector: selector}` (assert_push_event pins the payload), dismissal
  #    clears the panel and pushes `guide_cleared`, and the Go link renders
  #    only when `page` is set.
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
  # same justification as tasks_live_test.exs); the unit tests are pure but
  # share the module.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoDashWeb.LiveHooks.Guide
  alias EvoGit.TaskRegistry

  describe "normalize_guide/2" do
    test "atom-keyed payload → exact canonical map" do
      assert Guide.normalize_guide("g1", %{
               message: "hello",
               page: "/system",
               selector: "#el",
               dismissible: true
             }) == %{
               id: "g1",
               message: "hello",
               page: "/system",
               selector: "#el",
               dismissible: true
             }
    end

    test "string-keyed payload → same canonical map" do
      assert Guide.normalize_guide("g1", %{
               "message" => "hello",
               "page" => "/system",
               "selector" => "#el",
               "dismissible" => true
             }) == %{
               id: "g1",
               message: "hello",
               page: "/system",
               selector: "#el",
               dismissible: true
             }
    end

    test "partial payload → safe defaults (missing message → \"\", missing page/selector → nil)" do
      assert Guide.normalize_guide("g1", %{}) ==
               %{id: "g1", message: "", page: nil, selector: nil, dismissible: false}
    end

    test "non-boolean dismissible → false" do
      assert Guide.normalize_guide("g1", %{message: "m", dismissible: "yes"}) ==
               %{id: "g1", message: "m", page: nil, selector: nil, dismissible: false}
    end

    test "non-map payload (nil) → safe defaults" do
      assert Guide.normalize_guide("g1", nil) ==
               %{id: "g1", message: "", page: nil, selector: nil, dismissible: false}
    end
  end

  describe "relevant?/2" do
    test "matching node → true (explicit current_node and missing-assign fallback)" do
      assert Guide.relevant?(%{current_node: node()}, node())
      assert Guide.relevant?(%{}, node())
    end

    test "foreign node → false" do
      refute Guide.relevant?(%{current_node: node()}, :guide_other_node)
      refute Guide.relevant?(%{}, :guide_other_node)
    end
  end

  describe "Genesis Guide panel (Tasks page integration)" do
    setup do
      # Terminate production children to prevent auto-restarts and use isolated
      # stores (same pattern as tasks_live_test.exs).
      Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
      Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

      unique = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "evogit_test_guide_#{unique}")
      File.mkdir_p!(root)
      sqlite_path = Path.join(root, "tasks.sqlite")

      start_supervised({EvoGit.Store, data_dir: sqlite_path})

      start_supervised(
        {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
      )

      # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
      # terminated by the Store/TaskRegistry isolation above — reset it so one
      # test's sidebar snapshot never leaks into the next.
      EvoDash.ActiveTasks.reset()

      on_exit(fn ->
        File.rm_rf(root)
        Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
        Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
      end)

      :ok
    end

    test "no guide panel on initial render", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The panel container class is unique to the floating guide panel. (A
      # literal "Genesis Guide" assertion would false-positive here — the
      # layout's `<!-- Floating "Genesis Guide" panel -->` HTML comment always
      # renders regardless of @guide.)
      refute render(view) =~ "fixed top-4 right-4 z-50"
    end

    test "guide broadcast renders the floating panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g1",
         %{message: "hello guide", page: nil, selector: nil, dismissible: true}, node()}
      )

      html = render(view)
      assert html =~ "Genesis Guide"
      assert html =~ "hello guide"
      assert html =~ "fixed top-4 right-4 z-50"
    end

    test "foreign-node guide broadcast is dropped, previous guide stays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g1",
         %{message: "hello guide", page: nil, selector: nil, dismissible: true}, node()}
      )

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
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g3",
         %{message: "m", page: nil, selector: "#main-content", dismissible: false}, node()}
      )

      # assert_push_event pins the payload (exact match) — the hook pushes
      # %{selector: selector} with no extra keys.
      assert_push_event(view, "guide_highlight", %{selector: "#main-content"})
    end

    test "guide without selector pushes no guide_highlight", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g4", %{message: "m", page: nil, selector: nil, dismissible: false},
         node()}
      )

      refute_push_event(view, "guide_highlight", %{selector: _})
    end

    test "dismissing a dismissible guide clears the panel and pushes guide_cleared",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g1",
         %{message: "hello guide", page: nil, selector: nil, dismissible: true}, node()}
      )

      assert render(view) =~ "hello guide"

      html = render_click(view, "guide_dismissed")

      refute html =~ "hello guide"
      refute html =~ "fixed top-4 right-4 z-50"
      assert_push_event(view, "guide_cleared", %{})
    end

    test "guide with a page renders the Go link pointing at that page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g1",
         %{message: "m", page: "/system", selector: nil, dismissible: false}, node()}
      )

      html = render(view)
      assert html =~ "Go"

      # Scoped to the guide panel — the sidebar System nav link also carries
      # href="/system" but is a different element.
      assert view
             |> element(".fixed.top-4.right-4.z-50 a[href='/system']")
             |> render() =~ "Go"
    end

    test "guide without a page renders no Go link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g1", %{message: "m", page: nil, selector: nil, dismissible: false},
         node()}
      )

      refute view |> has_element?("a", "Go")
    end

    test "panel markup includes the floating container classes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      send(
        view.pid,
        {:guide_updated, "g1", %{message: "m", page: nil, selector: nil, dismissible: false},
         node()}
      )

      assert render(view) =~ "fixed top-4 right-4 z-50"
    end
  end
end
