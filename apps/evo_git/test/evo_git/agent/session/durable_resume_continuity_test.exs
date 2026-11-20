defmodule EvoGit.Agent.Session.DurableResumeContinuityTest.StubAgent do
  @moduledoc """
  The role the durable-resume-continuity fixtures run AS: a fixed system prompt
  and no tools.

  Defined ABOVE the test module on purpose — `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the durable resume continuity stub agent."

  @doc "No tools: nothing here ever runs one."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.DurableResumeContinuityTest do
  @moduledoc """
  The agent-side DURABLE-RESUME CONTINUITY contract: what a resumed run gets
  back from its durable row, what it must NOT get back, and what it is told
  when the row cannot be used.

  The producer under test is the real one — `Persistence.initial_snapshot/1`
  plus a `Persistence.checkpoint/2` turn boundary — so what is restored is
  exactly what production writes, never a hand-shaped row.

  Pinned here:

    * **full continuity** — a multi-message, multi-turn transcript ending in a
      `:tool` result, plus `turn`, `%Usage{}`, `total_tokens`,
      `compression_count`, `objective`, `prompt_cache_key`, `current_commit`
      and `pending_inputs`, all come back through
      `Setup.build_initial_state/3` when the ctx asks to restore, while
      `repo_path`, `worktree`, `repo_root`, `branch` and `base_commit` stay the
      FRESH dispatch's;
    * **restore failure** — an absent row (`:not_found`) and a corrupt payload
      (`:corrupt_state`) both return the fresh state UNCHANGED, record
      `resume_info.restored == false`, log exactly ONE
      `"durable state not restored"` warning, and make
      `EvoGit.Agent.Resume.apply/1` tell the agent the earlier turns could NOT
      be restored;
    * **opt-out inertness** — `persistent_state: false` writes no row from
      `initial_snapshot/1`, writes nothing from `checkpoint/2`, restores
      nothing in `build_initial_state/3` (even with `restore_agent_state:
      true` and a row present) and leaves `Resume.apply/1` a byte-identical
      no-op.

  ## Why `async: true` — no BEAM-global is touched

  Each test starts its OWN UNNAMED `EvoGit.AgentState` server on a per-test
  SQLite file under ExUnit's `:tmp_dir` and pins it on the TEST process
  dictionary (`:evogit_agent_state_server`) — the same process that runs
  `Persistence` and `Setup` — so both the cast target and the checkpoint
  baseline key are test-local. Agent/task ids are unique per test, and the
  message-timestamp clock is pinned PER PROCESS through
  `EvoGit.Agent.Clock.with_now/2` (never an app-env global) so two builds in one
  test compare equal.

  Every read-backed assertion follows `EvoGit.AgentState.flush/0` (the
  documented read-your-writes barrier) — never a sleep as an assertion.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  alias EvoGit.Agent.Clock
  alias EvoGit.Agent.Resume
  alias EvoGit.Agent.Session.DurableResumeContinuityTest.StubAgent
  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentState
  alias EvoGit.Core.ContextNode

  @agent_id_base 10_060_000

  @fresh_objective "the objective of THIS dispatch"
  @persisted_objective "the objective the persisted run was working on"
  @persisted_assistant "working on it"

  # A fixed Unix second for every message timestamp in a test, so two builds of
  # the same fresh state compare byte-identically.
  @now 1_760_000_000

  # --- Fixtures -------------------------------------------------------------

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "CONTEXT.md"),
      "# Fresh repo context\n\nThe node contract of the freshly built run.\n"
    )

    # Its OWN unnamed server: `EvoGit.AgentState.child_spec/1` hardcodes
    # `id: __MODULE__`, so the child id must be overridden per test.
    store =
      start_supervised!(
        {EvoGit.AgentState,
         database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000},
        id: {EvoGit.AgentState, System.unique_integer([:positive])}
      )

    Process.put(:evogit_agent_state_server, store)

    %{store: store, repo: repo}
  end

  # --- 1. Full continuity ---------------------------------------------------

  describe "full continuity through Setup.build_initial_state/3" do
    test "restores the whole transcript and every conversation scalar, keeping the fresh dispatch's paths and run facts",
         %{repo: repo} do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      # The run's FIRST transcript (a completed tool batch + its answer), built
      # the way the session start path builds it: the START snapshot is the run's
      # one full-field write, so every identity/run fact — the objective, the
      # prompt-cache key, the branch and the base commit — is on the row from the
      # first instant and is never re-supplied by a later turn boundary.
      first = Enum.take(transcript(), 5)

      initial =
        run_state(task_id, agent_id, first,
          turn: 1,
          usage: %Usage{
            input_tokens: 900,
            output_tokens: 100,
            total_tokens: 1_000,
            input_cost: 0.02,
            output_cost: 0.03,
            total_cost: 0.05,
            cached_tokens: 0,
            cache_creation_tokens: 0
          },
          total_tokens: 1_000,
          compression_count: 0,
          objective: @persisted_objective,
          prompt_cache_key: "persisted-cache-key",
          branch: "evogit-agent-persisted",
          base_commit: "persisted-base"
        )

      assert :ok = Persistence.initial_snapshot(initial)

      # …then ONE turn boundary that extends it, so the row is the product of a
      # snapshot plus an APPEND — the production write sequence.
      usage = %Usage{
        input_tokens: 4_000,
        output_tokens: 200,
        total_tokens: 4_200,
        input_cost: 0.25,
        output_cost: 0.75,
        total_cost: 1.0,
        cached_tokens: 1_000,
        cache_creation_tokens: 0
      }

      # The turn boundary advances only the VOLATILE scalars.
      final =
        run_state(task_id, agent_id, transcript(),
          turn: 3,
          usage: usage,
          total_tokens: 4_200,
          compression_count: 2,
          current_commit: "abc123",
          pending_inputs: [%{"text" => "queued follow-up", "attachments" => []}]
        )

      assert :ok = Persistence.checkpoint(initial, final)
      AgentState.flush()

      # The row really holds the full, multi-turn transcript (a completed tool
      # result included) before the rebuild is asserted.
      assert {:ok, record} = AgentState.load(task_id, agent_id)
      assert record.messages == transcript()
      assert length(record.messages) >= 6

      assert {:ok, restored} = build_state(repo, task_id, agent_id, restore: true)

      # The persisted transcript is AUTHORITATIVE — never the fresh
      # `[system, user]` pair the builder just made from disk.
      assert restored.context.messages == transcript()
      assert length(restored.context.messages) == 7
      refute length(restored.context.messages) == 2
      assert Enum.count(restored.context.messages, &(&1.role == :tool)) == 1

      assert Enum.map(
               Enum.uniq_by(restored.context.messages, & &1.metadata[:turn]),
               & &1.metadata[:turn]
             ) ==
               [0, 1, 2, 3]

      # Every conversation scalar comes from the row.
      assert restored.turn == 3
      assert restored.usage == usage
      assert restored.total_tokens == 4_200
      assert restored.compression_count == 2
      assert restored.objective == @persisted_objective
      assert restored.prompt_cache_key == "persisted-cache-key"
      assert restored.current_commit == "abc123"

      assert restored.pending_inputs == [
               %{"text" => "queued follow-up", "attachments" => []}
             ]

      assert restored.resume_info.restore_agent_state == true
      assert restored.resume_info.restored == true

      # The FRESH dispatch wins where it must: this run's own worktree, paths
      # and durable run facts describe the checkout it actually has.
      assert restored.repo_path == repo
      assert restored.worktree == repo
      assert restored.repo_root == repo
      assert restored.branch == "evogit-agent-fresh"
      assert restored.base_commit == "fresh-base"
      assert restored.agent_id == agent_id
      assert restored.task_id == task_id
      assert restored.phase == :running
      assert restored.persistent_state == true

      # Control: the SAME row is ignored when the ctx does not ask to restore.
      assert {:ok, fresh} = build_state(repo, task_id, agent_id, restore: false)
      assert fresh.context.messages != transcript()
      assert length(fresh.context.messages) == 2
      assert fresh.turn == 0
      assert fresh.objective == @fresh_objective
      assert fresh.branch == "evogit-agent-fresh"
    end
  end

  # --- 2. Restore failure ---------------------------------------------------

  describe "restore failure" do
    test "an absent row leaves the fresh state untouched and narrates the degraded resume",
         %{repo: repo} do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      {{:ok, built}, log} =
        captured(fn -> build_state(repo, task_id, agent_id, restore: true) end)

      # Exactly ONE degraded-restore warning, for THIS agent.
      assert count_occurrences(log, "Agent #{agent_id}: durable state not restored") == 1
      assert log =~ ":not_found"

      # Unchanged = identical to the same build with no restore requested, apart
      # from the transient `resume_info` provenance.
      assert {:ok, control} = build_state(repo, task_id, agent_id, restore: false)
      assert_unrestored(built, control)

      assert built.resume_info.restore_agent_state == true
      assert built.resume_info.restored == false
      assert length(built.context.messages) == 2
      assert built.turn == 0
      assert built.objective == @fresh_objective

      # …and the resumed run is TOLD its earlier turns are missing.
      assert_recovery_narration(built)
    end

    test "a corrupt payload leaves the fresh state untouched and narrates the degraded resume",
         %{store: store, repo: repo} do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      seed!(task_id, agent_id, transcript(),
        turn: 3,
        objective: @persisted_objective,
        prompt_cache_key: "persisted-cache-key",
        current_commit: "abc123"
      )

      corrupt_message_count!(store, task_id, agent_id)

      {{:ok, built}, log} =
        captured(fn -> build_state(repo, task_id, agent_id, restore: true) end)

      assert count_occurrences(log, "Agent #{agent_id}: durable state not restored") == 1
      assert log =~ ":corrupt_state"

      assert {:ok, control} = build_state(repo, task_id, agent_id, restore: false)
      assert_unrestored(built, control)

      assert built.resume_info.restored == false
      assert length(built.context.messages) == 2
      assert built.turn == 0
      assert built.objective == @fresh_objective

      assert_recovery_narration(built)
    end
  end

  # --- 3. Opt-out inertness -------------------------------------------------

  describe "persistent_state: false inertness" do
    test "writes no row, restores nothing and leaves the resume repair a no-op",
         %{repo: repo} do
      task_id = unique_task_id()
      agent_id = unique_agent_id()

      inert =
        run_state(task_id, agent_id, transcript(),
          turn: 3,
          persistent_state: false,
          current_commit: "abc123",
          objective: @persisted_objective
        )

      # (a) the initial snapshot writes nothing …
      assert :ok = Persistence.initial_snapshot(inert)
      assert baseline(task_id, agent_id) == nil

      # (b) … and neither does a turn boundary.
      assert :ok =
               Persistence.checkpoint(
                 run_state(task_id, agent_id, [], persistent_state: false),
                 inert
               )

      assert baseline(task_id, agent_id) == nil
      AgentState.flush()
      assert AgentState.load(task_id, agent_id) == {:error, :not_found}

      # (c) A row NOW exists for this exact identity — written by a PERSISTENT
      # run — and the opt-out still restores nothing.
      seed!(task_id, agent_id, transcript(),
        turn: 3,
        objective: @persisted_objective,
        prompt_cache_key: "persisted-cache-key",
        current_commit: "abc123"
      )

      assert {:ok, built} = build_state(repo, task_id, agent_id, restore: true, persist: false)

      assert built.persistent_state == false
      # `resume_info` is nil, not `%{restored: false}`: an opted-out run is not a
      # resume at all, so no repair and no notice may ever run for it.
      assert built.resume_info == nil
      assert length(built.context.messages) == 2
      assert built.turn == 0
      assert built.objective == @fresh_objective
      assert Resume.restored_run?(built) == false

      # (d) A state that LOOKS like an interrupted run is still untouched.
      calls = [
        %ReqLLM.ToolCall{
          id: "c0",
          type: "function",
          function: %{name: "read", arguments: "{}"}
        }
      ]

      dangling = %{
        built
        | context:
            ReqLLM.Context.new([
              message(:system, "sys prompt"),
              message(:user, @fresh_objective),
              %ReqLLM.Message{
                role: :assistant,
                content: [ReqLLM.Message.ContentPart.text("running tools")],
                tool_calls: calls,
                metadata: %{turn: 2}
              }
            ]),
          pending_tool_batch: ToolBatch.build(calls, 2, [])
      }

      assert Resume.apply(dangling) == dangling

      assert Resume.apply(dangling, reattach_fun: fn _, _ -> {:error, :no_pending_batch} end) ==
               dangling
    end
  end

  # --- State builders -------------------------------------------------------

  defp unique_agent_id, do: @agent_id_base + System.unique_integer([:positive])

  defp unique_task_id, do: "durable-resume-#{System.unique_integer([:positive])}"

  defp message(role, text, turn \\ 0) do
    %ReqLLM.Message{
      role: role,
      content: [ReqLLM.Message.ContentPart.text(text)],
      metadata: %{turn: turn}
    }
  end

  # A SEVEN-message, FOUR-turn transcript (turns 0-3) with one completed tool
  # batch, so a restored conversation is structurally distinguishable from the
  # fresh `[system, user]` pair.
  defp transcript do
    [
      message(:system, "sys prompt"),
      message(:user, "the original objective"),
      %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("reading the file")],
        tool_calls: [
          %ReqLLM.ToolCall{
            id: "c1",
            type: "function",
            function: %{name: "read", arguments: ~s({"path":"./lib/a.ex"})}
          }
        ],
        metadata: %{turn: 1}
      },
      %ReqLLM.Message{
        role: :tool,
        tool_call_id: "c1",
        content: [ReqLLM.Message.ContentPart.text("defmodule A do\nend\n")],
        metadata: %{turn: 1}
      },
      message(:assistant, "I read the file", 2),
      message(:user, "keep going", 2),
      message(:assistant, @persisted_assistant, 3)
    ]
  end

  defp run_state(task_id, agent_id, messages, overrides) do
    defaults = [
      agent_id: agent_id,
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      repo_id: "primary",
      task_id: task_id,
      persistent_state: true,
      context: ReqLLM.Context.new(messages)
    ]

    struct!(State, Keyword.merge(defaults, overrides))
  end

  defp baseline(task_id, agent_id),
    do: Process.get({:evogit_agent_state_baseline, task_id, agent_id})

  # Seeds ONE run's durable record through the production writer path: the start
  # snapshot is the run's one full-field write (identity, every run fact and the
  # whole transcript); later turns checkpoint volatile scalars only.
  defp seed!(task_id, agent_id, messages, overrides) do
    assert :ok = Persistence.initial_snapshot(run_state(task_id, agent_id, messages, overrides))

    AgentState.flush()
    :ok
  end

  # The exact `ctx` key set `EvoGit.Agent.Session.build_state/2` supplies to
  # `Setup.build_initial_state/3`, with the FRESH run's own paths and durable
  # run facts.
  defp build_ctx(task_id, agent_id, repo_path, overrides) do
    defaults = [
      agent_id: agent_id,
      depth: 0,
      context_node: %ContextNode{path: "./", repo: repo_path},
      repo_path: repo_path,
      current_commit: "fresh-sha",
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
      prompt_cache_key: "fresh-cache",
      session_mode: :oneshot,
      quality_level: nil,
      custom_agent_id: nil,
      attachments: nil,
      branch: "evogit-agent-fresh",
      base_commit: "fresh-base"
    ]

    Keyword.merge(defaults, overrides)
  end

  # Builds the initial state as the session does, with the clock pinned so two
  # builds of the same fresh state are comparable.
  defp build_state(repo, task_id, agent_id, opts) do
    overrides =
      [restore_agent_state: Keyword.fetch!(opts, :restore)] ++
        if Keyword.get(opts, :persist, true) do
          []
        else
          [persistent_state: false]
        end

    Clock.with_now(@now, fn ->
      Setup.build_initial_state(
        StubAgent,
        @fresh_objective,
        build_ctx(task_id, agent_id, repo, overrides)
      )
    end)
  end

  # Corrupts the stored row's message count so the rebuilt transcript no longer
  # agrees with the row (the `:corrupt_state` shape the store rejects).
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

  # --- Resume narration -----------------------------------------------------

  # The degraded-resume narration: a repaired-looking state that cannot claim
  # anything about the earlier turns it never got back.
  defp assert_recovery_narration(%State{} = state) do
    resumed = Resume.apply(state)
    messages = resumed.context.messages

    # No tool result is invented: the fresh transcript had nothing dangling.
    refute Enum.any?(messages, &(&1.role == :tool))

    # Exactly ONE notice, and it states the restore degraded.
    assert Enum.count(messages, &notice_marked?/1) == 1
    notice = List.last(messages)

    assert notice.role == :user
    assert notice.metadata[:resume_notice] == true
    assert notice.metadata[:user_authored] == nil

    text = text_of(notice)
    assert text =~ "[RESUME]"
    assert text =~ "could NOT be restored from durable state"
    assert text =~ "earlier turns of this run are not present in this transcript"

    # The prefix invariant holds even on the degraded path.
    assert Enum.take(messages, 2) == Enum.take(state.context.messages, 2)

    # A second apply adds nothing.
    assert Resume.apply(resumed) == resumed
  end

  # A restore that found nothing left the fresh state untouched, apart from the
  # transient `resume_info` provenance it must report to the caller.
  defp assert_unrestored(built, control) do
    assert built.resume_info == %{
             restore_agent_state: true,
             restored: false,
             resume_kind: nil,
             retries: nil,
             retry_reason: nil,
             worktree_resume_from: nil
           }

    assert built.context == control.context
    assert built.turn == control.turn
    assert built.usage == control.usage
    assert built.total_tokens == control.total_tokens
    assert built.compression_count == control.compression_count
    assert built.objective == control.objective
    assert built.prompt_cache_key == control.prompt_cache_key
    assert built.pending_inputs == control.pending_inputs
    assert built.current_commit == control.current_commit
    assert built.pending_tool_batch == control.pending_tool_batch
  end

  defp notice_marked?(%ReqLLM.Message{metadata: metadata}) when is_map(metadata),
    do: Map.get(metadata, :resume_notice) == true

  defp notice_marked?(_message), do: false

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      other -> inspect(other)
    end)
    |> Enum.join()
  end

  defp text_of(_message), do: ""

  # Runs `fun` with its log captured (the deliberately degrading resume path
  # logs at `:warning`) and returns `{result, log}`.
  defp captured(fun) do
    log = capture_log(fn -> send(self(), {:captured_result, fun.()}) end)

    result =
      receive do
        {:captured_result, value} -> value
      after
        0 -> flunk("the captured call produced no result")
      end

    {result, log}
  end

  defp count_occurrences(text, pattern), do: length(String.split(text, pattern)) - 1
end
