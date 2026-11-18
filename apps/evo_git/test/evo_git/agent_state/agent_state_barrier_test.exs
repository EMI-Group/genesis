defmodule EvoGit.AgentState.BarrierTest do
  @moduledoc """
  HONEST-BARRIER and CAST-BOOKKEEPING coverage for `EvoGit.AgentState`:

    * `flush/1` is `:ok` only when the writer actually committed everything
      queued before it — a degraded writer, a dead/absent target and a queue
      already past `:agent_state_max_backlog` all answer `{:error, :timeout}`;
    * `mark_completed/3`, `delete/3`, `delete_task/2` and `delete_tasks/2` are
      CASTS: total `:ok` for any target, observable right after a `flush/1`.

  Every case uses its OWN isolated `EvoGit.AgentState` instance (unnamed, on a
  per-test SQLite file) addressed through `store: pid`, so the app-global
  `EvoGit.AgentState.Server` is never touched — hence `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record

  @moduletag :tmp_dir

  ## Isolation helpers (duplicated per file on purpose: no shared support module)

  defp start_store!(tmp_dir) do
    start_supervised!(
      {EvoGit.AgentState,
       database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000}
    )
  end

  defp server_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {EvoGit.AgentState.Server, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp message(text),
    do: %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text(text)]}

  defp rewrite(messages), do: %{kind: :rewrite, messages: messages, fields: %{}}

  ## flush/1

  describe "flush/1" do
    test "answers :ok against a healthy writer", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      :ok = AgentState.checkpoint("task-flush", 1, rewrite([message("m")]), store: pid)
      assert :ok = AgentState.flush(store: pid)

      assert {:ok, %Record{messages: [%ReqLLM.Message{}]}} =
               AgentState.load("task-flush", 1, store: pid)
    end

    test "answers :ok for a nil target (nothing to flush)" do
      assert :ok = AgentState.flush(nil)
      assert :ok = AgentState.flush(store: nil)
    end

    test "answers {:error, :timeout} when the writer's backlog is above the cap",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      server = server_pid(pid)
      cap = Application.get_env(:evo_git, :agent_state_max_backlog, 200)

      # Queue the `:sync` call FIRST and the noise casts BEHIND it: while the
      # writer is suspended nothing is processed, so when it resumes and reaches
      # the barrier its own mailbox already exceeds the cap.
      :ok = :sys.suspend(server)
      ref = make_ref()
      send(server, {:"$gen_call", {self(), ref}, :sync})
      for _index <- 1..(cap + 10), do: GenServer.cast(server, :noise)
      :ok = :sys.resume(server)

      assert_receive {^ref, {:error, :timeout}}, 5_000

      # The barrier is still usable once the backlog drains.
      assert :ok = AgentState.flush(store: pid)
    end

    test "answers {:error, :timeout} when the call exits (dead target)", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      absent_name = :"evogit_agent_state_absent_#{System.unique_integer([:positive])}"

      assert {:error, :timeout} = AgentState.flush(store: absent_name)
      assert {:error, :timeout} = AgentState.flush(store: spawn(fn -> :ok end))

      # A writer killed MID-CALL (the call is parked while the writer is
      # suspended) exits the caller; the barrier answers its documented value.
      server = server_pid(pid)
      :ok = :sys.suspend(server)
      task = Task.async(fn -> AgentState.flush(store: server) end)
      Process.exit(server, :kill)
      assert Task.await(task, 5_000) == {:error, :timeout}
    end
  end

  ## Bookkeeping writes

  describe "bookkeeping writes" do
    test "mark_completed/3 is a total cast, observable after flush/1", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      :ok = AgentState.checkpoint("task-mc", 1, rewrite([message("m")]), store: pid)
      assert :ok = AgentState.flush(store: pid)

      assert :ok = AgentState.mark_completed("task-mc", 1, store: pid)
      assert :ok = AgentState.flush(store: pid)

      assert {:ok, record} = AgentState.load("task-mc", 1, store: pid)
      assert record.fields[:status] == "completed"
      assert %DateTime{} = record.completed_at
      assert record.messages == [message("m")]
    end

    test "delete/3 and delete_task/2 are total casts, observable after flush/1",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      for {task_id, agent_id} <- [{"task-d", 1}, {"task-d", 2}, {"task-e", 1}] do
        :ok = AgentState.checkpoint(task_id, agent_id, rewrite([message("m")]), store: pid)
      end

      assert :ok = AgentState.flush(store: pid)

      assert :ok = AgentState.delete("task-d", 1, store: pid)
      assert :ok = AgentState.flush(store: pid)
      assert {:error, :not_found} = AgentState.load("task-d", 1, store: pid)
      assert {:ok, %Record{}} = AgentState.load("task-d", 2, store: pid)

      assert :ok = AgentState.delete_task("task-d", store: pid)
      assert :ok = AgentState.flush(store: pid)
      assert {:error, :not_found} = AgentState.load("task-d", 2, store: pid)
      assert {:ok, %Record{}} = AgentState.load("task-e", 1, store: pid)
    end

    test "delete_tasks/2 is ONE total cast for a bulk cleanup", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      for task_id <- ["task-x", "task-y", "task-z"] do
        :ok = AgentState.checkpoint(task_id, 1, rewrite([message("m")]), store: pid)
      end

      assert :ok = AgentState.flush(store: pid)

      assert :ok = AgentState.delete_tasks(["task-x", "task-y"], store: pid)
      assert :ok = AgentState.flush(store: pid)

      assert {:error, :not_found} = AgentState.load("task-x", 1, store: pid)
      assert {:error, :not_found} = AgentState.load("task-y", 1, store: pid)
      assert {:ok, %Record{}} = AgentState.load("task-z", 1, store: pid)
    end

    test "bookkeeping is total for every dead/absent target" do
      absent_name = :"evogit_agent_state_absent_#{System.unique_integer([:positive])}"
      dead = spawn(fn -> :ok end)

      for target <- [absent_name, dead] do
        assert :ok = AgentState.mark_completed("task-a", 1, store: target)
        assert :ok = AgentState.delete("task-a", 1, store: target)
        assert :ok = AgentState.delete_task("task-a", store: target)
        assert :ok = AgentState.delete_tasks(["task-a", "task-b"], store: target)
        assert :ok = AgentState.checkpoint("task-a", 1, rewrite([message("m")]), store: target)
      end
    end
  end
end
