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
    (`turn`, `message_count`, `status`) and never writes `context`;
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

  ## KNOWN PRODUCTION DEFECT — the SUCCESS path cannot deliver today

  `EvoGit.Agent.Session.Worker.refresh/1`
  (`apps/evo_git/lib/evo_git/agent/session/worker.ex:85-87`) pipes the exchange
  outcome's third element into `EvoGit.Agent.Runner.refresh_commit_sha/1` and
  then calls `elem(1)` on the result:

      defp refresh({:finish, %State{} = state, result}) do
        {:finish, state, result |> Runner.refresh_commit_sha() |> elem(1)}
      end

  `EvoGit.Agent.Exchange.outcome/0` is `{:finish, State.t(), Result.t()}` — the
  third element is a BARE `%Result{}`, NOT an `{:ok, result}` tuple — and
  `refresh_commit_sha/1` returns that same shape for a repo-less run, so
  `elem/2` raises `ArgumentError` (`:erlang.element(2, %EvoGit.Agent.Result{…})`)
  on EVERY successful exchange. The worker task then dies, the session exits
  with that `:badarg` crash reason, and NO `{:agent_session_result, …}` is
  delivered at all.
  An `{:error, reason}` outcome IS delivered correctly, and the force-cancel and
  crash paths are unaffected, so exactly the five SUCCESS scenarios below fail
  (each for this one reason) while force-cancel and the crashing-worker case
  pass.
  The fix belongs to production (`refresh/1` must deliver the refreshed
  `%Result{}` itself — unwrap `{:ok, inner}` → `inner`, otherwise pass through);
  these assertions are deliberately NOT weakened or skipped, per this suite's
  policy ("a production defect is never hidden to make a suite green"), so they
  are the regression pin for that fix.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  setup do
    # Uniqueness is what makes this module async-safe: the summary table is
    # app-global, so two concurrent modules must never share an agent id.
    agent_id = 9_930_000 + System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    # A SENTINEL context: `Summary.publish/3` must NEVER write `context`, so a
    # row seeded with a context the run could not have produced proves the merge
    # is summary-only.
    sentinel_context = ReqLLM.Context.new([ReqLLM.Context.user("registration sentinel message")])
    :ok = SchedStore.put_agent_state(agent_id, agent_state(sentinel_context))

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{agent_id: agent_id, tmp_dir: tmp_dir, sentinel_context: sentinel_context}
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

    test "the summary row reports the running turn and keeps its registration-time context",
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

      # `publish/3` merges summary fields only: the sentinel context is intact,
      # i.e. the run's conversation was never copied into the row.
      assert %ReqLLM.Context{messages: sentinel_messages} = row.context
      assert Enum.map(sentinel_messages, &text_of/1) == ["registration sentinel message"]

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

  # The pre-installed scheduler row the session reads its identity/model fields
  # from. A missing row makes the session finalize with `{:error, :not_registered}`.
  defp agent_state(sentinel_context) do
    %EvoGit.AgentScheduler.AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      parent_id: nil,
      archive: false,
      llm_model: nil,
      model_id: "session-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: nil,
      repo_id: "primary",
      llm_context_window: 200_000,
      context: sentinel_context
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

  defp await_terminal(scheduler, agent_id, session_pid, timeout \\ 5_000) do
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
  defp await_phase(pid, phase, timeout \\ 2_000) do
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
