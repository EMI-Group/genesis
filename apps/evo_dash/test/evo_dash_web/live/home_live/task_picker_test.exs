defmodule EvoDashWeb.HomeLive.TaskPickerTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias EvoDashWeb.HomeLive.{TaskPicker, TaskTracking}

  setup do
    EvoDash.Test.IsolatedTaskStore.isolate!("task_picker")
    EvoDash.Test.ConfigDir.isolate!("task_picker")
    EvoGit.Config.VersionState.complete_onboarding()
    EvoDash.ChatHistory.reset()
    :ok
  end

  test "opening lists real task names and selecting one follows without typing an ID", %{
    conn: conn
  } do
    insert("choose-me", "Improve assistant task selection", "/tmp/genesis", :prompt)
    {:ok, view, _} = live(conn, "/assistant")
    view |> element("#assistant-task-menu-trigger") |> render_click()
    await(view, &has_element?(&1, "#assistant-task-choice-choose-me"))

    assert has_element?(
             view,
             "#assistant-task-choice-choose-me",
             "Improve assistant task selection"
           )

    assert has_element?(view, "#assistant-task-choice-choose-me", "genesis")
    view |> element("#assistant-task-choice-choose-me") |> render_click()
    await(view, &has_element?(&1, "#assistant-task-choose-me"))
    assert has_element?(view, "#assistant-task-choice-choose-me[disabled]", "Following")
    assert has_element?(view, "#assistant-task-by-id #assistant-follow-task")
  end

  test "search filters before pagination and load more keeps earlier choices", %{conn: conn} do
    for i <- 1..23, do: insert("picker-#{i}", "Searchable task #{i}", "/tmp/project")
    insert("other", "Unrelated", "/tmp/other")
    {:ok, view, _} = live(conn, "/assistant")
    render_click(view, "assistant_task_picker_open")
    await(view, &has_element?(&1, "#assistant-task-more"))
    assert length(state(view).task_picker.rows) == 20
    view |> element("#assistant-task-more") |> render_click()
    await(view, &(length(state(&1).task_picker.rows) == 24))
    view |> form("#assistant-task-search", %{query: "Unrelated"}) |> render_change()
    await(view, &(state(&1).task_picker.loading == false))
    assert has_element?(view, "#assistant-task-choice-other")
    refute has_element?(view, "#assistant-task-more")
    assert length(state(view).task_picker.rows) == 1
    view |> form("#assistant-task-search", %{query: "missing-name"}) |> render_change()
    await(view, &(state(&1).task_picker.loading == false))
    assert has_element?(view, "#assistant-task-choices", "No matching tasks")
  end

  test "pending remote never offers local tasks and new chat invalidates an old result", %{
    conn: conn
  } do
    insert("local-only", "Local task", "/tmp/local")
    {:ok, view, _} = live(conn, "/assistant")

    :sys.replace_state(view.pid, fn state ->
      %{
        state
        | socket:
            Phoenix.Component.assign(state.socket,
              current_node: node(),
              current_node_id: "pending-remote"
            )
      }
    end)

    render_click(view, "assistant_task_picker_open")
    await(view, &(state(&1).task_picker.loading == false))
    assert has_element?(view, "#assistant-task-choices", "Could not load tasks")
    refute has_element?(view, "#assistant-task-choice-local-only")
    assert TaskPicker.fetch({:unavailable, 12}, "", 0) == {:error, :not_connected}

    old = state(view).task_picker
    render_click(view, "new_chat")

    send(
      view.pid,
      {{:assistant_task_choices, old.seq, old.scope, 0},
       {:ok, {:ok, %{rows: [%{id: "stale"}], next_offset: nil}}}}
    )

    assert state(view).task_picker.rows == []
  end

  test "late searches and another node's rows cannot overwrite the current choices" do
    scope = {node(), 9}
    picker = %{TaskPicker.new(4) | scope: scope, query: "latest", loading: true}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, chat_id: 9, task_picker: picker}
    }

    result = {:ok, {:ok, %{rows: [%{id: "late"}], next_offset: nil}}}
    assert TaskPicker.apply_result(socket, 3, scope, 0, result) == socket
    assert TaskPicker.apply_result(socket, 4, {:remote, 9}, 0, result) == socket
    changed = Phoenix.Component.assign(socket, current_node: :remote)
    assert TaskPicker.view(changed.assigns).rows == []
    refute TaskPicker.view(changed.assigns).loading
    assert TaskTracking.scope(changed.assigns) == {:remote, 9}
  end

  defp insert(id, objective, path, field \\ :objective) do
    EvoGit.Store.put_task(EvoGit.Store, %EvoGit.TaskInfo{
      id: id,
      type: :genesis,
      status: :completed,
      opts: [{field, objective}, {:path, path}],
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      result: nil
    })
  end

  defp state(view), do: :sys.get_state(view.pid).socket.assigns
  defp await(view, check, left \\ 200)

  defp await(view, check, left) when left > 0 do
    if check.(view),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(view, check, left - 1)
        )
  end

  defp await(view, check, _), do: assert(check.(view))
end
