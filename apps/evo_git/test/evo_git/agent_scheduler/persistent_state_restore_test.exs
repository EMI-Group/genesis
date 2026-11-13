defmodule EvoGit.AgentScheduler.PersistentStateRestoreTest do
  @moduledoc """
  Pins the RESTORE MERGE POINT of the per-task `:persistent_state` feature:
  `EvoGit.Agent.Session.Setup.build_initial_state/3` on a retry-shaped ctx
  (`restore_agent_state: true` + `persistent_state: true`) must merge the
  persisted CONVERSATION onto the freshly built `%EvoGit.Agent.State{}` while
  every identity/worktree/path/model field — and `phase` — stays FRESH.

  This is the production behaviour a crash retry depends on: the durable record
  is the authority for what the run was DOING (transcript, turn, usage, tokens,
  compression count, cache key, objective, pending inputs, last observed
  commit), and the CURRENT run is the authority for where it runs and which
  model it uses (agent id, task id, repo/worktree paths, model selection,
  `model_id_locked`, `phase: :running`).

  ## What is pinned here

    * happy path — the persisted message list replaces the freshly built
      `[system, user]` pair byte-identically, and every restored scalar
      (`turn`, `usage.input_tokens`, `total_tokens`, `compression_count`,
      `prompt_cache_key`, `objective`, `pending_inputs`, `current_commit`)
      comes from the record while the fresh half does not;
    * `restore_agent_state: false` — the SAME seeded record is ignored: the
      freshly built prompt survives and the conversation counters stay at
      zero;
    * `persistent_state: false, restore_agent_state: true` — the durability
      flag alone gates the restore, so the state is fresh and
      `state.persistent_state == false`.

  The record is seeded through the REAL writer path
  (`EvoGit.AgentState.checkpoint/4` + the `flush/1` read-your-writes barrier),
  never by writing SQL: what is restored is exactly what production persists.

  ## Why `async: true`

  Every test starts its OWN unnamed `EvoGit.AgentState` server on a private
  `@moduletag :tmp_dir` database and points the calling process at it through
  the `:evogit_agent_state_server` process-dictionary seam, so the app-global
  service is never read or written (the seam lives in the test process and dies
  with it). The fresh repo path is a plain per-test directory, the agent/task
  ids are per-test unique, and the two `:global`-locked migration boot helpers
  are write-once/idempotent. No app env is mutated.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.Core.ContextNode

  @moduletag :tmp_dir

  @agent_id_base 9_980_000

  # A minimal `EvoGit.Agent` role — `build_initial_state/3` only needs
  # `system_prompt/0`, `delegation_level/0` and `session_mode/0`.
  #
  # Defined ABOVE the test module on purpose: `mix test` starts the async ExUnit
  # runner before every file finishes loading, so a helper defined AFTER an
  # `async: true` test module can be unloaded when its first test runs.
  defmodule StubAgent do
    use EvoGit.Agent

    @doc "The role's fixed system prompt."
    def system_prompt, do: "You are the persistent-state restore test role."

    @doc "No tools: the state builder never inspects the tool set here."
    def available_tools, do: []
  end

  setup %{tmp_dir: tmp_dir} do
    # The FRESH run's repo/worktree: a plain directory carrying a CONTEXT.md is
    # enough (`build_initial_state/3` only requires the node path to exist and
    # the context-tree read to succeed — no git repo needed).
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "CONTEXT.md"),
      "# Fresh repo context\n\nThe node contract of the freshly built run.\n"
    )

    # An ISOLATED durable store: never the app-global `EvoGit.AgentState.Server`.
    pid =
      start_supervised!(
        {EvoGit.AgentState,
         database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000}
      )

    # `EvoGit.AgentState.server/0` prefers this process-dictionary key, which is
    # what `Persistence.restore/3` reads from inside `build_initial_state/3`.
    Process.put(:evogit_agent_state_server, pid)

    %{repo: repo, server: pid}
  end

  describe "build_initial_state/3 merges the persisted conversation" do
    test "restores the conversation and the run scalars, keeping identity/worktree fresh", %{
      repo: repo,
      server: server
    } do
      {task_id, agent_id} = unique_identity()
      seed!(server, task_id, agent_id)

      state = build_state(repo, task_id, agent_id)

      # The persisted transcript is AUTHORITATIVE: it replaces `[system, user]`
      # exactly (the record round-trips through `term_to_binary/2`).
      assert state.context.messages == persisted_messages()

      # Every restored scalar comes from the record.
      assert state.turn == 4
      assert state.usage.input_tokens == 10
      assert state.usage.output_tokens == 2
      assert state.total_tokens == 1234
      assert state.compression_count == 2
      assert state.prompt_cache_key == "restored-cache-key"
      assert state.objective == "persisted objective"
      assert state.pending_inputs == ["restored pending input"]
      assert state.current_commit == "restored-sha"

      # …while the fresh half is THIS run's: identity, paths, model selection,
      # phase and the durability flag.
      assert state.repo_path == repo
      assert state.repo_root == repo
      assert state.agent_id == agent_id
      assert state.task_id == task_id
      assert state.repo_id == "primary"
      assert state.llm_model == "test:model"
      assert state.model_id == "restore-test"
      assert state.model_id_locked == true
      assert state.persistent_state == true
      assert state.phase == :running
    end

    test "leaves the freshly built state alone when restoration is not requested", %{
      repo: repo,
      server: server
    } do
      {task_id, agent_id} = unique_identity()
      seed!(server, task_id, agent_id)

      state = build_state(repo, task_id, agent_id, restore_agent_state: false)

      # The record EXISTS and is readable — it is simply not consulted.
      assert {:ok, _record} = AgentState.load(task_id, agent_id, store: server)

      refute state.context.messages == persisted_messages()
      assert length(state.context.messages) == 2
      assert user_message_text(state) =~ "fresh objective"

      assert state.turn == 0
      assert state.total_tokens == 0
      assert state.compression_count == 0
      assert state.objective == "fresh objective"
      assert state.current_commit == "fresh-sha"
    end

    test "the :persistent_state flag alone gates the restore", %{repo: repo, server: server} do
      {task_id, agent_id} = unique_identity()
      seed!(server, task_id, agent_id)

      state = build_state(repo, task_id, agent_id, persistent_state: false)

      refute state.context.messages == persisted_messages()
      assert length(state.context.messages) == 2
      assert user_message_text(state) =~ "fresh objective"

      assert state.turn == 0
      assert state.total_tokens == 0
      assert state.objective == "fresh objective"
      assert state.persistent_state == false
    end
  end

  # --- helpers ---

  # The durable record, written through the REAL writer path: ONE `:rewrite`
  # checkpoint carrying the whole transcript plus the scalar fields, followed by
  # the `flush/1` read-your-writes barrier.
  defp seed!(server, task_id, agent_id) do
    entry = %{
      kind: :rewrite,
      base_seq: nil,
      messages: persisted_messages(),
      fields: %{
        turn: 4,
        usage: %{
          "input_tokens" => 10,
          "output_tokens" => 2,
          "total_tokens" => 12,
          "input_cost" => 0,
          "output_cost" => 0,
          "total_cost" => 0,
          "cached_tokens" => 0,
          "cache_creation_tokens" => 0
        },
        total_tokens: 1234,
        compression_count: 2,
        prompt_cache_key: "restored-cache-key",
        objective: "persisted objective",
        pending_inputs: ["restored pending input"],
        current_commit: "restored-sha"
      }
    }

    AgentState.checkpoint(task_id, agent_id, entry, store: server)
    :ok = AgentState.flush(server)
  end

  # Mirrors the session's production `state_ctx` (`EvoGit.Agent.Session.build_state/2`)
  # with every `Keyword.fetch!`ed key present.
  defp build_state(repo, task_id, agent_id, overrides \\ []) do
    ctx = [
      agent_id: agent_id,
      depth: 0,
      context_node: %ContextNode{path: "./", repo: repo},
      repo_path: repo,
      current_commit: "fresh-sha",
      repo_root: repo,
      repo_id: "primary",
      repo_less: false,
      task_id: task_id,
      parent_id: nil,
      archive: false,
      persistent_state: Keyword.get(overrides, :persistent_state, true),
      restore_agent_state: Keyword.get(overrides, :restore_agent_state, true),
      foreign_repos: [],
      repo_notes: nil,
      max_turns: 30,
      max_depth: 5,
      max_retries: 10,
      compression_count: 0,
      llm_context_window: 200_000,
      llm_model: "test:model",
      llm_generation_params: %{},
      model_spec: nil,
      provider_profile_id: nil,
      model_id: "restore-test",
      model_id_locked: true
    ]

    assert {:ok, %State{} = state} =
             Setup.build_initial_state(StubAgent, "fresh objective", ctx)

    state
  end

  defp unique_identity do
    n = System.unique_integer([:positive])
    {"task-restore-#{n}", @agent_id_base + n}
  end

  defp persisted_messages do
    [
      %ReqLLM.Message{
        role: :system,
        content: [ReqLLM.Message.ContentPart.text("persisted system prompt")]
      },
      %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text("persisted reply")]
      }
    ]
  end

  defp user_message_text(%State{context: %{messages: messages}}) do
    messages
    |> Enum.find(&(&1.role == :user))
    |> Map.get(:content)
    |> Enum.map_join("", fn part -> part.text || "" end)
  end
end
