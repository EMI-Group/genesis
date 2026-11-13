defmodule EvoGit.TaskRegistry.AgentStateCascadeTest do
  @moduledoc """
  Deleting a task cascades to the task's DURABLE agent state
  (`EvoGit.AgentState`, a separate SQLite database): a deleted task must leave
  no recoverable run behind.

  Runs `async: true`: each test gets its own isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase`, every task/agent id is
  per-test unique, and no app-env key or shared ETS table is touched. The only
  shared resource is the app-booted default `EvoGit.AgentState.Server` — the
  store the registry itself reaches in `:test` — and it is addressed ONLY with
  those unique ids (removed again in `on_exit`).

  There is no `Process.sleep/1`: checkpoints are flushed before every read, and
  a `TaskRegistry` CALL after the delete cast is the synchronization barrier
  (the registry runs the cascade synchronously inside that cast).
  """

  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.AgentState

  defp seed_task!(task_id, status) do
    task = %TaskInfo{
      id: task_id,
      type: :genesis,
      status: status,
      opts: [path: "/tmp/test"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: if(status in [:completed, :failed, :cancelled], do: DateTime.utc_now()),
      logs: [],
      result: nil
    }

    :ok = EvoGit.Store.put_task(store(), task)
  end

  # Writes one durable run per agent id through the DEFAULT agent-state server
  # (no `store:` opt → `EvoGit.AgentState.server/0`), exactly the store the
  # registry's cascade resolves, and flushes so the rows are readable.
  defp seed_agent_state!(task_id, agent_ids) do
    on_exit(fn -> AgentState.delete_task(task_id) end)

    for agent_id <- agent_ids do
      :ok =
        AgentState.checkpoint(task_id, agent_id, %{
          kind: :rewrite,
          messages: [
            %ReqLLM.Message{
              role: :user,
              content: [ReqLLM.Message.ContentPart.text("durable run #{agent_id}")]
            }
          ],
          fields: %{phase: "running"}
        })
    end

    :ok = AgentState.flush()

    for agent_id <- agent_ids do
      assert {:ok, _record} = AgentState.load(task_id, agent_id),
             "the seeded durable state for #{task_id}/#{agent_id} must be readable"
    end
  end

  describe "delete_task/1" do
    test "removes the task row AND every durable agent run of that task" do
      unique = System.unique_integer([:positive])
      task_id = "agent_state_cascade_#{unique}"

      seed_task!(task_id, :completed)
      seed_agent_state!(task_id, [1, 2])

      TaskRegistry.delete_task(task_id)

      # Barrier: a call is handled after the cast, and the cast runs the
      # cascade synchronously, so both effects are settled here.
      _ = TaskRegistry.list_tasks()

      assert EvoGit.Store.get_task(store(), task_id) == nil
      assert AgentState.load(task_id, 1) == {:error, :not_found}
      assert AgentState.load(task_id, 2) == {:error, :not_found}
    end
  end

  describe "clear_finished_tasks/0" do
    test "removes durable agent state for every cleared finished task" do
      unique = System.unique_integer([:positive])
      first_id = "agent_state_clear_a_#{unique}"
      second_id = "agent_state_clear_b_#{unique}"

      seed_task!(first_id, :completed)
      seed_task!(second_id, :failed)
      seed_agent_state!(first_id, [1])
      seed_agent_state!(second_id, [3])

      assert :ok = TaskRegistry.clear_finished_tasks()

      assert EvoGit.Store.get_task(store(), first_id) == nil
      assert EvoGit.Store.get_task(store(), second_id) == nil
      assert AgentState.load(first_id, 1) == {:error, :not_found}
      assert AgentState.load(second_id, 3) == {:error, :not_found}
    end
  end
end
