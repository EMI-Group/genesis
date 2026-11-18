defmodule EvoGit.AgentState.DurableRowLifecycleResumeTest.StubAgent do
  @moduledoc """
  The role this file's durable fixtures run AS. `EvoGit.Agent.Session.Persistence`
  never calls into the role (it only stores `agent_module` as a scalar), but a
  real `%EvoGit.Agent.State{}` always carries one, so the durable row is built
  from a production-shaped state.

  Defined ABOVE the test module on purpose: `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the force-kill stub role."
  def system_prompt, do: "You are the durable row force-kill stub agent."

  @doc "No tools: nothing here ever dispatches one."
  def available_tools, do: []
end

defmodule EvoGit.AgentState.DurableRowLifecycleResumeTest do
  @moduledoc """
  A FORCE-KILLED run is never resumable-as-done.

  The session half of this invariant is already pinned elsewhere
  (`agent/session/persistence_session_test.exs`: a force-killed session never
  reaches `Persistence.complete/2`, so its row keeps `status: "running"` with no
  `completed_at`). What no suite pins is the TASK half, which is what this file
  adds:

    * `EvoGit.TaskRegistry.force_kill_task/1` — the brutal path — persists the
      task `:failed` with `pause_kind: nil` and `result: nil`
      (`lib/evo_git/task_registry.ex`, `force_kill_write/2`: "a killed task can
      never look resumable") and touches NO durable row;
    * the killed run's durable ROOT row therefore SURVIVES as a plain
      `status: "running"` row with no result and no completed marking — the
      CORRECT state for a run that was interrupted, never a `done` claim;
    * `resume_task/1` refuses it with `{:error, :not_paused}` (resume accepts a
      `:paused` row only), so a later resume can never treat the killed run as a
      finished/completed run.

  ## Why `async: true` — the one app-global this test needs

  Each test gets its OWN isolated `EvoGit.Store` + `EvoGit.TaskRegistry` from
  `EvoGit.TaskRegistryCase`, all with unique registered names. The durable row
  cannot use a process-dictionary store seam: `EvoGit.TaskRegistry.Pause`
  resolves `EvoGit.AgentState.server/0` inside the REGISTRY process, so the row
  must live in the app-booted `EvoGit.AgentState.Server` — the per-run scratch
  `agent_state.sqlite` `config/test.exs` pins under a unique `:data_dir`. That
  is the only route a genuine registry/recovery path has (the same argument
  `task_registry/pause_test.exs` documents). Each test owns a per-test-unique
  task id and agent id, never lists the table wholesale, and deletes exactly its
  own rows in `on_exit`.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentState.DurableRowLifecycleResumeTest.StubAgent
  alias EvoGit.AgentState.Record

  setup do
    # The app-booted writer: the ONLY store a registry-side read can resolve.
    server = Process.whereis(EvoGit.AgentState.Server)
    assert is_pid(server)

    # Per-test unique identity, so a concurrent module can never observe (or
    # delete) this test's rows in the shared per-run database.
    agent_id = 9_971_000 + System.unique_integer([:positive])
    task_id = "durable-row-kill-#{System.unique_integer([:positive])}"

    # `on_exit` runs in a DIFFERENT process, so it passes the store explicitly
    # instead of relying on the process dictionary.
    on_exit(fn -> AgentState.delete_task(task_id, store: server) end)

    %{durable_server: server, durable_agent_id: agent_id, durable_task_id: task_id}
  end

  describe "force_kill_task/1 × the durable row" do
    test "leaves a plain running row and is never resumable-as-done", ctx do
      task_id = ctx.durable_task_id
      agent_id = ctx.durable_agent_id

      # The run's durable ROOT row, written by the real producer exactly as a
      # live run writes it: RUNNING, no result, no completed marking.
      assert :ok = Persistence.initial_snapshot(root_state(task_id, agent_id))
      assert :ok = AgentState.flush()

      assert {:ok, %Record{} = before} = AgentState.load(task_id, agent_id)
      assert Record.status(before) == "running"
      assert before.completed_at == nil
      assert Record.result(before) == nil

      # A live, owning task row plus the wrapper the registry force-kills.
      seed_running_task!(task_id)
      put_fake_wrapper!(task_id)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      # The TASK side: `:failed` (never `:cancelled`), no result, and — the
      # part the pause protocol reads — NO pause classification, so a killed
      # task can never look resumable.
      killed = EvoGit.Store.get_task(store(), task_id)
      assert killed.status == :failed
      assert killed.result == nil
      assert killed.pause_kind == nil
      assert killed.finished_at != nil
      assert killed.lease_expires_at == nil

      # The DURABLE side: the row survives, still `running`, still no result
      # and still not completed — the kill marked nothing as finished.
      assert :ok = AgentState.flush()

      assert {:ok, %Record{} = after_kill} = AgentState.load(task_id, agent_id)
      assert Record.status(after_kill) == "running"
      assert after_kill.completed_at == nil
      assert Record.result(after_kill) == nil
      assert after_kill.message_count == before.message_count
      assert after_kill.messages == before.messages

      # …and it is NOT resumable: `resume_task/1` accepts a `:paused` row only,
      # so the killed run can never be re-enqueued as a finished one.
      assert {:error, :not_paused} = TaskRegistry.resume_task(task_id)

      # Neither surface was resurrected by the refused resume.
      assert EvoGit.Store.get_task(store(), task_id).status == :failed

      assert :ok = AgentState.flush()
      assert {:ok, %Record{} = still_running} = AgentState.load(task_id, agent_id)
      assert Record.status(still_running) == "running"
      assert Record.result(still_running) == nil

      # The row is the task's only durable run, so no sibling was invented or
      # marked done either.
      assert [%Record{}] = AgentState.roster(task_id, store: ctx.durable_server)
    end
  end

  # ---------------------------------------------------------------------------
  # fixtures
  # ---------------------------------------------------------------------------

  defp root_state(task_id, agent_id) do
    struct!(State,
      task_id: task_id,
      agent_id: agent_id,
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          %ReqLLM.Message{
            role: :user,
            content: [ReqLLM.Message.ContentPart.text("kill objective")]
          }
        ]),
      persistent_state: true,
      current_commit: "killed-sha"
    )
  end

  # The live, owning `:running` row the force kill acts on: it holds the lease
  # and the persisted opts the pause/resume admission reads.
  defp seed_running_task!(task_id) do
    :ok =
      EvoGit.Store.put_task(store(), %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :running,
        opts: [path: "/tmp/test", mode: "simple", persistent_state: true],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) + 300
      })
  end

  # A live wrapper pinned in the registry's in-memory `task_refs`, so the kill
  # takes the normal `:running` arm (a wrapper to stop) rather than the
  # no-wrapper `:pausing`/`:paused` arm.
  defp put_fake_wrapper!(task_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    :sys.replace_state(TaskRegistry.server(), fn state ->
      %{
        state
        | task_refs:
            Map.put(state.task_refs, task_id, %Task{
              pid: pid,
              ref: make_ref(),
              owner: self(),
              mfa:
                {EvoGit.TaskRegistry.TaskExecutor, :execute_task,
                 [:evolve, [path: "/tmp/test"], task_id]}
            })
      }
    end)
  end
end
