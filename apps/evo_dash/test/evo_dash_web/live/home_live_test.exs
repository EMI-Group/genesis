# HomeLive (chat page) test suite.
#
# Covers the idle render, the send-message flow (deterministic fail-fast
# reflect tasks against the isolated Store+TaskRegistry — see the setup's
# "fail-fast" block: every real spawn is rejected at the AgentScheduler, so
# no LLM endpoint is ever contacted), new-chat + ChatHistory store semantics,
# the onboarding dead-render redirect, streaming display (REAL-shaped core
# payloads: integer agent ids, KEYWORD-LIST changed_fields, real
# %ReqLLM.Message{} structs), completion/error rendering, the assistant
# task-card (status badge + thought process), chat persistence/restore across
# remounts, the production-mimicking crash-reproduction flow, sidebar
# robustness, stop/cancel, and node-awareness.
#
# The config directory is isolated PER PROCESS through the test-only
# `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`, installed by
# test/test_helper.exs), never through a BEAM-global `XDG_CONFIG_HOME` write.
# The override lives in the TEST process' dictionary and reaches the mounted
# LiveView plus its supervised load tasks through the OTP `:"$callers"` chain
# (`support/config_dir_test.exs` proves all three levels), so every test gets its
# OWN empty `<temp dir>/genesis` config dir — the exact layout the old env-var
# redirect produced, with zero assertion changes.
#
# async: false — FOUR process-global dependencies, and every test in this file
# mounts `/help`, so no contained subset can escape them:
#
#   1. `EvoDash.Test.IsolatedTaskStore.isolate!/1` (module-wide setup) terminates
#      and re-registers the process-global `EvoGit.Store` / `EvoGit.TaskRegistry`
#      SINGLETON NAMES. A (re)start cannot overlap another module's use of those
#      names, so this alone forces the sync phase.
#   2. `EvoDash.ChatHistory` — a boot-created global GenServer + named ETS table
#      (`EvoDash.Application`) with NO per-process seam. This suite resets it,
#      and the HomeLive mount itself calls `ChatHistory.new_chat/1` +
#      `put_state/2`, while the ASYNC `EvoDash.ChatHistoryTest` asserts ABSOLUTE
#      contents (`list_chats() == [id]`); running concurrently would make both
#      flaky (that suite's own module comment states the same invariant).
#   3. The boot-global `EvoGit.AgentScheduler` config is forced to the fail-fast
#      `model_profiles: []` for every test (the documented seam that keeps a
#      real send from reaching an LLM endpoint), then restored in `on_exit`.
#   4. Per-test app-env seams (`:approval_responder`, `:approval_pending_runner`,
#      `:source_availability_runner`, `:source_clone_runner`, `:config_dir_fun`)
#      are written and restored by the tests that use them; canonical launch
#      fixtures must also reach TaskRegistry outside the test's caller chain.
defmodule EvoDashWeb.HomeLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo

  # Poll interval for the file's wait_until/2 helper. Tightened from 10ms to
  # 2ms: the pollers observe async work that typically settles within a few
  # ms, so the old interval was pure overshoot latency (the residual wait of a
  # fixed-interval poll averages interval/2). Still non-zero so the loop never
  # spins hot.
  @poll_interval_ms 2

  setup do
    # Isolated Store + TaskRegistry (pattern from tasks_live_test). The helper
    # owns teardown: it stops the isolated pair FIRST, then restores and
    # VERIFIES the production children, so the reflect tasks started by
    # send_message never leak into other suites and the globals are always
    # deterministically restored afterwards.
    :ok = EvoDash.Test.IsolatedTaskStore.isolate!("home_live")

    # Fail-fast scheduler config: run_agent clause (a) (agent_scheduler.ex)
    # rejects every spawn synchronously with {:error, :llm_not_configured} when
    # model_profiles is [] — BEFORE any agent registration, ETS row, or LLM
    # HTTP call. This suite is a dashboard-layer suite: the real reflect
    # runtime (core suites cover it) must never run here. On this machine the
    # ambient config carries a REAL (expired) API key — a live send would spam
    # 403 network errors; on a machine with no key at all the agent crashes
    # with a MatchError instead. The empty-profiles rejection makes every
    # send deterministic-and-quiet in both worlds (the executor maps the
    # {:error, _} to a persisted :failed row, with no network I/O). The same
    # seam is the documented idiom in evo_git's own suites
    # (evolution_test.exs without_model_profiles/1, agent_scheduler_test.exs).
    # Per-send cleanup below still runs (the row + wrapper must be reaped);
    # with the fail-fast in place no agent ETS rows can exist, so the
    # cleanup's ETS sweep is a cheap no-op.
    original_model_profiles =
      GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})

    GenServer.call(EvoGit.AgentScheduler, {:update_config, model_profiles: []})

    # ChatHistory is a global GenServer under EvoDash.Application that is NOT
    # terminated by the Store/TaskRegistry isolation above — reset it so the
    # chats persisted by one test never leak into the next (the
    # node_aware_test.exs / chat_history_test.exs convention).
    EvoDash.ChatHistory.reset()

    # `EvoDash.ActiveTasks` is a process-less public-ETS module (NOT a GenServer) over
    # the boot-created, process-wide `:evo_dash_active_tasks` table, so it is shared by
    # the whole run and untouched by the `EvoDash.Test.IsolatedTaskStore.isolate!/1` above.
    # This module is `async: false`, so its whole-table `EvoDash.ActiveTasks.reset()`
    # cannot race another module: it clears the previous test's sidebar snapshot so it
    # cannot seed the next whole-page mount or dead render.
    EvoDash.ActiveTasks.reset()

    # Onboarding (pattern from projects_live_test.set_onboarding_completed):
    # isolate the config dir to a per-test temp dir and mark onboarding complete
    # so the HomeLive dead render does NOT redirect first-time users to
    # /welcome. The "onboarding redirect" describe re-isolates to a fresh empty
    # dir in its own test body.
    #
    # `isolate!/1` creates the temp dir, activates it in THIS process and
    # registers the `File.rm_rf!` cleanup itself; the explicit `on_exit` below
    # keeps the dir lifetime visible at the call site (both removals are
    # idempotent).
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_home_live_test_config")
    on_exit(fn -> File.rm_rf!(dir) end)

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      # Restore the ambient scheduler config FIRST (before the per-test Store
      # child dies — update_config only touches the global scheduler, and the
      # eviction sweep in State.do_update_config reads :evogit_sched_meta via
      # :ets.whereis, so a missing table is a safe no-op).
      restore_model_profiles(original_model_profiles)
    end)

    :ok
  end

  # --- helpers ---

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as welcome_live_test.exs / settings_live_test.exs).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Decoded task opts are a list of mixed atom/string-key tuples (the Store
  # codec atomizes only its whitelist), so string keys must be looked up via
  # Map.new — Access.get/3 and Keyword.has_key?/2 reject non-atom keys on
  # keyword lists.
  defp opt(task, key), do: Map.get(Map.new(task.opts || []), key)
  defp has_opt?(task, key), do: Map.has_key?(Map.new(task.opts || []), key)

  # Inserts a task directly into the SQLite store (bypasses the async task
  # spawn that `start_task/2` triggers). Lets a test prove that an unrelated
  # pre-existing row is untouched by an event.
  #
  # No on_exit delete is needed: the Store is per-test (setup terminates the
  # production children and starts a fresh temp sqlite that is rm_rf'd in
  # setup's on_exit), so rows cannot leak into other tests — and by the time
  # an on_exit would run, the isolated Store process is already dead, so a
  # delete would raise `(exit) no process`.
  defp insert_task_fixture!(overrides) do
    id = Keyword.get(overrides, :id) || "fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: Keyword.get(overrides, :type, :genesis),
        status: :completed,
        opts: Keyword.get(overrides, :opts, path: "/tmp/test"),
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

  # Restores the scheduler's model_profiles captured by setup. update_config
  # rejects a nil llm_model but accepts model_profiles lists unconditionally;
  # the original value is whatever the ambient config resolved at boot.
  defp restore_model_profiles(original) do
    GenServer.call(EvoGit.AgentScheduler, {:update_config, model_profiles: original})
  end

  # Cancels + deletes a launched reflect task in on_exit so its persisted row
  # never leaks into other tests. Under the setup's fail-fast scheduler config
  # the wrapper already returned {:error, :llm_not_configured} → the row is
  # terminal :failed, so the cancel call is a defensive no-op; delete is what
  # reaps the row (only relevant for suites reading this file's leftovers,
  # since each test's Store is rm_rf'd anyway). Additionally sweeps the
  # scheduler ETS rows (cancel/delete do not remove them) — with the fail-fast
  # in place no agent is ever registered, so this sweep is a cheap no-op kept
  # for safety if the config seam is ever relaxed.
  #
  # Cleanup in on_exit: ExUnit terminates the test supervisor (stopping the
  # isolated Store + TaskRegistry) BEFORE running on_exit callbacks, so the
  # GenServer.call in cancel_task/1 exits with :noproc — catch exits so a
  # teardown failure can't mask the actual test result (the row is also
  # rm_rf'd by setup's on_exit regardless).
  defp cleanup_task_on_exit(task_id) do
    on_exit(fn ->
      try do
        EvoGit.TaskRegistry.cancel_task(task_id)
      catch
        :exit, _ -> :ok
      end

      try do
        EvoGit.TaskRegistry.delete_task(task_id)
      catch
        :exit, _ -> :ok
      end

      # The reflect agent's scheduler rows (agent_id -> %{task_id: ...} in
      # :evogit_sched_meta, plus :evogit_agent_state) are NOT removed by
      # cancel/delete — the agent stays alive/blocked on an LLM slot with no
      # credentials, so without this sweep its ETS rows leak into
      # agents_live_test.exs (which expects an empty agent registry).
      try do
        if :ets.whereis(:evogit_sched_meta) != :undefined do
          for {agent_id, meta} <- :ets.tab2list(:evogit_sched_meta),
              Map.get(meta, :task_id) == task_id do
            :ets.delete(:evogit_sched_meta, agent_id)

            if :ets.whereis(:evogit_agent_state) != :undefined,
              do: :ets.delete(:evogit_agent_state, agent_id)
          end
        end

        :ok
      catch
        :exit, _ -> :ok
      end
    end)

    task_id
  end

  # Injects a terminal `:failed` task event directly into the view (the
  # documented test idiom for the push-based event contract — see
  # test/CONTEXT.md "Notes for Agents") and flushes it with render/1. This
  # deterministically drives the chat back to :idle WITHOUT asserting on the
  # real (async) task lifecycle, which is out of scope here.
  defp finalize_failed(view, task_id) do
    send(view.pid, {:task_updated, task_id, :failed, node()})
    render(view)
  end

  # Returns true when the first element matching `selector` has a `disabled`
  # attribute in the rendered HTML (Phoenix HEEx renders `disabled={true}` as a
  # bare attribute, omitted when false).
  defp disabled?(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> case do
      [{_tag, attrs, _children} | _] -> Enum.any?(attrs, fn {k, _v} -> k == "disabled" end)
      _ -> false
    end
  end

  # Returns true when at least one element matches `selector`.
  defp present?(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector) != []
  end

  # Scope the page-alive/name pin to its heading: assistant entries and the
  # composer also carry the assistant's name, but cannot replace the page title.
  defp page_heading(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("h1")
    |> Floki.text()
    |> String.trim()
  end

  # Polls `fun` until it returns truthy (or the timeout elapses) — the
  # tasks_live_test.exs pattern for observing async results (the real
  # supervised fetches, the PubSub debounce) without fixed sleeps. The poll
  # interval is @poll_interval_ms (a few ms — see the attribute).
  defp wait_until(fun, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for async condition")
        else
          Process.sleep(@poll_interval_ms)
          wait_loop.(wait_loop)
        end
      end
    end

    wait_loop.(wait_loop)
  end

  # Runs a REAL chat send (a typed `render_submit(view, "send_message", ...)`
  # or a suggestion-chip `render_click`) plus an await of the started reflect
  # task's terminal status inside ONE ExUnit.CaptureLog.with_log/2 window, and
  # returns {html, log} — the canonical-send test's shape, shared by EVERY
  # real-send test in this file.
  #
  # WHY the window: the suite-level `capture_log: true` only keeps the Logger
  # :default handler swapped out WHILE a capture is active, so a log emitted
  # after a test's capture closed prints to the console as uncaptured noise
  # (observed in the between-test gap: `[warning] TaskRegistry:
  # FAILED_TRANSITION task_id=<id> source=result_handler prev_status=:running
  # result={:error, :llm_not_configured}`). with_log/1's internal Logger.flush/0
  # drains pending entries before the window closes.
  #
  # ORDERING — awaiting the persisted terminal status is a DETERMINISTIC
  # guarantee that the FAILED_TRANSITION log is inside the window: the
  # registry's `{ref, result}` handler calls
  # `Diagnostics.log_failed_transition(task_id, :result_handler, ...)` BEFORE it
  # casts the terminal status (apps/evo_git/lib/evo_git/task_registry.ex: ~:1477
  # vs the ~:1489 `update_task_status_with_caller/4`), and that cast writes the
  # row synchronously in `handle_update_status/6` (its ~:909 log precedes the
  # ~:956 `EvoGit.Store.update_task_columns/3`). The await therefore returns
  # only after the log was emitted.
  #
  # TOTAL await: `TaskRegistry.start_task/2` is a GenServer.call, so a real
  # LOCAL send has already persisted its row (non-terminal) by the time
  # `send_fun` returns — the poll then waits it to terminal. A send that starts
  # NO task at all (a gate-blocked composer, or a remote fail-fast send that
  # persists no local row) leaves no non-terminal :reflect row, so the poll is
  # immediately satisfied.
  defp send_and_await_terminal(send_fun) when is_function(send_fun, 0) do
    ExUnit.CaptureLog.with_log(fn ->
      html = send_fun.()
      await_reflect_terminal()
      html
    end)
  end

  # Polls until every :reflect row in the store is terminal (an empty set counts
  # as settled). The file's own wait_until/2 poll idiom — no fixed sleep.
  defp await_reflect_terminal do
    wait_until(fn ->
      EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      |> Enum.filter(&(&1.type == :reflect))
      |> Enum.all?(&(&1.status in [:failed, :completed, :cancelled]))
    end)
  end

  # Polls until the async Genesis-source availability check has landed on the
  # socket (its runner resolves at spawn time inside a TaskSupervisor child, so
  # render_async/2 cannot await it — same reason the file polls other async
  # assigns) and then syncs the test proxy via render/1.
  defp await_source_available(view, expected, timeout \\ 2000) do
    wait_until(fn -> assigns(view)[:source_available] == expected end, timeout)
    render(view)
  end

  # Restores an Application env key captured before a test mutated it (a stored
  # `false`/`nil` is handled correctly). Mirrors system_live_test.exs'
  # restore_env_value/2.
  defp restore_env_value(key, original) do
    if original != nil do
      Application.put_env(:evo_dash, key, original)
    else
      Application.delete_env(:evo_dash, key)
    end
  end

  # A REAL-shaped history payload (the exact production data path): native
  # %ReqLLM.Message{} structs with a :thinking content part, tool_calls,
  # reasoning_details, a tool message, and a nil-metadata message.
  defp real_history do
    [
      %ReqLLM.Message{
        role: :system,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "you are genesis"}],
        metadata: %{turn: 0, timestamp: 1_700_000_000}
      },
      %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "New message: hi"}],
        metadata: %{turn: 1, timestamp: 1_700_000_001}
      },
      %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{type: :thinking, text: "let me inspect the source"},
          %ReqLLM.Message.ContentPart{type: :text, text: ""}
        ],
        tool_calls: [
          %ReqLLM.ToolCall{
            id: "call_1",
            type: "function",
            function: %{name: "spawn_investigator", arguments: "{}"}
          }
        ],
        reasoning_details: [%ReqLLM.Message.ReasoningDetails{text: "think", index: 0}],
        metadata: %{turn: 2, timestamp: 1_700_000_002}
      },
      %ReqLLM.Message{
        role: :tool,
        name: "spawn_investigator",
        tool_call_id: "call_1",
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "result..."}],
        metadata: %{turn: 2, timestamp: 1_700_000_003}
      },
      %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{type: :text, text: "Genesis is an Elixir framework."}
        ],
        metadata: nil
      }
    ]
  end

  # Builds a %ReqLLM.Context{} from the real history (for seeding REAL
  # :evogit_agent_state rows).
  defp real_context, do: ReqLLM.Context.new(real_history())

  describe "render" do
    test "renders the idle chat page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/help")

      assert page_heading(html) == "Genesis Assistant"
      assert html =~ "Start a conversation"

      # The message input and Send button are present and ENABLED on idle
      # (chat_status == :idle → disabled={false} → attribute omitted).
      assert present?(html, ~s(textarea[name="message"]))
      refute disabled?(html, ~s(textarea[name="message"]))
      assert present?(html, ~s(button[type="submit"]))
      refute disabled?(html, ~s(button[type="submit"]))

      # New chat is enabled on idle (it is disabled only while a chat is
      # running); Stop is disabled when nothing is running.
      assert present?(html, ~s(button[phx-click="new_chat"]))
      refute disabled?(html, ~s(button[phx-click="new_chat"]))
      assert present?(html, ~s(button[phx-click="stop"]))
      assert disabled?(html, ~s(button[phx-click="stop"]))
    end

    test "empty state renders the greeting and four operator suggestion chips", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/help")

      # ChatGPT-style empty state: greeting + 4 suggestion chips, each wired to
      # the send_message event with its message text as the phx-value (so
      # clicking a chip submits it through the existing handle_event clause).
      assert html =~ "What would you like Genesis to do?"

      chips =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s(button[phx-click="send_message"][phx-value-message]))

      assert length(chips) == 4

      assert html =~ ~s(phx-value-message="Show my running tasks")
      assert html =~ ~s(phx-value-message="Check system status and capacity")
      assert html =~ ~s(phx-value-message="Start a task for me")
      assert html =~ ~s(phx-value-message="Explain how tasks are scheduled")
    end
  end

  # Extracts the FIRST chat-entry wrapper + its bubble's class attribute from
  # rendered html. The user message is always the first transcript entry after a
  # fresh send (document order), and its wrapper is right-aligned
  # (`flex justify-end`) around a single content-fit bubble div (the assistant
  # entries follow with `flex justify-start` wrappers).
  defp first_user_bubble(html) do
    doc = Floki.parse_document!(html)

    wrapper_class =
      doc
      |> Floki.find(~s(div[id^="chat-entry-"]))
      |> hd()
      |> Floki.attribute("class")
      |> List.first()

    bubble_class =
      doc
      |> Floki.find(~s(div[id^="chat-entry-"] > div))
      |> hd()
      |> Floki.attribute("class")
      |> List.first()

    {wrapper_class, bubble_class}
  end

  describe "send message" do
    # THE canonical real-send pin (every other send in this file is deduped
    # against it or the model-selector describes). Under the setup's fail-fast
    # scheduler config the reflect wrapper returns {:error, :llm_not_configured}
    # deterministically — the row + its opts land on the persisted TaskInfo, no
    # agent is registered, and no LLM endpoint is ever contacted. The submit +
    # terminal await run inside a CaptureLog.with_log/2 window so the wrapper's
    # asynchronous error log is captured rather than printed between tests.
    test "starts a reflect task with the right opts and tracks it synchronously", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      # The wrapper's `SelfReflective failed: ...` error log is emitted
      # ASYNCHRONOUSLY at task end, so the submit + the await of the row's
      # terminal status run inside ONE ExUnit.CaptureLog.with_log/2 window (see
      # send_and_await_terminal/1, which documents the ordering guarantee and
      # why an un-windowed send prints uncaptured noise between tests).
      {html, log} =
        send_and_await_terminal(fn ->
          render_submit(view, "send_message", %{"message" => "hello genesis"})
        end)

      # Deterministic under the fail-fast pin — proof the capture window really
      # held the wrapper's error log (it is never printed to the console).
      assert log =~ "SelfReflective failed"
      # Optimistic UI: the user bubble appears immediately and the start flow
      # did not render the error bubble. (Regression: passing the bare
      # %EvoGit.TaskInfo{} struct — instead of {:ok, task} — to
      # AgentStream.task_id_from_start/1 fell through to {:error, :no_task_id},
      # leaving chat_task_id nil and rendering the error bubble even though the
      # reflect task DID start.)
      assert html =~ "hello genesis"
      refute html =~ "Failed to start the task"

      # The persisted row: repo-less reflect task with the FIRST message as the
      # bare objective, mode "reflect", and NO :path key (atom or string).
      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "hello genesis"
      assert opt(task, :path) == nil
      refute has_opt?(task, :path)
      refute has_opt?(task, "path")

      # Synchronous tracking, proved race-free: a :failed event for the ROW's
      # id only finalizes the transcript when the chat is tracking exactly
      # that id (handle_task_event drops non-matching ids). The wrapper may
      # already have broadcast the real :failed (the finalize is idempotent),
      # but a chat that failed to track its task would stay :running with a
      # still-streaming bubble.
      finalize_failed(view, task.id)

      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      assert assigns(view).transcript |> List.last() |> Map.get(:text) == "The task failed."

      cleanup_task_on_exit(task.id)
    end

    test "second message carries the transcript preamble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      # Establish the transcript deterministically via :sys.replace_state (the
      # real reflect-task lifecycle is async and out of scope — see the
      # "completion / error rendering" describes for the full recipe). The
      # socket assigns are mutated directly (same pattern as
      # agents_live_test.exs) — Phoenix.LiveView.assign/2 does not exist.
      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: %{
              state.socket
              | assigns:
                  Map.merge(state.socket.assigns, %{
                    transcript: [%{id: "1", role: :user, text: "hello", streaming: false}],
                    chat_status: :idle
                  })
            }
        }
      end)

      {_html, log} =
        send_and_await_terminal(fn ->
          render_submit(view, "send_message", %{"message" => "what is genesis?"})
        end)

      # Deterministic proof that the capture window really held the registry's
      # asynchronous FAILED_TRANSITION warning: the persisted row only reaches
      # its terminal status AFTER that log is emitted (see
      # send_and_await_terminal/1), so a log landing between tests would make
      # this assert flunk instead of leaking to the console.
      assert log =~ "FAILED_TRANSITION"

      # The persisted row's objective must carry the preamble.
      [task] =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      assert opt(task, :objective) ==
               "Previous conversation:\nUser: hello\nNew message: what is genesis?"

      cleanup_task_on_exit(task.id)
    end

    test "whitespace-only message is a no-op", %{conn: conn} do
      # Seed an unrelated task to prove the empty submit creates NO new row.
      fixture_id = insert_task_fixture!(opts: [path: "/tmp/test", objective: "fixture"])

      {:ok, view, _html} = live(conn, "/help")

      html = render_submit(view, "send_message", %{"message" => "   "})

      # No optimistic bubbles, no task, still idle.
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      assert html =~ "Start a conversation"
      assert EvoGit.TaskRegistry.get_task(fixture_id) != nil
      assert length(EvoGit.Store.safe_select_all_tasks(EvoGit.Store)) == 1
    end

    # The user-bubble markup is identical on the typed and chip send routes
    # (both share do_send_chat/2's optimistic-transcript assign), so ONE test
    # pins the classes against a SEEDED transcript materialized by a real
    # assign path (the matching {:task_updated, ...} event runs
    # handle_task_event's assign/persist path) — no task needs to start. The
    # chip ROUTE itself (send_suggestion -> do_send_chat) is covered by the
    # "model selector" chip tests below.
    test "typed send renders the right-aligned soft user bubble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      seed_chat_state(view, %{
        chat_task_id: "t1",
        chat_status: :running,
        transcript: [%{id: "1", role: :user, text: "typed hi", streaming: false}]
      })

      # Materialize the seeded transcript into the rendered html via the real
      # assign path (replace_state alone never pushes a diff — see the badge
      # tests in "assistant task-card").
      send(view.pid, {:task_updated, "t1", :running, node()})
      html = render(view)

      assert html =~ "typed hi"

      {wrapper_class, bubble_class} = first_user_bubble(html)

      # Right-aligned wrapper around a content-fit bubble.
      assert wrapper_class =~ "flex justify-end"

      # The DaisyUI theme-token bubble (bg-base-200/text-base-content read
      # correctly in both light and dark themes), text left-aligned inside.
      assert bubble_class =~ "w-fit"
      assert bubble_class =~ "bg-base-200"
      assert bubble_class =~ "text-left"
      refute bubble_class =~ "bg-primary"
    end
  end

  describe "new chat" do
    test "resets the chat to the idle empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      # Synthetic running chat (seed + terminal event) — the real reflect
      # runtime must never run in this suite (see the setup's fail-fast
      # block). The seeded "hello" user entry gives new_chat a non-empty
      # transcript to reset, exactly like a real send would.
      seed_running_chat(view)

      # Deterministically drive the chat to a terminal state via the same
      # {:task_updated, ...} event shape the core broadcasts.
      finalize_failed(view, "t1")

      assert assigns(view).chat_status == :idle

      html = render_click(view, "new_chat", %{})
      assert html =~ "Start a conversation"
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      refute disabled?(html, ~s(button[type="submit"]))
    end

    test "starts a fresh persisted chat and keeps the old one in the store", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      old_id = assigns(view).chat_id
      assert old_id != nil

      # Synthetic running chat (seed + terminal event) — same rationale as the
      # "resets the chat" test above.
      seed_running_chat(view)

      # Deterministically drive the chat to a terminal state (same event
      # shape as the reset test above).
      finalize_failed(view, "t1")

      old_state = EvoDash.ChatHistory.get_state(old_id)
      assert old_state != nil
      assert Enum.any?(old_state.transcript, &(&1.role == :user and &1.text == "hello"))

      html = render_click(view, "new_chat", %{})
      new_id = assigns(view).chat_id

      assert new_id != nil and new_id != old_id
      assert html =~ "Start a conversation"
      assert assigns(view).transcript == []
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil

      # The store keeps the old chat AND points the current pointer at the new
      # one (old chats are kept — there is no chat-switching UI yet).
      assert EvoDash.ChatHistory.current_chat_id() == new_id
      assert old_id in EvoDash.ChatHistory.list_chats()
      assert EvoDash.ChatHistory.get_state(old_id) == old_state
    end

    test "new chat prunes the store to the newest 10 chats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      first_id = assigns(view).chat_id

      # Seed 11 more chats directly (the click's prune(10) will drop the 3
      # oldest: the mount chat + the first two seeds).
      for _ <- 1..11, do: EvoDash.ChatHistory.new_chat()

      html = render_click(view, "new_chat", %{})
      new_id = assigns(view).chat_id

      assert html =~ "Start a conversation"
      assert EvoDash.ChatHistory.current_chat_id() == new_id
      assert length(EvoDash.ChatHistory.list_chats()) == 10
      refute first_id in EvoDash.ChatHistory.list_chats()
      assert new_id in EvoDash.ChatHistory.list_chats()
    end
  end

  describe "onboarding redirect" do
    test "dead render redirects first-time users to /welcome", %{conn: conn} do
      # The setup completed onboarding under ITS temp config dir. Re-isolate to
      # a brand-new empty temp dir here (a SECOND `isolate!/1` — it returns a
      # fresh directory and re-activates this process) so VersionState's
      # path-keyed :persistent_term cache re-reads from disk, finds no
      # version-state file, and reports onboarding_needed?() == true again.
      dir = EvoDash.Test.ConfigDir.isolate!("evogit_home_live_onboarding")
      on_exit(fn -> File.rm_rf!(dir) end)

      assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, "/help")
    end
  end

  # Establishes deterministic chat state by mutating the LiveView's socket
  # assigns directly (the agents_live_test.exs pattern — Phoenix.LiveView.assign
  # does not exist in this LiveView version). The keys are only marked changed
  # (and a diff pushed) when a subsequent event handler runs assign/2, so
  # rendered-html assertions are reliable only AFTER sending a message that
  # triggers an assign; assigns/1 (sys.get_state) is always accurate for state
  # assertions.
  defp seed_chat_state(view, overrides) do
    :sys.replace_state(view.pid, fn state ->
      %{state | socket: %{state.socket | assigns: Map.merge(state.socket.assigns, overrides)}}
    end)
  end

  # A running chat: a user bubble + an empty streaming assistant bubble (the
  # optimistic state right after send_message), with the task/agent refs set.
  defp seed_running_chat(view) do
    seed_chat_state(view, %{
      chat_status: :running,
      chat_task_id: "t1",
      chat_agent_id: 1001,
      transcript: [
        %{id: "1", role: :user, text: "hello", streaming: false},
        %{id: "2", role: :assistant, text: "", streaming: true}
      ]
    })
  end

  # Seeds a REAL %AgentState{} row into the scheduler ETS (the exact shape the
  # core keeps) and sweeps it in on_exit.
  defp seed_agent_state!(agent_id, context \\ real_context()) do
    state = %EvoGit.AgentScheduler.AgentState{
      context: context,
      context_node: %EvoGit.Core.ContextNode{path: "/tmp/x", repo: "/tmp/x"},
      llm_model: nil,
      max_retries: 1,
      max_depth: 1,
      turn: 4,
      task_local_id: 9
    }

    :ets.insert(:evogit_agent_state, {agent_id, state})

    on_exit(fn ->
      :ets.delete(:evogit_agent_state, agent_id)
    end)

    state
  end

  describe "streaming display" do
    test "assistant text from the history fetch appears in the bubble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001,
         [%{role: :assistant, content: [%{text: "Genesis responds"}]}]}
      )

      html = render(view)
      assert html =~ "Genesis responds"
      assert assigns(view).agent_message_count == 1
      assert assigns(view).chat_status == :running
    end

    test "agent_registered sets the chat agent and triggers the history fetch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: nil,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      send(
        view.pid,
        {:agent_registered, 1001,
         %{task_id: "t1", message_count: 1, agent_module: EvoGit.Agents.SelfReflective}, node()}
      )

      render(view)
      assert assigns(view).chat_agent_id == 1001

      # agent_registered spawned a REAL async history fetch (bumping
      # chat_fetch_seq); it returns [] for the fake agent id, which is harmless.
      # Inject the manual result with the CURRENT seq (read dynamically — never
      # hardcode).
      seq = assigns(view)[:chat_fetch_seq]

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001,
         [%{role: :assistant, content: [%{text: "Genesis responds"}]}]}
      )

      html = render(view)
      assert html =~ "Genesis responds"
    end

    test "kwlist changed_fields with :message_count triggers a history refetch (regression)", %{
      conn: conn
    } do
      # The PROD BUG this pins: the core broadcasts changed_fields as a
      # KEYWORD LIST (real shape [message_count: n]) — the old
      # tuple-membership guard was always false for it, so the streamed text
      # never updated after the first history fetch.
      agent_id = 200_000 + rem(System.unique_integer([:positive]), 50_000)

      ctx =
        ReqLLM.Context.new([
          %ReqLLM.Message{
            role: :assistant,
            content: [%ReqLLM.Message.ContentPart{type: :text, text: "kwlist response"}]
          }
        ])

      seed_agent_state!(agent_id, ctx)

      {:ok, view, _html} = live(conn, "/help")

      seq = assigns(view)[:chat_fetch_seq]

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: agent_id,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Real keyword-list changed_fields: the guard (is_list +
      # Keyword.has_key?) matches → a REAL refetch is spawned (seq bumped).
      send(view.pid, {:agent_updated, agent_id, [message_count: 2], node()})
      render(view)
      assert assigns(view)[:chat_fetch_seq] == seq + 1

      # The real refetch lands against the ETS row → the streamed text appears
      # (this is the exact production data path, no injected result).
      wait_until(fn -> assigns(view)[:agent_message_count] == 1 end)
      html = render(view)
      assert html =~ "kwlist response"
    end

    test "kwlist changed_fields WITHOUT :message_count does not refetch (HistoryGate)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      # Other field changes (status/turn/...) must NOT refetch the history.
      send(view.pid, {:agent_updated, 1001, [status: :running, turn: 2], node()})
      render(view)

      assert assigns(view)[:chat_fetch_seq] == seq
    end

    test "atom-list changed_fields is ignored (the core sends kwlists, never atom lists)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      # A legacy atom list is NOT a keyword list → Keyword.has_key? rejects it
      # (pin: only [message_count: n] triggers a refetch).
      send(view.pid, {:agent_updated, 1001, [:message_count], node()})
      render(view)

      assert assigns(view)[:chat_fetch_seq] == seq
    end

    test "real-shaped core event sequence does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: nil,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Real order from the core: agent_updated FIRST (agent-state insert, no
      # message_count), then the throttled agents_updated, then
      # agent_registered with an INTEGER id.
      send(
        view.pid,
        {:agent_updated, 1, [total_tokens: 0, compression_count: 0, objective: "hi"], node()}
      )

      send(view.pid, {:agents_updated, node()})
      render(view)

      send(
        view.pid,
        {:agent_registered, 1,
         %{
           status: :pending,
           depth: 0,
           parent_id: nil,
           task_id: "t1",
           task_number: 1,
           objective: "hi"
         }, node()}
      )

      render(view)
      assert assigns(view).chat_agent_id == 1

      send(view.pid, {:agent_updated, 1, [status: :running, worktree: "/tmp/x"], node()})
      send(view.pid, {:agent_updated, 1, [turn: 2], node()})
      send(view.pid, {:agent_updated, 1, [message_count: 3], node()})
      render(view)

      # Inject the fetched history with the CURRENT seq (the kwlist
      # :message_count refetch bumped it).
      send(
        view.pid,
        {:chat_history_loaded, node(), assigns(view)[:chat_fetch_seq], 1, real_history()}
      )

      # Await the assign the {:chat_history_loaded, ...} handler writes (the
      # same barrier the sibling "real AgentState ETS row" test uses) so the
      # render below reads the fully-applied injected history.
      wait_until(fn -> assigns(view)[:agent_message_count] == length(real_history()) end)

      html = render(view)
      assert html =~ "Genesis is an Elixir framework."
      assert html =~ "Thought process"

      # Double agent_removed (the core's recycling emits TWO) — no-op.
      send(view.pid, {:agent_removed, 1, node()})
      send(view.pid, {:agent_removed, 1, node()})

      html = render(view)
      assert page_heading(html) == "Genesis Assistant"
    end

    test "real AgentState ETS row flows through the real get_agent_history path", %{conn: conn} do
      agent_id = 300_000 + rem(System.unique_integer([:positive]), 50_000)
      seed_agent_state!(agent_id)

      {:ok, view, _html} = live(conn, "/help")

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: nil,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      send(
        view.pid,
        {:agent_registered, agent_id,
         %{
           status: :pending,
           depth: 0,
           parent_id: nil,
           task_id: "t1",
           task_number: 1,
           objective: "hi"
         }, node()}
      )

      # The REAL async fetch (NodeContext → RemoteNode → RemoteAPI
      # .get_agent_history) reads the ETS row and returns the native
      # %ReqLLM.Message{} structs — nil metadata, thinking parts, tool_calls
      # and all.
      wait_until(fn -> assigns(view)[:agent_message_count] == 5 end)

      html = render(view)
      assert html =~ "Genesis is an Elixir framework."
      assert html =~ "Thought process"
      assert html =~ "spawn_investigator"
    end

    test "foreign-node events are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_history_loaded, :other@host, seq, 1001,
         [%{role: :assistant, content: [%{text: "NOPE"}]}]}
      )

      send(view.pid, {:agent_updated, 1001, [message_count: 1], :other@host})

      send(
        view.pid,
        {:agent_registered, 1009, %{task_id: "t1", message_count: 1}, :other@host}
      )

      html = render(view)
      refute html =~ "NOPE"

      # Transcript unchanged: user bubble + still-streaming empty assistant
      # bubble; the foreign agent_registered never set chat_agent_id.
      assert assigns(view).chat_agent_id == 1001
      assert assigns(view).agent_message_count == nil

      assert [%{role: :user, text: "hello"}, %{role: :assistant, text: "", streaming: true}] =
               assigns(view).transcript
    end

    test "streamed text stays plain (never markdown) with no action group", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      # The history fetch replaces the in-progress bubble text (streaming stays
      # true) — a mid-stream render must show the literal source + caret, never
      # a markdown render (half-rendered streams would flicker).
      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001,
         [%{role: :assistant, content: [%{text: "partial **md**"}]}]}
      )

      html = render(view)
      assert html =~ "partial **md**"
      assert html =~ "help-caret"
      refute html =~ "md-content"
      # No hover action group on the still-streaming entry.
      refute html =~ "toggle_assistant_raw"
      refute html =~ "assistant-copy-"

      assert [%{role: :user}, %{role: :assistant, text: "partial **md**", streaming: true}] =
               assigns(view).transcript
    end
  end

  # Counts the assistant card's "Task" badge headers in rendered html. The
  # regex requires the text to be the WHOLE element content, so the sidebar
  # heading "Active Tasks" (more text inside one element) never counts.
  defp badge_count(html), do: length(Regex.scan(~r/>\s*Task\s*</s, html))

  describe "completion / error rendering" do
    # Each test drives finalize_terminal via an injected {:chat_task_loaded, ...}
    # with the CURRENT chat_task_fetch_seq (read dynamically). The handler only
    # reads Map.get(task, :status)/:result/:error, so a plain map works.
    test "completed task with a result renders the final answer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1",
         %{status: :completed, result: {:ok, %{result: "final answer"}}}}
      )

      html = render(view)
      assert html =~ "final answer"
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil

      assert [
               %{role: :user, text: "hello"},
               %{role: :assistant, text: "final answer", streaming: false}
             ] =
               assigns(view).transcript
    end

    test "completed markdown result renders .md-content with the rendered html", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1",
         %{status: :completed, result: {:ok, %{result: "**bold** answer"}}}}
      )

      html = render(view)

      # The finalized assistant entry renders through EvoDash.MarkdownRender:
      # a .md-content container with the rendered <strong>. Scope the
      # assertion with Floki — do NOT refute "**bold**" on the WHOLE html, the
      # copy button's data-content attribute legitimately carries the raw
      # markdown source.
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil

      md =
        html
        |> Floki.parse_document!()
        |> Floki.find(".md-content")

      assert md != []
      assert md |> Floki.find("strong") |> Floki.text() == "bold"
      # The copy action group carries the FULL raw source text.
      assert html =~ ~s(data-content="**bold** answer")
    end

    test "completed task without a result renders No response", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1", %{status: :completed, result: {:ok, %{}}}}
      )

      html = render(view)
      assert html =~ "No response."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "completed task with an error result renders The task failed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1", %{status: :completed, result: {:error, :boom}}}
      )

      html = render(view)
      assert html =~ "The task failed."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "cancelled task with a preserved result renders it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1",
         %{status: :cancelled, result: {:ok, %{result: "preserved"}}}}
      )

      html = render(view)
      assert html =~ "preserved"
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "cancelled task without a result renders Stopped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)
      send(view.pid, {:chat_task_loaded, node(), seq, "t1", %{status: :cancelled, result: nil}})
      html = render(view)
      assert html =~ "Stopped."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "deleted task renders the conversation-deleted marker", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)
      send(view.pid, {:chat_task_loaded, node(), seq, "t1", nil})
      html = render(view)
      assert html =~ "The conversation was deleted."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "failed task event finalizes the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_running_chat(view)
      send(view.pid, {:task_updated, "t1", :failed, node()})
      html = render(view)
      assert html =~ "The task failed."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "failed task whose error record carries a message renders that message", %{conn: conn} do
      # The fetched-task :failed terminal path (finalize_terminal → finalize_failed):
      # the decoded TaskInfo error record (atom-keyed %{kind:, source:, message:,
      # stacktrace:}) drives the final text via
      # AgentStream.extract_failed_message/1.
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1",
         %{
           status: :failed,
           error: %{
             kind: :force_kill,
             source: :force_kill_task,
             message: "Task force-killed by user",
             stacktrace: nil
           }
         }}
      )

      html = render(view)
      assert html =~ "Task force-killed by user"
      # The structured message REPLACES the generic placeholder.
      refute html =~ "The task failed."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      # clear_task_refs keeps the :failed badge on the final assistant card.
      assert assigns(view).chat_task_status == :failed

      assert [
               %{role: :user, text: "hello"},
               %{role: :assistant, text: "Task force-killed by user", streaming: false}
             ] = assigns(view).transcript
    end

    test "failed task without a usable error message falls back to The task failed", %{conn: conn} do
      # error absent / nil / empty / blank-only message — extract_failed_message/1
      # returns nil for each, so finalize_failed shows the generic gettext
      # fallback. Each payload needs its own view (one terminal injection per
      # chat), so iterate with a fresh mount per payload.
      payloads = [
        %{status: :failed},
        %{status: :failed, error: nil},
        %{status: :failed, error: %{kind: :boom, message: ""}},
        %{status: :failed, error: %{kind: :boom, message: "   "}}
      ]

      for payload <- payloads do
        {:ok, view, _html} = live(conn, "/help")
        seq = assigns(view)[:chat_task_fetch_seq]
        seed_running_chat(view)
        send(view.pid, {:chat_task_loaded, node(), seq, "t1", payload})
        html = render(view)
        assert html =~ "The task failed.", "expected the fallback for #{inspect(payload)}"
        assert assigns(view).chat_status == :idle
        assert assigns(view).chat_task_id == nil
        GenServer.stop(view.pid)
      end
    end

    test "legacy failed rows without a structured error render the fallback, no crash", %{
      conn: conn
    } do
      # Pre-feature failed rows carry no decoded error field (only the legacy
      # {:error, _} result tuple) — and an error value that is not a map must
      # degrade exactly like an absent one. extract_failed_message/1 never
      # raises, so each payload finalizes to the generic placeholder.
      payloads = [
        # Legacy row: result {:error, reason}, NO error key.
        %{status: :failed, result: {:error, :boom}},
        # error key present but the value is not a map.
        %{status: :failed, error: {:error, :boom}},
        %{status: :failed, error: "legacy string error"}
      ]

      for payload <- payloads do
        {:ok, view, _html} = live(conn, "/help")
        seq = assigns(view)[:chat_task_fetch_seq]
        seed_running_chat(view)
        send(view.pid, {:chat_task_loaded, node(), seq, "t1", payload})
        html = render(view)
        assert html =~ "The task failed.", "expected the fallback for #{inspect(payload)}"
        assert assigns(view).chat_status == :idle
        assert assigns(view).chat_task_id == nil
        assert assigns(view).chat_task_status == :failed
        GenServer.stop(view.pid)
      end
    end

    test "task deleted event finalizes the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_running_chat(view)
      send(view.pid, {:task_deleted, "t1", node()})
      html = render(view)
      assert html =~ "The conversation was deleted."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "final badge persists on the card after completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1",
         %{status: :completed, result: {:ok, %{result: "final answer"}}}}
      )

      html = render(view)
      assert html =~ "final answer"
      # clear_task_refs keeps :chat_task_status — the last assistant entry
      # still renders the "Task" header + the Completed badge.
      assert assigns(view).chat_task_status == :completed
      assert html =~ "Completed"
      assert badge_count(html) == 1
    end

    test "reflect task result renders as a mini task-card chat message", %{conn: conn} do
      # Pins the reflect-task rendering path on /help: a repo-less :reflect row
      # (the shape the Home send flow starts — mode "reflect", NO :path key, nil
      # project_path) whose terminal result must render as the final assistant
      # task-card entry on the Home page, regardless of how the Tasks page
      # displays (or hides) reflect tasks. Pure insert + deterministic terminal
      # injection — no real send, so neither cleanup_task_on_exit/1 nor the ETS
      # sweep is needed.
      fixture_id =
        insert_task_fixture!(
          id: "reflect_card_pin",
          type: :reflect,
          opts: [mode: "reflect", objective: "REFLECT_PIN_OBJECTIVE"],
          project_path: nil
        )

      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: fixture_id,
        chat_agent_id: 1001,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, fixture_id,
         %{
           status: :completed,
           result: {:ok, %{result: "REFLECT_PIN_RESULT rendered as task-card"}}
         }}
      )

      html = render(view)
      assert html =~ "REFLECT_PIN_RESULT rendered as task-card"
      # The finalized entry carries the mini task-card header + Completed badge.
      assert assigns(view).chat_task_status == :completed
      assert html =~ "Completed"
      assert badge_count(html) == 1
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil

      # The pinned row really is the repo-less reflect task (type :reflect, nil
      # project_path) — the row shape this chat renders results for.
      [reflect] =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      assert reflect.id == fixture_id
      assert reflect.project_path == nil
    end
  end

  describe "assistant task-card" do
    test "status badge attaches to the last assistant entry and tracks task events", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help")
      seed_running_chat(view)
      # Before any task event there is no badge (chat_task_status nil). Scoped
      # to .badge elements: the run-command approvals HTML comment in
      # home_live.ex also contains the word "Pending", so a bare substring
      # refute would always fail — the badge's presence is what matters.
      html = render(view)
      doc = Floki.parse_document!(html)
      assert Floki.find(doc, ".badge") == []
      # :pending → "Pending" badge appears on the card header.
      send(view.pid, {:task_updated, "t1", :pending, node()})
      html = render(view)
      doc = Floki.parse_document!(html)
      assert [badge] = Floki.find(doc, ".badge")
      assert Floki.text(badge) =~ "Pending"
      assert badge_count(html) == 1
      # :running → "Running" + the pulsing-dot convention (animate-ping).
      send(view.pid, {:task_updated, "t1", :running, node()})
      html = render(view)
      assert html =~ "Running"
      assert html =~ "animate-ping"
      # :completed → async_fetch_task bumped the seq; inject the terminal
      # result deterministically with the CURRENT seq.
      send(
        view.pid,
        {:chat_task_loaded, node(), assigns(view)[:chat_task_fetch_seq], "t1",
         %{status: :completed, result: {:ok, %{result: "done at last"}}}}
      )

      html = render(view)
      assert html =~ "done at last"
      assert html =~ "Completed"
      assert badge_count(html) == 1
      assert assigns(view).chat_status == :idle
    end

    test "only the LAST assistant entry carries the badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_fetch_seq]

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: 1001,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "older answer", streaming: false},
          %{id: "3", role: :user, text: "again", streaming: false},
          %{id: "4", role: :assistant, text: "", streaming: true}
        ]
      })

      # Materialize the seeded transcript into the rendered html via a real
      # assign path (history fetch updates the streaming bubble).
      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001,
         [%{role: :assistant, content: [%{text: "streamed"}]}]}
      )

      html = render(view)
      assert html =~ "older answer"
      assert html =~ "streamed"
      # No badge yet (chat_task_status nil).
      assert badge_count(html) == 0
      # A task event flips the badge on — but ONLY on the LAST assistant
      # entry (index 3), never the earlier one.
      send(view.pid, {:task_updated, "t1", :running, node()})
      html = render(view)
      assert html =~ "Running"
      assert badge_count(html) == 1
    end

    test "thought process section lists context-history entries incl. tool calls", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)
      send(view.pid, {:chat_history_loaded, node(), seq, 1001, real_history()})
      html = render(view)
      # Zero-JS <details> section with the 5 entry headers.
      assert html =~ "Thought process"
      assert html =~ "(5)"
      # System/user entry contents.
      assert html =~ "you are genesis"
      assert html =~ "New message: hi"
      # Assistant entry: reasoning details render from reasoning_details; the
      # :thinking content part's text is EXCLUDED from the entry content (it
      # would otherwise duplicate the reasoning text).
      refute html =~ "let me inspect the source"
      assert html =~ "think"
      # Tool entry: tool-name header + result content.
      assert html =~ "Tool Result: spawn_investigator"
      assert html =~ "result..."
      # Tool-call row via the agents-page ToolCallDisplay contract.
      assert html =~ "spawn_investigator"
    end
  end

  describe "assistant raw toggle & copy flash" do
    test "raw toggle flips exactly one message between markdown and raw view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_fetch_seq]

      # Two FINALIZED assistant entries (both render .md-content) plus a
      # streaming tail. The history fetch materializes the seeded transcript
      # into the rendered html via the real assign path (replace_state alone
      # never pushes a diff — same pattern as the badge tests).
      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: 1001,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "**first** md", streaming: false},
          %{id: "3", role: :assistant, text: "**second** md", streaming: false},
          %{id: "4", role: :assistant, text: "", streaming: true}
        ]
      })

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001,
         [%{role: :assistant, content: [%{text: "streamed tail"}]}]}
      )

      html = render(view)

      # NOTE: Floki.find must run on a PARSED document, never on the raw html
      # binary (LiveView envelope markup confuses the direct-binary path and
      # tag selectors come back empty) — parse first, everywhere below.
      doc = Floki.parse_document!(html)
      assert length(Floki.find(doc, ".md-content")) == 2

      # Toggle entry "2" to raw: its .md-content disappears (plain escaped
      # source text now), entry "3" is untouched — scope per wrapper id.
      html = render_click(view, "toggle_assistant_raw", %{"id" => "2"})
      doc = Floki.parse_document!(html)
      assert Floki.find(doc, ~s(#chat-entry-2 .md-content)) == []
      assert Floki.find(doc, ~s(#chat-entry-2)) |> Floki.text() =~ "**first** md"
      assert length(Floki.find(doc, ~s(#chat-entry-3 .md-content))) == 1
      assert MapSet.member?(assigns(view).raw_entry_ids, "2")
      refute MapSet.member?(assigns(view).raw_entry_ids, "3")

      # Toggle back: markdown returns for entry "2", the raw set empties.
      html = render_click(view, "toggle_assistant_raw", %{"id" => "2"})
      doc = Floki.parse_document!(html)
      assert length(Floki.find(doc, ".md-content")) == 2
      refute MapSet.member?(assigns(view).raw_entry_ids, "2")
    end

    test "copied event flashes the info confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      # Finalize a completed entry (the copy button exists on finalized
      # entries only; the hook is client-side, the event just flashes).
      send(
        view.pid,
        {:chat_task_loaded, node(), seq, "t1",
         %{status: :completed, result: {:ok, %{result: "final answer"}}}}
      )

      render(view)

      html = render_hook(view, "copied", %{})
      assert html =~ "Copied to clipboard"
      assert assigns(view).chat_status == :idle
    end
  end

  describe "chat persistence / restore (ChatHistory)" do
    test "transcript and status persist across a remount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      chat_id = assigns(view).chat_id
      assert chat_id != nil

      # Fully SYNTHETIC running chat: seed the state a real send would produce
      # (the user entry "persist me please" + an empty streaming assistant
      # entry, refs set) via seed_chat_state — the real reflect runtime must
      # never run in this suite (see the setup's fail-fast block).
      # seed_chat_state bypasses __changed__ tracking, so
      # the seeded transcript is materialized into rendered html by the same
      # real assign path the badge/persistence tests use (a matching task
      # event), then finalized with the exact {:task_updated, ...} shape the
      # core broadcasts.
      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t_persist",
        chat_agent_id: 1001,
        chat_node: node(),
        transcript: [
          %{id: "1", role: :user, text: "persist me please", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Materialize the seeded state (a matching non-terminal task event runs
      # handle_task_event's assign/persist path) and persist the running state
      # into ChatHistory through the REAL persist point.
      send(view.pid, {:task_updated, "t_persist", :running, node()})
      render(view)
      assert assigns(view).chat_status == :running
      assert EvoDash.ChatHistory.get_state(chat_id).chat_status == :running

      # Deterministic terminal event (the same event the finalize_failed
      # helper drives): :failed finalizes the transcript and clears the refs.
      finalize_failed(view, "t_persist")

      assert assigns(view).chat_status == :idle
      # The terminal event persisted the full state into ChatHistory.
      stored = EvoDash.ChatHistory.get_state(chat_id)
      assert stored != nil
      assert Enum.any?(stored.transcript, &(&1.role == :user and &1.text == "persist me please"))
      # "Close the page" (stop the view process) and remount: attach_chat
      # restores the CURRENT chat — transcript and status.
      GenServer.stop(view.pid)
      {:ok, view2, html} = live(conn, "/help")
      assert assigns(view2).chat_id == chat_id
      assert html =~ "persist me please"
      assert assigns(view2).chat_status == :idle
      assert assigns(view2).chat_task_id == nil
    end

    test "reconciliation finalizes from a terminal row that carries an archive (lite read)", %{
      conn: conn
    } do
      # The result still carries the legacy `archive_records` payload (older
      # rows); the per-agent archive itself is no longer a task-row column. The
      # terminal path needs only status/result/error, so the lite read must
      # still finalize the transcript.
      insert_task_fixture!(
        id: "t_archived",
        type: :reflect,
        status: :completed,
        opts: [mode: "reflect", objective: "New message: archived"],
        project_path: nil,
        result:
          {:ok,
           %{
             result: "final answer with archive",
             commit_sha: nil,
             branch_name: nil,
             tag: nil,
             archive_records: [%{"agent_id" => 1, "objective" => "probe"}]
           }}
      )

      {:ok, view, _html} = live(conn, "/help")
      chat_id = assigns(view).chat_id

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t_archived",
        chat_agent_id: 1001,
        chat_node: node(),
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Persist the mid-run state via a REAL persist point (task event).
      send(view.pid, {:task_updated, "t_archived", :running, node()})
      render(view)
      # Leave the page and remount: the ONE-SHOT reconciliation fetch lands
      # the terminal row and finalizes the transcript from `result`.
      GenServer.stop(view.pid)
      {:ok, view2, _html} = live(conn, "/help")
      assert assigns(view2).chat_id == chat_id

      wait_until(fn -> assigns(view2).chat_status == :idle end)
      html = render(view2)
      assert html =~ "final answer with archive"
      assert assigns(view2).chat_task_status == :completed
      assert assigns(view2).chat_task_id == nil
    end

    test "mid-run remount reconciles the task ONCE and applies the terminal state", %{
      conn: conn
    } do
      # The task "completes while the page is closed": the store row is
      # ALREADY terminal when the view remounts.
      insert_task_fixture!(
        id: "t_away",
        type: :reflect,
        status: :completed,
        opts: [mode: "reflect", objective: "New message: away"],
        project_path: nil,
        result:
          {:ok, %{result: "finished while away", commit_sha: nil, branch_name: nil, tag: nil}}
      )

      {:ok, view, _html} = live(conn, "/help")
      chat_id = assigns(view).chat_id

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t_away",
        chat_agent_id: 1001,
        chat_node: node(),
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Persist the mid-run state via a REAL persist point (task event).
      send(view.pid, {:task_updated, "t_away", :running, node()})
      render(view)
      assert EvoDash.ChatHistory.get_state(chat_id).chat_status == :running
      # Leave the page and remount.
      GenServer.stop(view.pid)
      {:ok, view2, _html} = live(conn, "/help")
      assert assigns(view2).chat_id == chat_id
      # attach_chat restored the running chat; reconcile_chat spawned the
      # ONE-SHOT task fetch (chat_task_fetch_seq 0→1) which lands the
      # terminal :completed row → finalize + clear refs.
      wait_until(fn -> assigns(view2).chat_status == :idle end)
      html = render(view2)
      assert html =~ "finished while away"
      assert assigns(view2).chat_task_id == nil
      assert assigns(view2).chat_agent_id == nil
      # The final badge stays (clear_task_refs keeps :chat_task_status).
      assert assigns(view2).chat_task_status == :completed
      assert html =~ "Completed"
    end

    test "mid-run remount keeps the refs when the task is still alive", %{conn: conn} do
      insert_task_fixture!(
        id: "t_alive",
        type: :reflect,
        status: :running,
        opts: [mode: "reflect", objective: "New message: alive"],
        project_path: nil
      )

      {:ok, view, _html} = live(conn, "/help")
      chat_id = assigns(view).chat_id

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t_alive",
        chat_agent_id: 1001,
        chat_node: node(),
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      send(view.pid, {:task_updated, "t_alive", :running, node()})
      render(view)
      GenServer.stop(view.pid)
      {:ok, view2, _html} = live(conn, "/help")
      assert assigns(view2).chat_id == chat_id
      # The one-shot reconcile fetch finds a STILL-RUNNING task: badge/status
      # refreshed, refs KEPT (further task/agent events must still match).
      wait_until(fn -> assigns(view2)[:chat_task_fetch_seq] == 1 end)
      assert assigns(view2).chat_task_id == "t_alive"
      assert assigns(view2).chat_status == :running
      assert assigns(view2).chat_agent_id == 1001
      assert assigns(view2).chat_task_status == :running
    end
  end

  describe "provider-profile model selector" do
    # All real sends still use the file-level empty scheduler profile seam:
    # inspect the persisted dashboard→TaskRegistry opts, never contact an LLM.
    # ModelSelect and TaskRegistry admission must read the same canonical file.
    # The singleton registry has no caller chain back to the test, so expose this
    # fixture through the call-time directory seam for the duration of the test.
    # This additional app-global dependency is safe only in this sync module;
    # it does NOT populate scheduler profiles or permit a provider request.
    defp write_provider_profile_config do
      config_path = EvoGit.Config.config_path()
      config_root = config_path |> Path.dirname() |> Path.dirname()
      original_config_dir_fun = Application.fetch_env(:evo_git, :config_dir_fun)
      Application.put_env(:evo_git, :config_dir_fun, fn -> config_root end)

      on_exit(fn ->
        case original_config_dir_fun do
          {:ok, resolver} -> Application.put_env(:evo_git, :config_dir_fun, resolver)
          :error -> Application.delete_env(:evo_git, :config_dir_fun)
        end
      end)

      assert EvoGit.Config.config_path() == config_path

      File.write!(config_path, """
      [llm]
      default_provider_profile = "work-account"

      [[llm.providers]]
      id = "first-account"
      name = "Personal"
      provider = "openai"
      models = ["fast-model"]

      [[llm.providers]]
      id = "work-account"
      name = "Work"
      provider = "openai"
      base_url = "https://example.invalid/v1"
      extra = {account_secret = "server-only-test-secret"}
      default_model = "reasoned-model"
      models = ["fast-model", {model = "reasoned-model", reasoning_efforts = ["low", "medium", "high"], default_reasoning_effort = "medium"}]
      """)
    end

    defp work_spec(effort \\ "medium") do
      %{
        "provider_profile_id" => "work-account",
        "model" => "reasoned-model",
        "reasoning_effort" => effort
      }
    end

    defp selected_option(html, id) do
      html
      |> Floki.parse_document!()
      |> Floki.find("##{id} option[selected]")
      |> Floki.attribute("value")
    end

    defp only_reflect_task do
      [task] =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      task
    end

    defp assert_task_selection(task, spec) do
      # Store.Codec atomizes the outer canonical key, preserving string keys
      # inside its selection map; the legacy lock key still decodes as a string.
      assert opt(task, :model_spec) == spec
      refute has_opt?(task, "model_spec")
      assert opt(task, "model_id_locked") == true
      refute has_opt?(task, :model_id)
      refute has_opt?(task, "model_id")
      refute has_opt?(task, :path)
      refute has_opt?(task, "path")
    end

    defp assert_auto_task(task) do
      for key <- [
            :model_spec,
            :model_id,
            :model_id_locked,
            "model_spec",
            "model_id",
            "model_id_locked"
          ] do
        refute has_opt?(task, key)
      end
    end

    test "header projects canonical provider, model and reasoning defaults without credentials",
         %{
           conn: conn
         } do
      write_provider_profile_config()
      {:ok, view, html} = live(conn, "/help")

      assert present?(
               html,
               ~s(#chat-llm-selection-provider[name="provider_profile_id"][phx-change="select_provider_profile"])
             )

      assert present?(
               html,
               ~s(#chat-llm-selection-model[name="model"][phx-change="select_model"])
             )

      assert present?(
               html,
               ~s(#chat-llm-selection-reasoning[name="reasoning_effort"][phx-change="select_reasoning_effort"][value="1"])
             )

      refute present?(html, ~s(select[name="model_id"]))
      refute present?(html, "#chat-form #chat-llm-selection")
      dom = Floki.parse_document!(html)

      assert dom |> Floki.find("#chat-llm-selection-provider option") |> Floki.attribute("value") ==
               ["", "first-account", "work-account"]

      assert dom |> Floki.find("#chat-llm-selection-model option") |> Floki.attribute("value") ==
               ["", "fast-model", "reasoned-model"]

      assert selected_option(html, "chat-llm-selection-provider") == ["work-account"]
      assert selected_option(html, "chat-llm-selection-model") == ["reasoned-model"]
      assert assigns(view).model_spec == work_spec()
      assert assigns(view).selected_model_id == nil
      assert assigns(view).model_selection_scope == {nil, node()}

      assert assigns(view).provider_profiles ==
               EvoGit.Config.Schema.provider_profiles(assigns(view).model_snapshot.config)

      assert assigns(view).model_selections ==
               EvoGit.Config.Schema.model_selections(assigns(view).model_snapshot.config)

      refute html =~ "server-only-test-secret"
      refute html =~ "https://example.invalid/v1"
      refute html =~ "Auto (by rules)"
    end

    test "empty configuration renders disabled provider controls and setup guidance", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/help")

      assert assigns(view).provider_profiles == []
      assert present?(html, ~s(#chat-llm-selection-provider[disabled]))
      assert present?(html, ~s(#chat-llm-selection-model[disabled]))
      assert html =~ "No provider profiles configured. Add one in Settings to choose a model."
      refute present?(html, "#chat-llm-selection-reasoning")
    end

    test "typed submit locks a canonical model_spec and the resolved slider effort", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      assert assigns(view).model_spec == work_spec("high")

      {html, _log} =
        send_and_await_terminal(fn ->
          render_submit(view, "send_message", %{"message" => "hello"})
        end)

      assert html =~ "hello"
      task = only_reflect_task()
      assert_task_selection(task, work_spec("high"))
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "hello"
      refute inspect(task.opts) =~ "server-only-test-secret"
      cleanup_task_on_exit(task.id)
    end

    test "explicit Auto after a pin survives remount and submits no model override", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      assert assigns(view).model_spec == work_spec()
      render_change(view, "select_provider_profile", %{"provider_profile_id" => ""})
      assert assigns(view).model_spec == %{}
      chat_id = assigns(view).chat_id
      assert EvoDash.ChatHistory.get_state(chat_id).model_spec == %{}

      GenServer.stop(view.pid)
      {:ok, view, html} = live(conn, "/help")
      assert assigns(view).chat_id == chat_id
      assert assigns(view).model_spec == %{}
      assert selected_option(html, "chat-llm-selection-provider") == [""]
      refute present?(html, "#chat-llm-selection-reasoning")

      send_and_await_terminal(fn ->
        render_submit(view, "send_message", %{"message" => "auto please"})
      end)

      task = only_reflect_task()
      assert_auto_task(task)
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "auto please"
      cleanup_task_on_exit(task.id)
    end

    test "provider and model changes reset downstream defaults and reject forged choices", %{
      conn: conn
    } do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      html = render_change(view, "select_model", %{"model" => "fast-model"})

      assert assigns(view).model_spec == %{
               "provider_profile_id" => "work-account",
               "model" => "fast-model"
             }

      refute present?(html, "#chat-llm-selection-reasoning")

      render_change(view, "select_model", %{"model" => "reasoned-model"})
      assert assigns(view).model_spec == work_spec()
      render_change(view, "select_provider_profile", %{"provider_profile_id" => "first-account"})
      expected = %{"provider_profile_id" => "first-account", "model" => "fast-model"}
      assert assigns(view).model_spec == expected

      for {event, params} <- [
            {"select_provider_profile", %{"provider_profile_id" => "removed"}},
            {"select_model", %{"model" => "reasoned-model"}},
            {"select_reasoning_effort", %{"reasoning_effort" => "99"}}
          ] do
        html = render_change(view, event, params)
        assert html =~ "Choose a valid provider profile, model and reasoning effort."
        assert assigns(view).model_spec == expected
        assert EvoDash.ChatHistory.get_state(assigns(view).chat_id).model_spec == expected
      end
    end

    test "legacy ChatHistory id migrates on mount to a canonical same-node selection", %{
      conn: conn
    } do
      write_provider_profile_config()
      chat_id = EvoDash.ChatHistory.new_chat()
      EvoDash.ChatHistory.put_state(chat_id, %{selected_model_id: "first-account"})

      {:ok, view, html} = live(conn, "/help")
      expected = %{"provider_profile_id" => "first-account", "model" => "fast-model"}
      assert assigns(view).chat_id == chat_id
      assert assigns(view).model_spec == expected
      assert assigns(view).selected_model_id == nil
      assert assigns(view).model_selection_scope == {nil, node()}
      assert selected_option(html, "chat-llm-selection-provider") == ["first-account"]
      assert EvoDash.ChatHistory.get_state(chat_id).model_spec == expected
    end

    test "malformed persisted selection blocks submit without losing the draft until explicitly repaired",
         %{conn: conn} do
      write_provider_profile_config()
      chat_id = EvoDash.ChatHistory.new_chat()

      EvoDash.ChatHistory.put_state(chat_id, %{
        model_spec: false,
        model_selection_scope: {nil, node()},
        chat_draft: "keep this draft"
      })

      {:ok, view, html} = live(conn, "/help")
      assert assigns(view).model_selection_error == :invalid_model_spec
      assert disabled?(html, ~s(#chat-form button[type="submit"]))
      html = render_submit(view, "send_message", %{"message" => "keep this draft"})
      assert html =~ "Choose a valid model before sending a message."
      assert assigns(view).chat_draft == "keep this draft"
      assert assigns(view).transcript == []
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      render_change(view, "select_provider_profile", %{"provider_profile_id" => "work-account"})
      assert assigns(view).model_selection_error == nil
      assert assigns(view).model_spec == work_spec()
      saved = EvoDash.ChatHistory.get_state(chat_id)
      assert saved.model_spec == work_spec()
      assert saved.model_selection_error == nil
    end

    test "canonical pin and node scope survive a remount without persisting the snapshot", %{
      conn: conn
    } do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      chat_id = assigns(view).chat_id
      saved = EvoDash.ChatHistory.get_state(chat_id)
      assert saved.model_spec == work_spec("high")
      assert saved.model_selection_scope == {nil, node()}
      assert saved.selected_model_id == nil

      for key <- [:model_snapshot, :model_selection_bundle, :provider_profiles, :model_selections] do
        refute Map.has_key?(saved, key)
      end

      refute inspect(saved) =~ "server-only-test-secret"

      GenServer.stop(view.pid)
      {:ok, view, html} = live(conn, "/help")
      assert assigns(view).chat_id == chat_id
      assert assigns(view).model_spec == work_spec("high")
      assert assigns(view).model_selection_scope == {nil, node()}
      assert selected_option(html, "chat-llm-selection-provider") == ["work-account"]
      assert present?(html, ~s(#chat-llm-selection-reasoning[value="2"]))
    end

    test "suggestion-chip send locks the same canonical selection as typed submit", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")

      send_and_await_terminal(fn ->
        view |> element(~s(button[phx-value-message="Show my running tasks"])) |> render_click()
      end)

      task = only_reflect_task()
      assert_task_selection(task, work_spec())
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "Show my running tasks"
      cleanup_task_on_exit(task.id)
    end

    test "suggestion-chip send on explicit Auto omits all model overrides", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_provider_profile", %{"provider_profile_id" => ""})

      send_and_await_terminal(fn ->
        view |> element(~s(button[phx-value-message="Start a task for me"])) |> render_click()
      end)

      task = only_reflect_task()
      assert_auto_task(task)
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "Start a task for me"
      cleanup_task_on_exit(task.id)
    end

    test "new chat retains its same-node canonical pin and locks the next send", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      old_chat_id = assigns(view).chat_id
      html = render_click(view, "new_chat", %{})
      assert html =~ "Start a conversation"
      assert assigns(view).chat_id != old_chat_id
      assert assigns(view).transcript == []
      assert assigns(view).model_spec == work_spec("high")
      assert EvoDash.ChatHistory.get_state(assigns(view).chat_id).model_spec == work_spec("high")

      send_and_await_terminal(fn ->
        render_submit(view, "send_message", %{"message" => "after new chat"})
      end)

      task = only_reflect_task()
      assert_task_selection(task, work_spec("high"))
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "after new chat"
      cleanup_task_on_exit(task.id)
    end
  end

  describe "production-mimicking crash repro" do
    test "real reflect task + real agent ETS rows + real broadcasts end-to-end", %{conn: conn} do
      # A REAL agent id in the scheduler's id space (integer, like production).
      agent_id = 400_000 + rem(System.unique_integer([:positive]), 50_000)
      # REAL scheduler ETS rows: SchedMeta + AgentState with a REAL
      # %ReqLLM.Context{} whose history includes thinking parts, tool_calls,
      # reasoning_details, nil metadata AND an assistant message with
      # content: [] (the empty-list hardening case).
      spec = %EvoGit.AgentSpec{
        context_node: %EvoGit.Core.ContextNode{path: "/tmp/x", repo: "/tmp/x"},
        phylo_node: %EvoGit.Core.PhyloGraphNode{
          repo: "/tmp/x",
          base_commit: "abc",
          current_commit: "abc"
        },
        agent_module: EvoGit.Agents.SelfReflective,
        objective: "New message: crash"
      }

      meta = %EvoGit.AgentScheduler.SchedMeta{
        id: agent_id,
        depth: 0,
        task_id: "t_crash",
        spec: spec
      }

      :ets.insert(:evogit_sched_meta, {agent_id, meta})
      on_exit(fn -> :ets.delete(:evogit_sched_meta, agent_id) end)

      seed_agent_state!(
        agent_id,
        ReqLLM.Context.new(
          real_history() ++ [%ReqLLM.Message{role: :assistant, content: [], metadata: nil}]
        )
      )

      # A REAL reflect task row: :running, nil project_path (repo-less), the
      # exact opts the dashboard writes.
      insert_task_fixture!(
        id: "t_crash",
        type: :reflect,
        status: :running,
        opts: [mode: "reflect", objective: "New message: crash"],
        project_path: nil
      )

      {:ok, view, _html} = live(conn, "/help")

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t_crash",
        chat_agent_id: agent_id,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # The exact production event sequence, rendering after each step.
      send(view.pid, {:task_updated, "t_crash", :running, node()})
      html = render(view)
      assert page_heading(html) == "Genesis Assistant"
      send(view.pid, {:agent_updated, agent_id, [message_count: 2], node()})
      html = render(view)
      assert page_heading(html) == "Genesis Assistant"

      send(
        view.pid,
        {:agent_registered, agent_id,
         %{
           status: :running,
           depth: 0,
           parent_id: nil,
           task_id: "t_crash",
           task_number: 1,
           objective: "hi"
         }, node()}
      )

      html = render(view)
      assert page_heading(html) == "Genesis Assistant"
      # The real history fetch lands: 6 messages (5 real + the empty-content
      # assistant) — nil metadata, thinking parts, tool_calls and all.
      wait_until(fn -> assigns(view)[:agent_message_count] == 6 end)
      html = render(view)
      assert html =~ "Genesis is an Elixir framework."
      assert html =~ "Thought process"
      # The task completes: the REAL row flips to :completed with a real
      # reflect result; the broadcast triggers the REAL terminal fetch.
      EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
        id: "t_crash",
        type: :reflect,
        status: :completed,
        opts: [mode: "reflect", objective: "New message: crash"],
        project_path: nil,
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result:
          {:ok, %{result: "final reflect answer", commit_sha: nil, branch_name: nil, tag: nil}}
      })

      send(view.pid, {:task_updated, "t_crash", :completed, node()})
      html = render(view)
      assert page_heading(html) == "Genesis Assistant"
      wait_until(fn -> assigns(view).chat_status == :idle end)
      html = render(view)
      assert html =~ "final reflect answer"
      assert html =~ "Completed"
      assert assigns(view).chat_task_id == nil
    end
  end

  describe "sidebar robustness" do
    test "warm ActiveTasks hub seeds the sidebar instantly on mount (no broadcast needed)", %{
      conn: conn
    } do
      # Pre-warm the shared hub for the local context with a reflect-style
      # :running summary map (the shape an applied fetch result writes — the
      # 16-key EvoGit.TaskRegistry.list_tasks_summary/1 projection). The hub
      # seed is SYNCHRONOUS (node_aware.ex on_mount), so the VERY FIRST render
      # already carries the sidebar — no task_updated broadcast, no debounce
      # sleep: the exact no-blink contract. (The connected-mount
      # staleness-catch-up fetch still fires afterwards and is stale-guarded;
      # it lands after this html assertion and does not affect the first
      # paint.)
      EvoDash.ActiveTasks.put(
        nil,
        node(),
        [
          %{
            id: "reflect_instant",
            type: :reflect,
            status: :running,
            review_status: nil,
            started_at: DateTime.utc_now(),
            finished_at: nil,
            project_path: nil,
            opts: [mode: "reflect", objective: "New message: instant"],
            branch_name: nil,
            model_id: nil,
            agent_count: 0,
            base_sha: nil,
            commit_sha: nil,
            lease_expires_at: nil,
            updated_at: nil,
            error: nil
          }
        ],
        []
      )

      # Both the dead render and the connected mount seed :running_tasks /
      # :pending_tasks synchronously from the hub, so the mount html already
      # contains the running reflect task's sidebar row.
      {:ok, _view, html} = live(conn, "/help")

      assert html =~ "Active Tasks"
      assert html =~ "New message: instant"
    end

    test "debounced reload after task_updated renders sidebar with a reflect task", %{conn: conn} do
      # A repo-less reflect row (nil project_path) must not break the sidebar.
      insert_task_fixture!(
        id: "reflect_side",
        type: :reflect,
        status: :running,
        opts: [mode: "reflect", objective: "New message: hi"],
        project_path: nil
      )

      {:ok, view, _html} = live(conn, "/help")
      send(view.pid, {:task_updated, "reflect_side", :pending, node()})
      send(view.pid, {:task_updated, "reflect_side", :running, node()})

      # The broadcast has been processed (assigns/1 is a :sys.get_state
      # round-trip), so the trailing-edge debounce is scheduled. Poll
      # until it has fired and the sidebar reload ran — no fixed sleep.
      assert assigns(view)[:tasks_reload_pending] == true
      wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)

      html = render(view)
      assert html =~ "Active Tasks"
      assert html =~ "New message"
    end

    test "completed tasks with nil timestamps do not crash the partition sort", %{conn: conn} do
      insert_task_fixture!(
        id: "reflect_a",
        type: :reflect,
        status: :completed,
        opts: [mode: "reflect", objective: "New message: a"],
        project_path: nil,
        started_at: nil,
        finished_at: nil,
        branch_name: "agent-x"
      )

      insert_task_fixture!(
        id: "reflect_b",
        type: :reflect,
        status: :completed,
        opts: [mode: "reflect", objective: "New message: b"],
        project_path: nil,
        started_at: nil,
        finished_at: nil,
        branch_name: "agent-y"
      )

      {:ok, view, _html} = live(conn, "/help")
      send(view.pid, {:task_updated, "reflect_a", :completed, node()})
      send(view.pid, {:task_updated, "reflect_b", :completed, node()})

      # The broadcasts have been processed (assigns/1 syncs), so the
      # trailing-edge debounce is scheduled. Poll until it fired and the
      # sidebar reload ran (exercise partition_active_tasks/1 with the
      # nil-timestamp rows) — no fixed sleep.
      assert assigns(view)[:tasks_reload_pending] == true
      wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)

      html = render(view)
      assert page_heading(html) == "Genesis Assistant"
    end

    test "nil-status (review-mutation) broadcast is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_running_chat(view)
      send(view.pid, {:task_updated, "t1", nil, node()})
      html = render(view)
      assert page_heading(html) == "Genesis Assistant"
      assert assigns(view).chat_status == :running
      assert assigns(view).chat_task_id == "t1"
      assert assigns(view).chat_task_status == nil
    end

    # (A former "real send through the real TaskRegistry survives the full
    # lifecycle" test was removed: the full wrapper→terminal lifecycle is
    # core-runtime territory covered by evo_git's own suites, and this page's
    # unique behaviors — optimistic bubbles, synchronous tracking, persisted
    # opts, finalize paths — are pinned by the canonical send test above and
    # the injection-driven describes here.)
  end

  describe "stop / cancel flow" do
    test "stop cancels a pending task and finalizes it", %{conn: conn} do
      fixture_id = insert_task_fixture!(status: :pending)
      {:ok, view, _html} = live(conn, "/help")

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: fixture_id,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Materialize a diff so the rendered html reflects the running state: a
      # matching :running task event triggers async_lookup_agent → assign. The
      # Stop-button state itself is NOT diffed here (chat_status was injected
      # via replace_state, bypassing assign/2's __changed__ tracking), so the
      # html-level "enabled" check is unreliable — assert the accurate assigns
      # value instead.
      send(view.pid, {:task_updated, fixture_id, :running, node()})
      render(view)
      assert assigns(view).chat_status == :running
      # render_click("stop") runs the REAL cancel: :pending → immediate
      # :cancelled + broadcast. The view shows :cancelling (the async task
      # fetch may already have landed → :idle; accept both).
      render_click(view, "stop", %{})
      assert assigns(view).chat_status in [:cancelling, :idle]
      # Deterministic finalize: inject the fetched :cancelled task with the
      # CURRENT seq. If the real async fetch already landed (chat_task_id nil),
      # the injected message is stale-dropped — but the finalize already
      # happened, so the assertions still hold. Both paths are idempotent.
      seq = assigns(view)[:chat_task_fetch_seq]

      send(
        view.pid,
        {:chat_task_loaded, node(), seq, fixture_id, %{status: :cancelled, result: nil}}
      )

      html = render(view)
      assert html =~ "Stopped."
      assert assigns(view).chat_status == :idle
      assert disabled?(html, ~s(button[phx-click="stop"]))
    end

    test "stop with no task is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      html = render_click(view, "stop", %{})
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      assert html =~ "Start a conversation"
    end
  end

  # Command-approval request fixtures (security levels 2 & 3 of the core's
  # run_command tool). Defaults match the seeded running chat used by the
  # approval tests below: task "t1" on the LOCAL node; agent_id nil so the
  # task-id path of own_request?/2 does the matching.
  defp l2_request(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "req-1",
        command: "NavigateToPage.navigate",
        args: "guide the user to the Settings page",
        level: 2,
        agent_id: nil,
        task_id: "t1",
        node: node()
      },
      Map.new(overrides)
    )
  end

  defp l3_request(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "req-1",
        command: "StartTask.start_task",
        args: "start a genesis task",
        level: 3,
        agent_id: nil,
        task_id: "t1",
        node: node()
      },
      Map.new(overrides)
    )
  end

  # The evaluator runs on target_node, but the pending request and its
  # response belong to the SOURCE chat node (`node`), which may differ.
  defp eval_request(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "eval-1",
        kind: :elixir_eval,
        tier: :write,
        code: "value = \"<exact>& code\"\n  value <> \"  preserved\"\n",
        warning: nil,
        target_node: :target@runtime,
        agent_id: nil,
        task_id: "t1",
        node: node()
      },
      Map.new(overrides)
    )
  end

  defp approval_button(id, decision) do
    ~s(button[phx-click="approval_response"][phx-value-request_id="#{id}"][phx-value-decision="#{decision}"])
  end

  defp install_blocking_approval_responder do
    test_pid = self()

    Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
      send(test_pid, {:approval_response_called, self(), source, id, decision})

      receive do
        {:respond, result} -> result
      after
        5000 -> exit(:approval_test_timeout)
      end
    end)
  end

  defp seed_restorable_approval_chat do
    insert_task_fixture!(
      id: "t1",
      type: :reflect,
      status: :running,
      opts: [mode: "reflect", objective: "approval recovery"],
      project_path: nil
    )

    chat_id = EvoDash.ChatHistory.new_chat()

    EvoDash.ChatHistory.put_state(
      chat_id,
      EvoDashWeb.HomeLive.ChatState.build(%{
        chat_status: :running,
        chat_task_status: :running,
        chat_task_id: "t1",
        chat_agent_id: 1001,
        chat_node: node()
      })
    )

    chat_id
  end

  defp approval_scope(view) do
    a = assigns(view)

    {a[:chat_id], a[:current_node_id], a[:current_node], a[:chat_node] || a[:current_node],
     a[:chat_task_id], a[:chat_agent_id]}
  end

  describe "command approvals (security levels 2 & 3)" do
    setup do
      keys = [:approval_responder, :approval_pending_runner]
      originals = Map.new(keys, &{&1, Application.fetch_env(:evo_dash, &1)})

      # A restored chat must never query an ambient singleton's pending list.
      # Recovery tests below override this list-returning runner explicitly.
      Application.put_env(:evo_dash, :approval_pending_runner, fn _source -> [] end)

      on_exit(fn ->
        Enum.each(originals, fn
          {key, {:ok, value}} -> Application.put_env(:evo_dash, key, value)
          {key, :error} -> Application.delete_env(:evo_dash, key)
        end)
      end)

      :ok
    end

    test "level-2 request renders an informational card with both buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l2_request()})
      html = render(view)

      # Informational wording + info styling (title/badge/icon/Confirm).
      assert html =~ "The assistant wants your attention"
      assert html =~ "hero-information-circle"
      assert html =~ "btn btn-primary btn-sm"
      assert html =~ "badge badge-sm badge-info"
      # The command shows in a <code> block; args as plain escaped text below it.
      assert html =~ "NavigateToPage.navigate"
      assert html =~ "guide the user to the Settings page"

      # Both buttons: Confirm (approve) + Deny (deny), each carrying the
      # phx-click + request id.
      doc = Floki.parse_document!(html)
      assert length(Floki.find(doc, ~s([phx-click="approval_response"]))) == 2
      assert length(Floki.find(doc, ~s([phx-value-decision="approve"]))) == 1
      assert length(Floki.find(doc, ~s([phx-value-decision="deny"]))) == 1
      assert length(Floki.find(doc, ~s([phx-value-request_id="req-1"]))) == 2

      assert [entry] = assigns(view)[:pending_approvals]
      assert entry.request_id == "req-1"
    end

    test "level-3 request renders a danger card with alarming wording", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l3_request()})
      html = render(view)

      # Danger wording + error styling (title/badge/icon/Confirm).
      assert html =~ "Action required — real side effects"
      assert html =~ "StartTask.start_task"
      assert html =~ "hero-exclamation-triangle"
      assert html =~ "btn btn-error btn-sm"
      assert html =~ "badge badge-sm badge-error"
      refute html =~ "The assistant wants your attention"
    end

    test "requests for other tasks, agents, and nodes are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      # Other task id (agent_id nil → no agent match either).
      send(view.pid, {:approval_requested, l2_request(task_id: "other-task")})
      render(view)
      assert assigns(view)[:pending_approvals] == []

      # Same shape but a foreign agent: string "someone-else" vs the integer
      # 1001 → the to_string/1 comparison never matches.
      send(view.pid, {:approval_requested, l2_request(task_id: nil, agent_id: "someone-else")})
      render(view)
      assert assigns(view)[:pending_approvals] == []

      # Matching task but a foreign node.
      send(view.pid, {:approval_requested, l2_request(node: :foreign@node)})
      html = render(view)
      assert assigns(view)[:pending_approvals] == []
      refute html =~ "The assistant wants your attention"
      refute html =~ "Action required — real side effects"
    end

    test "approval_resolved removes the card (unknown ids are no-ops)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l2_request()})
      render(view)
      assert length(assigns(view)[:pending_approvals]) == 1

      # Unknown id: harmless no-op — the card stays.
      send(view.pid, {:approval_resolved, "unknown-id", :approve})
      render(view)
      assert length(assigns(view)[:pending_approvals]) == 1

      send(view.pid, {:approval_resolved, "req-1", :approve})
      html = render(view)
      assert assigns(view)[:pending_approvals] == []
      refute html =~ "The assistant wants your attention"
    end

    test "confirm/deny retain a busy card until the asynchronous responder succeeds", %{
      conn: conn
    } do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      for {id, decision} <- [{"req-1", "approve"}, {"req-2", "deny"}] do
        send(view.pid, {:approval_requested, l2_request(request_id: id)})
        render(view)

        html =
          view
          |> element(approval_button(id, decision))
          |> render_click()

        assert_receive {:approval_response_called, worker, source, ^id, ^decision}, 2000
        assert source == node()
        refute worker == view.pid
        assert [%{request_id: ^id}] = assigns(view)[:pending_approvals]
        assert disabled?(html, approval_button(id, "approve"))
        assert disabled?(html, approval_button(id, "deny"))
        seq = assigns(view).approval_responses[id]
        assert is_integer(seq)

        # Even a forged repeat event cannot submit a busy request twice.
        render_click(view, "approval_response", %{"request_id" => id, "decision" => decision})
        assert assigns(view).approval_responses[id] == seq
        refute_receive {:approval_response_called, _, _, _, _}, 50

        send(worker, {:respond, :ok})
        wait_until(fn -> assigns(view)[:pending_approvals] == [] end)
        html = render(view)
        assert assigns(view).approval_responses == %{}
        assert assigns(view).approval_error == nil
        refute present?(html, approval_button(id, decision))
      end
    end

    test "invalid decision never reaches the responder and keeps the card", %{conn: conn} do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn node, id, decision ->
        send(test_pid, {:approval_response_called, node, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l2_request()})
      render(view)

      render_click(view, "approval_response", %{"request_id" => "req-1", "decision" => "maybe"})
      refute_received {:approval_response_called, _, _, _}
      assert length(assigns(view)[:pending_approvals]) == 1
    end

    test "responder failure retains a visible card and error, then permits retry", %{conn: conn} do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l2_request()})
      render(view)
      view |> element(approval_button("req-1", "approve")) |> render_click()
      assert_receive {:approval_response_called, worker, source, "req-1", "approve"}, 2000
      assert source == node()
      assert [%{request_id: "req-1"}] = assigns(view).pending_approvals

      # Exercise the REAL SafeCall envelope, not an obsolete synthetic
      # :approval_response_result tag: {:ok, {:error, :nodedown}}.
      send(worker, {:respond, {:error, :nodedown}})
      wait_until(fn -> assigns(view).approval_error == {:response, "req-1", :nodedown} end)
      html = render(view)
      assert html =~ "nodedown"
      assert html =~ "The assistant wants your attention"
      assert [%{request_id: "req-1"}] = assigns(view).pending_approvals
      assert assigns(view).approval_responses == %{}
      refute disabled?(html, approval_button("req-1", "approve"))
      refute disabled?(html, approval_button("req-1", "deny"))

      view |> element(approval_button("req-1", "deny")) |> render_click()
      assert_receive {:approval_response_called, retry_worker, ^source, "req-1", "deny"}, 2000
      assert assigns(view).approval_error == nil
      send(retry_worker, {:respond, :ok})
      wait_until(fn -> assigns(view).pending_approvals == [] end)
      html = render(view)
      assert assigns(view).approval_error == nil
      refute html =~ "nodedown"
      refute html =~ "The assistant wants your attention"
    end

    test "nonpending and no-longer-owned responses cannot invoke the responder", %{conn: conn} do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
        send(test_pid, {:unexpected_approval_response, source, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      render_click(view, "approval_response", %{
        "request_id" => "missing",
        "decision" => "approve"
      })

      assert assigns(view).approval_responses == %{}

      send(view.pid, {:approval_requested, l2_request()})
      render(view)
      send(view.pid, {:approval_resolved, "req-1", :deny})
      render(view)
      render_click(view, "approval_response", %{"request_id" => "req-1", "decision" => "approve"})
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_responses == %{}

      # Defend against a late click even if an old card survives a scope change.
      send(view.pid, {:approval_requested, l2_request(request_id: "old-scope")})
      render(view)
      seed_chat_state(view, %{chat_task_id: "t2", chat_agent_id: 1002})

      render_click(view, "approval_response", %{
        "request_id" => "old-scope",
        "decision" => "deny"
      })

      assert assigns(view).approval_responses == %{}
      refute_receive {:unexpected_approval_response, _, _, _}, 50
    end

    test "evaluator write and sudo cards show the exact code, target and distinct authority", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})
      request = eval_request()
      send(view.pid, {:approval_requested, request})
      html = render(view)

      assert html =~ "Allow this Elixir code once?"
      assert html =~ "not permission for future evaluations"
      assert html =~ "Target runtime: target@runtime"
      assert html =~ "Allow once"
      assert html =~ "border-info/30"

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               request.code

      refute html =~ "Danger — unrestricted Elixir execution"
      refute html =~ "Level 2"
      # The literal '<exact>' is escaped, never treated as markup.
      refute present?(html, "pre exact")

      # Same id: replace write with sudo rather than displaying both grants.
      sudo = eval_request(tier: :sudo, warning: "Custom warning: <no rollback>")
      send(view.pid, {:approval_requested, sudo})
      html = render(view)
      assert html =~ "Danger — unrestricted Elixir execution"
      assert html =~ "unrestricted ordinary Elixir"
      assert html =~ "There is no rollback."
      assert html =~ "This is not OS root access."
      assert html =~ "Allow unrestricted execution once"
      assert html =~ "border-error/40"

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               sudo.code

      assert html |> Floki.parse_document!() |> Floki.text() =~ sudo.warning
      refute html =~ "Allow this Elixir code once?"
      refute present?(html, "p no")
      assert length(assigns(view).pending_approvals) == 1
    end

    test "evaluator ownership and resolutions use the source node, never the target runtime", %{
      conn: conn
    } do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      # Neither a matching target nor a matching task can authenticate another
      # source node; evaluator requests without a source stamp are rejected too.
      for request <- [
            eval_request(node: :foreign@source, target_node: node()),
            eval_request(node: nil),
            eval_request(task_id: "other-task", agent_id: nil)
          ] do
        send(view.pid, {:approval_requested, request})
      end

      render(view)
      assert assigns(view).pending_approvals == []

      # String/integer agent refs match even without the task ref. The target
      # is deliberately remote; the response must still go to LOCAL source.
      request = eval_request(task_id: nil, agent_id: "1001")
      send(view.pid, {:approval_requested, request})
      html = render(view)
      assert html =~ "Target runtime: target@runtime"
      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals

      send(view.pid, {:approval_resolved, "eval-1", :approve, :foreign@source})
      render(view)
      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals

      view |> element(approval_button("eval-1", "approve")) |> render_click()
      assert_receive {:approval_response_called, worker, source, "eval-1", "approve"}, 2000
      assert source == node()
      refute source == request.target_node

      send(view.pid, {:approval_resolved, "eval-1", :approve, node()})
      html = render(view)
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_responses == %{}
      refute present?(html, approval_button("eval-1", "approve"))

      # A late error from the now-resolved response cannot resurrect its card
      # or show an error. Monitor the worker before draining the page mailbox.
      monitor = Process.monitor(worker)
      send(worker, {:respond, {:error, :nodedown}})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
      render(view)
      assert assigns(view).approval_error == nil
      assert assigns(view).pending_approvals == []
    end

    test "new chat clears the workflow and rejects an old asynchronous response", %{conn: conn} do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/help")
      old_chat = assigns(view).chat_id
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})
      send(view.pid, {:approval_requested, eval_request()})
      render(view)
      view |> element(approval_button("eval-1", "approve")) |> render_click()
      assert_receive {:approval_response_called, worker, _, "eval-1", "approve"}, 2000
      assert map_size(assigns(view).approval_responses) == 1

      # A completed conversation permits New chat. Drive the REAL reset event
      # (not a forged workflow result) before releasing the old responder.
      seed_chat_state(view, %{chat_status: :idle})
      render_click(view, "new_chat", %{})
      assert assigns(view).chat_id != old_chat
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_responses == %{}
      assert assigns(view).approval_error == nil

      monitor = Process.monitor(worker)
      send(worker, {:respond, {:error, :old_scope_failure}})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
      html = render(view)
      assert assigns(view).approval_error == nil
      assert assigns(view).pending_approvals == []
      refute html =~ "old_scope_failure"
      refute present?(html, approval_button("eval-1", "approve"))
    end

    test "restored chats recover a real list-returning pending snapshot off-process", %{
      conn: conn
    } do
      chat_id = seed_restorable_approval_chat()
      test_pid = self()
      owned = eval_request()

      Application.put_env(:evo_dash, :approval_pending_runner, fn source ->
        send(test_pid, {:approval_snapshot_called, self(), source})

        # Return the backend API's LIST, not {:ok, list}: SafeCall supplies
        # the outer {:ok, list} consumed by ApprovalWorkflow.recovered/3.
        [
          owned,
          l2_request(request_id: "legacy-agent", task_id: nil, agent_id: "1001"),
          eval_request(request_id: "other-task", task_id: "t2"),
          eval_request(request_id: "wrong-source", node: :foreign@source, target_node: node()),
          eval_request(request_id: "unstamped", node: nil)
        ]
      end)

      {:ok, view, _html} = live(conn, "/help")
      assert_receive {:approval_snapshot_called, worker, source}, 2000
      refute worker == view.pid
      assert source == node()
      assert assigns(view).chat_id == chat_id
      wait_until(fn -> length(assigns(view).pending_approvals) == 2 end)
      html = render(view)
      assert assigns(view).approval_recovering == false
      assert assigns(view).approval_error == nil

      assert Enum.sort(Enum.map(assigns(view).pending_approvals, & &1.request_id)) ==
               ["eval-1", "legacy-agent"]

      assert present?(html, approval_button("eval-1", "approve"))
      assert present?(html, approval_button("legacy-agent", "deny"))
      refute present?(html, approval_button("wrong-source", "approve"))

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               owned.code
    end

    test "an in-flight recovery keeps live requests and cannot resurrect a resolved card", %{
      conn: conn
    } do
      seed_restorable_approval_chat()
      test_pid = self()

      Application.put_env(:evo_dash, :approval_pending_runner, fn source ->
        send(test_pid, {:approval_snapshot_waiting, self(), source})

        receive do
          {:snapshot, requests} -> requests
        after
          5000 -> exit(:approval_test_timeout)
        end
      end)

      {:ok, view, _html} = live(conn, "/help")
      assert_receive {:approval_snapshot_waiting, worker, source}, 2000
      assert source == node()
      assert assigns(view).approval_recovering
      scope = approval_scope(view)
      seq = assigns(view).approval_recovery_seq

      # Wrong generation is ignored by the PAGE's nested-message route too.
      send(view.pid, {{:approval_pending_loaded, seq - 1, scope}, {:ok, [eval_request()]}})
      render(view)
      assert assigns(view).approval_recovering
      assert assigns(view).pending_approvals == []

      send(view.pid, {:approval_requested, eval_request(request_id: "resolved")})
      send(view.pid, {:approval_resolved, "resolved", :deny, node()})
      live_request = eval_request(request_id: "newer", code: "newer exact code")
      send(view.pid, {:approval_requested, live_request})
      render(view)

      send(
        worker,
        {:snapshot,
         [
           eval_request(request_id: "resolved"),
           eval_request(request_id: "newer", code: "old snapshot code"),
           l2_request()
         ]}
      )

      wait_until(fn -> assigns(view).approval_recovering == false end)
      html = render(view)

      assert Enum.sort(Enum.map(assigns(view).pending_approvals, & &1.request_id)) ==
               ["newer", "req-1"]

      assert html =~ "newer exact code"
      refute html =~ "old snapshot code"
      refute present?(html, approval_button("resolved", "approve"))
    end

    test "a recovery result captured for the previous chat scope is discarded", %{conn: conn} do
      seed_restorable_approval_chat()
      test_pid = self()

      Application.put_env(:evo_dash, :approval_pending_runner, fn _source ->
        send(test_pid, {:approval_snapshot_waiting, self()})

        receive do
          :release_snapshot -> [eval_request()]
        after
          5000 -> exit(:approval_test_timeout)
        end
      end)

      {:ok, view, _html} = live(conn, "/help")
      assert_receive {:approval_snapshot_waiting, worker}, 2000
      old_scope = approval_scope(view)
      seq = assigns(view).approval_recovery_seq
      assert is_integer(seq)

      # Model a scope moving before its old asynchronous result can land.
      # Use the SAME task refs to ensure the full chat scope, not only the
      # own-request predicate, is checked by the page's forwarding handler.
      seed_chat_state(view, %{chat_id: "different-chat"})
      send(view.pid, {{:approval_pending_loaded, seq, old_scope}, {:ok, [eval_request()]}})
      render(view)
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_recovering == false
      assert assigns(view).approval_recovery_seq == nil
      assert assigns(view).approval_error == nil

      # The real, late SafeCall reply is equally stale after that rejection.
      monitor = Process.monitor(worker)
      send(worker, :release_snapshot)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
      html = render(view)
      assert assigns(view).pending_approvals == []
      refute present?(html, approval_button("eval-1", "approve"))
    end

    test "duplicate approval_requested upserts instead of stacking", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l2_request()})
      send(view.pid, {:approval_requested, l2_request()})
      render(view)

      assert length(assigns(view)[:pending_approvals]) == 1
      assert hd(assigns(view)[:pending_approvals]).request_id == "req-1"
    end
  end

  describe "genesis source gate" do
    # The gate's availability/clone runners are read from the app env AT SPAWN
    # TIME inside EvoDash.TaskSupervisor children, so tests stub them BEFORE
    # live/3 and restore the originals in on_exit (the system_live_test.exs
    # "genesis source card" restore_env_value/2 idiom). The default runners
    # degrade to {:unavailable, :function_missing} while the core
    # EvoGit.SelfReflectiveSource backend is absent, so the gate stays OFF for
    # every test that does not stub it.
    setup do
      keys = [:source_availability_runner, :source_clone_runner]
      originals = Map.new(keys, fn key -> {key, Application.get_env(:evo_dash, key)} end)

      on_exit(fn ->
        Enum.each(originals, fn {key, original} -> restore_env_value(key, original) end)
      end)

      :ok
    end

    test "known-unavailable source shows the gate and blocks the composer", %{conn: conn} do
      Application.put_env(:evo_dash, :source_availability_runner, fn -> false end)

      # An unrelated pre-existing row proves a blocked send persists nothing new.
      fixture_id = insert_task_fixture!(opts: [path: "/tmp/test", objective: "fixture"])

      {:ok, view, _html} = live(conn, "/help")
      html = await_source_available(view, false)

      # Gate container + Download button render (idle → enabled, "Download source").
      assert present?(html, "#genesis-source-gate")
      assert present?(html, "#genesis-source-download")
      assert html =~ "has not been downloaded yet"
      assert html =~ "Download source"
      refute html =~ "Cloning…"
      refute disabled?(html, "#genesis-source-download")
      # Secondary node-aware link to the System page (local node → /system).
      assert present?(html, ~s(#genesis-source-gate a[href="/system"]))

      # The empty state swaps the suggestion chips for the blocked note.
      assert html =~ "Download the Genesis source to start chatting."
      refute html =~ "Show my running tasks"

      # Composer blocked: textarea + Send button disabled.
      assert disabled?(html, ~s(textarea[name="message"]))
      assert disabled?(html, ~s(button[type="submit"]))

      # A submit is a defensive no-op: no optimistic bubble, no :reflect task,
      # error flash pointing at the Download button. (Wrapped in the send
      # helper for uniformity — it starts no task, so the terminal await is
      # immediately satisfied and no async registry log can escape.)
      {html, _log} =
        send_and_await_terminal(fn ->
          render_submit(view, "send_message", %{"message" => "hello genesis"})
        end)

      assert html =~ "Download the Genesis source before sending a message."
      refute html =~ "hello genesis"
      assert assigns(view).chat_task_id == nil
      assert assigns(view).chat_status == :idle
      assert assigns(view).transcript == []

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      assert Enum.filter(tasks, &(&1.type == :reflect)) == []
      assert EvoGit.TaskRegistry.get_task(fixture_id) != nil
    end

    test "available source renders no gate and the send path stays open", %{conn: conn} do
      Application.put_env(:evo_dash, :source_availability_runner, fn -> true end)

      {:ok, view, _html} = live(conn, "/help")
      html = await_source_available(view, true)

      # No gate, chips intact, composer enabled — the gate's open state is the
      # subject; a full real task run is not (the send-path contract is pinned
      # by the canonical send test in "send message").
      refute present?(html, "#genesis-source-gate")
      refute html =~ "Download the Genesis source to start chatting."
      assert html =~ "Show my running tasks"
      refute disabled?(html, ~s(textarea[name="message"]))
      refute disabled?(html, ~s(button[type="submit"]))
      assert assigns(view).source_available == true
    end

    test "a successful download clears the gate (busy → post-clone re-check)", %{conn: conn} do
      Application.put_env(:evo_dash, :source_availability_runner, fn -> false end)

      {:ok, view, _html} = live(conn, "/help")
      html = await_source_available(view, false)
      assert present?(html, "#genesis-source-gate")

      # The post-clone re-check now reports the source as downloaded. The
      # "Cloning…" busy state asserted below is assigned SYNCHRONOUSLY by the
      # `download_source` event handler, and `render_click/1`'s reply carries
      # the render taken immediately after that handler returns (the LiveView
      # process cannot process the clone-result message before then) — so the
      # busy markup is deterministic and the stub needs no artificial delay.
      # The post-clone settle is waited for with the bounded `wait_until/1`
      # poll below.
      Application.put_env(:evo_dash, :source_availability_runner, fn -> true end)

      Application.put_env(:evo_dash, :source_clone_runner, fn -> {:ok, %{}} end)
      html = render_click(view, "download_source")
      assert html =~ "Cloning…"
      assert disabled?(html, "#genesis-source-download")

      # The clone result clears the busy marker and re-runs the availability
      # check → the gate disappears and the composer is usable again.
      wait_until(fn -> assigns(view)[:source_busy] == nil end)
      html = await_source_available(view, true)

      refute present?(html, "#genesis-source-gate")
      refute html =~ "has not been downloaded yet"
      refute disabled?(html, ~s(textarea[name="message"]))
      assert html =~ "Show my running tasks"
    end

    test "a failing download flashes the error and keeps the gate", %{conn: conn} do
      Application.put_env(:evo_dash, :source_availability_runner, fn -> false end)

      Application.put_env(:evo_dash, :source_clone_runner, fn -> {:error, :boom} end)
      {:ok, view, _html} = live(conn, "/help")
      html = await_source_available(view, false)
      assert present?(html, "#genesis-source-gate")

      render_click(view, "download_source")
      wait_until(fn -> assigns(view)[:source_busy] == nil end)

      html = render(view)
      assert html =~ "Failed to download the Genesis source"
      assert html =~ ":boom"
      # Still unavailable → the gate stays.
      assert present?(html, "#genesis-source-gate")
    end
  end

  describe "node-awareness" do
    # The file-level setup already isolates the config dir per test (per-process
    # `:config_dir_fun` override), so saving a dedicated target here never
    # touches the developer's real config. The
    # fake connection manager (defined below the module) makes
    # ?node=test-remote resolve to a connected remote BEAM node. async: false
    # is already set at the module level (see the module header).
    setup do
      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: "test-remote",
          name: "Test Remote"
        })

      start_supervised!(
        {EvoDashWeb.HomeLiveTest.ConnectionManager,
         {"test-remote", %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      :ok
    end

    test "?node= resolves the remote node", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help?node=test-remote")
      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      assert assigns(view).current_node_id == "test-remote"
    end

    test "missing remote model snapshot rejects sends before touching the draft or transcript", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help?node=test-remote")
      wait_until(fn -> not assigns(view).model_select_loading end)
      render_change(view, "chat_input", %{"message" => "hi remote"})
      html = render_submit(view, "send_message", %{"message" => "hi remote"})

      assert html =~ "Choose a valid model before sending a message."
      refute html =~ "Failed to start the task"
      assert assigns(view).model_snapshot == nil
      assert assigns(view).model_select_load_error != nil
      assert assigns(view).chat_draft == "hi remote"
      assert assigns(view).transcript == []
      assert assigns(view).chat_status == :idle
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []
    end

    test "node switch starts a NEW persisted chat and keeps the old one", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help?node=test-remote")
      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      old_id = assigns(view).chat_id
      assert old_id != nil
      # Seed some chat state so the reset is observable.
      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        transcript: [%{id: "1", role: :user, text: "hello", streaming: false}]
      })

      # A LOCAL-node event must be ignored while viewing the remote node.
      send(view.pid, {:task_updated, "x", :failed, node()})
      html = render(view)
      refute html =~ "The task failed."
      # Patching back to "/help" (no ?node=) switches to local → a NEW chat.
      html = render_patch(view, "/help")
      assert assigns(view).current_node == node()
      assert html =~ "Start a conversation"
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      new_id = assigns(view).chat_id
      assert new_id != nil and new_id != old_id
      # The old chat is KEPT in the store (node switch starts a fresh one,
      # the current pointer moves to the new chat).
      assert old_id in EvoDash.ChatHistory.list_chats()
      assert EvoDash.ChatHistory.current_chat_id() == new_id
    end

    test "node switches clear account pins and ignore late snapshots from the old scope", %{
      conn: conn
    } do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      assert assigns(view).model_spec == work_spec("high")
      local_chat_id = assigns(view).chat_id
      local_snapshot = assigns(view).model_snapshot
      local_seq = assigns(view).model_select_seq

      render_patch(view, "/help?node=test-remote")
      wait_until(fn -> not assigns(view).model_select_loading end)
      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      assert assigns(view).chat_id != local_chat_id
      remote_chat_id = assigns(view).chat_id
      assert assigns(view).model_spec == nil
      assert assigns(view).selected_model_id == nil
      assert assigns(view).model_selection_scope == {"test-remote", :"genesis_remote@127.0.0.1"}
      assert assigns(view).model_snapshot == nil
      assert EvoDash.ChatHistory.get_state(local_chat_id).model_spec == work_spec("high")
      assert EvoDash.ChatHistory.get_state(remote_chat_id).model_spec == nil

      send(view.pid, {{:model_select_loaded, local_seq, node()}, {:ok, {:ok, local_snapshot}}})
      assert assigns(view).model_snapshot == nil
      remote_seq = assigns(view).model_select_seq

      html = render_patch(view, "/help")
      assert assigns(view).current_node == node()
      assert assigns(view).chat_id not in [local_chat_id, remote_chat_id]
      # A different node gets its own configured default, NOT the earlier high pin.
      assert assigns(view).model_spec == work_spec()
      assert assigns(view).model_selection_scope == {nil, node()}
      assert present?(html, ~s(#chat-llm-selection-reasoning[value="1"]))

      remote_snapshot = %{local_snapshot | node: :"genesis_remote@127.0.0.1"}

      send(
        view.pid,
        {{:model_select_loaded, remote_seq, remote_snapshot.node}, {:ok, {:ok, remote_snapshot}}}
      )

      assert assigns(view).model_snapshot.node == node()
      assert assigns(view).model_spec == work_spec()
      # Sequence guard also rejects an old response even when the node matches.
      send(view.pid, {{:model_select_loaded, local_seq, node()}, {:ok, {:error, :obsolete}}})
      assert assigns(view).model_select_load_error == nil
    end

    test "source gate never renders on a remote node (local-only)", %{conn: conn} do
      test_pid = self()
      original = Application.get_env(:evo_dash, :source_availability_runner)
      on_exit(fn -> restore_env_value(:source_availability_runner, original) end)

      # A loud runner that would flag any invocation — the local-only gate must
      # NEVER spawn it while viewing a remote node.
      Application.put_env(:evo_dash, :source_availability_runner, fn ->
        send(test_pid, :availability_runner_called)
        false
      end)

      {:ok, view, _html} = live(conn, "/help?node=test-remote")
      html = render(view)

      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      # No check is spawned for a remote node → the runner is never called and
      # source_available stays "unknown".
      #
      # The 50ms window (down from 200ms) is sufficient because the failure mode
      # is impossible BY CONSTRUCTION and, when it could occur, is immediate:
      # `maybe_check_source/1` is the ONLY caller of the spawn helper and gates
      # it on `SourceGate.visible?(current_node)` (node in [nil, node()]), and
      # this test views a remote node — so a regression would call the runner
      # during the CONNECTED MOUNT (handle_params), i.e. before/while `live/3`
      # returns. The runner then sends its flag synchronously on the very next
      # TaskSupervisor scheduler slot, far inside a 50ms budget. The
      # `assert assigns(view).source_available == nil` line below is the
      # durable assertion on the same failure mode (a spawned check with this
      # node would make the gate known-unavailable → false).
      refute_receive :availability_runner_called, 50
      assert assigns(view).source_available == nil

      # The source gate is local-only, but a missing remote model snapshot
      # independently disables sending until a valid node-scoped load succeeds.
      refute present?(html, "#genesis-source-gate")
      refute html =~ "Download the Genesis source to start chatting."
      refute disabled?(html, ~s(textarea[name="message"]))
      assert disabled?(html, ~s(#chat-form button[type="submit"]))
      assert html =~ "Show my running tasks"
    end
  end
end

# A minimal GenServer that stands in for a real connection manager in
# `EvoGit.RemoteConnection.Registry`, so `EvoGit.RemoteConnection.status/1`
# resolves a configured status for a target id without starting any SSH
# machinery (same pattern as `EvoDashWeb.NodeAwareTest.ConnectionManager`).
# The process dies (and its Registry entry is auto-removed) at test end via
# `start_supervised!`.
defmodule EvoDashWeb.HomeLiveTest.ConnectionManager do
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
