defmodule EvoGit.Agent.Session.PersistenceSessionTest.StubAgent do
  @moduledoc """
  The one-shot stub role a persistence-session run executes AS.

  A session needs a real `EvoGit.Agent` implementation because
  `EvoGit.Agent.Session.Setup.build_initial_state/3` calls the role's
  `system_prompt/0`, `available_tools/0` and `delegation_level/0`. The tool list
  is deliberately EMPTY: every exchange here is driven end-to-end by the
  `:llm_call` engine seam (a reply with no tool calls finishes a one-shot run),
  so no tool schema is ever dispatched.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the one-shot stub role."
  def system_prompt, do: "You are the persistence-session stub agent."

  @doc "No tools: the scripted model never asks for one."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.PersistenceSessionTest.InteractiveAgent do
  @moduledoc """
  The interactive stub role: `session_mode/0` returns `:interactive`, so an
  engine `{:implicit_completion, response, text}` turn becomes the engine's
  `{:yield, state, text}` outcome instead of a terminal completion, and the
  session parks in `:awaiting_input` — the state that must NOT be marked
  completed in the durable store.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the interactive stub role."
  def system_prompt, do: "You are the persistence-session interactive stub agent."

  @doc "No tools: the scripted model never asks for one."
  def available_tools, do: []

  @doc "The opt-in: this role can be parked and resumed across exchanges."
  def session_mode, do: :interactive
end

