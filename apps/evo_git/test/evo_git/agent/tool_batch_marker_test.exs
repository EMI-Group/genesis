defmodule EvoGit.Agent.ToolBatchMarkerTest.LifecycleAgent do
  @moduledoc """
  The role the marker-lifecycle exchange runs AS.

  A canned `system_prompt/0` and no tools are all the engine needs: the whole
  tool batch is replaced by the `:tool_batch` seam, so no real tool — and no
  subagent spawn — is ever dispatched. No subagents are declared, which keeps
  every call in the batch on the seam-covered standard-call path.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the tool-batch marker lifecycle stub agent."

  @doc "No tools: `:tool_batch` replaces the entire batch."
  def available_tools, do: []
end

defmodule EvoGit.Agent.ToolBatchMarkerTest do
  @moduledoc """
  The LIFECYCLE of the in-flight tool-batch marker
  (`%EvoGit.Agent.State{pending_tool_batch: batch}`), driven through the real
  `EvoGit.Agent.Exchange` engine with its seam set — no live session, no ETS
  write-through, no real tool execution.

  ## What is pinned (the module's stated invariant)

      pending_tool_batch != nil  <=>  a tool batch is executing right now

  1. **Before the batch runs**, the pre-batch checkpoint carries BOTH the
     assistant `tool_calls` message AND the marker in its own field — and it
     reaches the checkpoint seam BEFORE the batch seam is entered, so a crash
     inside the batch leaves a durable "these calls were in flight" record;
  2. the marker's `turn` is the ALREADY-INCREMENTED turn of the batch (that is
     what makes the pre-batch checkpoint adoptable by the session);
  3. **`continue_after_tools` clears it** in the SAME state the turn boundary
     checkpoints, and the transcript of that state answers exactly the calls the
     marker listed (proving the batch really completed in between);
  4. **`Exchange.terminal_state/1` clears it** even when the incoming state
     still carries a stale marker, so a durable terminal row can never claim a
     batch is live;
  5. **`persistent_state: false` is fully inert**: no marker is written and the
     pre-batch checkpoint — the only store-touching cast on this path — is never
     fired (the seam is not merely handed a `nil`), while the loop's transcript,
     turn count and result stay byte-identical to the durable run.

  ## Isolation

  The checkpoint and tool-batch seams send to the TEST pid (no file, no Agent,
  no shared process). The two app-global ETS rows the completion path still
  reads are installed under a per-test-UNIQUE agent id and deleted on exit — the
  module never asserts on table size or emptiness.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolBatch
  alias EvoGit.Agent.ToolBatchMarkerTest.LifecycleAgent
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec

  # Per-test-unique, disjoint from every other suite's id base (the golden
  # exchange test uses 9_900_000, the checkpoint-seam suite 9_920_000).
  @agent_id_base 9_930_000

  @objective "Objective: observe the in-flight tool-batch marker."
  @report_text "marker lifecycle report text"
  @usage %{input_tokens: 100, output_tokens: 20, total_tokens: 120}

  # A pinned clock so two runs of the same script can be compared byte for byte
  # (per-message `metadata[:timestamp]` is otherwise wall-clock).
  @pinned_now 1_700_000_000

  @tool_output "tool output for the in-flight batch"

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    install_agent_row(agent_id)

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
    end)

    # Repo-less identity: no worktree, no git, no archive (the completion path
    # short-circuits `base_commit` to nil and writes no note).
    Process.put(:repo_less, true)
    on_exit(fn -> Process.delete(:repo_less) end)

    %{agent_id: agent_id}
  end

  describe "the marker BEFORE a tool batch runs" do
    test "the pre-batch checkpoint carries the assistant tool_calls AND the marker",
         %{agent_id: agent_id} do
      timeline = run_script(agent_id, persistent_state: true)

      # TWO tool-calling turns and ONE finishing turn, so the ordered timeline is
      # exactly: pre-batch cp, batch, turn cp, pre-batch cp, batch, turn cp,
      # terminal cp. The batch entries are BETWEEN checkpoint entries — the
      # marker reached the seam BEFORE any tool ran.
      assert [:cp, :batch, :cp, :cp, :batch, :cp, :cp] = Enum.map(timeline, &elem(&1, 0))

      [{:cp, pre_one}, {:batch, batch_one_turn, batch_one_marker}, {:cp, after_one} | _rest] =
        timeline

      # 1. The turn was ALREADY incremented when the marker was written (this is
      #    what makes the pre-batch checkpoint adoptable at the same turn).
      assert pre_one.turn == 1
      marker = pre_one.pending_tool_batch
      assert %{turn: 1, started_at: started_at, calls: pre_one_calls} = marker
      assert is_binary(started_at)
      assert {:ok, _, _} = DateTime.from_iso8601(started_at)
      assert marker.turn == pre_one.turn

      assert pre_one_calls == [
               %{index: 0, id: "call_t1_read", name: "read", class: :read},
               %{index: 1, id: "call_t1_bash", name: "bash", class: :shell}
             ]

      # 2. The SAME checkpoint state carries the assistant `tool_calls` message in
      #    its transcript — the marker alone would not say what was called.
      assert %ReqLLM.Message{role: :assistant} = last_message(pre_one)

      assert Enum.map(last_message(pre_one).tool_calls, & &1.id) ==
               Enum.map(pre_one_calls, & &1.id)

      assert message_count(pre_one) == 3

      # 3. The batch seam was entered AFTER that checkpoint and saw the marker.
      assert batch_one_turn == 1
      assert batch_one_marker == marker

      # 4. `continue_after_tools` cleared the marker in the state the turn
      #    boundary checkpoints, and that transcript answers exactly the calls
      #    the marker listed (the batch really completed).
      assert after_one.pending_tool_batch == nil
      assert after_one.turn == 1
      assert tool_result_ids(after_one) == Enum.map(pre_one_calls, & &1.id)
      assert message_count(after_one) == message_count(pre_one) + 2
    end

    test "every tool-calling turn opens its own marker with that turn's classes",
         %{agent_id: agent_id} do
      timeline = run_script(agent_id, persistent_state: true)
      checkpoints = for {:cp, state} <- timeline, do: state

      markers = Enum.map(checkpoints, & &1.pending_tool_batch)

      assert Enum.map(markers, fn
               nil -> nil
               batch -> {batch.turn, Enum.map(batch.calls, & &1.class)}
             end) == [
               {1, [:read, :shell]},
               nil,
               {2, [:edit, :write]},
               nil,
               nil
             ]

      # Every marker's turn IS the turn it was written on (never turn-1, never a
      # synthetic batch index), and its call indices are dense and ordered.
      for %State{pending_tool_batch: batch} = state <- checkpoints, not is_nil(batch) do
        assert batch.turn == state.turn

        assert Enum.map(batch.calls, & &1.index) ==
                 Enum.to_list(0..(length(batch.calls) - 1))
      end

      # The terminal checkpoint (turn 3) is the completion turn: no marker.
      assert List.last(checkpoints).turn == 3
      assert List.last(checkpoints).pending_tool_batch == nil
    end
  end

  describe "the marker AFTER the batch" do
    test "the finished run's state carries no marker", %{agent_id: agent_id} do
      {final_state, result} = run_script_result(agent_id, persistent_state: true)

      assert %State{} = final_state
      assert %Result{} = result
      assert final_state.pending_tool_batch == nil
      assert result.result == @report_text
      # 2 initial messages + 1 assistant + 2 results per tool turn (× 2) +
      # 1 final assistant reply.
      assert message_count(final_state) == 9
    end

    test "Exchange.terminal_state/1 clears a STALE marker on the terminal checkpoint",
         %{agent_id: agent_id} do
      # A restored-but-unrepaired marker: `Resume.apply/1` is a no-op without a
      # crash-retry `resume_info`, so the loop really starts with it set.
      stale_marker = ToolBatch.build([%{id: "call_stale", name: "bash"}], 0, [])
      state = initial_state(agent_id, persistent_state: true, pending_tool_batch: stale_marker)
      refute is_nil(state.pending_tool_batch)

      # The FIRST turn is the terminal one (plain-text reply, no tool calls).
      test_pid = self()

      assert {:finish, %State{} = final_state, %Result{}} =
               Exchange.run(state,
                 now: @pinned_now,
                 llm_call: completion_llm_stub(),
                 tool_batch: no_tools_batch(test_pid),
                 scheduler: scheduler_stub(),
                 checkpoint: fn st -> send(test_pid, {:cp, st}) end
               )

      timeline = collect_timeline()

      # Exactly ONE checkpoint (the terminal state) and NO batch entry at all.
      assert [{:cp, terminal}] = timeline
      assert terminal.turn == 1
      # `terminal_state/1` normalises the DURABLE row: the checkpointed state can
      # never claim a batch is live…
      assert terminal.pending_tool_batch == nil
      assert message_count(terminal) == message_count(final_state)
      # …while the in-memory state the exchange returns is untouched (the run is
      # over, so only the durable row's invariant matters).
      assert final_state.turn == 1
      assert final_state.pending_tool_batch == stale_marker
    end
  end

  describe "persistent_state: false is fully inert" do
    test "writes no marker, fires NO pre-batch checkpoint, and changes nothing else",
         %{agent_id: agent_id} do
      durable = run_script(agent_id, persistent_state: true)
      inert = run_script(agent_id, persistent_state: false)

      # (a) The durable run fires the pre-batch checkpoint for each tool turn;
      #     the inert run fires ONLY the turn-boundary checkpoints. Counting the
      #     seam calls (not inspecting a value) is what proves the opt-out skips
      #     the store-touching cast entirely.
      assert [:cp, :batch, :cp, :cp, :batch, :cp, :cp] = Enum.map(durable, &elem(&1, 0))
      assert [:batch, :cp, :batch, :cp, :cp] = Enum.map(inert, &elem(&1, 0))

      inert_checkpoints = for {:cp, state} <- inert, do: state
      assert Enum.map(inert_checkpoints, & &1.turn) == [1, 2, 3]

      # (b) Nothing the inert run produces ever carries a marker — not the
      #     checkpointed states and not the state handed to the batch.
      assert Enum.all?(inert_checkpoints, &(&1.pending_tool_batch == nil))

      for {:batch, _turn, marker} <- inert do
        assert marker == nil
      end

      # (c) The opt-out costs NOTHING but durability: same transcript, same turn
      #     count, same report (the clock is pinned, so even the per-message
      #     timestamps match).
      durable_checkpoints = for {:cp, state} <- durable, do: state

      assert Enum.count(durable_checkpoints, &(not is_nil(&1.pending_tool_batch))) == 2

      {durable_final, durable_result} = run_script_result(agent_id, persistent_state: true)
      {inert_final, inert_result} = run_script_result(agent_id, persistent_state: false)

      assert inert_final.context == durable_final.context
      assert inert_final.turn == durable_final.turn
      assert message_count(inert_final) == message_count(durable_final)
      assert inert_result.result == durable_result.result
      assert inert_final.pending_tool_batch == nil
      assert durable_final.pending_tool_batch == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario
  # ---------------------------------------------------------------------------

  # The ordered timeline of ONE exchange run: every checkpoint seam call and
  # every tool-batch seam entry, in ARRIVAL order (both seams send from this
  # process, so message order IS program order).
  defp run_script(agent_id, marker_opts) do
    {_final_state, _result} = run_script_result(agent_id, marker_opts)
    collect_timeline()
  end

  defp run_script_result(agent_id, marker_opts) do
    test_pid = self()

    {:finish, %State{} = final_state, %Result{} = result} =
      Exchange.run(
        initial_state(agent_id, marker_opts),
        now: @pinned_now,
        llm_call: scripted_llm_stub(),
        tool_batch: fn indexed_calls, state ->
          send(test_pid, {:batch, state.turn, state.pending_tool_batch})

          Enum.map(indexed_calls, fn {call, index} ->
            {index, call.id, ReqLLM.ToolCall.name(call), @tool_output}
          end)
        end,
        scheduler: scheduler_stub(),
        checkpoint: fn state -> send(test_pid, {:cp, state}) end
      )

    {final_state, result}
  end

  defp collect_timeline(acc \\ []) do
    receive do
      {:cp, %State{} = state} -> collect_timeline([{:cp, state} | acc])
      {:batch, turn, marker} -> collect_timeline([{:batch, turn, marker} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Turn 1: read + shell. Turn 2: edit + write. Turn 3: a plain-text reply,
  # which IS the completion.
  defp scripted_llm_stub do
    fn context, _tools, _gen_params, _agent_id, _max_retries ->
      case assistant_message_count(context) do
        0 ->
          {:ok,
           response(
             context,
             tool_message([
               ReqLLM.ToolCall.new("call_t1_read", "read", "{}"),
               ReqLLM.ToolCall.new("call_t1_bash", "bash", "{}")
             ])
           )}

        1 ->
          {:ok,
           response(
             context,
             tool_message([
               ReqLLM.ToolCall.new("call_t2_edit", "edit", "{}"),
               ReqLLM.ToolCall.new("call_t2_write", "create_files", "{}")
             ])
           )}

        _done ->
          {:implicit_completion, response(context, assistant_message(@report_text, nil)),
           @report_text}
      end
    end
  end

  # A reply with no tool calls: the FIRST turn is terminal.
  defp completion_llm_stub do
    fn context, _tools, _gen_params, _agent_id, _max_retries ->
      {:implicit_completion, response(context, assistant_message(@report_text, nil)),
       @report_text}
    end
  end

  # Records any batch entry (which the timeline assertion then rejects): a
  # terminal first turn must never enter the tool batch.
  defp no_tools_batch(test_pid) do
    fn indexed_calls, state ->
      send(test_pid, {:batch, state.turn, state.pending_tool_batch})

      Enum.map(indexed_calls, fn {call, index} ->
        {index, call.id, ReqLLM.ToolCall.name(call), @tool_output}
      end)
    end
  end

  # ONE adapter for every scheduler/control-plane interaction the loop performs:
  # no pending inputs, no cancellation.
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
      id: "marker-response",
      model: "marker:model",
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

  defp tool_message(tool_calls), do: assistant_message("Running the batch.", tool_calls)

  defp initial_state(agent_id, opts) do
    %State{
      agent_id: agent_id,
      agent_module: LifecycleAgent,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system(LifecycleAgent.system_prompt()),
          ReqLLM.Context.user(@objective)
        ]),
      objective: @objective,
      repo_less: true,
      persistent_state: Keyword.fetch!(opts, :persistent_state),
      pending_tool_batch: Keyword.get(opts, :pending_tool_batch),
      max_turns: 128,
      max_retries: 3,
      llm_generation_params: [],
      llm_context_window: 200_000
    }
  end

  # The TWO registration reads the completion path still performs (the summary
  # row for the archive/model metadata and the sched_meta row for the spec's
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
        model_id: "marker",
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
          agent_module: LifecycleAgent,
          objective: @objective
        }
      })

    :ok
  end

  # ---------------------------------------------------------------------------
  # Transcript inspection
  # ---------------------------------------------------------------------------

  defp message_count(%State{context: %ReqLLM.Context{messages: messages}}),
    do: length(messages)

  defp last_message(%State{context: %ReqLLM.Context{messages: messages}}), do: List.last(messages)

  defp assistant_message_count(%ReqLLM.Context{messages: messages}),
    do: Enum.count(messages, &(&1.role == :assistant))

  defp tool_result_ids(%State{context: %ReqLLM.Context{messages: messages}}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(& &1.tool_call_id)
  end
end
