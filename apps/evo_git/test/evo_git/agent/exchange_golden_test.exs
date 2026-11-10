defmodule EvoGit.Agent.ExchangeGoldenTest.GoldenAgent do
  @moduledoc """
  The agent module a golden exchange runs AS.

  A golden test needs a role whose tool list is a fixed, comparable value: the
  engine offers `available_tools/0` to the LLM on every turn, so pinning that
  list (and the fact that it does NOT change between turns) is part of proving
  "an unwatched exchange makes exactly the same calls as before".

  The three tools are the model-facing names the scripted model asks for
  (`read`, `rg`, `write`), and the callback is a plain MFA tuple — never a
  closure — so two calls of `available_tools/0` are STRUCT-EQUAL and the test
  can assert on the tool list directly.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc """
  The fixed tool inventory this role exposes (three schemas, always in this
  order).
  """
  def available_tools do
    [
      tool("read", "Read a file from the agent's worktree."),
      tool("rg", "Search file contents with ripgrep."),
      tool("write", "Write a file into the agent's worktree.")
    ]
  end

  @doc false
  # Never executed: the exchange is driven by the `:tool_batch` seam, so no
  # schema is ever dispatched against a real callback.
  def unused_callback(_args), do: {:ok, "unused"}

  defp tool(name, description) do
    ReqLLM.Tool.new!(
      name: name,
      description: description,
      callback: {__MODULE__, :unused_callback}
    )
  end
end

defmodule EvoGit.Agent.ExchangeGoldenTest do
  @moduledoc """
  GOLDEN test for P1's core claim: an **unwatched** exchange makes exactly the
  same LLM and tool calls as the production loop, and it runs in a PLAIN ExUnit
  process — no `EvoGit.AgentScheduler` agent process, no scheduler call, no ETS
  control plane beyond the ONE read the completion path still performs in P1.

  The whole exchange is executed inline in the test process through the
  default-inert seams of `EvoGit.Agent.Exchange.Seams` (`:llm_call`,
  `:tool_batch`, `:scheduler`, `:checkpoint`), all passed via `opts`. Nothing
  here mutates app env, the scheduler config, the Logger level or any other
  BEAM-global state.

  ## The scripted scenario (3 turns)

  | turn | the "model" replies with | the tool batch returns |
  |---|---|---|
  | 1 | 2 tool calls: `read ./lib/a.ex`, then `rg defmodule ./lib` | both results |
  | 2 | 1 tool call: `write ./lib/b.ex` | its result |
  | 3 | plain text — `{:implicit_completion, resp, "scripted report text"}`, the ONE completion route | (no batch) |

  ## What is pinned

  * the exact ORDERED tool-call sequence the engine hands to the tool batch —
    turn, in-response index, tool name and decoded arguments;
  * exactly 3 LLM calls, in order, with the growing context each one saw (call
    2 carries the turn-1 tool results, call 3 both turns') — so "same calls as
    before" is pinned on message CONTENT, not merely on counts;
  * the per-turn tool list is `GoldenAgent.available_tools/0`, non-empty and
    stable across all three turns;
  * the ONE terminal outcome `{:finish, final_state, %Result{result:
    "scripted report text"}}`;
  * the final conversation: ordered roles, the three tool results with their
    call ids/outputs, and the engine's exact turn tags (assistant messages 1-2-3,
    tool results 1-1-2);
  * the `:scheduler` seam's CONTROL-PLANE sequence — one input drain and one
    cancel check per turn and nothing else (the per-turn ETS write-through kinds
    are gone);
  * the `:checkpoint` seam firing exactly once per turn, each checkpointed state
    carrying that turn's `turn`, `context`, `total_tokens` and `usage` — the ONE
    state-publication path now (`EvoGit.Agent.Session.Summary.publish/3`), with
    each checkpointed context byte-identical to what the NEXT LLM call received.

  ## The ONE remaining ETS touch

  `ToolDispatch.build_completion/3` still reads the agent's scheduler row
  (`EvoGit.AgentScheduler.get_agent_state/1`) for the archive/model metadata — a
  documented P1 carry-over. So the test installs ONE real
  `%EvoGit.AgentScheduler.AgentState{}` row under a per-test-UNIQUE agent id and
  deletes exactly that row on exit. It never asserts on table size or emptiness,
  which keeps the module `async: true`.

  `Process.put(:repo_less, true)` makes the run truly repo-less: no worktree, no
  git call, `commit_sha: nil`, and `base_commit: nil` — so no git note and no
  `task_agent_archives` row is written either.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.ExchangeGoldenTest.GoldenAgent
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  # Per-test-unique, disjoint from every other suite's id base, so the ONE
  # app-global ETS row this test installs can never collide with (or be deleted
  # by) a concurrently running module.
  @agent_id_base 9_900_000

  @system_text "You are the golden-exchange stub agent."
  @objective "Objective: pin the unwatched-exchange call sequence."
  @report_text "scripted report text"

  # Distinct, greppable outputs so every tool result in the context is
  # identified by its OWN payload (never by position alone).
  @read_output "defmodule A do\n  # golden read\nend\n"
  @rg_output "./lib/a.ex:1: defmodule A do"
  @write_output "wrote ./lib/b.ex (golden write)"

  # A provider-reported usage map: big enough to be real, tiny enough that the
  # window-relative compression trigger is never approached.
  @usage %{input_tokens: 100, output_tokens: 20, total_tokens: 120}

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    install_agent_row(agent_id)
    on_exit(fn -> SchedStore.delete_agent_state(agent_id) end)

    # Repo-less identity, exactly as the Runner installs it for a `:reflect`
    # agent: no worktree, no git, no archive.
    Process.put(:repo_less, true)
    on_exit(fn -> Process.delete(:repo_less) end)

    %{agent_id: agent_id}
  end

  describe "an unwatched exchange" do
    test "runs in the calling process and makes exactly the same LLM and tool calls as before",
         %{agent_id: agent_id} do
      test_pid = self()
      counters = :counters.new(1, [:atomics])

      opts = [
        llm_call: llm_stub(counters),
        tool_batch: tool_batch_stub(),
        scheduler: scheduler_stub(),
        checkpoint: checkpoint_stub()
      ]

      state = initial_state(agent_id)
      # Unwatched: no streaming consumer is registered for this session.
      assert state.watchers == %{}

      assert {:finish, final_state, %Result{} = result} = Exchange.run(state, opts)

      llm_calls = recorded(:llm_calls)
      tool_batches = recorded(:tool_batches)
      scheduler_calls = recorded(:scheduler_calls)
      checkpoints = recorded(:checkpoints)

      # --- 1. The exact ordered tool-call sequence ---------------------------
      #
      # Everything about the batch is pinned: which turn it belongs to, the
      # in-response index, the tool name and the decoded arguments.
      assert Enum.map(tool_batches, fn batch -> {batch.turn, batch.calls} end) == [
               {1,
                [
                  {0, "read", %{"path" => "./lib/a.ex"}},
                  {1, "rg", %{"pattern" => "defmodule", "path" => "./lib"}}
                ]},
               {2,
                [{0, "write", %{"path" => "./lib/b.ex", "content" => "defmodule B do\nend\n"}}]}
             ]

      # The batch runs in the test process — no agent process, no tool task.
      assert Enum.map(tool_batches, & &1.pid) == [test_pid, test_pid]

      # --- 2. Exactly 3 LLM calls, in order, with a correctly GROWING context
      assert length(llm_calls) == 3
      assert Enum.map(llm_calls, & &1.index) == [1, 2, 3]
      assert Enum.map(llm_calls, & &1.pid) == [test_pid, test_pid, test_pid]
      assert Enum.map(llm_calls, & &1.agent_id) == [agent_id, agent_id, agent_id]
      assert Enum.map(llm_calls, & &1.max_retries) == [3, 3, 3]
      assert Enum.map(llm_calls, & &1.gen_params) == [[], [], []]

      [first, second, third] = llm_calls

      # Call 1: just the initial [system, user] conversation.
      assert roles(first.context) == [:system, :user]
      assert Enum.map(messages(first.context), &text_of/1) == [@system_text, @objective]

      # Call 2: the turn-1 assistant message plus BOTH turn-1 tool results, as
      # real tool-result messages with their call ids and payloads.
      assert roles(second.context) == [:system, :user, :assistant, :tool, :tool]

      assert tool_results(second.context) == [
               {"call_t1_read", "read", @read_output},
               {"call_t1_rg", "rg", @rg_output}
             ]

      # The prefix the model already saw is UNCHANGED (append-only growth).
      assert Enum.take(messages(second.context), 2) == messages(first.context)

      # Call 3: both turns' tool results are present, in call order.
      assert roles(third.context) == [
               :system,
               :user,
               :assistant,
               :tool,
               :tool,
               :assistant,
               :tool
             ]

      assert tool_results(third.context) == [
               {"call_t1_read", "read", @read_output},
               {"call_t1_rg", "rg", @rg_output},
               {"call_t2_write", "write", @write_output}
             ]

      assert Enum.take(messages(third.context), 5) == messages(second.context)

      # --- 3. The per-turn tool list is the agent module's available_tools/0 --
      expected_tools = GoldenAgent.available_tools()
      assert expected_tools != []

      assert Enum.map(llm_calls, & &1.tools) == [
               expected_tools,
               expected_tools,
               expected_tools
             ]

      # --- 4. The ONE terminal outcome --------------------------------------
      assert %Result{result: @report_text} = result
      assert result.result == @report_text
      # Repo-less: nothing was committed and nothing was archived.
      assert result.commit_sha == nil
      assert result.repo_id == nil
      assert result.branch == "evogit-agent-T-A0"

      # --- 5. The final conversation ----------------------------------------
      assert final_state.turn == 3

      assert roles(final_state.context) == [
               :system,
               :user,
               :assistant,
               :tool,
               :tool,
               :assistant,
               :tool,
               :assistant
             ]

      assert tool_results(final_state.context) == [
               {"call_t1_read", "read", @read_output},
               {"call_t1_rg", "rg", @rg_output},
               {"call_t2_write", "write", @write_output}
             ]

      # The engine tags each assistant message with the turn it produced, and
      # each tool-result message with the turn whose batch produced it — so the
      # turn-1 batch's two results are tagged 1, the turn-2 batch's result 2.
      assert final_state.context |> assistant_messages() |> Enum.map(&turn_tag/1) == [1, 2, 3]
      assert final_state.context |> tool_messages() |> Enum.map(&turn_tag/1) == [1, 1, 2]

      # The report text is the model's own final message, verbatim.
      assert final_state.context |> messages() |> List.last() |> text_of() == @report_text

      # Still unwatched at the end of the run.
      assert final_state.watchers == %{}

      # --- 6. The scheduler CONTROL-PLANE sequence ---------------------------
      #
      # One input drain + one cancel check per turn, and NOTHING else: the
      # per-turn ETS write-through kinds (`:context`, `:total_tokens`, `:turn`,
      # `{:batch, fields}`) no longer exist — the exchange's own state is the
      # authority and is published by the `:checkpoint` seam below.
      assert Enum.map(scheduler_calls, fn {kind, _payload} -> kind end) == [
               :drain_inputs,
               :cancel_requested?,
               :drain_inputs,
               :cancel_requested?,
               :drain_inputs,
               :cancel_requested?
             ]

      # --- 7. The per-turn `:checkpoint` publication ------------------------
      #
      # ONE checkpoint per turn, in turn order, each carrying that turn's state:
      # `turn`, `context`, `total_tokens` and `usage` all agree with the turn
      # that produced it. This is the ONLY per-turn state-publication path now —
      # `EvoGit.Agent.Session.Summary.publish/3` merges the summary fields
      # (`turn`, `message_count`, `usage`, `total_tokens`, `compression_count`)
      # onto the dashboard row and deliberately never copies `context`.
      assert Enum.map(checkpoints, & &1.turn) == [1, 2, 3]
      assert Enum.all?(checkpoints, &match?(%State{}, &1))
      assert Enum.all?(checkpoints, &(&1.agent_id == agent_id))

      # The checkpointed contexts ARE the conversations the next LLM call saw
      # (turn 1 → call 2, turn 2 → call 3) and the finishing turn's checkpoint
      # is the terminal state.
      assert Enum.map(checkpoints, fn cp -> cp.context.messages |> length() end) == [5, 7, 8]

      assert Enum.map(checkpoints, & &1.context) == [
               second.context,
               third.context,
               final_state.context
             ]

      assert Enum.map(checkpoints, &roles(&1.context)) ==
               [roles(second.context), roles(third.context), roles(final_state.context)]

      # The finishing turn's checkpointed state IS the final state.
      assert List.last(checkpoints) == final_state

      # Token accounting rides the checkpoint: `total_tokens` is the CURRENT
      # context length (replace semantics), `usage` the CUMULATIVE usage.
      assert Enum.map(checkpoints, & &1.total_tokens) == [120, 120, 120]
      assert Enum.map(checkpoints, & &1.usage.input_tokens) == [100, 200, 300]
      assert Enum.map(checkpoints, & &1.usage.output_tokens) == [20, 40, 60]
      assert Enum.map(checkpoints, & &1.compression_count) == [0, 0, 0]
    end
  end

  # ---------------------------------------------------------------------------
  # Seams
  # ---------------------------------------------------------------------------

  # The scripted model: ONE `%ReqLLM.Response{}` per call, appended to the
  # context the engine handed over (exactly as a real response builder does),
  # and the third call is the completion signal instead of a tool batch.
  defp llm_stub(counters) do
    fn context, tools, gen_params, agent_id, max_retries ->
      index = :counters.get(counters, 1) + 1
      :counters.add(counters, 1, 1)

      record(:llm_calls, %{
        pid: self(),
        index: index,
        context: context,
        tools: tools,
        gen_params: gen_params,
        agent_id: agent_id,
        max_retries: max_retries
      })

      scripted_reply(index, context)
    end
  end

  defp scripted_reply(1, context) do
    {:ok,
     response(
       context,
       assistant_message("Reading the module and searching for its siblings.", [
         tool_call("call_t1_read", "read", %{"path" => "./lib/a.ex"}),
         tool_call("call_t1_rg", "rg", %{"pattern" => "defmodule", "path" => "./lib"})
       ])
     )}
  end

  defp scripted_reply(2, context) do
    {:ok,
     response(
       context,
       assistant_message("Writing the sibling module.", [
         tool_call("call_t2_write", "write", %{
           "path" => "./lib/b.ex",
           "content" => "defmodule B do\nend\n"
         })
       ])
     )}
  end

  defp scripted_reply(3, context) do
    # A reply with NO tool calls ends the run and its text IS the report — the
    # ONE completion route (there is no completion tool).
    {:implicit_completion, response(context, assistant_message(@report_text, nil)), @report_text}
  end

  # The `:tool_batch` seam REPLACES the whole standard-call batch: it receives
  # `[{tool_call, index}]` and must answer `[{index, tool_call_id, name,
  # output}]`, which is exactly the shape `batch_execute_tools/5` returns.
  defp tool_batch_stub do
    fn indexed_calls, state ->
      calls =
        Enum.map(indexed_calls, fn {call, index} ->
          {index, ReqLLM.ToolCall.name(call), ReqLLM.ToolCall.args_map(call)}
        end)

      record(:tool_batches, %{pid: self(), turn: state.turn, calls: calls})

      Enum.map(indexed_calls, fn {call, index} ->
        name = ReqLLM.ToolCall.name(call)
        {index, call.id, name, output_for(name)}
      end)
    end
  end

  # The `:scheduler` seam: one adapter for every scheduler CONTROL-PLANE
  # interaction the loop performs. It records the kind + payload and answers the
  # sane values a bare process needs (no pending inputs, no cancellation).
  defp scheduler_stub do
    fn kind, payload, _state ->
      record(:scheduler_calls, {kind, payload})

      case kind do
        :drain_inputs -> []
        :cancel_requested? -> false
      end
    end
  end

  # The `:checkpoint` seam: records every state handed to it. Its return value is
  # discarded by the engine (observable-only), so `:ok` is the whole contract.
  defp checkpoint_stub do
    fn state ->
      record(:checkpoints, state)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario data
  # ---------------------------------------------------------------------------

  defp output_for("read"), do: @read_output
  defp output_for("rg"), do: @rg_output
  defp output_for("write"), do: @write_output

  defp tool_call(id, name, args) do
    ReqLLM.ToolCall.new(id, name, Jason.encode!(args))
  end

  defp response(context, message) do
    %ReqLLM.Response{
      id: "golden-response",
      model: "golden:model",
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
      agent_module: GoldenAgent,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system(@system_text),
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

  # The ONE ETS read the P1 finish path still performs
  # (`ToolDispatch.build_completion/3` → `AgentScheduler.get_agent_state/1`).
  # `phylo_node: nil` is the repo-less shape (never dereferenced because
  # `repo_less` short-circuits `base_commit` to nil) and `archive: false` keeps
  # the archive writer out of the run entirely.
  defp install_agent_row(agent_id) do
    :ok =
      SchedStore.put_agent_state(agent_id, %AgentState{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        phylo_node: nil,
        parent_id: nil,
        archive: false,
        llm_model: nil,
        model_id: "golden",
        max_turns: 128,
        max_retries: 3,
        max_depth: nil,
        repo_id: "primary",
        llm_context_window: 200_000
      })
  end

  # ---------------------------------------------------------------------------
  # Recording (process dictionary of the calling — plain ExUnit — process)
  # ---------------------------------------------------------------------------

  defp record(key, entry) do
    Process.put(key, [entry | Process.get(key, [])])
    :ok
  end

  defp recorded(key), do: key |> Process.get([]) |> Enum.reverse()

  # ---------------------------------------------------------------------------
  # Context inspection
  # ---------------------------------------------------------------------------

  defp messages(%ReqLLM.Context{messages: messages}), do: messages

  defp roles(context), do: context |> messages() |> Enum.map(& &1.role)

  defp assistant_messages(context),
    do: context |> messages() |> Enum.filter(&(&1.role == :assistant))

  defp tool_messages(context), do: context |> messages() |> Enum.filter(&(&1.role == :tool))

  defp tool_results(context) do
    context
    |> tool_messages()
    |> Enum.map(fn msg -> {msg.tool_call_id, msg.name, text_of(msg)} end)
  end

  defp turn_tag(%ReqLLM.Message{metadata: metadata}), do: metadata[:turn]

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
