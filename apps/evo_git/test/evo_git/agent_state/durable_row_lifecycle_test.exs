defmodule EvoGit.AgentState.DurableRowLifecycleTest.StubAgent do
  @moduledoc """
  The role these durable-row fixtures run AS. `EvoGit.Agent.Session.Persistence`
  never calls into the role (it only stores `agent_module` as a scalar), but a
  real `%EvoGit.Agent.State{}` always carries one, so the durable projection is
  built from a production-shaped state.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the durable-row stub role."
  def system_prompt, do: "You are the durable row lifecycle stub agent."

  @doc "No tools: nothing here ever dispatches one."
  def available_tools, do: []
end

defmodule EvoGit.AgentState.DurableRowLifecycleTest do
  @moduledoc """
  The durable ROW LIFECYCLE of a task's agent tree at the `EvoGit.AgentState`
  facade boundary — the invariants this file uniquely pins:

  1. a ROOT's completion drops its OWN row and NOTHING ELSE: the task's `done`
     CHILD row stays readable, with its stored result, as the proof the child
     finished (the existing suites pin the two halves SEPARATELY — a root's row
     dropping in `agent/session/persistence_test.exs` and a child's row staying
     in the same file — so a `delete_task`-shaped regression in the root path
     would satisfy both while destroying the sibling rows this test reads back
     through `EvoGit.AgentState.roster/2`);
  2. `persistent_state: false` is fully INERT even when a row ALREADY EXISTS for
     the same `(task_id, agent_id)`: every entry point (`initial_snapshot/1`,
     `checkpoint/2`, `resync/1`, `complete/1,2`) writes nothing, marks nothing
     and leaves the append BASELINE intact, so the next real checkpoint still
     lands as a tail append. The existing opt-out tests can only prove "nothing
     was created" (they start from an empty identity); this one proves "nothing
     was touched".

  Per-step coverage that already exists and is deliberately NOT duplicated here:
  the initial snapshot before the first turn (`durable_run_facts_test.exs` +
  `durable_run_session_test.exs`), the batch-clearing checkpoint as the done
  child's only deleter (`durable_run_facts_test.exs`), and the
  `persistent_state: false` no-row-created cases across all four suites.

  ## Why `async: true` — no BEAM-global is touched

  Each test starts its OWN UNNAMED `EvoGit.AgentState` supervisor on a
  per-test-unique SQLite file under `System.tmp_dir!()` and pins it on the TEST
  process dictionary (`:evogit_agent_state_server`), which is exactly the process
  making every `EvoGit.Agent.Session.Persistence` call — so the cast target, the
  append baseline key and every read are test-local. Task ids and agent ids are
  unique per test, and nothing here mutates app env, an ETS table,
  `:persistent_term` (beyond the server's own pid-keyed repo entry) or a PubSub
  topic.

  Checkpoints are CASTS, so every read-backed assertion follows
  `EvoGit.AgentState.flush/0` (the documented read-your-writes barrier) — never
  a sleep.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentState.DurableRowLifecycleTest.StubAgent
  alias EvoGit.AgentState.Record

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "evogit_durable_row_lifecycle_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    # Registered BEFORE the supervised child, so ExUnit's own (later-registered,
    # LIFO) stop callback runs FIRST and the store is closed before its file is
    # removed.
    on_exit(fn -> File.rm_rf(tmp) end)

    # Its OWN unnamed server: `EvoGit.AgentState.child_spec/1` hardcodes
    # `id: __MODULE__`, so the child id must be overridden per test.
    store =
      start_supervised!(
        {EvoGit.AgentState, database: Path.join(tmp, "agent_state.sqlite"), name: nil},
        id: {EvoGit.AgentState, System.unique_integer([:positive])}
      )

    Process.put(:evogit_agent_state_server, store)
    {:ok, store: store}
  end

  describe "the row lifecycle of one task's agent tree" do
    test "a ROOT's completion drops only its OWN row, leaving the done child readable" do
      task_id = unique_task_id()
      root_id = unique_agent_id()
      child_id = unique_agent_id()

      # The task's ROOT run: ONE durable row from the initial snapshot, still
      # RUNNING (no turn has completed it).
      assert :ok = Persistence.initial_snapshot(root_state(task_id, root_id))

      # The task's CHILD run: started, then completed with its report — the
      # `done` row a parent (and a resume) reads as proof the child finished.
      assert :ok =
               Persistence.initial_snapshot(child_state(task_id, child_id, root_id))

      assert :ok = Persistence.complete(child_state(task_id, child_id, root_id), "child report")
      flush!()

      # Both rows of the ONE task coexist, ordered `depth ASC, agent_id ASC`.
      assert [%Record{} = running_root, %Record{} = done_child] = AgentState.roster(task_id)
      assert running_root.agent_id == root_id
      assert Record.status(running_root) == "running"
      assert done_child.agent_id == child_id
      assert Record.status(done_child) == "done"

      # The ROOT completes: nothing consumes a root's result, so its row is
      # dropped…
      assert :ok = Persistence.complete(root_state(task_id, root_id), "root report")
      flush!()

      assert AgentState.load(task_id, root_id) == {:error, :not_found}

      # …and ONLY its own row: the child's `done` row still carries its result
      # and its completed marking, and reads back as the task's only row.
      assert [%Record{} = survivor] = AgentState.roster(task_id)
      assert survivor.agent_id == child_id
      assert Record.status(survivor) == "done"

      assert Record.result(survivor) == %{
               "text" => "child report",
               "commit" => "child-sha",
               "repo_id" => "primary"
             }

      assert %DateTime{} = survivor.completed_at
      assert {:ok, %Record{} = loaded} = AgentState.load(task_id, child_id)
      assert loaded.messages == msgs(2)
    end

    test "persistent_state: false is inert even when a row already exists for the identity" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      # The run's durable row, written while persistence was ON: a full
      # snapshot, then one append turn. Each step is FLUSHED before the next
      # one: the writer COALESCES the checkpoints still queued for one run
      # (a rewrite followed by an append folds into a single rewrite, i.e. ONE
      # chunk), so the chunk counts below are only meaningful per committed
      # boundary.
      assert :ok = Persistence.initial_snapshot(run_state(task_id, agent_id, msgs(2)))
      flush!()

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, msgs(2)),
                 %{run_state(task_id, agent_id, msgs(3)) | turn: 1}
               )

      flush!()
      before = load!(task_id, agent_id)
      assert before.message_count == 3
      assert before.chunk_count == 2
      assert Record.status(before) == "running"

      # Every entry point of the module, now with persistence OFF — and with a
      # state that would otherwise be a full rewrite, a resync and a terminal
      # result, i.e. every shape a run could reach.
      inert = %{run_state(task_id, agent_id, msgs(6)) | persistent_state: false}
      assert :ok = Persistence.initial_snapshot(inert)
      assert :ok = Persistence.checkpoint(%{inert | persistent_state: true}, inert)
      assert :ok = Persistence.checkpoint(inert, inert)
      assert :ok = Persistence.resync(inert)
      assert :ok = Persistence.complete(inert)
      assert :ok = Persistence.complete(inert, "must never be recorded")
      flush!()

      # The pre-existing row is byte-identical: no conversation write, no scalar
      # upsert, no `done` marking, no result and no deletion.
      untouched = load!(task_id, agent_id)
      assert untouched.message_count == before.message_count
      assert untouched.chunk_count == before.chunk_count
      assert untouched.messages == before.messages
      assert untouched.fields == before.fields
      assert Record.status(untouched) == "running"
      assert untouched.completed_at == nil
      assert Record.result(untouched) == nil

      # The inert calls left the append BASELINE intact too: the next REAL
      # checkpoint of the same run still lands as a one-message tail append
      # instead of a rewrite (a rewrite would collapse the chunks back to ONE).
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, msgs(3)),
                 %{run_state(task_id, agent_id, msgs(4)) | turn: 2}
               )

      flush!()
      appended = load!(task_id, agent_id)

      assert appended.message_count == 4
      assert appended.chunk_count == before.chunk_count + 1
      assert Record.status(appended) == "running"
    end
  end

  # ---------------------------------------------------------------------------
  # fixtures
  # ---------------------------------------------------------------------------

  defp unique_agent_id, do: 9_970_000 + System.unique_integer([:positive])
  defp unique_task_id, do: "durable-row-#{System.unique_integer([:positive])}"

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  # `n` structurally identical messages on every call, so two independently
  # built lists compare equal (the store round-trip must be byte-exact).
  defp msgs(n), do: Enum.map(1..n//1, fn index -> message(:user, "m#{index}") end)

  # A ROOT run of the task: `parent_id` stays nil and `depth` 0.
  defp root_state(task_id, agent_id, overrides \\ []) do
    run_state(
      task_id,
      agent_id,
      msgs(2),
      Keyword.merge([current_commit: "root-sha"], overrides)
    )
  end

  # A CHILD run of the task: the spawn position and parentage a parent's
  # batch-clearing checkpoint keys on.
  defp child_state(task_id, agent_id, parent_id) do
    run_state(task_id, agent_id, msgs(2),
      parent_id: parent_id,
      depth: 1,
      spawn_turn: 1,
      spawn_index: 0,
      current_commit: "child-sha"
    )
  end

  defp run_state(task_id, agent_id, messages, overrides \\ []) do
    defaults = [
      task_id: task_id,
      agent_id: agent_id,
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new(messages),
      persistent_state: true
    ]

    struct!(State, Keyword.merge(defaults, overrides))
  end

  defp flush!, do: assert(:ok = AgentState.flush())

  defp load!(task_id, agent_id) do
    assert {:ok, %Record{} = record} = AgentState.load(task_id, agent_id)
    record
  end
end
