# HomeLive (chat page) test suite — PART 1 of 2.
#
# This part covers the module skeleton, the isolated Store+TaskRegistry setup,
# the shared helpers, and the four "easy" describes: render (idle page), send
# message (reflect task opts), new chat (reset), and the onboarding dead-render
# redirect. A follow-up executor appends the remaining describes (streaming,
# completion/error, stop/cancel, node-awareness) BELOW the marker at the bottom
# of this file, reusing the helpers in the `# --- helpers ---` section.
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

  describe "render" do
    test "renders the idle chat page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

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
  end

  describe "send message" do
    test "starts a reflect task with the right opts", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

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

    test "second message carries the transcript preamble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

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

      {:ok, view, _html} = live(conn, "/")

      html = render_submit(view, "send_message", %{"message" => "   "})

      # No optimistic bubbles, no task, still idle.
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      assert html =~ "Start a conversation"
      assert EvoGit.TaskRegistry.get_task(fixture_id) != nil
      assert length(EvoGit.Store.safe_select_all_tasks(EvoGit.Store)) == 1
    end
  end

  describe "new chat" do
    test "resets the chat to the idle empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_submit(view, "send_message", %{"message" => "hello"})

      # The real reflect task fails fast in the test env (no LLM config), so it
      # may already have cleared the task refs by the time render_submit
      # returns. Branch on that: nil → already :idle; otherwise inject a
      # deterministic :failed terminal event to drive it back to :idle.
      case chat_task_id(view) do
        nil ->
          :ok

        id ->
          cleanup_task_on_exit(id)
          finalize_failed(view, id)
      end

      assert assigns(view).chat_status == :idle

      html = render_click(view, "new_chat", %{})
      assert html =~ "Start a conversation"
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
      refute disabled?(html, ~s(button[type="submit"]))
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

      assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, "/")
    end
  end

  # --- PART 2 ---
  # Streaming, completion/error, stop/cancel, and node-awareness describes.
  # Reuse the helpers above.

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
      chat_agent_id: "agent-1",
      transcript: [
        %{id: "1", role: :user, text: "hello", streaming: false},
        %{id: "2", role: :assistant, text: "", streaming: true}
      ]
    })
  end

  describe "streaming display" do
    test "assistant text from the history fetch appears in the bubble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, "agent-1",
         [%{role: :assistant, content: [%{text: "Genesis responds"}]}]}
      )

      html = render(view)
      assert html =~ "Genesis responds"
      assert assigns(view).agent_message_count == 1
      assert assigns(view).chat_status == :running
    end

    test "agent_registered sets the chat agent and triggers the history fetch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

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
        {:agent_registered, "agent-1",
         %{task_id: "t1", message_count: 1, agent_module: EvoGit.Agents.SelfReflective}, node()}
      )

      render(view)
      assert assigns(view).chat_agent_id == "agent-1"

      # agent_registered spawned a REAL async history fetch (bumping
      # chat_fetch_seq); it returns [] for the fake agent id, which is harmless.
      # Inject the manual result with the CURRENT seq (read dynamically — never
      # hardcode).
      seq = assigns(view)[:chat_fetch_seq]

      send(
        view.pid,
        {:chat_history_loaded, node(), seq, "agent-1",
         [%{role: :assistant, content: [%{text: "Genesis responds"}]}]}
      )

      html = render(view)
      assert html =~ "Genesis responds"
    end

    test "foreign-node events are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      seq = assigns(view)[:chat_fetch_seq]
      seed_running_chat(view)

      send(
        view.pid,
        {:chat_history_loaded, :other@host, seq, "agent-1",
         [%{role: :assistant, content: [%{text: "NOPE"}]}]}
      )

      send(view.pid, {:agent_updated, "agent-1", [:message_count], :other@host})

      send(
        view.pid,
        {:agent_registered, "agent-9", %{task_id: "t1", message_count: 1}, :other@host}
      )

      html = render(view)
      refute html =~ "NOPE"

      # Transcript unchanged: user bubble + still-streaming empty assistant
      # bubble; the foreign agent_registered never set chat_agent_id.
      assert assigns(view).chat_agent_id == "agent-1"
      assert assigns(view).agent_message_count == nil

      assert [%{role: :user, text: "hello"}, %{role: :assistant, text: "", streaming: true}] =
               assigns(view).transcript
    end
  end

  describe "completion / error rendering" do
    # Each test drives finalize_terminal via an injected {:chat_task_loaded, ...}
    # with the CURRENT chat_task_fetch_seq (read dynamically). The handler only
    # reads Map.get(task, :status)/:result, so a plain map works.
    test "completed task with a result renders the final answer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

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

    test "completed task without a result renders No response", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

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
      {:ok, view, _html} = live(conn, "/")

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
      {:ok, view, _html} = live(conn, "/")

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
      {:ok, view, _html} = live(conn, "/")

      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(view.pid, {:chat_task_loaded, node(), seq, "t1", %{status: :cancelled, result: nil}})

      html = render(view)
      assert html =~ "Stopped."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "deleted task renders the conversation-deleted marker", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      seq = assigns(view)[:chat_task_fetch_seq]
      seed_running_chat(view)

      send(view.pid, {:chat_task_loaded, node(), seq, "t1", nil})

      html = render(view)
      assert html =~ "The conversation was deleted."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "failed task event finalizes the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      seed_running_chat(view)
      send(view.pid, {:task_updated, "t1", :failed, node()})
      html = render(view)

      assert html =~ "The task failed."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end

    test "task deleted event finalizes the transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      seed_running_chat(view)
      send(view.pid, {:task_deleted, "t1", node()})
      html = render(view)

      assert html =~ "The conversation was deleted."
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
    end
  end

  describe "stop / cancel flow" do
    test "stop cancels a pending task and finalizes it", %{conn: conn} do
      fixture_id = insert_task_fixture!(status: :pending)

      {:ok, view, _html} = live(conn, "/")

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
      {:ok, view, _html} = live(conn, "/")

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
      {:ok, view, _html} = live(conn, "/?node=test-remote")

      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"
      assert assigns(view).current_node_id == "test-remote"
    end

    test "send routes through NodeContext to the remote and fails fast", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?node=test-remote")

      html = render_submit(view, "send_message", %{"message" => "hi remote"})

      # The synchronous :erpc to the nonexistent remote BEAM node fails fast →
      # error bubble + back to :idle; NO row is created in the LOCAL store.
      assert html =~ "Failed to start the task"
      assert assigns(view).chat_status == :idle
      assert length(EvoGit.Store.safe_select_all_tasks(EvoGit.Store)) == 0
    end

    test "node switch resets the chat and local events are ignored remotely", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?node=test-remote")
      assert assigns(view).current_node == :"genesis_remote@127.0.0.1"

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

      # Patching back to "/" (no ?node=) switches to local → reset_chat.
      html = render_patch(view, "/")
      assert assigns(view).current_node == node()
      assert html =~ "Start a conversation"
      assert assigns(view).chat_status == :idle
      assert assigns(view).chat_task_id == nil
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
