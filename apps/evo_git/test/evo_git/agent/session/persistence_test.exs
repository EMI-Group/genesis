defmodule EvoGit.Agent.Session.PersistenceTest.StubAgent do
  @moduledoc """
  The role the persistence fixtures run AS: a fixed system prompt and NO tools.

  Defined ABOVE the test module on purpose — `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the persistence stub agent."

  @doc "No tools: nothing in these tests ever runs one."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.PersistenceTest do
  @moduledoc """
  The UNIT-level contract of the durable per-agent state layer:
  `EvoGit.Agent.Session.Persistence` (state ↔ checkpoint-entry translation,
  append/rewrite classification, the process-dictionary baseline, restore
  merge, resync and completion) over a real, isolated `EvoGit.AgentState`
  SQLite store.

  Pinned here:

    * opt-out inertness — `persistent_state: false` issues NO cast, writes no
      baseline and leaves `Setup.build_initial_state/3`'s fresh state alone;
    * the first checkpoint of a run is a FULL `:rewrite` (one chunk);
    * a genuine prefix extension is an `:append` (tail only: `+1` chunk);
    * a store-level `:append` with an empty tail only UPSERTs the scalar fields,
      while `Persistence.checkpoint/2` classifies an IDENTICAL list as `:skip`
      and therefore issues NO cast at all (a behavioural gap, documented on the
      test that pins it);
    * a compression, and any structural divergence (non-prefix with the same
      compression count), is a `:rewrite` of the full list (back to ONE chunk);
    * a store/session continuity GAP answers `{:agent_state_resync, …}` and
      writes NOTHING; `resync/1` heals it with one full rewrite;
    * `restore/3` merges ONLY conversation state (the stored transcript is
      authoritative) and keeps identity/worktree/paths/model/phase FRESH, with
      `:not_found` / `:corrupt_state` / `:empty_state` / `:no_identity` all
      total;
    * `complete/1` marks the row completed and keeps it.

  ## Why `async: true` — no BEAM-global is touched

  Each test starts its OWN UNNAMED `EvoGit.AgentState` server on a
  per-test-unique SQLite file under `System.tmp_dir!()` and pins it on the TEST
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

  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.Session.PersistenceTest.StubAgent
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentState
  alias EvoGit.Core.ContextNode

  # --- Fixtures -------------------------------------------------------------

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "evogit_agent_state_persist_#{:os.getpid()}_#{System.unique_integer([:positive])}"
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

    {:ok, store: store, tmp: tmp}
  end

  defp unique_agent_id, do: 9_990_000 + System.unique_integer([:positive])

  defp unique_task_id, do: "persist-test-#{System.unique_integer([:positive])}"

  defp context(messages), do: ReqLLM.Context.new(messages)

  defp context(messages, tools), do: %{ReqLLM.Context.new(messages) | tools: tools}

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  # `n` structurally identical messages on every call, so two independently
  # built lists compare equal (the store round-trip must be byte-exact).
  defp msgs(n), do: Enum.map(1..n//1, fn index -> message(:user, "m#{index}") end)

  defp state(overrides \\ []) do
    defaults = [
      agent_id: unique_agent_id(),
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      context: context([]),
      task_id: unique_task_id(),
      persistent_state: true
    ]

    struct!(State, Keyword.merge(defaults, overrides))
  end

  # One state of ONE run: the identity is pinned, everything else overrides.
  defp run_state(task_id, agent_id, messages, overrides \\ []) do
    state(
      Keyword.merge(
        [task_id: task_id, agent_id: agent_id, context: context(messages)],
        overrides
      )
    )
  end

  defp baseline(task_id, agent_id),
    do: Process.get({:evogit_agent_state_baseline, task_id, agent_id})

  defp load!(task_id, agent_id) do
    AgentState.flush()

    case AgentState.load(task_id, agent_id) do
      {:ok, record} -> record
      {:error, reason} -> flunk("expected a persisted record, got #{inspect(reason)}")
    end
  end

  # Seeds ONE run's durable record exactly as the session hot path would: the
  # first checkpoint of a run is always a full `:rewrite`.
  defp seed!(task_id, agent_id, messages, overrides) do
    :ok =
      Persistence.checkpoint(
        run_state(task_id, agent_id, []),
        run_state(task_id, agent_id, messages, overrides)
      )

    AgentState.flush()
    :ok
  end

  # The exact `ctx` key set `EvoGit.Agent.Session.build_state/2` supplies to
  # `Setup.build_initial_state/3` (every `fetch!`ed key must be present).
  defp build_ctx(task_id, agent_id, repo_path, overrides) do
    defaults = [
      agent_id: agent_id,
      depth: 0,
      context_node: %ContextNode{path: "./", repo: repo_path},
      repo_path: repo_path,
      current_commit: "base-sha",
      repo_root: repo_path,
      repo_id: "primary",
      repo_less: false,
      task_id: task_id,
      parent_id: nil,
      archive: false,
      persistent_state: true,
      restore_agent_state: false,
      foreign_repos: [],
      repo_notes: nil,
      max_turns: 32,
      max_depth: 2,
      max_retries: 3,
      compression_count: 0,
      llm_context_window: 128_000,
      llm_model: "test:model",
      llm_generation_params: [],
      model_spec: nil,
      provider_profile_id: nil,
      model_id: nil,
      model_id_locked: false,
      prompt_cache_key: nil,
      session_mode: :oneshot,
      quality_level: nil,
      custom_agent_id: nil,
      attachments: nil
    ]

    Keyword.merge(defaults, overrides)
  end

  # A private workspace dir for the `Setup.build_initial_state/3` cases.
  defp workspace!(agent_id, label) do
    tmp = Path.join(System.tmp_dir!(), "evogit_persist_#{label}_#{agent_id}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    tmp
  end

  # Corrupts the stored row's message count so the rebuilt transcript no longer
  # agrees with the row (the `:corrupt_state` shape `Store.load/3` rejects).
  defp corrupt_message_count!(store, task_id, agent_id) do
    repo = EvoGit.AgentState.repo(store)
    assert is_pid(repo)

    EvoGit.Store.RepoScope.with_repo(repo, fn ->
      {:ok, _result} =
        Ecto.Adapters.SQL.query(
          EvoGit.Repo.get_dynamic_repo(),
          "UPDATE agent_states SET message_count = message_count + 5 " <>
            "WHERE task_id = ? AND agent_id = ?",
          [task_id, agent_id]
        )
    end)

    :ok
  end

  # --- 1. Opt-out inertness (the product contract) --------------------------

  describe "opt-out inertness" do
    test "checkpoint/2 is fully inert for a non-persistent state" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      old = run_state(task_id, agent_id, [])
      new = run_state(task_id, agent_id, msgs(3), turn: 1, persistent_state: false)

      assert new.persistent_state == false

      # `false` is the struct DEFAULT — opt-in is explicit, so a hand-built
      # state (unit test, fixture, archived copy) can never write.
      assert struct(State,
               agent_id: agent_id,
               agent_module: StubAgent,
               depth: 0,
               node_path: "./",
               context: context([])
             ).persistent_state == false

      assert :ok = Persistence.checkpoint(old, new)
      assert baseline(task_id, agent_id) == nil

      AgentState.flush()
      assert AgentState.load(task_id, agent_id) == {:error, :not_found}
    end

    test "build_initial_state/3 restores NOTHING when persistent_state is false" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      seeded_messages = msgs(4)

      seed!(task_id, agent_id, seeded_messages, turn: 4, objective: "seeded objective")

      tmp = workspace!(agent_id, "build")

      # (a) restore_agent_state: true but persistent_state: false ⇒ NO load.
      assert {:ok, built} =
               Setup.build_initial_state(
                 StubAgent,
                 "the persistence objective",
                 build_ctx(task_id, agent_id, tmp,
                   persistent_state: false,
                   restore_agent_state: true
                 )
               )

      assert built.persistent_state == false
      assert length(built.context.messages) == 2

      assert [%ReqLLM.Message{role: :system}, %ReqLLM.Message{role: :user}] =
               built.context.messages

      refute built.context.messages == seeded_messages

      # (b) CONTROL: the same ctx with persistent_state: true DOES restore the
      # seeded transcript verbatim, so (a) is not vacuous.
      assert {:ok, restored} =
               Setup.build_initial_state(
                 StubAgent,
                 "the persistence objective",
                 build_ctx(task_id, agent_id, tmp,
                   persistent_state: true,
                   restore_agent_state: true
                 )
               )

      assert restored.persistent_state == true
      assert restored.context.messages == seeded_messages
      assert restored.turn == 4
      assert restored.objective == "seeded objective"
    end
  end

  # --- 2. First checkpoint is a full rewrite --------------------------------

  describe "first checkpoint" do
    test "an absent baseline makes the first checkpoint a full rewrite (ONE chunk)" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      messages = msgs(3)

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, [], turn: 0),
                 run_state(task_id, agent_id, messages, turn: 1)
               )

      record = load!(task_id, agent_id)

      assert record.messages == messages
      assert record.message_count == 3
      assert record.chunk_count == 1
      assert record.fields[:turn] == 1
      assert record.completed_at == nil
    end
  end

  # --- 3. Append classification --------------------------------------------

  describe "append classification" do
    test "a later turn whose list extends the previous one appends ONLY the tail" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      first = msgs(3)
      second = msgs(5)

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, [], turn: 0),
                 run_state(task_id, agent_id, first, turn: 1)
               )

      record = load!(task_id, agent_id)
      assert record.message_count == 3
      assert record.chunk_count == 1
      assert baseline(task_id, agent_id) == 3

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, first, turn: 1),
                 run_state(task_id, agent_id, second, turn: 2)
               )

      record = load!(task_id, agent_id)

      # Tail-only write: the message count grew by the TAIL (2) and exactly ONE
      # chunk row was added — `chunk_count` is what proves it structurally.
      assert record.message_count == 5
      assert record.chunk_count == 2
      assert record.messages == second
      assert record.fields[:turn] == 2
      assert baseline(task_id, agent_id) == 5
    end
  end

  # --- 4. No-chunk append (store semantics) + empty tail --------------------

  describe "empty-tail handling" do
    test "a store-level :append with an empty tail only UPSERTs the scalar fields" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      seed!(task_id, agent_id, msgs(3), turn: 1)

      assert :ok =
               AgentState.checkpoint(task_id, agent_id, %{
                 kind: :append,
                 base_seq: 3,
                 messages: [],
                 fields: %{turn: 3},
                 owner: self()
               })

      record = load!(task_id, agent_id)

      # No new chunk row, no message growth — but the scalar UPSERT still ran.
      assert record.message_count == 3
      assert record.chunk_count == 1
      assert record.fields[:turn] == 3
      assert record.messages == msgs(3)
    end

    test "Persistence.checkpoint/2 with an IDENTICAL list classifies as :skip (no cast)" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      messages = msgs(3)

      seed!(task_id, agent_id, messages, turn: 1)
      assert baseline(task_id, agent_id) == 3

      # OBSERVED CONTRACT (a behavioural gap vs "the scalar turn is still
      # updated"): `classify/6` returns `:skip` for an empty tail, so NO cast is
      # issued and the stored scalar `turn` does NOT advance.
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, messages, turn: 1),
                 run_state(task_id, agent_id, messages, turn: 2)
               )

      record = load!(task_id, agent_id)

      assert record.message_count == 3
      assert record.chunk_count == 1
      assert record.fields[:turn] == 1
      assert baseline(task_id, agent_id) == 3
    end
  end

  # --- 5. Compression ⇒ rewrite --------------------------------------------

  describe "compression rewrites" do
    test "a compression checkpoint rewrites the FULL list even when it extends the old one" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      first = msgs(3)
      second = msgs(5)

      seed!(task_id, agent_id, first, turn: 1, compression_count: 0)

      # `first` IS a prefix of `second`, so an append would have produced a
      # SECOND chunk; the bumped compression count forces a rewrite instead.
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, first, turn: 1, compression_count: 0),
                 run_state(task_id, agent_id, second, turn: 2, compression_count: 1)
               )

      record = load!(task_id, agent_id)

      assert record.chunk_count == 1
      assert record.message_count == 5
      assert record.messages == second
      assert record.fields[:compression_count] == 1
    end

    test "a compression that REPLACES the transcript with a shorter one rewrites it" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      replaced = msgs(1)

      seed!(task_id, agent_id, msgs(5), turn: 2, compression_count: 0)

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, msgs(5), turn: 2, compression_count: 0),
                 run_state(task_id, agent_id, replaced, turn: 2, compression_count: 1)
               )

      record = load!(task_id, agent_id)

      assert record.chunk_count == 1
      assert record.message_count == 1
      assert record.messages == replaced
    end
  end

  # --- 6. Structural non-prefix ⇒ rewrite ----------------------------------

  describe "structural divergence" do
    test "a non-prefix list with an UNCHANGED compression count rewrites, never appends" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      adopted = msgs(2)
      appended = msgs(4)

      diverged = [message(:user, "m1"), message(:user, "CHANGED"), message(:user, "m3")]

      seed!(task_id, agent_id, adopted, turn: 1)

      # First make the transcript span TWO chunks, so "back to 1" is meaningful.
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, adopted, turn: 1),
                 run_state(task_id, agent_id, appended, turn: 2)
               )

      record = load!(task_id, agent_id)
      assert record.chunk_count == 2
      assert record.message_count == 4

      # `appended`(4) is NOT a prefix of `diverged`(3) although the compression
      # count is unchanged ⇒ rewrite of the full new list.
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, appended, turn: 2),
                 run_state(task_id, agent_id, diverged, turn: 3)
               )

      record = load!(task_id, agent_id)

      assert record.chunk_count == 1
      assert record.message_count == 3
      assert record.messages == diverged
      assert record.messages != appended
      assert record.fields[:turn] == 3
    end
  end

  # --- 7. Gap ⇒ resync -----------------------------------------------------

  describe "continuity gap" do
    test "a diverged store answers {:agent_state_resync, ...} and resync/1 heals it" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      adopted = msgs(3)
      extended = msgs(4)

      seed!(task_id, agent_id, adopted, turn: 1)

      # Diverge the STORE from what the session believes (a lost/rolled-back
      # checkpoint) with a direct full rewrite.
      assert :ok =
               AgentState.checkpoint(task_id, agent_id, %{
                 kind: :rewrite,
                 messages: msgs(10),
                 fields: %{},
                 owner: self()
               })

      assert load!(task_id, agent_id).message_count == 10

      # A genuine prefix extension — but the append's base_seq no longer matches
      # the stored count, so NOTHING is written.
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, adopted, turn: 1),
                 run_state(task_id, agent_id, extended, turn: 2)
               )

      assert_receive {:agent_state_resync, ^task_id, ^agent_id}, 5_000

      record = load!(task_id, agent_id)
      assert record.message_count == 10
      assert record.chunk_count == 1
      assert record.messages == msgs(10)
      assert record.fields[:turn] == 1

      # The healing rewrite replaces the store's copy wholesale.
      assert :ok = Persistence.resync(run_state(task_id, agent_id, extended, turn: 2))

      record = load!(task_id, agent_id)

      assert record.message_count == 4
      assert record.chunk_count == 1
      assert record.messages == extended
      assert record.fields[:turn] == 2
      assert baseline(task_id, agent_id) == 4
    end

    test "resync/1 and checkpoint/2 are inert for a non-persistent state" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      inert = [persistent_state: false]

      assert :ok = Persistence.resync(run_state(task_id, agent_id, msgs(2), inert))

      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, [], inert),
                 run_state(task_id, agent_id, msgs(2), inert)
               )

      assert baseline(task_id, agent_id) == nil
      AgentState.flush()
      assert AgentState.load(task_id, agent_id) == {:error, :not_found}
    end

    test "a state with no durable identity is skipped by every entry point" do
      agent_id = unique_agent_id()

      skipped_states = [
        run_state(nil, agent_id, msgs(2), turn: 1),
        run_state("   ", agent_id + 1, msgs(2), turn: 1),
        run_state(unique_task_id(), "7", msgs(2), turn: 1)
      ]

      for skipped <- skipped_states do
        assert :ok =
                 Persistence.checkpoint(run_state(skipped.task_id, skipped.agent_id, []), skipped)

        assert :ok = Persistence.resync(skipped)
        assert :ok = Persistence.complete(skipped)
        assert baseline(skipped.task_id, skipped.agent_id) == nil
      end

      AgentState.flush()

      for skipped <- tl(skipped_states) do
        assert AgentState.load(skipped.task_id, skipped.agent_id) == {:error, :not_found}
      end
    end
  end

  # --- 8. Restore merge ----------------------------------------------------

  describe "restore/3" do
    test "merges ONLY conversation state: the stored transcript is authoritative" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      seeded_messages = msgs(4)

      seed!(task_id, agent_id, seeded_messages,
        turn: 7,
        usage: %Usage{input_tokens: 11, output_tokens: 22, total_tokens: 33},
        total_tokens: 33,
        compression_count: 2,
        prompt_cache_key: "cache-key-1",
        objective: "seeded objective",
        pending_inputs: ["queued"],
        current_commit: "abc123"
      )

      fresh =
        run_state("fresh-task", agent_id, msgs(2),
          context: context(msgs(2), [:fresh_tool]),
          repo_path: "/fresh/worktree",
          repo_root: "/fresh/root",
          node_path: "./fresh",
          model_spec: %{"model" => "fresh"},
          provider_profile_id: "fresh-profile",
          model_id: "fresh-model",
          prompt_cache_key: "fresh-cache",
          objective: "fresh objective",
          pending_inputs: [],
          current_commit: "fresh-sha",
          turn: 0,
          usage: %Usage{},
          total_tokens: 0,
          compression_count: 0,
          phase: :running
        )

      restored = Persistence.restore(fresh, task_id, agent_id)

      # Conversation state comes from the RECORD.
      assert restored.context.messages == seeded_messages
      assert restored.turn == 7
      assert restored.usage == %Usage{input_tokens: 11, output_tokens: 22, total_tokens: 33}
      assert restored.total_tokens == 33
      assert restored.compression_count == 2
      assert restored.prompt_cache_key == "cache-key-1"
      assert restored.objective == "seeded objective"
      assert restored.pending_inputs == ["queued"]
      assert restored.current_commit == "abc123"

      # The fresh context's TOOLS survive the transcript replacement.
      assert restored.context.tools == [:fresh_tool]

      # Identity / worktree / paths / model selection / phase stay FRESH.
      assert restored.agent_id == fresh.agent_id
      assert restored.task_id == "fresh-task"
      assert restored.repo_path == "/fresh/worktree"
      assert restored.repo_root == "/fresh/root"
      assert restored.node_path == "./fresh"
      assert restored.model_spec == %{"model" => "fresh"}
      assert restored.provider_profile_id == "fresh-profile"
      assert restored.model_id == "fresh-model"
      assert restored.phase == :running
      assert restored.persistent_state == true
    end

    test "every error path is total and leaves the caller's fresh state usable" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      seed!(task_id, agent_id, msgs(2), turn: 1)

      # A run with no stored row.
      assert Persistence.restore(state(), unique_task_id(), agent_id) == {:error, :not_found}

      # A row whose counts no longer agree with its chunks.
      corrupt_message_count!(Process.get(:evogit_agent_state_server), task_id, agent_id)
      assert Persistence.restore(state(), task_id, agent_id) == {:error, :corrupt_state}

      # A stored run with NO messages (`:rewrite` of an empty list ⇒ 0 chunks).
      empty_task = unique_task_id()
      empty = run_state(empty_task, agent_id, [])

      assert :ok = Persistence.checkpoint(empty, run_state(empty_task, agent_id, []))

      record = load!(empty_task, agent_id)
      assert record.message_count == 0
      assert record.chunk_count == 0

      assert Persistence.restore(state(), empty_task, agent_id) == {:error, :empty_state}

      # No durable identity at all.
      assert Persistence.restore(state(), nil, agent_id) == {:error, :no_identity}
      assert Persistence.restore(state(), "   ", agent_id) == {:error, :no_identity}
      assert Persistence.restore(state(), task_id, "7") == {:error, :no_identity}
      assert Persistence.restore(state(), task_id, nil) == {:error, :no_identity}

      # `Setup.build_initial_state/3` turns a `:not_found` restore into the
      # untouched FRESH state (never a raise, never a partial merge).
      tmp = workspace!(agent_id, "notfound")

      assert {:ok, built} =
               Setup.build_initial_state(
                 StubAgent,
                 "the persistence objective",
                 build_ctx(unique_task_id(), agent_id, tmp,
                   persistent_state: true,
                   restore_agent_state: true
                 )
               )

      assert length(built.context.messages) == 2
      assert built.turn == 0
      assert built.objective == "the persistence objective"
    end
  end

  # --- 9. complete/1 --------------------------------------------------------

  describe "complete/1" do
    test "is inert for a non-persistent state" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      assert :ok =
               Persistence.complete(run_state(task_id, agent_id, [], persistent_state: false))

      AgentState.flush()
      assert AgentState.load(task_id, agent_id) == {:error, :not_found}
    end

    test "marks a persisted run completed and KEEPS the row" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      seed!(task_id, agent_id, msgs(2), turn: 1)

      # The column's own default (a checkpoint never writes `status`).
      assert load!(task_id, agent_id).fields[:status] == "running"

      assert :ok = Persistence.complete(run_state(task_id, agent_id, []))

      record = load!(task_id, agent_id)

      assert record.fields[:status] == "completed"
      assert %DateTime{} = record.completed_at
      assert record.messages == msgs(2)
      assert record.message_count == 2
    end
  end
end
