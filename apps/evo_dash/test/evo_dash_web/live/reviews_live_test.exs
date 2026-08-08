defmodule EvoDashWeb.ReviewsLiveTest do
  use EvoDashWeb.ConnCase
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

  setup [:setup_temp_dir, :isolate_config]

  defp setup_temp_dir(%{} = context) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_reviews_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    # The LiveView expands paths (Path.expand/1); on Windows tmp_dir uses
    # backslashes + a capital drive letter while the expanded form uses
    # forward slashes + a lowercase drive.
    {:ok, Map.merge(context, %{tmp_dir: tmp_dir, expanded_dir: Path.expand(tmp_dir)})}
  end

  # No submissions happen here (fixtures go straight into the store), but the
  # config dir is still isolated so mounting never sees the real user config.
  defp isolate_config(%{conn: conn} = _context) do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_reviews_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  # Inserts a task directly into the shared SQLite store and registers on_exit
  # cleanup so the fixture never leaks into other tests. Returns %TaskInfo{}.
  defp insert_task_fixture!(overrides) do
    id = "reviews_fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :genesis,
        status: :completed,
        opts: Keyword.merge([path: "/tmp/test"], Keyword.get(overrides, :opts, [])),
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.Store.delete_task(EvoGit.Store, id)
      rescue
        _ -> :ok
      end
    end)

    task
  end

  describe "mount" do
    test "renders the top bar with the current Review tab and both groups", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/reviews")

      # Top bar: same minimal header as the home page, Review tab is current
      assert html =~ "Genesis"
      assert html =~ "Tree"
      assert html =~ "Settings"
      assert html =~ "System"
      assert has_element?(view, "a[href='/reviews'][aria-current='page']")

      # Both groups render, empty states included
      assert has_element?(view, "#reviews-waiting")
      assert has_element?(view, "#reviews-decided")
      assert html =~ "Waiting for you"
      assert html =~ "Decided"
      assert html =~ "Nothing waiting."
      assert html =~ "No decisions yet."
    end
  end

  describe "Waiting for you" do
    test "rows show prompt, full path, branch, time and navigate to /review/:id", %{
      conn: conn,
      expanded_dir: expanded_dir
    } do
      task =
        insert_task_fixture!(
          status: :completed,
          project_path: expanded_dir,
          branch_name: "genesis/waiting-row",
          started_at: DateTime.add(DateTime.utc_now(), -155, :second),
          finished_at: DateTime.add(DateTime.utc_now(), -95, :second),
          opts: [path: expanded_dir, mode: "new", prompt: "Build the waiting row"]
        )

      {:ok, view, html} = live(conn, ~p"/reviews")

      # Row content: prompt, FULL path (mono), branch, relative finish time
      assert html =~ "Build the waiting row"
      assert html =~ expanded_dir
      assert html =~ "genesis/waiting-row"
      assert html =~ "1m ago"

      # The whole row navigates to the review page
      assert has_element?(view, "a#review-row-#{task.id}[href='/review/#{task.id}']")
    end

    test "waiting rows are newest-finished first", %{conn: conn} do
      older =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/older",
          started_at: DateTime.add(DateTime.utc_now(), -3700, :second),
          finished_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          opts: [path: "/tmp/older", mode: "new", prompt: "reviews order older"]
        )

      newer =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/newer",
          started_at: DateTime.add(DateTime.utc_now(), -70, :second),
          finished_at: DateTime.add(DateTime.utc_now(), -60, :second),
          opts: [path: "/tmp/newer", mode: "new", prompt: "reviews order newer"]
        )

      {:ok, _view, html} = live(conn, ~p"/reviews")

      {newer_pos, _} = :binary.match(html, "review-row-#{newer.id}")
      {older_pos, _} = :binary.match(html, "review-row-#{older.id}")
      assert newer_pos < older_pos
    end

    test "tasks without a branch or with a decided review_status are excluded", %{conn: conn} do
      no_branch =
        insert_task_fixture!(
          status: :completed,
          opts: [path: "/tmp/nobranch", mode: "new", prompt: "reviews no branch"]
        )

      decided =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/decided",
          review_status: :rejected,
          opts: [path: "/tmp/decided", mode: "new", prompt: "reviews already decided"]
        )

      running =
        insert_task_fixture!(
          status: :running,
          finished_at: nil,
          branch_name: "genesis/running",
          opts: [path: "/tmp/running", mode: "new", prompt: "reviews still running"]
        )

      {:ok, view, _html} = live(conn, ~p"/reviews")

      refute has_element?(view, "#review-row-#{no_branch.id}")
      refute has_element?(view, "#review-row-#{decided.id}")
      refute has_element?(view, "#review-row-#{running.id}")
    end

    test "a branch carried only in the result payload still counts as waiting", %{conn: conn} do
      task =
        insert_task_fixture!(
          status: :completed,
          branch_name: nil,
          result: {:ok, %{branch_name: "genesis/result-only"}},
          opts: [path: "/tmp/resultonly", mode: "new", prompt: "reviews result branch"]
        )

      {:ok, view, _html} = live(conn, ~p"/reviews")
      assert has_element?(view, "a#review-row-#{task.id}[href='/review/#{task.id}']")
    end

    test "the top-bar count equals the waiting group size", %{conn: conn} do
      insert_task_fixture!(
        status: :completed,
        branch_name: "genesis/one",
        opts: [path: "/tmp/one", mode: "new", prompt: "reviews count one"]
      )

      insert_task_fixture!(
        status: :completed,
        branch_name: "genesis/two",
        opts: [path: "/tmp/two", mode: "new", prompt: "reviews count two"]
      )

      {:ok, view, _html} = live(conn, ~p"/reviews")
      assert has_element?(view, "a[href='/reviews'] b", "2")
    end
  end

  describe "Decided" do
    test "shows the recent taken decisions with status text (L3), not links", %{conn: conn} do
      merged =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/merged",
          review_status: :merged,
          opts: [path: "/tmp/merged", mode: "new", prompt: "reviews merged row"]
        )

      ignored =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/ignored",
          review_status: :ignored,
          opts: [path: "/tmp/ignored", mode: "new", prompt: "reviews ignored row"]
        )

      {:ok, view, html} = live(conn, ~p"/reviews")

      # Decided rows render as plain divs with the status text — no navigation
      assert has_element?(view, "div#decided-row-#{merged.id}", "merged")
      assert has_element?(view, "div#decided-row-#{ignored.id}", "ignored")
      refute has_element?(view, "a#decided-row-#{merged.id}")
      assert html =~ "reviews merged row"
      assert html =~ "reviews ignored row"
    end
  end

  describe "PubSub" do
    test "debounced reload picks up newly reviewable tasks", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/reviews")
      assert html =~ "Nothing waiting."

      task =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/pubsub",
          opts: [path: "/tmp/pubsub", mode: "new", prompt: "reviews PubSub fixture"]
        )

      # Store writes broadcast {:tasks_updated}; the 300ms trailing debounce
      # coalesces it into one reload.
      send(view.pid, :node_aware_reload_tasks)

      assert has_element?(view, "a#review-row-#{task.id}[href='/review/#{task.id}']")
    end
  end
end
