defmodule EvoDashWeb.HomeRepro2Test do
  # WIP throwaway repro — pumps REAL-shaped core payloads (integer agent ids,
  # keyword-list changed_fields, real ReqLLM structs, ISO-string updated_at)
  # through the HomeLive post-send flow to find the crash the suite misses.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  setup do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_home_repro2_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})
    start_supervised({TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry})

    tmp_config =
      Path.join(System.tmp_dir!(), "evogit_home_repro2_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_config)
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original_xdg, do: System.put_env("XDG_CONFIG_HOME", original_xdg), else: System.delete_env("XDG_CONFIG_HOME")
      File.rm_rf!(tmp_config)

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

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp insert_reflect!(overrides) do
    id = "reflect_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :reflect,
        status: :running,
        opts: [mode: "reflect", objective: "New message: hi"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        project_path: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)
    id
  end

  defp seed_chat_state(view, overrides) do
    :sys.replace_state(view.pid, fn state ->
      %{state | socket: %{state.socket | assigns: Map.merge(state.socket.assigns, overrides)}}
    end)
  end

  defp seed_running_chat(view, task_id \\ "t1") do
    seed_chat_state(view, %{
      chat_status: :running,
      chat_task_id: task_id,
      chat_agent_id: nil,
      transcript: [
        %{id: "1", role: :user, text: "hello", streaming: false},
        %{id: "2", role: :assistant, text: "", streaming: true}
      ]
    })
  end

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
        reasoning_details: [
          %ReqLLM.Message.ReasoningDetails{text: "think", index: 0}
        ],
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
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Genesis is an Elixir framework."}],
        metadata: nil
      }
    ]
  end

  test "REAL-shaped agent event sequence (int ids, kw changed_fields, real structs) does not crash",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/help")
    seed_running_chat(view)

    # Real order from the core: agent_updated FIRST (agent-state insert),
    # then throttled agents_updated, then agent_registered.
    send(view.pid, {:agent_updated, 1, [total_tokens: 0, compression_count: 0, objective: "hi"], node()})
    send(view.pid, {:agents_updated, node()})
    render(view)

    send(
      view.pid,
      {:agent_registered, 1,
       %{status: :pending, depth: 0, parent_id: nil, task_id: "t1", task_number: 1, objective: "hi"},
       node()}
    )

    render(view)
    seq = assigns(view)[:chat_fetch_seq]

    send(view.pid, {:agent_updated, 1, [status: :running, worktree: "/tmp/x", task_ref: %Task{mfa: {nil, :x, []}, owner: self(), pid: self(), ref: make_ref()}], node()})
    send(view.pid, {:agent_updated, 1, [turn: 2], node()})
    send(view.pid, {:agent_updated, 1, [message_count: 3], node()})
    render(view)

    # Real history: list of real ReqLLM.Message structs (system/user/assistant
    # with :thinking parts + tool_calls + reasoning_details, metadata nil case).
    send(view.pid, {:chat_history_loaded, node(), seq, 1, real_history()})

    html = render(view)
    assert html =~ "Genesis is an Elixir framework."

    # Double agent_removed (real recycling emits TWO).
    send(view.pid, {:agent_removed, 1, node()})
    send(view.pid, {:agent_removed, 1, node()})

    html = render(view)
    assert html =~ "Chat with Genesis"
  end

  test "REAL row shape (ISO-string updated_at, lease int, agent_count 0) renders in sidebar",
       %{conn: conn} do
    id =
      insert_reflect!(
        status: :running,
        updated_at: DateTime.utc_now(),
        agent_count: 0,
        lease_expires_at: System.system_time(:second)
      )

    {:ok, view, _html} = live(conn, "/help")

    send(view.pid, {:task_updated, id, :running, node()})
    Process.sleep(600)

    html = render(view)
    assert html =~ "Active Tasks"
    assert html =~ "New message"
  end

  test "two completed tasks with nil timestamps: partition sort crash is rescued (no LV crash)",
       %{conn: conn} do
    id1 = insert_reflect!(status: :completed, started_at: nil, finished_at: nil, branch_name: "agent-x")
    id2 = insert_reflect!(status: :completed, started_at: nil, finished_at: nil, branch_name: "agent-y")

    {:ok, view, _html} = live(conn, "/help")

    send(view.pid, {:task_updated, id1, :completed, node()})
    send(view.pid, {:task_updated, id2, :completed, node()})
    Process.sleep(600)

    html = render(view)
    assert html =~ "Chat with Genesis"
  end

  test "nil-status (review-mutation) broadcast does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/help")
    seed_running_chat(view)

    send(view.pid, {:task_updated, "t1", nil, node()})
    html = render(view)
    assert html =~ "Chat with Genesis"
  end

  test "REAL send_chat through the real TaskRegistry (real wrapper + real broadcasts)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/help")

    html = render_submit(view, "send_message", %{"message" => "hello repro2"})
    assert html =~ "hello repro2"

    # Let the real wrapper run/fail-fast + broadcasts + the 300ms debounce fire.
    Process.sleep(1500)

    html = render(view)
    assert html =~ "Chat with Genesis"

    tasks = EvoGit.Store.safe_select_all_tasks(EvoGit.Store)
    reflect = Enum.filter(tasks, &(&1.type == :reflect))

    unless reflect == [] do
      task_id = hd(reflect).id

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
      end)
    end

    IO.puts("REPRO2 send_chat: reflect rows=#{length(reflect)}, chat_status=#{inspect(assigns(view)[:chat_status])}")
  end
end
