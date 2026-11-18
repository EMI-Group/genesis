defmodule EvoGit.TaskRegistry.AgentStateReadTest do
  @moduledoc """
  BOUNDED, offloaded reads of the durable agent-state store from a
  life-critical caller (`EvoGit.TaskRegistry.AgentStateRead`).
  `EvoGit.AgentState` reads run in the CALLING process, so a busy/locked
  database would block the registry GenServer — and every dashboard call it
  serves. These tests use a budget that cannot be met (`timeout: 0`, the bound
  itself) and a store that is GONE (stopped instance) and pin that:
    * every read — `roster/2`, `pause_commit/3` — answers its DOCUMENTED
      degraded value within the budget (`[]`, `nil`) instead of blocking;
    * the restart classifier degrades to "not resumable" (`nil`, i.e. today's
      `:failed` restart behaviour) rather than pretending;
    * a resume with an unprovable durable store answers `{:error, :not_resumable}`
      promptly and spawns NO wrapper;
    * the happy path is unchanged (the stored roster row, the stored sha), and
      the resume hands the ROOT run's pause checkpoint to the scheduler instead
      of letting the scheduler read the store itself.
  Runs `async: true`: each test owns an isolated `EvoGit.Store` (from
  `EvoGit.TaskRegistryCase`) and an isolated `EvoGit.AgentState` instance pinned
  on THIS process's `:evogit_agent_state_server` seam, so nothing app-global is
  mutated and no other module can observe this file's ids or its stopped store.
  """
  use EvoGit.TaskRegistryCase, async: true
  alias EvoGit.AgentState
  alias EvoGit.TaskRegistry.AgentStateRead
  alias EvoGit.TaskRegistry.Pause

  setup %{data_dir: data_dir} do
    agent_state = start_agent_state!(data_dir)
    Process.put(:evogit_agent_state_server, agent_state)
    on_exit(fn -> Process.delete(:evogit_agent_state_server) end)
    %{agent_state: agent_state}
  end

  describe "the happy path (unchanged)" do
    test "answers the stored roster row and pause checkpoint",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_durable_run!(agent_state, task_id, 7)

      assert [%EvoGit.AgentState.Record{agent_id: 7}] = AgentStateRead.roster(task_id)
      assert AgentStateRead.pause_commit(task_id, 7) == nil

      :ok = AgentState.put_pause_commit(task_id, 7, "abc123", store: agent_state)
      assert AgentStateRead.pause_commit(task_id, 7) == "abc123"

      assert AgentStateRead.roster(unique_task_id()) == []
      assert AgentStateRead.pause_commit(task_id, 999) == nil
    end
  end

  describe "roster/2 — the whole durable tree" do
    test "returns every row ordered depth ASC, agent_id ASC with messages: nil",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      # Two roots (no `depth`, so they sort first by agent_id) plus one child.
      seed_durable_run!(agent_state, task_id, 4)
      seed_run!(agent_state, task_id, 2, %{parent_id: 4, depth: 1, branch: "child-branch"})
      seed_durable_run!(agent_state, task_id, 1)

      assert [
               %EvoGit.AgentState.Record{} = first,
               %EvoGit.AgentState.Record{} = second,
               %EvoGit.AgentState.Record{} = child
             ] = AgentStateRead.roster(task_id)

      assert first.agent_id == 1
      assert second.agent_id == 4
      assert child.agent_id == 2
      assert child.fields[:depth] == 1
      assert child.fields[:parent_id] == 4
      assert child.fields[:branch] == "child-branch"
      # The scalar fields arrive; the transcript deliberately does not.
      assert Enum.all?([first, second, child], &is_nil(&1.messages))

      assert AgentStateRead.roster(unique_task_id()) == []
    end

    test "degrades to [] within its budget and when the store is gone",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_durable_run!(agent_state, task_id, 7)

      assert timed(fn ->
               assert AgentStateRead.roster(task_id, timeout: 0, op: "roster") == []
             end) < 1_000

      # Nothing was lost: the real read still answers the stored row.
      assert [%EvoGit.AgentState.Record{agent_id: 7}] = AgentStateRead.roster(task_id)

      stop_store!(agent_state)
      assert timed(fn -> assert AgentStateRead.roster(task_id) == [] end) < 1_000
    end
  end

  describe "a read that cannot answer" do
    test "degrades to the documented empty value within its budget", %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_durable_run!(agent_state, task_id, 7)

      # A ZERO budget can never be met, so this pins the bound itself: the
      # caller answers its documented degraded value instead of waiting, and the
      # worker is shut down rather than left running.
      assert timed(fn ->
               assert AgentStateRead.roster(task_id, timeout: 0, op: "roster") == []
             end) < 1_000

      assert timed(fn ->
               assert AgentStateRead.pause_commit(task_id, 7, timeout: 0, op: "pause_commit") ==
                        nil
             end) < 1_000

      # Nothing was lost: the real read still answers the stored facts.
      assert [%EvoGit.AgentState.Record{agent_id: 7}] = AgentStateRead.roster(task_id)
    end

    test "an UNAVAILABLE store degrades immediately (no worker at all)",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_durable_run!(agent_state, task_id, 1)
      stop_store!(agent_state)

      assert timed(fn -> assert AgentStateRead.roster(task_id) == [] end) < 1_000
      assert timed(fn -> assert AgentStateRead.pause_commit(task_id, 1) == nil end) < 1_000
    end
  end

  describe "the restart classifier" do
    test "reads a live store as :dirty", %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_task!(task_id, :running)
      seed_durable_run!(agent_state, task_id, 1)

      assert Pause.pause_kind_for_restart(store(), task_id) == :dirty
    end

    test "degrades to nil (never a fake :dirty pause) when the store is gone",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_task!(task_id, :running)
      seed_durable_run!(agent_state, task_id, 1)
      stop_store!(agent_state)

      assert timed(fn -> assert Pause.pause_kind_for_restart(store(), task_id) == nil end) < 2_000
    end
  end

  describe "a resume" do
    test "REFUSES instead of re-enqueueing an unrestorable run when the store is gone",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_task!(task_id, :paused)
      seed_durable_run!(agent_state, task_id, 1)
      stop_store!(agent_state)
      test_pid = self()

      elapsed =
        timed(fn ->
          assert Pause.resume(store(), task_id, nil, spawn_report(test_pid)) ==
                   {:error, :not_resumable}
        end)

      assert elapsed < 2_000
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "carries the ROOT run's pause checkpoint on the spawn opts",
         %{agent_state: agent_state} do
      task_id = unique_task_id()
      seed_task!(task_id, :paused)
      seed_durable_run!(agent_state, task_id, 1)
      :ok = AgentState.put_pause_commit(task_id, 1, "abc123", store: agent_state)
      test_pid = self()

      assert {:ok, _ref} = Pause.resume(store(), task_id, nil, spawn_report(test_pid))

      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000
      # Resolved OUTSIDE the scheduler and always present: `nil` means
      # "resolved, nothing stored", absence would mean "not a pause resume".
      assert Keyword.has_key?(spawn_opts, :pause_commit)
      assert Keyword.get(spawn_opts, :pause_commit) == "abc123"
      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause
    end
  end

  ## Fixtures

  defp unique_task_id, do: "agent_state_read-#{System.unique_integer([:positive])}"

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
      finished_at: nil,
      logs: [],
      result: nil,
      session_mode: "oneshot",
      lease_expires_at: System.system_time(:second) + 300
    }

    :ok = EvoGit.Store.put_task(store(), task)
  end

  # One ROOT durable run (no `parent_id`), written through the real writer path.
  defp seed_durable_run!(agent_state, task_id, agent_id) do
    seed_run!(agent_state, task_id, agent_id, %{phase: "paused"})
  end

  # One durable run with caller-chosen scalar fields (a CHILD row needs
  # `parent_id`/`depth`), flushed so the following read is stable.
  defp seed_run!(agent_state, task_id, agent_id, fields) do
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
          fields: fields
        },
        store: agent_state
      )

    :ok = AgentState.flush(store: agent_state)
    assert {:ok, _record} = AgentState.load(task_id, agent_id, store: agent_state)
  end

  # An ISOLATED agent-state instance (unnamed, its own database file).
  defp start_agent_state!(data_dir) do
    dir = Path.join(data_dir, "agent_state")
    File.mkdir_p!(dir)

    {:ok, pid} =
      EvoGit.AgentState.start_link(database: Path.join(dir, "agent_state.sqlite"), name: nil)

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000) end)
    pid
  end

  # The wrapper spawn seam `Pause.resume/4` takes: it reports the spawn to the
  # test process and returns a live (idle) pid, so no runtime ever starts.
  defp spawn_report(test_pid) do
    fn task_type, spawn_opts, task_id, server ->
      send(test_pid, {:wrapper_spawned, task_type, spawn_opts, task_id, server})
      spawn(fn -> Process.sleep(:infinity) end)
    end
  end

  # An agent-state instance that is GONE: the store resolves to nothing, which
  # is the documented "unavailable store" degradation (`[]` / `false` / `nil`).
  defp stop_store!(agent_state) do
    assert :ok = Supervisor.stop(agent_state, :normal, 5_000)
    refute Process.alive?(agent_state)
  end
end
