defmodule EvoGit.Agent.Session.SummaryTest do
  @moduledoc """
  Tests for `EvoGit.Agent.Session.Summary` — the ONE writer/reader helper over
  the `:evogit_agent_summary` row.

  A session owns its `%EvoGit.Agent.State{}`; `publish/3` copies EVERY summary
  field of that state onto the EXISTING registration row (never creating one)
  and never writes the conversation. Two bounds are pinned here:

    * the published row carries the COMPLETE summary field set from the state,
      keeps every REGISTRATION-only field intact, and contains NO `:context`;
    * a publish whose merged row would not change (compared excluding
      `:last_activity_at`) is a NO-OP — nothing is written and
      `last_activity_at` does not advance.

  Uses `async: true`: rows live in the app-global `:evogit_agent_summary` ETS
  table under per-test UNIQUE agent ids (its own 9_960_000+ range), so no test
  ever wipes the table. The `"agents"` PubSub topic is shared, but every
  assertion matches on the agent id.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session.Summary
  alias EvoGit.Agent.State
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode

  # Anything longer than this is truncated into `objective_preview`.
  @objective_preview_limit 4_096

  # --- Fixtures ---

  # Per-test-unique agent id: the summary table is app-global and shared with
  # every concurrently running `async: true` module.
  defp unique_agent_id, do: 9_960_000 + :erlang.unique_integer([:positive])

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/summary-test"}
  end

  # The row `Dispatch` registers BEFORE a session can exist: identity, model
  # selection and limits, with every state-owned field still at its default.
  defp registration_row(overrides) do
    defaults = [
      context_node: context_node(),
      llm_model: "test:model",
      llm_generation_params: [temperature: 0.1, max_tokens: 4096],
      llm_context_window: 200_000,
      model_id: "default",
      provider_profile_id: "account",
      model_spec: %{"provider_profile_id" => "account", "model" => "gpt-4o-mini"},
      model_id_locked: true,
      max_retries: 7,
      max_depth: 3,
      max_turns: 42,
      parent_id: nil,
      objective: "the objective",
      repo_id: "primary",
      repo_root: "/repo/root",
      task_local_id: 5,
      archive: true,
      foreign_repos: []
    ]

    struct!(AgentState, Keyword.merge(defaults, overrides))
  end

  # Registers the row and removes it (plus its control-plane rows) on exit.
  defp register_agent!(agent_id, overrides \\ []) do
    :ok = Store.put_agent_state(agent_id, registration_row(overrides))
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
    :ok
  end

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  # A session-owned run state — the summary SOURCE. Only the fields a running
  # session actually moves differ from the registration row.
  defp run_state(agent_id, overrides \\ []) do
    defaults = [
      agent_id: agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context_node: context_node(),
      context:
        ReqLLM.Context.new([
          message(:system, "system prompt"),
          message(:user, "the objective"),
          message(:assistant, "a reply")
        ]),
      mode: :oneshot,
      objective: "the objective",
      turn: 4,
      usage: %Usage{input_tokens: 120, output_tokens: 30, total_tokens: 150},
      total_tokens: 9_000,
      compression_count: 2,
      llm_context_window: 96_000,
      current_commit: "feedface"
    ]

    struct!(State, Keyword.merge(defaults, overrides))
  end

  defp drain_mailbox do
    receive do
      _msg -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  # --- Tests ---

  test "publish/3 writes the COMPLETE summary field set onto the registration row" do
    agent_id = unique_agent_id()
    register_agent!(agent_id)
    state = run_state(agent_id)

    assert :ok = Summary.publish(agent_id, state)

    row = Summary.read(agent_id)

    # State-owned fields, copied verbatim from the session's state...
    assert row.mode == :oneshot
    assert row.turn == 4
    assert row.message_count == 3
    assert row.usage == state.usage
    assert row.total_tokens == 9_000
    assert row.compression_count == 2
    assert row.context_window == 96_000
    assert row.current_commit == "feedface"
    assert row.objective_preview == "the objective"
    assert %DateTime{} = row.last_activity_at

    # ...and the row carries NO conversation.
    refute Map.has_key?(row, :context)

    # Registration-only fields survive the merge (a publish updates the row,
    # it never rebuilds it).
    assert row.objective == "the objective"
    assert row.llm_model == "test:model"
    assert row.llm_generation_params == [temperature: 0.1, max_tokens: 4096]
    assert row.model_id == "default"
    assert row.provider_profile_id == "account"
    assert row.model_spec == %{"provider_profile_id" => "account", "model" => "gpt-4o-mini"}
    assert row.model_id_locked
    assert row.max_retries == 7
    assert row.max_depth == 3
    assert row.max_turns == 42
    assert row.repo_id == "primary"
    assert row.repo_root == "/repo/root"
    assert row.task_local_id == 5
    assert row.archive
    assert row.context_node == context_node()
  end

  test "a second publish of an UNCHANGED state performs no write" do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, PubSub.agent_topic())
    drain_mailbox()

    agent_id = unique_agent_id()
    register_agent!(agent_id)
    state = run_state(agent_id)

    assert :ok = Summary.publish(agent_id, state)
    first_row = Summary.read(agent_id)
    assert %DateTime{} = first_row.last_activity_at

    # Flush the first publish's delta.
    assert_receive {:agent_updated, ^agent_id, _fields, _node}, 1_000
    drain_mailbox()

    # Same state again: the merged row is identical, so nothing is written —
    # `last_activity_at` does not advance and no delta is broadcast.
    assert :ok = Summary.publish(agent_id, state)

    assert Summary.read(agent_id) == first_row
    assert Summary.read(agent_id).last_activity_at == first_row.last_activity_at
    refute_receive {:agent_updated, ^agent_id, _fields, _node}, 100
  end

  test "publish/3's extra overrides set status and current_commit (unknown keys ignored)" do
    agent_id = unique_agent_id()
    register_agent!(agent_id)
    state = run_state(agent_id, current_commit: "deadbeef")

    assert :ok =
             Summary.publish(agent_id, state,
               status: :running,
               current_commit: "cafebabe",
               not_a_summary_field: "ignored"
             )

    row = Summary.read(agent_id)
    assert row.status == :running
    assert row.current_commit == "cafebabe"
  end

  test "a publish for a missing row is a no-op (a session never creates the row)" do
    missing_id = unique_agent_id()

    assert :ok = Summary.publish(missing_id, run_state(missing_id))
    assert Summary.read(missing_id) == nil
    assert Store.get_agent_state(missing_id) == :error
  end

  test "objective_preview is bounded to the preview limit without splitting a codepoint" do
    agent_id = unique_agent_id()
    register_agent!(agent_id, objective: String.duplicate("é", 5_000))
    state = run_state(agent_id, objective: String.duplicate("é", 5_000))

    assert :ok = Summary.publish(agent_id, state)

    row = Summary.read(agent_id)
    assert String.length(row.objective_preview) == @objective_preview_limit
    # A grapheme-safe slice: only complete "é" codepoints, never a broken tail.
    assert row.objective_preview == String.duplicate("é", @objective_preview_limit)
    # The registration row's full objective is untouched by the preview.
    assert row.objective == String.duplicate("é", 5_000)
  end
end
