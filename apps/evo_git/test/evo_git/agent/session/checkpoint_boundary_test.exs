defmodule EvoGit.Agent.Session.CheckpointBoundaryTest.StubAgent do
  @moduledoc """
  The role the checkpoint-boundary fixtures run AS: a fixed system prompt and NO
  tools.

  Defined ABOVE the test module on purpose — `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the checkpoint-boundary stub agent."

  @doc "No tools: nothing in these tests ever runs one."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.CheckpointBoundaryTest do
  @moduledoc """
  The BOUNDARY-CLASSIFICATION contract of `EvoGit.Agent.Session.Persistence`
  over a real, isolated `EvoGit.AgentState` store, exercised on LONG
  transcripts (200+ and 500 messages) rather than the short fixtures of the
  unit suite:

    * a genuine prefix extension appends ONLY the new tail (ONE extra chunk);
    * a non-prefix list with an unchanged `compression_count` rewrites the
      whole transcript (previous chunks replaced, back to ONE);
    * a boundary that learned NOTHING does NO store work at all — no cast, no
      encoding, no anchor task — which is proven BY CONSTRUCTION by suspending
      the writer and asserting its mailbox stays EMPTY;
    * the classification cost of a 500-message boundary stays far below a
      GENEROUS wall-clock budget (the old `Enum.take(new, length(old)) == old`
      prefix check allocated a copy of the whole prefix on every boundary).

  ## Why `async: true` — no BEAM-global is touched

  Each test starts its OWN UNNAMED `EvoGit.AgentState` server on a
  per-test-unique SQLite file under `System.tmp_dir!()` (named with the owning
  BEAM's pid, so concurrent runs cannot collide) and pins it on the TEST
  process dictionary (`:evogit_agent_state_server`), which is exactly the
  process calling `Persistence.checkpoint/2` — so both the cast target and the
  baseline key are test-local. Task ids and agent ids are unique per test, and
  nothing here mutates app env, an ETS table, `:persistent_term` (beyond the
  server's own pid-keyed repo entry) or a PubSub topic.

  Checkpoints are CASTS, so every read-backed assertion follows
  `EvoGit.AgentState.flush/0` (the documented read-your-writes barrier) — never
  a sleep.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session.CheckpointBoundaryTest.StubAgent
  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.State
  alias EvoGit.AgentState

  # A GENEROUS ceiling, not a benchmark: the classification alone is expected in
  # the tens of microseconds (see the cost test), so this only fails if a
  # boundary regresses to something that walks/allocates the transcript in a
  # pathological way. A loaded host is allowed ~3 orders of magnitude of slack.
  @boundary_budget_us 50_000

  # --- Fixtures -------------------------------------------------------------

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "evogit_checkpoint_boundary_#{:os.getpid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    # Registered BEFORE the supervised child, so ExUnit's own (later-registered,
    # LIFO) stop callback runs FIRST and the store is closed before its file is
    # removed.
    on_exit(fn -> File.rm_rf(tmp) end)

    # Its OWN unnamed server. `prune_interval` is pushed far out so the writer
    # schedules no prune message during the suspended-mailbox window.
    store =
      start_supervised!(
        {EvoGit.AgentState,
         database: Path.join(tmp, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000},
        id: {EvoGit.AgentState, System.unique_integer([:positive])}
      )

    Process.put(:evogit_agent_state_server, store)

    {:ok, store: store, tmp: tmp}
  end

  defp unique_agent_id, do: 9_980_000 + System.unique_integer([:positive])

  defp unique_task_id, do: "checkpoint-boundary-#{System.unique_integer([:positive])}"

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  # `n` structurally identical messages on every call, so `msgs(m)` is always a
  # PREFIX of `msgs(n)` for `m <= n` (the append cases rely on that).
  defp msgs(n), do: Enum.map(1..n//1, fn index -> message(:user, "m#{index}") end)

  defp run_state(task_id, agent_id, messages, overrides) do
    defaults = [
      agent_id: agent_id,
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new(messages),
      task_id: task_id,
      persistent_state: true,
      # Repo-less: `anchor_fields/4` short-circuits before touching git, so no
      # repository is needed for these fixtures.
      repo_less: true,
      turn: 0
    ]

    struct!(State, Keyword.merge(defaults, overrides))
  end

  defp baseline(task_id, agent_id),
    do: Process.get({:evogit_agent_state_baseline, task_id, agent_id})

  # The read-your-writes barrier: checkpoints are casts, so every read follows
  # `flush/0` instead of sleeping.
  defp load!(task_id, agent_id) do
    assert :ok = AgentState.flush()

    case AgentState.load(task_id, agent_id) do
      {:ok, record} -> record
      {:error, reason} -> flunk("expected a persisted record, got #{inspect(reason)}")
    end
  end

  # The isolated instance pid is a SUPERVISOR pid; its writer is the one child —
  # the process the checkpoint cast actually lands in.
  defp writer_pid(supervisor) do
    writer =
      supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {EvoGit.AgentState.Server, pid, :worker, _modules} when is_pid(pid) -> pid
        _other -> nil
      end)

    writer || flunk("no agent-state writer under #{inspect(supervisor)}")
  end

  defp queue_len(pid) do
    {:message_queue_len, length} = Process.info(pid, :message_queue_len)
    length
  end

  # --- 1. Long transcript append --------------------------------------------

  describe "long transcript append" do
    test "extends the stored transcript by exactly ONE tail chunk" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      messages = msgs(220)

      # The run's FIRST durable row (a full `:rewrite`) also plants the
      # process-dictionary baseline the next boundary classifies against.
      assert :ok = Persistence.initial_snapshot(run_state(task_id, agent_id, messages, turn: 1))

      record = load!(task_id, agent_id)
      assert record.message_count == 220
      assert record.chunk_count == 1
      assert record.messages == messages
      assert baseline(task_id, agent_id) == 220

      extended = msgs(223)

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, messages, turn: 1),
                 run_state(task_id, agent_id, extended, turn: 2)
               )

      record = load!(task_id, agent_id)

      # The stored transcript is the FULL new list…
      assert record.messages == extended
      assert record.message_count == 223
      # …but only ONE chunk row was added (the initial rewrite + this tail):
      # a re-sent prefix would have produced more chunks.
      assert record.chunk_count == 2
      assert record.fields[:turn] == 2
      assert baseline(task_id, agent_id) == 223
    end
  end

  # --- 2. Long transcript rewrite -------------------------------------------

  describe "long transcript rewrite" do
    test "a non-prefix list replaces the transcript wholesale (back to ONE chunk)" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      messages = msgs(220)

      assert :ok = Persistence.initial_snapshot(run_state(task_id, agent_id, messages, turn: 1))

      record = load!(task_id, agent_id)
      assert record.message_count == 220
      assert record.chunk_count == 1

      # Post-compression shape: the SAME length and the SAME `compression_count`,
      # but the first message changed — so `messages` is NOT a prefix of it.
      diverged = [message(:user, "m1-CHANGED") | Enum.drop(messages, 1)]
      assert length(diverged) == 220

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, messages, turn: 1, compression_count: 0),
                 run_state(task_id, agent_id, diverged, turn: 2, compression_count: 0)
               )

      record = load!(task_id, agent_id)

      assert record.messages == diverged
      refute record.messages == messages
      assert record.message_count == 220
      # A rewrite REPLACES the previous chunks rather than appending to them.
      assert record.chunk_count == 1
      assert record.fields[:turn] == 2
      assert baseline(task_id, agent_id) == 220
    end
  end

  # --- 3. Unchanged state does NO store work --------------------------------

  describe "unchanged state" do
    test "a boundary with nothing new issues NO cast and leaves the record unchanged", %{
      store: store
    } do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      messages = msgs(5)

      assert :ok = Persistence.initial_snapshot(run_state(task_id, agent_id, messages, turn: 1))

      settled = load!(task_id, agent_id)
      assert settled.message_count == 5
      assert settled.chunk_count == 1
      assert settled.fields[:turn] == 1
      assert baseline(task_id, agent_id) == 5

      writer = writer_pid(store)

      # Drain anything still queued BEFORE the measurement window: the only
      # thing that may appear in the writer's mailbox afterwards is a cast this
      # boundary would have issued.
      assert :ok = AgentState.flush()

      old = run_state(task_id, agent_id, messages, turn: 1)
      copy = run_state(task_id, agent_id, messages, turn: 1)

      :ok = :sys.suspend(writer)

      try do
        assert queue_len(writer) == 0

        # Same transcript list content, same volatile scalars, matching
        # baseline ⇒ the boundary learned nothing.
        assert :ok = Persistence.checkpoint(old, copy)

        # A `:append` (even with an empty tail) or a `:rewrite` would be a CAST
        # sitting in the SUSPENDED writer's mailbox. The early return leaves it
        # empty — absence is proven by construction, not by a timed window.
        assert queue_len(writer) == 0
      after
        :ok = :sys.resume(writer)
      end

      # And the stored record is byte-identical: no message growth, no chunk
      # growth, no scalar drift (what a redundant empty-tail append would have
      # re-upserted).
      record = load!(task_id, agent_id)
      assert record.message_count == 5
      assert record.chunk_count == 1
      assert record.messages == messages
      assert record.fields[:turn] == 1
      assert record.completed_at == nil
    end
  end

  # --- 4. Cheap boundary cost -----------------------------------------------

  describe "boundary cost" do
    test "classifying a 500-message boundary stays far below the generous budget" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      messages = msgs(500)

      assert :ok = Persistence.initial_snapshot(run_state(task_id, agent_id, messages, turn: 1))
      assert load!(task_id, agent_id).message_count == 500
      assert baseline(task_id, agent_id) == 500

      extended = msgs(503)

      old = run_state(task_id, agent_id, messages, turn: 1)
      new = run_state(task_id, agent_id, extended, turn: 2)

      # The measured WALL-CLOCK cost of ONE served boundary on an idle host:
      # 100-250 µs (repeated runs of this file; the range moves with host load,
      # which is why the assertion below is a generous ceiling). The
      # former form allocated a fresh copy of the whole prefix (`Enum.take/2`)
      # on every boundary; a regression there is visible as a jump well past
      # this range.
      {micros, :ok} = :timer.tc(fn -> Persistence.checkpoint(old, new) end)

      assert micros < @boundary_budget_us,
             "boundary classification measured #{micros} µs, above the generous " <>
               "#{@boundary_budget_us} µs ceiling"

      # The measured boundary really was an APPEND (not a silently skipped one).
      record = load!(task_id, agent_id)
      assert record.message_count == 503
      assert record.chunk_count == 2
      assert record.messages == extended
      assert record.fields[:turn] == 2
    end
  end
end
