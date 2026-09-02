# HomeLive (chat page) test suite.
#
# Covers the idle render, the send-message flow (real reflect tasks against
# the isolated Store+TaskRegistry), new-chat + ChatHistory store semantics,
# the onboarding dead-render redirect, streaming display (REAL-shaped core
# payloads: integer agent ids, KEYWORD-LIST changed_fields, real
# %ReqLLM.Message{} structs), completion/error rendering, the assistant
# task-card (status badge + thought process), chat persistence/restore across
# remounts, the production-mimicking crash-reproduction flow, sidebar
# robustness, stop/cancel, and node-awareness.
#
# EvoDash.ChatHistory is PROCESS-SHARED (a global GenServer under
# EvoDash.Application that survives the per-test Store/TaskRegistry isolation
# below), so the setup calls EvoDash.ChatHistory.reset() — chats never leak
# across tests. The module is async: false for the same reason (shared store
# + shared scheduler ETS tables).
defmodule EvoDashWeb.HomeLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  setup do
    # Isolated Store + TaskRegistry (pattern from tasks_live_test): terminate
    # the production children so this suite uses fresh temp sqlite stores and
    # the reflect tasks started by send_message never leak into other suites.
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_home_live_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    # ChatHistory is a global GenServer under EvoDash.Application that is NOT
    # terminated by the Store/TaskRegistry isolation above — reset it so the
    # chats persisted by one test never leak into the next (the
    # node_aware_test.exs / chat_history_test.exs convention).
    EvoDash.ChatHistory.reset()

    # Onboarding (pattern from projects_live_test.set_onboarding_completed):
    # isolate XDG_CONFIG_HOME to a temp dir and mark onboarding complete so the
    # HomeLive dead render does NOT redirect first-time users to /welcome. The
    # "onboarding redirect" describe re-isolates to a fresh empty dir in its
    # own test body.
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_home_live_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)

      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        File.rm_rf(root)
      rescue
        _ -> :ok
      end

      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
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

  # The chat task id the view is currently tracking (nil when idle).
  defp chat_task_id(view), do: assigns(view)[:chat_task_id]

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

  # Cancels + deletes a launched reflect task in on_exit so its persisted row
  # (and any still-running wrapper) never leaks into other tests. The reflect
  # task runs the REAL runtime — with no LLM credentials it fails fast after
  # retries, with the user's real config its agent may block on an LLM slot —
  # so the cancel is what unblocks/cleans it up regardless of which happened.
  # Additionally sweeps the agent's scheduler ETS rows (cancel/delete do not
  # remove them), so the blocked agent cannot leak into agents_live_test.exs
  # (which expects an empty agent registry).
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

  # Polls `fun` every 10ms until it returns truthy (or the timeout elapses) —
  # the tasks_live_test.exs pattern for observing async results (the real
  # supervised fetches, the 300ms PubSub debounce) without fixed sleeps.
  defp wait_until(fun, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for async condition")
        else
          Process.sleep(10)
          wait_loop.(wait_loop)
        end
      end
    end

    wait_loop.(wait_loop)
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

      assert html =~ "Chat with Genesis"
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

    test "empty state renders the greeting and four suggestion chips", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/help")

      # ChatGPT-style empty state: greeting + 4 suggestion chips, each wired to
      # the send_message event with its message text as the phx-value (so
      # clicking a chip submits it through the existing handle_event clause).
      assert html =~ "How can I help you today?"

      chips =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s(button[phx-click="send_message"][phx-value-message]))

      assert length(chips) == 4

      assert html =~ ~s(phx-value-message="Explain the Genesis architecture")
      assert html =~ ~s(phx-value-message="How does task cancellation work?")
      assert html =~ ~s(phx-value-message="What can you help me with?")
      assert html =~ ~s(phx-value-message="Guide me through the dashboard")
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
    test "starts a reflect task with the right opts", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      html = render_submit(view, "send_message", %{"message" => "hello genesis"})

      # Optimistic UI: the user bubble appears immediately. (The real reflect
      # task fails FAST in the test env — no LLM config — so chat_status may
      # already be back at :idle by the time render_submit returns; never
      # assert running-only state synchronously after a real send.)
      assert html =~ "hello genesis"

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
      cleanup_task_on_exit(task.id)
    end

    test "real send sets chat_task_id and renders no task-start error (regression)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      html = render_submit(view, "send_message", %{"message" => "hello genesis"})

      # The real send flow sets chat_task_id synchronously in send_chat/2, so it
      # is readable immediately after render_submit returns. Regression: passing
      # the bare %EvoGit.TaskInfo{} struct (instead of {:ok, task}) to
      # AgentStream.task_id_from_start/1 fell through to {:error, :no_task_id},
      # leaving chat_task_id nil and rendering the error bubble even though the
      # reflect task DID start.
      task_id = chat_task_id(view)
      assert is_binary(task_id)

      # The reflect task started — the error bubble must NOT appear.
      refute html =~ "Failed to start the task"

      # The tracked id must be the persisted reflect task's id.
      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      assert hd(reflect).id == task_id

      cleanup_task_on_exit(task_id)
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

      render_submit(view, "send_message", %{"message" => "what is genesis?"})

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)

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

    test "typed send renders the right-aligned soft user bubble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      html = render_submit(view, "send_message", %{"message" => "typed hi"})
      assert html =~ "typed hi"

      {wrapper_class, bubble_class} = first_user_bubble(html)

      # Right-aligned wrapper around a content-fit bubble.
      assert wrapper_class =~ "flex justify-end"

      # The DaisyUI theme-token bubble (bg-base-300/text-base-content read
      # correctly in both light and dark themes), text left-aligned inside.
      assert bubble_class =~ "w-fit"
      assert bubble_class =~ "bg-base-300"
      assert bubble_class =~ "text-left"
      refute bubble_class =~ "bg-primary"

      reflect =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      assert reflect != []
      cleanup_task_on_exit(hd(reflect).id)
    end

    test "suggestion-chip send renders the same user bubble classes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      # Chips render only while the transcript is empty — click the REAL chip
      # element (phx-click="send_message" + phx-value-message); both routes
      # share the send_chat path and must produce the same user bubble.
      html =
        view
        |> element(~s(button[phx-value-message="Explain the Genesis architecture"]))
        |> render_click()

      assert html =~ "Explain the Genesis architecture"

      {wrapper_class, bubble_class} = first_user_bubble(html)
      assert wrapper_class =~ "flex justify-end"
      assert bubble_class =~ "w-fit"
      assert bubble_class =~ "bg-base-300"
      assert bubble_class =~ "text-left"
      refute bubble_class =~ "bg-primary"

      reflect =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      assert reflect != []
      cleanup_task_on_exit(hd(reflect).id)
    end
  end

  describe "new chat" do
    test "resets the chat to the idle empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")

      render_submit(view, "send_message", %{"message" => "hello"})

      # ALWAYS register the ETS sweep — the reflect agent may remain
      # alive/blocked in the scheduler ETS even after the task itself fails
      # fast: the `:failed` task event clears the view's chat_task_id (and the
      # status goes :idle) while the agent row persists as :running. Gating the
      # cleanup on chat_task_id would skip it exactly when the agent is still
      # registered, leaking the row into agents_live_test.exs (which expects an
      # empty agent registry). The persisted reflect row's id is authoritative
      # (the sched_meta task_id is the same string).
      reflect =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      if reflect != [] do
        cleanup_task_on_exit(hd(reflect).id)
      end

      # The real reflect task fails fast in the test env (no LLM config), so it
      # may already have cleared the task refs by the time render_submit
      # returns. Branch on that: nil → already :idle; otherwise inject a
      # deterministic :failed terminal event to drive it back to :idle.
      case chat_task_id(view) do
        nil ->
          :ok

        id ->
          finalize_failed(view, id)
      end

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

      render_submit(view, "send_message", %{"message" => "hello"})

      # Deterministically drive the chat to a terminal state (same branch as
      # the reset test above).
      case chat_task_id(view) do
        nil -> :ok
        id -> finalize_failed(view, id)
      end

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
      # The setup completed onboarding under ITS temp XDG_CONFIG_HOME. Re-isolate
      # to a brand-new empty temp dir here so VersionState's path-keyed
      # :persistent_term cache re-reads from disk, finds no version-state file,
      # and reports onboarding_needed?() == true again.
      tmp_config =
        Path.join(
          System.tmp_dir!(),
          "evogit_home_live_onboarding_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_config)
      original = System.get_env("XDG_CONFIG_HOME")
      System.put_env("XDG_CONFIG_HOME", tmp_config)

      on_exit(fn ->
        if original do
          System.put_env("XDG_CONFIG_HOME", original)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf!(tmp_config)
      end)

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

      html = render(view)
      assert html =~ "Genesis is an Elixir framework."
      assert html =~ "Thought process"

      # Double agent_removed (the core's recycling emits TWO) — no-op.
      send(view.pid, {:agent_removed, 1, node()})
      send(view.pid, {:agent_removed, 1, node()})

      html = render(view)
      assert html =~ "Chat with Genesis"
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
    # reads Map.get(task, :status)/:result, so a plain map works.
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
  end

  describe "assistant task-card" do
    test "status badge attaches to the last assistant entry and tracks task events", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/help")
      seed_running_chat(view)
      # Before any task event there is no badge (chat_task_status nil).
      html = render(view)
      refute html =~ "Pending"
      # :pending → "Pending" badge appears on the card header.
      send(view.pid, {:task_updated, "t1", :pending, node()})
      html = render(view)
      assert html =~ "Pending"
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
      # Assistant entry: thinking-part text + reasoning details.
      assert html =~ "let me inspect the source"
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
      render_submit(view, "send_message", %{"message" => "persist me please"})
      # ALWAYS register the cleanup for the real reflect task (see the
      # "new chat" describe for the rationale).
      reflect =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      if reflect != [] do
        cleanup_task_on_exit(hd(reflect).id)
      end

      # Deterministically drive the chat to a terminal state.
      case chat_task_id(view) do
        nil -> :ok
        id -> finalize_failed(view, id)
      end

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

  describe "model selector" do
    # Writes a config.toml with a single model profile into the test's isolated
    # XDG_CONFIG_HOME (set per test by the file-level setup) so
    # ModelSelect.load/1 — called from mount's assign_model_select — sees a
    # profile to render and pin. Pattern copied from projects_live_test.exs
    # ("model selection auto/lock semantics" describe): EvoGit.Config caches by
    # config_path, and the per-test fresh XDG_CONFIG_HOME makes the path unique
    # so the new file is re-read.
    defp write_model_profile_config do
      config_path = EvoGit.Config.config_path()
      File.mkdir_p!(Path.dirname(config_path))

      File.write!(config_path, """
      [[llm.models]]
      id = "profile-a"
      model = {provider = "anthropic", id = "claude-sonnet-5"}
      concurrency = 3
      """)
    end

    test "selector renders in the header with a profile and an Auto option", %{conn: conn} do
      write_model_profile_config()

      {:ok, view, html} = live(conn, "/help")

      # The header select is form-less (OUTSIDE #chat-form), so its id travels
      # via a bare phx-change — asserted through the select's own attributes.
      assert present?(html, ~s(select[name="model_id"][phx-change="select_chat_model"]))

      options =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s(select[name="model_id"] option))

      # Auto option: value="" + selected while nothing is pinned (nil → Auto).
      # No [model_selection] script is configured in this config, so
      # model_selection_enabled is false and the label is the plain "Auto" —
      # "Auto (by rules)" is script-only.
      auto = Enum.find(options, fn {_, attrs, _} -> {"value", ""} in attrs end)
      assert auto != nil
      {_tag, auto_attrs, _children} = auto
      assert {"selected", ""} in auto_attrs
      assert Floki.text(auto) |> String.trim() == "Auto"
      refute html =~ "Auto (by rules)"

      # One option per configured profile (value = the profile id).
      assert Enum.any?(options, fn {_, attrs, _} -> {"value", "profile-a"} in attrs end)

      # The loaded assigns back the UI (no script → model_selection_enabled
      # false, exactly like ProjectsLive without a script).
      assert assigns(view)[:model_profiles] != []
      assert assigns(view)[:model_selection_enabled] == false
    end

    test "selector is absent when no model profiles are configured", %{conn: conn} do
      # NO config written — the fresh empty XDG_CONFIG_HOME dir means
      # ModelSelect.load/1 sees zero profiles. The contract renders the select
      # hidden/absent when @model_profiles == [] (there is nothing to choose).
      {:ok, _view, html} = live(conn, "/help")

      refute present?(html, ~s(select[name="model_id"]))
    end

    test "pinned model threads :model_id + :model_id_locked into the reflect task", %{
      conn: conn
    } do
      write_model_profile_config()

      {:ok, view, _html} = live(conn, "/help")

      # Pick a profile via the header select's phx-change. The contract
      # normalizes the id (non-empty binary → itself) and persists it into
      # ChatHistory so it survives remounts.
      render_change(view, "select_chat_model", %{"model_id" => "profile-a"})
      assert assigns(view)[:selected_model_id] == "profile-a"

      html = render_submit(view, "send_message", %{"message" => "hello"})
      assert html =~ "hello"

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)

      # The pinned id threads BOTH keys. String-key checks: :model_id /
      # :model_id_locked are NOT in the codec's @known_opt_keys whitelist, so
      # the round-tripped opts decode them as STRING keys (same as
      # projects_live_test.exs "model selection auto/lock semantics"). mode /
      # objective ARE whitelisted → atom keys.
      assert opt(task, "model_id") == "profile-a"
      assert opt(task, "model_id_locked") == true
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "hello"
      refute has_opt?(task, :path)
      refute has_opt?(task, "path")

      cleanup_task_on_exit(task.id)
    end

    test "Auto (no pinned model) threads neither model key", %{conn: conn} do
      # No model selected — this test mounts with NO config written, so there
      # is nothing to select and the send must thread only the plain reflect
      # opts (mode + objective).
      {:ok, view, _html} = live(conn, "/help")

      html = render_submit(view, "send_message", %{"message" => "auto please"})
      assert html =~ "auto please"

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)

      # Auto (nil/absent) → NEITHER :model_id NOR :model_id_locked is threaded
      # (string or atom key) — the runtime's model-selection script (or the
      # default model) decides. Refute the atom forms too so a future codec
      # whitelist addition can't silently break the contract. mode / objective
      # ARE whitelisted codec atoms → atom keys here.
      refute has_opt?(task, "model_id")
      refute has_opt?(task, "model_id_locked")
      refute has_opt?(task, :model_id)
      refute has_opt?(task, :model_id_locked)
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "auto please"

      cleanup_task_on_exit(task.id)
    end

    test "pinned model survives a remount via ChatHistory", %{conn: conn} do
      write_model_profile_config()

      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_chat_model", %{"model_id" => "profile-a"})
      assert assigns(view)[:selected_model_id] == "profile-a"

      # "Close the page" (stop the view process) and remount: attach_chat
      # restores the CURRENT chat — including the pinned model (the
      # select_chat_model handler persisted it via ChatHistory).
      GenServer.stop(view.pid)
      {:ok, view2, _html} = live(conn, "/help")
      assert assigns(view2)[:selected_model_id] == "profile-a"
    end

    test "suggestion-chip send threads the pinned model exactly like a typed submit", %{
      conn: conn
    } do
      write_model_profile_config()

      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_chat_model", %{"model_id" => "profile-a"})
      assert assigns(view)[:selected_model_id] == "profile-a"

      # Chips render only while the transcript is empty (fresh mount) — click
      # the REAL chip element. Both send routes share the same
      # handle_event("send_message", %{"message" => text}) clause → send_chat/2
      # → ModelSelect.task_opts/2, so the pinned id must thread EXACTLY like
      # the typed-submit test above.
      html =
        view
        |> element(~s(button[phx-value-message="Explain the Genesis architecture"]))
        |> render_click()

      assert html =~ "Explain the Genesis architecture"

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)

      # String-key checks: :model_id / :model_id_locked are NOT codec-whitelisted
      # (round-trip as STRING keys); mode / objective ARE → atom keys.
      assert opt(task, "model_id") == "profile-a"
      assert opt(task, "model_id_locked") == true
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "Explain the Genesis architecture"
      refute has_opt?(task, :path)
      refute has_opt?(task, "path")

      cleanup_task_on_exit(task.id)
    end

    test "suggestion-chip send on Auto threads neither model key", %{conn: conn} do
      # No config written — nothing to pin, the chip send must thread only the
      # plain reflect opts (mode + objective).
      {:ok, view, _html} = live(conn, "/help")

      html =
        view
        |> element(~s(button[phx-value-message="What can you help me with?"]))
        |> render_click()

      assert html =~ "What can you help me with?"

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)

      # Auto (nil/absent) → NEITHER :model_id NOR :model_id_locked is threaded
      # (string or atom key). Refute the atom forms too so a future codec
      # whitelist addition can't silently break the contract.
      refute has_opt?(task, "model_id")
      refute has_opt?(task, "model_id_locked")
      refute has_opt?(task, :model_id)
      refute has_opt?(task, :model_id_locked)
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "What can you help me with?"

      cleanup_task_on_exit(task.id)
    end

    test "pinned model survives a new chat and threads into the next send", %{conn: conn} do
      write_model_profile_config()

      {:ok, view, _html} = live(conn, "/help")

      # A fresh first-ever mount (no restored chat) starts on Auto — only
      # base_assigns/0 seeds selected_model_id (nil).
      assert assigns(view)[:selected_model_id] == nil

      render_change(view, "select_chat_model", %{"model_id" => "profile-a"})
      assert assigns(view)[:selected_model_id] == "profile-a"
      old_chat_id = assigns(view).chat_id
      assert old_chat_id != nil

      # New chat while idle: the transcript resets but the PIN survives —
      # reset_chat/0 deliberately does not clear selected_model_id, and
      # start_new_chat/1 persists the fresh empty chat carrying the pinned id.
      html = render_click(view, "new_chat", %{})
      assert html =~ "Start a conversation"
      new_chat_id = assigns(view).chat_id
      assert new_chat_id != old_chat_id
      assert assigns(view).transcript == []
      assert assigns(view)[:selected_model_id] == "profile-a"

      # The next (typed) send threads the surviving pin into the reflect task.
      render_submit(view, "send_message", %{"message" => "after new chat"})

      tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
      reflect = Enum.filter(tasks, &(&1.type == :reflect))
      assert length(reflect) == 1
      task = hd(reflect)

      assert opt(task, "model_id") == "profile-a"
      assert opt(task, "model_id_locked") == true
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
      assert html =~ "Chat with Genesis"
      send(view.pid, {:agent_updated, agent_id, [message_count: 2], node()})
      html = render(view)
      assert html =~ "Chat with Genesis"

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
      assert html =~ "Chat with Genesis"
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
      assert html =~ "Chat with Genesis"
      wait_until(fn -> assigns(view).chat_status == :idle end)
      html = render(view)
      assert html =~ "final reflect answer"
      assert html =~ "Completed"
      assert assigns(view).chat_task_id == nil
    end
  end

  describe "sidebar robustness" do
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
      # Let the 300ms debounce fire and the async sidebar fetch complete.
      Process.sleep(600)
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
      Process.sleep(600)
      html = render(view)
      assert html =~ "Chat with Genesis"
    end

    test "nil-status (review-mutation) broadcast is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      seed_running_chat(view)
      send(view.pid, {:task_updated, "t1", nil, node()})
      html = render(view)
      assert html =~ "Chat with Genesis"
      assert assigns(view).chat_status == :running
      assert assigns(view).chat_task_id == "t1"
      assert assigns(view).chat_task_status == nil
    end

    test "real send through the real TaskRegistry survives the full lifecycle", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help")
      html = render_submit(view, "send_message", %{"message" => "hello real lifecycle"})
      assert html =~ "hello real lifecycle"
      # Let the real wrapper run/fail-fast + broadcasts + the 300ms debounce.
      Process.sleep(1500)
      html = render(view)
      assert html =~ "Chat with Genesis"

      reflect =
        EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
        |> Enum.filter(&(&1.type == :reflect))

      assert reflect != []
      cleanup_task_on_exit(hd(reflect).id)
    end
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

  describe "node-awareness" do
    # The file-level setup already isolates XDG_CONFIG_HOME per test, so saving
    # a dedicated target here never touches the developer's real config. The
    # fake connection manager (defined below the module) makes
    # ?node=test-remote resolve to a connected remote BEAM node. async: false
    # is already set at the module level.
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

    test "send routes through NodeContext to the remote and fails fast", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/help?node=test-remote")
      html = render_submit(view, "send_message", %{"message" => "hi remote"})
      # The synchronous :erpc to the nonexistent remote BEAM node fails fast →
      # error bubble + back to :idle; NO row is created in the LOCAL store.
      assert html =~ "Failed to start the task"
      assert assigns(view).chat_status == :idle
      assert length(EvoGit.Store.safe_select_all_tasks(EvoGit.Store)) == 0
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

    test "pinned model survives a node switch", %{conn: conn} do
      write_model_profile_config()

      # Mount LOCAL first and pin a profile via the header select.
      {:ok, view, _html} = live(conn, "/help")
      render_change(view, "select_chat_model", %{"model_id" => "profile-a"})
      assert assigns(view)[:selected_model_id] == "profile-a"
      local_chat_id = assigns(view).chat_id
      assert local_chat_id != nil

      # Switch to the remote node: handle_params starts a NEW persisted chat
      # (node change), but reset_chat/0 does NOT clear the pinned model — the
      # selected_model_id assign must survive. Assert the ASSIGN, not the
      # rendered select: on the unreachable remote node ModelSelect.load
      # degrades to {[], false} so the header select is absent.
      html = render_patch(view, "/help?node=test-remote")
      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      assert html =~ "Start a conversation"
      assert assigns(view).chat_id != local_chat_id
      assert assigns(view)[:selected_model_id] == "profile-a"

      # Back to local: profiles reload (assign_model_select for the local
      # node) and the pin is still there.
      html = render_patch(view, "/help")
      assert assigns(view).current_node == node()
      assert html =~ "Start a conversation"
      assert assigns(view)[:selected_model_id] == "profile-a"
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
