# ProcessesLive (managed OS processes) test suite.
#
# async: false — this module writes PROCESS-GLOBAL app-env seams
# (`:processes_page_load_runner`, `:processes_control_runner` and the
# `:processes_entering_ttl_ms` animation TTL) that every concurrently mounted
# ProcessesLive would observe, and it BROADCASTS on the shared global
# `EvoGit.PubSub` topic `"processes"`, which any other module's
# mounted view (or the app-global `EvoGit.ProcessManager`) subscribes to. Both
# are BEAM-wide state, so the module stays in ExUnit's serial phase. Every seam
# is restored in `on_exit` from the value captured before the write.
#
# The page is exercised exactly the way a browser would: the load seam answers
# an injected execution list and liveness arrives ONLY as `EvoGit.PubSub`
# broadcasts. There is no polling in the page, so every wait below is a bounded
# `:sys.get_state` / render round-trip — never a fixed sleep.
defmodule EvoDashWeb.ProcessesLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.ProcessManager.Execution

  @processes_topic "processes"

  # Poll cadence for wait_until/3: each poll is a cheap synchronous round-trip
  # (:sys.get_state or a render), so 2ms observes any transition within a
  # couple of scheduling quanta without ever becoming a hot spin.
  @wait_poll_ms 2
  # The shared host swings 10-30x under load (see test/CONTEXT.md); the 5s
  # `:sys.get_state` default and 1-2s poll budgets exit on a loaded machine.
  @assigns_timeout_ms 30_000
  @async_wait_budget_ms 30_000
  # A "did this action spawn a refetch?" window. The loader is spawned inside
  # the event handler that precedes this assertion, so a refetch's runner call
  # would already be in flight — this is a bounded mailbox wait, not a sleep.
  @no_refetch_window_ms 150

  # A command comfortably longer than the row's 90-char truncation, so the
  # collapsed cell and the expanded "Full Command" block are distinguishable.
  @long_command "mix test --trace test/evo_dash_web/live/processes_live_test.exs " <>
                  "--max-failures 1 --seed 0 --formatter ExUnit.CLIFormatter"

  # ---------------------------------------------------------------------------
  # Seams (captured + restored, so one test's runner never leaks into the next)
  # ---------------------------------------------------------------------------

  defp put_seam(key, value) do
    original = Application.fetch_env(:evo_dash, key)
    Application.put_env(:evo_dash, key, value)

    on_exit(fn ->
      # Teardown must never mask the test's own failure.
      try do
        case original do
          {:ok, previous} -> Application.put_env(:evo_dash, key, previous)
          :error -> Application.delete_env(:evo_dash, key)
        end
      rescue
        _error -> :ok
      end
    end)
  end

  # The page-load seam is resolved AT SPAWN TIME inside
  # `EvoDashWeb.ProcessesLive.Load.run/4`; it answers the documented
  # `{:ok, list}` / `{:error, reason}` envelope.
  defp install_load_runner(fun) do
    test_pid = self()

    put_seam(:processes_page_load_runner, fn node, opts ->
      send(test_pid, {:load_called, node, opts})
      fun.(node, opts)
    end)
  end

  # The control seam is resolved AT CALL TIME inside
  # `EvoDashWeb.ProcessesLive.Actions.control/4`.
  defp install_control_runner(fun) do
    test_pid = self()

    put_seam(:processes_control_runner, fn node, id, action, reason ->
      send(test_pid, {:control_called, node, id, action, reason})
      fun.(node, id, action, reason)
    end)
  end

  # The enter-animation TTL is read AT CALL TIME by the page, so a test can
  # shrink it (observe the clear without a 1.5s wait) or lengthen it (assert the
  # class is present without racing the timer on a loaded host).
  defp install_entering_ttl(ms), do: put_seam(:processes_entering_ttl_ms, ms)

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp execution(overrides) do
    Map.merge(
      %{
        id: "proc-1",
        kind: :tool_call,
        tool: "bash",
        command: "mix test",
        label: nil,
        agent_id: 101,
        task_id: "task-1",
        owner_pid: nil,
        cwd: "/tmp/repo",
        repo_root: "/tmp/repo",
        backend: :systemd,
        runtime: :foreground,
        status: :running,
        os_pid: nil,
        unit: nil,
        job_id: nil,
        exit_code: nil,
        reason: nil,
        inserted_at: ~U[2026-11-09 10:00:00Z],
        started_at: DateTime.add(DateTime.utc_now(), -125, :second),
        ended_at: nil,
        stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800},
        control_log: []
      },
      Map.new(overrides)
    )
  end

  defp initial_control_log do
    [
      %{
        action: :pause,
        signal: "STOP",
        reason: "initial pause by operator",
        actor: :remote,
        at: ~U[2026-11-10 04:02:03Z]
      }
    ]
  end

  # Live (:running), live (:paused, background job), finished (:completed) and
  # finished (:failed, background job) — every branch the page renders.
  defp executions do
    [
      execution(%{
        id: "proc-1",
        command: @long_command,
        unit: "genesis-tool-1.service",
        control_log: initial_control_log()
      }),
      execution(%{
        id: "proc-2",
        kind: :background_job,
        command: "npm run dev",
        agent_id: 202,
        task_id: "task-2",
        runtime: :background,
        backend: :bwrap,
        status: :paused,
        os_pid: 4242,
        started_at: DateTime.add(DateTime.utc_now(), -2_400, :second),
        stats: %{cpu_percent: 1.5, rss_bytes: 10_485_760}
      }),
      execution(%{
        id: "proc-3",
        command: "cargo build --release",
        agent_id: 303,
        task_id: "task-3",
        unit: "genesis-tool-3.service",
        status: :completed,
        exit_code: 0,
        started_at: ~U[2026-11-09 10:00:00Z],
        ended_at: ~U[2026-11-09 10:02:05Z],
        stats: %{cpu_percent: 0.0, rss_bytes: 0}
      }),
      execution(%{
        id: "proc-4",
        kind: :background_job,
        command: "sleeper --queue",
        agent_id: 404,
        task_id: "task-4",
        runtime: :background,
        backend: :none,
        unit: nil,
        job_id: "job_abc",
        status: :failed,
        exit_code: 1,
        ended_at: ~U[2026-11-09 11:00:00Z],
        stats: %{cpu_percent: 0.0}
      })
    ]
  end

  # ---------------------------------------------------------------------------
  # Waits (bounded, event-driven)
  # ---------------------------------------------------------------------------

  defp wait_until(fun, timeout \\ @async_wait_budget_ms, poll_ms \\ @wait_poll_ms) do
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

  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  # The page starts every load from handle_params/3 (connected only), never
  # from mount/3, so the row assertions always follow this drain.
  defp wait_for_load(view) do
    wait_until(fn ->
      assigns = assigns(view)
      assigns.executions_loading == false and assigns.executions_loaded == true
    end)

    render(view)
  end

  defp row(view, id), do: view |> element("#process-row-#{id}") |> render()

  # Renders the WHOLE page until `needle` shows up (a render is a synchronous
  # round-trip, so it also drains every already-delivered broadcast).
  defp wait_for_html(view, needle) do
    wait_until(fn -> render(view) =~ needle end)
    render(view)
  end

  defp wait_for_row(view, id, needle) do
    wait_until(fn -> row(view, id) =~ needle end)
    row(view, id)
  end

  defp broadcast(event), do: Phoenix.PubSub.broadcast(EvoGit.PubSub, @processes_topic, event)

  defp count_occurrences(text, needle), do: length(String.split(text, needle)) - 1

  # Byte offset of `needle` in `text` (used for render-order assertions).
  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {pos, _len} -> pos
      :nomatch -> flunk("expected the rendered page to contain #{inspect(needle)}")
    end
  end

  defp cell_texts(row_html) do
    row_html
    |> Floki.parse_fragment!()
    |> Floki.find("td")
    |> Enum.map(fn cell -> cell |> Floki.text() |> String.trim() end)
  end

  defp mount_page(conn, path \\ ~p"/processes") do
    {:ok, view, _html} = live(conn, path)
    assert_receive {:load_called, _node, _opts}, @async_wait_budget_ms
    wait_for_load(view)
    view
  end

  # ---------------------------------------------------------------------------
  # 1. Rendering
  # ---------------------------------------------------------------------------

  test "renders status, links, command, runtime, backend, target and usage", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)

    view = mount_page(conn)

    # The default tab is LIVE: finished rows are not rendered at all.
    refute render(view) =~ "process-row-proc-3"
    refute render(view) =~ "process-row-proc-4"

    running = row(view, "proc-1")
    assert running =~ "Running"
    # Agent / task cells are node-aware links.
    assert running =~ "#101"
    assert running =~ "#task-1"
    assert running =~ ~s(href="/agents")
    assert running =~ ~s(href="/tasks")
    assert running =~ "bash"
    assert running =~ "Foreground"
    assert running =~ "systemd"
    assert running =~ "unit genesis-tool-1.service"
    assert running =~ "12.3%"
    assert running =~ "50.0 MB"
    # started_at is 125s in the past — the live row's uptime is "2m <ss>s".
    assert running =~ ~r/2m [0-5]\ds/

    paused = row(view, "proc-2")
    assert paused =~ "Paused"
    assert paused =~ "Background"
    assert paused =~ "bwrap"
    assert paused =~ "pid 4242"
    assert paused =~ "1.5%"
    assert paused =~ "10.0 MB"
    # A paused (still live) process keeps its operator controls.
    assert paused =~ ~s(aria-label="Resume")
    assert paused =~ ~s(aria-label="Kill")
  end

  # ---------------------------------------------------------------------------
  # 2. Status tabs are render-time state
  # ---------------------------------------------------------------------------

  test "the status tab switches at render time without refetching", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)

    view = mount_page(conn)
    refute render(view) =~ "process-row-proc-3"

    html = view |> element(~s(button[phx-value-status="all"])) |> render_click()

    assert html =~ "process-row-proc-1"
    assert html =~ "process-row-proc-2"
    assert html =~ "process-row-proc-3"
    assert html =~ "process-row-proc-4"

    completed = row(view, "proc-3")
    assert completed =~ "Completed"
    # Fixed started_at/ended_at: exactly 2m 05s, deterministic.
    assert completed =~ "2m 05s"
    assert completed =~ "cargo build --release"
    assert completed =~ "0"

    # The exit column is index 10 (Status, Agent, Task, Command, Runtime,
    # Backend, Target, Uptime, CPU, Memory, Exit, Actions).
    assert Enum.at(cell_texts(completed), 10) == "0"

    failed = row(view, "proc-4")
    assert failed =~ "Failed"
    assert failed =~ "job job_abc"

    # A tab switch is a push_patch over already-loaded rows: no RPC.
    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  # ---------------------------------------------------------------------------
  # 3. Kind / search filters
  # ---------------------------------------------------------------------------

  test "the kind and free-text filters narrow the rows", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)

    view = mount_page(conn, ~p"/processes?kind=background_job&status=all")
    html = render(view)
    assert html =~ "process-row-proc-2"
    assert html =~ "process-row-proc-4"
    refute html =~ "process-row-proc-1"
    refute html =~ "process-row-proc-3"

    # Free text matches the command...
    by_command = mount_page(conn, ~p"/processes?q=npm")
    html = render(by_command)
    assert html =~ "process-row-proc-2"
    refute html =~ "process-row-proc-1"

    # ...and the agent/task id (proc-4's agent is 404).
    by_id = mount_page(conn, ~p"/processes?q=404&status=all")
    html = render(by_id)
    assert html =~ "process-row-proc-4"
    refute html =~ "process-row-proc-2"
  end

  # ---------------------------------------------------------------------------
  # 4. Core-side filters refetch
  # ---------------------------------------------------------------------------

  test "an agent id filter refetches with a native integer id", %{conn: conn} do
    install_load_runner(fn _node, opts ->
      case Keyword.get(opts, :agent_id) do
        101 ->
          {:ok,
           [
             execution(%{
               id: "proc-101",
               agent_id: 101,
               command: "agent scoped command"
             })
           ]}

        _other ->
          {:ok, executions()}
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/processes?agent_id=101")

    # `Load.typed_id/1` turns the numeric URL value into an integer, which is
    # the shape the core's executions carry.
    assert_receive {:load_called, _node, [agent_id: 101]}, @async_wait_budget_ms

    html = wait_for_load(view)
    assert html =~ ~s(id="process-row-proc-101")
    assert html =~ "agent scoped command"
    # The unfiltered roster is NOT rendered: match the full id attribute,
    # because "process-row-proc-1" is a prefix of "process-row-proc-101".
    refute html =~ ~s(id="process-row-proc-1")
  end

  test "a task id filter refetches with a raw string id", %{conn: conn} do
    install_load_runner(fn _node, opts ->
      {:ok,
       [
         execution(%{
           id: "proc-task",
           task_id: Keyword.get(opts, :task_id),
           command: "task scoped command"
         })
       ]}
    end)

    {:ok, view, _html} = live(conn, ~p"/processes?task_id=task-9")

    # Non-numeric ids stay strings (never an atom conversion).
    assert_receive {:load_called, _node, [task_id: "task-9"]}, @async_wait_budget_ms

    html = wait_for_load(view)
    assert html =~ "process-row-proc-task"
    assert html =~ "task scoped command"
  end

  # ---------------------------------------------------------------------------
  # 5. Push events (no refetch)
  # ---------------------------------------------------------------------------

  test "a resource sample updates the row in place", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    view = mount_page(conn)

    broadcast(
      {:process_sample, node(), 1,
       [%{id: "proc-1", status: :running, stats: %{cpu_percent: 42.0, rss_bytes: 104_857_600}}]}
    )

    sampled = wait_for_row(view, "proc-1", "42.0%")
    assert sampled =~ "100.0 MB"
    refute sampled =~ "12.3%"
    refute sampled =~ "50.0 MB"

    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  test "a started process is prepended", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    view = mount_page(conn)

    broadcast(
      {:process_started,
       execution(%{id: "proc-new", command: "freshly started command", agent_id: 909}), node()}
    )

    html = wait_for_html(view, "process-row-proc-new")
    assert html =~ "freshly started command"

    # Newest first: the new row renders ABOVE the previously first row.
    assert index_of(html, "process-row-proc-new") < index_of(html, "process-row-proc-1")

    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  test "a status update merges into the row", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    view = mount_page(conn)

    broadcast({:process_updated, "proc-1", %{status: :paused}, node()})

    updated = wait_for_row(view, "proc-1", "Paused")
    assert updated =~ ~s(aria-label="Resume")
    refute updated =~ ~s(aria-label="Pause")
    # The merge kept the untouched fields.
    assert updated =~ "unit genesis-tool-1.service"

    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  test "an exit replaces the row and drops its controls", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    # An exited process is FINISHED, so the default live tab would hide it.
    view = mount_page(conn, ~p"/processes?status=all")

    broadcast(
      {:process_exited,
       execution(%{
         id: "proc-1",
         command: @long_command,
         unit: "genesis-tool-1.service",
         status: :completed,
         exit_code: 0,
         ended_at: DateTime.utc_now(),
         control_log: initial_control_log()
       }), node()}
    )

    exited = wait_for_row(view, "proc-1", "Completed")

    # Replace, not append: exactly one row carries the id.
    assert count_occurrences(render(view), ~s(id="process-row-proc-1")) == 1

    # Terminal statuses render no operator controls.
    refute exited =~ ~s(aria-label="Pause")
    refute exited =~ ~s(aria-label="Resume")
    refute exited =~ ~s(aria-label="Terminate")
    refute exited =~ ~s(aria-label="Kill")

    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  test "a control log entry is appended exactly once", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    view = mount_page(conn)

    # Expand the row so the detail log renders.
    html = view |> element("#process-row-proc-1 td:first-child") |> render_click()
    assert html =~ "Full Command"
    assert count_occurrences(html, "initial pause by operator") == 1

    entry = %{
      action: {:signal, "TERM"},
      signal: "TERM",
      reason: "operator asked to stop",
      actor: :remote,
      at: ~U[2026-11-10 04:05:06Z]
    }

    broadcast({:process_control, "proc-1", entry, node()})

    html = wait_for_html(view, "operator asked to stop")
    assert count_occurrences(html, "operator asked to stop") == 1
    assert html =~ "Signal TERM"
    assert html =~ "04:05:06"
    assert html =~ "Dashboard"

    # A redelivery of the SAME entry (same :at + :action) is deduped.
    broadcast({:process_control, "proc-1", entry, node()})
    :sys.get_state(view.pid, @assigns_timeout_ms)

    assert count_occurrences(render(view), "operator asked to stop") == 1

    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  test "an event from a foreign node is ignored", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    view = mount_page(conn)

    html_before = render(view)
    executions_before = assigns(view).executions

    broadcast(
      {:process_started, execution(%{id: "proc-foreign", command: "foreign command"}),
       :other@host}
    )

    # A synchronous round-trip proves the event has already been handled.
    :sys.get_state(view.pid, @assigns_timeout_ms)

    assert render(view) == html_before
    assert assigns(view).executions == executions_before
    refute render(view) =~ "proc-foreign"
  end

  # ---------------------------------------------------------------------------
  # 6. Reversible controls
  # ---------------------------------------------------------------------------

  test "pause and resume run one-click with a default reason", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    install_control_runner(fn _node, _id, _action, _reason -> :ok end)

    view = mount_page(conn)

    view |> element(~s(#process-row-proc-1 button[aria-label="Pause"])) |> render_click()

    assert_receive {:control_called, _node, "proc-1", :pause, reason}, @async_wait_budget_ms
    assert is_binary(reason)
    assert String.trim(reason) != ""
    assert render(view) =~ "Process paused."
    assert view |> element("#flash-info") |> render() =~ "Process paused."

    view |> element(~s(#process-row-proc-2 button[aria-label="Resume"])) |> render_click()

    assert_receive {:control_called, _node, "proc-2", :resume, resume_reason},
                   @async_wait_budget_ms

    assert is_binary(resume_reason)
    assert String.trim(resume_reason) != ""
    assert render(view) =~ "Process resumed."
  end

  # ---------------------------------------------------------------------------
  # 7. Destructive controls require a reason
  # ---------------------------------------------------------------------------

  test "kill requires a reason and sends the operator's text", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    install_control_runner(fn _node, _id, _action, _reason -> :ok end)

    view = mount_page(conn)

    html = view |> element(~s(#process-row-proc-1 button[aria-label="Kill"])) |> render_click()
    assert html =~ "process-confirm-modal"
    assert html =~ "Kill process?"

    # A blank reason performs NO control call and keeps the modal open.
    html = view |> element("#process-confirm-form") |> render_submit(%{"reason" => "   "})

    refute_received {:control_called, _node, _id, _action, _reason}
    assert html =~ "A reason is required."
    assert html =~ "process-confirm-modal"
    assert view |> element("#process-confirm-modal") |> render() =~ "A reason is required."

    # A real reason is passed through VERBATIM (trimmed).
    html = view |> element("#process-confirm-form") |> render_submit(%{"reason" => "the reason"})

    assert_receive {:control_called, _node, "proc-1", :kill, "the reason"}, @async_wait_budget_ms
    assert html =~ "Kill signal sent to the process."
    refute html =~ "process-confirm-modal"
  end

  test "terminate sends the TERM signal with the operator's reason", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    install_control_runner(fn _node, _id, _action, _reason -> :ok end)

    view = mount_page(conn)

    html =
      view |> element(~s(#process-row-proc-2 button[aria-label="Terminate"])) |> render_click()

    assert html =~ "process-confirm-modal"
    assert html =~ "Terminate process?"

    html = view |> element("#process-confirm-form") |> render_submit(%{"reason" => "the reason"})

    assert_receive {:control_called, _node, "proc-2", {:signal, "TERM"}, "the reason"},
                   @async_wait_budget_ms

    assert html =~ "Terminate signal sent to the process."
    refute html =~ "process-confirm-modal"
  end

  # ---------------------------------------------------------------------------
  # 8. Control failures
  # ---------------------------------------------------------------------------

  test "control failures are surfaced without crashing the page", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)

    install_control_runner(fn _node, id, action, _reason ->
      case {id, action} do
        {"proc-1", :pause} -> {:error, :unsupported}
        {"proc-2", :resume} -> {:error, :terminal}
        {"proc-1", :kill} -> {:error, {:boom, 1}}
        _other -> :ok
      end
    end)

    view = mount_page(conn)

    # :unsupported — the platform cannot deliver signals (e.g. Windows).
    view |> element(~s(#process-row-proc-1 button[aria-label="Pause"])) |> render_click()

    assert_receive {:control_called, _node, "proc-1", :pause, _reason}, @async_wait_budget_ms
    html = render(view)
    assert html =~ "This action is not supported on this platform."
    # The page survives and still shows its rows.
    assert html =~ "process-row-proc-1"
    assert html =~ "process-row-proc-2"

    # :terminal — the OS already ended the process.
    view |> element(~s(#process-row-proc-2 button[aria-label="Resume"])) |> render_click()

    assert_receive {:control_called, _node, "proc-2", :resume, _reason}, @async_wait_budget_ms
    assert render(view) =~ "This process has already exited."

    # A generic reason is formatted, never raised.
    view |> element(~s(#process-row-proc-1 button[aria-label="Kill"])) |> render_click()

    html = view |> element("#process-confirm-form") |> render_submit(%{"reason" => "boom reason"})

    assert_receive {:control_called, _node, "proc-1", :kill, "boom reason"}, @async_wait_budget_ms
    assert html =~ "failed"
    # A failed destructive action keeps the modal open with the exact text the
    # operator typed, so a retry needs no retyping.
    assert html =~ "process-confirm-modal"

    textarea =
      view
      |> element("#process-confirm-form")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("textarea")
      |> Floki.text()

    assert textarea == "boom reason"

    # The page is still alive and usable after every failure.
    assert render(view) =~ "process-row-proc-1"
  end

  # ---------------------------------------------------------------------------
  # 9. Load failure + retry
  # ---------------------------------------------------------------------------

  test "a failed load shows the error state and Retry recovers", %{conn: conn} do
    counter = :ets.new(:processes_load_calls, [:public])

    install_load_runner(fn _node, _opts ->
      calls = :ets.update_counter(counter, :calls, {2, 1}, {:calls, 0})

      if calls == 1, do: {:error, :bad_target}, else: {:ok, executions()}
    end)

    {:ok, view, _html} = live(conn, ~p"/processes")

    assert_receive {:load_called, _node, _opts}, @async_wait_budget_ms

    wait_until(fn ->
      assigns = assigns(view)
      assigns.executions_loading == false and assigns.executions_error != nil
    end)

    html = render(view)
    assert html =~ "processes-load-error"
    assert html =~ "Could not load processes."
    assert html =~ "bad_target"
    refute html =~ "process-row-proc-1"

    # Retry re-runs the loader; the second answer paints the rows.
    view |> element("#processes-load-error button") |> render_click()
    assert_receive {:load_called, _node, _opts}, @async_wait_budget_ms

    html = wait_for_load(view)
    assert html =~ "process-row-proc-1"
    refute html =~ "processes-load-error"
  end

  # ---------------------------------------------------------------------------
  # 10. Row expansion
  # ---------------------------------------------------------------------------

  test "a row expands to its full command, paths and control log", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    view = mount_page(conn)

    collapsed = row(view, "proc-1")
    refute collapsed =~ "Full Command"

    collapsed_code =
      collapsed
      |> Floki.parse_fragment!()
      |> Floki.find("td code")
      |> Floki.text()
      |> String.trim()

    # Collapsed cells truncate at 90 chars; the expanded block is complete.
    assert collapsed_code == String.slice(@long_command, 0, 90) <> "..."
    assert collapsed_code != @long_command

    html = view |> element("#process-row-proc-1 td:first-child") |> render_click()

    assert html =~ "Full Command"
    assert html =~ @long_command
    assert html =~ "Working Directory"
    assert html =~ "Repository Root"
    assert html =~ "/tmp/repo"

    # The existing control-log entry: reason, actor and HH:MM:SS timestamp.
    assert html =~ "Control Log"
    assert html =~ "initial pause by operator"
    assert html =~ "Dashboard"
    assert html =~ "04:02:03"
    assert html =~ "STOP"

    # Clicking again collapses it.
    html = view |> element("#process-row-proc-1 td:first-child") |> render_click()
    refute html =~ "Full Command"
  end

  # ---------------------------------------------------------------------------
  # 11. REAL struct records (the registry's own shape)
  # ---------------------------------------------------------------------------

  # The core hands the page `%EvoGit.ProcessManager.Execution{}` STRUCTS (the
  # registry's own records), which do NOT implement Access: every `record[:key]`
  # read raises `UndefinedFunctionError` at render time. This exercises the
  # whole page over real structs — collapsed rows, the expanded detail block
  # and a terminal record with a control log.
  test "renders REAL Execution structs end to end", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, struct_executions()} end)

    view = mount_page(conn, ~p"/processes?status=all")

    html = render(view)
    assert html =~ "process-row-proc-s1"
    assert html =~ "process-row-proc-s2"

    running = row(view, "proc-s1")
    assert running =~ "Running"
    assert running =~ "#101"
    assert running =~ "#task-1"
    assert running =~ "mix test --struct"
    assert running =~ "Foreground"
    assert running =~ "systemd"
    assert running =~ "unit genesis-tool-1.service"
    assert running =~ "12.3%"
    assert running =~ "50.0 MB"
    assert running =~ ~s(aria-label="Pause")

    completed = row(view, "proc-s2")
    assert completed =~ "Completed"
    assert completed =~ "cargo build --release"
    assert completed =~ "pid 4242"
    assert completed =~ "1.0 MB"
    # A terminal struct offers no operator controls.
    refute completed =~ ~s(aria-label="Kill")
    refute completed =~ ~s(aria-label="Terminate")

    # The expanded branch (`execution_details/1`) is the second latent crash.
    expanded = view |> element("#process-row-proc-s1 td:first-child") |> render_click()
    assert expanded =~ "Full Command"
    assert expanded =~ "mix test --struct"
    assert expanded =~ "Working Directory"
    assert expanded =~ "Repository Root"
    assert expanded =~ "/tmp/repo"
    assert expanded =~ "Started"
    assert expanded =~ "No control actions recorded."

    expanded_completed =
      view |> element("#process-row-proc-s2 td:first-child") |> render_click()

    assert expanded_completed =~ "cargo build --release"
    assert expanded_completed =~ "Ended"
    assert expanded_completed =~ "2026-11-09 10:02"
    # Control log of the terminal struct: reason, signal, time and actor.
    assert expanded_completed =~ "operator killed it"
    assert expanded_completed =~ "TERM"
    assert expanded_completed =~ "10:02:04"
    assert expanded_completed =~ "Dashboard"
  end

  # ---------------------------------------------------------------------------
  # 12. New-row enter animation
  # ---------------------------------------------------------------------------

  # The class only ever marks a row that arrived AFTER the initial snapshot; a
  # load, a refetch (Retry) and a node/filter switch replace the whole table and
  # therefore animate nothing.
  test "the initial load renders no entering row", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)

    view = mount_page(conn)
    html = render(view)

    assert html =~ "process-row-proc-1"
    assert html =~ "process-row-proc-2"
    refute html =~ "process-row-enter"
  end

  test "a started process is prepended with the enter class", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    # A long TTL so the class cannot expire before the assertion on a loaded
    # host (that it CLEARS is the next test's concern).
    install_entering_ttl(30_000)

    view = mount_page(conn)

    broadcast(
      {:process_started,
       execution(%{id: "proc-new", command: "freshly started command", agent_id: 909}), node()}
    )

    html = wait_for_html(view, "process-row-proc-new")
    assert html =~ "freshly started command"
    assert index_of(html, "process-row-proc-new") < index_of(html, "process-row-proc-1")

    # Only the newly joined row animates; the rows from the snapshot do not.
    assert row(view, "proc-new") =~ "process-row-enter"
    refute row(view, "proc-1") =~ "process-row-enter"
    refute row(view, "proc-2") =~ "process-row-enter"

    refute_receive {:load_called, _node, _opts}, @no_refetch_window_ms
  end

  test "the enter class clears after the TTL", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    install_entering_ttl(30)

    view = mount_page(conn)

    broadcast(
      {:process_started, execution(%{id: "proc-new", command: "freshly started command"}), node()}
    )

    wait_until(fn -> render(view) =~ "process-row-proc-new" end)
    # The page schedules its own `{:clear_entering, ids}` self-message, so this
    # is a bounded poll for that transition — never a fixed sleep.
    wait_until(fn -> not (render(view) =~ "process-row-enter") end)

    html = render(view)
    refute html =~ "process-row-enter"
    # The row itself survives the clear.
    assert html =~ "process-row-proc-new"
  end

  test "a later patch for a cleared row never re-runs the animation", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    install_entering_ttl(30)

    view = mount_page(conn)

    broadcast(
      {:process_started, execution(%{id: "proc-new", command: "freshly started command"}), node()}
    )

    wait_until(fn -> render(view) =~ "process-row-proc-new" end)
    wait_until(fn -> not (render(view) =~ "process-row-enter") end)

    # A resource sample patches the SAME id in place: no animation comes back.
    broadcast(
      {:process_sample, node(), 2,
       [%{id: "proc-new", status: :running, stats: %{cpu_percent: 7.5, rss_bytes: 2_097_152}}]}
    )

    sampled = wait_for_row(view, "proc-new", "7.5%")
    refute sampled =~ "process-row-enter"

    # Neither does a field update.
    broadcast({:process_updated, "proc-new", %{status: :paused}, node()})

    paused = wait_for_row(view, "proc-new", "Paused")
    refute paused =~ "process-row-enter"

    # A repeat `started` broadcast for a now-known id is dropped entirely: no
    # duplicate row and no re-animation.
    broadcast(
      {:process_started, execution(%{id: "proc-new", command: "freshly started command"}), node()}
    )

    :sys.get_state(view.pid, @assigns_timeout_ms)
    html = render(view)

    assert count_occurrences(html, ~s(id="process-row-proc-new")) == 1
    assert row(view, "proc-new") =~ "Paused"
    refute html =~ "process-row-enter"
  end

  test "an exit for a process the page never saw start also animates", %{conn: conn} do
    install_load_runner(fn _node, _opts -> {:ok, executions()} end)
    install_entering_ttl(30_000)

    # An exited process is FINISHED, so the live tab would hide it.
    view = mount_page(conn, ~p"/processes?status=all")

    broadcast(
      {:process_exited,
       execution(%{
         id: "proc-late",
         command: "exited before this page opened",
         status: :completed,
         exit_code: 0,
         ended_at: DateTime.utc_now()
       }), node()}
    )

    html = wait_for_html(view, "process-row-proc-late")
    assert html =~ "exited before this page opened"
    # The unknown id is PREPENDED (newest first) and animated.
    assert index_of(html, "process-row-proc-late") < index_of(html, "process-row-proc-1")

    assert row(view, "proc-late") =~ "process-row-enter"
    refute row(view, "proc-1") =~ "process-row-enter"
  end

  # ---------------------------------------------------------------------------
  # Struct fixture helpers
  # ---------------------------------------------------------------------------

  # A live foreground tool call, built as the REAL struct.
  defp struct_execution(overrides \\ []) do
    struct!(
      %Execution{
        id: "proc-s1",
        kind: :tool_call,
        tool: "bash",
        command: "mix test --struct",
        label: nil,
        agent_id: 101,
        task_id: "task-1",
        owner_pid: nil,
        cwd: "/tmp/repo",
        repo_root: "/tmp/repo",
        backend: :systemd,
        runtime: :foreground,
        status: :running,
        os_pid: nil,
        unit: "genesis-tool-1.service",
        job_id: nil,
        exit_code: nil,
        reason: nil,
        inserted_at: ~U[2026-11-09 10:00:00Z],
        started_at: DateTime.add(DateTime.utc_now(), -125, :second),
        ended_at: nil,
        stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800},
        control_log: []
      },
      overrides
    )
  end

  # A terminal foreground tool call addressed by OS pid, with one control-log
  # entry (the operator killed it).
  defp struct_executions do
    [
      struct_execution(),
      struct_execution(
        id: "proc-s2",
        command: "cargo build --release",
        status: :completed,
        exit_code: 0,
        unit: nil,
        os_pid: 4242,
        started_at: ~U[2026-11-09 10:00:00Z],
        ended_at: ~U[2026-11-09 10:02:05Z],
        stats: %{cpu_percent: 0.0, rss_bytes: 1_048_576},
        control_log: [
          %{
            action: :kill,
            signal: "TERM",
            reason: "operator killed it",
            actor: :remote,
            at: ~U[2026-11-09 10:02:04Z]
          }
        ]
      )
    ]
  end
end