defmodule EvoGit.Agent.Session.PersistenceSessionTest do
  @moduledoc """
  SESSION-LEVEL wiring of the durable per-agent state layer
  (`EvoGit.Agent.Session.Persistence` → `EvoGit.AgentState`).

  The unit-level contracts of the persistence module and of the store are
  covered elsewhere; this file pins only what a REAL `EvoGit.Agent.Session`
  process does with them:

  1. a completed one-shot run is CHECKPOINTED (full transcript + scalar fields)
     and then marked completed by the ONE terminal delivery;
  2. an INTERACTIVE session parked in `:awaiting_input` has a checkpoint but is
     NOT completed (it is still resumable);
  3. a FORCE-KILLED session is never marked completed;
  4. `persistent_state: false` writes nothing at all — the opt-out is enforced
     end to end, not only inside the unit;
  5. a reported continuity gap (`{:agent_state_resync, task_id, agent_id}`) is
     answered with a FULL rewrite of the session's own transcript, while a
     resync naming a different identity is ignored.

  ## Why `async: true` is safe — the store isolation argument

  `EvoGit.AgentState.server/0` resolves the process-dictionary key
  `:evogit_agent_state_server` in the CALLING process, and a process dictionary
  does not cross a process boundary — so a real session process ALWAYS resolves
  the app-booted NAMED server (`EvoGit.AgentState.Server`). That is the only
  route a genuine session has, and it is safe because the database is not
  shared across runs: `config/test.exs` pins `:evo_git, :data_dir` to a UNIQUE
  per-run directory, so the app-booted `agent_state.sqlite` is per-run scratch
  space.

  Within that database each test owns a PER-TEST UNIQUE task id
  (`"persist-session-<n>"`) and agent id (`9_940_000 + unique_integer`): nothing
  here lists the table wholesale, asserts on its size, or touches another run's
  row, and `on_exit` deletes exactly this test's row through the facade. The
  test process PINS the server pid it resolved at setup, so `flush/0` and
  `load/3` provably read the same server the session wrote to.

  The only other shared state is the app-global `:evogit_agent_summary` ETS
  table, handled the same way any session suite handles it: production-shaped
  rows under per-test unique ids, never a table-wide read, and each test deletes
  its own row. No app-env key, `Logger` level, `:persistent_term` entry or
  app-global store is mutated here.

  ## Event-driven waits only

  Every wait is anchored on a persistent fact: the terminal
  `{:agent_session_result, …}` (this context carries `scheduler: self()`, so the
  session delivers it to the test instead of the app-global scheduler), the
  worker's `{:llm_blocked, pid}` notice, the monitor `:DOWN`, or a bounded poll
  of `EvoGit.AgentState.load/3`. `Process.sleep/1` appears only as the interval
  INSIDE those bounded polls, never as an assertion.

  Session API calls (`inspect/2`, `history/2`) are bounded RETRIES, never a
  single tight call: a late answer on a saturated host is a VM-scheduling
  measurement, not a session fact, so a fixed short timeout would fail this file
  on a healthy, idle session while proving nothing about the code under test.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.Persistence
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.AgentScheduler.AgentState, as: SchedulerRow
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  @agent_id_base 9_940_000
  @objective "persist session objective"
  @report "session persist report"

  setup do
    # Per-test unique identity: the durable DB is per-run scratch, but ids are
    # what keep concurrently running modules from ever touching each other's row.
    agent_id = @agent_id_base + System.unique_integer([:positive])
    task_id = "persist-session-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_persist_session_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    # A session process can only reach the NAMED server, so pin THAT pid here and
    # make every read-backed assertion go through it.
    server = Process.whereis(EvoGit.AgentState.Server)
    assert is_pid(server)
    Process.put(:evogit_agent_state_server, server)

    # The registration rows the session reads its identity/model fields from and
    # the completion path reads its spec from (production Dispatch writes both
    # before starting a session).
    :ok = SchedStore.put_agent_state(agent_id, scheduler_row())
    :ok = SchedStore.put_sched_meta(agent_id, sched_meta(agent_id, task_id))

    on_exit(fn ->
      # `on_exit` runs in a DIFFERENT process, so it passes the server explicitly
      # instead of relying on the pinned process dictionary.
      AgentState.delete(task_id, agent_id, store: server)
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{agent_id: agent_id, task_id: task_id, tmp_dir: tmp_dir, server: server}
  end

  describe "the ONE terminal delivery marks the durable run" do
    test "a completed one-shot run is persisted AND marked completed",
         %{agent_id: agent_id, task_id: task_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, task_id, tmp_dir, llm_call: completed_llm_call()))

      # One-shot: a tool-free reply finishes the run, and the terminal fact is
      # delivered BEFORE the `:normal` stop (signal ordering), so awaiting the
      # result can never race the death of the process that sent it.
      assert_receive {:agent_session_result, ^agent_id, ^pid, {:ok, %Result{}}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # The writer is a cast-based serialized writer: flush is the
      # read-your-writes barrier before reading back.
      AgentState.flush()

      assert {:ok, %Record{} = record} = AgentState.load(task_id, agent_id)

      # The turn-1 checkpoint is the run's FIRST (no baseline), so it is ONE
      # full rewrite: system + first user + the assistant reply.
      assert record.message_count == 3
      assert record.chunk_count == 1
      assert Enum.map(record.messages, & &1.role) == [:system, :user, :assistant]
      assert text_of(List.last(record.messages)) == @report

      # The scalar projection the session supplied, and the completed marking
      # written ONLY by the terminal path.
      assert record.fields[:turn] == 1
      assert record.fields[:objective] == @objective
      assert record.fields[:repo_id] == "primary"
      assert record.fields[:repo_less] == true
      assert record.agent_id == agent_id
      assert record.fields[:status] == "done"
      assert %DateTime{} = record.completed_at
    end

    test "an INTERACTIVE session parked in :awaiting_input is NOT completed",
         %{agent_id: agent_id, task_id: task_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(agent_id, task_id, tmp_dir,
            agent_module: EvoGit.Agent.Session.PersistenceSessionTest.InteractiveAgent,
            llm_call: yielding_llm_call()
          )
        )

      # A yield parks the session: no terminal fact, an :awaiting_input phase.
      assert await_phase(pid, :awaiting_input) == true
      assert_phase(pid, :awaiting_input, "yield")

      AgentState.flush()
      assert {:ok, %Record{} = record} = AgentState.load(task_id, agent_id)

      # A checkpoint DID happen (the yield's turn boundary), so the row exists
      # with the conversation — but nothing marked it completed: the session is
      # still resumable.
      assert record.message_count > 0
      # `agent_states.status` is `TEXT NOT NULL DEFAULT 'running'`
      # (`priv/agent_state_repo/migrations/000001_create_agent_state.exs`), so a
      # checkpointed-but-never-marked row reads back as `"running"` — NOT nil.
      # The completed marking is the only writer of this column, and
      # `completed_at` is its companion, so "not completed" is pinned by both.
      assert record.fields[:status] == "running"
      assert record.completed_at == nil

      # Cleanup: a force kill never reaches the terminal path either.
      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000
    end

    test "a resumed input is durable before the next LLM finishes", ctx do
      parent = self()

      llm = fn context, _tools, _params, _id, _retries ->
        if Enum.any?(context.messages, &(text_of(&1) =~ "second durable input")) do
          send(parent, {:second_llm_blocked, self()})

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end

        {:implicit_completion, response(context, "yield response"), "yield response"}
      end

      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(ctx.agent_id, ctx.task_id, ctx.tmp_dir,
            agent_module: EvoGit.Agent.Session.PersistenceSessionTest.InteractiveAgent,
            llm_call: llm
          )
        )

      assert await_phase(pid, :awaiting_input)
      assert :ok = Session.input(pid, "second durable input")
      assert_receive {:second_llm_blocked, worker}, 5000

      {:ok, record} =
        await_record(ctx.task_id, ctx.agent_id, fn record ->
          Enum.any?(record.messages, &(text_of(&1) =~ "second durable input"))
        end)

      assert record.chunk_count > 1
      send(worker, :release)
      assert await_phase(pid, :awaiting_input)
      AgentState.flush()
      {:ok, record} = AgentState.load(ctx.task_id, ctx.agent_id)
      assert Enum.map(record.messages, &text_of/1) == Enum.map(await_history(pid), &text_of/1)
      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5000
    end

    test "a force-killed session is never marked completed",
         %{agent_id: agent_id, task_id: task_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(agent_id, task_id, tmp_dir, llm_call: blocking_llm_call(self()))
        )

      assert_receive {:llm_blocked, _worker}, 5_000

      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000

      AgentState.flush()

      # This test pins the {:error, :not_found} shape: checkpoints start at a
      # TURN boundary, and the blocked first turn never reaches one, so a
      # force-killed session leaves no durable row at all — the strongest
      # possible statement that it was never marked completed. If a future
      # change starts checkpointing before the first reply, the alternative
      # (existing row with status != "completed" and completed_at == nil) is
      # still a pass of the same invariant; adjust this assertion then.
      assert AgentState.load(task_id, agent_id) == {:error, :not_found}
    end

    test "a persistent_state: false session writes NOTHING",
         %{agent_id: agent_id, task_id: task_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(agent_id, task_id, tmp_dir,
            llm_call: completed_llm_call(),
            persistent_state: false
          )
        )

      # The run itself is completely normal: it finishes and stops :normal.
      assert_receive {:agent_session_result, ^agent_id, ^pid, {:ok, %Result{}}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      AgentState.flush()

      # The opt-out is enforced END TO END: neither the per-turn checkpoint nor
      # the terminal completion marking may create a row.
      assert AgentState.load(task_id, agent_id) == {:error, :not_found}
    end
  end

  describe "continuity gap (resync)" do
    test "the session answers a gap with a FULL rewrite and ignores another identity",
         %{agent_id: agent_id, task_id: task_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(agent_id, task_id, tmp_dir, llm_call: blocking_llm_call(self()))
        )

      # The worker is parked inside its LLM call, so the session's OWN transcript
      # is still the freshly built [system, user] pair and no checkpoint of this
      # run has been written yet.
      assert_receive {:llm_blocked, worker}, 5_000
      own_messages = await_history(pid)
      assert length(own_messages) == 2

      # Seed a DIVERGENT transcript into the SAME row, from the test process
      # (which resolves the same pinned server the session uses).
      Persistence.checkpoint(
        divergent_state(agent_id, task_id),
        divergent_state(agent_id, task_id)
      )

      AgentState.flush()

      assert {:ok, %Record{} = seeded} = AgentState.load(task_id, agent_id)
      assert seeded.message_count == 5
      assert seeded.chunk_count == 1

      # A resync naming a DIFFERENT identity is ignored by the session's
      # own-task/own-agent guard: the divergent row must stay untouched.
      send(pid, {:agent_state_resync, task_id, 999_999})
      # A successful `inspect/2` reply is a call from THIS process, so signal
      # ordering guarantees the info message above has already been handled when
      # it arrives; the bounded retry only absorbs a busy VM (see
      # `assert_phase/3`) — it can never turn "the session handled the resync"
      # into an unchecked assumption.
      assert_phase(pid, :running, "ignored resync")

      AgentState.flush()
      assert {:ok, %Record{} = untouched} = AgentState.load(task_id, agent_id)
      assert untouched.message_count == 5
      assert untouched.chunk_count == 1

      # The real gap report is answered with ONE FULL rewrite of the session's own
      # transcript (never an append on top of the store's divergent copy).
      send(pid, {:agent_state_resync, task_id, agent_id})
      assert_phase(pid, :running, "real resync")

      assert {:ok, %Record{} = healed} =
               await_record(task_id, agent_id, fn record ->
                 record.message_count == 2 and record.chunk_count == 1
               end)

      # The rebuilt conversation IS the session's current transcript, byte for byte.
      assert healed.messages == own_messages
      assert healed.messages == await_history(pid)

      # Let the blocked turn finish so no worker outlives the test.
      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch context / session lifecycle
  # ---------------------------------------------------------------------------

  defp dispatch_ctx(agent_id, task_id, tmp_dir, opts) do
    agent_module =
      Keyword.get(opts, :agent_module, EvoGit.Agent.Session.PersistenceSessionTest.StubAgent)

    spec = %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      agent_module: agent_module,
      objective: @objective,
      opts: [repo_less: true, task_tmpdir: tmp_dir]
    }

    meta = %SchedMeta{
      id: agent_id,
      depth: 0,
      spec: spec,
      task_id: task_id,
      from: {self(), make_ref()}
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
      # The durable-state opt the session forwards onto its owned %State{}.
      persistent_state: Keyword.get(opts, :persistent_state, true),
      # Test-owned sinks: the terminal result/yield notices land in THIS process
      # instead of the app-global scheduler, which this direct start never uses.
      scheduler: self(),
      notify: self(),
      exchange_opts: [llm_call: Keyword.fetch!(opts, :llm_call)]
    ]
  end

  # The pre-installed scheduler SUMMARY row the session reads its identity/model
  # fields from. A missing row makes the session finalize with
  # `{:error, :not_registered}`.
  defp scheduler_row do
    %SchedulerRow{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      objective: "registration objective sentinel",
      parent_id: nil,
      archive: false,
      llm_model: nil,
      model_id: "persist-session-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: nil,
      repo_id: "primary",
      llm_context_window: 200_000
    }
  end

  # The registration metadata the session reads its `task_id` from (and the
  # completion path reads its spec from). `from` is a REAL `GenServer.from/0`
  # shape whose reply lands in the test process: these sessions start DIRECTLY,
  # so the scheduler's top-level reply path has no caller to answer.
  defp sched_meta(agent_id, task_id) do
    %SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: task_id,
      from: {self(), make_ref()},
      spec: %EvoGit.AgentSpec{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        phylo_node: nil,
        agent_module: EvoGit.Agent.Session.PersistenceSessionTest.StubAgent,
        objective: @objective,
        opts: [repo_less: true]
      }
    }
  end

  defp start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)

    # A force-killed session exits `:shutdown`, so the link must go away before
    # the test can observe it; the monitor keeps the exit observable.
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
      {:implicit_completion, response(context, @report), @report}
    end
  end

  # An interactive role turns the SAME scripted turn into the engine's
  # `{:yield, state, text}` outcome, which parks the session in `:awaiting_input`.
  defp yielding_llm_call do
    fn context, _tools, _params, _agent_id, _retries ->
      {:implicit_completion, response(context, "persist session yield"), "persist session yield"}
    end
  end

  # Blocks until the test releases THIS worker. Later calls (a grace turn, a
  # retry) return immediately, so a released run always terminates promptly.
  # `test_pid` is captured by the caller IN the test process (`self()`), because
  # the seam itself runs inside the exchange worker.
  #
  # The `after` clause is a SAFETY NET, never the test's timing: it must stay far
  # above every bounded wait in the file, because a turn that ends on its own
  # stops the session and would fail assertions that mean "still running on a
  # loaded VM".
  defp blocking_llm_call(test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      unless Process.get(:persistence_session_released) do
        send(test_pid, {:llm_blocked, self()})

        receive do
          :release -> Process.put(:persistence_session_released, true)
        after
          30_000 -> Process.put(:persistence_session_released, true)
        end
      end

      {:implicit_completion, response(context, @report), @report}
    end
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "persist-session-response",
      model: "test:model",
      # The engine advances the conversation from the response's own context.
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  # A hand-built durable entry with 5 DISTINCTIVE messages: what the store holds
  # after "someone else" diverged this run's row.
  defp divergent_state(agent_id, task_id) do
    messages =
      Enum.map(1..5, fn index ->
        %ReqLLM.Message{
          role: :user,
          content: [ReqLLM.Message.ContentPart.text("divergent message #{index}")],
          tool_calls: nil
        }
      end)

    %State{
      agent_id: agent_id,
      task_id: task_id,
      agent_module: EvoGit.Agent.Session.PersistenceSessionTest.StubAgent,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new(messages),
      persistent_state: true
    }
  end

  # ---------------------------------------------------------------------------
  # Bounded, event-driven waits
  # ---------------------------------------------------------------------------

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # The phase transition is synchronous with the yield/outcome handling; the poll
  # only absorbs scheduling latency.
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

  # The same phase assertion, but FAILING (with the last answer) instead of
  # returning a boolean.
  #
  # The retry is not a weakened assertion — it is the fix for a saturated host:
  # a single tight `inspect/2` call timeout is a VM-scheduling measurement, not a
  # session fact, and a healthy, idle session answers a queued `:inspect` call
  # late simply because it was not scheduled yet. Every attempt that DOES answer
  # keeps the barrier intact, because `send/2` from this process followed by this
  # call means the session handled everything sent before it.
  defp assert_phase(pid, phase, label, timeout \\ 5_000) do
    do_assert_phase(pid, phase, label, deadline(timeout))
  end

  defp do_assert_phase(pid, phase, label, deadline) do
    case Session.inspect(pid, 500) do
      {:ok, %{phase: ^phase}} ->
        :ok

      other ->
        if remaining(deadline) > 0 do
          Process.sleep(10)
          do_assert_phase(pid, phase, label, deadline)
        else
          flunk(
            "#{label}: the session never reported phase #{inspect(phase)} " <>
              "(last answer: #{inspect(other)}, alive?: #{Process.alive?(pid)})"
          )
        end
    end
  end

  # `history/2` answers `[]` for a gone session AND for a call that timed out, so
  # a bounded retry distinguishes "not scheduled yet" from "gone" instead of
  # failing on one tight call. The 5 s budget still lets a dead session fail the
  # caller's own assertion instead of hanging the test.
  defp await_history(pid, timeout \\ 5_000) do
    do_await_history(pid, deadline(timeout))
  end

  defp do_await_history(pid, deadline) do
    case Session.history(pid, 500) do
      [] ->
        if remaining(deadline) > 0 do
          Process.sleep(10)
          do_await_history(pid, deadline)
        else
          []
        end

      messages ->
        messages
    end
  end

  # Bounded poll of the durable row: the write is a cast handled by the
  # agent-state server, so this waits for the persisted FACT (flushing before each
  # read), never for a fixed duration.
  defp await_record(task_id, agent_id, predicate, timeout \\ 2_000) do
    do_await_record(task_id, agent_id, predicate, deadline(timeout))
  end

  defp do_await_record(task_id, agent_id, predicate, deadline) do
    AgentState.flush()

    case AgentState.load(task_id, agent_id) do
      {:ok, %Record{} = record} ->
        if predicate.(record),
          do: {:ok, record},
          else: retry_record(task_id, agent_id, predicate, deadline)

      _other ->
        retry_record(task_id, agent_id, predicate, deadline)
    end
  end

  defp retry_record(task_id, agent_id, predicate, deadline) do
    if remaining(deadline) > 0 do
      Process.sleep(10)
      do_await_record(task_id, agent_id, predicate, deadline)
    else
      flunk(
        "durable row for #{inspect(task_id)}/#{inspect(agent_id)} never reached the expected shape"
      )
    end
  end

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
