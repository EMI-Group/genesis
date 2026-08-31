defmodule EvoDashWeb.HomeRepro3Test do
  # WIP throwaway repro — FINAL variant: a real %AgentState{context:
  # %ReqLLM.Context{}} row in :evogit_agent_state + a real integer-id
  # {:agent_registered, id, summary, node} broadcast → HomeLive's real
  # async_fetch_history → EvoDash.NodeContext.get_agent_history →
  # EvoGit.RemoteNode → RemoteAPI.get_agent_history (real ETS read) →
  # real %ReqLLM.Message{} structs → Messages.assistant_text →
  # Transcript.put_streaming_text. This is the exact production data path the
  # 23-test suite never exercises (the suite fakes string ids + plain-map
  # histories).
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskRegistry

  setup do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_home_repro3_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    tmp_config =
      Path.join(System.tmp_dir!(), "evogit_home_repro3_config_#{System.unique_integer([:positive])}")

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
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Genesis is an Elixir framework."}],
        metadata: nil
      }
    ]
  end

  test "REAL AgentState ETS row → real get_agent_history path through HomeLive does not crash",
       %{conn: conn} do
    agent_id = 700_000 + rem(System.unique_integer([:positive]), 100_000)
    ctx = ReqLLM.Context.new(real_history())

    state = %EvoGit.AgentScheduler.AgentState{
      context: ctx,
      context_node: %EvoGit.Core.ContextNode{path: "/tmp/x", repo: "/tmp/x"},
      llm_model: nil,
      max_retries: 1,
      max_depth: 1,
      turn: 4,
      task_local_id: 9
    }

    # (No sched_meta row needed: get_agent_history reads only :evogit_agent_state.)
    :ets.insert(:evogit_agent_state, {agent_id, state})

    on_exit(fn ->
      :ets.delete(:evogit_agent_state, agent_id)
    end)

    {:ok, view, _html} = live(conn, "/help")
    seed_running_chat(view, "t1")

    send(
      view.pid,
      {:agent_registered, agent_id,
       %{status: :pending, depth: 0, parent_id: nil, task_id: "t1", task_number: 1, objective: "hi"},
       node()}
    )

    Process.sleep(300)
    html = render(view)
    assert html =~ "Genesis is an Elixir framework."
  end
end
