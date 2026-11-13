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
# mounts `/assistant`, so no contained subset can escape them:
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
defmodule EvoDashWeb.HomeLiveTest.ScriptedAgent do
  @moduledoc """
  The role a scripted HomeLive fixture session runs AS.

  A real `EvoGit.Agent.Session` needs a module implementing the `EvoGit.Agent`
  behaviour (`system_prompt/0`, `available_tools/0`, `delegation_level/0`). The
  tool list is deliberately EMPTY: every fixture conversation is driven
  end-to-end by the `dispatch_ctx[:exchange_opts]` engine seams, so no real tool
  schema is ever dispatched.

  Defined ABOVE the test module on purpose: `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the scripted role."
  def system_prompt, do: "You are the HomeLive scripted fixture agent."

  @doc "No tools: the scripted model always answers with a scripted reply."
  def available_tools, do: []
end

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

  # The shared host swings 10-30x under load (see test/CONTEXT.md); the 5 s
  # :sys.get_state default and 1-2 s poll budgets exit on a loaded machine.
  @assigns_timeout_ms 30_000
  # A load-tolerant deadline for bounded polls / async-result awaits.
  @async_wait_budget_ms 30_000

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
  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

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
      # :evogit_sched_meta, plus the :evogit_agent_summary read model) are NOT
      # removed by cancel/delete — the agent stays alive/blocked on an LLM slot
      # with no credentials, so without this sweep its ETS rows leak into
      # agents_live_test.exs (which expects an empty agent registry).
      try do
        if :ets.whereis(:evogit_sched_meta) != :undefined do
          for {agent_id, meta} <- :ets.tab2list(:evogit_sched_meta),
              Map.get(meta, :task_id) == task_id do
            :ets.delete(:evogit_sched_meta, agent_id)

            if :ets.whereis(:evogit_agent_summary) != :undefined,
              do: :ets.delete(:evogit_agent_summary, agent_id)
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
  defp wait_until(fun, timeout \\ @async_wait_budget_ms) do
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
  defp await_source_available(view, expected, timeout \\ @async_wait_budget_ms) do
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

  describe "render" do
    test "renders the idle chat page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/assistant")

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
      {:ok, _view, html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")

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

      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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

      assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, "/assistant")
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

  # Seeds a REAL conversation the ONLY way it can still exist: a live
  # `EvoGit.Agent.Session` parked mid-exchange.
  #
  # WHY a session: the `:evogit_agent_summary` row is a READ MODEL with no
  # conversation (`AgentState` declares no `:context`), and
  # `RemoteAPI.get_agent_history/1` answers from the live session
  # (`EvoGit.Agent.Session.history/1`, `[]` once the session is gone). A
  # transcript can therefore no longer be seeded through ETS at all.
  #
  # The conversation is scripted through the `dispatch_ctx[:exchange_opts]`
  # engine seams (`:llm_call` + `:tool_batch`) — the pattern of
  # `apps/evo_git/test/evo_git/agent_scheduler/session_runtime_invariants_test.exs`.
  # Each `steps` entry is ONE turn's assistant reply. A reply carrying a tool
  # call CONTINUES the run, so the state it produced is checkpointed (and
  # readable through `Session.history/1`) while the NEXT turn's LLM call is
  # parked — the script simply has no step left for that turn, and every
  # fixture below ends with such a parked turn. A reply with NO tool call would
  # FINISH the run and stop the session (history → `[]`), which is why the
  # parked turn is load-bearing.
  defp seed_scripted_session!(agent_id, steps, opts \\ []) do
    task_id = Keyword.get(opts, :task_id, "t1")
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_home_live_session_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    context_node = %EvoGit.Core.ContextNode{path: "./", repo: tmp_dir}

    spec = %EvoGit.AgentSpec{
      context_node: context_node,
      phylo_node: nil,
      agent_module: EvoDashWeb.HomeLiveTest.ScriptedAgent,
      objective: "New message: hi",
      opts: [repo_less: true, task_tmpdir: tmp_dir]
    }

    meta = %EvoGit.AgentScheduler.SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: task_id,
      spec: spec,
      status: :running
    }

    :ok =
      EvoGit.AgentScheduler.Store.put_agent_state(agent_id, %EvoGit.AgentScheduler.AgentState{
        context_node: context_node,
        objective: "New message: hi",
        llm_model: "test:model",
        model_id: "home-live-scripted",
        max_turns: 128,
        max_retries: 3,
        max_depth: 8,
        repo_id: "primary",
        repo_root: tmp_dir,
        llm_context_window: 200_000
      })

    :ok = EvoGit.AgentScheduler.Store.put_sched_meta(agent_id, meta)

    # Repo-less: no worktree, no git, no `WorktreeManager` lease. The terminal
    # result (never delivered while the run is parked) targets THIS test rather
    # than the app-global scheduler.
    {:ok, pid} =
      EvoGit.Agent.Session.start_link(
        agent_id: agent_id,
        depth: 0,
        repo_root: tmp_dir,
        repo_id: "primary",
        worktree_path: Path.join(tmp_dir, "worker"),
        retries: 0,
        spec: spec,
        meta: meta,
        repo_less: true,
        repo_less_repo_path: tmp_dir,
        exchange_opts: [
          llm_call: scripted_llm_call(self(), steps),
          tool_batch: scripted_tool_batch()
        ],
        scheduler: self()
      )

    # The session's own stop is never an assertion failure here; the monitor
    # keeps it observable without linking the test process.
    Process.unlink(pid)
    ref = Process.monitor(pid)

    on_exit(fn ->
      # Force-cancel FIRST: that is the only path that also shuts the parked
      # exchange worker down (`Session` kills it via `Task.shutdown/2`).
      _ = EvoGit.Agent.Session.cancel(pid, :force)
      if Process.alive?(pid), do: Process.exit(pid, :kill)

      EvoGit.AgentScheduler.Store.delete_agent_state(agent_id)
      EvoGit.AgentScheduler.Store.delete_sched_meta(agent_id)
      EvoGit.AgentScheduler.Store.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    ref
  end

  # The `:llm_call` seam: plays the next scripted reply, then PARKS (see
  # `seed_scripted_session!/3`). The turn index is the number of assistant
  # messages already in the conversation, so the script needs no state of its
  # own.
  defp scripted_llm_call(test_pid, steps) do
    fn context, _tools, _params, _agent_id, _retries ->
      turn = Enum.count(context.messages, &(&1.role == :assistant))

      case Enum.at(steps, turn) do
        nil ->
          send(test_pid, {:scripted_llm_parked, self()})

          receive do
            :release -> :ok
          after
            # Bounded only so a worker that outlives the test can never park
            # forever; `on_exit` kills the session (and this worker) first.
            @async_wait_budget_ms -> :ok
          end

          {:implicit_completion, scripted_response(context, %{content: []}), "parked"}

        step ->
          {:ok, scripted_response(context, step)}
      end
    end
  end

  # The `:tool_batch` seam: replaces the whole standard-call batch, so no real
  # tool runs (and no tool runtime/slot is touched) while the engine still
  # builds the `%ReqLLM.Message{}` tool messages itself.
  defp scripted_tool_batch do
    fn indexed_calls, _state ->
      Enum.map(indexed_calls, fn {call, index} ->
        {index, call.id, ReqLLM.ToolCall.name(call), "result..."}
      end)
    end
  end

  # One scripted assistant reply. The response carries the SAME message on top
  # of the conversation — exactly how the engine advances `state.context`.
  defp scripted_response(context, step) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: Map.get(step, :content, []),
      tool_calls: Map.get(step, :tool_calls),
      reasoning_details: Map.get(step, :reasoning_details)
    }

    %ReqLLM.Response{
      id: "home-live-scripted-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  defp scripted_tool_call(id, name \\ "spawn_investigator") do
    %ReqLLM.ToolCall{
      id: id,
      type: "function",
      function: %{name: name, arguments: "{}"}
    }
  end

  describe "streaming display" do
    test "assistant text from the history fetch appears in the bubble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)
      stream_seq = assigns(view)[:stream_attach_seq]

      # Every independent read carries BOTH generations plus agent identity.
      # Neither the old unscoped route nor stale/wrong-scope replies may write.
      for message <- [
            {:chat_history_loaded, node(), seq, 1001,
             [%{role: :assistant, content: "unscoped reply"}]},
            {:chat_history_loaded, node(), seq - 1, 1001, stream_seq,
             [%{role: :assistant, content: "stale history reply"}]},
            {:chat_history_loaded, node(), seq, 1002, stream_seq,
             [%{role: :assistant, content: "wrong agent reply"}]},
            {:chat_history_loaded, node(), seq, 1001, stream_seq + 1,
             [%{role: :assistant, content: "obsolete watch reply"}]}
          ] do
        send(view.pid, message)
      end

      ignored = render(view)
      refute ignored =~ "unscoped reply"
      refute ignored =~ "stale history reply"
      refute ignored =~ "wrong agent reply"
      refute ignored =~ "obsolete watch reply"
      assert assigns(view).agent_message_count == nil

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001, stream_seq,
         [%{role: :assistant, content: [%{text: "Genesis responds"}]}]}
      )

      html = render(view)
      assert html =~ "Genesis responds"
      assert assigns(view).agent_message_count == 1
      assert assigns(view).chat_status == :running
    end

    test "agent_registered sets the chat agent and triggers the history fetch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")

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
        {:chat_history_loaded, node(), seq, 1001, assigns(view)[:stream_attach_seq],
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

      # A real session parked after ONE tool-calling turn, so its checkpointed
      # transcript is [system, user, assistant("kwlist response"), tool result]
      # — 4 messages, the real shape a mid-run Assistant agent exposes.
      seed_scripted_session!(agent_id, [
        %{
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "kwlist response"}],
          tool_calls: [scripted_tool_call("kwlist-1")]
        }
      ])

      {:ok, view, _html} = live(conn, "/assistant")

      seed_chat_state(view, %{
        chat_status: :running,
        chat_task_id: "t1",
        chat_agent_id: agent_id,
        transcript: [
          %{id: "1", role: :user, text: "hello", streaming: false},
          %{id: "2", role: :assistant, text: "", streaming: true}
        ]
      })

      # Read the CURRENT seq AFTER the seeded state SETTLES (a synchronous
      # `assigns/1` round-trip drains every message already delivered to the
      # view). Reading it before the seed made this test order-dependent: the
      # connected mount reconciles a RESTORED running chat (`reconcile_chat/1`
      # → `async_fetch_history/2`) and a live session seeded by
      # `seed_scripted_session!/3` can also publish an out-of-band
      # `:agent_updated` with a `:message_count`, so an extra refetch landing
      # between the read and the assertion bumped the counter by two
      # (`seq + 2`) in some full-suite orders while the REAL contract under
      # test — the keyword-list changed_fields triggers a refetch — held.
      seq = assigns(view)[:chat_fetch_seq]

      # Real keyword-list changed_fields: the guard (is_list +
      # Keyword.has_key?) matches → a REAL refetch is spawned (seq bumped).
      send(view.pid, {:agent_updated, agent_id, [message_count: 2], node()})

      # The refetch is ASYNCHRONOUS, so await its RESULT (the exact production
      # data path, no injected result) instead of assuming one spawn, and pin
      # that the injected event did advance the counter.
      wait_until(fn -> assigns(view)[:agent_message_count] == 4 end)
      assert assigns(view)[:chat_fetch_seq] >= seq + 1

      # The real refetch lands against the LIVE session's transcript → the
      # streamed text appears.
      html = render(view)
      assert html =~ "kwlist response"
    end

    test "kwlist changed_fields WITHOUT :message_count does not refetch (HistoryGate)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      # A legacy atom list is NOT a keyword list → Keyword.has_key? rejects it
      # (pin: only [message_count: n] triggers a refetch).
      send(view.pid, {:agent_updated, 1001, [:message_count], node()})
      render(view)

      assert assigns(view)[:chat_fetch_seq] == seq
    end

    test "real-shaped core event sequence does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")

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
        {:chat_history_loaded, node(), assigns(view)[:chat_fetch_seq], 1,
         assigns(view)[:stream_attach_seq], real_history()}
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

    test "real live session flows through the real get_agent_history path", %{conn: conn} do
      agent_id = 300_000 + rem(System.unique_integer([:positive]), 50_000)

      # A real parked session whose first (tool-calling) turn already produced
      # the thinking part, the tool call and the assistant text, so the fetch
      # returns [system, user, assistant(thinking + tool_call), tool result].
      seed_scripted_session!(agent_id, [
        %{
          content: [
            %ReqLLM.Message.ContentPart{type: :thinking, text: "let me inspect the source"},
            %ReqLLM.Message.ContentPart{type: :text, text: "Genesis is an Elixir framework."}
          ],
          tool_calls: [scripted_tool_call("call_1")],
          reasoning_details: [%ReqLLM.Message.ReasoningDetails{text: "think", index: 0}]
        }
      ])

      {:ok, view, _html} = live(conn, "/assistant")

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
      # .get_agent_history → Agent.Session.history/1) returns the native
      # %ReqLLM.Message{} structs the SESSION owns — thinking parts,
      # reasoning details, tool calls and the tool result included.
      wait_until(fn -> assigns(view)[:agent_message_count] == 4 end)

      html = render(view)
      assert html =~ "Genesis is an Elixir framework."
      assert html =~ "Thought process"
      assert html =~ "spawn_investigator"
    end

    test "foreign-node events are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_history_loaded, :other@host, seq, 1001, assigns(view)[:stream_attach_seq],
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
      {:ok, view, _html} = live(conn, "/assistant")
      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      # The history fetch replaces the in-progress bubble text (streaming stays
      # true) — a mid-stream render must show the literal source + caret, never
      # a markdown render (half-rendered streams would flicker).
      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001, assigns(view)[:stream_attach_seq],
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)
      send(view.pid, {:chat_task_loaded, node(), seq, "t1", %{status: :cancelled, result: nil}})
      html = render(view)
      assert html =~ "Stopped."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "deleted task renders the conversation-deleted marker", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)
      send(view.pid, {:chat_task_loaded, node(), seq, "t1", nil})
      html = render(view)
      assert html =~ "The conversation was deleted."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "failed task event finalizes the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
        {:ok, view, _html} = live(conn, "/assistant")
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
        {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
      seed_running_chat(view)
      send(view.pid, {:task_deleted, "t1", node()})
      html = render(view)
      assert html =~ "The conversation was deleted."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "final badge persists on the card after completion", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
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
      # Pins the reflect-task rendering path on /assistant: a repo-less :reflect row
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

      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
        {:chat_history_loaded, node(), seq, 1001, assigns(view)[:stream_attach_seq],
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
      {:ok, view, _html} = live(conn, "/assistant")
      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, 1001, assigns(view)[:stream_attach_seq],
         real_history()}
      )

      html = render(view)
      # The disclosure belongs to this answer: assistant/tool reasoning only,
      # not the system prompt or user turns from the raw context.
      assert html =~ "Thought process"
      assert html =~ "(3)"

      thoughts =
        html |> Floki.parse_document!() |> Floki.find("#chat-messages details") |> Floki.text()

      refute thoughts =~ "you are genesis"
      refute thoughts =~ "New message: hi"
      # The complete five-row context is still retained in the debug projection.
      assert length(assigns(view).thought_process) == 5
      assert inspect(assigns(view).thought_process) =~ "you are genesis"
      assert inspect(assigns(view).thought_process) =~ "New message: hi"
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
      {:ok, view, _html} = live(conn, "/assistant")
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
        {:chat_history_loaded, node(), seq, 1001, assigns(view)[:stream_attach_seq],
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view2, html} = live(conn, "/assistant")
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

      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view2, _html} = live(conn, "/assistant")
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

      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view2, _html} = live(conn, "/assistant")
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

      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view2, _html} = live(conn, "/assistant")
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

    # Fused-capsule picker: the selected provider profile is the drill-down
    # provider-list item carrying BOTH `aria-selected="true"` and
    # `.capsule-item-active`; its id is `phx-value-provider_profile_id`.
    defp selected_provider(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find(
        "#chat-llm-selection-provider-list .capsule-item-active[aria-selected=\"true\"]"
      )
      |> Floki.attribute("phx-value-provider_profile_id")
    end

    # The drill row's right-aligned value mirrors the current profile's display
    # label (blank -> Auto/choose text, unknown -> "Unavailable profile: …").
    defp provider_drill_label(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#chat-llm-selection-provider .capsule-drill-value")
      |> Floki.text()
      |> String.trim()
    end

    # Fused-capsule picker: the selected model is the listbox button with
    # `aria-selected="true"`, and its value is `phx-value-model`.
    defp selected_model(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#chat-llm-selection-model .capsule-item[aria-selected=\"true\"]")
      |> Floki.attribute("phx-value-model")
      |> List.first()
    end

    # Fused-capsule picker: the active reasoning stop is the button with
    # `aria-pressed="true"`; its zero-based effort index is
    # `phx-value-reasoning_effort` and its human label is the button text.
    defp selected_reasoning_index(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#chat-llm-selection-reasoning button[aria-pressed=\"true\"]")
      |> Floki.attribute("phx-value-reasoning_effort")
      |> List.first()
    end

    defp selected_reasoning_label(html) do
      html
      |> Floki.parse_document!()
      |> Floki.find("#chat-llm-selection-reasoning button[aria-pressed=\"true\"]")
      |> Floki.text()
      |> String.trim()
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

    test "composer projects canonical provider, model and reasoning defaults without credentials",
         %{
           conn: conn
         } do
      write_provider_profile_config()
      {:ok, view, html} = live(conn, "/assistant")

      # The capsule root: the shared client hook owns the active panel view, and
      # the model view is the initial one.
      assert present?(html, ~s(#chat-llm-selection[phx-hook="CapsulePanel"]))
      assert present?(html, ~s(#chat-llm-selection[data-capsule-view="model"]))

      # ONE panel with two sibling views (model, then the provider drill-down);
      # the drill row opens the provider list and the back row returns.
      assert present?(html, ~s(#chat-llm-selection .capsule-view[data-view="model"]))
      assert present?(html, ~s(#chat-llm-selection .capsule-view[data-view="provider"]))
      assert present?(html, ~s(#chat-llm-selection-provider[data-capsule-drill="provider"]))
      assert present?(html, ~s(#chat-llm-selection-provider-list[role="listbox"]))
      assert present?(html, ~s(#chat-llm-selection .capsule-back[data-capsule-back]))

      # There is no provider `<select>` and no `phx-change` in the picker: its
      # rows carry their own click events.
      refute present?(html, ~s(#chat-llm-selection select))
      refute present?(html, ~s(#chat-llm-selection [phx-change]))
      refute present?(html, ~s(#chat-llm-selection [name="provider_profile_id"]))

      assert present?(
               html,
               ~s(#chat-llm-selection-model[role="listbox"][aria-label="Model"])
             )

      assert present?(
               html,
               ~s(#chat-llm-selection-reasoning[role="group"][aria-label="Reasoning effort"])
             )

      assert present?(
               html,
               ~s(#chat-llm-selection-reasoning button[aria-pressed="true"][phx-value-reasoning_effort="1"])
             )

      refute present?(html, ~s(select[name="model_id"]))
      # The picker moved from the header into the composer card's control bar
      # (still inside the ONE `#chat-form`).
      assert present?(html, "#chat-form #chat-composer-controls #chat-llm-selection")
      refute present?(html, "#chat-header #chat-llm-selection")
      refute present?(html, "form#chat-llm-selection-form")
      dom = Floki.parse_document!(html)

      assert dom
             |> Floki.find("#chat-llm-selection-provider-list [role=\"option\"]")
             |> Floki.attribute("phx-value-provider_profile_id") ==
               ["", "first-account", "work-account"]

      assert dom
             |> Floki.find("#chat-llm-selection-model .capsule-item")
             |> Floki.attribute("phx-value-model") == ["", "fast-model", "reasoned-model"]

      assert selected_provider(html) == ["work-account"]
      assert provider_drill_label(html) == "Work"
      assert selected_model(html) == "reasoned-model"
      assert selected_reasoning_label(html) == "Medium"
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
      {:ok, view, html} = live(conn, "/assistant")

      assert assigns(view).provider_profiles == []
      assert present?(html, ~s(#chat-llm-selection-provider[disabled]))
      assert provider_drill_label(html) == "Choose a provider profile"

      assert present?(
               html,
               ~s(#chat-llm-selection-model .capsule-item[disabled][phx-value-model=""])
             )

      assert html =~ "No provider profiles configured. Add one in Settings to choose a model."
      refute present?(html, "#chat-llm-selection-reasoning")
    end

    test "typed submit locks a canonical model_spec and the resolved slider effort", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
      assert assigns(view).model_spec == work_spec()
      render_change(view, "select_provider_profile", %{"provider_profile_id" => ""})
      assert assigns(view).model_spec == %{}
      chat_id = assigns(view).chat_id
      assert EvoDash.ChatHistory.get_state(chat_id).model_spec == %{}

      GenServer.stop(view.pid)
      {:ok, view, html} = live(conn, "/assistant")
      assert assigns(view).chat_id == chat_id
      assert assigns(view).model_spec == %{}
      assert selected_provider(html) == [""]
      assert provider_drill_label(html) == "Choose a provider profile"
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
      {:ok, view, _html} = live(conn, "/assistant")
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

    test "composer picker events never reach the composer's chat_input handler", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, html} = live(conn, "/assistant")

      # Placement: the capsule is a control in the composer card, not the
      # header; it renders inside the ONE `#chat-form` but owns its own
      # `phx-click` bindings, so no form submission is involved.
      assert present?(html, "#chat-form #chat-composer-controls #chat-llm-selection")
      refute present?(html, "#chat-header #chat-llm-selection")

      # Typing still drives the draft through the form-level `chat_input`.
      render_change(view, "chat_input", %{"message" => "draft text"})
      assert assigns(view).chat_draft == "draft text"

      # Capsule selections carry ONLY their own `phx-value-*` payload (the
      # picker's items are plain buttons with their own click events, never a
      # form field) and mutate the selection only: the draft and transcript are
      # untouched, i.e. the composer's `chat_input` never fired.
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      assert assigns(view).model_spec == work_spec("high")
      assert assigns(view).chat_draft == "draft text"
      assert assigns(view).transcript == []

      html =
        render_change(view, "select_provider_profile", %{"provider_profile_id" => "first-account"})

      assert assigns(view).model_spec == %{
               "provider_profile_id" => "first-account",
               "model" => "fast-model"
             }

      assert assigns(view).chat_draft == "draft text"
      assert assigns(view).transcript == []
      assert present?(html, "#chat-form textarea[name=\"message\"]")

      # The reverse direction still works after the move: a textarea change
      # keeps updating the draft.
      render_change(view, "chat_input", %{"message" => "draft text v2"})
      assert assigns(view).chat_draft == "draft text v2"

      assert assigns(view).model_spec == %{
               "provider_profile_id" => "first-account",
               "model" => "fast-model"
             }
    end

    test "the composer form still submits end-to-end with the picker in its control bar", %{
      conn: conn
    } do
      write_provider_profile_config()
      {:ok, view, html} = live(conn, "/assistant")

      # The submit control lives in the same control bar row as the capsule.
      assert present?(html, "#chat-composer-controls button[type=\"submit\"]")
      assert present?(html, "#chat-composer-controls #chat-llm-selection")
      assert disabled?(html, ~s(#chat-form button[type="submit"])) == false

      render_change(view, "chat_input", %{"message" => "sent from the composer"})

      # A REAL form submit: the test client resolves `phx-submit` from the
      # `#chat-form` DOM node and collects the form's own input values.
      {html, _log} =
        send_and_await_terminal(fn ->
          view |> form("#chat-form", %{message: "sent from the composer"}) |> render_submit()
        end)

      assert html =~ "sent from the composer"
      task = only_reflect_task()
      assert_task_selection(task, work_spec())
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "sent from the composer"
      cleanup_task_on_exit(task.id)
    end

    test "legacy ChatHistory id migrates on mount to a canonical same-node selection", %{
      conn: conn
    } do
      write_provider_profile_config()
      chat_id = EvoDash.ChatHistory.new_chat()
      EvoDash.ChatHistory.put_state(chat_id, %{selected_model_id: "first-account"})

      {:ok, view, html} = live(conn, "/assistant")
      expected = %{"provider_profile_id" => "first-account", "model" => "fast-model"}
      assert assigns(view).chat_id == chat_id
      assert assigns(view).model_spec == expected
      assert assigns(view).selected_model_id == nil
      assert assigns(view).model_selection_scope == {nil, node()}
      assert selected_provider(html) == ["first-account"]
      assert provider_drill_label(html) == "Personal"
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

      {:ok, view, html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, html} = live(conn, "/assistant")
      assert assigns(view).chat_id == chat_id
      assert assigns(view).model_spec == work_spec("high")
      assert assigns(view).model_selection_scope == {nil, node()}
      assert selected_provider(html) == ["work-account"]
      assert provider_drill_label(html) == "Work"
      assert selected_reasoning_index(html) == "2"
      assert selected_reasoning_label(html) == "High"
    end

    test "suggestion-chip send locks the same canonical selection as typed submit", %{conn: conn} do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
    test "real reflect task + real live session + real broadcasts end-to-end", %{conn: conn} do
      # A REAL agent id in the scheduler's id space (integer, like production).
      agent_id = 400_000 + rem(System.unique_integer([:positive]), 50_000)
      # REAL scheduler rows (SchedMeta + the summary read model) plus a REAL
      # live session whose scripted conversation includes thinking parts,
      # tool_calls, reasoning_details AND an assistant reply with content: []
      # (the empty-list hardening case). The session is parked after its SECOND
      # tool-calling turn, so the transcript it exposes is
      # [system, user, assistant, tool, assistant(content: []), tool].
      seed_scripted_session!(
        agent_id,
        [
          %{
            content: [
              %ReqLLM.Message.ContentPart{type: :thinking, text: "let me inspect the source"},
              %ReqLLM.Message.ContentPart{type: :text, text: "Genesis is an Elixir framework."}
            ],
            tool_calls: [scripted_tool_call("call_1")],
            reasoning_details: [%ReqLLM.Message.ReasoningDetails{text: "think", index: 0}]
          },
          %{
            content: [],
            tool_calls: [scripted_tool_call("call_2")]
          }
        ],
        task_id: "t_crash"
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

      {:ok, view, _html} = live(conn, "/assistant")

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
      # The real history fetch lands: 6 messages from the live session: thinking
      # parts, tool_calls, reasoning_details and the empty-content assistant
      # reply included.
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
      {:ok, _view, html} = live(conn, "/assistant")

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

      {:ok, view, _html} = live(conn, "/assistant")
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

      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")

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
      {:ok, view, _html} = live(conn, "/assistant")
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

  # A repo-less interactive `/assistant` session owns NO `tasks` row: the
  # scheduler MINTS its task id (`SchedMeta.task_id` via
  # `AgentScheduler.task_id_for_agent/1`) and the session agent id is the only
  # identity the dashboard always has. Approval gates must key on those alone,
  # so this fixture deliberately references a task nothing ever inserted.
  @task_less_task_id "4f2a9c7e1b3d5a60"

  defp task_less_eval_request(overrides \\ %{}) do
    eval_request(Map.merge(%{task_id: @task_less_task_id, agent_id: "1001"}, Map.new(overrides)))
  end

  defp approval_button(id, decision) do
    ~s(button[phx-click="approval_response"][phx-value-request_id="#{id}"][phx-value-decision="#{decision}"])
  end

  # The approval strip's numeric pending count ("" when nothing is pending) and
  # the review dialog's "N of M" position badge ("" while only one request is
  # pending). Both read the RENDERED markup, so they pin what the user sees.
  defp approval_strip_count(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(#approval-status-bar .badge))
    |> Floki.text()
    |> String.trim()
  end

  defp approval_position(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s(#approval-dialog .badge-ghost))
    |> Floki.text()
    |> String.trim()
  end

  defp dialog_open?(html), do: present?(html, "#approval-dialog")

  # Sends a raw page message and returns the HTML rendered AFTER the page has
  # applied it. `assigns/1` is a direct `:sys.get_state/2` round-trip from THIS
  # process, so per-sender ordering guarantees the `send/2` above is processed
  # before the render; a bare `render/1` goes through the LiveViewTest proxy and
  # could race the very message it is meant to observe.
  defp send_and_render(view, message) do
    send(view.pid, message)
    assigns(view)
    render(view)
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

    # A new live request shows the reserved-height strip AND asks in place: the
    # dialog opens on its own, carrying ONE request (so no "N of M" badge).
    test "a new live request shows the strip and opens the dialog on its own", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      # Nothing pending: the strip keeps its reserved height but renders no
      # count/Review, and no dialog is mounted.
      html = render(view)
      assert present?(html, "#approval-status-bar")
      assert approval_strip_count(html) == ""
      refute dialog_open?(html)

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert approval_strip_count(html) == "1"
      assert html =~ "Genesis is waiting for your approval"
      assert dialog_open?(html)
      assert present?(html, approval_button("req-1", "approve"))
      assert approval_position(html) == ""
    end

    test "level-2 request shows the pending count and its dialog carries both decisions", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l2_request()})

      # Informational wording + info styling (title/summary/body/badge/icon).
      assert approval_strip_count(html) == "1"
      assert present?(html, ~s(#approval-status-bar button[phx-click="open_approval_dialog"]))
      assert dialog_open?(html)
      assert html =~ "The assistant wants your attention"
      assert html =~ "Confirm an action before the assistant continues."
      assert html =~ "It is asking you to confirm an action before it continues."
      assert html =~ "hero-information-circle"
      assert html =~ "bg-info/10"
      assert html =~ "btn btn-primary btn-sm"
      # The command shows in a <code> block; args as plain escaped text below it.
      assert html =~ "NavigateToPage.navigate"
      assert html =~ "guide the user to the Settings page"
      # ONE request at a time: no position badge, no stepping controls.
      assert approval_position(html) == ""
      refute present?(html, ~s(button[phx-click="prev_approval"]))
      refute present?(html, ~s(button[phx-click="next_approval"]))

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

    test "level-3 request opens a danger-styled dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l3_request()})

      # Danger wording + error styling (title/summary/command/danger frame).
      assert approval_strip_count(html) == "1"
      assert dialog_open?(html)
      assert html =~ "Action required — real side effects"
      assert html =~ "Perform a destructive task action."
      assert html =~ "StartTask.start_task"
      assert html =~ "hero-exclamation-triangle"
      assert html =~ "btn btn-error btn-sm"
      assert html =~ "bg-error/10"
      refute html =~ "The assistant wants your attention"
      refute html =~ "bg-info/10"
    end

    test "requests for other tasks, agents, and nodes are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      # Other task id (agent_id nil → no agent match either).
      html = send_and_render(view, {:approval_requested, l2_request(task_id: "other-task")})
      assert assigns(view)[:pending_approvals] == []
      assert approval_strip_count(html) == ""
      refute dialog_open?(html)

      # Same shape but a foreign agent: string "someone-else" vs the integer
      # 1001 → the to_string/1 comparison never matches.
      html =
        send_and_render(
          view,
          {:approval_requested, l2_request(task_id: nil, agent_id: "someone-else")}
        )

      assert assigns(view)[:pending_approvals] == []
      assert approval_strip_count(html) == ""

      # Matching task but a foreign node.
      html = send_and_render(view, {:approval_requested, l2_request(node: :foreign@node)})
      assert assigns(view)[:pending_approvals] == []
      assert approval_strip_count(html) == ""
      assert assigns(view)[:approval_dialog_open] == false
      refute dialog_open?(html)
      refute html =~ "Genesis is waiting for your approval"
      refute html =~ "The assistant wants your attention"
      refute html =~ "Action required — real side effects"
    end

    test "approval_resolved closes the dialog (unknown ids are no-ops)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert length(assigns(view)[:pending_approvals]) == 1
      assert dialog_open?(html)

      # Unknown id: harmless no-op — the request (and its dialog) stay.
      html = send_and_render(view, {:approval_resolved, "unknown-id", :approve})
      assert length(assigns(view)[:pending_approvals]) == 1
      assert approval_strip_count(html) == "1"
      assert dialog_open?(html)
      assert present?(html, approval_button("req-1", "approve"))

      html = send_and_render(view, {:approval_resolved, "req-1", :approve})
      assert assigns(view)[:pending_approvals] == []
      assert assigns(view)[:approval_dialog_open] == false
      assert approval_strip_count(html) == ""
      refute dialog_open?(html)
      refute html =~ "Genesis is waiting for your approval"
    end

    test "approve/deny keep the request busy until the asynchronous responder succeeds", %{
      conn: conn
    } do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      for {id, decision} <- [{"req-1", "approve"}, {"req-2", "deny"}] do
        html = send_and_render(view, {:approval_requested, l2_request(request_id: id)})
        assert dialog_open?(html)

        html =
          view
          |> element(approval_button(id, decision))
          |> render_click()

        assert_receive {:approval_response_called, worker, source, ^id, ^decision},
                       @async_wait_budget_ms

        assert source == node()
        refute worker == view.pid
        assert [%{request_id: ^id}] = assigns(view)[:pending_approvals]
        # The dialog stays on that request with BOTH decisions disabled while
        # the response is in flight.
        assert dialog_open?(html)
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
        assert approval_strip_count(html) == ""
        refute dialog_open?(html)
        refute present?(html, approval_button(id, decision))
      end
    end

    test "invalid decision never reaches the responder and keeps the request pending", %{
      conn: conn
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn node, id, decision ->
        send(test_pid, {:approval_response_called, node, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert dialog_open?(html)

      # A forged payload bypassing the dialog's own buttons must still be
      # rejected by ApprovalWorkflow.respond/3's decision whitelist.
      render_click(view, "approval_response", %{"request_id" => "req-1", "decision" => "maybe"})
      refute_received {:approval_response_called, _, _, _}

      assert [%{request_id: "req-1"}] = assigns(view)[:pending_approvals]
      assert assigns(view).approval_responses == %{}
      html = render(view)
      assert dialog_open?(html)
      assert approval_strip_count(html) == "1"
      assert present?(html, approval_button("req-1", "approve"))
    end

    test "a responder failure keeps the dialog and its error until a retry succeeds", %{
      conn: conn
    } do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert dialog_open?(html)
      view |> element(approval_button("req-1", "approve")) |> render_click()

      assert_receive {:approval_response_called, worker, source, "req-1", "approve"},
                     @async_wait_budget_ms

      assert source == node()
      assert [%{request_id: "req-1"}] = assigns(view).pending_approvals

      # Exercise the REAL SafeCall envelope, not an obsolete synthetic
      # :approval_response_result tag: {:ok, {:error, :nodedown}}.
      send(worker, {:respond, {:error, :nodedown}})
      wait_until(fn -> assigns(view).approval_error == {:response, "req-1", :nodedown} end)
      html = render(view)

      # The request stays visible in BOTH surfaces: the strip reports it with
      # its retry guidance and the dialog is still open, neither decision busy.
      assert assigns(view).approval_responses == %{}
      assert [%{request_id: "req-1"}] = assigns(view).pending_approvals
      assert approval_strip_count(html) == "1"
      assert dialog_open?(html)
      assert html =~ "nodedown"
      assert present?(html, "#approval-response-error")
      assert html =~ "the request is still pending; try again"
      assert html =~ "The assistant wants your attention"
      refute disabled?(html, approval_button("req-1", "approve"))
      refute disabled?(html, approval_button("req-1", "deny"))

      view |> element(approval_button("req-1", "deny")) |> render_click()

      assert_receive {:approval_response_called, retry_worker, ^source, "req-1", "deny"},
                     @async_wait_budget_ms

      assert assigns(view).approval_error == nil
      send(retry_worker, {:respond, :ok})
      wait_until(fn -> assigns(view)[:pending_approvals] == [] end)
      html = render(view)
      assert assigns(view).approval_error == nil
      refute html =~ "nodedown"
      assert approval_strip_count(html) == ""
      refute dialog_open?(html)
    end

    test "nonpending and no-longer-owned responses cannot invoke the responder", %{conn: conn} do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
        send(test_pid, {:unexpected_approval_response, source, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      render_click(view, "approval_response", %{
        "request_id" => "missing",
        "decision" => "approve"
      })

      assert assigns(view).approval_responses == %{}

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert dialog_open?(html)
      html = send_and_render(view, {:approval_resolved, "req-1", :deny})
      refute dialog_open?(html)

      render_click(view, "approval_response", %{"request_id" => "req-1", "decision" => "approve"})
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_responses == %{}

      # Defend against a late click even if an old request survives a scope change.
      html = send_and_render(view, {:approval_requested, l2_request(request_id: "old-scope")})
      assert dialog_open?(html)
      assert present?(html, approval_button("old-scope", "deny"))
      seed_chat_state(view, %{chat_task_id: "t2", chat_agent_id: 1002})

      render_click(view, "approval_response", %{
        "request_id" => "old-scope",
        "decision" => "deny"
      })

      assert assigns(view).approval_responses == %{}
      refute_receive {:unexpected_approval_response, _, _, _}, 50
    end

    test "the evaluator dialog shows the exact code and marks the sudo tier as danger", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})
      request = eval_request()
      html = send_and_render(view, {:approval_requested, request})
      assert dialog_open?(html)

      assert html =~ "Allow this Elixir code once?"
      assert html =~ "not permission for future evaluations"
      assert html =~ "Allow once"
      assert html =~ "bg-info/10"
      # The target line names the request's `target_node` (the field the core
      # stamps), never "Unknown target".
      assert html =~ "Target runtime: target@runtime"
      # A write-tier request carries no warning: no request-warning block.
      refute present?(html, "#approval-request-warning")

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               request.code

      refute html =~ "Danger — unrestricted Elixir execution"
      refute html =~ "Level 2"
      # The literal '<exact>' is escaped, never treated as markup.
      refute present?(html, "pre exact")

      # Same id: replace write with sudo rather than displaying both grants.
      sudo = eval_request(tier: :sudo, warning: "Custom warning: <no rollback>")
      html = send_and_render(view, {:approval_requested, sudo})
      assert html =~ "Danger — unrestricted Elixir execution"
      assert html =~ "Unrestricted Elixir — no rollback"
      assert html =~ "unrestricted ordinary Elixir"
      assert html =~ "There is no rollback."
      assert html =~ "This is not OS root access."
      assert html =~ "Allow unrestricted execution once"
      assert html =~ "border-error/40"

      # The dialog renders the tier's own warning block AND the request's own
      # optional `:warning` (the core's sudo text), each exactly once.
      assert present?(html, "#approval-sudo-warning")
      assert present?(html, "#approval-request-warning")

      # The text is escaped, not interpreted as markup.
      warning_text =
        html
        |> Floki.parse_document!()
        |> Floki.find("#approval-request-warning")
        |> Floki.text()

      assert warning_text =~ "Custom warning: <no rollback>"

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               sudo.code

      refute html =~ "Allow this Elixir code once?"
      refute present?(html, "p no")
      assert length(assigns(view).pending_approvals) == 1
    end

    test "evaluator ownership and resolutions use the source node, never the target runtime", %{
      conn: conn
    } do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      # Neither a matching target nor a matching task can authenticate another
      # source node; evaluator requests without a source stamp are rejected too.
      for request <- [
            eval_request(node: :foreign@source, target_node: node()),
            eval_request(node: nil),
            eval_request(task_id: "other-task", agent_id: nil)
          ] do
        html = send_and_render(view, {:approval_requested, request})
        assert assigns(view)[:pending_approvals] == []
        assert approval_strip_count(html) == ""
        refute dialog_open?(html)
      end

      # String/integer agent refs match even without the task ref. The target
      # is deliberately remote; the response must still go to LOCAL source.
      request = eval_request(task_id: nil, agent_id: "1001")
      html = send_and_render(view, {:approval_requested, request})
      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals
      assert dialog_open?(html)
      assert present?(html, approval_button("eval-1", "approve"))

      # A resolution stamped by the TARGET never touches the source's request.
      html = send_and_render(view, {:approval_resolved, "eval-1", :approve, :foreign@source})
      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals
      assert dialog_open?(html)

      view |> element(approval_button("eval-1", "approve")) |> render_click()

      assert_receive {:approval_response_called, worker, source, "eval-1", "approve"},
                     @async_wait_budget_ms

      assert source == node()
      refute source == request.target_node

      html = send_and_render(view, {:approval_resolved, "eval-1", :approve, node()})
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_responses == %{}
      refute dialog_open?(html)
      refute present?(html, approval_button("eval-1", "approve"))

      # A late error from the now-resolved response cannot resurrect its card
      # or show an error. Monitor the worker before draining the page mailbox.
      monitor = Process.monitor(worker)
      send(worker, {:respond, {:error, :nodedown}})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @async_wait_budget_ms
      render(view)
      assert assigns(view).approval_error == nil
      assert assigns(view).pending_approvals == []
    end

    test "new chat clears the workflow and rejects an old asynchronous response", %{conn: conn} do
      install_blocking_approval_responder()
      {:ok, view, _html} = live(conn, "/assistant")
      old_chat = assigns(view).chat_id
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})
      html = send_and_render(view, {:approval_requested, eval_request()})
      assert dialog_open?(html)
      view |> element(approval_button("eval-1", "approve")) |> render_click()

      assert_receive {:approval_response_called, worker, _, "eval-1", "approve"},
                     @async_wait_budget_ms

      assert map_size(assigns(view).approval_responses) == 1

      # A completed conversation permits New chat. Drive the REAL reset event
      # (not a forged workflow result) before releasing the old responder.
      seed_chat_state(view, %{chat_status: :idle})
      render_click(view, "new_chat", %{})
      assert assigns(view).chat_id != old_chat
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_responses == %{}
      assert assigns(view).approval_error == nil
      assert assigns(view).approval_dialog_open == false
      html = render(view)
      refute dialog_open?(html)
      assert approval_strip_count(html) == ""

      monitor = Process.monitor(worker)
      send(worker, {:respond, {:error, :old_scope_failure}})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @async_wait_budget_ms
      html = render(view)
      assert assigns(view).approval_error == nil
      assert assigns(view).pending_approvals == []
      refute html =~ "old_scope_failure"
      refute dialog_open?(html)
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

      {:ok, view, _html} = live(conn, "/assistant")
      assert_receive {:approval_snapshot_called, worker, source}, @async_wait_budget_ms
      refute worker == view.pid
      assert source == node()
      assert assigns(view).chat_id == chat_id
      wait_until(fn -> length(assigns(view)[:pending_approvals]) == 2 end)
      html = render(view)
      assert assigns(view).approval_recovering == false
      assert assigns(view).approval_error == nil

      assert Enum.sort(Enum.map(assigns(view)[:pending_approvals], & &1.request_id)) ==
               ["eval-1", "legacy-agent"]

      # The snapshot populated the strip, and pushed NO browser notification
      # (the recovery result is already applied, so this window cannot hide it).
      assert approval_strip_count(html) == "2"
      assert present?(html, ~s(#approval-status-bar button[phx-click="open_approval_dialog"]))
      refute_push_event(view, "task_notification", %{tag: "genesis-approval"}, 50)

      # A RECOVERY snapshot never opens the dialog on its own: Review does.
      assert assigns(view).approval_dialog_open == false
      refute dialog_open?(html)

      html =
        view
        |> element(~s(#approval-status-bar button[phx-click="open_approval_dialog"]))
        |> render_click()

      assert dialog_open?(html)
      assert approval_position(html) == "1 of 2"
      assert present?(html, approval_button("eval-1", "approve"))
      refute present?(html, approval_button("wrong-source", "approve"))

      # The recovered request renders its EXACT code.
      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               owned.code

      # Stepping reaches the legacy-agent grant, which has no code block.
      html = view |> element(~s(button[phx-click="next_approval"])) |> render_click()
      assert approval_position(html) == "2 of 2"
      assert present?(html, approval_button("legacy-agent", "deny"))
      assert html =~ "NavigateToPage.navigate"
      refute present?(html, approval_button("eval-1", "approve"))
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

      {:ok, view, _html} = live(conn, "/assistant")
      assert_receive {:approval_snapshot_waiting, worker, source}, @async_wait_budget_ms
      assert source == node()
      assert assigns(view).approval_recovering
      scope = approval_scope(view)
      seq = assigns(view).approval_recovery_seq

      # Wrong generation is ignored by the PAGE's nested-message route too.
      html =
        send_and_render(
          view,
          {{:approval_pending_loaded, seq - 1, scope}, {:ok, [eval_request()]}}
        )

      assert assigns(view).approval_recovering
      assert assigns(view).pending_approvals == []
      refute dialog_open?(html)

      send(view.pid, {:approval_requested, eval_request(request_id: "resolved")})
      send(view.pid, {:approval_resolved, "resolved", :deny, node()})

      html =
        send_and_render(
          view,
          {:approval_requested, eval_request(request_id: "newer", code: "newer exact code")}
        )

      # A live request during recovery still asks in place.
      assert dialog_open?(html)

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

      assert approval_strip_count(html) == "2"
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

      {:ok, view, _html} = live(conn, "/assistant")
      assert_receive {:approval_snapshot_waiting, worker}, @async_wait_budget_ms
      old_scope = approval_scope(view)
      seq = assigns(view).approval_recovery_seq
      assert is_integer(seq)

      # Model a scope moving before its old asynchronous result can land.
      # Use the SAME task refs to ensure the full chat scope, not only the
      # own-request predicate, is checked by the page's forwarding handler.
      seed_chat_state(view, %{chat_id: "different-chat"})

      html =
        send_and_render(
          view,
          {{:approval_pending_loaded, seq, old_scope}, {:ok, [eval_request()]}}
        )

      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_recovering == false
      assert assigns(view).approval_recovery_seq == nil
      assert assigns(view).approval_error == nil
      assert approval_strip_count(html) == ""
      refute dialog_open?(html)

      # The real, late SafeCall reply is equally stale after that rejection.
      monitor = Process.monitor(worker)
      send(worker, :release_snapshot)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @async_wait_budget_ms
      html = render(view)
      assert assigns(view).pending_approvals == []
      refute present?(html, approval_button("eval-1", "approve"))
      assert approval_strip_count(html) == ""
    end

    test "duplicate approval_requested upserts instead of stacking", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send(view.pid, {:approval_requested, l2_request()})
      html = send_and_render(view, {:approval_requested, l2_request()})

      assert length(assigns(view)[:pending_approvals]) == 1
      assert hd(assigns(view)[:pending_approvals]).request_id == "req-1"
      assert approval_strip_count(html) == "1"
      # One request only: no position badge and exactly one decision pair.
      assert approval_position(html) == ""

      assert length(Floki.find(Floki.parse_document!(html), ~s([phx-value-decision="approve"]))) ==
               1
    end

    test "two pending requests step through the dialog with disabled ends", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l2_request(request_id: "first")})
      assert dialog_open?(html)
      assert approval_position(html) == ""

      html = send_and_render(view, {:approval_requested, l2_request(request_id: "second")})
      assert approval_strip_count(html) == "2"
      assert dialog_open?(html)
      # Newest first, ONE request at a time, with the ends disabled.
      assert approval_position(html) == "1 of 2"
      assert present?(html, approval_button("second", "approve"))
      refute present?(html, approval_button("first", "approve"))
      assert disabled?(html, ~s(button[phx-click="prev_approval"]))
      refute disabled?(html, ~s(button[phx-click="next_approval"]))

      html = view |> element(~s(button[phx-click="next_approval"])) |> render_click()
      assert approval_position(html) == "2 of 2"
      assert present?(html, approval_button("first", "approve"))
      refute present?(html, approval_button("second", "approve"))
      refute disabled?(html, ~s(button[phx-click="prev_approval"]))
      assert disabled?(html, ~s(button[phx-click="next_approval"]))
      assert assigns(view).approval_dialog_index == 1

      html = view |> element(~s(button[phx-click="prev_approval"])) |> render_click()
      assert approval_position(html) == "1 of 2"
      assert present?(html, approval_button("second", "approve"))
      assert assigns(view).approval_dialog_index == 0
    end

    test "Review re-opens the closed dialog while the strip keeps the count", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert dialog_open?(html)

      html =
        view
        |> element(~s(#approval-dialog button[phx-click="dialog_closed"]))
        |> render_click()

      refute dialog_open?(html)
      assert assigns(view).approval_dialog_open == false
      # Dismissing the dialog deliberately keeps the request pending.
      assert [%{request_id: "req-1"}] = assigns(view).pending_approvals
      assert approval_strip_count(html) == "1"

      html =
        view
        |> element(~s(#approval-status-bar button[phx-click="open_approval_dialog"]))
        |> render_click()

      assert dialog_open?(html)
      assert assigns(view).approval_dialog_open == true
      assert present?(html, approval_button("req-1", "approve"))
    end

    test "the dialog sends only the request id and a whitelisted decision to the responder", %{
      conn: conn
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
        send(test_pid, {:approval_response_arguments, source, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      html = send_and_render(view, {:approval_requested, eval_request()})
      assert dialog_open?(html)
      view |> element(approval_button("eval-1", "approve")) |> render_click()

      # EXACTLY (chat node, request id, "approve") — no code, tier or target.
      assert_receive {:approval_response_arguments, source, "eval-1", "approve"},
                     @async_wait_budget_ms

      assert source == node()
      wait_until(fn -> assigns(view)[:pending_approvals] == [] end)
      assert assigns(view).approval_responses == %{}

      html = send_and_render(view, {:approval_requested, l2_request()})
      assert dialog_open?(html)
      view |> element(approval_button("req-1", "deny")) |> render_click()

      assert_receive {:approval_response_arguments, ^source, "req-1", "deny"},
                     @async_wait_budget_ms

      wait_until(fn -> assigns(view)[:pending_approvals] == [] end)
      assert assigns(view).approval_error == nil
    end

    test "resolving the last request closes the dialog and core resolutions step the cursor", %{
      conn: conn
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
        send(test_pid, {:approval_response_arguments, source, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send_and_render(view, {:approval_requested, l2_request(request_id: "first")})
      html = send_and_render(view, {:approval_requested, l2_request(request_id: "second")})
      assert approval_position(html) == "1 of 2"

      # The core resolved the request the dialog is SHOWING: the cursor moves
      # to the survivor instead of blanking or stacking.
      html = send_and_render(view, {:approval_resolved, "second", :approve})
      assert dialog_open?(html)
      assert approval_strip_count(html) == "1"
      assert approval_position(html) == ""
      assert present?(html, approval_button("first", "approve"))
      assert assigns(view).approval_dialog_index == 0

      # Deciding the LAST request closes the dialog and empties the strip.
      view |> element(approval_button("first", "approve")) |> render_click()

      assert_receive {:approval_response_arguments, _source, "first", "approve"},
                     @async_wait_budget_ms

      wait_until(fn -> assigns(view)[:pending_approvals] == [] end)
      html = render(view)
      assert approval_strip_count(html) == ""
      refute present?(html, ~s(#approval-status-bar button[phx-click="open_approval_dialog"]))
      refute dialog_open?(html)
      # The response path syncs the dialog view state too: nothing is left to
      # show, so the dialog is closed and its cursor reset.
      assert assigns(view).approval_dialog_open == false
      assert assigns(view).approval_dialog_index == 0

      # A core resolution that empties the list closes the dialog's own state.
      html = send_and_render(view, {:approval_requested, l2_request(request_id: "third")})
      assert dialog_open?(html)
      html = send_and_render(view, {:approval_resolved, "third", :deny})
      refute dialog_open?(html)
      assert assigns(view).approval_dialog_open == false
      assert approval_strip_count(html) == ""
    end

    test "a response or recovery that empties the list closes the dialog and clamps the cursor",
         %{
           conn: conn
         } do
      test_pid = self()

      Application.put_env(:evo_dash, :approval_responder, fn _source, id, decision ->
        send(test_pid, {:approval_response_arguments, id, decision})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send_and_render(view, {:approval_requested, l2_request(request_id: "one")})
      html = send_and_render(view, {:approval_requested, l2_request(request_id: "two")})
      # Newest first: "two" is position 1, "one" is position 2.
      assert approval_position(html) == "1 of 2"
      assert present?(html, approval_button("two", "approve"))

      # Step to the LAST request, then decide it asynchronously.
      html = view |> element(~s(button[phx-click="next_approval"])) |> render_click()
      assert approval_position(html) == "2 of 2"
      assert assigns(view).approval_dialog_index == 1
      assert present?(html, approval_button("one", "approve"))

      view |> element(approval_button("one", "approve")) |> render_click()
      assert_receive {:approval_response_arguments, "one", "approve"}, @async_wait_budget_ms

      wait_until(fn -> length(assigns(view)[:pending_approvals]) == 1 end)
      html = render(view)

      # The dialog stays open on the survivor, but the cursor is CLAMPED to the
      # shorter list (index 1 would be out of range).
      assert assigns(view).approval_dialog_open == true
      assert assigns(view).approval_dialog_index == 0
      assert approval_position(html) == ""
      assert present?(html, approval_button("two", "approve"))

      view |> element(approval_button("two", "deny")) |> render_click()
      assert_receive {:approval_response_arguments, "two", "deny"}, @async_wait_budget_ms

      wait_until(fn -> assigns(view)[:pending_approvals] == [] end)
      html = render(view)
      assert assigns(view).approval_dialog_open == false
      assert assigns(view).approval_dialog_index == 0
      refute dialog_open?(html)

      # The recovery-apply path syncs exactly the same view state: an empty
      # snapshot closes an open dialog instead of leaving it "open".
      html = send_and_render(view, {:approval_requested, l2_request(request_id: "solo")})
      assert dialog_open?(html)
      assert assigns(view).approval_dialog_open == true

      tag = {:approval_pending_loaded, assigns(view).approval_recovery_seq, approval_scope(view)}
      html = send_and_render(view, {tag, {:ok, []}})

      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_dialog_open == false
      assert assigns(view).approval_dialog_index == 0
      refute dialog_open?(html)
    end

    test "a new live request raises a browser notification", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      send_and_render(view, {:approval_requested, l2_request()})

      assert_push_event(
        view,
        "task_notification",
        %{tag: "genesis-approval"},
        @async_wait_budget_ms
      )
    end

    test "requests this chat does not own never raise a browser notification", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      seed_chat_state(view, %{chat_status: :running, chat_task_id: "t1", chat_agent_id: 1001})

      # The workflow ignores all of these, so notifying would ask the user to
      # act on an approval this page cannot even show. The notification gate is
      # the SAME ownership predicate (ApprovalWorkflow.own_request?/2).
      for request <- [
            l2_request(task_id: "other-task"),
            l2_request(task_id: nil, agent_id: "someone-else"),
            l2_request(node: :foreign@node)
          ] do
        send_and_render(view, {:approval_requested, request})

        refute_push_event(view, "task_notification", %{tag: "genesis-approval"}, 50)
      end

      assert assigns(view).pending_approvals == []
      refute dialog_open?(render(view))

      # The gate is per request: the next OWNED request notifies normally.
      send_and_render(view, {:approval_requested, l2_request()})

      assert_push_event(
        view,
        "task_notification",
        %{tag: "genesis-approval"},
        @async_wait_budget_ms
      )
    end

    # A task-LESS interactive session (the repo-less `/assistant` root) has a
    # scheduler-MINTED task id that owns no `tasks` row. Everything the user
    # sees must therefore come from the broadcast + `pending/0` snapshot, keyed
    # on the chat node plus that minted id OR the session agent id.
    test "a task-less interactive session surfaces, notifies and answers a live request", %{
      conn: conn
    } do
      install_blocking_approval_responder()

      # Nothing in the isolated store owns this minted id: no task row exists to
      # read, list or gate on.
      refute match?(%{status: _}, EvoGit.TaskRegistry.get_task_lite(@task_less_task_id))

      {:ok, view, _html} = live(conn, "/assistant")

      seed_chat_state(view, %{
        chat_status: :awaiting_input,
        chat_task_id: @task_less_task_id,
        chat_agent_id: 1001,
        chat_node: node()
      })

      request = task_less_eval_request()
      html = send_and_render(view, {:approval_requested, request})

      # The strip counts it, the dialog opens on its own, and the browser
      # notification fires — the same treatment a task-backed request gets.
      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals
      assert approval_strip_count(html) == "1"
      assert html =~ "Genesis is waiting for your approval"
      assert dialog_open?(html)
      assert present?(html, approval_button("eval-1", "approve"))

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               request.code

      assert_push_event(
        view,
        "task_notification",
        %{tag: "genesis-approval"},
        @async_wait_budget_ms
      )

      # Approve travels to the responder with (chat node, request id, decision).
      view |> element(approval_button("eval-1", "approve")) |> render_click()

      assert_receive {:approval_response_called, worker, source, "eval-1", "approve"},
                     @async_wait_budget_ms

      assert source == node()
      refute worker == view.pid
      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals
      assert dialog_open?(render(view))

      # The core's own resolution (stamped with the SOURCE node) settles the
      # card even while the response is still in flight.
      html = send_and_render(view, {:approval_resolved, "eval-1", :approve, node()})

      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_dialog_open == false
      assert assigns(view).approval_dialog_index == 0
      assert approval_strip_count(html) == ""
      refute dialog_open?(html)

      # A late success cannot resurrect the resolved card or raise an error.
      monitor = Process.monitor(worker)
      send(worker, {:respond, :ok})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @async_wait_budget_ms
      html = render(view)
      assert assigns(view).pending_approvals == []
      assert assigns(view).approval_error == nil
      refute dialog_open?(html)
    end

    test "a task-less session never renders or notifies for another agent's request", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/assistant")

      seed_chat_state(view, %{
        chat_status: :awaiting_input,
        chat_task_id: @task_less_task_id,
        chat_agent_id: 1001,
        chat_node: node()
      })

      # Another agent (no task ref at all), another minted task id, and a
      # foreign source node: each is somebody else's decision.
      for request <- [
            task_less_eval_request(%{request_id: "other-agent", task_id: nil, agent_id: "2002"}),
            task_less_eval_request(%{
              request_id: "other-task",
              task_id: "01f0b2c3",
              agent_id: nil
            }),
            task_less_eval_request(%{request_id: "other-node", node: :foreign@node})
          ] do
        html = send_and_render(view, {:approval_requested, request})

        assert assigns(view).pending_approvals == []
        assert assigns(view).approval_dialog_open == false
        assert approval_strip_count(html) == ""
        refute dialog_open?(html)
        refute html =~ "Genesis is waiting for your approval"
        refute_push_event(view, "task_notification", %{tag: "genesis-approval"}, 50)
      end
    end

    test "a task-less session recovers its pending request on mount without a task row", %{
      conn: conn
    } do
      test_pid = self()
      request = task_less_eval_request()

      Application.put_env(:evo_dash, :approval_pending_runner, fn source ->
        send(test_pid, {:task_less_snapshot, self(), source})
        [request]
      end)

      chat_id = EvoDash.ChatHistory.new_chat()

      EvoDash.ChatHistory.put_state(
        chat_id,
        EvoDashWeb.HomeLive.ChatState.build(%{
          chat_status: :awaiting_input,
          chat_task_status: :running,
          chat_task_id: @task_less_task_id,
          chat_agent_id: 1001,
          chat_node: node()
        })
      )

      refute match?(%{status: _}, EvoGit.TaskRegistry.get_task_lite(@task_less_task_id))

      {:ok, view, _html} = live(conn, "/assistant")

      assert_receive {:task_less_snapshot, worker, source}, @async_wait_budget_ms
      refute worker == view.pid
      assert source == node()
      assert assigns(view).chat_id == chat_id

      wait_until(fn -> length(assigns(view)[:pending_approvals]) == 1 end)
      html = render(view)

      assert [%{request_id: "eval-1"}] = assigns(view).pending_approvals
      assert approval_strip_count(html) == "1"

      # A recovery snapshot never auto-opens or notifies; Review opens it and
      # the exact code is there.
      assert assigns(view).approval_dialog_open == false
      refute dialog_open?(html)
      refute_push_event(view, "task_notification", %{tag: "genesis-approval"}, 50)

      html =
        view
        |> element(~s(#approval-status-bar button[phx-click="open_approval_dialog"]))
        |> render_click()

      assert dialog_open?(html)

      assert html |> Floki.parse_document!() |> Floki.find("pre code") |> Floki.text() ==
               request.code
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

      {:ok, view, _html} = live(conn, "/assistant")
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

      {:ok, view, _html} = live(conn, "/assistant")
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

      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant?node=test-remote")
      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      assert assigns(view).current_node_id == "test-remote"
    end

    test "missing remote model snapshot rejects sends before touching the draft or transcript", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/assistant?node=test-remote")
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
      {:ok, view, _html} = live(conn, "/assistant?node=test-remote")
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
      # Patching back to "/assistant" (no ?node=) switches to local → a NEW chat.
      html = render_patch(view, "/assistant")
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
      {:ok, view, _html} = live(conn, "/assistant")
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "2"})
      assert assigns(view).model_spec == work_spec("high")
      local_chat_id = assigns(view).chat_id
      local_snapshot = assigns(view).model_snapshot
      local_seq = assigns(view).model_select_seq

      render_patch(view, "/assistant?node=test-remote")
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

      html = render_patch(view, "/assistant")
      assert assigns(view).current_node == node()
      assert assigns(view).chat_id not in [local_chat_id, remote_chat_id]
      # A different node gets its own configured default, NOT the earlier high pin.
      assert assigns(view).model_spec == work_spec()
      assert assigns(view).model_selection_scope == {nil, node()}
      assert selected_reasoning_index(html) == "1"
      assert selected_reasoning_label(html) == "Medium"

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

      {:ok, view, _html} = live(conn, "/assistant?node=test-remote")
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

  # ───────────────────────────────────────────────────────────────────────────
  # Interactive session send path (ONE long-lived session per conversation)
  #
  # `/assistant` no longer starts a one-shot `:reflect` task per message: the first
  # send starts ONE interactive Assistant session (`:home_session_start_runner`)
  # and every later send queues a message on it (`:home_session_send_runner`).
  # One-shot `:reflect` survives ONLY as the documented fallback when sessions
  # are unavailable. The seams below are call-time (resolved inside the spawned
  # SafeCall function), so installing them AFTER `live/3` is honoured.
  # ───────────────────────────────────────────────────────────────────────────

  # Installs a call-time app-env seam and restores the exact previous value
  # (or deletes the key, when it was unset) in `on_exit` — a seam must never
  # leak into the rest of this sync suite.
  defp install_session_seam(key, fun) do
    original = Application.fetch_env(:evo_dash, key)

    Application.put_env(:evo_dash, key, fun)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:evo_dash, key, value)
        :error -> Application.delete_env(:evo_dash, key)
      end
    end)

    :ok
  end

  # One user message in the shape the real attach loader returns (what
  # `HomeLive.apply_attach/2` feeds to `Messages.to_entries/1`).
  defp attach_history(text) do
    [
      %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: text}]
      }
    ]
  end

  # The attach state of a session that is MID-RUN: a `:running` summary keeps
  # `chat_status: :running` (a missing summary would settle the page at
  # `:ended`), and the history is the transcript the reattach renders.
  defp running_attach(session_id, history) do
    fn _node, _agent_id ->
      %{
        summary: %{id: session_id, status: :running, message_count: 4, task_id: nil},
        awaiting?: false,
        history: history
      }
    end
  end

  # The same MID-RUN attach answer, but as a VALUE (for the counting seam).
  defp running_attach_state(session_id, history) do
    %{
      summary: %{
        id: session_id,
        status: :running,
        message_count: 2,
        task_id: "task-#{session_id}"
      },
      awaiting?: false,
      history: history
    }
  end

  # The attach answer of a PARKED session (`:awaiting_input` → the page maps it
  # to `:idle`, i.e. writable) with no live history to rebuild a transcript from.
  defp parked_attach(session_id, status \\ :awaiting_input) do
    %{
      summary: %{id: session_id, status: status, message_count: 0, task_id: "task-#{session_id}"},
      awaiting?: false,
      history: []
    }
  end

  # The attach answer for a session the core no longer knows: no summary, not in
  # the awaiting list, no history.
  defp gone_attach, do: %{summary: nil, awaiting?: false, history: []}
  # A counting attach seam. `:counters` (shared atomics) is the drain-proof
  # witness for "the attach ran EXACTLY once": a mailbox count would need a quiet
  # window this sync suite cannot guarantee around the spawned child.
  # With `release?: true` that child PARKS until the test sends its answer, which
  # is what makes "the CACHED render is visible before the live result lands" a
  # deterministic observation instead of a race (no sleep, no timing window).
  defp counting_attach_runner(counter, test_pid, release?, answer \\ nil) do
    fn node, session_id ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:attach_called, node, session_id, self()})

      if release? do
        receive do
          {:release_attach, released} -> released
        end
      else
        answer
      end
    end
  end

  # Seeds a CACHED conversation in `EvoDashWeb.HomeLive.ChatState`'s real shape —
  # what `reattach_session/2` restores before the live attach result lands.
  defp seed_cached_chat(session_id, transcript, thought_process \\ []) do
    EvoDash.ChatHistory.put_state(session_id, %{
      transcript: transcript,
      chat_draft: "",
      chat_status: :idle,
      chat_task_id: nil,
      chat_agent_id: session_id,
      agent_message_count: length(transcript),
      chat_task_status: :awaiting_input,
      session_id: session_id,
      session_mode: :interactive,
      thought_process: thought_process,
      queued_echoes: []
    })

    session_id
  end

  # ── rendered conversation-list inspection (Floki) ─────────────────────────
  # Row ids in RENDER order, read from the shared app-layout sidebar's
  # "Conversations" section — `EvoDashWeb.HomeLive.SessionList` is rendered by
  # `EvoDashWeb.Layouts.app/1` on EVERY page and its `#chat-session-<id>` rows
  # are loaded/stale-guarded by `EvoDashWeb.LiveHooks.NodeAware`, not by the
  # Assistant page itself.
  defp session_row_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#chat-session-list a")
    |> Enum.flat_map(fn element ->
      case Floki.attribute(element, "id") do
        ["chat-session-" <> id] ->
          case Integer.parse(id) do
            {value, ""} -> [value]
            _other -> []
          end

        _other ->
          []
      end
    end)
  end

  defp session_row_html(html, id) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#chat-session-#{id}")
    |> List.first()
  end

  defp session_row_href(html, id) do
    case session_row_html(html, id) do
      nil -> nil
      element -> element |> Floki.attribute("href") |> List.first()
    end
  end

  defp session_row_raw(html, id) do
    case session_row_html(html, id) do
      nil -> ""
      element -> Floki.raw_html(element)
    end
  end

  defp write_tmp_attachment!(name, content) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_home_live_attach_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  # Seeds the "this conversation is a live interactive session" slice of the
  # chat state (the seeded assigns are authoritative for `assigns/1`; rendered
  # assertions need a real event afterwards — see seed_chat_state/2).
  defp seed_session_state(view, session_id, overrides \\ %{}) do
    seed_chat_state(
      view,
      Map.merge(
        %{
          session_id: session_id,
          current_session_id: session_id,
          chat_id: session_id,
          session_mode: :interactive,
          chat_agent_id: session_id,
          chat_status: :idle,
          chat_task_id: nil,
          agent_message_count: 0,
          transcript: [],
          queued_echoes: []
        },
        overrides
      )
    )
  end

  describe "interactive session send path" do
    test "no session starts ONE repo-less interactive Assistant session and adopts it", %{
      conn: conn
    } do
      text = "hello session"
      test_pid = self()
      local_node = node()

      install_session_seam(:home_session_start_runner, fn node, opts ->
        send(test_pid, {:session_start_called, node, opts})
        {:ok, 4242}
      end)

      install_snapshot_fixture(4242, attach_history("re-attached transcript"), :running)

      install_session_seam(
        :home_session_attach_runner,
        running_attach(4242, attach_history("re-attached transcript"))
      )

      {:ok, view, _html} = live(conn, "/assistant")
      html = render_submit(view, "send_message", %{"message" => text})

      assert_receive {:session_start_called, start_node, opts}
      assert start_node == node()
      # The Assistant session spec: repo-less, interactive, and the RAW typed
      # text as the objective (the one-shot transcript preamble is NOT built
      # for a session — it owns the whole conversation).
      assert opts[:agent_module] == EvoGit.Agents.SelfReflective
      assert opts[:repo_less] == true
      assert opts[:session_mode] == :interactive
      assert opts[:objective] == text
      # Auto selection: no canonical model spec, no legacy override and no
      # attachment list (nothing was staged).
      refute Keyword.has_key?(opts, :model_spec)
      refute Keyword.has_key?(opts, :model_id)
      refute Keyword.has_key?(opts, :attachments)

      # Adoption: the returned id becomes the chat/session identity AND the URL.
      assert_patch(view, "/assistant?session=4242")
      assigns = assigns(view)
      assert assigns.session_id == 4242
      assert assigns.current_session_id == 4242
      assert assigns.chat_id == 4242
      assert assigns.chat_agent_id == 4242
      assert assigns.session_mode == :interactive
      assert assigns.chat_status == :running
      assert assigns.chat_draft == ""
      # The optimistic user bubble is in the synchronous submit render. The
      # authoritative Watch cut then replaces it with the live transcript.
      assert html =~ text

      # Await the watch transcript itself, not an independent attach reply or
      # summary message count: history and current activity belong to one cut.
      wait_until(fn ->
        Enum.any?(assigns(view)[:transcript], fn entry ->
          entry.role == :user and entry.text == "re-attached transcript"
        end)
      end)

      settled = assigns(view)
      assert settled.session_id == 4242
      assert settled.chat_status == :running

      assert Enum.any?(
               settled.transcript,
               &(&1.role == :user and &1.text == "re-attached transcript")
             )

      # A SECOND send rides the adopted session: no second start, one queued
      # message on the SAME agent id.
      install_session_seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(test_pid, {:session_send_called, node, agent_id, message, policy})
        :ok
      end)

      html2 = render_submit(view, "send_message", %{"message" => "second message"})
      assert_receive {:session_send_called, ^local_node, 4242, "second message", :queue}
      refute_receive {:session_start_called, _node, _opts}, 0
      assert html2 =~ "second message"
      # Mid-run sends are QUEUED, so the echo line renders (the message is not
      # lost, just deferred to the next turn boundary).
      assert html2 =~ "Queued — sent at the next turn boundary"
    end

    test "an existing session queues the message without starting any task", %{conn: conn} do
      test_pid = self()
      local_node = node()

      install_session_seam(:home_session_start_runner, fn node, opts ->
        send(test_pid, {:session_start_called, node, opts})
        {:ok, 5252}
      end)

      install_session_seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(test_pid, {:session_send_called, node, agent_id, message, policy})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      seed_session_state(view, 5252, %{
        transcript: [%{id: "1", role: :user, text: "first", streaming: false}]
      })

      html = render_submit(view, "send_message", %{"message" => "another one"})

      # The bare BINARY message (no attachments staged) and the queue policy.
      assert_receive {:session_send_called, ^local_node, 5252, "another one", :queue}
      # Neither a new session nor a one-shot reflect task is created.
      refute_receive {:session_start_called, _node, _opts}, 0
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      assigns = assigns(view)
      assert assigns.chat_status == :running
      assert assigns.chat_draft == ""
      assert Enum.any?(assigns.transcript, &(&1.role == :user and &1.text == "another one"))
      assert html =~ "another one"
    end

    test "an unavailable interactive session falls back to one-shot reflect mode", %{conn: conn} do
      text = "fallback question"

      install_session_seam(:home_session_start_runner, fn _node, _opts ->
        {:error, :llm_not_configured}
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      {html, log} =
        send_and_await_terminal(fn ->
          render_submit(view, "send_message", %{"message" => text})
        end)

      # The real (fail-fast) reflect wrapper's asynchronous error log, captured
      # inside the same window (see send_and_await_terminal/1).
      assert log =~ "SelfReflective failed"

      assigns = assigns(view)
      assert assigns.session_mode == :one_shot
      assert assigns.session_id == nil

      assert assigns.flash["info"] ==
               "Interactive sessions are unavailable here. This conversation runs in one-shot mode."

      assert html =~ text

      reflect =
        Enum.filter(EvoGit.Store.safe_select_all_tasks(EvoGit.Store), &(&1.type == :reflect))

      assert [task] = reflect
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == text
      refute has_opt?(task, :path)
      cleanup_task_on_exit(task.id)
    end

    test "a wrapped interactive_root_only refusal also falls back to one-shot mode", %{
      conn: conn
    } do
      text = "root only here"

      install_session_seam(:home_session_start_runner, fn _node, _opts ->
        {:error, {:start_session_failed, {:interactive_root_only, "subagent"}}}
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      {_html, log} =
        send_and_await_terminal(fn ->
          render_submit(view, "send_message", %{"message" => text})
        end)

      assert log =~ "SelfReflective failed"

      assigns = assigns(view)
      assert assigns.session_mode == :one_shot
      assert assigns.session_id == nil

      assert assigns.flash["info"] ==
               "Interactive sessions are unavailable here. This conversation runs in one-shot mode."

      reflect =
        Enum.filter(EvoGit.Store.safe_select_all_tasks(EvoGit.Store), &(&1.type == :reflect))

      assert [task] = reflect
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == text
      cleanup_task_on_exit(task.id)
    end

    test "a finished session ends the chat, keeps the transcript and disables the composer", %{
      conn: conn
    } do
      assert_session_ended(conn, {:session, :finished})
    end

    test "a not_found session ends the chat the same way", %{conn: conn} do
      assert_session_ended(conn, {:session, :not_found})
    end

    test "an unrecoverable send failure does NOT end the chat", %{conn: conn} do
      test_pid = self()

      install_session_seam(:home_session_send_runner, fn _node, _agent_id, message, _policy ->
        send(test_pid, {:session_send_called, message})
        {:error, :timeout}
      end)

      {:ok, view, _html} = live(conn, "/assistant")
      # A send failure only surfaces while the turn is in flight; the idle
      # seed would leave the page at `:idle` and never exercise the
      # retryable-non-terminal branch.
      seed_session_state(view, 6161, %{chat_status: :running})

      render_submit(view, "send_message", %{"message" => "hello"})
      assert_receive {:session_send_called, "hello"}

      assigns = assigns(view)
      # NOT an ended conversation: the session may still be alive, so the send
      # is retryable and the status stays running (no `:ended` dead end).
      assert assigns.chat_status == :running
      assert assigns.flash["error"] =~ "Failed to send the message"
    end
  end

  # Drives the documented "session is GONE" contract on a seeded session: a
  # first successful send renders an exchange, then a send failing with
  # `reason` must end the chat WITHOUT dropping what is already on screen.
  defp assert_session_ended(conn, reason) do
    test_pid = self()

    install_session_seam(:home_session_send_runner, fn _node, _agent_id, message, _policy ->
      send(test_pid, {:session_send_called, message})

      if message == "old question" do
        :ok
      else
        {:error, reason}
      end
    end)

    {:ok, view, _html} = live(conn, "/assistant")
    seed_session_state(view, 6363)

    html = render_submit(view, "send_message", %{"message" => "old question"})
    assert_receive {:session_send_called, "old question"}
    assert html =~ "old question"

    html2 = render_submit(view, "send_message", %{"message" => "after end"})
    assert_receive {:session_send_called, "after end"}

    assigns = assigns(view)
    assert assigns.chat_status == :ended
    # The transcript is KEPT — the earlier exchange still renders and is still
    # in the state (the ended session is read-only, not cleared).
    assert Enum.any?(assigns.transcript, &(&1.role == :user and &1.text == "old question"))
    assert html2 =~ "old question"

    assert assigns.flash["error"] ==
             "This conversation has ended. Start a new chat to continue."

    # The composer is closed: no message can be typed into a dead session.
    assert disabled?(html2, ~s(textarea[name="message"]))
    assert html2 =~ "This conversation has ended. Start a new chat to continue."
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # REATTACH (`?session=<id>`) and the mounted SESSION LIST.
  #
  # A reattach ADOPTS an existing interactive session: the cached conversation is
  # restored from ChatHistory, then Watch supplies the authoritative lifecycle
  # and transcript while the independent attach loader supplies task identity.
  # It must NEVER start a task, so tests also pin the empty task store.
  # ─────────────────────────────────────────────────────────────────────────────
  describe "interactive session reattach (?session=)" do
    test "adopts a parked session from the cache in ONE attach and starts no task", %{conn: conn} do
      test_pid = self()
      session_id = 6_501
      attach_calls = :counters.new(1, [:atomics])
      start_calls = :counters.new(1, [:atomics])
      install_session_seam(:home_session_list_runner, fn _node -> {[], []} end)
      install_session_seam(:source_availability_runner, fn -> true end)

      install_session_seam(:home_session_start_runner, fn node, opts ->
        :counters.add(start_calls, 1, 1)
        send(test_pid, {:session_start_called, node, opts})
        {:ok, 1}
      end)

      install_session_seam(
        :home_session_attach_runner,
        counting_attach_runner(attach_calls, test_pid, true)
      )

      # Hold the authoritative cut alongside attach so the cached render below
      # remains observable until this test releases the live lifecycle.
      install_session_seam(:home_agent_watch_runner, fn _node, ^session_id, consumer ->
        send(test_pid, {:watch_pending, self()})

        await_snapshot_release(consumer, fn ->
          snapshot_answer(7, attach_history("cached text"), phase: :awaiting_input).(session_id)
        end)
      end)

      install_session_seam(:home_agent_unwatch_runner, fn _node, _id, _consumer -> :ok end)

      seed_cached_chat(session_id, [
        %{id: "u1", role: :user, text: "cached text", streaming: false}
      ])

      {:ok, view, html} = live(conn, "/assistant?session=#{session_id}")

      # `handle_params` reattaches on the FIRST connected render, so the CACHED
      # conversation is already visible (not an empty state).
      assert html =~ "cached text"
      refute html =~ "What would you like Genesis to do?"
      assert assigns(view).session_id == session_id
      assert assigns(view).session_mode == :interactive

      assert_receive {:attach_called, _node, ^session_id, attach_pid}, 5_000

      # Safety net: a failure before the release below must never leave the
      # spawned attach child parked forever.
      on_exit(fn -> send(attach_pid, {:release_attach, gone_attach()}) end)

      assert_receive {:watch_pending, watch_pid}, @async_wait_budget_ms
      send(watch_pid, :release)
      send(attach_pid, {:release_attach, parked_attach(session_id)})

      wait_until(fn ->
        a = assigns(view)
        a.chat_status == :idle and a.chat_task_id == "task-#{session_id}"
      end)

      a = assigns(view)
      # Phase mapping: `:awaiting_input` is a PARKED (writable) session.
      assert a.chat_task_status == :awaiting_input
      refute a.model_select_loading

      # EXACTLY ONE attach for this id, and NO session start / task row.
      assert :counters.get(attach_calls, 1) == 1
      assert :counters.get(start_calls, 1) == 0
      refute_receive {:session_start_called, _node, _opts}, 0
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      # A reattached idle session is WRITABLE: composer + New chat both enabled.
      html = await_source_available(view, true)
      refute disabled?(html, ~s(textarea[name="message"]))
      refute disabled?(html, ~s(button[phx-click="new_chat"]))
    end

    test "maps a RUNNING session to :running and locks New chat, still without a task",
         %{conn: conn} do
      test_pid = self()
      session_id = 6_502
      attach_calls = :counters.new(1, [:atomics])
      start_calls = :counters.new(1, [:atomics])
      install_session_seam(:home_session_list_runner, fn _node -> {[], []} end)
      install_session_seam(:source_availability_runner, fn -> true end)

      install_session_seam(:home_session_start_runner, fn _node, _opts ->
        :counters.add(start_calls, 1, 1)
        {:ok, 1}
      end)

      install_snapshot_fixture(session_id, attach_history("live transcript line"), :running)

      install_session_seam(
        :home_session_attach_runner,
        counting_attach_runner(
          attach_calls,
          test_pid,
          false,
          running_attach_state(session_id, attach_history("live transcript line"))
        )
      )

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:attach_called, _node, ^session_id, _pid}, 5_000
      wait_until(fn -> assigns(view).chat_status == :running end)

      a = assigns(view)
      assert a.chat_task_status == :running
      # The live history REPLACES the cached transcript.
      assert Enum.any?(a.transcript, &(&1.text == "live transcript line"))
      assert :counters.get(attach_calls, 1) == 1
      assert :counters.get(start_calls, 1) == 0
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      html = await_source_available(view, true)
      # Mid-run a follow-up may still be QUEUED, but a new chat may not begin.
      refute disabled?(html, ~s(textarea[name="message"]))
      assert disabled?(html, ~s(button[phx-click="new_chat"]))
    end

    test "a VANISHED session keeps the cached conversation read-only and ends the chat",
         %{conn: conn} do
      test_pid = self()
      session_id = System.unique_integer([:positive]) + 1_000_000_000
      attach_calls = :counters.new(1, [:atomics])
      start_calls = :counters.new(1, [:atomics])
      install_session_seam(:home_session_list_runner, fn _node -> {[], []} end)
      install_session_seam(:source_availability_runner, fn -> true end)

      install_session_seam(:home_session_start_runner, fn _node, _opts ->
        :counters.add(start_calls, 1, 1)
        {:ok, 1}
      end)

      # No watch seam: the default NodeContext/core registration must establish
      # that this unique id genuinely has no session.

      install_session_seam(
        :home_session_attach_runner,
        counting_attach_runner(attach_calls, test_pid, false, gone_attach())
      )

      cached_thoughts = [
        %{type: "assistant", turn: 1, data: %{content: "cached reasoning"}, timestamp: nil}
      ]

      seed_cached_chat(
        session_id,
        [
          %{id: "u1", role: :user, text: "cached before vanish", streaming: false},
          %{
            id: "a1",
            role: :assistant,
            text: "cached answer",
            streaming: false,
            reasoning: cached_thoughts
          }
        ],
        cached_thoughts
      )

      {:ok, view, html} = live(conn, "/assistant?session=#{session_id}")
      assert html =~ "cached before vanish"

      assert_receive {:attach_called, _node, ^session_id, _pid}, 5_000

      monitor_watch_cleanup(view)
      wait_until(fn -> assigns(view).chat_status == :ended end)

      assert assigns(view).chat_status == :ended

      a = assigns(view)
      assert a.chat_task_id == nil
      assert a.chat_task_status == nil
      # An EMPTY fetched history means the session is gone: the cached
      # transcript and its reasoning are KEPT (never wiped by `[]`).
      assert Enum.map(a.transcript, & &1.text) == ["cached before vanish", "cached answer"]
      assert a.thought_process == cached_thoughts
      assert List.last(a.transcript).reasoning == cached_thoughts
      assert a.chat_stream.error == {:not_found, :session_not_found}
      refute present?(render(view), "#chat-stream-error")
      # Exactly ONE attach, no session start and no task row.
      assert :counters.get(attach_calls, 1) == 1
      assert :counters.get(start_calls, 1) == 0
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      html = await_source_available(view, true)
      # The retained conversation (reasoning included) is still on screen...
      assert html =~ "cached before vanish"
      assert html =~ "cached reasoning"
      # ...with no streaming assistant bubble and no ended-session empty state...
      refute present?(html, ".help-caret")
      refute present?(html, "#chat-session-ended")
      # ...and is READ-ONLY, while New chat stays ENABLED so the user can move on.
      assert disabled?(html, ~s(textarea[name="message"]))
      refute disabled?(html, ~s(button[phx-click="new_chat"]))
    end

    test "a VANISHED session with no cached conversation renders the session-ended state",
         %{conn: conn} do
      test_pid = self()
      session_id = System.unique_integer([:positive]) + 1_000_000_000
      attach_calls = :counters.new(1, [:atomics])
      install_session_seam(:home_session_list_runner, fn _node -> {[], []} end)
      install_session_seam(:source_availability_runner, fn -> true end)

      # No watch seam: the default NodeContext/core registration must establish
      # that this unique id genuinely has no session.

      install_session_seam(
        :home_session_attach_runner,
        counting_attach_runner(attach_calls, test_pid, false, gone_attach())
      )

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:attach_called, _node, ^session_id, _pid}, 5_000

      monitor_watch_cleanup(view)
      wait_until(fn -> assigns(view).chat_status == :ended end)

      assert assigns(view).chat_status == :ended

      assert assigns(view).transcript == []
      assert assigns(view).chat_stream.error == {:not_found, :session_not_found}
      refute present?(render(view), "#chat-stream-error")
      assert :counters.get(attach_calls, 1) == 1
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      html = await_source_available(view, true)
      # Nothing was cached and nothing was fetched, so the ended-session state
      # replaces the greeting (whose suggestion chips could only send doomed
      # messages) and offers the explicit New-chat affordance.
      refute html =~ "What would you like Genesis to do?"
      refute present?(html, ~s(#chat-messages button[phx-value-message]))
      assert present?(html, "#chat-session-ended")
      assert html =~ "This session has ended."
      assert present?(html, ~s(#chat-session-ended button[phx-click="new_chat"]))
      assert disabled?(html, ~s(textarea[name="message"]))
      refute disabled?(html, ~s(button[phx-click="new_chat"]))
    end

    test "a NON-EMPTY fetched history replaces the cached conversation on attach",
         %{conn: conn} do
      test_pid = self()
      session_id = 6_505
      attach_calls = :counters.new(1, [:atomics])
      start_calls = :counters.new(1, [:atomics])

      # The sidebar loader is independent of Watch. Advertising no live session
      # here would freeze a cached "Ended" row titled "stale cached line" if the
      # list loads before Watch replaces the transcript. All three fixtures must
      # describe the same running session, including its live sidebar title.
      install_session_seam(:home_session_list_runner, fn _node ->
        {[
           %{
             id: session_id,
             status: :running,
             agent_module: EvoGit.Agents.SelfReflective,
             parent_id: nil,
             objective: "live transcript line"
           }
         ], []}
      end)

      install_session_seam(:source_availability_runner, fn -> true end)

      install_session_seam(:home_session_start_runner, fn _node, _opts ->
        :counters.add(start_calls, 1, 1)
        {:ok, 1}
      end)

      # Keep the cache observable until both independent mount loaders settle.
      install_session_seam(:home_agent_watch_runner, fn _node, ^session_id, consumer ->
        send(test_pid, {:watch_pending, self()})

        await_snapshot_release(consumer, fn ->
          snapshot_answer(7, attach_history("live transcript line"), phase: :running).(session_id)
        end)
      end)

      install_session_seam(:home_agent_unwatch_runner, fn _node, _id, _consumer -> :ok end)

      install_session_seam(
        :home_session_attach_runner,
        counting_attach_runner(
          attach_calls,
          test_pid,
          false,
          running_attach_state(session_id, attach_history("live transcript line"))
        )
      )

      seed_cached_chat(
        session_id,
        [%{id: "u1", role: :user, text: "stale cached line", streaming: false}],
        [%{type: "user", turn: 1, data: %{content: "stale cached reasoning"}, timestamp: nil}]
      )

      {:ok, view, html} = live(conn, "/assistant?session=#{session_id}")
      monitor_watch_cleanup(view)
      assert html =~ "stale cached line"

      assert_receive {:attach_called, _node, ^session_id, _pid}, 5_000
      assert_receive {:watch_pending, watch_pid}, @async_wait_budget_ms
      await_attach_settled(view, session_id)

      wait_until(fn ->
        a = assigns(view)
        a.session_list_loading == false and a.session_list_seq >= 1
      end)

      # Exercise the formerly racy ordering: sidebar and identity arrive while
      # Watch is held, so only the conversation body still contains the cache.
      assert session_row_html(render(view), session_id) |> Floki.text() =~ "live transcript line"
      assert Enum.any?(assigns(view).transcript, &(&1.text == "stale cached line"))
      send(watch_pid, :release)
      await_stream_seeded(view, 7)
      wait_until(fn -> assigns(view).chat_status == :running end)

      a = assigns(view)
      # A fetched history ALWAYS wins over the cache, reasoning included.
      assert Enum.any?(a.transcript, &(&1.text == "live transcript line"))
      refute Enum.any?(a.transcript, &(&1.text == "stale cached line"))
      refute inspect(a.thought_process) =~ "stale cached reasoning"
      assert :counters.get(attach_calls, 1) == 1
      assert :counters.get(start_calls, 1) == 0
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

      html = await_source_available(view, true)
      assert html =~ "live transcript line"
      refute html =~ "stale cached line"
    end
  end

  describe "interactive session list (mounted)" do
    test "orders awaiting, running and cached rows and patches into a session", %{conn: conn} do
      test_pid = self()
      awaiting_id = 6_601
      running_id = 6_602
      cached_id = 6_603
      attach_calls = :counters.new(1, [:atomics])
      start_calls = :counters.new(1, [:atomics])

      install_session_seam(:home_session_list_runner, fn _node ->
        {[
           %{
             id: awaiting_id,
             status: :awaiting_input,
             agent_module: EvoGit.Agents.SelfReflective,
             parent_id: nil,
             objective: "parked objective"
           },
           %{
             id: running_id,
             status: :running,
             agent_module: EvoGit.Agents.SelfReflective,
             parent_id: nil,
             objective: "running objective"
           }
         ], [%{agent_id: awaiting_id}]}
      end)

      install_session_seam(:source_availability_runner, fn -> true end)

      install_session_seam(:home_session_start_runner, fn _node, _opts ->
        :counters.add(start_calls, 1, 1)
        {:ok, 1}
      end)

      install_session_seam(
        :home_session_attach_runner,
        counting_attach_runner(attach_calls, test_pid, false, parked_attach(cached_id))
      )

      # The synthetic parked session needs a matching authoritative Watch cut;
      # the independent attach answer alone cannot establish its idle lifecycle.
      install_snapshot_fixture(cached_id, [], :awaiting_input)

      seed_cached_chat(cached_id, [
        %{id: "u1", role: :user, text: "cached objective", streaming: false}
      ])

      {:ok, view, _html} = live(conn, "/assistant")
      wait_until(fn -> session_row_ids(render(view)) != [] end)

      html = render(view)
      assert present?(html, "#chat-session-list")
      ids = session_row_ids(html)
      # Awaiting FIRST (violet dot), then running, then the ended/cached rows.
      assert Enum.take(ids, 2) == [awaiting_id, running_id]
      assert cached_id in ids
      assert Enum.find_index(ids, &(&1 == running_id)) < Enum.find_index(ids, &(&1 == cached_id))
      assert session_row_raw(html, awaiting_id) =~ "oklch(0.68_0.17_290)"
      assert session_row_raw(html, running_id) =~ "bg-warning"
      assert session_row_raw(html, cached_id) =~ "bg-base-content/30"
      assert session_row_href(html, awaiting_id) == "/assistant?session=#{awaiting_id}"
      assert session_row_href(html, cached_id) == "/assistant?session=#{cached_id}"

      # Patching a row ADOPTS that session: ONE attach, never a new task.
      render_patch(view, "/assistant?session=#{cached_id}")
      monitor_watch_cleanup(view)
      assert_receive {:attach_called, _node, ^cached_id, _pid}, 5_000
      await_stream_seeded(view, 7)
      await_attach_settled(view, cached_id)

      wait_until(fn ->
        assigns(view).session_id == cached_id and assigns(view).chat_status == :idle
      end)

      assert :counters.get(attach_calls, 1) == 1
      assert :counters.get(start_calls, 1) == 0
      assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []
    end

    test "ignores a stale-seq or foreign-node list result and applies the current one",
         %{conn: conn} do
      install_session_seam(:home_session_list_runner, fn _node -> {[], []} end)

      {:ok, view, _html} = live(conn, "/assistant")

      wait_until(fn ->
        a = assigns(view)
        a.session_list_loading == false and a.session_list_seq >= 1
      end)

      current_seq = assigns(view).session_list_seq
      assert current_seq >= 1
      before_ids = session_row_ids(render(view))

      stale_rows = [%{id: 6_701, title: "stale row", marker: :ended}]
      foreign_rows = [%{id: 6_702, title: "foreign row", marker: :ended}]

      # `EvoDashWeb.LiveHooks.NodeAware` OWNS this load: it spawns it on mount
      # and intercepts the nested `{{:session_list_loaded, seq, node}, result}`
      # message, applying it through `SessionList.applied/4` only while seq and
      # node still match. These injections therefore exercise the HOOK's
      # guards, not a page-local apply path (the page only asks for a
      # page-local refresh after it adopts or closes a session).
      send(
        view.pid,
        {{:session_list_loaded, current_seq - 1, node()}, {:ok, {:ok, stale_rows}}}
      )

      send(
        view.pid,
        {{:session_list_loaded, current_seq, :"genesis_remote@127.0.0.1"},
         {:ok, {:ok, foreign_rows}}}
      )

      html = render(view)
      assert session_row_ids(html) == before_ids
      refute html =~ "stale row"
      refute html =~ "foreign row"

      send(
        view.pid,
        {{:session_list_loaded, current_seq, node()},
         {:ok, {:ok, [%{id: 6_703, title: "applied row", marker: :running}]}}}
      )

      wait_until(fn -> session_row_ids(render(view)) == [6_703] end)
      assert render(view) =~ "applied row"
    end

    test "session links preserve the viewed node id" do
      url = &EvoDashWeb.HomeLive.SessionActions.url/2
      assert url.(nil, nil) == "/assistant"
      assert url.(nil, 42) == "/assistant?session=42"
      assert url.("target-1", nil) == "/assistant?node=target-1"
      assert url.("target-1", 42) == "/assistant?session=42&node=target-1"
    end
  end

  describe "interactive session queue echo and interrupt" do
    test "a mid-run send is queued, echoed, and the echo is dropped on message-count growth", %{
      conn: conn
    } do
      test_pid = self()
      local_node = node()

      install_session_seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(test_pid, {:session_send_called, node, agent_id, message, policy})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      seed_session_state(view, 7001, %{
        chat_status: :running,
        agent_message_count: 2,
        transcript: [%{id: "1", role: :user, text: "first", streaming: false}]
      })

      text = "queued message"
      html = render_submit(view, "send_message", %{"message" => text})

      assert_receive {:session_send_called, ^local_node, 7001, ^text, :queue}

      # The user entry is appended immediately AND the queued echo is persisted
      # (`%{id: binary, text:, at: integer}`) and rendered under the documented
      # container/line.
      assigns = assigns(view)
      assert [echo] = assigns.queued_echoes
      assert is_binary(echo.id)
      assert echo.text == text
      assert is_integer(echo.at)
      assert Enum.any?(assigns.transcript, &(&1.role == :user and &1.text == text))
      assert html =~ ~s(id="chat-queued-echoes")
      assert html =~ ~s(id="chat-queued-echo-#{echo.id}")
      assert html =~ "Queued — sent at the next turn boundary"

      # RECONCILIATION (a): the session's message count grew, so the agent has
      # consumed the queue — the echo is dropped (assigns/1 is a synchronous
      # round-trip, so the handler has already run).
      send(view.pid, {:agent_updated, 7001, [message_count: 3], node()})
      assert assigns(view).queued_echoes == []
    end

    test "a successful Stop clears the queued echo", %{conn: conn} do
      test_pid = self()
      local_node = node()
      echo = %{id: "echo-1", text: "queued message", at: System.system_time(:millisecond)}

      install_session_seam(:home_session_close_runner, fn node, agent_id, reason ->
        send(test_pid, {:session_close_called, node, agent_id, reason})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      seed_session_state(view, 7002, %{chat_status: :running, queued_echoes: [echo]})

      render_click(view, "stop")

      # The close runs synchronously through the seam (the page is interactive
      # with a session and no task id, so Stop closes the session).
      assert_receive {:session_close_called, ^local_node, 7002, :normal}
      assert assigns(view).queued_echoes == []
    end

    test "New chat clears the queued echo", %{conn: conn} do
      echo = %{id: "echo-2", text: "queued message", at: System.system_time(:millisecond)}

      {:ok, view, _html} = live(conn, "/assistant")

      # New chat is idle-only, so the session is parked at `:idle`.
      seed_session_state(view, 7003, %{chat_status: :idle, queued_echoes: [echo]})

      render_click(view, "new_chat")

      assigns = assigns(view)
      assert assigns.queued_echoes == []
      assert assigns.session_id == nil
      assert assigns.session_mode == nil
    end

    test "interrupt_turn sends the DRAFT with the :interrupt policy and echoes it", %{
      conn: conn
    } do
      test_pid = self()
      local_node = node()

      install_session_seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(test_pid, {:session_send_called, node, agent_id, message, policy})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      seed_session_state(view, 7004, %{
        chat_status: :running,
        chat_draft: "do it now",
        agent_message_count: 1
      })

      html = render_click(view, "interrupt_turn")

      # The interrupt is NOT a queue: the running turn is pre-empted so the
      # draft reaches the agent at the next boundary, phrased as `:interrupt`.
      assert_receive {:session_send_called, ^local_node, 7004, "do it now", :interrupt}

      assigns = assigns(view)
      assert assigns.chat_draft == ""
      assert [echo] = assigns.queued_echoes
      assert echo.text == "do it now"
      assert is_binary(echo.id)
      assert is_integer(echo.at)
      assert html =~ "Queued — sent at the next turn boundary"
    end
  end

  describe "interactive session attachments" do
    test "a staged TEXT attachment rides the send as appended message text", %{conn: conn} do
      test_pid = self()
      local_node = node()
      path = write_tmp_attachment!("notes.md", "attached body text")

      install_session_seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(test_pid, {:session_send_called, node, agent_id, message, policy})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      # The REAL staging path: the native picker is disabled in tests, so the
      # pick click reports unavailable and reveals the manual-path fallback,
      # which is then submitted with a real local text file.
      render_click(view, "chat_attach", %{"kind" => "text"})
      assert assigns(view).attach_unavailable == true

      html = render_submit(view, "chat_attach_manual", %{"path" => path})
      assert EvoDashWeb.HomeLive.Attachments.count(assigns(view).pending_attachments) == 1
      # The chip renders the attached file's name.
      assert html =~ "notes.md"

      seed_session_state(view, 7070)

      render_submit(view, "send_message", %{"message" => "here it is"})
      assert_receive {:session_send_called, ^local_node, 7070, message, :queue}

      # A TEXT attachment stays OUT of the binary list: it is appended to the
      # outgoing body (so the message is still a bare binary).
      assert is_binary(message)
      assert message =~ "here it is"
      assert message =~ "## Attached file: notes.md"
      assert message =~ "attached body text"

      # Success clears the staging state.
      assert EvoDashWeb.HomeLive.Attachments.count(assigns(view).pending_attachments) == 0
    end

    test "a staged IMAGE rides the send as a message map with an attachment part", %{
      conn: conn
    } do
      test_pid = self()
      local_node = node()
      bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> "fake png payload"
      path = write_tmp_attachment!("diagram.png", bytes)

      install_session_seam(:home_session_send_runner, fn node, agent_id, message, policy ->
        send(test_pid, {:session_send_called, node, agent_id, message, policy})
        :ok
      end)

      {:ok, view, _html} = live(conn, "/assistant")

      # The picker result message is the page's real staging entry point for a
      # binary pick (`handle_attach_result/3` → `stage_binary_attachment/3`).
      send(
        view.pid,
        {:directory_picker_result, EvoDashWeb.HomeLive.Attachments.picker_id_image(), {:ok, path}}
      )

      assert assigns(view)
             |> Map.get(:pending_attachments)
             |> then(&(EvoDashWeb.HomeLive.Attachments.count(&1) == 1))

      seed_session_state(view, 7071)

      render_submit(view, "send_message", %{"message" => "look at this"})
      assert_receive {:session_send_called, ^local_node, 7071, message, :queue}

      # A binary attachment upgrades the message to the session's map shape.
      assert %{text: "look at this", attachments: [attachment]} = message
      assert attachment["type"] == "image"
      assert attachment["name"] == "diagram.png"
      assert attachment["media_type"] == "image/png"
      assert Base.decode64!(attachment["data"]) == bytes

      assert EvoDashWeb.HomeLive.Attachments.count(assigns(view).pending_attachments) == 0
    end

    test "the attachment caps refuse a 5th entry and an over-15-MiB file", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/assistant")
      attachments = EvoDashWeb.HomeLive.Attachments

      # Size cap: an image read enforces the 15 MiB per-file limit (a TEXT
      # attachment has no size cap by design, so the pin needs a binary read).
      too_big = write_tmp_attachment!("huge.png", :binary.copy(<<0>>, 15 * 1024 * 1024 + 1))

      send(view.pid, {:directory_picker_result, attachments.picker_id_image(), {:ok, too_big}})

      assert assigns(view).flash["error"] =~ "File is too large (max 15 MiB)"
      assert attachments.count(assigns(view).pending_attachments) == 0

      # Count cap: four staged files are accepted, the FIFTH is refused.
      paths =
        for index <- 1..5 do
          write_tmp_attachment!("note-#{index}.md", "body #{index}")
        end

      for path <- Enum.take(paths, 4) do
        render_submit(view, "chat_attach_manual", %{"path" => path})
      end

      assert attachments.count(assigns(view).pending_attachments) == 4

      render_submit(view, "chat_attach_manual", %{"path" => Enum.at(paths, 4)})

      assert assigns(view).flash["error"] == "Maximum of 4 attachments per message"
      assert attachments.count(assigns(view).pending_attachments) == 4
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # PUSH-ONLY agent-delta streaming (`EvoDashWeb.HomeLive.Watch` +
  # `EvoDashWeb.HomeLive.Delta`). A mounted /assistant?session=<id> page subscribes
  # ITSELF to `"agent:<id>"` (the subscription is consumer-local) and applies
  # `{:agent_delta, id, seq, batch}` broadcasts against the snapshot the
  # asynchronously registered watcher returned. The watch/unwatch runners are the
  # call-time seams `:home_agent_watch_runner` / `:home_agent_unwatch_runner`.
  # ─────────────────────────────────────────────────────────────────────────────

  # Installs every seam a mounted delta-streaming test needs: the reattach
  # suite's session-list / source-availability stubs, a PARKED attach answer (so
  # the page settles writable and cannot clobber a later status assertion), and
  # the register/unregister runners reporting into the test process.
  # `snapshot_fun` receives the agent id (and optionally the consumer pid for
  # cancellation-safe blocking fixtures) and returns the runner's flat answer.
  defp install_watch_seams(session_id, test_pid, snapshot_fun) do
    install_session_seam(:home_session_list_runner, fn _node -> {[], []} end)
    install_session_seam(:source_availability_runner, fn -> true end)

    install_session_seam(:home_session_attach_runner, fn _node, _id ->
      parked_attach(session_id)
    end)

    install_session_seam(:home_agent_watch_runner, fn node, agent_id, watcher ->
      send(test_pid, {:agent_watched, node, agent_id, watcher})

      if is_function(snapshot_fun, 2),
        do: snapshot_fun.(agent_id, watcher),
        else: snapshot_fun.(agent_id)
    end)

    install_session_seam(:home_agent_unwatch_runner, fn node, agent_id, watcher ->
      send(test_pid, {:agent_unwatched, node, agent_id, watcher})
      :ok
    end)

    :ok
  end

  # A failed assertion must not strand a serial watch worker inside its runner.
  # Consumer death releases this gate even before the test learns the worker pid.
  defp await_snapshot_release(consumer, snapshot_fun) do
    monitor = Process.monitor(consumer)

    result =
      receive do
        :release -> snapshot_fun.()
        {:DOWN, ^monitor, :process, ^consumer, _reason} -> {:error, :consumer_down}
      after
        @async_wait_budget_ms -> {:error, :fixture_release_timeout}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  # Lifecycle and transcript come from ONE authoritative watch cut, not the
  # independent attach loader (which supplies task identity only while watched).
  defp install_snapshot_fixture(session_id, messages, phase) do
    install_session_seam(:home_agent_watch_runner, fn _node, ^session_id, _consumer ->
      snapshot_answer(7, messages, phase: phase).(session_id)
    end)

    install_session_seam(:home_agent_unwatch_runner, fn _node, _id, _consumer -> :ok end)
  end

  # Registered after the seams, so ExUnit's LIFO teardown awaits the actual
  # consumer/serial worker before restoring the app-global runner callbacks.
  defp monitor_watch_cleanup(view) do
    consumer = view.pid
    worker = assigns(view).chat_stream_worker

    on_exit(fn ->
      consumer_ref = Process.monitor(consumer)
      if Process.alive?(consumer), do: Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, _}, @async_wait_budget_ms

      if is_pid(worker) do
        worker_ref = Process.monitor(worker)
        assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, @async_wait_budget_ms
      end
    end)
  end

  # The watch runner's answer: a real `%EvoGit.Agent.Stream.Snapshot{}` at `seq`.
  defp snapshot_answer(seq, messages \\ [], overrides \\ []) do
    fn agent_id ->
      snapshot =
        struct!(
          EvoGit.Agent.Stream.Snapshot,
          [agent_id: agent_id, messages: messages, seq: seq] ++ overrides
        )

      {:ok, snapshot, seq}
    end
  end

  # The core announces a fresh LLM attempt before emitting its chunks. An idle
  # snapshot has no current call, so bare text/thinking chunks are not actionable.
  defp call_started(agent_id) do
    {:activity,
     %{
       phase: :llm,
       current_call: %{
         id: "#{agent_id}-attempt-0",
         turn: 0,
         attempt: 0,
         text: "",
         thinking: ""
       }
     }}
  end

  defp broadcast_delta(agent_id, seq, batch) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      "agent:#{agent_id}",
      {:agent_delta, agent_id, seq, batch}
    )
  end

  # Polls until the page seeded its delta stream at `seq` (the snapshot landed).
  defp await_stream_seeded(view, seq) do
    wait_until(fn ->
      case assigns(view)[:chat_stream] do
        %{delta: %{seq: ^seq}} -> true
        _other -> false
      end
    end)
  end

  # One assistant message in the shape `NodeContext.get_agent_history/2` and the
  # watch snapshot return.
  defp history_assistant_message(text) do
    %ReqLLM.Message{
      role: :assistant,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: text}]
    }
  end

  # Polls until the parked session-attach answer landed (its summary task id is
  # the attach's observable marker), so a later status assertion cannot be
  # overwritten by a late attach.
  defp await_attach_settled(view, session_id) do
    wait_until(fn -> assigns(view)[:chat_task_id] == "task-#{session_id}" end)
  end

  describe "mounted watch recovery" do
    for failure <- [:timeout, :overflow, :worker_death] do
      test "#{failure} keeps the cache live until an explicit Retry adopts a new snapshot", %{
        conn: conn
      } do
        assert_watch_retry(conn, unquote(failure))
      end
    end
  end

  defp assert_watch_retry(conn, failure) do
    test_pid = self()
    session_id = System.unique_integer([:positive]) + 1_000_000_000
    attempts = :counters.new(1, [:atomics])

    thoughts = [
      %{
        type: "assistant",
        turn: 1,
        timestamp: nil,
        data: %{content: "retained recovery reasoning"}
      }
    ]

    cached = [
      %{
        id: "cached-recovery",
        role: :assistant,
        text: "retained recovery answer",
        streaming: false,
        reasoning: thoughts
      }
    ]

    install_watch_seams(session_id, test_pid, fn id, consumer ->
      :counters.add(attempts, 1, 1)
      attempt = :counters.get(attempts, 1)
      send(test_pid, {:registration_attempt, attempt, self()})

      if attempt == 1 do
        case failure do
          :timeout ->
            {:error, :timeout}

          _ ->
            # This IS the real serial registration worker, not a fabricated
            # DOWN/result message. Consumer death releases it on failed tests.
            await_snapshot_release(consumer, fn -> {:error, :timeout} end)
        end
      else
        snapshot_answer(20, [history_assistant_message("recovered authoritative answer")],
          phase: :running
        ).(id)
      end
    end)

    seed_cached_chat(session_id, cached, thoughts)
    {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")
    monitor_watch_cleanup(view)
    assert_receive {:registration_attempt, 1, worker}, @async_wait_budget_ms
    assert assigns(view).chat_stream_worker == worker
    assert_receive {:agent_watched, _node, ^session_id, consumer}, @async_wait_budget_ms
    assert consumer == view.pid
    await_attach_settled(view, session_id)

    expected_error =
      case failure do
        :timeout ->
          :timeout

        :overflow ->
          # Overflow the real pending registration buffer through subscribed
          # deltas, rather than fabricating a lifecycle/failure result.
          for seq <- 1..129, do: broadcast_delta(session_id, seq, [{:text, "buffered"}])
          wait_until(fn -> assigns(view).chat_stream.error == :watch_buffer_overflow end)
          send(worker, :release)
          :watch_buffer_overflow

        :worker_death ->
          ref = Process.monitor(worker)
          Process.exit(worker, :kill)
          assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @async_wait_budget_ms
          {:watch_worker_down, :killed}
      end

    wait_until(fn -> assigns(view).chat_stream.error == expected_error end)

    if failure != :worker_death do
      # The failed register and its queued cleanup have actually completed.
      assert_receive {:agent_unwatched, _node, ^session_id, ^consumer}, @async_wait_budget_ms
    end

    a = assigns(view)
    assert Process.alive?(view.pid)
    assert a.chat_status != :ended
    assert a.transcript == cached
    assert a.thought_process == thoughts
    html = render(view)
    assert html =~ "retained recovery answer"
    assert html =~ "retained recovery reasoning"
    assert html =~ "The conversation may still be running."
    refute present?(html, "#chat-session-ended")

    assert has_element?(
             view,
             ~s(#chat-stream-error button[phx-click="retry_chat_stream"]),
             "Retry"
           )

    # A completed failure is stable: ordinary updates and stray late chunks
    # cannot restart registration or replace the cache behind the user's back.
    send(view.pid, {:agent_updated, session_id, [message_count: 99], node()})

    send(
      view.pid,
      {:agent_delta, session_id, 19, [call_started(session_id), {:text, "ignored late"}]}
    )

    assert assigns(view).chat_stream.error == expected_error
    assert assigns(view).transcript == cached
    assert :counters.get(attempts, 1) == 1

    view
    |> element(~s(#chat-stream-error button[phx-click="retry_chat_stream"]))
    |> render_click()

    assert_receive {:registration_attempt, 2, recovered_worker}, @async_wait_budget_ms
    monitor_watch_cleanup(view)
    if failure == :worker_death, do: assert(recovered_worker != worker)
    await_stream_seeded(view, 20)
    assert assigns(view).chat_status == :running
    assert assigns(view).chat_stream.error == nil
    refute has_element?(view, "#chat-stream-error")
    assert render(view) =~ "recovered authoritative answer"
    refute render(view) =~ "retained recovery answer"

    broadcast_delta(session_id, 21, [call_started(session_id), {:text, "newer recovered delta"}])
    await_stream_seeded(view, 21)
    assert render(view) =~ "newer recovered delta"
    assert :counters.get(attempts, 1) == 2
    assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []
  end

  # Direct terminal handoff is a final atomic cut, not another asynchronous
  # history read. Keep these mounted contracts beside the push-only stream tests.
  defp terminal_chat_snapshot(session_id, seq, status \\ :completed) do
    {:ok, snapshot, ^seq} =
      snapshot_answer(
        seq,
        [
          %ReqLLM.Message{
            role: :assistant,
            content: [
              %ReqLLM.Message.ContentPart{
                type: :thinking,
                text: "authoritative terminal thinking"
              },
              %ReqLLM.Message.ContentPart{type: :text, text: "authoritative terminal answer"}
            ],
            reasoning_details: [
              %ReqLLM.Message.ReasoningDetails{text: "authoritative terminal thinking", index: 0}
            ]
          }
        ],
        phase: :done
      ).(session_id)

    Map.put(snapshot, :status, status)
  end

  defp assert_terminal_chat(view, snapshot, status) do
    a = assigns(view)
    closed? = EvoDashWeb.HomeLive.Watch.closed?(%{assigns: a})
    assert closed?
    assert a.chat_stream.closed_seq == snapshot.seq
    assert a.chat_stream.error == nil
    assert a.chat_status == :ended
    assert a.chat_task_status == status
    assert a.agent_message_count == length(snapshot.messages)
    assert a.queued_echoes == []

    assert [%{role: :assistant, text: "authoritative terminal answer", streaming: false} = reply] =
             a.transcript

    assert a.thought_process == EvoDashWeb.HomeLive.Messages.to_entries(snapshot.messages)
    assert inspect(reply.reasoning) =~ "authoritative terminal thinking"
    html = render(view)
    assert html =~ "authoritative terminal answer"
    assert html =~ "authoritative terminal thinking"
    refute present?(html, ".help-caret")
    refute present?(html, "#chat-stream-error")
    assert disabled?(html, ~s(textarea[name="message"]))
    assert EvoDash.ChatHistory.get_state(a.chat_id).transcript == a.transcript
    a
  end

  describe "mounted authoritative terminal handoff" do
    for status <- [:completed, :failed, :cancelled] do
      test "#{status} closure replaces partial text/thinking and stays closed after removal", %{
        conn: conn
      } do
        test_pid = self()
        session_id = System.unique_integer([:positive]) + 1_000_000_000
        watches = :counters.new(1, [:atomics])
        history_reads = :counters.new(1, [:atomics])

        install_watch_seams(session_id, test_pid, fn id ->
          :counters.add(watches, 1, 1)
          snapshot_answer(7, [], phase: :running).(id)
        end)

        install_session_seam(:home_agent_history_runner, fn _node, _id ->
          :counters.add(history_reads, 1, 1)
          [history_assistant_message("forbidden post-closure history")]
        end)

        {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")
        monitor_watch_cleanup(view)
        await_attach_settled(view, session_id)
        await_stream_seeded(view, 7)

        send(
          view.pid,
          {:agent_delta, session_id, 8,
           [
             call_started(session_id),
             {:thinking, "abandoned thinking"},
             {:text, "partial answer"}
           ]}
        )

        await_stream_seeded(view, 8)
        seed_chat_state(view, %{queued_echoes: [%{id: "terminal-echo", text: "queued", at: 0}]})

        # Equality is essential: messages may checkpoint at the finish batch's
        # existing watermark without another public delta increment.
        snapshot = terminal_chat_snapshot(session_id, 8, unquote(status))
        send(view.pid, {:agent_stream_closed, session_id, snapshot, 8})
        final = assert_terminal_chat(view, snapshot, unquote(status))
        consumer = view.pid
        local_node = node()

        assert_receive {:agent_unwatched, ^local_node, ^session_id, ^consumer},
                       @async_wait_budget_ms

        send(view.pid, {:agent_removed, session_id, node()})
        send(view.pid, {:agent_updated, session_id, [message_count: 999], node()})
        send(view.pid, {:agents_updated, node()})

        send(
          view.pid,
          {:agent_delta, session_id, 99, [call_started(session_id), {:text, "late text"}]}
        )

        send(
          view.pid,
          {:agent_stream_closed, session_id, terminal_chat_snapshot(session_id, 100, :failed),
           100}
        )

        render_click(view, "retry_chat_stream")
        settled = assert_terminal_chat(view, snapshot, unquote(status))
        assert settled.transcript == final.transcript
        assert settled.chat_fetch_seq == final.chat_fetch_seq
        assert settled.stream_attach_seq == final.stream_attach_seq
        assert :counters.get(watches, 1) == 1
        assert :counters.get(history_reads, 1) == 0

        # Even an actual registration-worker death after cleanup cannot turn
        # the authoritative terminal view into a retryable watch error.
        worker = settled.chat_stream_worker
        ref = Process.monitor(worker)
        Process.exit(worker, :kill)
        assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @async_wait_budget_ms
        wait_until(fn -> assigns(view).chat_stream_worker == nil end)
        assert_terminal_chat(view, snapshot, unquote(status))
        assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []
      end
    end

    for result <- [:success, :failure] do
      test "closure wins over a late #{result} from the actual final-snapshot worker", %{
        conn: conn
      } do
        test_pid = self()
        session_id = System.unique_integer([:positive]) + 1_000_000_000
        attempts = :counters.new(1, [:atomics])

        install_watch_seams(session_id, test_pid, fn id, consumer ->
          :counters.add(attempts, 1, 1)

          if :counters.get(attempts, 1) == 1 do
            snapshot_answer(7, [], phase: :running).(id)
          else
            send(test_pid, {:final_snapshot_blocked, self()})

            await_snapshot_release(consumer, fn ->
              case unquote(result) do
                :success ->
                  snapshot_answer(9, [history_assistant_message("obsolete async answer")],
                    phase: :awaiting_input
                  ).(id)

                :failure ->
                  {:error, {:not_found, :session_not_found}}
              end
            end)
          end
        end)

        {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")
        monitor_watch_cleanup(view)
        await_attach_settled(view, session_id)
        await_stream_seeded(view, 7)
        send(view.pid, {:agent_delta, session_id, 8, [{:finished, :completed}]})
        assert_receive {:final_snapshot_blocked, worker}, @async_wait_budget_ms
        assert assigns(view).chat_stream.final_resync == :pending
        assert assigns(view).chat_stream_worker == worker

        snapshot = terminal_chat_snapshot(session_id, 8)
        send(view.pid, {:agent_stream_closed, session_id, snapshot, 8})
        final = assert_terminal_chat(view, snapshot, :completed)
        send(worker, :release)
        consumer = view.pid
        assert_receive {:agent_unwatched, _node, ^session_id, ^consumer}, @async_wait_budget_ms
        # The worker sends ready BEFORE servicing unregister. Its own mailbox
        # barrier proves that result was sent; the view round-trip drains it.
        wait_until(fn -> assigns(view).chat_stream.token == final.chat_stream.token end)
        assert_terminal_chat(view, snapshot, :completed)
        assert :counters.get(attempts, 1) == 2
        refute render(view) =~ "obsolete async answer"
      end
    end

    test "closure during registration respects buffered sequence and survives a late missing-session answer",
         %{
           conn: conn
         } do
      test_pid = self()
      session_id = System.unique_integer([:positive]) + 1_000_000_000

      install_watch_seams(session_id, test_pid, fn _id, consumer ->
        send(test_pid, {:initial_snapshot_blocked, self()})
        await_snapshot_release(consumer, fn -> {:error, {:not_found, :session_not_found}} end)
      end)

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")
      monitor_watch_cleanup(view)
      assert_receive {:initial_snapshot_blocked, worker}, @async_wait_budget_ms
      await_attach_settled(view, session_id)

      send(
        view.pid,
        {:agent_delta, session_id, 11, [call_started(session_id), {:text, "buffered suffix"}]}
      )

      assert length(assigns(view).chat_stream.pending) == 1
      assert assigns(view).chat_stream.delta == nil

      # A cut older than a buffered batch is not authoritative for this view.
      send(
        view.pid,
        {:agent_stream_closed, session_id, terminal_chat_snapshot(session_id, 10), 10}
      )

      assert assigns(view).chat_stream.closed_seq == nil
      assert length(assigns(view).chat_stream.pending) == 1

      snapshot = terminal_chat_snapshot(session_id, 11)
      send(view.pid, {:agent_stream_closed, session_id, snapshot, 11})
      assert_terminal_chat(view, snapshot, :completed)
      assert assigns(view).chat_stream.pending == []
      send(worker, :release)
      consumer = view.pid
      assert_receive {:agent_unwatched, _node, ^session_id, ^consumer}, @async_wait_budget_ms
      assert_terminal_chat(view, snapshot, :completed)
      refute render(view) =~ "buffered suffix"
    end

    test "stale sequences, foreign agents and an old node scope cannot close the current chat", %{
      conn: conn
    } do
      session_id = System.unique_integer([:positive]) + 1_000_000_000
      install_watch_seams(session_id, self(), snapshot_answer(7, [], phase: :running))
      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")
      monitor_watch_cleanup(view)
      await_attach_settled(view, session_id)
      await_stream_seeded(view, 7)

      send(
        view.pid,
        {:agent_delta, session_id, 8, [call_started(session_id), {:text, "current answer"}]}
      )

      await_stream_seeded(view, 8)
      before = assigns(view)

      send(view.pid, {:agent_stream_closed, session_id, terminal_chat_snapshot(session_id, 7), 7})

      send(
        view.pid,
        {:agent_stream_closed, session_id + 1, terminal_chat_snapshot(session_id + 1, 20), 20}
      )

      send(
        view.pid,
        {:agent_stream_closed, session_id, terminal_chat_snapshot(session_id + 1, 20), 20}
      )

      send(
        view.pid,
        {:agent_stream_closed, session_id, terminal_chat_snapshot(session_id, 20), 19}
      )

      a = assigns(view)
      assert a.transcript == before.transcript
      assert a.chat_status == :running
      refute EvoDashWeb.HomeLive.Watch.closed?(%{assigns: a})

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: "terminal-remote",
          name: "Terminal Remote"
        })

      start_supervised!(
        {EvoDashWeb.HomeLiveTest.ConnectionManager,
         {"terminal-remote",
          %{phase: :connected, node: "terminal_remote@127.0.0.1", last_error: nil}}}
      )

      render_patch(view, "/assistant?node=terminal-remote")
      assert assigns(view).current_node == :"terminal_remote@127.0.0.1"
      remote = assigns(view)

      send(
        view.pid,
        {:agent_stream_closed, session_id, terminal_chat_snapshot(session_id, 30), 30}
      )

      a = assigns(view)
      assert a.chat_id == remote.chat_id
      assert a.transcript == remote.transcript
      assert a.chat_status == remote.chat_status
      refute EvoDashWeb.HomeLive.Watch.closed?(%{assigns: a})
    end
  end

  describe "push-only delta streaming" do
    test "a published delta updates a mounted page", %{conn: conn} do
      test_pid = self()
      session_id = 7_101
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, watcher}, 5_000
      await_stream_seeded(view, 7)

      # Only the SUBSCRIBER receives this: the LiveView itself subscribed (the
      # watcher registration task did not), which is what proves the
      # consumer-local half of the attach.
      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "streamed line"}])

      wait_until(fn ->
        a = assigns(view)
        is_map(a[:chat_stream]) and a.chat_stream.delta.seq == 8
      end)

      assert assigns(view).chat_stream.delta.seq == 8
      assert render(view) =~ "streamed line"
      assert is_pid(watcher)
    end

    test "stale deltas are dropped and a newer one still applies", %{conn: conn} do
      test_pid = self()
      session_id = 7_102
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)
      transcript_before = assigns(view).transcript

      # `seq <= snapshot.seq` is stale: both are dropped. `render/1` processes
      # them first (they were delivered synchronously into the LiveView mailbox
      # by the broadcast), so the assertions below are not racing a mailbox.
      # The marker is a PHRASE, not a bare word: the app layout renders plain
      # HTML comments (e.g. “stale-guarded by …”) into every page's shell, so a
      # single-word marker would match the shell instead of the transcript.
      stale_marker = "stale delta payload"
      broadcast_delta(session_id, 7, [call_started(session_id), {:text, stale_marker}])
      broadcast_delta(session_id, 3, [call_started(session_id), {:text, stale_marker}])
      html = render(view)

      refute html =~ stale_marker
      assert assigns(view).transcript == transcript_before
      assert assigns(view).chat_stream.delta.seq == 7

      # ...while a genuinely newer seq IS applied on the SAME page.
      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "fresh"}])
      wait_until(fn -> assigns(view).chat_stream.delta.seq == 8 end)

      assert render(view) =~ "fresh"
      refute render(view) =~ stale_marker

      # A replay of an already-applied chunk would duplicate text if the seq
      # guard failed, even though the call identity itself is unchanged.
      transcript_after = assigns(view).transcript
      broadcast_delta(session_id, 8, [{:text, "fresh"}])
      render(view)
      assert assigns(view).transcript == transcript_after
      assert assigns(view).chat_stream.delta.seq == 8
    end

    test "a delta for another agent is dropped", %{conn: conn} do
      test_pid = self()
      session_id = 7_103
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      # Deliver on the subscribed topic with the WRONG payload identity: merely
      # publishing to another topic would test PubSub routing, not this guard.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "agent:#{session_id}",
        {:agent_delta, session_id + 100, 99, [call_started(session_id + 100), {:text, "foreign"}]}
      )

      html = render(view)

      refute html =~ "foreign"
      assert assigns(view).chat_stream.delta.seq == 7

      # The page IS attached — its OWN agent's delta applies — so the drop above
      # was the agent match, not a dead stream.
      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "own line"}])
      wait_until(fn -> assigns(view).chat_stream.delta.seq == 8 end)

      html = render(view)
      assert html =~ "own line"
      refute html =~ "foreign"
    end

    test "the attach snapshot seeds the transcript and the thought process", %{conn: conn} do
      test_pid = self()
      session_id = 7_104

      messages = [
        %ReqLLM.Message{
          role: :assistant,
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "snapshot line"}]
        }
      ]

      install_watch_seams(session_id, test_pid, snapshot_answer(7, messages))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)
      wait_until(fn -> Enum.any?(assigns(view).transcript, &(&1.text == "snapshot line")) end)

      a = assigns(view)
      assert Enum.any?(a.transcript, &(&1.role == :assistant and &1.text == "snapshot line"))
      # `apply_history/3` is the ONE funnel: the snapshot's messages rebuild BOTH
      # halves, so the thought process is exactly `Messages.to_entries/1`'s.
      assert a.thought_process == EvoDashWeb.HomeLive.Messages.to_entries(messages)
      assert render(view) =~ "snapshot line"
    end

    test "thinking and tool deltas reach the thought process and the transcript", %{conn: conn} do
      test_pid = self()
      session_id = 7_105
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      broadcast_delta(session_id, 8, [
        call_started(session_id),
        {:thinking, "pondering"},
        {:tool_call, "call-1", "bash"}
      ])

      wait_until(fn -> Enum.any?(assigns(view).transcript, &(&1.role == :tool)) end)
      wait_until(fn -> inspect(assigns(view).thought_process) =~ "pondering" end)

      assert render(view) =~ "bash"
      assert [thought] = assigns(view).thought_process
      assert thought.data.metadata == %{thinking: true, call_id: "#{session_id}-attempt-0"}
      assert [%{text: "pondering", type: "thinking"}] = thought.data.reasoning_details
      assert Enum.filter(assigns(view).transcript, &(&1.role == :assistant)) == []

      broadcast_delta(session_id, 9, [{:tool_result, "call-1", :ok}])

      wait_until(fn ->
        Enum.any?(assigns(view).transcript, &(&1.role == :tool and &1.tool_status == :ok))
      end)

      tool = Enum.find(assigns(view).transcript, &(&1.role == :tool))
      assert tool.tool_name == "bash"
      assert tool.tool_status == :ok
      assert tool.tool_call_id == "call-1"
    end

    test "a turn delta updates the meta line under the assistant bubble", %{conn: conn} do
      test_pid = self()
      session_id = 7_106
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      # A streaming assistant bubble must exist for the meta line to render
      # (it rides the transcript's LAST assistant entry).
      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "partial"}])
      wait_until(fn -> Enum.any?(assigns(view).transcript, &(&1.role == :assistant)) end)

      broadcast_delta(
        session_id,
        9,
        [{:turn, %{turn: 2, total_tokens: 1234, duration_ms: 1500, usage: nil}}]
      )

      wait_until(fn -> assigns(view).chat_stream_meta.total_tokens == 1234 end)

      assert assigns(view).chat_stream_meta.turn == 2
      assert assigns(view).chat_stream_meta.duration_ms == 1500

      html = render(view)
      assert html =~ "1234"
      assert html =~ "Turn 2"
    end

    test "a yield finalizes the bubble and parks the session", %{conn: conn} do
      test_pid = self()
      session_id = 7_107
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_attach_settled(view, session_id)
      await_stream_seeded(view, 7)

      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "partial"}])

      wait_until(fn ->
        case List.last(assigns(view).transcript) do
          %{role: :assistant, streaming: true} -> true
          _other -> false
        end
      end)

      broadcast_delta(session_id, 9, [{:yield, "final answer"}])

      wait_until(fn -> assigns(view).chat_status == :idle and last_bubble_final?(view) end)

      a = assigns(view)
      assert a.chat_status == :idle
      assert a.chat_task_status == :awaiting_input
      last = List.last(a.transcript)
      assert last.role == :assistant
      assert last.text == "final answer"
      assert last.streaming == false
      refute Enum.any?(a.transcript, &Map.get(&1, :streaming))

      html = await_source_available(view, true)
      refute disabled?(html, ~s(textarea[name="message"]))
      assert html =~ "final answer"
    end

    test "a finished delta ends the session without a stuck streaming bubble", %{conn: conn} do
      test_pid = self()
      session_id = 7_108
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_attach_settled(view, session_id)
      await_stream_seeded(view, 7)

      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "partial"}])
      wait_until(fn -> Enum.any?(assigns(view).transcript, &Map.get(&1, :streaming)) end)

      broadcast_delta(session_id, 9, [{:finished, :failed}])

      wait_until(fn -> assigns(view).chat_status == :ended end)

      a = assigns(view)
      assert a.chat_status == :ended
      assert a.chat_task_status == :failed
      refute Enum.any?(a.transcript, &Map.get(&1, :streaming))
    end

    test "a watched session does not refetch history on message-count changes", %{conn: conn} do
      test_pid = self()
      session_id = 7_109
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_attach_settled(view, session_id)
      await_stream_seeded(view, 7)

      # A queued echo is the observable half of the `drop_echoes` behaviour.
      seed_chat_state(view, %{queued_echoes: [%{id: "echo-1", text: "queued", at: 0}]})
      fetch_seq_before = assigns(view).chat_fetch_seq

      send(view.pid, {:agent_updated, session_id, [message_count: 5], node()})
      render(view)

      a = assigns(view)
      # The stream drives the transcript: NO history refetch was spawned...
      assert a.chat_fetch_seq == fetch_seq_before
      # ...while the echo bookkeeping still happens.
      assert a.queued_echoes == []
    end

    test "new chat detaches the delta stream", %{conn: conn} do
      test_pid = self()
      session_id = 7_110
      local_node = node()
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      render_click(view, "new_chat")

      assert_receive {:agent_unwatched, ^local_node, ^session_id, pid}, 5_000
      assert is_pid(pid)
      assert assigns(view).chat_stream == nil
      assert assigns(view).session_id == nil
    end

    test "a text → tool_call → text → turn turn renders ONE assistant bubble", %{conn: conn} do
      test_pid = self()
      session_id = 7_111
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      broadcast_delta(session_id, 8, [
        call_started(session_id),
        {:text, "first"},
        {:tool_call, "c1", "bash"}
      ])

      wait_until(fn -> Enum.any?(assigns(view).transcript, &(&1.role == :tool)) end)

      broadcast_delta(session_id, 9, [{:text, " second"}, {:tool_result, "c1", :ok}])
      wait_until(fn -> assigns(view).chat_stream.delta.seq == 9 end)

      broadcast_delta(session_id, 10, [{:turn, %{turn: 1, total_tokens: 5, duration_ms: 10}}])
      wait_until(fn -> assigns(view).chat_stream.delta.seq == 10 end)

      transcript = assigns(view).transcript

      assert [%{role: :assistant, text: "first second", streaming: false}] =
               Enum.filter(transcript, &(&1.role == :assistant))

      assert [tool] = Enum.filter(transcript, &(&1.role == :tool))
      assert tool.tool_call_id == "c1"
      assert tool.tool_status == :ok
      # The text after the tool call landed in the SAME bubble, never in a
      # second one and never in an empty one.
      refute Enum.any?(transcript, &(&1.role == :assistant and &1.text == ""))

      assert render(view) =~ "first second"
    end

    test "a thinking-only turn leaves no empty assistant bubble", %{conn: conn} do
      test_pid = self()
      session_id = 7_112
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      broadcast_delta(session_id, 8, [
        call_started(session_id),
        {:thinking, "pondering"},
        {:turn, %{turn: 1}}
      ])

      wait_until(fn ->
        assigns(view).chat_stream.delta.seq == 8 and
          inspect(assigns(view).thought_process) =~ "pondering"
      end)

      refute Enum.any?(assigns(view).transcript, &(&1.role == :assistant))
      assert inspect(assigns(view).thought_process) =~ "pondering"
    end

    test "chat_stream_ready preserves an in-flight streaming bubble", %{conn: conn} do
      test_pid = self()
      session_id = 7_113
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      # Registration is held while newer batches buffer. The cut includes the
      # captured prefix of the CURRENT call alongside checkpointed history.
      install_session_seam(:home_agent_watch_runner, fn _node, agent_id, consumer ->
        send(test_pid, {:watch_pending, self()})

        await_snapshot_release(consumer, fn ->
          {:activity, activity} = call_started(agent_id)
          activity = put_in(activity.current_call.text, "in-flight reply")

          snapshot_answer(7, [history_assistant_message("from history")],
            phase: :running,
            activity: activity
          ).(agent_id)
        end)
      end)

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:watch_pending, watch_pid}, 5_000
      await_attach_settled(view, session_id)

      broadcast_delta(session_id, 8, [{:text, " plus suffix"}])
      wait_until(fn -> length(assigns(view).chat_stream.pending) == 1 end)
      assert assigns(view).chat_stream.delta == nil
      send(watch_pid, :release)

      await_stream_seeded(view, 8)
      wait_until(fn -> is_map(assigns(view).chat_stream_meta) end)

      a = assigns(view)
      assert Enum.any?(a.transcript, &(&1.text == "in-flight reply plus suffix" and &1.streaming))
      assert Enum.any?(a.transcript, &(&1.text == "from history" and not &1.streaming))
      assert render(view) =~ "in-flight reply plus suffix"
      assert length(Enum.filter(a.transcript, &String.contains?(&1.text, "in-flight reply"))) == 1
      assert a.chat_stream.delta.seq == 8
      assert a.agent_message_count == 1
    end

    test "a finished delta with no streamed text resyncs the authoritative snapshot once", %{
      conn: conn
    } do
      test_pid = self()
      session_id = 7_114
      watches = :counters.new(1, [:atomics])

      install_watch_seams(session_id, test_pid, fn agent_id ->
        :counters.add(watches, 1, 1)

        if :counters.get(watches, 1) == 1 do
          snapshot_answer(7).(agent_id)
        else
          snapshot_answer(8, [history_assistant_message("final reply from history")],
            phase: :done
          ).(agent_id)
        end
      end)

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_attach_settled(view, session_id)
      await_stream_seeded(view, 7)

      install_session_seam(:home_agent_history_runner, fn _node, _agent_id ->
        send(test_pid, :history_fetched)
        [history_assistant_message("final reply from history")]
      end)

      # NO text before the finish: the final attempt's chunks were suppressed.
      # Recovery must use a new atomic cut, never independent history.
      broadcast_delta(session_id, 8, [{:finished, :completed}])

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, @async_wait_budget_ms

      wait_until(fn ->
        Enum.any?(assigns(view).transcript, &(&1.text == "final reply from history"))
      end)

      reply = Enum.find(assigns(view).transcript, &(&1.text == "final reply from history"))
      assert reply.role == :assistant
      assert reply.streaming == false
      assert assigns(view).chat_status == :ended

      # EXACTLY one atomic reconciliation — never a fetch loop or a legacy read.
      assert :counters.get(watches, 1) == 2
      refute_receive :history_fetched, 0
    end

    test "streamed text suppresses the finished refresh", %{conn: conn} do
      test_pid = self()
      session_id = 7_115
      install_watch_seams(session_id, test_pid, snapshot_answer(7))

      {:ok, view, _html} = live(conn, "/assistant?session=#{session_id}")

      assert_receive {:agent_watched, _node, ^session_id, _watcher}, 5_000
      await_stream_seeded(view, 7)

      install_session_seam(:home_agent_history_runner, fn _node, _agent_id ->
        send(test_pid, :history_fetched)
        []
      end)

      broadcast_delta(session_id, 8, [call_started(session_id), {:text, "streamed"}])
      wait_until(fn -> Enum.any?(assigns(view).transcript, &(&1.text == "streamed")) end)

      broadcast_delta(session_id, 9, [{:turn, %{turn: 1}}])
      wait_until(fn -> assigns(view).chat_stream.delta.seq == 9 end)

      broadcast_delta(session_id, 10, [{:finished, :completed}])
      wait_until(fn -> assigns(view).chat_status == :ended end)

      refute_receive :history_fetched, 300

      assert [%{role: :assistant, text: "streamed", streaming: false}] =
               Enum.filter(assigns(view).transcript, &(&1.role == :assistant))
    end
  end

  # The transcript's last entry is a FINALIZED assistant bubble.
  defp last_bubble_final?(view) do
    case List.last(assigns(view).transcript) do
      %{role: :assistant, streaming: false} -> true
      _other -> false
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
