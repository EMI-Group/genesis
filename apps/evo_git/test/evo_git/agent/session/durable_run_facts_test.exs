defmodule EvoGit.Agent.Session.DurableRunFactsTest.StubAgent do
  @moduledoc """
  The role the durable-run-facts fixtures run AS: a fixed system prompt, no
  tools and the default read/read_write + delegation callbacks, so
  `EvoGit.AgentState.Redispatch.build/2` can project its role facts.

  Defined ABOVE the test module on purpose — `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the durable run-facts stub agent."

  @doc "No tools: nothing here ever runs one."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.DurableRunFactsTest do
  @moduledoc """
  The DURABLE RUN FACTS and the durable ROW LIFECYCLE of one run, at the
  `EvoGit.Agent.Session.Persistence` boundary (`docs/agent-run-durability.md`).

  Pinned here:

    * `initial_snapshot/1` writes the run's ONE row the moment it starts — the
      WHOLE transcript and EVERY scalar, `status: "running"` — and it sets the
      process-dictionary baseline so the next turn boundary is an APPEND of the
      tail, not a second full rewrite;
    * it anchors an already-known `current_commit` (`refs/genesis/agent-state/…`)
      and never anchors a repo-less run;
    * the batch-clearing checkpoint (`pending_tool_batch != nil → nil`) deletes
      exactly the `done` children of THAT batch, whether the OLD marker is
      atom-keyed (live) or STRING-keyed (restored from JSON);
    * the `redispatch` blob survives the row's JSON round-trip and rebuilds the
      same spec options through `EvoGit.AgentState.Redispatch.to_spec_opts/1`;
    * `persistent_state: false` stays FULLY inert (no row, no baseline, no ref).

  ## Why `async: true` — no BEAM-global is touched

  Each test starts its OWN UNNAMED `EvoGit.AgentState` server on a per-test
  SQLite file under ExUnit's `:tmp_dir` and pins it on the TEST process
  dictionary (`:evogit_agent_state_server`), which is exactly the process
  calling `Persistence` — so both the cast target and the baseline key are
  test-local. Task and agent ids are unique per test, the git fixture is that
  test's own `:tmp_dir` repository, and the anchor dedupe lives in the caller's
  process dictionary.

  Every read-backed assertion follows `EvoGit.AgentState.flush/0` (the
  documented read-your-writes barrier) — never a sleep as an assertion.
  """

  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Session.DurableRunFactsTest.StubAgent
  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Anchor
  alias EvoGit.AgentState.Redispatch
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode

  # --- Fixtures -------------------------------------------------------------

  setup %{tmp_dir: tmp_dir} do
    store_dir = Path.join(tmp_dir, "state")
    File.mkdir_p!(store_dir)

    # Its OWN unnamed server: `EvoGit.AgentState.child_spec/1` hardcodes
    # `id: __MODULE__`, so the child id must be overridden per test.
    store =
      start_supervised!(
        {EvoGit.AgentState, database: Path.join(store_dir, "agent_state.sqlite"), name: nil},
        id: {EvoGit.AgentState, System.unique_integer([:positive])}
      )

    Process.put(:evogit_agent_state_server, store)

    {:ok, store: store, repo_dir: Path.join(tmp_dir, "repo")}
  end

  defp unique_agent_id, do: 10_040_000 + System.unique_integer([:positive])

  defp unique_task_id, do: "durable-run-facts-#{System.unique_integer([:positive])}"

  defp context(messages), do: ReqLLM.Context.new(messages)

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  defp msgs(n), do: Enum.map(1..n//1, fn index -> message(:user, "m#{index}") end)

  defp run_state(task_id, agent_id, messages, overrides \\ []) do
    defaults = [
      task_id: task_id,
      agent_id: agent_id,
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      context: context(messages),
      persistent_state: true
    ]

    struct!(State, Keyword.merge(defaults, overrides))
  end

  defp load!(task_id, agent_id) do
    AgentState.flush()

    case AgentState.load(task_id, agent_id) do
      {:ok, record} -> record
      {:error, reason} -> flunk("expected a persisted record, got #{inspect(reason)}")
    end
  end

  # The ONE rewrite a run's first checkpoint performs.
  defp seed!(task_id, agent_id, overrides) do
    :ok =
      Persistence.checkpoint(
        run_state(task_id, agent_id, []),
        run_state(task_id, agent_id, msgs(2), overrides)
      )

    AgentState.flush()
    :ok
  end

  # A finished CHILD: seeded, then completed (which marks it `done` and keeps
  # the row — the parent's batch-clearing checkpoint is its only deleter).
  defp done_child!(task_id, parent_id, spawn_turn) do
    agent_id = unique_agent_id()

    overrides = [
      parent_id: parent_id,
      depth: 1,
      spawn_turn: spawn_turn,
      spawn_index: 0,
      branch: "evogit-agent-T1-A#{spawn_turn}"
    ]

    seed!(task_id, agent_id, overrides)
    :ok = Persistence.complete(run_state(task_id, agent_id, msgs(2), overrides), "child report")
    AgentState.flush()
    agent_id
  end

  # The in-flight marker as a RESTORED run sees it: STRING-keyed, straight out
  # of the JSON column (`EvoGit.Agent.ToolBatch.normalize/1` is the one place
  # that rebuilds the atom-keyed shape).
  defp stored_batch(turn) do
    %{
      "turn" => turn,
      "started_at" => "2026-01-01T00:00:00Z",
      "calls" => [%{"index" => 0, "id" => "call_1", "name" => "read", "class" => "read"}]
    }
  end

  # --- 1. initial_snapshot/1 ------------------------------------------------

  describe "initial_snapshot/1" do
    test "writes ONE durable row with the whole transcript and every scalar before any turn" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      redispatch = %{"agent_type" => "read", "spawn_turn" => nil, "objective" => "root run"}

      state =
        run_state(task_id, agent_id, msgs(2),
          branch: "evogit-agent-T1-A1",
          base_commit: "base-sha-1",
          redispatch: redispatch
        )

      assert :ok = Persistence.initial_snapshot(state)

      record = load!(task_id, agent_id)

      # ONE full rewrite: the row exists before the first turn with the run's
      # whole (system + first user) conversation.
      assert record.message_count == 2
      assert record.chunk_count == 1
      assert record.messages == msgs(2)
      assert record.completed_at == nil

      fields = record.fields

      # The LIVE-ness a checkpoint path always writes, so a resumed run
      # RE-OPENS a previously `done` row.
      assert fields[:status] == "running"
      assert fields[:turn] == 0

      # The durable run facts.
      assert fields[:branch] == "evogit-agent-T1-A1"
      assert fields[:base_commit] == "base-sha-1"
      assert fields[:spawn_turn] == nil
      assert fields[:spawn_index] == nil
      assert fields[:redispatch] == redispatch
      # Nothing known yet: no commit was advanced, so no anchor.
      assert fields[:anchor_ref] == nil
      assert fields[:current_commit] == nil

      # The baseline is set, so the NEXT boundary is an APPEND of the tail
      # (a second chunk) instead of another full rewrite (which would collapse
      # the row back to one chunk).
      assert Process.get({:evogit_agent_state_baseline, task_id, agent_id}) == 2

      assert :ok = Persistence.checkpoint(state, %{state | context: context(msgs(3))})

      extended = load!(task_id, agent_id)
      assert extended.message_count == 3
      assert extended.chunk_count == 2
      assert extended.messages == msgs(3)
    end

    test "is inert without persistent_state or without an identity" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      assert :ok =
               Persistence.initial_snapshot(
                 run_state(task_id, agent_id, msgs(2), persistent_state: false)
               )

      # No valid (task_id, agent_id) — and not even a state struct.
      assert :ok = Persistence.initial_snapshot(run_state(nil, agent_id, msgs(2)))
      assert :ok = Persistence.initial_snapshot(run_state("  ", agent_id, msgs(2)))
      assert :ok = Persistence.initial_snapshot(:not_a_state)

      AgentState.flush()

      assert AgentState.load(task_id, agent_id) == {:error, :not_found}
      assert AgentState.roster(task_id) == []
      assert Process.get({:evogit_agent_state_baseline, task_id, agent_id}) == nil
    end

    test "anchors an already-known current_commit at refs/genesis/agent-state", %{
      repo_dir: repo_dir
    } do
      {repo, sha} = init_repo(repo_dir)
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      state =
        run_state(task_id, agent_id, msgs(2),
          repo_path: repo,
          current_commit: sha,
          base_commit: sha
        )

      assert :ok = Persistence.initial_snapshot(state)

      record = load!(task_id, agent_id)
      ref_name = "refs/genesis/agent-state/#{task_id}/#{agent_id}"

      assert record.fields[:anchor_ref] == ref_name
      assert Anchor.ref(task_id, agent_id) == ref_name
      assert record.fields[:current_commit] == sha

      # Fire-and-forget: the ref lands asynchronously in a supervised task.
      assert wait_for_ref(repo, ref_name, sha) == {:ok, sha}
    end

    test "never anchors a repo-less run", %{repo_dir: repo_dir} do
      {repo, sha} = init_repo(repo_dir)
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      state =
        run_state(task_id, agent_id, msgs(2),
          repo_path: repo,
          repo_less: true,
          current_commit: sha
        )

      assert :ok = Persistence.initial_snapshot(state)

      record = load!(task_id, agent_id)
      assert record.fields[:current_commit] == sha
      assert record.fields[:anchor_ref] == nil
      assert match?({:error, _}, Git.rev_parse(repo, Anchor.ref(task_id, agent_id)))
    end
  end

  # --- 2. Done-child cleanup at the batch-clearing checkpoint --------------

  describe "the batch-clearing checkpoint" do
    test "deletes exactly the done children of THAT batch" do
      task_id = unique_task_id()
      parent_id = unique_agent_id()

      in_batch = done_child!(task_id, parent_id, 3)
      later_batch = done_child!(task_id, parent_id, 4)

      # Both finished children are `done` rows the parent has not consumed yet.
      assert load!(task_id, in_batch).fields[:status] == "done"
      assert load!(task_id, later_batch).fields[:status] == "done"

      old_parent = %{
        run_state(task_id, parent_id, msgs(4))
        | pending_tool_batch: stored_batch(3)
      }

      # The transition `marker != nil → nil` IS the batch boundary.
      assert :ok = Persistence.checkpoint(old_parent, %{old_parent | pending_tool_batch: nil})

      AgentState.flush()

      assert AgentState.load(task_id, in_batch) == {:error, :not_found}

      assert {:ok, %{fields: fields}} = AgentState.load(task_id, later_batch)
      assert fields[:status] == "done"
      assert fields[:spawn_turn] == 4
    end

    test "deletes nothing while the batch is still in flight or the turn is unknown" do
      task_id = unique_task_id()
      parent_id = unique_agent_id()

      in_batch = done_child!(task_id, parent_id, 3)

      # A checkpoint that does NOT clear the marker is not a batch boundary.
      still_running = %{
        run_state(task_id, parent_id, msgs(3))
        | pending_tool_batch: stored_batch(3)
      }

      assert :ok =
               Persistence.checkpoint(still_running, %{
                 still_running
                 | context: context(msgs(4)),
                   pending_tool_batch: stored_batch(3)
               })

      AgentState.flush()
      assert {:ok, %{fields: fields}} = AgentState.load(task_id, in_batch)
      assert fields[:status] == "done"

      # A marker without an integer turn cannot name a batch: nothing is deleted.
      nameless = %{still_running | pending_tool_batch: %{"calls" => stored_batch(3)["calls"]}}

      assert :ok = Persistence.checkpoint(nameless, %{nameless | pending_tool_batch: nil})

      AgentState.flush()
      assert {:ok, _record} = AgentState.load(task_id, in_batch)
    end
  end

  # --- 3. The redispatch blob ----------------------------------------------

  describe "the redispatch blob" do
    test "survives the row's JSON round-trip and rebuilds the same spec options" do
      task_id = unique_task_id()
      agent_id = unique_agent_id()
      repo = "/tmp/durable-run-facts-repo"

      spec = %AgentSpec{
        context_node: %ContextNode{path: "./lib", repo: repo},
        phylo_node: nil,
        agent_module: StubAgent,
        objective: "child objective",
        repo_id: "primary",
        opts: [repo_less: true, max_turns: 40, node_path: "./lib", archive: true]
      }

      blob =
        Redispatch.build(spec,
          parent_id: 424_242,
          depth: 1,
          spawn_turn: 3,
          spawn_index: 1,
          task_number: 7,
          task_local_id: 12,
          tools: ["read", "bash"],
          model_spec: %{"provider_profile_id" => "acct", "model" => "m1"},
          custom_agent_id: "custom-1",
          quality_level: "deep",
          repo_less: true
        )

      # JSON-clean BY CONSTRUCTION: the store encodes this column with Jason, so
      # it must re-encode to the same term.
      assert Jason.decode!(Jason.encode!(blob)) == blob

      state = run_state(task_id, agent_id, msgs(2), redispatch: blob)
      assert :ok = Persistence.initial_snapshot(state)

      stored = load!(task_id, agent_id).fields[:redispatch]

      # A STRING-keyed map, exactly what a JSON column gives back.
      assert is_map(stored)
      assert stored["spawn_turn"] == 3
      assert stored["objective"] == "child objective"

      opts = Redispatch.to_spec_opts(stored)

      # The rebuildable facts a resume needs, all recovered from the row.
      assert opts[:parent_id] == 424_242
      assert opts[:depth] == 1
      assert opts[:spawn_turn] == 3
      assert opts[:spawn_index] == 1
      assert opts[:task_number] == 7
      assert opts[:task_local_id] == 12
      assert opts[:tools] == ["read", "bash"]
      assert opts[:custom_agent_id] == "custom-1"
      assert opts[:model_spec] == %{"provider_profile_id" => "acct", "model" => "m1"}
      assert opts[:node_path] == "./lib"
      assert opts[:repo_id] == "primary"
      assert opts[:objective] == "child objective"
      assert opts[:quality_level] == "deep"
      assert opts[:archive] == true
      assert opts[:repo_less] == true
      assert opts[:max_turns] == 40
      assert opts[:agent_type] == StubAgent.agent_type()
      assert opts[:delegation_level] == StubAgent.delegation_level()

      # The persisted blob and the live one rebuild the SAME options.
      assert opts == Redispatch.to_spec_opts(blob)
    end
  end

  # --- git fixture ----------------------------------------------------------

  # A throw-away repo with one commit on the default branch. Identity comes from
  # `EvoGit.GitEnv` through the adapter (no `-c` flags needed).
  defp init_repo(dir) do
    File.mkdir_p!(dir)
    assert {:ok, _} = Git.init(dir)
    File.write!(Path.join(dir, "README.md"), "# fixture\n")
    assert {:ok, _} = Git.add(dir)
    assert {:ok, _} = Git.commit(dir, "initial")
    {:ok, sha} = Git.rev_parse(dir, "HEAD")
    {dir, sha}
  end

  # Bounded poll: `Anchor.anchor/4` is fire-and-forget, so the ref lands
  # asynchronously in a supervised task. No fixed sleep as an assertion.
  defp wait_for_ref(repo, ref_name, expected, attempts \\ 300) do
    case Git.rev_parse(repo, ref_name) do
      {:ok, ^expected} = ok ->
        ok

      other ->
        if attempts > 0 do
          Process.sleep(10)
          wait_for_ref(repo, ref_name, expected, attempts - 1)
        else
          other
        end
    end
  end
end
