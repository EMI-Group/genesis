# TasksLive (task history) test suite.
#
# Config isolation goes through the test-only `:config_dir_fun` seam
# (`EvoDash.Test.ConfigDir.isolate!/1`, installed by test/test_helper.exs) and
# NOT through the BEAM-global `XDG_CONFIG_HOME`: the override lives in the TEST
# process' dictionary and reaches the mounted LiveView plus its supervised load
# tasks through the OTP `:"$callers"` chain
# (`support/config_dir_test.exs` proves all three levels), so every test that
# needs one gets its OWN `<temp dir>/genesis` config dir.
#
# async: false — the module-wide setup calls
# `EvoDash.Test.IsolatedTaskStore.isolate!/1`, which TERMINATES and re-registers
# the process-global `EvoGit.Store` / `EvoGit.TaskRegistry` SINGLETON NAMES
# against a temp sqlite file (every fixture below is written through that
# pair). A (re)start of a name cannot overlap another module's use of the same
# name, so the whole module must stay in ExUnit's serial phase; the isolated
# pair is also why the page's async store reads must be drained before teardown
# (see `flush_tasks_load/2`). No test here needs config isolation at the file
# level — the one helper that does (`register_remote_target!/1`) isolates its
# own dir through the per-process seam.
defmodule EvoDashWeb.TasksLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

  setup do
    # Isolated Store + TaskRegistry against a temp sqlite file. The helper owns
    # teardown: it stops the isolated pair FIRST, then restores and VERIFIES the
    # production children (no start_supervised/on_exit racing).
    :ok = EvoDash.Test.IsolatedTaskStore.isolate!("tasks_live")

    # `EvoDash.ActiveTasks` is a process-less public-ETS module (NOT a GenServer) over
    # the boot-created, process-wide `:evo_dash_active_tasks` table, so it is shared by
    # the whole run and untouched by the `EvoDash.Test.IsolatedTaskStore.isolate!/1` above.
    # This module is `async: false`, so its whole-table `EvoDash.ActiveTasks.reset()`
    # cannot race another module: it clears the previous test's sidebar snapshot so it
    # cannot seed the next whole-page mount or dead render.
    EvoDash.ActiveTasks.reset()

    :ok
  end

  # Inserts a task directly into the SQLite store (bypasses the async
  # task spawn that `start_task/2` triggers). This lets us create deterministic
  # fixture tasks for search/filter assertions.
  defp insert_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

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
    id
  end

  # Drains the async page load (via the shared EvoDashWeb.TestHelpers.flush_loading/4)
  # AND synchronizes the test proxy before returning: flush_loading stops as soon
  # as the "Loading tasks..." marker leaves the proxy's cached tree, but that tree
  # is patched by channel diffs as they arrive, so a caller may otherwise assert
  # against a tree read mid-diff. Await the cleared :tasks_loading assign on the
  # socket (a synchronous :sys.get_state round-trip, the file's wait_until idiom)
  # and re-render so every call site reads a fully-applied page-load result.
  # It additionally DRAINS every async store read this view provoked before returning
  # (drain_async_loads/2): the page load AND NodeAware's sidebar fetch both run
  # in EvoDash.TaskSupervisor children, and each of them drives an offloaded
  # `EvoGit.Store` read. A read still in flight when this suite's per-test
  # isolated Store is stopped (its `on_exit`) crashes on the store's vanished
  # Ecto query-cache ETS table and leaks an `[error]` crash report into the
  # between-test gap — outside ExUnit's capture_log window.
  defp flush_tasks_load(view, timeout \\ 5000) do
    EvoDashWeb.TestHelpers.flush_loading(
      view,
      "Loading tasks...",
      "timed out waiting for the async task load to finish",
      timeout
    )

    wait_until(
      fn -> :sys.get_state(view.pid).socket.assigns[:tasks_loading] == false end,
      timeout
    )

    drain_async_loads(view, timeout)

    render(view)
  end

  # Leaves no async load in flight: waits out an ARMED NodeAware debounce (a
  # `{:task_updated, ...}` broadcast both a test and the cancel/force-kill
  # handlers provoke arms the trailing-edge timer) and then waits for every
  # EvoDash.TaskSupervisor child this view spawned to exit.
  #
  # The leading `:sys.get_state/1` is a synchronous round-trip, so any broadcast
  # already sitting in the view's mailbox has been processed by the time it
  # returns and an armed debounce is observable via `:tasks_reload_pending`. No
  # fixed sleeps.
  #
  # It is deliberately NOT a `render/1`: the drain only needs the round-trip (a
  # render additionally serializes the WHOLE page to an HTML string, which the
  # archive tests — up to 500 rendered entries — pay for on every call). Callers
  # that assert on rendered output still call `render/1` (or an `element/2`
  # scoped render) themselves, and those ping the proxy first, so the cached
  # tree they read is current.
  defp drain_async_loads(view, timeout) do
    :sys.get_state(view.pid)

    wait_until(
      fn -> not :sys.get_state(view.pid).socket.assigns[:tasks_reload_pending] end,
      timeout
    )

    await_view_async_loads(view, timeout)
  end

  # Waits until every EvoDash.TaskSupervisor child started by THIS LiveView
  # process has exited. Task.Supervisor records the spawning process in the
  # child's `$callers` process-dictionary entry, so matching it against the view
  # pid targets exactly this view's tasks — a leftover task from another test is
  # never waited on. A task's result is sent (and its offloaded store read has
  # therefore already replied) BEFORE the process exits, so by the time its
  # monitor fires nothing is in flight anymore.
  defp await_view_async_loads(view, timeout) do
    view.pid
    |> view_async_task_pids()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        # A task that already exited delivers its :DOWN immediately anyway
        # (reason :noproc); either way its store read is done.
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
    |> Enum.flat_map(fn
      pid when is_pid(pid) ->
        if view_pid in task_callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      _ -> []
    end
  end

  # Renders only the task-list container (#tasks-list), scoping list-content
  # assertions away from the sidebar, which now also lists completed tasks.
  defp render_tasks_list(view), do: view |> element("#tasks-list") |> render()

  # Poll interval for wait_until/3. Every poll is a cheap synchronous
  # round-trip (:sys.get_state / a render) and the fastest transition this file
  # waits on is the debounce itself — 10ms in the suite
  # (:node_aware_reload_debounce_ms in test_helper.exs), 300ms in production —
  # so a 2ms cadence observes any of them within a couple of scheduling quanta
  # while staying comfortably above 0 (never a hot spin; the previous cadence
  # was a hardcoded 10ms). A call site can opt into a different cadence with
  # wait_until/3's third argument.
  @wait_poll_ms 2

  # Polls `fun` every @wait_poll_ms until it returns truthy (or the TIMEOUT
  # elapses — deliberately left generous, in seconds, so real breakage still
  # fails loudly). Used to observe the PubSub-driven debounce phases
  # (:tasks_reload_pending true → false) without fixed sleeps.
  defp wait_until(fun, timeout \\ 2000, poll_ms \\ @wait_poll_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for async condition")
        else
          Process.sleep(poll_ms)
          wait_loop.(wait_loop)
        end
      end
    end

    wait_loop.(wait_loop)
  end

  # Installs a counting wrapper on the :tasks_page_load_hook seam so a test can
  # observe EVERY page-load spawn (the spawn itself still runs). The hook fires
  # in whichever process drives the LiveView — the test process for the
  # disconnected HTTP render, the LiveView process for the connected pass — so
  # the message lands in this test's mailbox either way.
  defp install_page_load_hook do
    test_pid = self()

    Application.put_env(:evo_dash, :tasks_page_load_hook, fn fun ->
      send(test_pid, :page_load_spawned)
      fun.()
    end)

    on_exit(fn -> Application.delete_env(:evo_dash, :tasks_page_load_hook) end)
  end

  # Installs the page-load RUNNER seam, resolved AT SPAWN TIME inside
  # `PageLoad.run/6`. The runner is invoked inside `EvoDash.SafeCall.run/1` and
  # `{:tasks_page_loaded, seq, node, result}` is ALWAYS sent (with
  # `{:error, reason}` on failure), so an exiting/raising runner can never
  # crash the LiveView or wedge `:tasks_loading`. Restored in on_exit so one
  # test's broken loader never leaks into the next.
  defp install_tasks_page_load_runner(fun) do
    Application.put_env(:evo_dash, :tasks_page_load_runner, fun)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :tasks_page_load_runner)
    end)
  end

  # Installs the per-card LITE-DETAIL runner seam (:tasks_task_detail_runner,
  # 2-arity `fn node, task_id -> %EvoGit.TaskInfo{} | nil end`), resolved AT
  # SPAWN TIME inside `EvoDashWeb.TasksLive.TaskDetail`. Restored in on_exit so
  # one test's injected runner never leaks into the next.
  defp install_task_detail_runner(fun) do
    Application.put_env(:evo_dash, :tasks_task_detail_runner, fun)
    on_exit(fn -> Application.delete_env(:evo_dash, :tasks_task_detail_runner) end)
  end

  # Installs the per-card ARCHIVE PAGE runner seam
  # (:tasks_task_archive_runner, 3-arity
  # `fn node, task_id, opts -> %{entries: [map()], total: n} end`), also resolved
  # at spawn time.
  defp install_task_archive_runner(fun) do
    Application.put_env(:evo_dash, :tasks_task_archive_runner, fun)
    on_exit(fn -> Application.delete_env(:evo_dash, :tasks_task_archive_runner) end)
  end

  # Installs the per-AGENT archive-result runner seam
  # (:tasks_task_archive_agent_runner, 3-arity
  # `fn node, task_id, agent_id -> map() | nil end`).
  defp install_task_archive_agent_runner(fun) do
    Application.put_env(:evo_dash, :tasks_task_archive_agent_runner, fun)
    on_exit(fn -> Application.delete_env(:evo_dash, :tasks_task_archive_agent_runner) end)
  end

  # Registers a CONNECTED (fake) remote target and returns its id, so NodeAware
  # resolves `/tasks?node=<id>` to a remote BEAM node atom. Same pattern as the
  # review page's remote-node tests: a per-test config dir (through the
  # test-only `:config_dir_fun` seam — `EvoDash.Test.ConfigDir.isolate!/1`,
  # activated in THIS process and inherited by the mounted view + its supervised
  # load tasks through `$callers`) for the target's TOML, plus a
  # Registry-backed stand-in for the connection manager.
  defp register_remote_target!(prefix) do
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_test_config_#{prefix}")
    on_exit(fn -> File.rm_rf!(dir) end)

    target_id = "#{prefix}-target-#{System.unique_integer([:positive])}"

    {:ok, _target} =
      EvoGit.RemoteConnections.save(%{
        ssh_target: "user@host",
        id: target_id,
        name: "Tasks Remote Target"
      })

    start_supervised!(
      {EvoDashWeb.TasksLiveTest.ConnectionManager,
       {target_id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
    )

    target_id
  end

  # The per-card detail cache entry for `task_id` (nil when not fetched yet).
  # `:sys.get_state/1` is a synchronous round-trip, so every async result
  # already sitting in the LiveView mailbox is applied by the time it returns.
  defp detail_entry(view, task_id) do
    case :sys.get_state(view.pid).socket.assigns[:task_details] do
      %{^task_id => entry} -> entry
      _ -> nil
    end
  end

  # Opens a card and WAITS for its LAZY detail fetch to settle (`:ok` or
  # `:error`), then drains the async work and re-renders. The expanded content
  # (Agent Message / usage / logs / archive disclosure) only exists once the
  # detail has landed, so every expanded-content assertion must go through
  # here — `render_hook(view, "toggle_task_details", ...)` alone returns with
  # the detail still `:loading`.
  defp expand_card(view, task_id, timeout \\ 5000) do
    _loading_html = render_hook(view, "toggle_task_details", %{"task_id" => task_id})

    wait_until(
      fn -> match?(%{state: state} when state in [:ok, :error], detail_entry(view, task_id)) end,
      timeout
    )

    drain_async_loads(view, timeout)
    render(view)
  end

  # Memory footprint of a term in BYTES: heap words (`:erts_debug.size/1` × 8,
  # as the payload test documents) PLUS the payload of every referenced binary.
  # `:erts_debug.size/1` alone reports a 2 MB refc binary as 8 words on OTP 29
  # — it measures the ProcBin word block, never the off-heap payload — so the
  # binary payloads are summed explicitly. That sum is exactly what
  # distinguishes a summary row from a full `%EvoGit.TaskInfo{}` carrying the
  # multi-MB `result` blob.
  defp term_bytes(term), do: :erts_debug.size(term) * 8 + binary_payload_bytes(term)

  defp binary_payload_bytes(bin) when is_binary(bin), do: byte_size(bin)

  # Structs are NOT Enumerable (protocol dispatch falls back to Any), so they
  # are unwrapped first — a summary row/full TaskInfo carries DateTime,
  # Range/MapSet and struct fields.
  defp binary_payload_bytes(%_{} = struct),
    do: binary_payload_bytes(Map.from_struct(struct))

  defp binary_payload_bytes(map) when is_map(map) do
    Enum.reduce(map, 0, fn {key, value}, acc ->
      acc + binary_payload_bytes(key) + binary_payload_bytes(value)
    end)
  end

  defp binary_payload_bytes(list) when is_list(list) do
    Enum.reduce(list, 0, &(binary_payload_bytes(&1) + &2))
  end

  defp binary_payload_bytes(tuple) when is_tuple(tuple),
    do: binary_payload_bytes(Tuple.to_list(tuple))

  defp binary_payload_bytes(_term), do: 0

  # Drains every already-sent `{:detail_fetch, task_id}` notification from the
  # test mailbox. Used before a negative "no further fetch" assertion, because
  # ONE "tasks" broadcast is delivered twice (TasksLive + NodeAware both
  # subscribe) and therefore refetches twice.
  #
  # The timeout is ZERO on purpose: every call site runs AFTER a
  # `drain_async_loads/2`, and a fetch notification is sent by a
  # Task.Supervisor child to this process BEFORE that child exits, so by the
  # time the drain returns every notification already sent is provably in THIS
  # mailbox (local sends are ordered with the drain's `:sys.get_state/1`
  # round-trip). A non-zero window would only burn the wall clock.
  defp flush_detail_fetches(task_id) do
    receive do
      {:detail_fetch, ^task_id} -> flush_detail_fetches(task_id)
    after
      0 -> :ok
    end
  end

  # The page reload is ASYNC, so its result arrives on a later
  # {:tasks_page_loaded, ...} message: poll the task-list container (each
  # render is a synchronous round-trip that drains the mailbox) until `needle`
  # shows up. Scoped to #tasks-list on purpose — the sidebar lists completed
  # tasks too, so it can show a row before the page reload lands.
  defp wait_for_list(view, needle, timeout \\ 5000) do
    wait_until(fn -> render_tasks_list(view) =~ needle end, timeout)
    render_tasks_list(view)
  end

  describe "task search" do
    test "search_tasks matches prompt text case-insensitively and clearing restores all", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "build a web app", path: "/tmp/proj"])
      insert_fixture!(opts: [prompt: "write a Database migration", path: "/tmp/proj"])
      insert_fixture!(opts: [prompt: "refactor the auth module", path: "/tmp/proj"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Prompt match, lower-case query against mixed-case text (the store filter
      # is case-insensitive on every searched column — the branch-name test
      # below covers the same leg for branch_name).
      _html = render_hook(view, "search_tasks", %{"search_query" => "database"})
      flush_tasks_load(view)

      # The sidebar now lists every completed task pending review, so
      # list-content assertions must be scoped to the #tasks-list container.
      assert render_tasks_list(view) =~ "write a Database migration"
      refute render_tasks_list(view) =~ "build a web app"
      refute render_tasks_list(view) =~ "refactor the auth module"

      # Clearing the query restores every task.
      _html = render_hook(view, "search_tasks", %{"search_query" => ""})
      html = flush_tasks_load(view)

      assert html =~ "build a web app"
      assert html =~ "write a Database migration"
      assert html =~ "refactor the auth module"
    end

    test "search_tasks handler filters tasks by objective text", %{conn: conn} do
      insert_fixture!(opts: [objective: "fix the login bug"])
      insert_fixture!(opts: [objective: "add dark mode toggle"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => "login"})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "fix the login bug"
      refute render_tasks_list(view) =~ "add dark mode toggle"
    end

    test "search_tasks handler filters tasks by task ID", %{conn: conn} do
      id1 = insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => id1})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "alpha task"
      refute render_tasks_list(view) =~ "beta task"
    end

    test "search_tasks handler filters tasks by branch name", %{conn: conn} do
      # The SQL search covers the task ID, the prompt/objective opts and the
      # BRANCH NAME — never the heavy `result` blob (the /tasks page load is a
      # lightweight summary projection; see "lightweight page load" below).
      # Each fixture's branch is unique, so a hit proves the branch_name column
      # match. The prompts are what render in the task cards.
      insert_fixture!(
        opts: [prompt: "deploy the delivery scheduling feature"],
        branch_name: "widget-deployment"
      )

      insert_fixture!(
        opts: [prompt: "write the inventory audit report"],
        branch_name: "legacy-parser-refactor"
      )

      insert_fixture!(
        opts: [prompt: "tune the payment gateway timeouts"],
        branch_name: "checkout-race-fix"
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Exact-fragment leg: the query occurs in exactly one fixture's branch
      # name, so only that task row survives the store filter.
      _html = render_hook(view, "search_tasks", %{"search_query" => "widget-deployment"})
      html = flush_tasks_load(view)

      assert html =~ "deploy the delivery scheduling feature"
      refute html =~ "write the inventory audit report"
      refute html =~ "tune the payment gateway timeouts"

      # Case-insensitive leg: re-search the same branch fragment with
      # different casing and the matching fixture still renders.
      _html = render_hook(view, "search_tasks", %{"search_query" => "WIDGET-DEPLOYMENT"})
      html = flush_tasks_load(view)

      assert html =~ "deploy the delivery scheduling feature"
      refute html =~ "write the inventory audit report"
      refute html =~ "tune the payment gateway timeouts"
    end

    test "search_tasks handler no longer matches the agent response (result) blob", %{
      conn: conn
    } do
      # Regression pin for the lightweight /tasks architecture: the WHERE
      # clause searches ID / opts / branch_name only, so text that exists ONLY
      # in a task's `result` can never match again (the result is not even
      # loaded until a card is expanded).
      insert_fixture!(
        opts: [prompt: "deploy the delivery scheduling feature"],
        result: {:ok, %{result: "Widget Deployment finished cleanly"}}
      )

      insert_fixture!(
        opts: [prompt: "write the inventory audit report"],
        result: {:ok, %{result: "Refactored the legacy parser module"}}
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "search_tasks", %{"search_query" => "Widget Deployment"})
      html = flush_tasks_load(view)

      assert html =~ "No tasks found"
      refute html =~ "deploy the delivery scheduling feature"
      refute html =~ "write the inventory audit report"
    end
  end

  describe "filter selects" do
    test "filter_tasks handler filters by status and 'all' shows everything", %{conn: conn} do
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      insert_fixture!(status: :failed, opts: [prompt: "failed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "filter_tasks", %{"status_filter" => "failed"})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "failed one"
      refute render_tasks_list(view) =~ "completed one"

      # "all" clears the status filter again.
      _html = render_hook(view, "filter_tasks", %{"status_filter" => "all"})
      html = flush_tasks_load(view)

      assert html =~ "completed one"
      assert html =~ "failed one"
    end

    test "reset_filters clears all filters including search", %{conn: conn} do
      insert_fixture!(opts: [prompt: "alpha task"])
      insert_fixture!(opts: [prompt: "beta task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Apply a search filter first
      _html = render_hook(view, "search_tasks", %{"search_query" => "alpha"})
      flush_tasks_load(view)
      # Then reset
      _html = render_click(view, "reset_filters")
      html = flush_tasks_load(view)

      assert html =~ "alpha task"
      assert html =~ "beta task"
    end
  end

  describe "reflect chat tasks (show_reflect_tasks reveal toggle)" do
    # :reflect repo-less Home-chat (self-reflective agent) tasks are hidden
    # from the cross-project list by default and only revealed when the
    # "Show chat tasks" checkbox in the filter bar is checked. The toggle is a
    # page-local REVEAL preference, NOT a narrowing filter: it is deliberately
    # left out of reset_filters and the active-filters indicator.

    test "reflect tasks are hidden by default; the reveal checkbox renders unchecked", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "MARKER NORMAL TASK SHOWN BY DEFAULT"])

      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER REFLECT CHAT TASK HIDDEN BY DEFAULT"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # The normal task renders; the :reflect task does NOT.
      assert html =~ "MARKER NORMAL TASK SHOWN BY DEFAULT"
      refute html =~ "MARKER REFLECT CHAT TASK HIDDEN BY DEFAULT"

      # The "Show chat tasks" label renders in the filter bar, and its checkbox
      # (value="true") is present but unchecked (default false).
      assert html =~ "Show chat tasks"
      assert attribute(html, "input[name=show_reflect_tasks]", "value") == ["true"]
      assert attribute(html, "input[name=show_reflect_tasks]", "checked") == []
    end

    test "checking the reveal toggle shows reflect tasks", %{conn: conn} do
      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER REFLECT CHAT TASK REVEALED BY TOGGLE"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # With only a hidden :reflect row the list renders its empty state.
      assert html =~ "No tasks found"
      refute html =~ "MARKER REFLECT CHAT TASK REVEALED BY TOGGLE"

      # A CHECKED daisyUI checkbox submits "true" (an unchecked box would be
      # absent from the form params); the async page load re-runs.
      _html = render_hook(view, "toggle_reflect_tasks", %{"show_reflect_tasks" => "true"})
      html = flush_tasks_load(view)

      assert html =~ "MARKER REFLECT CHAT TASK REVEALED BY TOGGLE"
      refute html =~ "No tasks found"
      assert html =~ "Show chat tasks"
      assert attribute(html, "input[name=show_reflect_tasks]", "checked") != []

      # The reveal preference is not counted as an active (narrowing) filter:
      # no active-filters indicator appears just because reflect tasks are shown.
      refute html =~ "Active filters:"
    end

    test "toggle is additive: normal tasks render regardless and other filter assigns survive", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "MARKER KEEPS VISIBLE NORMAL TASK"])
      insert_fixture!(opts: [prompt: "MARKER EXCLUDED NORMAL TASK"])

      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER KEEPS VISIBLE REFLECT CHAT TASK"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Narrow with a search query: the matching normal task renders, the
      # non-matching one is filtered out, and the matching :reflect row is
      # hidden by the reveal preference (it passes the SQL filter but is
      # dropped by visible_tasks/2).
      _html = render_hook(view, "search_tasks", %{"search_query" => "MARKER KEEPS VISIBLE"})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "MARKER KEEPS VISIBLE NORMAL TASK"
      refute render_tasks_list(view) =~ "MARKER EXCLUDED NORMAL TASK"
      refute render_tasks_list(view) =~ "MARKER KEEPS VISIBLE REFLECT CHAT TASK"

      # Toggling reveal ON adds the matching :reflect row without disturbing
      # the search query — the excluded normal task stays excluded.
      _html = render_hook(view, "toggle_reflect_tasks", %{"show_reflect_tasks" => "true"})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "MARKER KEEPS VISIBLE NORMAL TASK"
      assert render_tasks_list(view) =~ "MARKER KEEPS VISIBLE REFLECT CHAT TASK"
      refute render_tasks_list(view) =~ "MARKER EXCLUDED NORMAL TASK"

      # Toggling reveal back OFF (an unchecked box sends no param) hides only
      # the :reflect row; the search query is still intact.
      _html = render_hook(view, "toggle_reflect_tasks", %{})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "MARKER KEEPS VISIBLE NORMAL TASK"
      refute render_tasks_list(view) =~ "MARKER KEEPS VISIBLE REFLECT CHAT TASK"
      refute render_tasks_list(view) =~ "MARKER EXCLUDED NORMAL TASK"
    end

    test "empty store renders the first-run nudge, not the adjust-filters hint", %{conn: conn} do
      # No fixtures at all: genuinely empty DB, no filters, reveal toggle off.
      # total_count == 0, so the empty-state hint falls through to the friendly
      # first-run message (not the "adjust your filters" nudge).
      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ "No tasks found"
      assert html =~ "Tasks will appear here once you start them from the dashboard."
      refute html =~ "Try adjusting your filters or search query."
    end

    test "a store containing only hidden reflect tasks renders the adjust-filters hint", %{
      conn: conn
    } do
      # A single :reflect (repo-less Home-chat) row: total_count > 0 but the
      # reveal toggle is off, so the visible list is empty and the hint tells
      # the user the filter-bar "Show chat tasks" checkbox would un-hide it.
      insert_fixture!(
        type: :reflect,
        opts: [mode: "reflect", prompt: "MARKER ONLY REFLECT CHAT TASK IN STORE"]
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # The visible list is empty and the hidden :reflect row does not render.
      assert html =~ "No tasks found"
      refute html =~ "MARKER ONLY REFLECT CHAT TASK IN STORE"

      # total_count (SQL-truthful) counts the reflect row, so the adjusting
      # hint wins over the first-run nudge.
      assert html =~ "Try adjusting your filters or search query."
      refute html =~ "Tasks will appear here once you start them from the dashboard."
    end
  end

  describe ":task_updated broadcast handling" do
    # The EvoGit runtime broadcasts {:task_updated, task_id, status, node} on
    # the "tasks" PubSub topic (node-identity contract). TasksLive forwards the
    # message to NodeAware.handle_task_info/2, which applies the node filter
    # (only the viewed node's events trigger UI updates) and schedules a
    # debounced reload. These tests verify the handle_info clauses handle these
    # messages gracefully.

    test "handle_info {:task_updated, _, :finalizing, node} does not crash the LiveView", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # Broadcast a :finalizing status transition in the new node-identity shape
      # (the message that previously crashed).
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "test-finalizing", :finalizing, node()}
      )

      # render/1 flushes pending messages synchronously; a crash would propagate here.
      html = render(view)
      assert is_binary(html)
      assert html =~ "All Statuses"

      # The broadcast armed NodeAware's debounce; drain it (plus the
      # mount's async page load) so nothing is left in flight when this suite's
      # isolated Store is torn down (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "handle_info catch-all does not crash on unknown messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # An arbitrary message the LiveView doesn't specifically handle should be
      # swallowed by the catch-all clause rather than crashing.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:some_unexpected_event, 42})

      html = render(view)
      assert is_binary(html)
      assert html =~ "All Statuses"

      # Drain the mount's async page load so no offloaded store read is in
      # flight when this suite's isolated Store is torn down.
      flush_tasks_load(view)
    end
  end

  describe "pagination" do
    # Inserts a task with a deterministic, distinct started_at so ordering is
    # predictable. Index 0 is the oldest; higher indices are more recent and
    # appear first (ORDER BY started_at DESC). Each task gets a unique prompt
    # so tests can assert which page shows what. Optional overrides allow
    # customizing status and prompt for filtering tests.
    defp insert_timed_fixture!(i, opts \\ []) do
      id = "page_fixture_#{System.unique_integer([:positive])}"
      started = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second)

      task = %TaskInfo{
        id: id,
        type: :genesis,
        status: Keyword.get(opts, :status, :completed),
        opts: [path: "/tmp/test", prompt: Keyword.get(opts, :prompt, "task number #{i}")],
        ref: nil,
        started_at: started,
        finished_at: DateTime.add(started, 1, :second),
        logs: [],
        result: nil
      }

      EvoGit.Store.put_task(EvoGit.Store, task)
      id
    end

    test "page 1 shows first page_size tasks and pagination controls appear", %{conn: conn} do
      # Insert page_size + 1 = 26 tasks to trigger pagination (2 pages).
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # Pagination controls should render.
      assert html =~ "Page 1 of 2"

      # "Showing X–Y of Z" text — page 1 shows 1..25 of 26.
      assert html =~ "Showing 1–25 of 26 tasks"

      # The most recent tasks (indices 25..1) should be on page 1.
      assert render_tasks_list(view) =~ "task number 25"
      assert render_tasks_list(view) =~ "task number 1"
      # Index 0 (oldest) is on page 2.
      refute render_tasks_list(view) =~ "task number 0"
    end

    test "navigating to ?page=2 shows the next set", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks?page=2")
      html = flush_tasks_load(view)

      assert html =~ "Page 2 of 2"

      # Page 2 shows the oldest task (index 0).
      assert render_tasks_list(view) =~ "task number 0"
      # Page 2 should NOT show the newest (index 25).
      refute render_tasks_list(view) =~ "task number 25"
    end

    test "invalid page params clamp and do not crash", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      # Non-integer page → defaults to 1.
      {:ok, view_abc, _html} = live(conn, ~p"/tasks?page=abc")
      html_abc = flush_tasks_load(view_abc)
      assert html_abc =~ "Page 1 of 2"

      # Negative page → clamps to 1.
      {:ok, view_neg, _html} = live(conn, ~p"/tasks?page=-1")
      html_neg = flush_tasks_load(view_neg)
      assert html_neg =~ "Page 1 of 2"

      # Out-of-range page → clamps to last page (2).
      {:ok, view_big, _html} = live(conn, ~p"/tasks?page=9999")
      html_big = flush_tasks_load(view_big)
      assert html_big =~ "Page 2 of 2"
      assert html_big =~ "task number 0"
    end

    test "next_page / prev_page / goto_page events navigate correctly", %{conn: conn} do
      for i <- 0..25, do: insert_timed_fixture!(i)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Navigate to page 2 via next_page.
      _html = render_click(view, "next_page")
      html_next = flush_tasks_load(view)
      assert html_next =~ "Page 2 of 2"
      assert html_next =~ "task number 0"

      # Navigate back to page 1 via prev_page.
      _html = render_click(view, "prev_page")
      html_prev = flush_tasks_load(view)
      assert html_prev =~ "Page 1 of 2"
      assert html_prev =~ "task number 25"

      # goto_page jumps straight to the requested page.
      _html = render_click(view, "goto_page", %{"page" => "2"})
      html_goto = flush_tasks_load(view)
      assert html_goto =~ "Page 2 of 2"
      assert html_goto =~ "task number 0"
    end

    test "status filter works across pages (server-side filtering)", %{conn: conn} do
      # Insert 30 tasks: 20 completed + 10 failed. Each gets a distinct
      # started_at so ordering is deterministic, and a unique prompt that
      # encodes the status so we can assert which appear/disappear.
      for i <- 0..19 do
        insert_timed_fixture!(i, status: :completed, prompt: "completed task number #{i}")
      end

      for i <- 0..9 do
        insert_timed_fixture!(i, status: :failed, prompt: "failed task number #{i}")
      end

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = render_hook(view, "filter_tasks", %{"status_filter" => "failed"})
      html = flush_tasks_load(view)

      # 10 failed tasks, page_size 25 → 1 page.
      assert html =~ "Page 1 of 1"
      # "Showing 1–10 of 10 tasks"
      assert html =~ "Showing 1–10 of 10 tasks"

      # The failed prompts should appear.
      assert render_tasks_list(view) =~ "failed task number 9"
      assert render_tasks_list(view) =~ "failed task number 0"

      # The completed prompts should NOT appear.
      refute render_tasks_list(view) =~ "completed task number 19"
      refute render_tasks_list(view) =~ "completed task number 0"
    end
  end

  describe "node-aware behavior" do
    test "task list UI renders (no remote-only info message)", %{conn: conn} do
      insert_fixture!(opts: [prompt: "visible task"])

      {:ok, view, html} = live(conn, ~p"/tasks")

      # The old info message should NOT appear — the full UI always renders.
      refute html =~ "Task history is only available when viewing the local node"
      assert html =~ "Search by task ID, prompt, objective, or response"

      # Drain the mount's async page load so no offloaded store read is in
      # flight when this suite's isolated Store is torn down.
      flush_tasks_load(view)
    end
  end

  describe "page-load dispatch (connected-only, async)" do
    test "a connected navigation spawns exactly one page load", %{conn: conn} do
      install_page_load_hook()
      insert_fixture!(opts: [prompt: "one load task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # handle_params/3 runs on BOTH the disconnected (static) render and the
      # connected mount; only the connected pass may spawn a load. Exactly one
      # spawn here means the discarded static-render load is gone.
      assert_receive :page_load_spawned, 500

      # Corroborating evidence: the monotonic PAGE-LOAD spawn counter
      # advanced once (:page_load_seq is the page load's own counter — the
      # sidebar fetch has a separate :tasks_load_seq). start_async_page_load/3 is
      # the counter's only writer AND the hook's only caller, and this
      # `:sys.get_state/1` is a synchronous round-trip through the view — any
      # second spawn's `send/2` would already have landed in THIS mailbox, so the
      # refute needs no observation window at all.
      assert :sys.get_state(view.pid).socket.assigns.page_load_seq == 1
      refute_receive :page_load_spawned, 0

      html = flush_tasks_load(view)
      assert html =~ "one load task"
    end

    test "the disconnected render kicks off no page load", %{conn: conn} do
      install_page_load_hook()
      insert_fixture!(opts: [prompt: "never loaded on dead render"])

      # A plain HTTP GET runs the disconnected mount + handle_params only.
      conn = get(conn, ~p"/tasks")

      # The static HTML still paints the loading placeholder for the connected
      # pass to replace...
      assert html_response(conn, 200) =~ "Loading tasks..."
      # ...but no load was spawned (its result would only be discarded).
      #
      # Proof the zero-length window below is exact: a plain get/2 drives the
      # disconnected mount + handle_params/3 IN THIS TEST PROCESS (see the hook
      # comment in install_page_load_hook/0), and handle_params/3 reaches the
      # hook's only call site (spawn_page_load/1) ONLY on the connected pass
      # (tasks_live.ex handle_params/3, `if connected?(socket)`). So a wrongly
      # spawned load would `send(self(), :page_load_spawned)` into THIS mailbox
      # during the synchronous get/2 above — the message would already be here
      # when the refute runs, so nothing could arrive later (there is no spawned
      # Task that could produce one: the hook is invoked before any Task exists).
      refute_receive :page_load_spawned, 0
    end

    test "project filter dropdown populates from the async load", %{conn: conn} do
      insert_fixture!(opts: [prompt: "alpha task", path: "/tmp/proj/alpha"])
      insert_fixture!(opts: [prompt: "beta task", path: "/tmp/proj/beta"])

      {:ok, view, html} = live(conn, ~p"/tasks")

      # project_paths is seeded EMPTY — mount/3 runs no blocking store query.
      refute html =~ ~s{value="/tmp/proj/alpha"}
      refute html =~ ~s{value="/tmp/proj/beta"}

      # ...and is filled by the async load's get_unique_paths/1 result.
      html = flush_tasks_load(view)
      assert html =~ ~s{value="/tmp/proj/alpha"}
      assert html =~ ~s{value="/tmp/proj/beta"}
      assert has_element?(view, "#task-filters option[value='/tmp/proj/alpha']")
      assert has_element?(view, "#task-filters option[value='/tmp/proj/beta']")
    end

    test "changing a filter still spawns exactly one page load", %{conn: conn} do
      install_page_load_hook()
      insert_fixture!(opts: [prompt: "filtered task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      assert_receive :page_load_spawned, 500

      _html = render_hook(view, "search_tasks", %{"search_query" => "filtered"})

      assert_receive :page_load_spawned, 500
      # Same reasoning as the "exactly one page load" test above: the seq check
      # is a synchronous round-trip through the view, so it IS the deterministic
      # backstop for an EXTRA spawn (start_async_page_load/3 is the counter's
      # only writer and the hook's only caller) — no window needed.
      assert :sys.get_state(view.pid).socket.assigns.page_load_seq == 2
      refute_receive :page_load_spawned, 0

      html = flush_tasks_load(view)
      assert html =~ "filtered task"
    end
  end

  describe "async page load" do
    test "async page load populates the task list", %{conn: conn} do
      insert_fixture!(opts: [prompt: "async visible task"])

      {:ok, view, html} = live(conn, ~p"/tasks")

      # Deterministic: the async load task cannot apply its result before the
      # initial render, so the loading placeholder is what live/2 returns.
      assert html =~ "Loading tasks..."
      refute html =~ "async visible task"

      html = flush_tasks_load(view)

      assert html =~ "async visible task"
      assert html =~ "1 task found"
      assert html =~ "Page 1 of 1"
    end

    test "stale page-load result is dropped", %{conn: conn} do
      insert_fixture!(opts: [prompt: "real visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      stale_task = %TaskInfo{
        id: "stale_id",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/stale", prompt: "STALE MARKER TASK"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      # Old seq (0 < page_load_seq): dropped by the seq stale-guard.
      send(
        view.pid,
        {:tasks_page_loaded, 0, node(),
         {:ok,
          %{
            tasks: [stale_task],
            current_page: 1,
            total_count: 1,
            total_pages: 1,
            project_paths: []
          }}}
      )

      html = render(view)
      refute html =~ "STALE MARKER TASK"
      assert html =~ "real visible task"

      # Wrong node with a high seq: dropped by the node stale-guard.
      send(
        view.pid,
        {:tasks_page_loaded, 999, :other@host,
         {:ok,
          %{
            tasks: [stale_task],
            current_page: 1,
            total_count: 1,
            total_pages: 1,
            project_paths: []
          }}}
      )

      html = render(view)
      refute html =~ "STALE MARKER TASK"
      assert html =~ "real visible task"
    end

    test "a task_updated broadcast triggers a debounced reload", %{conn: conn} do
      insert_fixture!(opts: [prompt: "event visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # A task seeded AFTER the initial page load is only visible after a reload.
      insert_fixture!(opts: [prompt: "event-added task"])

      # New-shape event from the local node: NodeAware's node filter matches,
      # so the debounced reload is scheduled.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, "t1", :running, node()})

      # Phase 1: the event is processed and the debounce is scheduled.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == true
      end)

      # Phase 2: the debounce fires and kicks off the reload — now ASYNC, so
      # the LiveView does not block on the store and the fresh page arrives on
      # a later {:tasks_page_loaded, ...} message. Wait for that result.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == false
      end)

      list = wait_for_list(view, "event-added task")
      assert list =~ "event visible task"
      assert list =~ "event-added task"
    end

    test "a debounced task event reloads through the async path (never blocking)", %{
      conn: conn
    } do
      install_page_load_hook()
      insert_fixture!(opts: [prompt: "async visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Drain the connected mount's single spawn and pin it deterministically:
      # :page_load_seq is bumped only by start_async_page_load/3 (the hook's only
      # caller), so the `== 1` assertion below fails loudly on any extra mount
      # spawn — and being a synchronous round-trip it also proves every already
      # sent notification is in the mailbox, which is why the refute window is
      # zero length. `seq_before` is read straight after, and the debounced
      # reload must advance it.
      assert_receive :page_load_spawned, 500
      assert :sys.get_state(view.pid).socket.assigns.page_load_seq == 1
      refute_receive :page_load_spawned, 0

      insert_fixture!(opts: [prompt: "async added task"])

      seq_before = :sys.get_state(view.pid).socket.assigns.page_load_seq

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, "t1", :running, node()})

      # Phase 1: node filter matched → debounce scheduled.
      wait_until(fn ->
        :sys.get_state(view.pid).socket.assigns[:tasks_reload_pending] == true
      end)

      # Phase 2: the debounce fires and kicks off an ASYNC page load — the
      # spawn hook fires and the monotonic PAGE-LOAD counter advances (the
      # synchronous sync_apply_page/2 path never touches :page_load_seq, so
      # this proves the reload left the LiveView process).
      assert_receive :page_load_spawned, 2000

      wait_until(fn ->
        :sys.get_state(view.pid).socket.assigns.page_load_seq > seq_before
      end)

      # The debounce flag is cleared immediately (the load runs off-process)...
      wait_until(fn ->
        :sys.get_state(view.pid).socket.assigns[:tasks_reload_pending] == false
      end)

      # ...and the async result lands later and re-renders the list (scoped to
      # #tasks-list, since the sidebar lists completed tasks too).
      list = wait_for_list(view, "async added task")
      assert list =~ "async visible task"
      assert render(view) =~ "2 tasks found"
    end

    test "a debounced reload never blocks the LiveView on the store", %{conn: conn} do
      insert_fixture!(opts: [prompt: "block probe visible"])
      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      insert_fixture!(opts: [prompt: "block probe added"])
      seq_before = :sys.get_state(view.pid).socket.assigns.page_load_seq

      # Freeze the single, serialized task registry. EVERY synchronous read
      # now blocks there (up to the registry's 30s call timeout), which is
      # exactly what separates the async path from the old inline one: if the
      # debounced reload ran `load_page/4` inside the LiveView, the handler
      # below could never complete while the registry is frozen.
      :ok = :sys.suspend(EvoGit.TaskRegistry)

      on_exit(fn ->
        # Safety net (LIFO: runs BEFORE the isolated Store/TaskRegistry
        # teardown registered in setup/1) so a failed assertion can never
        # leave the shared registry frozen for the next suite. The resume is
        # wrapped: the isolated registry is linked to the test process and can
        # die between this whereis/1 check and :sys.resume/1's own name lookup,
        # which then exits with :noproc (a load-dependent flake — see the test
        # policy's teardown-only rescue allowance).
        if Process.whereis(EvoGit.TaskRegistry) do
          try do
            :sys.resume(EvoGit.TaskRegistry)
          catch
            # Expected teardown race — the registry is already gone.
            :exit, _ -> :ok
          end
        end
      end)

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, "t1", :running, node()})

      # The debounce fires and its handler COMPLETES (debounce flag cleared,
      # a page load handed to a supervised task) while the store is still
      # frozen — impossible for a synchronous reload.
      wait_until(fn ->
        assigns = :sys.get_state(view.pid).socket.assigns

        assigns[:tasks_reload_pending] == false and assigns.page_load_seq > seq_before
      end)

      # ...and the LiveView is still responsive (this render round-trips
      # through it) with the reloaded rows NOT yet applied — the query really
      # is off-process, not merely fast.
      refute render_tasks_list(view) =~ "block probe added"

      # Unfreeze: the off-process load completes and its result re-renders.
      :ok = :sys.resume(EvoGit.TaskRegistry)

      list = wait_for_list(view, "block probe added")
      assert list =~ "block probe visible"
    end

    test "a foreign-node task_updated broadcast does not trigger a reload", %{conn: conn} do
      insert_fixture!(opts: [prompt: "event visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # The connected mount spawned its single page load. :page_load_seq is
      # bumped ONLY by start_async_page_load/3, so it is also the deterministic
      # backstop for the no-reload assertion at the end of this test.
      assert :sys.get_state(view.pid).socket.assigns.page_load_seq == 1

      # A task seeded after the initial load would only render if a reload
      # wrongly fired.
      insert_fixture!(opts: [prompt: "foreign marker task"])

      # Event from a DIFFERENT BEAM node: the node filter must drop it BEFORE
      # the debounce is scheduled.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "t1", :running, :remote@elsewhere}
      )

      # Sample across the debounce window: the reload-pending flag must never
      # become true.
      #
      # The window is SHORT because the failure it guards against is fast and
      # fully determined by the 10ms test-seam debounce
      # (:node_aware_reload_debounce_ms): a node-matching event arms the
      # debounce SYNCHRONOUSLY in the handler (NodeAware.debounce_task_reload/1
      # sets :tasks_reload_pending before Process.send_after/3 returns), so the
      # very first :sys.get_state round-trip below — which drains the view's
      # mailbox, the broadcast having been delivered from THIS process — already
      # observes a wrongly armed timer; the added period then covers the
      # timer FIRING (one 10ms test-seam debounce) and a wrongly spawned reload
      # bumping :page_load_seq. Anything longer re-samples the same 10ms debounce.
      deadline = System.monotonic_time(:millisecond) + 12

      check_no_reload = fn check_no_reload ->
        state = :sys.get_state(view.pid)
        assert state.socket.assigns[:tasks_reload_pending] == false

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@wait_poll_ms)
          check_no_reload.(check_no_reload)
        end
      end

      check_no_reload.(check_no_reload)

      # Deterministic backstop on the SAME side effect: a wrongly triggered
      # reload would have bumped the monotonic page-load spawn counter.
      assert :sys.get_state(view.pid).socket.assigns.page_load_seq == 1

      html = render(view)
      assert html =~ "event visible task"
      refute html =~ "foreign marker task"
    end

    test "a task_deleted broadcast triggers a debounced reload", %{conn: conn} do
      insert_fixture!(opts: [prompt: "delete visible task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # Seed + remove a task directly in the store, then broadcast its deletion
      # — the debounced reload must re-read the store and drop the row.
      id = insert_fixture!(opts: [prompt: "delete me task"])
      EvoGit.Store.delete_task(EvoGit.Store, id)

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, id, node()})

      # Phase 1: the event is processed and the debounce is scheduled.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == true
      end)

      # Phase 2: the debounce fires and kicks off the reload ASYNC — wait until
      # the reloaded page (which no longer holds the deleted row) lands.
      wait_until(fn ->
        state = :sys.get_state(view.pid)
        state.socket.assigns[:tasks_reload_pending] == false
      end)

      wait_until(fn -> not (render_tasks_list(view) =~ "delete me task") end, 5000)

      list = render_tasks_list(view)
      assert list =~ "delete visible task"
      refute list =~ "delete me task"
    end
  end

  describe "async page-load exit safety" do
    test "an exiting page-load runner renders a retry-able error state and recovers on retry", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "recover me"])
      install_tasks_page_load_runner(fn _, _, _, _ -> exit(:boom) end)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # `SafeCall.run/1` turned the loader's exit into an error VALUE: the
      # LiveView survives and the loading flag is cleared.
      assert Process.alive?(view.pid)
      wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:tasks_loading] == false end)
      assert :sys.get_state(view.pid).socket.assigns[:tasks_error] != nil

      # Nothing was ever loaded, so the full load-error state renders.
      list = render_tasks_list(view)
      assert list =~ "tasks-load-error"
      assert list =~ "Could not load tasks."
      refute list =~ "recover me"
      refute render(view) =~ "tasks-refresh-error"

      # Restoring the real loader and clicking Retry loads the page.
      Application.delete_env(:evo_dash, :tasks_page_load_runner)
      render_click(view, "retry_load")
      html = flush_tasks_load(view)

      assert html =~ "recover me"
      assert :sys.get_state(view.pid).socket.assigns[:tasks_error] == nil
      refute html =~ "tasks-load-error"
    end

    test "a raising page-load runner fails the same way, without crashing", %{conn: conn} do
      install_tasks_page_load_runner(fn _, _, _, _ -> raise "boom" end)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      assert Process.alive?(view.pid)
      wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:tasks_loading] == false end)
      assert :sys.get_state(view.pid).socket.assigns[:tasks_error] != nil
      assert render_tasks_list(view) =~ "tasks-load-error"

      # Retry with the real runner recovers to the empty state (no fixtures).
      Application.delete_env(:evo_dash, :tasks_page_load_runner)
      render_click(view, "retry_load")
      wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:tasks_error] == nil end)
      flush_tasks_load(view)

      refute render(view) =~ "tasks-load-error"
      assert render(view) =~ "No tasks found"
    end

    test "a failed background reload keeps the loaded rows and shows the refresh-error strip", %{
      conn: conn
    } do
      insert_fixture!(opts: [prompt: "keep me"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      assert render_tasks_list(view) =~ "keep me"

      # Break the loader AFTER the initial load, then trigger the debounced
      # background reload (show_loading? false — the rows stay on screen).
      install_tasks_page_load_runner(fn _, _, _, _ -> exit(:boom) end)
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, "t1", :running, node()})
      wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:tasks_error] != nil end)

      # The previous rows survive; the compact retry strip sits above them and
      # the full-page load-error state is NOT used.
      assert render_tasks_list(view) =~ "keep me"
      html = render(view)
      assert html =~ "tasks-refresh-error"
      assert html =~ "Could not refresh tasks."
      refute html =~ "tasks-load-error"

      # Restoring the loader and clicking Retry clears the error.
      Application.delete_env(:evo_dash, :tasks_page_load_runner)
      render_click(view, "retry_load")
      wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:tasks_error] == nil end)

      refute render(view) =~ "tasks-refresh-error"
      assert render_tasks_list(view) =~ "keep me"
      flush_tasks_load(view)
    end
  end

  describe "cancelling status display" do
    test "renders the Cancelling label with a warning pulsing dot", %{conn: conn} do
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ "cancelling task"
      # Badge label — gettext("Cancelling…") uses a U+2026 ellipsis; assert the
      # stable prefix plus the warning pulsing-dot indicator classes
      # (cancelling shares the transitional warning family via
      # Helpers.task_status_dot_class/1).
      assert html =~ "Cancelling"
      assert html =~ "bg-warning"
    end

    test "status filter includes a cancelling option and filters to cancelling tasks", %{
      conn: conn
    } do
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])
      insert_fixture!(status: :completed, opts: [prompt: "completed one"])

      {:ok, view, html} = live(conn, ~p"/tasks")

      # The filter <select> offers the :cancelling status with the gettext label.
      # (The option body renders with newline indentation around the label.)
      assert html =~ ~r/<option value="cancelling"[^>]*>\s*Cancelling\s*<\/option>/

      _filtered = render_hook(view, "filter_tasks", %{"status_filter" => "cancelling"})
      flush_tasks_load(view)

      assert render_tasks_list(view) =~ "cancelling one"
      refute render_tasks_list(view) =~ "completed one"
    end
  end

  describe "review button" do
    test "renders a Review button for a cancelled task with a branch result", %{conn: conn} do
      id =
        insert_fixture!(
          status: :cancelled,
          result:
            {:ok,
             %{
               branch_name: "evogit/cancelled-branch",
               commit_sha: "deadbeef",
               result: "summary"
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ ~s(href="/review/#{id}")
      assert html =~ "Review"
    end

    test "renders a Review button for a cancelled task with a no_changes result", %{conn: conn} do
      id = insert_fixture!(status: :cancelled, result: {:ok, %{no_changes: true}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      assert html =~ ~s(href="/review/#{id}")
      assert html =~ "Review"
    end

    test "does not render a Review button for failed, cancelling, running, or pending tasks", %{
      conn: conn
    } do
      # The failed task uses the force-killed shape: result nil.
      insert_fixture!(status: :failed, result: nil, opts: [prompt: "failed one"])
      insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])
      insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running one"])
      insert_fixture!(status: :pending, finished_at: nil, opts: [prompt: "pending one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # No task card may link to the review page.
      refute html =~ ~r{href="/review/"}
    end
  end

  describe "cancel task action" do
    test "Cancel button renders only for pending and running tasks", %{conn: conn} do
      pending_id =
        insert_fixture!(status: :pending, finished_at: nil, opts: [prompt: "pending one"])

      running_id =
        insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running one"])

      completed_id = insert_fixture!(status: :completed, opts: [prompt: "completed one"])
      cancelled_id = insert_fixture!(status: :cancelled, opts: [prompt: "cancelled one"])

      cancelling_id =
        insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])

      finalizing_id =
        insert_fixture!(status: :finalizing, finished_at: nil, opts: [prompt: "finalizing one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      cancel_buttons =
        html
        |> then(&Regex.scan(~r/<button[^>]*phx-click="open_cancel_modal"[^>]*>/, &1))
        |> List.flatten()

      # The visibility guard is @task.status in [:pending, :running] — exactly
      # two cancel buttons (one per in-flight fixture), none for terminal states.
      assert length(cancel_buttons) == 2
      assert Enum.any?(cancel_buttons, &(&1 =~ pending_id))
      assert Enum.any?(cancel_buttons, &(&1 =~ running_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ completed_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ cancelled_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ cancelling_id))
      refute Enum.any?(cancel_buttons, &(&1 =~ finalizing_id))
    end

    test "open_cancel_modal shows the confirmation modal", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_cancel_modal", %{"task_id" => id})

      assert html =~ "Cancel Task?"

      assert html =~
               "All agents of this task will be informed to immediately save their changes and exit. Intermediate results will be saved."

      assert html =~ "Keep Running"

      # Drain the mount's async page load so no offloaded store read is in
      # flight when this suite's isolated Store is torn down.
      flush_tasks_load(view)
    end

    test "close_cancel_modal closes the modal without changing the store", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_cancel_modal", %{"task_id" => id})
      assert html =~ "Cancel Task?"

      html = render_click(view, "close_cancel_modal", %{})
      refute html =~ "Cancel Task?"

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running

      # Drain the mount's async page load (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "confirm_cancel_task on a pending task marks it cancelled immediately", %{conn: conn} do
      id = insert_fixture!(status: :pending, finished_at: nil, opts: [prompt: "pending task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_cancel_modal", %{"task_id" => id})
      render_click(view, "confirm_cancel_task", %{})

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :cancelled

      # Drains the mount page load AND the debounce armed by the cancellation's
      # own {:task_updated, ...} broadcast (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "confirm_cancel_task on a running task transitions it to :cancelling", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_cancel_modal", %{"task_id" => id})
      render_click(view, "confirm_cancel_task", %{})

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :cancelling

      # Drains the mount page load AND the debounce armed by the cancellation's
      # own {:task_updated, ...} broadcast (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "confirm_cancel_task on a completed task flashes an error", %{conn: conn} do
      id = insert_fixture!(status: :completed, opts: [prompt: "completed task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_cancel_modal", %{"task_id" => id})
      html = render_click(view, "confirm_cancel_task", %{})

      assert html =~ "Failed to cancel task"

      # Drain the mount's async page load so no offloaded store read is in
      # flight when this suite's isolated Store is torn down.
      flush_tasks_load(view)
    end

    test "confirm_cancel_task without opening the modal is a no-op", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_click(view, "confirm_cancel_task", %{})

      assert html =~ "running task"
      refute html =~ "Failed to cancel task"
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end
  end

  describe "force kill action" do
    test "dropdown menu is always present; force kill item only for running/cancelling", %{
      conn: conn
    } do
      running_id =
        insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running one"])

      cancelling_id =
        insert_fixture!(status: :cancelling, finished_at: nil, opts: [prompt: "cancelling one"])

      completed_id = insert_fixture!(status: :completed, opts: [prompt: "completed one"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # The three-dot dropdown <ul> menu is always in the DOM (CSS-hidden).
      assert html =~ "menu menu-sm dropdown-content"

      force_kill_buttons =
        html
        |> then(&Regex.scan(~r/<button[^>]*phx-click="open_force_kill_modal"[^>]*>/, &1))
        |> List.flatten()

      # Force kill item renders for :running and :cancelling only; the "Danger
      # zone" divider ships in the same conditional block.
      assert length(force_kill_buttons) == 2
      assert Enum.any?(force_kill_buttons, &(&1 =~ running_id))
      assert Enum.any?(force_kill_buttons, &(&1 =~ cancelling_id))
      refute Enum.any?(force_kill_buttons, &(&1 =~ completed_id))
      assert html =~ "Danger zone"
      assert html =~ "Force kill"

      # The existing Delete item keeps its phx-click + phx-confirm wiring.
      assert html =~ ~s(phx-click="delete_task")
      assert html =~ ~s(phx-confirm="Delete this task?")
    end

    test "open_force_kill_modal shows the confirmation modal", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_force_kill_modal", %{"task_id" => id})

      assert html =~ "Force Kill Task?"
      assert html =~ "ALL progress will be completely lost. This cannot be undone."
      assert html =~ "Force Kill"

      # Drain the mount's async page load so no offloaded store read is in
      # flight when this suite's isolated Store is torn down.
      flush_tasks_load(view)
    end

    test "close_force_kill_modal closes the modal without changing the store", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      html = render_click(view, "open_force_kill_modal", %{"task_id" => id})
      assert html =~ "Force Kill Task?"

      html = render_click(view, "close_force_kill_modal", %{})
      refute html =~ "Force Kill Task?"

      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running

      # Drain the mount's async page load (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "confirm_force_kill_task on a store-only running task flashes an error", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_force_kill_modal", %{"task_id" => id})
      html = render_click(view, "confirm_force_kill_task", %{})

      # NEW wording ("Failed to force kill task: %{reason}") — a sibling lib
      # change not yet merged into this worktree. This single assertion may fail
      # locally until that change lands; it must NOT be weakened to the old
      # shared msgid ("Failed to cancel task: ...").
      assert html =~ "Failed to force kill task"

      # Drains the mount page load AND any debounce armed by the handler's
      # broadcast (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "confirm_force_kill_task on an owned running task force-kills the wrapper", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      wrapper = spawn(fn -> Process.sleep(:infinity) end)

      # Inject the wrapper into the registry's in-memory task_refs so the
      # force-kill path sees an owned, alive task — store-only fixtures have no
      # task_refs entry and return {:error, :not_running}. The replace_state fun
      # runs inside the TaskRegistry process, so self() here IS the owner that
      # Task.shutdown/2 later validates against.
      :sys.replace_state(EvoGit.TaskRegistry, fn state ->
        task_ref = %Task{pid: wrapper, ref: make_ref(), owner: self(), mfa: nil}

        %{state | task_refs: Map.put(state.task_refs, id, task_ref)}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_click(view, "open_force_kill_modal", %{"task_id" => id})
      render_click(view, "confirm_force_kill_task", %{})

      # Backend contract: force kill ⇒ :failed with result nil. The evo_git
      # persistence change lands in a parallel workstream, so this assertion
      # may fail until then — do NOT revert it.
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :failed
      refute Process.alive?(wrapper)

      # Drains the mount page load AND the debounce armed by the force-kill's
      # own {:task_updated, ...} broadcast (see flush_tasks_load/2).
      flush_tasks_load(view)
    end

    test "confirm_force_kill_task without opening the modal is a no-op", %{conn: conn} do
      id = insert_fixture!(status: :running, finished_at: nil, opts: [prompt: "running task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_click(view, "confirm_force_kill_task", %{})

      assert html =~ "running task"
      refute html =~ "Failed to force kill task"
      assert EvoGit.Store.get_task(EvoGit.Store, id).status == :running
    end
  end

  describe "task detail view" do
    # Long objective/result fixtures: the old detail view truncated the
    # objective at 300 chars server-side; the flattened view renders the full
    # text in a scrollable container, so the tail marker must appear.
    test "expanded card renders the flattened Objective and Agent Message cards", %{conn: conn} do
      long_objective =
        "Build a web app. " <>
          String.duplicate("more words here ", 30) <> " OBJECTIVE TAIL MARKER"

      long_result =
        "The agent finished the work. " <>
          String.duplicate("more words here ", 30) <> " RESULT TAIL MARKER"

      id =
        insert_fixture!(
          opts: [prompt: long_objective, mode: "simple", path: "/tmp/test"],
          result:
            {:ok,
             %{
               result: long_result,
               commit_sha: "abc1234",
               branch_name: "genesis/agent_1",
               tag: "v1.0.0",
               pr_url: "https://example.com/pr"
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)

      # Flattened structure: "Objective" and "Agent Message" are direct h4 card
      # headers. The old nested "Options"/"Result" card headers are gone —
      # scoped to <h4> so the plain "Result"/"Options" words inside the
      # `<!-- Full Result Modal -->` / `<!-- Full Options Modal -->` HTML
      # comments (which HEEx emits verbatim) can't false-positive.
      h4_headers = h4_header_texts(html)
      assert "Objective" in h4_headers
      assert "Agent Message" in h4_headers
      refute "Options" in h4_headers
      refute "Result" in h4_headers

      # The full objective text renders (beyond the old 300-char truncation) in
      # a scrollable container.
      assert html =~ "OBJECTIVE TAIL MARKER"
      assert html =~ "max-h-48"
      assert html =~ "overflow-y-auto"

      # Objective card: copy + Full buttons, with the full text in data-content.
      assert html =~ ~s(phx-click="view_full_options")
      assert attribute(html, "#task-#{id}-objective-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#task-#{id}-objective-copy") =~ "OBJECTIVE TAIL MARKER"

      # Agent Message card: copy + Full buttons, with the full result text in
      # data-content.
      assert html =~ ~s(phx-click="view_full_result")
      assert attribute(html, "#task-#{id}-result-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#task-#{id}-result-copy") =~ "RESULT TAIL MARKER"

      # Result badges are preserved: branch, commit, tag, and PR link.
      assert html =~ "genesis/agent_1"
      assert html =~ "abc1234"
      assert html =~ "v1.0.0"
      assert html =~ "View PR"
      assert html =~ ~s(href="https://example.com/pr")

      # Mode/path badges render in the Objective card body.
      assert html =~ "simple"
      assert html =~ "/tmp/test"

      # Toggling again collapses the detail cards.
      collapsed = render_hook(view, "toggle_task_details", %{"task_id" => id})
      refute collapsed =~ "Agent Message"
    end

    test "error result renders the Error state and an inspected copy payload", %{conn: conn} do
      id = insert_fixture!(result: {:error, "explosion happened"})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)

      assert html =~ "Agent Message"
      assert html =~ "Error"
      assert html =~ "explosion happened"

      # result_copy_text({:error, reason}) inspects the reason, so the copy
      # payload is the quoted string "explosion happened" (Floki may or may not
      # decode the &quot; entities — assert the stable substring).
      assert data_content(html, "#task-#{id}-result-copy") =~ "explosion happened"
    end

    test "no-changes result renders the No Changes notice", %{conn: conn} do
      id = insert_fixture!(result: {:ok, %{no_changes: true, result: "nothing to do"}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)

      assert html =~ "Agent Message"
      assert html =~ "No Changes"
      assert html =~ "The agent completed without making any changes to the codebase."
      assert html =~ "nothing to do"
      assert data_content(html, "#task-#{id}-result-copy") == "nothing to do"
    end

    test "view_full_result opens the zoomed Task Result modal with a copy button", %{conn: conn} do
      long_result = "The agent finished the work. " <> String.duplicate("more words here ", 30)
      id = insert_fixture!(result: {:ok, %{result: long_result}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)
      assert html =~ "Agent Message"

      html = render_hook(view, "view_full_result", %{"task_id" => id})

      assert html =~ "Task Result"
      assert attribute(html, "#full-result-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#full-result-copy") == long_result
    end

    test "view_full_options opens the zoomed Full Objective modal with a copy button", %{
      conn: conn
    } do
      long_objective =
        "Build a web app. " <>
          String.duplicate("more words here ", 30) <> " OBJECTIVE TAIL MARKER"

      id = insert_fixture!(opts: [prompt: long_objective])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      _html = expand_card(view, id)

      html = render_hook(view, "view_full_options", %{"task_id" => id})

      assert html =~ "Full Objective"
      assert attribute(html, "#full-options-copy", "phx-hook") == ["ClipboardCopy"]
      assert data_content(html, "#full-options-copy") == long_objective
    end

    test "copied event flashes the confirmation message", %{conn: conn} do
      insert_fixture!(opts: [prompt: "some objective"], result: {:ok, %{result: "some result"}})

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = render_hook(view, "copied", %{})

      assert html =~ "Copied to clipboard"
    end
  end

  describe "task result repos dimension" do
    # Multi-repo results carry a top-level `repos` map (STRING keys):
    # `%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}` —
    # `"primary"` ALWAYS present (branch_name nil when the primary produced no
    # changes), writable foreign repos with commits present, read-only repos
    # absent. Legacy results have NO `repos` key and must render unchanged.
    # The Store Codec keeps the top-level `repos` key STRING-keyed after the
    # round trip (unknown result keys are never atomized), so fixtures pass
    # through the same shape the core produces.
    test "collapsed card shows the compact per-repo indicator", %{conn: conn} do
      # From a SUMMARY row a task is "multi-repo" only through
      # `opts[:foreign_repos]` — the result's `repos` map lives in the lazy
      # per-card detail. The summary-derived indicator therefore lists every
      # configured repo id plus the primary repo's short sha.
      id =
        insert_fixture!(
          commit_sha: "aaaaaaa1111111",
          branch_name: "genesis/agent_1",
          opts: [
            prompt: "multi-repo work",
            foreign_repos: [
              %{id: "legacy-api", root: "/tmp/legacy", description: "x", writable: true},
              %{id: "readme-tools", root: "/tmp/readme", description: "y", writable: false}
            ]
          ],
          result:
            {:ok,
             %{
               result: "multi-repo work done",
               commit_sha: "aaaaaaa1111111",
               branch_name: "genesis/agent_1",
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: "genesis/agent_1"},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"},
                 "readme-tools" => %{commit_sha: "ccccccc3333333", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # Collapsed indicator: repo ids + the primary short sha (first 7 chars)
      # visible without expanding. The foreign shas are NOT part of the
      # summary projection.
      assert html =~ "legacy-api:"
      assert html =~ "readme-tools:"
      assert html =~ "aaaaaaa"

      # Once the lazy detail has landed, collapsing again renders the ENRICHED
      # indicator from the result's `repos` map (the cache survives a collapse).
      _expanded = expand_card(view, id)
      collapsed = render_hook(view, "toggle_task_details", %{"task_id" => id})

      assert collapsed =~ "legacy-api:"
      assert collapsed =~ "readme-tools:"
      assert collapsed =~ "aaaaaaa"
      assert collapsed =~ "bbbbbbb"
      assert collapsed =~ "ccccccc"
    end

    test "expanded card renders the per-repo Repositories section", %{conn: conn} do
      id =
        insert_fixture!(
          opts: [prompt: "multi-repo work"],
          result:
            {:ok,
             %{
               result: "multi-repo work done",
               commit_sha: "aaaaaaa1111111",
               branch_name: "genesis/agent_1",
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: "genesis/agent_1"},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"},
                 "readme-tools" => %{commit_sha: "ccccccc3333333", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)

      assert html =~ "Repositories"
      assert html =~ "legacy-api:"
      assert html =~ "readme-tools:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
      assert html =~ "ccccccc"
      assert html =~ "genesis/agent_1"
    end

    test "full-result modal renders the per-repo Repositories section", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "multi-repo work done",
               commit_sha: "aaaaaaa1111111",
               branch_name: "genesis/agent_1",
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: "genesis/agent_1"},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # The modal state is derived from the LAZY detail cache, so the card must
      # be expanded (and its detail flushed) before the modal can be `:ok`.
      _expanded = expand_card(view, id)

      html = render_hook(view, "view_full_result", %{"task_id" => id})

      assert html =~ "Task Result"
      assert html =~ "Repositories"
      assert html =~ "legacy-api:"
      assert html =~ "aaaaaaa"
      assert html =~ "bbbbbbb"
    end

    test "legacy task without repos renders exactly as before", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "legacy summary",
               commit_sha: "abc1234",
               branch_name: "genesis/agent_old"
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      html = flush_tasks_load(view)

      # No per-repo indicator on the collapsed card.
      refute html =~ "Repositories"

      html = expand_card(view, id)

      # Existing badges/behavior unchanged.
      assert html =~ "Agent Message"
      assert html =~ "legacy summary"
      assert html =~ "abc1234"
      assert html =~ "genesis/agent_old"
      refute html =~ "Repositories"
    end

    test "repos with a nil primary branch (no changes) renders gracefully", %{conn: conn} do
      id =
        insert_fixture!(
          result:
            {:ok,
             %{
               result: "nothing to do",
               no_changes: true,
               commit_sha: "aaaaaaa1111111",
               branch_name: nil,
               repos: %{
                 "primary" => %{commit_sha: "aaaaaaa1111111", branch_name: nil},
                 "legacy-api" => %{commit_sha: "bbbbbbb2222222", branch_name: "genesis/agent_1"}
               }
             }}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)

      # The No Changes notice still renders (primary had no commits)…
      assert html =~ "No Changes"
      assert html =~ "nothing to do"

      # …and the Repositories section shows the primary short sha with a muted
      # "no changes" hint plus the foreign repo's branch.
      assert html =~ "Repositories"
      assert html =~ "aaaaaaa"
      assert html =~ "no changes"
      assert html =~ "legacy-api:"
      assert html =~ "bbbbbbb"
      assert html =~ "genesis/agent_1"
    end
  end

  # The 16 summary keys of the lightweight /tasks page load (the
  # `EvoDash.NodeContext.list_tasks_page/2` projection). `result`, `usage`,
  # `logs` and `archive_metadata` are deliberately absent — they are fetched
  # per card, on demand.
  @summary_keys [
    :id,
    :status,
    :review_status,
    :started_at,
    :finished_at,
    :type,
    :project_path,
    :opts,
    :branch_name,
    :model_id,
    :agent_count,
    :base_sha,
    :commit_sha,
    :lease_expires_at,
    :updated_at,
    :error
  ]

  describe "lightweight page load (summary rows)" do
    test "the page assigns summary-shaped rows with no heavy blobs", %{conn: conn} do
      insert_fixture!(opts: [prompt: "summary row task"])

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      tasks = :sys.get_state(view.pid).socket.assigns.tasks
      assert is_list(tasks) and tasks != []

      for row <- tasks do
        for key <- @summary_keys do
          assert Map.has_key?(row, key), "summary row is missing #{inspect(key)}"
        end

        for heavy <- [:result, :archive_metadata, :usage, :logs] do
          refute Map.has_key?(row, heavy), "summary row must not carry #{inspect(heavy)}"
        end
      end
    end

    test "a multi-MB result never rides the page load", %{conn: conn} do
      big = String.duplicate("multi-mb-payload ", 140_000)
      assert byte_size(big) > 2_000_000

      insert_fixture!(
        opts: [prompt: "big payload task"],
        result: {:ok, %{result: big, commit_sha: "abc1234"}}
      )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      page_rows = :sys.get_state(view.pid).socket.assigns.tasks
      assert length(page_rows) == 1

      # The full-row read of the SAME row for comparison.
      {full_rows, _total} = EvoDash.NodeContext.list_tasks_paginated(node(), limit: 50)
      assert length(full_rows) == 1

      page_bytes = term_bytes(page_rows)
      full_bytes = term_bytes(full_rows)

      # The summary page carries no payload at all — it stays orders of
      # magnitude below the full-row read (and far below the blob itself).
      assert page_bytes * 50 <= full_bytes,
             "expected the summary page (#{page_bytes} B) to be at least 50× " <>
               "smaller than the full-row read (#{full_bytes} B)"

      assert page_bytes < div(byte_size(big), 50)
    end
  end

  describe "lazy per-card detail" do
    test "expanding a card triggers exactly ONE async lite fetch", %{conn: conn} do
      id =
        insert_fixture!(
          opts: [prompt: "one fetch task"],
          result: {:ok, %{result: "the agent message", commit_sha: "abc1234"}}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      full = EvoDash.NodeContext.get_task_lite(node(), id)
      assert %EvoGit.TaskInfo{} = full

      test_pid = self()

      # The injected runner HOLDS its result until the test releases it, so the
      # in-flight ("loading") state is observable deterministically instead of
      # racing an extra LiveViewTest render round-trip.
      install_task_detail_runner(fn _node, task_id ->
        send(test_pid, {:detail_fetch, task_id, self()})

        receive do
          :release_detail -> full
        after
          5000 -> full
        end
      end)

      # The expand returns while the detail is still in flight — the card shows
      # its loading state, never a stale/empty heavy section.
      loading_html = render_hook(view, "toggle_task_details", %{"task_id" => id})
      assert loading_html =~ ~s(id="task-#{id}-detail-loading")
      assert loading_html =~ "Loading task details…"
      # Scope to the rendered <h4> headers — the template's own HTML comments
      # also mention "Agent Message" (the file's h4_header_texts/1 idiom).
      refute "Agent Message" in h4_header_texts(loading_html)

      assert_receive {:detail_fetch, ^id, child}, 2000

      # A second toggle while the first fetch is in flight is a COLLAPSE: the
      # cache/in-flight guard in TaskDetail.ensure/2 never refetches. Asserted
      # against the supervised-task registry instead of a timed mailbox window:
      # the only fetch in flight must still be the FIRST one, and no second
      # child may exist. This is exact, not a 100ms sample.
      collapsed_html = render_hook(view, "toggle_task_details", %{"task_id" => id})
      refute collapsed_html =~ "Loading task details…"
      assert [^child] = view_async_task_pids(view.pid)
      refute_receive {:detail_fetch, ^id, _pid}, 0

      send(child, :release_detail)
      wait_until(fn -> match?(%{state: :ok}, detail_entry(view, id)) end)
      drain_async_loads(view, 5000)

      # Re-expanding renders from the landed cache — still exactly ONE fetch
      # for the whole lifecycle of this card.
      html = render_hook(view, "toggle_task_details", %{"task_id" => id})
      assert html =~ "Agent Message"
      assert html =~ "the agent message"
      refute_receive {:detail_fetch, ^id, _pid}, 0
    end

    test "a failing or nil detail fetch renders the inline error state without crashing", %{
      conn: conn
    } do
      id =
        insert_fixture!(
          opts: [prompt: "failing detail task"],
          result: {:ok, %{result: "should not be visible while failing"}}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      # `nil` (the task vanished between the page load and the expand) becomes
      # `:not_found` without crashing the LiveView.
      install_task_detail_runner(fn _node, _task_id -> nil end)
      render_hook(view, "toggle_task_details", %{"task_id" => id})
      wait_until(fn -> match?(%{state: :error}, detail_entry(view, id)) end)
      drain_async_loads(view, 5000)

      html = render(view)
      assert html =~ ~s(id="task-#{id}-detail-error")
      assert html =~ "Could not load task details."
      assert html =~ ~s(phx-click="retry_task_detail")
      assert %{state: :error, error: :not_found} = detail_entry(view, id)

      # A runner that EXITS is captured by SafeCall — the LiveView survives and
      # still renders the retry-able error strip.
      install_task_detail_runner(fn _node, _task_id -> exit(:boom) end)
      render_click(view, "retry_task_detail", %{"task_id" => id})
      wait_until(fn -> match?(%{state: :error}, detail_entry(view, id)) end)
      drain_async_loads(view, 5000)

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ ~s(id="task-#{id}-detail-error")
      assert html =~ ~s(phx-click="retry_task_detail")
      assert %{state: :error, error: {:exit, :boom}} = detail_entry(view, id)

      # Retry with a working runner recovers the card in place.
      install_task_detail_runner(&EvoDash.NodeContext.get_task_lite/2)
      render_click(view, "retry_task_detail", %{"task_id" => id})
      wait_until(fn -> match?(%{state: :ok}, detail_entry(view, id)) end)
      drain_async_loads(view, 5000)

      html = render(view)
      assert html =~ "Agent Message"
      assert html =~ "should not be visible while failing"
      refute html =~ ~s(id="task-#{id}-detail-error")
    end

    test "a PubSub update invalidates the cached detail; a delete drops it", %{conn: conn} do
      id =
        insert_fixture!(
          opts: [prompt: "invalidate task"],
          result: {:ok, %{result: "first result"}}
        )

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      expand_card(view, id)
      assert match?(%{state: :ok}, detail_entry(view, id))

      test_pid = self()

      install_task_detail_runner(fn node, task_id ->
        send(test_pid, {:detail_fetch, task_id})
        EvoDash.NodeContext.get_task_lite(node, task_id)
      end)

      # An update broadcast on the viewed node drops the EXPANDED card's cache
      # entry and refetches it immediately (the open card shows loading, then
      # the fresh detail — it never blanks out). NOTE: BOTH TasksLive and
      # NodeAware subscribe to the "tasks" topic, so one broadcast is delivered
      # twice; the assertion is therefore "at least one refetch", not a pinned
      # count.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, :completed, node()})

      assert_receive {:detail_fetch, ^id}, 2000
      wait_until(fn -> match?(%{state: :ok}, detail_entry(view, id)) end)
      drain_async_loads(view, 5000)
      flush_detail_fetches(id)
      assert match?(%{state: :ok}, detail_entry(view, id))
      refute_receive {:detail_fetch, ^id}, 0

      # Collapse (the cache is retained), then a DELETE broadcast drops the
      # entry without refetching a collapsed card.
      render_hook(view, "toggle_task_details", %{"task_id" => id})
      assert match?(%{state: :ok}, detail_entry(view, id))

      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_deleted, id, node()})
      wait_until(fn -> detail_entry(view, id) == nil end)
      # Drain FIRST (the delete also arms NodeAware's trailing-edge reload), so
      # the zero-timeout flush/refute below are exact — see flush_detail_fetches/1.
      drain_async_loads(view, 5000)
      flush_detail_fetches(id)
      refute_receive {:detail_fetch, ^id}, 0

      assert detail_entry(view, id) == nil
    end
  end

  # --- paged archive fixtures & helpers ---

  # `count` root archive records with STRING keys and NO "result" key — exactly
  # what ONE page of `NodeContext.list_task_archives/3` returns with
  # `include_results: false`.
  defp paged_archive(count) do
    for i <- 1..count do
      %{
        "agent_id" => "agent-#{i}",
        "parent_id" => nil,
        "depth" => 0,
        "objective" => "objective of agent-#{i}"
      }
    end
  end

  # The 3-arity archive PAGE runner: reports every request to the test process
  # and returns the requested slice plus the TRUE total.
  defp paging_runner(entries, test_pid) do
    fn node, task_id, opts ->
      send(test_pid, {:archive_page, node, task_id, opts})
      offset = Keyword.get(opts, :offset, 0)
      limit = Keyword.get(opts, :limit, 100)

      %{entries: Enum.slice(entries, offset, limit), total: length(entries)}
    end
  end

  # The card's cached archive envelope (nil when no archive has been requested
  # or after an invalidation).
  defp archive_entry(view, task_id) do
    case detail_entry(view, task_id) do
      %{archive: archive} -> archive
      _ -> nil
    end
  end

  # Waits for the archive envelope to satisfy `predicate`, then drains the async
  # work and re-renders.
  defp wait_for_archive(view, task_id, predicate, timeout \\ 5000) do
    wait_until(fn -> predicate.(archive_entry(view, task_id)) end, timeout)
    drain_async_loads(view, timeout)
  end

  defp archive_ids(view, task_id) do
    view
    |> archive_entry(task_id)
    |> Map.get(:entries, [])
    |> Enum.map(& &1["agent_id"])
  end

  defp agent_result_state(view, task_id, agent_id) do
    with archive when is_map(archive) <- archive_entry(view, task_id) do
      get_in(archive, [:agent_results, agent_id, :state])
    else
      _ -> nil
    end
  end

  # Every archive "Export JSON" href of the rendered page.
  defp export_hrefs(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(a[href*="/export"]))
    |> Floki.attribute("href")
  end

  # Simulates NodeAware's `?node=` resolution to a CONNECTED remote target. The
  # suite has no distribution link to a real remote BEAM, so the resolved node
  # atom is written straight onto the socket exactly as `assign_node/2` does
  # (through `assign/2`, so HEEx change tracking re-renders node-aware markup).
  # `node_id` (the `?node=` target id) mirrors the second NodeAware assign that
  # node-aware links read.
  defp set_current_node(view, node) do
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.current_node, node)
    end)
  end

  describe "lazy per-card archive" do
    test "the first page fetches only on click and reports the true total", %{conn: conn} do
      id =
        insert_fixture!(
          opts: [archive: true, prompt: "archived task"],
          result: {:ok, %{result: "done"}}
        )

      test_pid = self()
      install_task_archive_runner(paging_runner(paged_archive(3), test_pid))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)

      html = expand_card(view, id)

      # Disclosure only: the opt-in section renders, no records do.
      assert html =~ "Archived Agent Details"
      assert html =~ "The archive loads on demand."
      assert html =~ ~s(phx-click="load_task_archive")
      refute html =~ "objective of agent-1"
      refute html =~ "Export JSON"
      # expand_card/3 already drained, so nothing is in flight: exact, not sampled.
      refute_receive {:archive_page, _, _, _}, 0

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))

      assert_receive {:archive_page, node, ^id, opts}, 2000
      assert node == node()
      assert opts[:limit] == 100
      assert opts[:offset] == 0
      refute opts[:include_results]

      html = render(view)
      assert html =~ "3 agents"
      assert html =~ "objective of agent-1"
      assert html =~ "Export JSON"
      # LOCAL node: the export href stays byte-for-byte what it always was.
      assert export_hrefs(html) == ["/tasks/#{id}/export"]
      # Every entry omits its "result" until it is asked for.
      assert html =~ "Show result"
      # Everything is loaded, so there is nothing more to page in.
      refute html =~ ~s(phx-click="load_more_task_archive")
    end

    test "an empty archive renders the empty state", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "empty archive task"])

      install_task_archive_runner(fn _node, _task_id, _opts ->
        %{entries: [], total: 0}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok, total: 0}, &1))

      html = render(view)
      assert html =~ "No archived agents for this task."
    end

    test "an archive fetch failure renders the error strip and recovers on retry", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "archive error task"])

      counter = :counters.new(1, [])

      install_task_archive_runner(fn _node, _task_id, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          raise "archive boom"
        else
          %{entries: paged_archive(2), total: 2}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :error}, &1))

      assert Process.alive?(view.pid)
      html = render(view)
      assert html =~ "Could not load the task archive."
      assert html =~ ~s(phx-click="load_task_archive")
      refute html =~ "objective of agent-1"

      # The strip's Retry is the same event; the second call succeeds.
      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))

      html = render(view)
      assert html =~ "objective of agent-1"
      refute html =~ "Could not load the task archive."
    end

    test "Load more appends the next page at offset 100 in order, without duplicates", %{
      conn: conn
    } do
      id = insert_fixture!(opts: [archive: true, prompt: "paged task"])

      test_pid = self()
      install_task_archive_runner(paging_runner(paged_archive(250), test_pid))

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok, total: 250}, &1))
      assert_receive {:archive_page, _node, ^id, first_opts}, 2000
      assert first_opts[:offset] == 0

      assert archive_ids(view, id) == Enum.map(1..100, &"agent-#{&1}")
      assert render(view) =~ "250 agents — showing 1–100"
      assert render(view) =~ ~s(phx-click="load_more_task_archive")

      render_hook(view, "load_more_task_archive", %{"task_id" => id})

      wait_for_archive(view, id, fn
        %{loading_more?: false, total: 250, entries: entries} -> length(entries) == 200
        _ -> false
      end)

      assert_receive {:archive_page, _node, ^id, more_opts}, 2000
      assert more_opts[:offset] == 100
      assert more_opts[:limit] == 100

      # Order preserved across pages, no duplicate agent ids.
      assert archive_ids(view, id) == Enum.map(1..200, &"agent-#{&1}")
      assert render(view) =~ "250 agents — showing 1–200"

      # The last page finishes the archive and retires the button.
      render_hook(view, "load_more_task_archive", %{"task_id" => id})

      wait_for_archive(view, id, fn
        %{loading_more?: false, total: 250, entries: entries} -> length(entries) == 250
        _ -> false
      end)

      assert_receive {:archive_page, _node, ^id, last_opts}, 2000
      assert last_opts[:offset] == 200

      html = render(view)
      assert html =~ "250 agents"
      refute html =~ "showing"
      refute html =~ ~s(phx-click="load_more_task_archive")
    end

    test "the retention window bounds the envelope and keeps the offset honest", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "huge archive task"])
      test_pid = self()
      # 600 agents = 6 pages of 100: one page MORE than the 500-entry retention
      # window (5 pages), which is exactly what this test must prove. Every page
      # costs one full-page render, so the roster stops at the smallest size that
      # still crosses the bound.
      install_task_archive_runner(paging_runner(paged_archive(600), test_pid))
      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)
      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))
      # Page through the WHOLE roster: 600 agents, 6 pages of 100.
      for _page <- 1..5 do
        render_hook(view, "load_more_task_archive", %{"task_id" => id})
        wait_for_archive(view, id, &match?(%{loading_more?: false}, &1))
      end

      entry = archive_entry(view, id)
      # Only the most recent 500 rows are retained; the evicted ones are counted.
      assert length(entry.entries) == 500
      assert entry.dropped == 100
      assert entry.total == 600
      assert entry.exhausted? == false
      assert Enum.map(entry.entries, & &1["agent_id"]) == Enum.map(101..600, &"agent-#{&1}")
      # Every request offset is the number of rows FETCHED, never the retained
      # length (which stops at the window bound).
      offsets =
        Stream.repeatedly(fn ->
          receive do
            {:archive_page, _node, ^id, opts} -> Keyword.fetch!(opts, :offset)
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert offsets == [0, 100, 200, 300, 400, 500]
      html = render(view)
      refute html =~ ~s(phx-click="load_more_task_archive")
      # The count line stays honest about the omitted leading rows.
      assert html =~ "600 agents — showing 101–600"
      assert html =~ "earlier entries omitted"
    end

    test "a short page exhausts the archive and clamps the pager", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "short archive task"])
      entries = paged_archive(137)

      install_task_archive_runner(fn _node, _task_id, opts ->
        offset = Keyword.get(opts, :offset, 0)
        %{entries: Enum.slice(entries, offset, 100), total: 250}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)
      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))
      render_hook(view, "load_more_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{loading_more?: false}, &1))
      entry = archive_entry(view, id)
      # The server counted 250 rows it will never return: the EFFECTIVE total is
      # what was fetched, so the pager stops; the label keeps the larger count.
      assert length(entry.entries) == 137
      assert entry.exhausted? == true
      assert entry.total == 137
      assert entry.server_total == 250
      html = render(view)
      refute html =~ ~s(phx-click="load_more_task_archive")
      assert html =~ "250 agents"
      assert html =~ "No more archive entries."
    end

    test "a page without a total still loads (lean roster projection)", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "no total task"])
      entries = paged_archive(3)
      install_task_archive_runner(fn _node, _task_id, _opts -> %{entries: entries} end)
      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)
      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))
      entry = archive_entry(view, id)
      # The short page exhausts the archive; with no COUNT(*) the total is the
      # fetched row count and no pager renders.
      assert length(entry.entries) == 3
      assert entry.server_total == nil
      assert entry.total == 3
      assert entry.exhausted? == true
      assert archive_ids(view, id) == ["agent-1", "agent-2", "agent-3"]
      html = render(view)
      assert html =~ "3 agents"
      refute html =~ ~s(phx-click="load_more_task_archive")
    end

    test "a retried page is idempotent (no duplicate agent ids)", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "retried page task"])

      entries = paged_archive(250)

      # A runner that ignores the offset and always answers with page 1 — the
      # worst case for an append (a retried/duplicated page).
      install_task_archive_runner(fn _node, _task_id, _opts ->
        %{entries: Enum.take(entries, 100), total: 250}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok, total: 250}, &1))

      render_hook(view, "load_more_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{loading_more?: false}, &1))

      ids = archive_ids(view, id)
      assert length(ids) == 100
      assert ids == Enum.uniq(ids)
      assert ids == Enum.map(1..100, &"agent-#{&1}")
    end

    test "an append failure keeps the loaded page and retries the same event", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "append error task"])

      entries = paged_archive(250)
      attempts = :counters.new(1, [])

      install_task_archive_runner(fn _node, _task_id, opts ->
        offset = Keyword.get(opts, :offset, 0)

        if offset > 0 do
          :counters.add(attempts, 1, 1)
          if :counters.get(attempts, 1) == 1, do: raise("append boom")
        end

        %{entries: Enum.slice(entries, offset, 100), total: length(entries)}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok, total: 250}, &1))

      render_hook(view, "load_more_task_archive", %{"task_id" => id})

      wait_for_archive(view, id, fn
        %{loading_more?: false, more_error: reason} -> reason != nil
        _ -> false
      end)

      assert Process.alive?(view.pid)
      # The already-loaded page survives; the append failure is inline.
      assert archive_ids(view, id) == Enum.map(1..100, &"agent-#{&1}")

      html = render(view)
      assert html =~ "Could not load more archive pages."
      assert html =~ "Retry"
      assert html =~ ~s(phx-click="load_more_task_archive")

      # Retry is the same event.
      render_hook(view, "load_more_task_archive", %{"task_id" => id})

      wait_for_archive(view, id, fn
        %{more_error: nil, entries: entries} -> length(entries) == 200
        _ -> false
      end)

      assert archive_ids(view, id) == Enum.map(1..200, &"agent-#{&1}")
      refute render(view) =~ "Could not load more archive pages."
    end

    test "an entry without a result asks for it instead of rendering an empty Result block", %{
      conn: conn
    } do
      id = insert_fixture!(opts: [archive: true, prompt: "show result task"])

      test_pid = self()
      install_task_archive_runner(paging_runner(paged_archive(2), test_pid))

      install_task_archive_agent_runner(fn _node, _task_id, agent_id ->
        %{"result" => agent_id}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))

      html = render(view)

      # One explicit button per paged entry — nothing is fetched on render.
      assert html =~ ~s(phx-click="load_task_archive_agent_result")
      assert html =~ ~s(phx-value-agent-id="agent-1")
      assert html =~ ~s(phx-value-agent-id="agent-2")
      assert html =~ "Show result"

      # No Result header is rendered for a paged entry (its body was never read).
      refute html =~ ~s(mb-0.5">Result</div>)
    end

    test "one agent's result is fetched once, cached, capped and refetched after invalidation", %{
      conn: conn
    } do
      id = insert_fixture!(opts: [archive: true, prompt: "lazy result task"])

      test_pid = self()
      install_task_archive_runner(paging_runner(paged_archive(2), test_pid))

      tail = "ZZ_LAZY_AGENT_RESULT_TAIL_ZZ"
      big = String.duplicate("lazy-agent-result-line ", 1_000) <> tail
      assert byte_size(big) > 8_192

      install_task_archive_agent_runner(fn node, task_id, agent_id ->
        send(test_pid, {:agent_fetch, node, task_id, agent_id})
        %{"agent_id" => agent_id, "result" => big}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))
      assert_receive {:archive_page, _node, ^id, _opts}, 2000
      # No agent result is fetched until its own control is used (drained above).
      refute_receive {:agent_fetch, _, _, _}, 0

      render_hook(view, "load_task_archive_agent_result", %{
        "task_id" => id,
        "agent_id" => "agent-1"
      })

      wait_until(fn -> agent_result_state(view, id, "agent-1") == :ok end)
      drain_async_loads(view, 5000)

      assert_receive {:agent_fetch, node, ^id, "agent-1"}, 2000
      assert node == node()
      # Fetched exactly once.
      refute_receive {:agent_fetch, _, _, "agent-1"}, 0

      html = render(view)
      assert html =~ "lazy-agent-result-line"
      refute html =~ tail
      assert html =~ "Showing 8,192 of"

      # Cached: a second click is a guarded no-op.
      render_hook(view, "load_task_archive_agent_result", %{
        "task_id" => id,
        "agent_id" => "agent-1"
      })

      drain_async_loads(view, 5000)
      refute_receive {:agent_fetch, _, _, "agent-1"}, 0

      # A task broadcast invalidates the WHOLE entry — the archive and its
      # cached agent results go with it.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_updated, id, :running, node()})
      wait_until(fn -> archive_entry(view, id) == nil end)
      drain_async_loads(view, 5000)

      refute render(view) =~ "lazy-agent-result-line"

      # Re-opening the disclosure re-reads page 1; the result is fetched again.
      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))
      assert_receive {:archive_page, _node, ^id, _opts}, 2000

      render_hook(view, "load_task_archive_agent_result", %{
        "task_id" => id,
        "agent_id" => "agent-1"
      })

      wait_until(fn -> agent_result_state(view, id, "agent-1") == :ok end)
      drain_async_loads(view, 5000)

      assert_receive {:agent_fetch, _node, ^id, "agent-1"}, 2000
      assert render(view) =~ "lazy-agent-result-line"
    end

    test "propagates the viewed node atom to both archive runners", %{conn: conn} do
      id = insert_fixture!(opts: [archive: true, prompt: "remote node task"])

      test_pid = self()

      install_task_archive_runner(fn node, task_id, _opts ->
        send(test_pid, {:archive_page_node, node, task_id})
        %{entries: paged_archive(1), total: 1}
      end)

      install_task_archive_agent_runner(fn node, task_id, agent_id ->
        send(test_pid, {:agent_fetch_node, node, task_id, agent_id})
        %{"agent_id" => agent_id, "result" => "remote node result"}
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      flush_tasks_load(view)
      _html = expand_card(view, id)

      remote = :"genesis_remote_test@127.0.0.1"
      set_current_node(view, remote)

      render_hook(view, "load_task_archive", %{"task_id" => id})
      assert_receive {:archive_page_node, ^remote, ^id}, 2000
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))

      render_hook(view, "load_task_archive_agent_result", %{
        "task_id" => id,
        "agent_id" => "agent-1"
      })

      assert_receive {:agent_fetch_node, ^remote, ^id, "agent-1"}, 2000
      wait_until(fn -> agent_result_state(view, id, "agent-1") == :ok end)
      drain_async_loads(view, 5000)

      assert render(view) =~ "remote node result"
    end

    test "the Export JSON link carries ?node= on a remote node", %{conn: conn} do
      target_id = register_remote_target!("tasks-export")

      id = insert_fixture!(opts: [archive: true, prompt: "export link task"])

      # Every node-aware read is served from the LOCAL store: the fake remote
      # node is unreachable, so the seams keep the page renderable while the
      # node CONTEXT stays remote.
      install_tasks_page_load_runner(fn _node, page, page_size, filters ->
        EvoDashWeb.TasksLive.PageLoad.load(node(), page, page_size, filters)
      end)

      install_task_detail_runner(fn _node, task_id ->
        EvoDash.NodeContext.get_task_lite(node(), task_id)
      end)

      install_task_archive_runner(fn _node, _task_id, _opts ->
        %{entries: paged_archive(1), total: 1}
      end)

      {:ok, view, _html} = live(conn, "/tasks?node=" <> target_id)
      flush_tasks_load(view)

      assert :sys.get_state(view.pid).socket.assigns.current_node_id == target_id

      _html = expand_card(view, id)
      render_hook(view, "load_task_archive", %{"task_id" => id})
      wait_for_archive(view, id, &match?(%{state: :ok}, &1))

      # Without the node target id the export controller resolves the task on
      # the LOCAL node and 404s.
      assert export_hrefs(render(view)) == ["/tasks/#{id}/export?node=#{target_id}"]
    end
  end

  # --- task detail view helpers ---

  # Extracts the first matching element's attribute (Floki), mirroring the
  # helper in project_components_test.exs.
  defp attribute(html, selector, attr) do
    [el] = Floki.find(Floki.parse_document!(html), selector)
    el |> Floki.attribute(attr) |> Enum.map(&to_string/1)
  end

  # Returns the data-content attribute of the first matching element.
  defp data_content(html, selector) do
    [value] = attribute(html, selector, "data-content")
    value
  end

  # The trimmed text of every <h4> on the page — used to pin the flattened
  # card headers ("Objective"/"Agent Message") and refute the old nested
  # "Options"/"Result" card headers.
  defp h4_header_texts(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("h4")
    |> Enum.map(fn el -> Floki.text(el) |> String.trim() end)
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# `EvoDashWeb.ReviewLiveTest.ConnectionManager`). The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.TasksLiveTest.ConnectionManager do
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
