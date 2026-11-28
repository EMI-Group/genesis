defmodule EvoGit.Agent.SessionTest.StubAgent do
  @moduledoc """
  The agent module a session-test run executes AS.

  A session needs a real `EvoGit.Agent` implementation because
  `EvoGit.Agent.Session.Setup.build_initial_state/3` calls the role's
  `system_prompt/0`, `available_tools/0` and `delegation_level/0`. The tool list
  is deliberately EMPTY: every exchange here is driven end-to-end by the
  `:llm_call` engine seam (a reply with no tool calls finishes the run), so no
  tool schema ever has to be dispatched.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the session-test stub agent."

  @doc "No tools: the scripted model never asks for one."
  def available_tools, do: []
end

defmodule EvoGit.Agent.SessionTest do
  @moduledoc """
  Behavioural coverage for `EvoGit.Agent.Session` — the ONE process that owns an
  agent's authoritative `%EvoGit.Agent.State{}` and runs each exchange in a
  separate worker task.

  ## What is pinned here

  * the ONE-SHOT lifecycle: `:starting` → `:running` → `:done`, with exactly ONE
    terminal `{:agent_session_result, agent_id, session_pid, {:ok, %Result{}}}`
    delivered to `EvoGit.AgentScheduler` BEFORE the session stops `:normal`;
  * that the owner stays RESPONSIVE while an exchange is blocked in its LLM call
    (`inspect/2` + `history/2` answer mid-run);
  * both cancel actions: `:graceful` sets the scheduler cancel flag and enters
    `:cancelling` WITHOUT killing the worker (the save-work grace keeps running
    to its terminal result), while `:force` kills the worker and stops
    `:shutdown` with NO result delivery;
  * the crash path: a raising worker becomes an abnormal session exit (the crash
    reason is propagated, never swallowed) and delivers no result;
  * the `:evogit_agent_summary` read model: `Summary.publish/3` reports the run
    (`turn`, `message_count`, `status`) and writes NO conversation (the struct
    has no `context` field at all);
  * `RemoteAPI.get_agent_history/1` serving the session-owned
    `[%ReqLLM.Message{}]` conversation while a session runs, and `[]` for an
    unknown agent id or a session that is gone;
  * `input/2`'s P2 transport — the message lands on the scheduler pending-message
    queue, and every public read/command degrades to its documented fallback
    once the session is gone.

  ## Why `async: true` is safe

  `:evogit_agent_summary` is a BEAM-global ETS table, so every test uses a
  PER-TEST UNIQUE agent id (`9_930_000 + System.unique_integer([:positive])`),
  installs a PRODUCTION-SHAPED `%EvoGit.AgentScheduler.AgentState{}` row, and
  deletes exactly that row (plus its control-plane entries) in `on_exit`.
  Nothing here asserts on the table as a whole, wipes it, mutates an app-env key,
  the global `Logger` level, `:persistent_term` or the scheduler's configuration,
  so no other concurrently running module can observe these rows.
  No assertion is weakened for parallelism: every wait is event-driven (a traced
  terminal message, the blocked-LLM notification, the monitor `:DOWN`) and every
  budget only absorbs scheduling latency.

  ## The session is started DIRECTLY

  Each test builds its own repo-less `dispatch_ctx` and calls
  `EvoGit.Agent.Session.start_link/1`; no scheduler dispatch is involved, and no
  git repository or worktree exists (the repo-less branch of
  `Session.Setup.bind_worktree/2` never touches `WorktreeManager`).
  The session is UNLINKED from the test process right after the start (one case
  asserts an abnormal exit, which must not kill the test) and re-monitored so the
  exits are still observable; `on_exit` stops any session a failed assertion left
  running.

  ## Terminal observation

  The terminal fact is a MESSAGE to `EvoGit.AgentScheduler`, which
  log-and-ignores it, so the only non-invasive way to observe it is `:receive`
  tracing of that process' mailbox. `trace_scheduler/0` enables it for the test,
  `await_terminal/3,4` matches the ONE `{:agent_session_result, …}` addressed to
  this test's agent id (ignoring unrelated trace lines from concurrently running
  modules), `refute_terminal/4` is the bounded negative, and the trace is
  disabled as soon as the assertion completes.

  ## Seven pinned scenarios

  1. lifecycle terminal delivery — the one-shot `:starting` → `:running` →
     `:done` run with exactly ONE `{:agent_session_result, …}`, delivered
     before the `:normal` stop;
  2. responsiveness while the worker blocks — `inspect/2` + `history/2` answer
     while the exchange is parked in its LLM call;
  3. graceful cancel — the scheduler cancel flag is set and the session enters
     `:cancelling` WITHOUT killing the worker, so the save-work grace runs to
     its terminal result;
  4. force cancel — the worker is killed and the session stops `:shutdown`
     with NO result delivered;
  5. abnormal exit on a crashing worker — the crash reason propagates and no
     result is delivered;
  6. the `:running` summary plus history — `Summary.publish/3` reports the run
     (`turn`, `message_count`, `status`) and writes no conversation (the summary
     struct has no `context` field), `history/2` returns the checkpointed
     messages, and `RemoteAPI.get_agent_history/1` serves that same list;
  7. `input/2` control-plane transport — the message lands on the scheduler's
     pending-message queue, and every public read/command degrades to its
     documented fallback once the session is gone.

  Engine seams reach the exchange only through the scheduler's
  `dispatch_ctx[:exchange_opts]` list, which is DEFAULT INERT: production never
  sets the key, so the tests add `:llm_call` (and its siblings) without a
  production-engine branch, and an absent key keeps the production path
  byte-identical.
  """

  use ExUnit.Case, async: true

  # The shared host's scheduling swings several-fold under parallel load, so
  # every awaited event in this module shares this ONE budget. It only absorbs
  # that latency: each helper returns as soon as it observes the event, so the
  # happy path never pays it, and an event that never arrives still FAILS.
  @await_budget_ms 30_000

  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  setup do
    # Uniqueness is what makes this module async-safe: the summary table is
    # app-global, so two concurrent modules must never share an agent id.
    agent_id = 9_930_000 + System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    # A REGISTRATION sentinel: `Summary.publish/3` merges only the summary
    # fields onto the existing row, so the registration-only values it does not
    # own (here the full objective) must survive every publication untouched.
    :ok = SchedStore.put_agent_state(agent_id, agent_state())
    # The registration `sched_meta` the session's completion path reads (the
    # spec's `phylo_node` supplies `base_commit`); production Dispatch writes it
    # before starting a session.
    :ok = SchedStore.put_sched_meta(agent_id, sched_meta(agent_id))

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{agent_id: agent_id, tmp_dir: tmp_dir}
  end

  describe "one-shot lifecycle" do
    test "a completed run stops :normal after delivering exactly ONE terminal result",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      scheduler = trace_scheduler()

      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: completed_llm_call()))

      # Delivered BEFORE the stop, so awaiting the result first can never race
      # the death of the process that sent it.
      assert {:ok, %EvoGit.Agent.Result{} = result} = await_terminal(scheduler, agent_id, pid)
      assert %{result: "session report"} = result
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # Exactly ONE: nothing may follow the single terminal fact.
      refute_terminal(scheduler, agent_id, pid, 300)
      stop_trace(scheduler)

      # The final summary merges `status: :done` onto the EXISTING row.
      assert %{status: :done} = Session.Summary.read(agent_id)
      assert Session.inspect(pid) == :error
    end

    test "inspect/2 and history/2 answer WHILE the exchange is blocked in its LLM call",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000

      # The owner never runs the exchange, so these calls answer while the
      # worker is still parked inside the LLM call.
      assert {:ok, %{phase: :running, state: %EvoGit.Agent.State{}}} = Session.inspect(pid, 500)

      messages = Session.history(pid, 500)
      assert is_list(messages)
      assert messages != []
      assert length(messages) >= 2
      assert hd(Enum.map(messages, & &1.role)) == :system

      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "a graceful cancel enters :cancelling, keeps the worker alive and still reports",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      scheduler = trace_scheduler()

      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000

      assert :ok = Session.cancel(pid, :graceful)

      # The flag the engine's turn top reads is set synchronously, before the
      # cancel call returns.
      assert SchedStore.cancel_requested?(agent_id) == true
      assert await_phase(pid, :cancelling) == true

      # The worker was NOT killed: releasing it lets the save-work grace run to
      # its ONE terminal result.
      send(worker, :release)
      assert {:ok, %EvoGit.Agent.Result{}} = await_terminal(scheduler, agent_id, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      refute_terminal(scheduler, agent_id, pid, 300)
      stop_trace(scheduler)
    end

    test "a force cancel kills the worker and delivers NO result at all",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      scheduler = trace_scheduler()

      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, _worker}, 5_000

      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000

      refute_terminal(scheduler, agent_id, pid, 300)
      stop_trace(scheduler)

      assert Session.inspect(pid) == :error
      assert Session.history(pid) == []
    end

    test "a crashing worker makes the session exit with that crash reason and delivers nothing",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      scheduler = trace_scheduler()

      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: raising_llm_call()))

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000

      # The crash is PROPAGATED (the scheduler's crash/retry path needs it),
      # never converted into a clean stop.
      refute reason == :normal

      refute_terminal(scheduler, agent_id, pid, 300)
      stop_trace(scheduler)
    end

    test "the summary row reports the running turn and carries no conversation",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000

      row = Session.Summary.read(agent_id)
      assert %EvoGit.AgentScheduler.AgentState{} = row
      # Turn 0: the initial state never passed through a turn boundary.
      assert row.turn == 0
      assert row.message_count >= 2
      assert row.status == :running

      # The row is a SUMMARY, so `publish/3` writes summary fields only: the
      # struct has NO conversation and NO cross-process control state at all —
      # those stay owned by the session (messages) and the control plane.
      refute Map.has_key?(row, :context)
      refute Map.has_key?(row, :pending_user_messages)
      refute Map.has_key?(row, :cancel_requested)
      refute Map.has_key?(row, :phylo_node)

      # …while a REGISTRATION-only value survives the merge untouched, proving
      # the merge is onto the existing row (not a fresh struct).
      assert row.objective == "registration objective sentinel"
      assert row.objective_preview == "session test objective"

      messages = Session.history(pid)
      assert length(messages) >= 2
      assert hd(Enum.map(messages, & &1.role)) == :system

      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "input/2 queues a message for the running engine and is refused once the run ended",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # A scheduler seam that never drains: while the worker is blocked in its
      # LLM call the engine cannot consume the injected message, so the queue can
      # be observed intact.
      seam = fn
        :drain_inputs, _payload, _state -> []
        :cancel_requested?, _payload, _state -> false
        _kind, _payload, _state -> :ok
      end

      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self()), scheduler: seam)
        )

      assert_receive {:llm_blocked, worker}, 5_000

      assert :ok = Session.input(pid, "hello")
      assert SchedStore.drain_pending_user_messages(agent_id) == ["hello"]

      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # A finished session is GONE, and every public function is total.
      assert Session.input(pid, "late") == {:error, :not_found}
      assert Session.inspect(pid) == :error
      assert Session.history(pid) == []
    end
  end

  # ---------------------------------------------------------------------------
  # `RemoteAPI.get_agent_history/1` — the RPC read of the SESSION-owned messages
  # ---------------------------------------------------------------------------

  describe "RemoteAPI.get_agent_history/1" do
    test "serves the session's %ReqLLM.Message{} conversation while it runs",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000

      # The summary row carries no conversation at all; the RPC resolves the
      # agent id to its live session and returns the session-owned messages.
      assert {:ok, %AgentState{} = row} = SchedStore.get_agent_state(agent_id)
      refute Map.has_key?(row, :context)

      messages = RemoteAPI.get_agent_history(agent_id)
      assert is_list(messages)
      assert length(messages) >= 2
      assert Enum.all?(messages, &match?(%ReqLLM.Message{}, &1))
      assert hd(Enum.map(messages, & &1.role)) == :system

      # Shape + content: the system prompt and the objective are both there, in
      # the order the engine built them, and the RPC is reading the LIVE state
      # (the same list `Session.history/2` serves).
      assert Enum.map(messages, & &1.role) == [:system, :user]
      assert text_of(hd(messages)) == "You are the session-test stub agent."
      assert Enum.at(messages, 1) |> text_of() =~ "session test objective"

      assert messages == Session.history(pid)

      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "returns [] for an unknown agent id and for a gone session",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # Never started: no registry entry at all.
      assert RemoteAPI.get_agent_history(9_999_999_999) == []

      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: completed_llm_call()))

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # The session is gone with its conversation: history is unrecoverable
      # post-completion (the archive stores the result, never the messages).
      assert RemoteAPI.get_agent_history(agent_id) == []
    end
  end

  describe "stop current interactive reply" do
    test "stops a blocked model, keeps the session, and resumes with the queued input intact",
         %{agent_id: id, tmp_dir: tmp} do
      parent = self()

      llm = fn context, _, _, _, _ ->
        send(parent, {:stop_test_llm, self(), context})

        receive do
          :finish_reply ->
            {:implicit_completion, response(context, "resumed answer"), "resumed answer"}
        end
      end

      ctx = dispatch_ctx(id, tmp, llm_call: llm) |> Keyword.put(:session_mode, :interactive)
      {:ok, pid, _} = start_session(ctx)
      assert_receive {:stop_test_llm, worker, _}, 5_000
      worker_ref = Process.monitor(worker)
      assert :ok = Session.stop_current_turn(pid)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000
      assert {:ok, %{phase: :awaiting_input}} = Session.inspect(pid)
      assert Process.alive?(pid)
      assert :ok = Session.stop_current_turn(pid)
      assert :ok = Session.start_input(pid, "second question")
      assert_receive {:stop_test_llm, worker2, context}, 5_000
      assert transcript_text(context.messages) =~ "second question"

      assert transcript_text(context.messages) =~
               "Tool operations already executed remain in effect"

      send(worker2, :finish_reply)
      assert {:ok, %{phase: :awaiting_input}} = wait_phase(pid, :awaiting_input)
      assert transcript_text(Session.history(pid)) =~ "resumed answer"
      # A late outcome from the killed worker cannot close this conversation.
      send(pid, {:exchange_finished, worker, {:error, :stale}})
      assert {:ok, %{phase: :awaiting_input}} = Session.inspect(pid)
    end

    test "settles an executing tool and preserves its result before stopping",
         %{agent_id: id, tmp_dir: tmp} do
      parent = self()

      llm = fn context, _, _, _, _ ->
        call = ReqLLM.ToolCall.new("stop-tool", "read", %{file_path: "unused"})
        message = %ReqLLM.Message{role: :assistant, content: [], tool_calls: [call]}

        {:ok,
         %{
           response(context, "")
           | message: message,
             context: ReqLLM.Context.append(context, message)
         }}
      end

      batch = fn [{_call, 0}], _state ->
        send(parent, {:stop_test_tool, self()})

        receive do
          :settle_tool -> :ok
        end

        send(parent, :tool_effect_completed)
        [{0, "stop-tool", "read", "real settled tool result"}]
      end

      ctx =
        dispatch_ctx(id, tmp, llm_call: llm, tool_batch: batch)
        |> Keyword.put(:session_mode, :interactive)

      {:ok, pid, _} = start_session(ctx)
      assert_receive {:stop_test_tool, worker}, 5_000
      assert :ok = Session.stop_current_turn(pid)
      assert Process.alive?(worker)
      assert {:ok, %{phase: :running}} = Session.inspect(pid)
      send(worker, :settle_tool)
      assert_receive :tool_effect_completed, 5_000
      assert {:ok, %{phase: :awaiting_input}} = wait_phase(pid, :awaiting_input)
      assert transcript_text(Session.history(pid)) =~ "real settled tool result"
      assert Process.alive?(pid)
    end

    test "does not turn a one-shot cancellation into an idle session",
         %{agent_id: id, tmp_dir: tmp} do
      {:ok, pid, _} = start_session(dispatch_ctx(id, tmp, llm_call: blocking_llm_call(self())))
      assert_receive {:llm_blocked, _}, 5_000
      assert {:error, {:bad_state, :running}} = Session.stop_current_turn(pid)
      assert {:ok, %{phase: :running}} = Session.inspect(pid)
    end
  end

  test "workspace updates are idle-only and replace trusted metadata without reading project files",
       %{agent_id: id, tmp_dir: tmp} do
    File.write!(Path.join(tmp, "CONTEXT.md"), "DO_NOT_READ_SELECTED_PROJECT")

    ctx =
      dispatch_ctx(id, tmp, llm_call: blocking_llm_call(self()))
      |> Keyword.put(:session_mode, :interactive)

    spec = %{
      ctx[:spec]
      | agent_module: EvoGit.Agents.SelfReflective,
        opts: Keyword.put(ctx[:spec].opts, :assistant_conversation_id, "original-conversation")
    }

    ctx = Keyword.put(ctx, :spec, spec)
    {:ok, meta} = SchedStore.get_sched_meta(id)
    SchedStore.put_sched_meta(id, %{meta | spec: spec})
    {:ok, pid, _} = start_session(ctx)
    assert_receive {:llm_blocked, _}, 5000
    workspace = %{path: tmp, node: node(), name: "selected"}
    assert {:error, {:bad_state, :running}} = Session.update_assistant_workspace(pid, workspace)
    assert :ok = Session.stop_current_turn(pid)
    assert :ok = Session.update_assistant_workspace(pid, workspace)
    {:ok, updated} = SchedStore.get_sched_meta(id)
    assert updated.spec.opts[:assistant_workspace] == workspace
    assert updated.spec.opts[:assistant_conversation_id] == "original-conversation"
    assert transcript_text(Session.history(pid)) =~ tmp
    refute transcript_text(Session.history(pid)) =~ "DO_NOT_READ_SELECTED_PROJECT"

    assert {:error, :invalid_workspace} =
             Session.update_assistant_workspace(pid, %{path: "relative"})

    assert :ok = Session.update_assistant_workspace(pid, nil)
    {:ok, cleared} = SchedStore.get_sched_meta(id)
    assert cleared.spec.opts[:assistant_workspace] == nil
    notice = List.last(Session.history(pid))
    assert notice.metadata.user_authored == false
    assert transcript_text([notice]) =~ "Authoritative selected project: none"
  end

  test "concurrent project sends cannot queue a message against another tab's selected project",
       %{agent_id: id, tmp_dir: tmp} do
    other = Path.join(tmp, "other-project")
    File.mkdir_p!(other)

    ctx =
      dispatch_ctx(id, tmp, llm_call: blocking_llm_call(self()))
      |> Keyword.put(:session_mode, :interactive)

    spec = %{ctx[:spec] | agent_module: EvoGit.Agents.SelfReflective}
    ctx = Keyword.put(ctx, :spec, spec)
    {:ok, meta} = SchedStore.get_sched_meta(id)
    SchedStore.put_sched_meta(id, %{meta | spec: spec})
    {:ok, pid, _} = start_session(ctx)
    assert_receive {:llm_blocked, _}, 5000
    assert :ok = Session.stop_current_turn(pid)

    selections = [
      {"tab one request", %{path: tmp, node: node()}},
      {"tab two request", %{path: other, node: node()}}
    ]

    results =
      selections
      |> Enum.map(fn {message, workspace} ->
        Task.async(fn ->
          {message, workspace,
           Session.send_message_with_workspace(pid, message, :queue, workspace)}
        end)
      end)
      |> Task.await_many()

    assert [{accepted, selected, :ok}] = Enum.filter(results, &(elem(&1, 2) == :ok))

    assert [{rejected, _, {:error, :workspace_changed}}] =
             Enum.reject(results, &(elem(&1, 2) == :ok))

    assert_receive {:llm_blocked, _}, 5000
    {:ok, saved} = SchedStore.get_sched_meta(id)
    assert saved.spec.opts[:assistant_workspace] == selected
    history = transcript_text(Session.history(pid))
    assert history =~ accepted
    refute history =~ rejected
    # The same authoritative selection can still queue normal follow-up messages.
    assert :ok =
             Session.send_message_with_workspace(
               pid,
               %{text: "same project follow-up", attachments: []},
               :queue,
               selected
             )
  end

  test "first assistant media reaches the model in both session modes",
       %{agent_id: id, tmp_dir: tmp} do
    parent = self()
    raw = <<137, 80, 78, 71, 0, 255>>

    attachments = [
      %{
        "type" => "image",
        "name" => "only.png",
        "media_type" => "image/png",
        "data" => Base.encode64(raw)
      }
    ]

    for mode <- [:oneshot, :interactive] do
      blocking = blocking_llm_call(parent)

      llm = fn context, tools, params, agent, retries ->
        send(parent, {:model_media, context.messages})
        blocking.(context, tools, params, agent, retries)
      end

      ctx = dispatch_ctx(id, tmp, llm_call: llm) |> Keyword.put(:session_mode, mode)

      spec = %{
        ctx[:spec]
        | agent_module: EvoGit.Agents.SelfReflective,
          objective: "",
          opts: Keyword.put(ctx[:spec].opts, :attachments, attachments)
      }

      {:ok, pid, ref} = start_session(Keyword.put(ctx, :spec, spec))
      assert_receive {:model_media, messages}, 5000
      assert Enum.any?(List.last(messages).content, &(Map.get(&1, :data) == raw))
      assert_receive {:llm_blocked, _}, 5000
      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5000
    end
  end

  test "assistant context and skills stay isolated in both session modes",
       %{agent_id: id, tmp_dir: tmp} do
    File.write!(
      Path.join(tmp, "CONTEXT.md"),
      "---\nskill:\n  - leaky\n---\nLEAKED_SOURCE_CONTEXT"
    )

    File.mkdir_p!(Path.join(tmp, ".agents/skills"))

    File.write!(
      Path.join(tmp, ".agents/skills/leaky.md"),
      "---\nname: leaky\ndescription: LEAKED_PROJECT_SKILL\n---\nLEAKED_PROJECT_SKILL"
    )

    assert [%{name: "leaky"}] = EvoGit.Skills.load_skills(tmp)
    assert EvoGit.Skills.hierarchical_skill_names("./", tmp) == ["leaky"]

    for mode <- [:oneshot, :interactive] do
      # Only one session owns an id at a time; force-stop before the next mode.
      ctx = dispatch_ctx(id, tmp, llm_call: blocking_llm_call(self()))
      spec = %{ctx[:spec] | agent_module: EvoGit.Agents.SelfReflective}
      ctx = ctx |> Keyword.put(:spec, spec) |> Keyword.put(:session_mode, mode)
      {:ok, pid, ref} = start_session(ctx)
      assert_receive {:llm_blocked, _}, 5_000
      assert {:ok, %{state: state}} = Session.inspect(pid)
      refute transcript_text(state.context.messages) =~ "LEAKED_SOURCE_CONTEXT"
      refute inspect(state.skill_schemas) =~ "leaky"
      assert state.skill_schemas == []
      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000
    end
  end

  defp transcript_text(messages) do
    Enum.map_join(messages, "\n", fn message ->
      Enum.map_join(message.content, "", fn part -> Map.get(part, :text) || "" end)
    end)
  end

  # Bounded poll of a phase the exchange worker produces (a yield re-parks the
  # session in `:awaiting_input`); the budget only absorbs scheduling latency,
  # and a phase that never arrives still fails the caller's own assertion.
  defp wait_phase(pid, target, timeout \\ @await_budget_ms) do
    wait_phase_until(pid, target, deadline(timeout))
  end

  defp wait_phase_until(pid, target, deadline) do
    case Session.inspect(pid) do
      {:ok, %{phase: ^target}} = result ->
        result

      _ ->
        if remaining(deadline) > 0 do
          Process.sleep(10)
          wait_phase_until(pid, target, deadline)
        else
          Session.inspect(pid)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch context / session lifecycle
  # ---------------------------------------------------------------------------

  defp dispatch_ctx(agent_id, tmp_dir, exchange_opts) do
    spec = %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      agent_module: EvoGit.Agent.SessionTest.StubAgent,
      objective: "session test objective",
      opts: [repo_less: true, task_tmpdir: tmp_dir]
    }

    meta = %EvoGit.AgentScheduler.SchedMeta{
      id: agent_id,
      depth: 0,
      spec: spec,
      task_id: "task-#{agent_id}"
    }

    [
      agent_id: agent_id,
      depth: 0,
      repo_root: tmp_dir,
      repo_id: "primary",
      worktree_path: Path.join(tmp_dir, "worker"),
      retries: 0,
      spec: spec,
      meta: meta,
      repo_less: true,
      repo_less_repo_path: tmp_dir,
      exchange_opts: exchange_opts
    ]
  end

  # The pre-installed scheduler SUMMARY row the session reads its
  # identity/model fields from. A missing row makes the session finalize with
  # `{:error, :not_registered}`. `objective` is a registration-only sentinel the
  # summary publication must never overwrite.
  defp agent_state do
    %EvoGit.AgentScheduler.AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      objective: "registration objective sentinel",
      parent_id: nil,
      archive: false,
      llm_model: nil,
      model_id: "session-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: nil,
      repo_id: "primary",
      llm_context_window: 200_000
    }
  end

  # The registration metadata the completion path reads for the agent's spec
  # (`phylo_node` = nil is the repo-less shape; `repo_less` short-circuits the
  # derived `base_commit` to nil). `from` is a REAL `GenServer.from/0` shape
  # whose reply lands in the test process: these sessions are started DIRECTLY
  # (no scheduler dispatch), so the scheduler's top-level reply path has no
  # caller to answer — and it must never be answered with `nil`.
  defp sched_meta(agent_id) do
    %EvoGit.AgentScheduler.SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: "task-#{agent_id}",
      from: {self(), make_ref()},
      spec: %EvoGit.AgentSpec{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        phylo_node: nil,
        agent_module: EvoGit.Agent.SessionTest.StubAgent,
        objective: "session test objective",
        opts: [repo_less: true]
      }
    }
  end

  defp start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)

    # One case asserts an ABNORMAL exit, so the link must go away before the
    # test can observe it; the monitor keeps the exit observable.
    Process.unlink(pid)
    ref = Process.monitor(pid)

    # A failed assertion must not leave a live session (and its worker) behind.
    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, pid, ref}
  end

  # ---------------------------------------------------------------------------
  # Scripted LLM seams (passed through `dispatch_ctx[:exchange_opts]`)
  # ---------------------------------------------------------------------------

  defp completed_llm_call do
    fn context, _tools, _params, _agent_id, _retries ->
      {:implicit_completion, response(context, "session report"), "session report"}
    end
  end

  # Blocks until the test releases THIS worker. Later calls (a grace turn, a
  # retry) return immediately, so a released run always terminates promptly.
  defp blocking_llm_call(test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      unless Process.get(:session_test_released) do
        send(test_pid, {:llm_blocked, self()})

        receive do
          :release -> Process.put(:session_test_released, true)
        after
          5_000 -> Process.put(:session_test_released, true)
        end
      end

      {:implicit_completion, response(context, "session report"), "session report"}
    end
  end

  defp raising_llm_call do
    fn _context, _tools, _params, _agent_id, _retries -> raise "boom" end
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "session-test-response",
      model: "test:model",
      # The engine advances the conversation from the response's own context.
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  # ---------------------------------------------------------------------------
  # Terminal observation (`:receive` tracing of the scheduler's mailbox)
  # ---------------------------------------------------------------------------

  defp trace_scheduler do
    scheduler = Process.whereis(EvoGit.AgentScheduler)
    assert is_pid(scheduler)

    # The terminal fact is a MESSAGE to the scheduler (which log-and-ignores it),
    # so tracing the scheduler's receive events is the one non-invasive way to
    # observe it — no production hook, no app-env seam.
    :erlang.trace(scheduler, true, [:receive])
    on_exit(fn -> :erlang.trace(scheduler, false, [:receive]) end)

    scheduler
  end

  defp stop_trace(scheduler), do: :erlang.trace(scheduler, false, [:receive])

  defp await_terminal(scheduler, agent_id, session_pid, timeout \\ @await_budget_ms) do
    do_await_terminal(scheduler, agent_id, session_pid, deadline(timeout))
  end

  defp do_await_terminal(scheduler, agent_id, session_pid, deadline) do
    receive do
      {:trace, ^scheduler, :receive, {:agent_session_result, ^agent_id, ^session_pid, result}} ->
        result

      # Another module's traffic (and the scheduler's own timers) is traced too:
      # ignore every unrelated line rather than treating it as a failure.
      {:trace, ^scheduler, :receive, _unrelated} ->
        do_await_terminal(scheduler, agent_id, session_pid, deadline)
    after
      remaining(deadline) ->
        flunk(
          "expected ONE {:agent_session_result, #{inspect(agent_id)}, #{inspect(session_pid)}, _} " <>
            "before the deadline; the session delivered nothing"
        )
    end
  end

  defp refute_terminal(scheduler, agent_id, session_pid, timeout) do
    do_refute_terminal(scheduler, agent_id, session_pid, deadline(timeout))
  end

  defp do_refute_terminal(scheduler, agent_id, session_pid, deadline) do
    receive do
      {:trace, ^scheduler, :receive, {:agent_session_result, ^agent_id, ^session_pid, result}} ->
        flunk("expected NO terminal result for #{inspect(agent_id)}, got #{inspect(result)}")

      {:trace, ^scheduler, :receive, _unrelated} ->
        do_refute_terminal(scheduler, agent_id, session_pid, deadline)
    after
      remaining(deadline) -> :ok
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Bounded poll (never a fixed sleep as the assertion): the phase transition is
  # synchronous with the cancel reply, the poll only absorbs scheduling latency.
  defp await_phase(pid, phase, timeout \\ @await_budget_ms) do
    do_await_phase(pid, phase, deadline(timeout))
  end

  defp do_await_phase(pid, phase, deadline) do
    case Session.inspect(pid, 200) do
      {:ok, %{phase: ^phase}} ->
        true

      _other ->
        if remaining(deadline) > 0 do
          Process.sleep(10)
          do_await_phase(pid, phase, deadline)
        else
          false
        end
    end
  end

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
