defmodule EvoGit.TaskControl.ObservationTest do
  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.{AgentSpec, TaskInfo}
  alias EvoGit.TaskControl.Observation

  setup do
    for table <- [:evogit_sched_meta, :evogit_agent_state] do
      if :ets.whereis(table) == :undefined,
        do: :ets.new(table, [:named_table, :set, :public])
    end

    task_id = "observation-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for {id, meta} <- :ets.tab2list(:evogit_sched_meta), meta.task_id == task_id do
        :ets.delete(:evogit_sched_meta, id)
        :ets.delete(:evogit_agent_state, id)
      end
    end)

    {:ok, task: %TaskInfo{id: task_id, status: :running, started_at: DateTime.utc_now()}}
  end

  test "reports only this task's actual scheduler state and excludes private context", %{
    task: task
  } do
    id =
      put_agent(task.id, :waiting,
        turn: 4,
        total_tokens: 120,
        compression_count: 2,
        context: %ReqLLM.Context{
          messages: [%ReqLLM.Message{role: :user, content: "PRIVATE HISTORY"}]
        },
        pending_user_messages: ["PRIVATE MESSAGE"],
        repo_notes: "PRIVATE NOTES"
      )

    other_id = put_agent("other-task", :running)

    on_exit(fn ->
      :ets.delete(:evogit_sched_meta, other_id)
      :ets.delete(:evogit_agent_state, other_id)
    end)

    snapshot =
      Observation.snapshot(%{task | opts: [prompt: "PRIVATE PROMPT"], logs: ["PRIVATE LOG"]})

    assert snapshot.scheduler_available
    assert snapshot.registered_agent_count == 1
    assert snapshot.agent_status_counts == %{"waiting" => 1}

    assert [
             %{
               id: ^id,
               status: "waiting",
               depth: 1,
               model_id: "test-model",
               objective: "Implement task behavior",
               activity: activity
             }
           ] = snapshot.agents

    assert activity.turn == 4
    assert activity.message_count == 1
    assert activity.total_tokens == 120
    assert activity.compression_count == 2
    assert activity.retries == 0
    assert is_nil(activity.current_commit)
    assert {:ok, json} = Jason.encode(snapshot)
    refute json =~ "PRIVATE"
    refute Map.has_key?(snapshot, :completion_percent)
    refute Map.has_key?(snapshot, :stalled)
  end

  test "keeps terminal elapsed duration fixed and distinguishes empty live state", %{task: task} do
    snapshot =
      Observation.snapshot(%{
        task
        | status: :completed,
          started_at: ~U[2026-01-01 00:00:00Z],
          finished_at: ~U[2026-01-01 00:01:30Z],
          agent_count: 3,
          result: %{answer: "private result"}
      })

    assert snapshot.elapsed_seconds == 90
    assert snapshot.registered_agent_count == 0
    assert snapshot.agents == []
    assert snapshot.agent_status_counts == %{}
    assert snapshot.saved_state.status == "completed"
    assert snapshot.saved_state.agent_count == 3
    assert snapshot.saved_state.has_result
    refute Jason.encode!(snapshot) =~ "private result"
  end

  test "change token ignores observation time but changes with real activity and saved state", %{
    task: task
  } do
    id = put_agent(task.id, :running, turn: 1)
    before = Observation.snapshot(task)
    Process.sleep(1_050)
    later = Observation.snapshot(task)
    assert later.elapsed_seconds > before.elapsed_seconds
    assert later.change_token == before.change_token

    [{^id, state}] = :ets.lookup(:evogit_agent_state, id)
    :ets.insert(:evogit_agent_state, {id, %{state | turn: 2}})
    changed = Observation.snapshot(task)
    refute changed.change_token == before.change_token

    refute Observation.snapshot(%{task | status: :finalizing}).change_token ==
             changed.change_token

    refute Observation.snapshot(%{task | result: %{value: 1}}).change_token ==
             changed.change_token

    assert byte_size(changed.change_token) == 64
  end

  test "bounds agent and objective output while counting every matching agent", %{task: task} do
    for _ <- 1..35, do: put_agent(task.id, :running, objective: String.duplicate("界", 2_000))
    snapshot = Observation.snapshot(task)

    assert snapshot.registered_agent_count == 35
    assert snapshot.agent_status_counts == %{"running" => 35}
    assert length(snapshot.agents) <= 20
    assert snapshot.agents_omitted == 35 - length(snapshot.agents)
    assert Enum.all?(snapshot.agents, &(String.length(&1.objective) <= 240))
    assert {:ok, _} = Jason.encode(snapshot)
  end

  test "reports unavailable scheduler tables without inferring task completion" do
    # A fresh VM exercises missing app-owned ETS tables without deleting the
    # global tables used by this VM's application and other test modules.
    ebin = Observation |> :code.which() |> List.to_string() |> Path.dirname()

    code = """
    result = EvoGit.TaskControl.Observation.snapshot(%EvoGit.TaskInfo{id: "absent", status: :running})
    unless result.scheduler_available == false and result.registered_agent_count == 0 and
           result.saved_state.status == "running" and is_nil(result.elapsed_seconds), do: raise("bad snapshot")
    """

    assert {_, 0} =
             System.cmd("elixir", ["--erl", "+S 2:2", "-pa", ebin, "-e", code],
               stderr_to_stdout: true
             )
  end

  test "does not invent activity for agents still awaiting dispatch", %{task: task} do
    id = put_agent(task.id, :pending)
    :ets.delete(:evogit_agent_state, id)

    assert [%{status: "pending", model_id: nil, activity: activity}] =
             Observation.snapshot(task).agents

    assert is_nil(activity.turn)
    assert activity.message_count == 0
    assert activity.total_tokens == 0
  end

  test "degrades malformed unrelated scheduler metadata without changing saved task status", %{
    task: task
  } do
    id = System.unique_integer([:positive])
    :ets.insert(:evogit_sched_meta, {id, %{task_id: "unrelated-malformed-task"}})

    try do
      snapshot = Observation.snapshot(task)

      refute snapshot.scheduler_available
      assert snapshot.registered_agent_count == 0
      assert snapshot.agents == []
      assert snapshot.saved_state.status == "running"
      refute Map.has_key?(snapshot, :stalled)
      refute Map.has_key?(snapshot, :completion_percent)
    after
      :ets.delete(:evogit_sched_meta, id)
    end
  end

  test "does not advance a terminal task's duration without a recorded finish", %{task: task} do
    snapshot = Observation.snapshot(%{task | status: :cancelled, finished_at: nil})
    assert is_nil(snapshot.elapsed_seconds)
  end

  test "detects activity changes in agents omitted from the displayed list", %{task: task} do
    ids = for _ <- 1..25, do: put_agent(task.id, :running, turn: 1)
    before = Observation.snapshot(task)
    hidden_id = Enum.max(ids)
    refute Enum.any?(before.agents, &(&1.id == hidden_id))
    [{^hidden_id, state}] = :ets.lookup(:evogit_agent_state, hidden_id)
    :ets.insert(:evogit_agent_state, {hidden_id, %{state | turn: 2}})

    after_change = Observation.snapshot(task)
    assert after_change.agents == before.agents
    refute after_change.change_token == before.change_token
  end

  defp put_agent(task_id, status, fields \\ []) do
    id = System.unique_integer([:positive])

    spec = %AgentSpec{
      context_node: nil,
      phylo_node: nil,
      agent_module: __MODULE__,
      objective: "Implement task behavior"
    }

    meta = %SchedMeta{id: id, depth: 1, spec: spec, task_id: task_id, status: status}

    state =
      struct!(
        AgentState,
        Keyword.merge(
          [
            context_node: nil,
            llm_model: "test:model",
            max_retries: 3,
            max_depth: 3,
            model_id: "test-model",
            objective: spec.objective
          ],
          fields
        )
      )

    :ets.insert(:evogit_sched_meta, {id, meta})
    :ets.insert(:evogit_agent_state, {id, state})
    id
  end
end
