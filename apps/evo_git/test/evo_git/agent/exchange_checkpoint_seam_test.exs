defmodule EvoGit.Agent.ExchangeCheckpointSeamTest.CheckpointAgent do
  @moduledoc """
  The role a checkpoint-seam exchange runs AS.

  A canned `system_prompt/0` and ONE fixed tool schema are all the engine needs
  from the agent module: the checkpoint seam is observable-only, so the test
  asserts on the states it receives, never on the role's behaviour.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the checkpoint-seam stub agent."

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
  # Never executed: the exchange is driven by the `:tool_batch` seam, so no
  # schema is ever dispatched against a real callback.
  def unused_callback(_args), do: {:ok, "unused"}
end

defmodule EvoGit.Agent.ExchangeCheckpointSeamTest do
  @moduledoc """
  P2 seam test for the FOURTH engine seam, `:checkpoint`.

  `EvoGit.Agent.Exchange` calls the seam EXACTLY ONCE PER TURN, after that
  turn's state update: the state handed to the recursive loop step for a
  CONTINUING turn, and once for the state of the FINISHING turn before the
  outcome is returned. The return value is discarded (observable-only), so the
  exchange outcome can never depend on it.

  ## What is pinned

  1. a 2-turn exchange calls the checkpoint seam exactly TWICE — the turn-1
     (continuing) state and the turn-2 (finishing) state — and the outcome is
     unchanged by the seam's presence;
  2. an ABSENT seam changes nothing: the same exchange produces the same
     outcome term, state and report with and without the seam;
  3. an explicitly `nil` `opts[:checkpoint]` wins over a configured app-env
     default (`:agent_exchange_checkpoint`) and produces no calls, mirroring the
     resolution rule of the other three seams.

  ## Isolation

  The checkpoint fn sends to the TEST pid (no file, no Agent, no shared
  process). The app-global ETS rows the completion path still reads (the agent
  SUMMARY row and the registration `sched_meta`) are installed under a
  per-test-UNIQUE agent id and deleted on exit — the module never asserts on
  table size or emptiness.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.ExchangeCheckpointSeamTest.CheckpointAgent
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec

  # Per-test-unique, disjoint from every other suite's id base (the golden
  # exchange test uses 9_900_000), so the ETS row can neither collide with nor
  # be deleted by a concurrently running module.
  @agent_id_base 9_920_000

  @objective "Objective: observe one checkpoint per turn."
  @report_text "checkpoint report text"
  @read_output "defmodule A do\n  # checkpoint read\nend\n"
  @usage %{input_tokens: 100, output_tokens: 20, total_tokens: 120}

  # The clock pin the context-equality test installs via `now:` (an integer Unix
  # second, 2023-11-14T22:13:20Z). Every per-message `metadata[:timestamp]` is
  # stamped through `EvoGit.Agent.Clock.now_seconds/0`, so WITHOUT this pin two
  # sequential runs of the same exchange can straddle a second boundary and
  # differ only in that metadata.
  @pinned_now 1_700_000_000

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    install_agent_row(agent_id)

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
    end)

    # Repo-less identity, exactly as the Runner installs it for a `:reflect`
    # agent: no worktree, no git, no archive.
    Process.put(:repo_less, true)
    on_exit(fn -> Process.delete(:repo_less) end)

    %{agent_id: agent_id}
  end

  describe "the :checkpoint seam" do
    test "fires exactly once per turn and never changes the outcome", %{agent_id: agent_id} do
      test_pid = self()

      opts = [
        llm_call: llm_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub(),
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      assert {:finish, %State{} = final_state, %Result{} = result} =
               Exchange.run(initial_state(agent_id), opts)

      checkpoints = collect_checkpoints(agent_id)

      # ONE checkpoint per turn: turn 1 continued (one tool batch), turn 2
      # finished with a plain-text reply.
      assert length(checkpoints) == 2
      assert Enum.map(checkpoints, & &1.turn) == [1, 2]
      assert Enum.all?(checkpoints, &match?(%State{}, &1))
      assert Enum.all?(checkpoints, &(&1.agent_id == agent_id))

      # Each checkpointed state is the state that turn PRODUCED: the turn-1
      # state already carries the tool result, the turn-2 state the final reply.
      [turn_one, turn_two] = checkpoints
      assert message_count(turn_one) < message_count(turn_two)
      assert message_count(turn_two) == message_count(final_state.context)

      # The finishing turn's checkpoint IS the final state.
      assert turn_two == final_state

      # The seam is observable-only: the outcome is the ordinary completion.
      assert result.result == @report_text
      assert final_state.turn == 2
    end

    test "an absent seam changes nothing", %{agent_id: agent_id} do
      test_pid = self()

      # SAME pinned clock for BOTH runs: the per-message `metadata[:timestamp]`
      # is otherwise wall-clock and the comparison below would flake whenever a
      # second boundary falls between the two runs' corresponding append sites.
      base_opts = [
        now: @pinned_now,
        llm_call: llm_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub()
      ]

      without_seam = Exchange.run(initial_state(agent_id), base_opts)

      with_seam =
        Exchange.run(
          initial_state(agent_id),
          base_opts ++ [checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end]
        )

      assert {:finish, %State{} = state_without, %Result{} = result_without} = without_seam
      assert {:finish, %State{} = state_with, %Result{} = result_with} = with_seam

      assert result_with == result_without
      assert state_with.turn == state_without.turn
      assert state_with.total_tokens == state_without.total_tokens
      assert state_with.context == state_without.context

      # The seam REALLY reaches every append site: every message the exchange
      # appended (the initial system+user pair is indices 0-1) carries the
      # pinned Unix second rather than the wall clock.
      for state <- [state_without, state_with] do
        appended = Enum.drop(state.context.messages, 2)
        assert length(appended) == 3
        assert Enum.all?(appended, &(&1.metadata[:timestamp] == @pinned_now))
      end

      # The seam fired (proving the comparison is not vacuous) and is the ONLY
      # difference between the two runs.
      assert length(collect_checkpoints(agent_id)) == 2
    end

    test "is the per-turn ETS publication path: :checkpoint -> Session.Summary.publish/3",
         %{agent_id: agent_id} do
      test_pid = self()

      # The PRODUCTION wiring (`Session.Worker`): the checkpoint hook is what
      # publishes the summary row the dashboard reads. No other per-turn ETS
      # write exists anymore, so a row that advances turn-by-turn is the proof.
      opts = [
        llm_call: llm_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub(),
        checkpoint: fn state ->
          :ok = EvoGit.Agent.Session.Summary.publish(state.agent_id, state)
          send(test_pid, {:published, state.turn, EvoGit.Agent.Session.Summary.read(agent_id)})
        end
      ]

      assert {:finish, %State{} = final_state, %Result{}} =
               Exchange.run(initial_state(agent_id), opts)

      # ONE publication per turn, each carrying that turn's summary fields.
      assert_receive {:published, 1, %AgentState{} = first_row}, 1_000
      assert_receive {:published, 2, %AgentState{} = second_row}, 1_000

      assert first_row.turn == 1
      assert first_row.total_tokens == 120
      assert first_row.usage.input_tokens == 100
      assert first_row.message_count < second_row.message_count

      # The finishing turn's publication is the terminal summary — and it never
      # writes a conversation: the summary read model has no `context` field at
      # all, so the messages stay owned by the session.
      assert second_row.turn == 2
      assert second_row.total_tokens == 120
      assert second_row.usage.input_tokens == 200
      assert second_row.message_count == message_count(final_state)
      refute Map.has_key?(second_row, :context)

      final_row = EvoGit.Agent.Session.Summary.read(agent_id)
      assert final_row.turn == 2
      assert final_row.message_count == message_count(final_state)
      assert final_row.total_tokens == second_row.total_tokens
      assert final_row.usage == second_row.usage

      refute_receive {:published, _turn, _row}, 100
    end

    test "an explicit nil opts[:checkpoint] wins over the app-env default", %{
      agent_id: agent_id
    } do
      test_pid = self()

      # The app-env default is a legitimate seam source when the opts key is
      # ABSENT (rule 2 of `Seams.from_opts/1`).
      Application.put_env(:evo_git, :agent_exchange_checkpoint, fn state ->
        send(test_pid, {:env_checkpoint, state})
      end)

      on_exit(fn -> Application.delete_env(:evo_git, :agent_exchange_checkpoint) end)

      base_opts = [
        llm_call: llm_stub(),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub()
      ]

      # 1. No `:checkpoint` key at all → the app-env default fires.
      assert {:finish, %State{}, %Result{}} =
               Exchange.run(initial_state(agent_id), base_opts)

      env_calls = collect_env_checkpoints(agent_id)
      assert length(env_calls) == 2
      assert Enum.map(env_calls, & &1.turn) == [1, 2]

      # 2. An EXPLICIT nil opts value wins over that same app-env default and
      #    means "no checkpointing" — no call at all.
      assert {:finish, %State{}, %Result{}} =
               Exchange.run(initial_state(agent_id), base_opts ++ [checkpoint: nil])

      assert collect_env_checkpoints(agent_id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Seams
  # ---------------------------------------------------------------------------

  # The scripted model, STATELESS: it derives the turn from the context it was
  # handed (assistant messages = turns already completed). Turn 1 asks for one
  # tool call; turn 2 replies with text, which IS the completion.
  defp llm_stub do
    fn context, _tools, _gen_params, _agent_id, _max_retries ->
      if assistant_message_count(context) == 0 do
        {:ok,
         response(
           context,
           assistant_message("Reading the module.", [
             ReqLLM.ToolCall.new("call_t1_read", "read", Jason.encode!(%{"path" => "./lib/a.ex"}))
           ])
         )}
      else
        {:implicit_completion, response(context, assistant_message(@report_text, nil)),
         @report_text}
      end
    end
  end

  # The `:tool_batch` seam REPLACES the whole standard-call batch.
  defp tool_batch_stub do
    fn indexed_calls, _state ->
      Enum.map(indexed_calls, fn {call, index} ->
        {index, call.id, ReqLLM.ToolCall.name(call), @read_output}
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

  defp response(context, message) do
    %ReqLLM.Response{
      id: "checkpoint-response",
      model: "checkpoint:model",
      # ReqLLM's response builder appends the assistant message to the context;
      # the engine's turn/context advance reads `response.context`.
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: @usage
    }
  end

  defp assistant_message(text, tool_calls) do
    %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: tool_calls
    }
  end

  defp initial_state(agent_id) do
    %State{
      agent_id: agent_id,
      agent_module: CheckpointAgent,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system(CheckpointAgent.system_prompt()),
          ReqLLM.Context.user(@objective)
        ]),
      objective: @objective,
      repo_less: true,
      max_turns: 128,
      max_retries: 3,
      llm_generation_params: [],
      llm_context_window: 200_000
    }
  end

  # The TWO registration reads the P1 finish path still performs
  # (`ToolDispatch.build_completion/3` → `AgentScheduler.get_agent_state/1` for
  # the archive/model metadata and `Store.get_sched_meta/1` for the spec's
  # `base_commit`). `phylo_node: nil` is the repo-less shape (never dereferenced
  # because `repo_less` short-circuits `base_commit` to nil) and `archive: false`
  # keeps the archive writer out of the run entirely.
  defp install_agent_row(agent_id) do
    :ok =
      SchedStore.put_agent_state(agent_id, %AgentState{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        parent_id: nil,
        archive: false,
        llm_model: nil,
        model_id: "checkpoint",
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
          agent_module: CheckpointAgent,
          objective: @objective
        }
      })

    :ok
  end

  # ---------------------------------------------------------------------------
  # Collectors (messages sent to THIS test process)
  # ---------------------------------------------------------------------------

  # Collects every `{:checkpoint, state}` this test's exchange produced. A
  # concurrent module can never contribute: the agent id is per-test-unique.
  defp collect_checkpoints(agent_id), do: collect(agent_id, :checkpoint)

  # An app-env seam is BEAM-global, so a concurrently running exchange can call
  # this test's env fn with ITS state; filtering by our unique agent id keeps
  # that harmless and the assertion exact.
  defp collect_env_checkpoints(agent_id), do: collect(agent_id, :env_checkpoint)

  defp collect(agent_id, tag) do
    receive do
      {^tag, %State{agent_id: ^agent_id} = state} -> [state | collect(agent_id, tag)]
      {^tag, _other_agent} -> collect(agent_id, tag)
    after
      0 -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Context inspection
  # ---------------------------------------------------------------------------

  defp message_count(%ReqLLM.Context{messages: messages}), do: length(messages)
  defp message_count(%State{context: context}), do: message_count(context)

  defp assistant_message_count(%ReqLLM.Context{messages: messages}),
    do: Enum.count(messages, &(&1.role == :assistant))
end
