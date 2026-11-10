defmodule EvoGit.Agent.ExchangeYieldTest.YieldAgent do
  @moduledoc """
  The role an interactive/one-shot exchange runs AS.
  A canned `system_prompt/0` and ONE fixed tool schema are all the engine needs
  from the agent module: the tests drive the loop through the four
  `EvoGit.Agent.Exchange.Seams` and assert on the OUTCOME SHAPE, never on the
  role's behaviour.
  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent
  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the yield/finish stub agent."
  @doc "The fixed tool inventory this role exposes."
  def available_tools do
    [
      ReqLLM.Tool.new!(
        name: "read",
        description: "Read a file from the agent's worktree.",
        callback: {__MODULE__, :unused_callback}
      )
    ]
  end

  @doc false
  # Never executed: the exchange is driven by the `:llm_call` seam, so no
  # schema is ever dispatched against a real callback.
  def unused_callback(_args), do: {:ok, "unused"}
end

defmodule EvoGit.Agent.ExchangeYieldTest do
  @moduledoc """
  P3 engine test for the `{:yield}` / `{:finish}` outcome split.
  The MODE decides only what a tool-free reply means:
    * `:interactive` -> `{:yield, %{bare_state() | }, text}`: pending work committed, the
      reply text handed back, NO `%EvoGit.Agent.Result{}` built and NO
      completion side effect written;
    * `:oneshot` -> `{:finish, %{bare_state() | }, %EvoGit.Agent.Result{}}`: byte-identical
      to the pre-P3 behaviour, with the completion side effects written exactly
      once by `EvoGit.Agent.Completion.Builder.finalize/2`.
  Also pinned here: exactly ONE `:checkpoint` per turn on a yield, the budget
  resolvers (`EvoGit.Agent.exchange_turn_budget/1` and
  `EvoGit.Agent.session_turn_budget/1`), `trigger_turn_limit_recovery?/1` for
  both modes, and the completion entry point itself.
  ## Isolation
  The seams send to the TEST pid (no file, no Agent, no shared process). The
  app-global ETS rows the completion path reads (the agent SUMMARY row and the
  registration `sched_meta`) are installed under a per-test-UNIQUE agent id and
  deleted on exit. The ONE BEAM-global touched here is the app env
  `:interactive_session_turns`, a default-inert seam read ONLY by
  `EvoGit.Agent.session_turn_budget/1` (this module), so no concurrently running
  module can observe it.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent
  alias EvoGit.Agent.Completion.Builder
  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.ExchangeYieldTest.YieldAgent
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec

  # Per-test-unique, disjoint from every other suite's id base (the golden
  # exchange test uses 9_900_000, the checkpoint seam test 9_920_000).
  @agent_id_base 9_930_000
  @objective "Objective: one tool-free reply."
  @report_text "yield report text"
  @usage %{input_tokens: 100, output_tokens: 20, total_tokens: 120}

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    install_agent_row(agent_id)

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
    end)

    # Repo-less identity, exactly as the Session installs it for a `:reflect`
    # agent: no worktree, no git, no archive.
    Process.put(:repo_less, true)
    on_exit(fn -> Process.delete(:repo_less) end)

    %{agent_id: agent_id}
  end

  describe "outcome split" do
    test "an interactive state YIELDS the reply text and builds no Result", %{agent_id: agent_id} do
      test_pid = self()

      opts = [
        llm_call: text_reply_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub(),
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      state = initial_state(agent_id, :interactive, %{max_turns: 128})

      assert {:yield, %State{mode: :interactive} = final_state, text} = Exchange.run(state, opts)

      # The model text is handed back VERBATIM (it is the session's message).
      assert text == @report_text
      refute match?(%Result{}, text)

      # The context grew by exactly ONE assistant message (the reply).
      assert message_count(final_state) == message_count(state) + 1
      assert assistant_message_count(final_state) == 1

      # No completion side effect ran: the repo-less commit sha is untouched.
      assert final_state.current_commit == state.current_commit
      assert final_state.turn == 1
      assert final_state.usage.input_tokens == 100

      # Exactly ONE checkpoint for the one-turn exchange.
      assert length(collect_checkpoints(agent_id)) == 1
    end

    test "a one-shot state still FINISHES with a Result", %{agent_id: agent_id} do
      opts = [
        llm_call: text_reply_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub()
      ]

      state = initial_state(agent_id, :oneshot, %{max_turns: 128})

      assert {:finish, %State{mode: :oneshot} = final_state, %Result{} = result} =
               Exchange.run(state, opts)

      assert result.result == @report_text
      # Repo-less: the completion entry point never invents a commit.
      assert result.commit_sha == nil
      assert final_state.turn == 1
    end

    test "the checkpoint seam fires exactly once on a yield", %{agent_id: agent_id} do
      test_pid = self()

      opts = [
        llm_call: text_reply_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub(),
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      assert {:yield, %State{}, @report_text} =
               Exchange.run(initial_state(agent_id, :interactive, %{max_turns: 128}), opts)

      checkpoints = collect_checkpoints(agent_id)
      assert length(checkpoints) == 1
      assert [%State{mode: :interactive, turn: 1}] = checkpoints
    end
  end

  describe "budget resolution" do
    test "exchange_turn_budget/1 prefers the explicit field, else max_turns" do
      assert Agent.exchange_turn_budget(%{bare_state() | max_turns: 128}) == 128

      assert Agent.exchange_turn_budget(%{bare_state() | max_turns: 128, max_exchange_turns: 12}) ==
               12

      # A non-positive field is not a budget: fall back to max_turns.
      assert Agent.exchange_turn_budget(%{bare_state() | max_turns: 128, max_exchange_turns: 0}) ==
               128

      assert Agent.exchange_turn_budget(%{bare_state() | max_turns: 128, max_exchange_turns: -1}) ==
               128
    end

    test "session_turn_budget/1 is explicit > app-env seam > 10x exchange budget" do
      on_exit(fn -> Application.delete_env(:evo_git, :interactive_session_turns) end)

      # No explicit field and no seam: ten per-exchange budgets.
      Application.delete_env(:evo_git, :interactive_session_turns)
      assert Agent.session_turn_budget(%{bare_state() | max_turns: 128}) == 1280

      assert Agent.session_turn_budget(%{bare_state() | max_turns: 128, max_exchange_turns: 10}) ==
               100

      # The seam is read at CALL time, not at compile time.
      Application.put_env(:evo_git, :interactive_session_turns, 7)
      assert Agent.session_turn_budget(%{bare_state() | max_turns: 128}) == 7

      # A non-positive seam value is ignored (never a zero/negative budget).
      Application.put_env(:evo_git, :interactive_session_turns, 0)
      assert Agent.session_turn_budget(%{bare_state() | max_turns: 128}) == 1280

      Application.put_env(:evo_git, :interactive_session_turns, -3)
      assert Agent.session_turn_budget(%{bare_state() | max_turns: 128}) == 1280

      # An explicit cumulative cap always wins over the seam.
      Application.put_env(:evo_git, :interactive_session_turns, 7)

      assert Agent.session_turn_budget(%{bare_state() | max_turns: 128, max_session_turns: 50}) ==
               50
    end
  end

  describe "turn-limit recovery trigger" do
    test "one-shot is unchanged: turn >= max_turns, per-exchange fields ignored" do
      refute Agent.trigger_turn_limit_recovery?(%{
               bare_state()
               | mode: :oneshot,
                 turn: 127,
                 max_turns: 128
             })

      assert Agent.trigger_turn_limit_recovery?(%{
               bare_state()
               | mode: :oneshot,
                 turn: 128,
                 max_turns: 128
             })

      # A per-exchange budget never applies to a one-shot agent.
      refute Agent.trigger_turn_limit_recovery?(%{
               bare_state()
               | mode: :oneshot,
                 turn: 2,
                 max_turns: 128,
                 max_exchange_turns: 2
             })
    end

    test "interactive exhausts at exchange_turn_base + max_exchange_turns, and not before" do
      state = %{
        bare_state()
        | mode: :interactive,
          exchange_turn_base: 10,
          max_exchange_turns: 5,
          max_turns: 128,
          max_session_turns: 100
      }

      refute Agent.trigger_turn_limit_recovery?(%{state | turn: 14})
      assert Agent.trigger_turn_limit_recovery?(%{state | turn: 15})
    end

    test "interactive also exhausts at the cumulative session cap, and not before" do
      state = %{
        bare_state()
        | mode: :interactive,
          exchange_turn_base: 10,
          max_exchange_turns: 50,
          max_turns: 128,
          max_session_turns: 20
      }

      refute Agent.trigger_turn_limit_recovery?(%{state | turn: 19})
      assert Agent.trigger_turn_limit_recovery?(%{state | turn: 20})
    end

    test "grace always wins over every budget" do
      refute Agent.trigger_turn_limit_recovery?(%{
               bare_state()
               | mode: :interactive,
                 turn: 10_000,
                 max_turns: 1,
                 max_session_turns: 1,
                 max_exchange_turns: 1,
                 in_grace_period: true
             })

      refute Agent.trigger_turn_limit_recovery?(%{
               bare_state()
               | mode: :oneshot,
                 turn: 10_000,
                 max_turns: 1,
                 in_grace_period: true
             })
    end
  end

  describe "EvoGit.Agent.Completion.Builder.finalize/2" do
    test "repo-less one-shot finalize returns {:ok, %Result{}} with commit_sha nil",
         %{agent_id: agent_id} do
      state = %{
        bare_state()
        | agent_id: agent_id,
          agent_module: YieldAgent,
          node_path: "./",
          objective: @objective,
          max_turns: 128,
          max_retries: 3,
          llm_generation_params: [],
          llm_context_window: 200_000
      }

      assert {:ok, %Result{} = result} = Builder.finalize(state, @report_text)

      assert result.result == @report_text
      # Repo-less: no worktree HEAD to capture.
      assert result.commit_sha == nil
      # No ETS task row is installed, so the branch name is the degenerate
      # `T-A` spelling - and it is derived deterministically.
      assert result.branch == "evogit-agent-T-A"
    end

    test "a missing scheduler row is an {:error, reason}, never a raise" do
      unregistered = @agent_id_base + 500_000 + System.unique_integer([:positive])

      state = %{
        bare_state()
        | agent_id: unregistered,
          agent_module: YieldAgent,
          node_path: "./",
          objective: @objective,
          max_turns: 128,
          max_retries: 3,
          llm_generation_params: [],
          llm_context_window: 200_000
      }

      assert {:error, {:agent_state_not_found, ^unregistered}} =
               Builder.finalize(state, @report_text)
    end
  end

  # ---------------------------------------------------------------------------
  # Seams
  # ---------------------------------------------------------------------------

  # A model that replies with TEXT and no tool calls on the FIRST turn - the
  # implicit completion, which is the only mode-dependent decision.
  defp text_reply_stub do
    fn context, _tools, _gen_params, _agent_id, _max_retries ->
      message = assistant_message(@report_text, nil)

      {:implicit_completion,
       %ReqLLM.Response{
         id: "yield-response",
         model: "yield:model",
         # ReqLLM's response builder appends the assistant message to the
         # context; the engine's turn/context advance reads `response.context`.
         context: ReqLLM.Context.append(context, message),
         message: message,
         usage: @usage
       }, @report_text}
    end
  end

  # Never used by these scenarios (the stub never emits a tool call), but kept
  # so an unexpected tool call cannot reach the real batch.
  defp tool_batch_stub do
    fn indexed_calls, _state ->
      Enum.map(indexed_calls, fn {call, index} ->
        {index, Map.get(call, :id), "unused", "unused"}
      end)
    end
  end

  # One adapter for every scheduler/ETS interaction the loop performs: no
  # pending inputs, no cancellation, `:ok` for the sync writes.
  defp scheduler_stub do
    fn kind, _payload, _state ->
      case kind do
        :drain_inputs -> []
        :cancel_requested? -> false
        _other -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario data
  # ---------------------------------------------------------------------------

  defp assistant_message(text, tool_calls) do
    %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: tool_calls
    }
  end

  defp bare_state do
    %State{
      agent_id: @agent_id_base,
      agent_module: YieldAgent,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([])
    }
  end

  defp initial_state(agent_id, mode, overrides) do
    %{
      bare_state()
      | agent_id: agent_id,
        agent_module: YieldAgent,
        mode: mode,
        depth: 0,
        node_path: "./",
        context:
          ReqLLM.Context.new([
            ReqLLM.Context.system(YieldAgent.system_prompt()),
            ReqLLM.Context.user(@objective)
          ]),
        objective: @objective,
        repo_less: true,
        max_turns: Map.get(overrides, :max_turns, 128),
        max_exchange_turns: Map.get(overrides, :max_exchange_turns),
        max_session_turns: Map.get(overrides, :max_session_turns),
        exchange_turn_base: Map.get(overrides, :exchange_turn_base, 0),
        max_retries: 3,
        llm_generation_params: [],
        llm_context_window: 200_000
    }
  end

  # The TWO registration reads the completion entry point performs
  # (`AgentScheduler.get_agent_state/1` for the archive/model metadata and
  # `Store.get_sched_meta/1` for the spec's `base_commit`). `phylo_node: nil` is
  # the repo-less shape and `archive: false` keeps the archive writer out.
  defp install_agent_row(agent_id) do
    :ok =
      SchedStore.put_agent_state(agent_id, %AgentState{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        parent_id: nil,
        archive: false,
        llm_model: nil,
        model_id: "yield",
        max_turns: 128,
        max_retries: 3,
        max_depth: nil,
        repo_id: "primary",
        llm_context_window: 200_000
      })

    :ok =
      SchedStore.put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        spec: %AgentSpec{
          context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
          phylo_node: nil,
          agent_module: YieldAgent,
          objective: @objective
        }
      })

    :ok
  end

  # ---------------------------------------------------------------------------
  # Collectors & context inspection
  # ---------------------------------------------------------------------------

  defp collect_checkpoints(agent_id), do: collect(agent_id, :checkpoint)

  defp collect(agent_id, tag) do
    receive do
      {^tag, %State{agent_id: ^agent_id} = state} -> [state | collect(agent_id, tag)]
      {^tag, _other_agent} -> collect(agent_id, tag)
    after
      0 -> []
    end
  end

  defp message_count(%ReqLLM.Context{messages: messages}), do: length(messages)
  defp message_count(%State{context: context}), do: message_count(context)

  defp assistant_message_count(%State{context: context}),
    do: assistant_message_count(context)

  defp assistant_message_count(%ReqLLM.Context{messages: messages}),
    do: Enum.count(messages, &(&1.role == :assistant))
end
