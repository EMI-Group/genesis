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

    test "returns summaries with all expected keys and native values" do
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

      # usage is a native %Usage{} struct
      assert %Usage{} = summary.usage
      assert summary.usage.input_tokens == 100
      assert summary.usage.output_tokens == 50
      assert summary.usage.total_tokens == 150

      # agent_module is the raw atom, not a string
      assert is_atom(summary.agent_module)
      assert summary.agent_module == __MODULE__
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

      # Still a native %Usage{} struct
      assert %Usage{} = summary.usage
      assert summary.usage == Usage.zero()
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

    test "includes repo_root, context_path, worktree, commits, and task fields from state" do
      phylo = %PhyloGraphNode{repo: "/tmp/test", base_commit: "base123", current_commit: "head456"}

      meta = %SchedMeta{
        id: 1,
        depth: 0,
        spec: agent_spec(),
        status: :running,
        parent_id: nil,
        worktree: "/worktrees/worker_T1_A1",
        task_id: "aabbccddeeff0011",
        task_number: 1,
        retries: 2
      }

      state =
        agent_state(
          repo_root: "/home/user/project",
          phylo_node: phylo
        )

      put_sched_meta(1, meta)
      put_agent_state(1, state)

      [summary] = RemoteAPI.list_agents()

      assert summary.repo_root == "/home/user/project"
      assert summary.context_path == "./"
      assert summary.worktree == "/worktrees/worker_T1_A1"
      assert summary.base_commit == "base123"
      assert summary.current_commit == "head456"
      assert summary.task_id == "aabbccddeeff0011"
      assert summary.task_number == 1
      assert summary.retries == 2
    end

    test "falls back to spec.phylo_node for commits when state.phylo_node is nil" do
      meta = %SchedMeta{
        id: 1,
        depth: 0,
        spec: agent_spec(),
        worktree: "/worktrees/wt1",
        task_id: "1122334455667788",
        task_number: 3,
        retries: 0
      }

      state = agent_state(phylo_node: nil, repo_root: "/repo/root")

      put_sched_meta(1, meta)
      put_agent_state(1, state)

      [summary] = RemoteAPI.list_agents()

      # spec.phylo_node has base_commit/current_commit "abc"
      assert summary.base_commit == "abc"
      assert summary.current_commit == "abc"
      assert summary.context_path == "./"
      assert summary.worktree == "/worktrees/wt1"
      assert summary.task_id == "1122334455667788"
      assert summary.task_number == 3
      assert summary.retries == 0
    end

    test "includes task and commit fields from spec when agent_state is missing" do
      meta = %SchedMeta{
        id: 7,
        depth: 0,
        spec: agent_spec(),
        worktree: nil,
        task_id: "deadbeefdeadbeef",
        task_number: 5,
        retries: 1
      }

      put_sched_meta(7, meta)

      [summary] = RemoteAPI.list_agents()

      # No agent_state → repo_root is nil, but context_path/commits come from spec
      assert is_nil(summary.repo_root)
      assert summary.context_path == "./"
      assert summary.base_commit == "abc"
      assert summary.current_commit == "abc"
      assert is_nil(summary.worktree)
      assert summary.task_id == "deadbeefdeadbeef"
      assert summary.task_number == 5
      assert summary.retries == 1
    end

    test "defaults retries to 0 when not set in meta" do
      meta = %SchedMeta{id: 1, depth: 0, spec: agent_spec()}
      put_sched_meta(1, meta)
      put_agent_state(1, agent_state())

      [summary] = RemoteAPI.list_agents()
      assert summary.retries == 0
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

    test "returns native ReqLLM.Message structs for an agent with a populated context" do
      content_part = ReqLLM.Message.ContentPart.text("hello world")

      message = %ReqLLM.Message{
        role: :user,
        content: [content_part],
        metadata: %{turn: 0}
      }

      context = %ReqLLM.Context{messages: [message]}
      put_agent_state(1, agent_state(context: context))

      [msg] = RemoteAPI.get_agent_history(1)

      # The returned message is the native struct, not a converted map.
      assert %ReqLLM.Message{} = msg
      assert msg.role == :user
      assert msg.content == [content_part]
      assert msg.metadata == %{turn: 0}
      assert is_nil(msg.tool_calls)
    end

    test "returns multiple messages as native structs" do
      message1 = %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("one")]}
      message2 = %ReqLLM.Message{role: :assistant, content: [ReqLLM.Message.ContentPart.text("two")]}

      context = %ReqLLM.Context{messages: [message1, message2]}
      put_agent_state(1, agent_state(context: context))

      messages = RemoteAPI.get_agent_history(1)
      assert length(messages) == 2

      assert Enum.all?(messages, &match?(%ReqLLM.Message{}, &1))
      assert Enum.map(messages, & &1.role) == [:user, :assistant]
    end

    test "preserves tool_calls as native structs" do
      tool_call = ReqLLM.ToolCall.new("call_1", "search", ~s({"query":"elixir"}))

      message = %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [tool_call]
      }

      context = %ReqLLM.Context{messages: [message]}
      put_agent_state(1, agent_state(context: context))

      [msg] = RemoteAPI.get_agent_history(1)

      # tool_calls are returned as native structs
      assert [tc] = msg.tool_calls
      assert %ReqLLM.ToolCall{} = tc
      assert tc.id == "call_1"
      assert tc.function.name == "search"
      assert tc.function.arguments == ~s({"query":"elixir"})
    end
  end

  # ── get_agent_state/1 ─────────────────────────────────────────────

  describe "get_agent_state/1" do
    test "returns nil for an unknown agent" do
      assert RemoteAPI.get_agent_state(999_999) == nil
    end

    test "returns a native AgentState struct with :context dropped" do
      state = agent_state(foreign_repos: [%ForeignRepo{id: "orig", root: "/tmp/orig"}])
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      # A native AgentState struct (with :context set to nil)
      assert %AgentState{} = result
      assert is_nil(result.context)

      # Native field values
      assert result.llm_model == "test:model"
      assert result.objective == "agent state objective"
      assert result.max_retries == 15
      assert result.max_depth == 8
      assert result.repo_id == "primary"
      assert result.model_id == "default"
    end

    test "returns usage as a native %Usage{} struct" do
      state = agent_state(usage: %Usage{input_tokens: 200, output_tokens: 100, total_tokens: 300})
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      # usage is a native %Usage{} struct
      assert %Usage{} = result.usage
      assert result.usage.input_tokens == 200
      assert result.usage.total_tokens == 300
    end

    test "keeps nil usage as nil" do
      state = agent_state(usage: nil)
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      assert is_nil(result.usage)
    end

    test "keeps foreign_repos as native structs" do
      state = agent_state(foreign_repos: [%ForeignRepo{id: "orig", root: "/tmp/orig"}])
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      assert is_list(result.foreign_repos)
      assert length(result.foreign_repos) == 1
      [repo] = result.foreign_repos
      # foreign_repos entries are native structs
      assert %ForeignRepo{} = repo
      assert repo.id == "orig"
      assert repo.root == "/tmp/orig"
    end

    test "keeps llm_generation_params as a native keyword list" do
      state = agent_state(llm_generation_params: [temperature: 0.7, max_tokens: 4096])
      put_agent_state(1, state)

      result = RemoteAPI.get_agent_state(1)

      # llm_generation_params is a native keyword list, not converted to a map
      assert Keyword.keyword?(result.llm_generation_params)
      assert result.llm_generation_params[:temperature] == 0.7
      assert result.llm_generation_params[:max_tokens] == 4096
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

    test "validation_errors is a list (native structs may be present)" do
      # get_config_status/0 returns the result of EvoGit.Config.config_status/0
      # directly. validation_errors may contain %ValidationError{} structs,
      # which are transferred natively via :erpc.call/5.
      status = RemoteAPI.get_config_status()

      assert is_list(status.validation_errors)
    end
  end

  # ── get_config/0, reload_config/0, and paused?/0 ──────────────────

  # These functions delegate to `EvoGit.AgentScheduler.get_config/0`,
  # `EvoGit.AgentScheduler.update_config/1`, and
  # `EvoGit.AgentScheduler.paused?/0`, which are GenServer.call/2 to the
  # running scheduler. Starting the full scheduler in a test requires a
  # complete config + worktree pool + git repo, which is too heavy for this
  # unit test. We verify delegation at the source level (they call the exact
  # functions) rather than booting a scheduler.

  # `build_reload_opts/1` is the pure extraction helper — it is tested
  # thoroughly below since it has its own logic.

  # ── build_reload_opts/1 ─────────────────────────────────────────────

  describe "build_reload_opts/1" do
    test "returns model_profiles + scheduler keys from a populated config" do
      config = %{
        scheduler: %{
          max_concurrency: 5,
          max_tool_concurrency: 3,
          agent_max_retries: 5,
          max_agent_depth: 10,
          max_retries: 20,
          max_turns: 64,
          max_turns_root: 64
        },
        llm: %{
          model: "anthropic:claude-sonnet-4-20250514",
          models: [
            %{id: "default", model: "anthropic:claude-sonnet-4-20250514", concurrency: 5},
            %{id: "fast", model: "openai:gpt-4o-mini", concurrency: 10}
          ]
        },
        sandbox: %{
          mode: :auto,
          resources: %{cpu_quota: "1000%"},
          process: %{memory_max: "8G"}
        }
      }

      opts = RemoteAPI.build_reload_opts(config)

      # Model profiles from [[llm.models]]
      assert Keyword.has_key?(opts, :model_profiles)
      profiles = opts[:model_profiles]
      assert length(profiles) == 2
      assert Enum.at(profiles, 0)[:id] == "default"
      assert Enum.at(profiles, 1)[:id] == "fast"

      # Scheduler settings
      assert opts[:max_tool_concurrency] == 3
      assert opts[:agent_max_retries] == 5
      assert opts[:max_depth] == 10
      assert opts[:max_retries] == 20
      assert opts[:max_turns] == 64
      assert opts[:max_turns_root] == 64

      # Sandbox settings
      assert opts[:sandbox_mode] == :auto
      assert opts[:sandbox_resources] == %{cpu_quota: "1000%"}
      assert opts[:sandbox_process_resources] == %{memory_max: "8G"}
    end

    test "synthesizes legacy default profile when models list is empty" do
      config = %{
        scheduler: %{max_concurrency: 4},
        llm: %{model: "google:gemini-2.0-flash-exp"}
      }

      opts = RemoteAPI.build_reload_opts(config)

      assert Keyword.has_key?(opts, :model_profiles)
      profiles = opts[:model_profiles]
      assert length(profiles) == 1
      assert hd(profiles)[:id] == "default"
      assert hd(profiles)[:model] == "google:gemini-2.0-flash-exp"
      assert hd(profiles)[:concurrency] == 4
    end

    test "synthesizes legacy default profile when llm section is missing" do
      config = %{
        scheduler: %{max_concurrency: 2}
      }

      opts = RemoteAPI.build_reload_opts(config)

      profiles = opts[:model_profiles]
      assert length(profiles) == 1
      assert hd(profiles)[:id] == "default"
      assert hd(profiles)[:model] == nil
      assert hd(profiles)[:concurrency] == 2
    end

    test "empty config returns keyword list with defaults" do
      opts = RemoteAPI.build_reload_opts(%{})

      assert Keyword.has_key?(opts, :model_profiles)
      profiles = opts[:model_profiles]
      assert length(profiles) == 1
      assert hd(profiles)[:id] == "default"
      assert hd(profiles)[:model] == nil
      assert hd(profiles)[:concurrency] == 3
    end

    test "rejects nil values from the keyword list" do
      config = %{
        scheduler: %{
          max_tool_concurrency: 2,
          agent_max_retries: nil,
          max_agent_depth: nil,
          max_retries: 15
        }
      }

      opts = RemoteAPI.build_reload_opts(config)

      # Nil values are rejected
      refute Keyword.has_key?(opts, :agent_max_retries)
      refute Keyword.has_key?(opts, :max_depth)

      # Non-nil values are kept
      assert opts[:max_tool_concurrency] == 2
      assert opts[:max_retries] == 15

      # Model profiles still present
      assert Keyword.has_key?(opts, :model_profiles)
    end
  end
end
