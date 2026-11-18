defmodule EvoGit.TaskRegistry.AgentStateCascadeTest do
  @moduledoc """
  Deleting a task cascades to the task's DURABLE agent state
  (`EvoGit.AgentState`, a separate SQLite database): a deleted task must leave
  no recoverable run behind — and that cascade must NEVER be a synchronous
  barrier for the registry (`docs/agent-run-durability.md` § Isolation and
  containment: "no synchronous barriers on life-critical processes").
  Pinned here:
    * `delete_task/1` and `clear_finished_tasks/0` answer `:ok` and remove the
      task row while the durable store is SUSPENDED (`:sys.suspend` on the
      writer: a cast queues, a call would hang) and while it is STOPPED;
    * the cascade still happens — once the store comes back, the task's runs are
      gone; and `clear_finished_tasks/0` deletes the whole cleared batch through
      ONE `EvoGit.AgentState.delete_tasks/1` cast, not a per-task loop;
    * nothing raises in any of those states.
  Runs `async: true`: every test gets its own isolated `EvoGit.Store`,
  `EvoGit.TaskRegistry` and — through the registry's `:agent_state_server`
  option — its own isolated `EvoGit.AgentState` instance, so the app-global
  writer is never touched and no other module can observe this file's ids.
  There is no `Process.sleep/1`: the delete is a CAST, so `EvoGit.AgentState.flush/1`
  on the test's own instance (or a bounded poll of it) is the barrier that makes
  the cascade observable.
  """
  use EvoGit.TaskRegistryCase, async: true
  alias EvoGit.AgentState

  setup %{data_dir: data_dir} do
    agent_state = start_agent_state!(data_dir)
    registry = start_registry!(data_dir, agent_state)
    %{agent_state: agent_state, writer: writer_pid(agent_state), registry: registry}
  end

  describe "delete_task/1" do
    test "removes the task row AND every durable agent run of that task",
         %{agent_state: agent_state} do
      task_id = unique_task_id("cascade")
      seed_task!(task_id, :completed)
      seed_agent_state!(agent_state, task_id, [1, 2])

      TaskRegistry.delete_task(task_id)
      # Barriers, in this order: a registry CALL is handled after the delete cast
      # (so the cascade cast has been sent), then the isolated writer's `flush/1`
      # makes that cascade observable.
      _ = TaskRegistry.list_tasks()
      assert :ok = AgentState.flush(store: agent_state)

      assert EvoGit.Store.get_task(store(), task_id) == nil
      assert AgentState.load(task_id, 1, store: agent_state) == {:error, :not_found}
      assert AgentState.load(task_id, 2, store: agent_state) == {:error, :not_found}
    end

    test "returns :ok promptly with the durable store SUSPENDED, then cascades",
         %{agent_state: agent_state, writer: writer} do
      task_id = unique_task_id("cascade_suspended")
      seed_task!(task_id, :completed)
      seed_agent_state!(agent_state, task_id, [1])
      :ok = :sys.suspend(writer)

      elapsed =
        timed(fn ->
          assert :ok = TaskRegistry.delete_task(task_id)
          # A registry CALL never reaches the durable store, so it settles the
          # delete even while that store is suspended.
          _ = TaskRegistry.list_tasks()
        end)

      # The task row is the registry's own store: the delete is settled before
      # the (cast) cascade is even sent, so a stalled writer cannot delay it.
      assert EvoGit.Store.get_task(store(), task_id) == nil
      assert elapsed < 1_000, "the delete waited #{elapsed}ms on the durable store"

      :ok = :sys.resume(writer)
      assert :ok = AgentState.flush(store: agent_state)
      assert AgentState.load(task_id, 1, store: agent_state) == {:error, :not_found}
    end

    test "returns :ok with the durable store STOPPED",
         %{agent_state: agent_state, writer: _writer} do
      task_id = unique_task_id("cascade_stopped")
      seed_task!(task_id, :completed)
      seed_agent_state!(agent_state, task_id, [1])
      stop_agent_state!(agent_state)

      elapsed =
        timed(fn ->
          assert :ok = TaskRegistry.delete_task(task_id)
          _ = TaskRegistry.list_tasks()
        end)

      assert EvoGit.Store.get_task(store(), task_id) == nil
      assert elapsed < 1_000, "the delete waited #{elapsed}ms on a stopped store"
    end
  end

  describe "clear_finished_tasks/0" do
    test "removes durable agent state for every cleared finished task",
         %{agent_state: agent_state} do
      first_id = unique_task_id("clear_a")
      second_id = unique_task_id("clear_b")
      seed_task!(first_id, :completed)
      seed_task!(second_id, :failed)
      seed_agent_state!(agent_state, first_id, [1])
      seed_agent_state!(agent_state, second_id, [3])

      assert :ok = TaskRegistry.clear_finished_tasks()
      assert :ok = AgentState.flush(store: agent_state)

      assert EvoGit.Store.get_task(store(), first_id) == nil
      assert EvoGit.Store.get_task(store(), second_id) == nil
      assert AgentState.load(first_id, 1, store: agent_state) == {:error, :not_found}
      assert AgentState.load(second_id, 3, store: agent_state) == {:error, :not_found}
    end

    test "clears with the durable store SUSPENDED and batches ONE cascade",
         %{agent_state: agent_state, writer: writer} do
      first_id = unique_task_id("clear_suspended_a")
      second_id = unique_task_id("clear_suspended_b")
      seed_task!(first_id, :completed)
      seed_task!(second_id, :failed)
      seed_agent_state!(agent_state, first_id, [1])
      seed_agent_state!(agent_state, second_id, [3])
      :ok = :sys.suspend(writer)

      elapsed = timed(fn -> assert :ok = TaskRegistry.clear_finished_tasks() end)
      assert EvoGit.Store.get_task(store(), first_id) == nil
      assert EvoGit.Store.get_task(store(), second_id) == nil
      assert elapsed < 1_000, "the clear waited #{elapsed}ms on the durable store"

      # ONE queued cascade message for the whole batch (`delete_tasks/1`), so
      # a stalled writer never sees a per-task loop.
      assert Enum.any?(:erlang.process_info(writer, :messages) |> elem(1), fn message ->
               match?({:"$gen_cast", {:delete_tasks, ids}} when is_list(ids), message)
             end)

      :ok = :sys.resume(writer)
      assert :ok = AgentState.flush(store: agent_state)
      assert AgentState.load(first_id, 1, store: agent_state) == {:error, :not_found}
      assert AgentState.load(second_id, 3, store: agent_state) == {:error, :not_found}
    end

    test "clears with the durable store STOPPED", %{agent_state: agent_state} do
      task_id = unique_task_id("clear_stopped")
      seed_task!(task_id, :completed)
      seed_agent_state!(agent_state, task_id, [1])
      stop_agent_state!(agent_state)

      elapsed = timed(fn -> assert :ok = TaskRegistry.clear_finished_tasks() end)
      assert EvoGit.Store.get_task(store(), task_id) == nil
      assert elapsed < 1_000, "the clear waited #{elapsed}ms on a stopped store"
    end
  end

  ## Fixtures

  defp unique_task_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp timed(fun) do
    {micros, _result} = :timer.tc(fun)
    div(micros, 1000)
  end

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

  # One durable run row per agent id, written through the REAL writer path.
  defp seed_agent_state!(agent_state, task_id, agent_ids) do
    for agent_id <- agent_ids do
      :ok =
        AgentState.checkpoint(
          task_id,
          agent_id,
          %{
            kind: :rewrite,
            messages: [
              %ReqLLM.Message{
                role: :user,
                content: [ReqLLM.Message.ContentPart.text("durable run #{agent_id}")]
              }
            ],
            fields: %{phase: "running"}
          },
          store: agent_state
        )
    end

    :ok = AgentState.flush(store: agent_state)

    for agent_id <- agent_ids do
      assert {:ok, _record} = AgentState.load(task_id, agent_id, store: agent_state),
             "the seeded durable state for #{task_id}/#{agent_id} must be readable"
    end
  end

  # An ISOLATED agent-state instance (unnamed, its own database) — never the
  # app-global writer, so a suspension here is invisible to every other module.
  # Linked to the test process only for lifetime; unlinked immediately so a
  # supervisor stop cannot take the test down with it.
  defp start_agent_state!(data_dir) do
    dir = Path.join(data_dir, "agent_state")
    File.mkdir_p!(dir)

    {:ok, pid} =
      EvoGit.AgentState.start_link(database: Path.join(dir, "agent_state.sqlite"), name: nil)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000) end)
    pid
  end

  defp stop_agent_state!(pid) do
    assert :ok = Supervisor.stop(pid, :normal, 5_000)
    refute Process.alive?(pid)
  end

  defp writer_pid(agent_state) do
    agent_state
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {EvoGit.AgentState.Server, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
    |> case do
      nil -> flunk("the isolated agent-state instance has no writer")
      pid -> pid
    end
  end

  # THIS test's registry instance, pointed at the isolated agent-state store
  # through the documented `:agent_state_server` option (the registry sets the
  # `:evogit_agent_state_server` process-dictionary seam for its own process).
  defp start_registry!(data_dir, agent_state) do
    registry = :"evogit_test_agent_state_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {TaskRegistry,
       task_store: store(), data_dir: data_dir, name: registry, agent_state_server: agent_state},
      id: registry
    )

    Process.put(:evogit_task_registry_server, registry)
    registry
  end
end
