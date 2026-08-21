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
  # spawn that `start_task/2` triggers) and registers on_exit delete. Lets a
  # test prove that an unrelated pre-existing row is untouched by an event.
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

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.Store.delete_task(EvoGit.Store, id)
      rescue
        _ -> :ok
      end
    end)

    id
  end

  # Cancels + deletes a launched reflect task in on_exit so its persisted row
  # (and any still-running wrapper) never leaks into other tests. The reflect
  # task runs the REAL runtime — with no LLM credentials it fails fast after
  # retries, with the user's real config its agent may block on an LLM slot —
  # so the cancel is what unblocks/cleans it up regardless of which happened.
  defp cleanup_task_on_exit(task_id) do
    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.TaskRegistry.cancel_task(task_id)
      rescue
        _ -> :ok
      end

      try do
        EvoGit.TaskRegistry.delete_task(task_id)
      rescue
        _ -> :ok
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
      [{_tag, attrs, _children} | _] -> Keyword.has_key?(attrs, "disabled")
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

      # Optimistic UI: the user bubble + an empty streaming assistant bubble
      # (pulsing dots), status :running.
      assert assigns(view).chat_status == :running
      assert html =~ "hello genesis"
      assert html =~ "animate-bounce"

      task_id = chat_task_id(view)
      assert is_binary(task_id)
      assert Regex.match?(~r/^[0-9a-f]{16}$/, task_id)
      cleanup_task_on_exit(task_id)

      # While running: the input + Send are disabled, New chat is disabled
      # (idle-only), Stop is enabled.
      assert disabled?(html, ~s(textarea[name="message"]))
      assert disabled?(html, ~s(button[type="submit"]))
      assert disabled?(html, ~s(button[phx-click="new_chat"]))
      refute disabled?(html, ~s(button[phx-click="stop"]))

      # The persisted row: repo-less reflect task with the FIRST message as the
      # bare objective, mode "reflect", and NO :path key (atom or string).
      task = EvoGit.TaskRegistry.get_task(task_id)
      assert task != nil
      assert task.type == :reflect
      assert opt(task, :mode) == "reflect"
      assert opt(task, :objective) == "hello genesis"
      assert opt(task, :path) == nil
      refute has_opt?(task, :path)
      refute has_opt?(task, "path")
    end

    test "second message carries the transcript preamble", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_submit(view, "send_message", %{"message" => "hello"})
      first_id = chat_task_id(view)
      cleanup_task_on_exit(first_id)

      # Drive back to :idle deterministically (the real reflect-task lifecycle
      # is async and out of scope): the :failed terminal event finalizes the
      # streaming bubble and clears the task refs.
      finalize_failed(view, first_id)
      assert assigns(view).chat_status == :idle

      # Sanity-pin the single-user-entry preamble shape (the objective's exact
      # expectation for a fresh transcript).
      {:ok, hand_built} =
        EvoDashWeb.HomeLive.Transcript.build_preamble([
          %{id: "1", role: :user, text: "hello", streaming: false}
        ])

      assert hand_built == "Previous conversation:\nUser: hello\n"

      # Compute the expected objective via the EXACT code path HomeLive uses at
      # send time (build_preamble on the LIVE transcript) — robust to whatever
      # text the :failed finalization wrote into the assistant bubble.
      {:ok, preamble} = EvoDashWeb.HomeLive.Transcript.build_preamble(assigns(view)[:transcript])

      render_submit(view, "send_message", %{"message" => "what is genesis?"})
      second_id = chat_task_id(view)
      cleanup_task_on_exit(second_id)

      second_task = EvoGit.TaskRegistry.get_task(second_id)
      assert second_task != nil
      assert opt(second_task, :objective) == preamble <> "New message: what is genesis?"
    end

    test "whitespace-only message is a no-op", %{conn: conn} do
      # Seed an unrelated task to prove the empty submit creates NO new row.
      fixture_id = insert_task_fixture!(opts: [path: "/tmp/test", objective: "fixture"])

      {:ok, view, html} = live(conn, "/")

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
      task_id = chat_task_id(view)
      cleanup_task_on_exit(task_id)

      # While running, New chat is disabled (idle-only action).
      assert disabled?(render(view), ~s(button[phx-click="new_chat"]))

      # Drive to :idle, then New chat re-enables and resets everything.
      finalize_failed(view, task_id)
      refute disabled?(render(view), ~s(button[phx-click="new_chat"]))

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

  # --- PART 2 (appended by a follow-up executor) ---
  # Remaining describes go BELOW this line: streaming, completion/error,
  # stop/cancel, and node-awareness. Reuse the helpers above.
end
