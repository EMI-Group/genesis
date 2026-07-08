defmodule EvoGit.AgentScheduler.RemoteAPITest do
  @moduledoc """
  Tests for `EvoGit.AgentScheduler.RemoteAPI` — the RPC-accessible read-only
  API over scheduler ETS state.

  Uses `async: false` because the tests manipulate global named ETS tables
  (`:evogit_agent_state` and `:evogit_sched_meta`).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  # --- Shared test fixtures ---

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp phylo_node do
    %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"}
  end

  defp agent_spec do
    %AgentSpec{
      context_node: context_node(),
      phylo_node: phylo_node(),
      agent_module: __MODULE__,
      objective: "test objective"
    }
  end

  defp agent_state(overrides \\ []) do
    defaults = [
      context_node: context_node(),
      llm_model: "test:model",
      max_retries: 15,
      max_depth: 8,
      objective: "agent state objective",
      task_local_id: 1,
      repo_id: "primary",
      model_id: "default"
    ]

    struct!(AgentState, Keyword.merge(defaults, overrides))
  end

  # --- ETS helpers (reuse pattern from lifecycle_test.exs) ---

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  defp clear_ets do
    if :ets.whereis(:evogit_agent_state) != :undefined,
      do: :ets.delete_all_objects(:evogit_agent_state)

    if :ets.whereis(:evogit_sched_meta) != :undefined,
      do: :ets.delete_all_objects(:evogit_sched_meta)
  end

  defp put_sched_meta(agent_id, meta) do
    :ets.insert(:evogit_sched_meta, {agent_id, meta})
  end

  defp put_agent_state(agent_id, state) do
    :ets.insert(:evogit_agent_state, {agent_id, state})
  end

  # --- Setup ---

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    clear_ets()

    on_exit(fn -> clear_ets() end)

    :ok
  end

  # ── list_agents/0 ──────────────────────────────────────────────────

  describe "list_agents/0" do
    test "returns [] when tables are empty" do
      assert RemoteAPI.list_agents() == []
    end

    test "returns [] when ETS tables are empty" do
      assert RemoteAPI.list_agents() == []
    end

    # Note: We do NOT test the "table doesn't exist" path here because deleting
    # the global named ETS tables (`:ets.delete/1`) creates a timing window that
    # breaks sibling test files whose `on_exit` callbacks call
    # `:ets.delete_all_objects/1` without a `:ets.whereis/1` guard. The
    # `:ets.whereis/1` guard in the production code (read_table/1 and
    # lookup_agent_state/1) is simple enough to trust by inspection.

    test "returns summaries with all expected keys and plain values" do
      meta = %SchedMeta{
        id: 1,
        depth: 0,
        spec: agent_spec(),
        status: :running,
        parent_id: nil
      }

      state = agent_state(usage: %Usage{input_tokens: 100, output_tokens: 50, total_tokens: 150})

      put_sched_meta(1, meta)
      put_agent_state(1, state)

      [summary] = RemoteAPI.list_agents()

      assert summary.id == 1
      assert summary.task_local_id == 1
      assert summary.repo_id == "primary"
      assert summary.status == :running
      assert summary.depth == 0
      assert is_nil(summary.parent_id)
      assert summary.objective == "agent state objective"
      assert is_nil(summary.result)
      assert is_nil(summary.started_at)
      assert summary.model_id == "default"

      # usage is a plain map, NOT a struct
      refute is_struct(summary.usage)
      assert summary.usage.input_tokens == 100
      assert summary.usage.output_tokens == 50
      assert summary.usage.total_tokens == 150

      # agent_module is a string, not a module/atom
      assert is_binary(summary.agent_module)
      assert summary.agent_module == inspect(__MODULE__)
    end

    test "falls back to sched_meta spec.objective when agent_state objective is nil" do
      meta = %SchedMeta{id: 1, depth: 0, spec: agent_spec()}

      state = agent_state(objective: nil)

      put_sched_meta(1, meta)
      put_agent_state(1, state)

      [summary] = RemoteAPI.list_agents()
      assert summary.objective == "test objective"
    end

    test "defaults usage to zero struct when agent_state usage is nil" do
      meta = %SchedMeta{id: 1, depth: 0, spec: agent_spec()}
      state = agent_state(usage: nil)

      put_sched_meta(1, meta)
      put_agent_state(1, state)

      [summary] = RemoteAPI.list_agents()

      # Still a plain map (converted from zero struct)
      refute is_struct(summary.usage)
      assert summary.usage == Map.from_struct(Usage.zero())
    end

    test "handles agents registered in sched_meta but missing agent_state" do
      meta = %SchedMeta{id: 5, depth: 2, spec: agent_spec(), parent_id: 1}

      put_sched_meta(5, meta)

      [summary] = RemoteAPI.list_agents()

      assert summary.id == 5
      assert summary.depth == 2
      assert summary.parent_id == 1
      assert is_nil(summary.task_local_id)
      assert is_nil(summary.repo_id)
      assert summary.objective == "test objective"
      assert summary.total_tokens == 0
      assert summary.compression_count == 0
      assert is_nil(summary.model_id)
    end

    test "returns multiple agents" do
      put_sched_meta(1, %SchedMeta{id: 1, depth: 0, spec: agent_spec()})
      put_sched_meta(2, %SchedMeta{id: 2, depth: 1, spec: agent_spec()})
      put_agent_state(1, agent_state())
      put_agent_state(2, agent_state(task_local_id: 2, objective: "child task"))

      summaries = RemoteAPI.list_agents()
      assert length(summaries) == 2

      ids = Enum.map(summaries, & &1.id) |> Enum.sort()
      assert ids == [1, 2]
    end
  end

  # ── get_agent_history/1 ───────────────────────────────────────────

  describe "get_agent_history/1" do
    test "returns [] for an unknown agent" do
      assert RemoteAPI.get_agent_history(999_999) == []
    end

    test "returns [] for an agent with nil context" do
      put_agent_state(1, agent_state(context: nil))
      assert RemoteAPI.get_agent_history(1) == []
    end

    test "returns converted message maps for an agent with a populated context" do
      content_part = ReqLLM.Message.ContentPart.text("hello world")

      message = %ReqLLM.Message{
        role: :user,
        content: [content_part],
        metadata: %{turn: 0}
      }

      context = %ReqLLM.Context{messages: [message]}
      put_agent_state(1, agent_state(context: context))

      [msg_map] = RemoteAPI.get_agent_history(1)

      assert msg_map.role == "user"
      assert msg_map.content_summary == "hello world"
      assert msg_map.turn == 0
      assert is_nil(msg_map.tool_calls)
    end

    test "joins multiple content parts into content_summary" do
      part1 = ReqLLM.Message.ContentPart.text("part one ")
      part2 = ReqLLM.Message.ContentPart.text("part two")

      message = %ReqLLM.Message{
        role: :assistant,
        content: [part1, part2]
      }

      context = %ReqLLM.Context{messages: [message]}
      put_agent_state(1, agent_state(context: context))

      [msg_map] = RemoteAPI.get_agent_history(1)
      assert msg_map.content_summary == "part one part two"
    end

    test "converts tool_calls to plain maps" do
      tool_call = ReqLLM.ToolCall.new("call_1", "search", ~s({"query":"elixir"}))

      message = %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [tool_call]
      }

      context = %ReqLLM.Context{messages: [message]}
      put_agent_state(1, agent_state(context: context))

      [msg_map] = RemoteAPI.get_agent_history(1)

      assert is_list(msg_map.tool_calls)
      assert length(msg_map.tool_calls) == 1

      [tc_map] = msg_map.tool_calls
      assert tc_map.id == "call_1"
      assert tc_map.name == "search"
      assert tc_map.arguments == %{"query" => "elixir"}
    end

    test "handles messages without turn metadata" do
      message = %ReqLLM.Message{
        role: :system,
        content: [ReqLLM.Message.ContentPart.text("system prompt")]
      }

      context = %ReqLLM.Context{messages: [message]}
      put_agent_state(1, agent_state(context: context))

      [msg_map] = RemoteAPI.get_agent_history(1)
      assert msg_map.turn == nil
      assert msg_map.role == "system"
    end
  end

  # ── get_agent_state/1 ─────────────────────────────────────────────

  describe "get_agent_state/1" do
    test "returns nil for an unknown agent" do
      assert RemoteAPI.get_agent_state(999_999) == nil
    end

    test "returns a plain map without :context key" do
      state = agent_state(foreign_repos: [%ForeignRepo{id: "orig", root: "/tmp/orig"}])
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      assert is_map(result)
      refute is_struct(result)
      refute Map.has_key?(result, :context)

      # llm_model is a plain value
      assert result.llm_model == "test:model"
      assert result.objective == "agent state objective"
      assert result.max_retries == 15
      assert result.max_depth == 8
      assert result.repo_id == "primary"
      assert result.model_id == "default"
    end

    test "converts usage to a plain map" do
      state = agent_state(usage: %Usage{input_tokens: 200, output_tokens: 100, total_tokens: 300})
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      # usage is a plain map, not a struct
      refute is_struct(result.usage)
      assert result.usage.input_tokens == 200
      assert result.usage.total_tokens == 300
    end

    test "defaults nil usage to zero struct" do
      state = agent_state(usage: nil)
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      refute is_struct(result.usage)
      assert result.usage == Map.from_struct(Usage.zero())
    end

    test "converts foreign_repos structs to plain maps" do
      state = agent_state(foreign_repos: [%ForeignRepo{id: "orig", root: "/tmp/orig"}])
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      assert is_list(result.foreign_repos)
      assert length(result.foreign_repos) == 1
      [repo_map] = result.foreign_repos
      refute is_struct(repo_map)
      assert repo_map.id == "orig"
      assert repo_map.root == "/tmp/orig"
    end

    test "converts llm_generation_params keyword list to a map" do
      state = agent_state(llm_generation_params: [temperature: 0.7, max_tokens: 4096])
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      assert is_map(result.llm_generation_params)
      assert result.llm_generation_params.temperature == 0.7
      assert result.llm_generation_params.max_tokens == 4096
    end
  end

  # ── get_config_status/0 ───────────────────────────────────────────

  describe "get_config_status/0" do
    test "returns map with expected keys" do
      status = RemoteAPI.get_config_status()

      assert Map.has_key?(status, :missing)
      assert Map.has_key?(status, :warnings)
      assert Map.has_key?(status, :ok?)
      assert Map.has_key?(status, :validation_errors)
    end

    test "validation_errors is always a list of plain maps (not structs)" do
      # config_status/0 calls resolve() which re-validates config and resets
      # the validation_errors process dictionary entry. We verify that
      # whatever config_status returns, the validation_errors are never
      # structs (always plain maps safe for cross-node serialization).
      status = RemoteAPI.get_config_status()

      assert is_list(status.validation_errors)

      for error <- status.validation_errors do
        refute is_struct(error), "expected plain map, got struct: #{inspect(error)}"
        assert is_map(error)
      end
    end
  end

  # ── get_config/0 and paused?/0 ────────────────────────────────────

  # These two functions delegate to `EvoGit.AgentScheduler.get_config/0` and
  # `EvoGit.AgentScheduler.paused?/0`, which are GenServer.call/2 to the
  # running scheduler. Starting the full scheduler in a test requires a
  # complete config + worktree pool + git repo, which is too heavy for this
  # unit test. We verify delegation at the source level (they call the exact
  # functions) rather than booting a scheduler.
end
