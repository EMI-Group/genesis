defmodule EvoDashWeb.HomeLiveTest do
  use EvoDashWeb.ConnCase
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

  setup [:setup_temp_dir, :isolate_config]

  defp setup_temp_dir(%{} = context) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_home_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.TaskRegistry.remove_recent_project(tmp_dir)
      rescue
        _ -> :ok
      end

      # File.rm_rf! can fail on Windows: the real TaskExecutor (git init) may
      # still hold file locks in tmp_dir when teardown runs. Rescue so the
      # leftover temp dir does not mask real test results (same guard as the
      # archived workspaces_live_test cleanup).
      try do
        File.rm_rf!(tmp_dir)
      rescue
        _ -> :ok
      end
    end)

    # The LiveView expands paths (Path.expand/1) before display/storage; on
    # Windows tmp_dir uses backslashes + a capital drive letter while the
    # expanded form uses forward slashes + a lowercase drive. Assertions must
    # compare against the expanded form.
    {:ok, Map.merge(context, %{tmp_dir: tmp_dir, expanded_dir: Path.expand(tmp_dir)})}
  end

  # Submissions spawn a REAL TaskExecutor via TaskRegistry.start_task/2.
  # Isolate XDG_CONFIG_HOME to a temp dir (same approach as
  # DashboardLiveTest.set_onboarding_completed) so the executor never sees
  # real LLM credentials — it fails fast in the background instead, while
  # start_task/2 itself returns {:ok, %TaskInfo{}} synchronously.
  defp isolate_config(%{conn: conn} = _context) do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_home_test_config_#{System.unique_integer([:positive])}"
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

  # Inserts a task directly into the shared SQLite store (bypassing the async
  # task spawn) and registers on_exit cleanup so the fixture never leaks into
  # other tests (the shared store persists across tests). Returns %TaskInfo{}.
  defp insert_task_fixture!(overrides) do
    id = "home_fixture_#{System.unique_integer([:positive])}"

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

  # Deletes tasks whose prompt/objective contains the given marker (used to
  # clean up tasks really started via start_task/2 in submit tests).
  defp cleanup_tasks_with(marker) do
    for task <- EvoGit.TaskRegistry.list_tasks_summary() do
      opts = task.opts || []
      text = (opts[:prompt] || opts[:objective] || "") <> ""

      if text =~ marker do
        EvoGit.TaskRegistry.delete_task(task.id)
      end
    end
  end

  defp tasks_with(marker) do
    EvoGit.TaskRegistry.list_tasks_summary()
    |> Enum.filter(fn task ->
      opts = task.opts || []
      (opts[:prompt] || opts[:objective] || "") <> "" =~ marker
    end)
  end

  describe "mount" do
    test "renders top bar, mode tabs, prompt, address row, expanded advanced, Start, rail",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      # Top bar (all quiet): brand + Tree / Review / Settings / System links
      assert html =~ "Genesis"
      assert html =~ ~p"/agents"
      assert html =~ ~p"/reviews"
      assert html =~ "Tree"
      assert html =~ "Review"
      assert html =~ "Settings"
      assert html =~ "System"

      # Mode tabs — "New" is current (L1 underline)
      assert has_element?(view, "button[phx-value-tab='new'].pad-tab-on")
      assert has_element?(view, "button[phx-value-tab='modify']")

      # Central prompt textarea (L1), Enter-submit wired via the PadFly hook
      assert has_element?(view, "form#pad-form[phx-hook='PadFly']")
      assert has_element?(view, "textarea#pad-prompt[name='prompt']")

      # Address row: full path input (mono) + New/Existing directory radios
      assert has_element?(view, "input#pad-path[name='path'][phx-hook='PathAutocomplete']")
      assert html =~ "New directory"
      assert html =~ "Existing directory"

      # Advanced block is EXPANDED by default (no progressive disclosure)
      assert has_element?(view, ".pad-adv")
      refute has_element?(view, ".pad-adv.closed")
      assert html =~ "Advanced"
      # New mode shows the build_system select (from the backend catalog)
      assert has_element?(view, "select[name='build_system']")

      # Start — the only solid action
      assert has_element?(view, "button[type='submit'].pad-start")

      # The right-edge rail exists
      assert has_element?(view, "aside#pad-rail")
    end

    test "review count in the top bar counts completed + branch + nil review_status", %{
      conn: conn
    } do
      insert_task_fixture!(
        status: :completed,
        branch_name: "genesis/count-me",
        opts: [path: "/tmp/a", mode: "new", prompt: "waiting one"]
      )

      insert_task_fixture!(
        status: :completed,
        branch_name: "genesis/count-me-too",
        opts: [path: "/tmp/b", mode: "new", prompt: "waiting two"]
      )

      # Decided — not counted
      insert_task_fixture!(
        status: :completed,
        branch_name: "genesis/decided",
        review_status: :merged,
        opts: [path: "/tmp/c", mode: "new", prompt: "already merged"]
      )

      # No branch — not counted
      insert_task_fixture!(
        status: :completed,
        opts: [path: "/tmp/d", mode: "new", prompt: "no branch here"]
      )

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "a[href='/reviews'] b", "2")
    end
  end

  describe "mode tabs" do
    test "Modify shows In place + evolve fields and hides build_system", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button[phx-value-tab='modify']") |> render_click()

      assert html =~ "In place"
      assert has_element?(view, "button[phx-value-tab='modify'].pad-tab-on")
      assert has_element?(view, "input[name='node_path']")
      assert has_element?(view, "input[name='starting_commit']")
      assert has_element?(view, "input[name='resume_from']")
      refute has_element?(view, "select[name='build_system']")
      # The directory radios are replaced by the single In-place option
      refute html =~ "New directory"

      html = view |> element("button[phx-value-tab='new']") |> render_click()
      assert html =~ "New directory"
      assert has_element?(view, "select[name='build_system']")
    end
  end

  describe "advanced block" do
    test "toggle collapses and re-expands (server assign)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, ".pad-adv.closed")

      view |> element(".pad-adv div[phx-click='pad_toggle_advanced']") |> render_click()
      assert has_element?(view, ".pad-adv.closed")
      # The fields stay in the DOM (CSS collapse) so their values survive
      assert has_element?(view, "select[name='build_system']")

      view |> element(".pad-adv div[phx-click='pad_toggle_advanced']") |> render_click()
      refute has_element?(view, ".pad-adv.closed")
    end
  end

  describe "address options" do
    test "recent project chips fill the path input", %{
      conn: conn,
      tmp_dir: tmp_dir,
      expanded_dir: expanded_dir
    } do
      EvoGit.TaskRegistry.add_recent_project(tmp_dir, "moon-cli")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "moon-cli"

      html =
        view
        |> element("button[phx-click='pad_fill_path']", "moon-cli")
        |> render_click()

      assert html =~ ~s(value="#{expanded_dir}")
    end

    test "path input refreshes autocomplete suggestions", %{
      conn: conn,
      expanded_dir: expanded_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("#pad-path") |> render_change(%{path: expanded_dir})
      assert html =~ ~s(<option value="#{expanded_dir}">)
    end

    test "radio switches between New directory and Existing directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # The active radio carries the filled glyph
      assert has_element?(view, "button[phx-value-option='create']", "●")

      view |> element("button[phx-value-option='existing']") |> render_click()
      assert has_element?(view, "button[phx-value-option='existing']", "●")
      assert has_element?(view, "button[phx-value-option='create']", "○")
    end
  end

  describe "submit" do
    test "success: New directory mode starts genesis new, clears only the prompt", %{
      conn: conn,
      tmp_dir: tmp_dir,
      expanded_dir: expanded_dir
    } do
      prompt = "home submit test #{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_tasks_with(prompt) end)

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form[phx-submit='pad_submit']")
        |> render_submit(%{prompt: prompt, path: tmp_dir})

      # The client is told to clear ONLY the prompt and refocus the textarea
      assert_push_event(view, "pad:clear_prompt", %{})
      # No inline error
      refute has_element?(view, "p[role='alert']")
      # The new task landed in the rail (tooltip data carries the prompt)
      assert html =~ prompt
      assert html =~ "pad-sq"
      # Path/mode/params are kept for continuous input (full path visible)
      assert html =~ ~s(value="#{expanded_dir}")

      [task] = tasks_with(prompt)
      assert task.type == :genesis
      assert task.opts[:mode] == "new"
      assert task.project_path == expanded_dir
    end

    test "success: New directory creates a missing directory (mkdir_p) then submits", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      prompt = "home mkdir test #{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_tasks_with(prompt) end)

      new_dir = Path.join(tmp_dir, "fresh-subdir")
      expanded_new_dir = Path.expand(new_dir)
      refute File.dir?(expanded_new_dir)

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("form[phx-submit='pad_submit']")
      |> render_submit(%{prompt: prompt, path: new_dir})

      assert_push_event(view, "pad:clear_prompt", %{})
      assert File.dir?(expanded_new_dir)

      [task] = tasks_with(prompt)
      assert task.type == :genesis
      assert task.opts[:mode] == "new"
      assert task.project_path == expanded_new_dir
    end

    test "success: Existing directory submits mode existing", %{
      conn: conn,
      tmp_dir: tmp_dir,
      expanded_dir: expanded_dir
    } do
      prompt = "home existing test #{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_tasks_with(prompt) end)

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("button[phx-value-option='existing']") |> render_click()

      view
      |> element("form[phx-submit='pad_submit']")
      |> render_submit(%{prompt: prompt, path: tmp_dir})

      assert_push_event(view, "pad:clear_prompt", %{})

      [task] = tasks_with(prompt)
      assert task.type == :genesis
      assert task.opts[:mode] == "existing"
      assert task.project_path == expanded_dir
    end

    test "success: Modify submits evolve simple with the objective", %{
      conn: conn,
      tmp_dir: tmp_dir,
      expanded_dir: expanded_dir
    } do
      prompt = "home modify test #{System.unique_integer([:positive])}"
      on_exit(fn -> cleanup_tasks_with(prompt) end)

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("button[phx-value-tab='modify']") |> render_click()

      view
      |> element("form[phx-submit='pad_submit']")
      |> render_submit(%{prompt: prompt, path: tmp_dir})

      assert_push_event(view, "pad:clear_prompt", %{})

      [task] = tasks_with(prompt)
      assert task.type == :evolve
      assert task.opts[:mode] == "simple"
      assert task.opts[:objective] == prompt
      assert task.project_path == expanded_dir
    end

    test "failure: empty prompt shows an inline error and starts nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form[phx-submit='pad_submit']")
        |> render_submit(%{prompt: "   ", path: "/tmp/whatever"})

      assert html =~ "Nothing to start"
      assert has_element?(view, "p[role='alert']")
    end

    test "failure: missing path shows an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form[phx-submit='pad_submit']")
        |> render_submit(%{prompt: "home orphan prompt", path: ""})

      assert html =~ "Set a project path first"
    end

    test "failure: Modify on a missing directory shows an inline error and starts nothing", %{
      conn: conn
    } do
      prompt = "home modify missing #{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("button[phx-value-tab='modify']") |> render_click()

      html =
        view
        |> element("form[phx-submit='pad_submit']")
        |> render_submit(%{
          prompt: prompt,
          path: "/nonexistent/home-test-dir-#{System.unique_integer([:positive])}"
        })

      assert html =~ "In-place modify needs an existing directory"
      assert tasks_with(prompt) == []
    end

    test "failure: Existing directory on a missing path shows an inline error", %{conn: conn} do
      prompt = "home existing missing #{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("button[phx-value-option='existing']") |> render_click()

      html =
        view
        |> element("form[phx-submit='pad_submit']")
        |> render_submit(%{
          prompt: prompt,
          path: "/nonexistent/home-test-dir-#{System.unique_integer([:positive])}"
        })

      assert html =~ "Not a directory"
      assert tasks_with(prompt) == []
    end
  end

  describe "rail" do
    test "renders squares: abbreviation, status dot variants, click targets", %{
      conn: conn,
      expanded_dir: expanded_dir
    } do
      running =
        insert_task_fixture!(
          status: :running,
          finished_at: nil,
          project_path: Path.join(expanded_dir, "moon-cli"),
          opts: [path: Path.join(expanded_dir, "moon-cli"), mode: "new", prompt: "running task"]
        )

      awaiting =
        insert_task_fixture!(
          status: :completed,
          project_path: "/tmp/测试",
          branch_name: "genesis/awaiting",
          opts: [path: "/tmp/测试", mode: "new", prompt: "awaiting review task"]
        )

      decided =
        insert_task_fixture!(
          status: :completed,
          project_path: "/tmp/decided-proj",
          branch_name: "genesis/decided",
          review_status: :merged,
          opts: [path: "/tmp/decided-proj", mode: "new", prompt: "decided task"]
        )

      failed =
        insert_task_fixture!(
          status: :failed,
          project_path: "/tmp/failed-proj",
          opts: [path: "/tmp/failed-proj", mode: "new", prompt: "failed task"]
        )

      {:ok, view, _html} = live(conn, ~p"/")

      # Running: folder name + prompt preview, run variant, links to /agents
      assert has_element?(view, "a#pad-sq-#{running.id}.pad-sq-run[href='/agents']")
      assert has_element?(view, "#pad-sq-#{running.id} .pad-sq-name", "moon-cli")
      assert has_element?(view, "#pad-sq-#{running.id} .pad-sq-preview", "running task")

      # Awaiting review: CJK folder name, review variant, links to /review/:id
      assert has_element?(
               view,
               "a#pad-sq-#{awaiting.id}.pad-sq-review[href='/review/#{awaiting.id}']"
             )

      assert has_element?(view, "#pad-sq-#{awaiting.id} .pad-sq-name", "测试")

      # Decided: completed, so also the review variant, clickable to /review/:id
      assert has_element?(
               view,
               "a#pad-sq-#{decided.id}.pad-sq-review[href='/review/#{decided.id}']"
             )

      # Failed: failed variant (the dot becomes a small square)
      assert has_element?(view, "div#pad-sq-#{failed.id}.pad-sq-failed")
    end

    test "tasks finished more than 24h ago are hidden", %{conn: conn} do
      old =
        insert_task_fixture!(
          status: :completed,
          branch_name: "genesis/old",
          finished_at: DateTime.add(DateTime.utc_now(), -2 * 86_400, :second),
          started_at: DateTime.add(DateTime.utc_now(), -2 * 86_400 - 60, :second),
          opts: [path: "/tmp/old", mode: "new", prompt: "ancient task"]
        )

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#pad-sq-#{old.id}")
    end

    test "debounced PubSub reload lands new squares in the rail", %{
      conn: conn,
      expanded_dir: expanded_dir
    } do
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "PubSub fixture task"

      task =
        insert_task_fixture!(
          status: :running,
          finished_at: nil,
          project_path: expanded_dir,
          opts: [path: expanded_dir, mode: "new", prompt: "PubSub fixture task"]
        )

      # Store writes broadcast {:tasks_updated}; the 300ms trailing debounce
      # coalesces it into one rail reload.
      send(view.pid, :node_aware_reload_tasks)

      assert has_element?(view, "#pad-sq-#{task.id}")
    end
  end

  describe "deep links" do
    test "?resume_from=<id>&starting_commit=<sha> forces the Modify tab and pre-fills", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/?resume_from=taskabc123&starting_commit=deadbeef")

      assert has_element?(view, "button[phx-value-tab='modify'].pad-tab-on")
      assert html =~ ~s(value="taskabc123")
      assert html =~ ~s(value="deadbeef")
    end

    test "?project=<path> fills the path input", %{conn: conn, expanded_dir: expanded_dir} do
      {:ok, _view, html} = live(conn, "/?project=#{expanded_dir}")
      assert html =~ ~s(value="#{expanded_dir}")
    end
  end
end
