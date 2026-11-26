Code.require_file("../review_test_helper.exs", __DIR__)

defmodule EvoDashWeb.AgentsLive.TaskNavigationTest do
  # The real scheduler read-model rows are visible to every /agents mount;
  # the async AgentsLiveTest asserts on exact unfiltered lists and also
  # replaces the app-global list runner. Unique fixture IDs alone cannot isolate us.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ReviewLiveTest.ConnectionManager
  alias EvoDashWeb.TestHelpers
  alias EvoGit.{AgentSpec, Store, TaskInfo}
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.Core.{ContextNode, PhyloGraphNode}

  @async_wait_budget_ms 30_000
  @moduletag :tmp_dir

  test "the task URL filters the agent tree, and the generic Agents page keeps no task identity",
       %{
         conn: conn,
         tmp_dir: project
       } do
    first = seed_task!(project)
    second = seed_task!(project)
    root = seed_agent!(first, project)
    child = seed_agent!(first, project, root)
    other = seed_agent!(second, project)

    {:ok, view, _html} = live(conn, ~p"/agents")
    settle_agents(view)

    # Same node AND same repository: the task ID, not the project, distinguishes the agents.
    assert_generic_shell(view)
    assert_agent_cards(view, [root, child, other])

    render_patch(view, task_agents_path(first))
    settle_agents(view)
    assert_agent_cards(view, [root, child])
    assert_task_shell(view, first)
    project_name = Path.basename(project)

    assert has_element?(
             view,
             ~s(.workbench-tab-rail > .workbench-context-title[title="#{project_name}"]),
             project_name
           )

    render_patch(view, task_agents_path(second))
    settle_agents(view)
    assert_agent_cards(view, [other])
    assert_task_shell(view, second)

    render_patch(view, ~p"/agents")
    settle_agents(view)
    assert_generic_shell(view)
    assert_agent_cards(view, [root, child, other])
  end

  test "a direct link to a pending task without agents still carries that task's identity", %{
    conn: conn,
    tmp_dir: project
  } do
    pending = seed_task!(project, :pending)
    unrelated = seed_task!(project)
    seed_agent!(unrelated, project)

    {:ok, view, _html} = live(conn, task_agents_path(pending))
    settle_agents(view)

    assert has_element?(view, "#main-content h1")
    assert_task_shell(view, pending)
    assert_agent_cards(view, [])
  end

  test "switching nodes retains the task URL and does not expose local agents on the pending target",
       %{
         conn: conn,
         tmp_dir: project
       } do
    task = seed_task!(project)
    local_agent = seed_agent!(task, project)
    EvoDash.Test.ConfigDir.isolate!("agents-task-navigation")
    target = "agents-navigation-#{System.unique_integer([:positive])}"
    name = "Agents navigation target"

    assert {:ok, _} =
             EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: target, name: name})

    start_supervised!(
      {ConnectionManager, {target, %{phase: :connecting, node: nil, last_error: nil}}}
    )

    local_path = task_agents_path(task)
    {:ok, view, _html} = live(conn, local_path)
    settle_agents(view)
    assert_agent_cards(view, [local_agent])

    # This is the node selector's navigation message. Delivering it directly
    # avoids starting a real SSH connection while the target is pending.
    send(view.pid, {:node_selected, target})
    render(view)
    assert_agents_patch(view, %{"task" => task, "node" => target})
    assert has_element?(view, "#main-content p", "Connecting to #{name}…")
    assert_task_shell(view, task, target)
    assert_agent_cards(view, [])

    send(view.pid, {:node_selected, "local"})
    render(view)
    assert_agents_patch(view, %{"task" => task})
    settle_agents(view)
    assert_task_shell(view, task)
    assert_agent_cards(view, [local_agent])
  end

  defp assert_agents_patch(view, params) do
    uri = view |> assert_patch(@async_wait_budget_ms) |> URI.parse()
    assert uri.path == "/agents"
    assert URI.decode_query(uri.query || "") == params
  end

  defp task_agents_path(task), do: ~p"/agents?#{[task: task]}"

  # This is the server side of the tab contract. LiveViewTest does not run
  # the browser hook: the node/task pair here is the same pair used on Tasks
  # and Review, while the page marker identifies the current destination.
  defp assert_task_shell(view, task, node_id \\ "") do
    assert has_element?(
             view,
             ~s(#app-layout[data-workbench-page="agents"][data-workbench-node="#{node_id}"][data-workbench-task="#{task}"])
           )
  end

  defp assert_generic_shell(view) do
    assert has_element?(view, ~s(#app-layout[data-workbench-page="agents"]))
    refute has_element?(view, ~s|#app-layout[data-workbench-task]:not([data-workbench-task=""])|)

    assert has_element?(
             view,
             ~s(.workbench-tab-rail > .workbench-context-title:first-child[title="Agents"]),
             "Agents"
           )
  end

  defp assert_agent_cards(view, ids) do
    cards =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find(~s(#main-content [id^="agent-card-"]))
      |> Floki.attribute("id")

    assert Enum.sort(cards) == Enum.sort(Enum.map(ids, &"agent-card-#{&1}"))
  end

  defp settle_agents(view) do
    TestHelpers.flush_loading(
      view,
      "Loading agents…",
      "Agents tree did not finish loading",
      @async_wait_budget_ms
    )
  end

  defp seed_task!(project, status \\ :running) do
    task = "agents-task-#{System.unique_integer([:positive])}"

    assert :ok =
             Store.put_task(%TaskInfo{
               id: task,
               type: :evolve,
               status: status,
               started_at: DateTime.utc_now(),
               opts: [path: project, objective: "Inspect #{task}"]
             })

    on_exit(fn -> Store.delete_task(task) end)
    task
  end

  # Populate just the read models consumed by RemoteAPI.list_agents/0; no
  # scheduler workflow, real LLM, or agent session can start from these rows.
  defp seed_agent!(task, project, parent \\ nil) do
    id = System.unique_integer([:positive]) + 10_000_000
    context = %ContextNode{path: "./", repo: project}

    meta = %SchedMeta{
      id: id,
      depth: if(parent, do: 1, else: 0),
      parent_id: parent,
      task_id: task,
      status: :running,
      spec: %AgentSpec{
        context_node: context,
        phylo_node: %PhyloGraphNode{},
        agent_module: EvoGit.Agents.Manager,
        objective: "Fixture agent for #{task}"
      }
    }

    summary = %AgentState{
      context_node: context,
      repo_root: project,
      llm_model: "test-model",
      max_retries: 1,
      max_depth: 1
    }

    on_exit(fn ->
      :ets.delete(:evogit_sched_meta, id)
      :ets.delete(:evogit_agent_summary, id)
    end)

    :ets.insert(:evogit_sched_meta, {id, meta})
    :ets.insert(:evogit_agent_summary, {id, summary})
    id
  end
end
