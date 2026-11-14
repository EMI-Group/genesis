defmodule EvoGit.Agent.ExchangePauseTest.PauseAgent do
  @moduledoc """
  The role a pause-seam exchange runs AS.

  A canned `system_prompt/0` and ONE fixed tool schema are all the engine needs
  from the agent module: the pause boundaries are loop control, so the tests
  assert on the outcomes and the states the seams receive, never on the role's
  behaviour.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the pause-seam stub agent."

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

defmodule EvoGit.Agent.ExchangePauseTest do
  @moduledoc """
  The AGENT-LOOP half of TASK-LEVEL PAUSE: where `EvoGit.Agent.Exchange` honours
  a per-agent pause request and what the resulting `{:pause, %State{}}` outcome
  guarantees.

  ## The two boundaries (and the one place a pause is NEVER honoured)

  A pause is probed at exactly TWO turn boundaries:

  1. the TOP of the exchange loop, immediately after the cancel check returned
     `:no_cancel` and BEFORE the turn-limit check and `EvoGit.Agent.Turn.run/3`
     — this is the boundary that catches a pause that arrived during an
     in-flight LLM call (`EvoGit.Agent.Exchange.continue_loop/3`);
  2. right AFTER a tool batch completed (results appended, the in-flight marker
     cleared) and before the next loop step
     (`EvoGit.Agent.ToolDispatch.continue_after_tools/7`).

  There is NO mid-batch check by design: a pause never interrupts an in-flight
  tool call, which is what makes the pause CLEAN.

  ## What these tests pin

  * the loop-top boundary returns `{:pause, state}` with NO further LLM call;
  * the batch boundary executes BOTH calls of a 2-call batch and returns
    `{:pause, state}` right after it, again with no further LLM call;
  * the `:pause_requested?` seam overrides the `ControlPlane` default in BOTH
    directions (flag false + seam true ⇒ pause; flag true + seam false ⇒ no
    pause), and an ABSENT seam reads the `ControlPlane` flag;
  * CANCEL WINS the contested boundary: with both flags set the cancel-grace
    path is entered first (`:cancel_requested?` / `:clear_cancel` before any
    `:pause_requested?` probe), so the pause can only be honoured at the NEXT
    boundary — when it is the only pending request it is honoured at the FIRST;
  * the paused state is checkpointed exactly ONCE per turn boundary, that
    checkpoint IS the returned state, and it carries NO `pending_tool_batch`
    marker (a completed batch is never live).

  ## Isolation

  Every seam sends to the TEST pid (no file, no Agent). `ControlPlane` flags are
  per-agent ETS state, written under a PER-TEST UNIQUE agent id
  (`10_010_000 + unique_integer`) whose production-shaped registration rows are
  deleted in `on_exit`; nothing here asserts on table size or emptiness, mutates
  an app-env key or touches `:persistent_term`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.Exchange.Seams
  alias EvoGit.Agent.ExchangePauseTest.PauseAgent
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec

  # A range of its own (the checkpoint/golden/yield/pause suites each own one),
  # so a concurrently running module can neither collide with nor delete this
  # module's ETS rows.
  @agent_id_base 10_010_000

  @objective "Objective: observe one pause at a turn boundary."
  @report_text "pause report text"
  @usage %{input_tokens: 100, output_tokens: 20, total_tokens: 120}

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    install_agent_row(agent_id)

    on_exit(fn ->
      # `delete_agent_state/1` also drops the control-plane inbox/control rows.
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
    end)

    # Repo-less identity, exactly as the Runner installs it for a `:reflect`
    # agent: no worktree, no git, no archive — so a `{:finish, …}` outcome in
    # the "no pause" cases never touches a repository.
    Process.put(:repo_less, true)
    on_exit(fn -> Process.delete(:repo_less) end)

    %{agent_id: agent_id}
  end

  describe "the loop-top boundary" do
    test "pauses before the next LLM call when the flag was set during the turn",
         %{agent_id: agent_id} do
      test_pid = self()

      # The seam sets the PRODUCTION flag while the turn is in flight and ends
      # the turn without a tool call (`{:interrupted, _}` re-enters the loop at
      # its top), so the pause can only be caught by the loop-top probe.
      llm_call = fn _context, _tools, _params, called_agent_id, _retries ->
        send(test_pid, {:llm_call, called_agent_id})
        :ok = ControlPlane.set_pause(agent_id, true)
        {:interrupted, :task_pause_requested}
      end

      opts = [
        llm_call: llm_call,
        tool_batch: flunk_tool_batch(),
        # NO scheduler seam: the production `:pause_requested?` read (the
        # ControlPlane flag) is under test here.
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), opts)

      # An LLM call happened ONCE and then the loop stopped: no second call, no
      # turn advance beyond the initial state.
      assert llm_calls(agent_id) == 1
      assert paused.turn == 0

      # The LAST turn boundary is the paused state: the terminal-state
      # checkpoint of `Exchange.run/2` fires AFTER the pause is decided, so the
      # durable row and the returned state describe the same boundary (the
      # exactly-once count is pinned by the dedicated test below).
      assert List.last(collect_checkpoints(agent_id)) == paused

      # A pause is a resting outcome, NOT a completion: the outcome is the
      # two-element `{:pause, state}` term (never `{:finish, state, %Result{}}`,
      # which the pattern match above already excludes) and the state carries no
      # in-flight marker.
      assert paused.pending_tool_batch == nil
    end

    test "a pause requested before the run is checkpointed exactly once, with no LLM call",
         %{agent_id: agent_id} do
      test_pid = self()

      # The flag is already set when the exchange starts: the FIRST loop top
      # honours it, so nothing but the terminal pause boundary is checkpointed.
      :ok = ControlPlane.set_pause(agent_id, true)

      opts = [
        llm_call: reply_after_llm(test_pid),
        tool_batch: flunk_tool_batch(),
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), opts)

      assert llm_calls(agent_id) == 0
      assert collect_checkpoints(agent_id) == [paused]
    end

    test "an absent :pause_requested? seam reads the ControlPlane flag in both directions",
         %{agent_id: agent_id} do
      test_pid = self()

      base_opts = [
        llm_call: reply_after_llm(test_pid),
        tool_batch: flunk_tool_batch()
      ]

      # 1. No flag set: the very same exchange finishes normally.
      assert {:finish, %State{}, %Result{result: @report_text}} =
               Exchange.run(initial_state(agent_id), base_opts)

      # 2. The ControlPlane flag set: the loop top pauses instead. The stub
      #    cannot have been reached (a pause is decided BEFORE the turn).
      :ok = ControlPlane.set_pause(agent_id, true)

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), base_opts)
      assert paused.turn == 0
    end
  end

  describe "the batch boundary" do
    test "runs the WHOLE batch, then pauses, with no further LLM call",
         %{agent_id: agent_id} do
      test_pid = self()

      # TWO calls in ONE batch. The seam sets the pause flag WHILE the batch is
      # executing; both calls must still run and both results must reach the
      # transcript.
      tool_batch = fn indexed_calls, _state ->
        :ok = ControlPlane.set_pause(agent_id, true)
        send(test_pid, {:tool_batch, length(indexed_calls)})

        Enum.map(indexed_calls, fn {call, index} ->
          {index, call.id, ReqLLM.ToolCall.name(call), "read output #{index}"}
        end)
      end

      opts = [
        llm_call: two_call_llm(test_pid),
        tool_batch: tool_batch,
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), opts)

      # The batch really ran BOTH calls ...
      assert_received {:tool_batch, 2}
      tool_results = tool_messages(paused)
      assert Enum.map(tool_results, &text_of/1) == ["read output 0", "read output 1"]

      # ... and the pause stopped the exchange right after it: ONE LLM call for
      # the whole run (the tool-calling turn only), never a second one.
      assert llm_calls(agent_id) == 1
      assert paused.turn == 1

      # The completed batch is never presented as still in flight.
      assert paused.pending_tool_batch == nil

      # ONE checkpoint — the terminal state of the paused turn (this state has
      # `persistent_state: false`, so the pre-batch marker checkpoint is inert).
      assert [checkpointed] = collect_checkpoints(agent_id)
      assert checkpointed == paused
    end

    test "the paused state is checkpointed once per turn and carries no in-flight marker",
         %{agent_id: agent_id} do
      test_pid = self()

      # `persistent_state: true` is the durable shape: the batch START
      # checkpoints the in-flight marker, and the pause boundary checkpoints the
      # SAME batch as completed. The two checkpoints are the proof that the
      # marker is written and then cleared in the state the pause returns.
      llm_call = two_call_llm(test_pid)

      tool_batch = fn indexed_calls, _state ->
        :ok = ControlPlane.set_pause(agent_id, true)

        Enum.map(indexed_calls, fn {call, index} ->
          {index, call.id, ReqLLM.ToolCall.name(call), "read output #{index}"}
        end)
      end

      opts = [
        llm_call: llm_call,
        tool_batch: tool_batch,
        checkpoint: fn state -> send(test_pid, {:checkpoint, state}) end
      ]

      assert {:pause, %State{} = paused} =
               Exchange.run(initial_state(agent_id, persistent_state: true), opts)

      [batch_start, paused_checkpoint] = collect_checkpoints(agent_id)

      # The batch START carries the marker; the pause boundary — exactly one
      # turn-boundary checkpoint later — does not.
      assert %{turn: 1, calls: [%{index: 0}, %{index: 1}]} = batch_start.pending_tool_batch
      assert batch_start.turn == paused.turn
      assert paused_checkpoint == paused
      assert paused_checkpoint.pending_tool_batch == nil
    end
  end

  describe "the :pause_requested? seam" do
    test "an explicit seam overrides the ControlPlane flag in both directions",
         %{agent_id: agent_id} do
      test_pid = self()

      # Direction (a): the flag is FALSE but the seam says pause.
      opts_pausing = [
        llm_call: reply_after_llm(test_pid),
        tool_batch: flunk_tool_batch(),
        scheduler:
          scheduler_seam(fn payload ->
            send(test_pid, {:pause_probe, payload})
            true
          end)
      ]

      assert ControlPlane.pause_requested?(agent_id) == false

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), opts_pausing)
      assert paused.turn == 0
      # The seam receives the AGENT ID as its payload — never the state or a
      # stale copy of the flag.
      assert_received {:pause_probe, ^agent_id}
      assert llm_calls(agent_id) == 0

      # Direction (b): the flag is TRUE but the seam says do not pause, so the
      # run completes exactly as it would with no pause at all.
      :ok = ControlPlane.set_pause(agent_id, true)

      opts_not_pausing = [
        llm_call: reply_after_llm(test_pid),
        tool_batch: flunk_tool_batch(),
        scheduler: scheduler_seam(fn _payload -> false end)
      ]

      assert {:finish, %State{}, %Result{result: @report_text}} =
               Exchange.run(initial_state(agent_id), opts_not_pausing)

      # The flag is still there: the seam OVERRODE the probe, it did not clear
      # the ControlPlane state.
      assert ControlPlane.pause_requested?(agent_id)
    end
  end

  describe "cancel wins the contested boundary" do
    test "with both flags set the cancel-grace path is entered before any pause probe",
         %{agent_id: agent_id} do
      test_pid = self()

      # BOTH requests are set through the PRODUCTION control plane, and the
      # recording seam only OBSERVES the calls the engine makes (it delegates to
      # `Seams.default_scheduler/3`), so the assertion is about the real order.
      :ok = ControlPlane.set_cancel(agent_id, true)
      :ok = ControlPlane.set_pause(agent_id, true)

      opts = [
        llm_call: reply_after_llm(test_pid),
        tool_batch: flunk_tool_batch(),
        scheduler: fn kind, payload, state ->
          send(test_pid, {:scheduler_kind, kind})
          Seams.default_scheduler(kind, payload, state)
        end
      ]

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), opts)

      kinds = scheduler_kinds()

      # The contested boundary is decided by the CANCEL check: the pause probe
      # comes only AFTER the cancel flag was read and cleared, i.e. the pause
      # was never consulted while the cancellation was pending.
      clear_index = Enum.find_index(kinds, &(&1 == :clear_cancel))
      pause_index = Enum.find_index(kinds, &(&1 == :pause_requested?))
      assert is_integer(clear_index)
      assert is_integer(pause_index)
      assert pause_index > clear_index
      assert Enum.find_index(kinds, &(&1 == :cancel_requested?)) < clear_index

      # The cancel-grace path really ran (it is what makes the state grace-
      # bearing) and NO LLM call happened before it: the pause is honoured at
      # the FIRST boundary at which it is the only pending request.
      assert paused.in_grace_period == true
      assert llm_calls(agent_id) == 0
    end

    test "a lone pause is honoured at the FIRST boundary, with no grace period",
         %{agent_id: agent_id} do
      test_pid = self()

      :ok = ControlPlane.set_pause(agent_id, true)

      opts = [
        llm_call: reply_after_llm(test_pid),
        tool_batch: flunk_tool_batch(),
        scheduler: fn kind, payload, state ->
          send(test_pid, {:scheduler_kind, kind})
          Seams.default_scheduler(kind, payload, state)
        end
      ]

      assert {:pause, %State{} = paused} = Exchange.run(initial_state(agent_id), opts)

      kinds = scheduler_kinds()
      assert :pause_requested? in kinds
      refute :clear_cancel in kinds
      assert paused.in_grace_period == false
      assert llm_calls(agent_id) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Seams
  # ---------------------------------------------------------------------------

  # A tool-free reply: the ONE completion route (a `%Result{}` for a one-shot
  # agent). Counts the LLM invocation so a "no further LLM call" claim is
  # provable rather than assumed.
  defp reply_after_llm(test_pid) do
    fn context, _tools, _params, agent_id, _retries ->
      send(test_pid, {:llm_call, agent_id})

      {:implicit_completion, response(context, assistant_message(@report_text, nil)),
       @report_text}
    end
  end

  # Turn 1 asks for TWO tool calls in ONE batch; the stub would answer a second
  # turn with plain text — which must never be reached once the pause lands.
  defp two_call_llm(test_pid) do
    fn context, _tools, _params, agent_id, _retries ->
      send(test_pid, {:llm_call, agent_id})

      if assistant_message_count(context) == 0 do
        {:ok,
         response(
           context,
           assistant_message("Reading two modules.", [
             ReqLLM.ToolCall.new("call_t1_a", "read", Jason.encode!(%{"path" => "./lib/a.ex"})),
             ReqLLM.ToolCall.new("call_t1_b", "read", Jason.encode!(%{"path" => "./lib/b.ex"}))
           ])
         )}
      else
        {:implicit_completion, response(context, assistant_message(@report_text, nil)),
         @report_text}
      end
    end
  end

  # A batch that must NEVER run: every scenario using it pauses at the LOOP TOP,
  # before any tool call is dispatched.
  defp flunk_tool_batch do
    fn _indexed_calls, _state ->
      flunk("the tool batch must not run: the pause is honoured at the loop top")
    end
  end

  # The pure scheduler adapter the loop calls, with the `:pause_requested?`
  # answer supplied by the test. Every other kind is the production one.
  defp scheduler_seam(pause_fun) do
    fn kind, payload, _state ->
      case kind do
        :drain_inputs ->
          []

        :cancel_requested? ->
          false

        :clear_cancel ->
          :ok

        :pause_requested? ->
          pause_fun.(payload)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario data
  # ---------------------------------------------------------------------------

  defp response(context, message) do
    %ReqLLM.Response{
      id: "exchange-pause-response",
      model: "pause:model",
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

  defp initial_state(agent_id, overrides \\ []) do
    %State{
      agent_id: agent_id,
      agent_module: PauseAgent,
      depth: 0,
      node_path: "./",
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system(PauseAgent.system_prompt()),
          ReqLLM.Context.user(@objective)
        ]),
      objective: @objective,
      repo_less: true,
      max_turns: 128,
      max_retries: 3,
      llm_generation_params: [],
      llm_context_window: 200_000,
      persistent_state: Keyword.get(overrides, :persistent_state, false)
    }
  end

  # The registration rows `ControlPlane.set_pause/2` / `set_cancel/2` require
  # (`agent_row?/1` reads the summary table) and the completion path reads.
  defp install_agent_row(agent_id) do
    :ok =
      SchedStore.put_agent_state(agent_id, %AgentState{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        parent_id: nil,
        archive: false,
        llm_model: nil,
        model_id: "pause",
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
          agent_module: PauseAgent,
          objective: @objective
        }
      })

    :ok
  end

  # ---------------------------------------------------------------------------
  # Collectors (messages sent to THIS test process)
  # ---------------------------------------------------------------------------

  defp llm_calls(agent_id), do: count_llm_calls(agent_id, 0)

  defp count_llm_calls(agent_id, count) do
    receive do
      {:llm_call, ^agent_id} -> count_llm_calls(agent_id, count + 1)
      {:llm_call, _other_agent} -> count_llm_calls(agent_id, count)
    after
      0 -> count
    end
  end

  # Only THIS test's exchange contributes: the agent id is per-test-unique.
  defp collect_checkpoints(agent_id), do: collect_checkpoints(agent_id, [])

  defp collect_checkpoints(agent_id, acc) do
    receive do
      {:checkpoint, %State{agent_id: ^agent_id} = state} ->
        collect_checkpoints(agent_id, [state | acc])

      {:checkpoint, _other_agent} ->
        collect_checkpoints(agent_id, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp scheduler_kinds, do: collect_kinds([])

  defp collect_kinds(acc) do
    receive do
      {:scheduler_kind, kind} -> collect_kinds([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Message inspection
  # ---------------------------------------------------------------------------

  defp tool_messages(%State{context: %ReqLLM.Context{messages: messages}}) do
    Enum.filter(messages, &(&1.role == :tool))
  end

  defp assistant_message_count(%ReqLLM.Context{messages: messages}) do
    Enum.count(messages, &(&1.role == :assistant))
  end

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    Enum.map_join(content, fn part -> Map.get(part, :text) || "" end)
  end

  defp text_of(%ReqLLM.Message{content: content}) when is_binary(content), do: content
end
