defmodule EvoGit.Agent.Session.InteractiveTest.InteractiveAgent do
  @moduledoc """
  The interactive stub role: `session_mode/0` returns `:interactive`, so an
  engine `{:implicit_completion, response, text}` turn becomes a `{:yield}`
  instead of a terminal completion, and the session parks in `:awaiting_input`.
  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring test files, so a helper defined after the
  test module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent
  @doc "The fixed system prompt of the interactive stub role."
  def system_prompt, do: "You are the interactive session stub agent."

  @doc "No tools: every exchange here is driven by the `:llm_call` seam."
  def available_tools, do: []

  @doc "The P3 opt-in: this role can be resumed across exchanges."
  def session_mode, do: :interactive
end

defmodule EvoGit.Agent.Session.InteractiveTest.OneshotAgent do
  @moduledoc """
  The negative-case role: the default `:oneshot` mode, used to pin that a
  non-interactive agent can never yield (the engine completes instead).
  """
  use EvoGit.Agent
  @doc "The fixed system prompt of the one-shot stub role."
  def system_prompt, do: "You are the one-shot session stub agent."

  @doc "No tools: every exchange here is driven by the `:llm_call` seam."
  def available_tools, do: []

  @doc "Explicit, though it is also the behaviour default."
  def session_mode, do: :oneshot
end

defmodule EvoGit.Agent.Session.InteractiveTest do
  @moduledoc """
  P3 invariant matrix for `EvoGit.Agent.Session` in INTERACTIVE mode
  (`docs/agent-runtime-refactor.md` D4/D8 + §4.7): one agent id, one cache
  identity and one worktree across every exchange, append-only context, an idle
  session holding no worker/timer/slot, and the exact terminal-delivery
  contract for `close/2`, graceful cancel and force kill.

  Every session here is started DIRECTLY (`Session.start_link/1`) against a
  repo-less `dispatch_ctx` and a scripted `:llm_call` engine seam, so no git
  repository or worktree exists and no scheduler dispatch is involved. An
  interactive agent's scripted turn yields (`{:implicit_completion, …}` →
  `{:yield, …}`), parking the session in `:awaiting_input`; `start_input/3`
  resumes the SAME session process for the next exchange.

  ## Labelled invariants

  * (a) one agent id / one cache key / one worktree / append-only context
  * (b) idle holds nothing (no worker, no timer, no parked slot)
  * (d) graceful cancel while idle → immediate terminal with a %Result{}
  * (e) force kill while idle → `:shutdown`, nothing delivered
  * (h) yield ≠ finish (no terminal fact, full history, `:awaiting_input`)

  Plus the pure unit contract of `Session.Input` and `Session.Outcome`.

  ## Why `async: true` is safe
  `:evogit_agent_summary` is a BEAM-global ETS table, so each test uses a
  PER-TEST UNIQUE agent id (`9_940_000 + System.unique_integer([:positive])`),
  installs one PRODUCTION-SHAPED row and deletes exactly that row (plus its
  control-plane entry and temp dir) in `on_exit`. Nothing asserts on the table
  as a whole, and no app-env key, Logger level or `:persistent_term` is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.{Input, Outcome}
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  @agent_id_base 9_940_000

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_interactive_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    :ok = SchedStore.put_agent_state(agent_id, agent_state(agent_id))
    :ok = SchedStore.put_sched_meta(agent_id, sched_meta(agent_id))

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{agent_id: agent_id, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # (h) yield ≠ finish
  # ---------------------------------------------------------------------------
  describe "(h) yield is NOT a finish" do
    test "a yielded exchange delivers no terminal fact and keeps the whole conversation",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: yielding_llm_call("first yield")))

      assert await_phase(pid, :awaiting_input) == true
      # The scheduler is told about the yield, never about a result.
      assert {:ok, %{phase: :awaiting_input, state: %State{}}} = Session.inspect(pid, 500)

      assert_receive {:agent_session_yield, ^agent_id, ^pid, "first yield"}, 2_000

      refute_terminal(agent_id, pid, 300)
      refute_closed(agent_id, pid, 300)

      # The FULL conversation is still there — a yield parks, it does not recycle.
      messages = Session.history(pid, 500)
      assert length(messages) == 3
      assert hd(messages).role == :system
      assert List.last(messages).role == :assistant

      # The read model reports the non-terminal interactive status.
      assert %{status: :awaiting_input} = Session.Summary.read(agent_id)
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # (b) idle holds nothing
  # ---------------------------------------------------------------------------
  describe "(b) an idle session holds nothing" do
    test "no exchange worker, an empty mailbox and no parked slot while :awaiting_input",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # The FIRST exchange blocks in its seam so the worker pid is observable;
      # releasing it yields, which is the idle state under test.
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000
      # Running: the owner MONITORS the worker (`async_nolink` monitors, it
      # never links), which is how the exchange Task is tracked.
      assert {:process, worker} in elem(Process.info(pid, :monitors), 1)

      send(worker, :release)
      assert await_phase(pid, :awaiting_input) == true

      # 1. No worker: the exchange task is DEAD and no longer linked.
      refute Process.alive?(worker)
      # ... and the owner no longer monitors that dead worker.
      refute {:process, worker} in elem(Process.info(pid, :monitors), 1)

      # 2. No timer: OTP exposes no per-process timer enumeration, so pin the
      # observable proxy — an empty mailbox and a session parked in receive.
      # The session is NOT woken by an idle timer (three samples over ~200 ms).
      for _ <- 1..3 do
        assert {:ok, %{phase: :awaiting_input}} = Session.inspect(pid, 500)
        assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
        Process.sleep(60)
      end

      # 3. No LLM slot parked: the fixture model is `nil` and the seam replaces
      # the slot-gated call entirely, so no pool may be WAITING (a parked agent
      # would show up as a waiter).
      status = EvoGit.AgentScheduler.get_llm_slot_status()
      assert is_map(status)
      refute Enum.any?(status, fn {_pool, %{waiting: waiting}} -> waiting > 0 end)
    end
  end

  # ---------------------------------------------------------------------------
  # (a) identity + append-only context across exchanges
  # ---------------------------------------------------------------------------
  describe "(a) one identity, append-only context" do
    test "3 exchanges keep the same pid/agent id/cache key and only APPEND messages",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: yielding_llm_call("yield one")))

      assert await_phase(pid, :awaiting_input) == true
      assert {:ok, first} = Session.inspect(pid, 500)
      first_messages = Session.history(pid, 500)

      # The cache identity is the ONE projected from the registration row's
      # provider options — non-nil and stable for the session's whole life.
      assert first.state.prompt_cache_key == "genesis-fixture-#{agent_id}"
      assert first.state.agent_id == agent_id
      assert first.state.repo_path == tmp_dir

      assert :ok = Session.start_input(pid, "second objective", :queue)
      assert await_yield(pid, "yield two") == true
      assert {:ok, second} = Session.inspect(pid, 500)
      second_messages = Session.history(pid, 500)

      assert :ok = Session.start_input(pid, "third objective", :queue)
      assert await_yield(pid, "yield three") == true
      assert {:ok, third} = Session.inspect(pid, 500)
      third_messages = Session.history(pid, 500)

      # ONE session process, ONE agent id, ONE cache key, ONE worktree.
      for {snapshot, phase} <- [{second, :awaiting_input}, {third, :awaiting_input}] do
        assert snapshot.phase == phase
        assert snapshot.state.agent_id == agent_id
        assert snapshot.state.prompt_cache_key == first.state.prompt_cache_key
        assert snapshot.state.repo_path == first.state.repo_path
        assert snapshot.state.llm_generation_params == first.state.llm_generation_params
      end

      # APPEND-ONLY: every earlier message survives BYTE-IDENTICALLY (struct
      # equality on `%ReqLLM.Message{}`), and the count only grows.
      assert prefix?(first_messages, second_messages)
      assert prefix?(second_messages, third_messages)
      assert length(first_messages) < length(second_messages)
      assert length(second_messages) < length(third_messages)

      # The first user message is NEVER rebuilt: exactly one system message and
      # exactly one objective message, unchanged after two resumes (no
      # `# Context Tree` regeneration, no second objective block).
      assert Enum.count(third_messages, &(&1.role == :system)) == 1
      assert Enum.at(third_messages, 0) == Enum.at(first_messages, 0)
      assert Enum.at(third_messages, 1) == Enum.at(first_messages, 1)
      assert text_of(Enum.at(third_messages, 1)) == text_of(Enum.at(first_messages, 1))
      assert text_of(Enum.at(third_messages, 1)) =~ "<objective>"
      refute text_of(Enum.at(third_messages, 1)) =~ "# Context Tree"
      assert Enum.count(third_messages, &(text_of(&1) =~ "<objective>")) == 1
    end

    test "a second session with a different registration row gets a DIFFERENT cache key",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      other_id = agent_id + 500_000
      other_dir = Path.join(tmp_dir, "other")
      File.mkdir_p!(other_dir)

      :ok =
        SchedStore.put_agent_state(other_id, agent_state(other_id, "genesis-other-#{other_id}"))

      :ok = SchedStore.put_sched_meta(other_id, sched_meta(other_id))

      on_exit(fn ->
        SchedStore.delete_agent_state(other_id)
        SchedStore.delete_sched_meta(other_id)
        SchedStore.clear_cancel_requested(other_id)
        File.rm_rf(other_dir)
      end)

      {:ok, pid_a, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: yielding_llm_call("a")))

      {:ok, pid_b, _ref} =
        start_session(dispatch_ctx(other_id, other_dir, llm_call: yielding_llm_call("b")))

      assert await_phase(pid_a, :awaiting_input) == true
      assert await_phase(pid_b, :awaiting_input) == true

      assert {:ok, snap_a} = Session.inspect(pid_a, 500)
      assert {:ok, snap_b} = Session.inspect(pid_b, 500)

      assert snap_a.state.prompt_cache_key == "genesis-fixture-#{agent_id}"
      assert snap_b.state.prompt_cache_key == "genesis-other-#{other_id}"
      refute snap_a.state.prompt_cache_key == snap_b.state.prompt_cache_key
    end
  end

  # ---------------------------------------------------------------------------
  # (d) graceful cancel while idle
  # ---------------------------------------------------------------------------
  describe "(d) graceful cancel while idle" do
    test "is immediate, delivers ONE result and keeps the transcript up to the cancel",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(agent_id, tmp_dir, llm_call: yielding_llm_call("last yielded"))
        )

      assert await_phase(pid, :awaiting_input) == true
      before_cancel = Session.history(pid, 500)
      assert length(before_cancel) == 3

      assert :ok = Session.cancel(pid, :graceful)

      assert {:ok, %Result{} = result} = await_terminal(agent_id, pid)
      # The idle cancel reclaims the LAST yielded text as the report — no new
      # exchange is run and no extra turn is paid.
      assert result.result == "last yielded"
      # The transcript taken just before the cancel was the one finalized.
      assert length(before_cancel) == 3
      assert List.last(before_cancel).role == :assistant
      assert text_of(List.last(before_cancel)) == "last yielded"

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      refute_terminal(agent_id, pid, 300)
      assert %{status: :done} = Session.Summary.read(agent_id)
    end
  end

  # ---------------------------------------------------------------------------
  # (e) force kill while idle
  # ---------------------------------------------------------------------------
  describe "(e) force kill while idle" do
    test "stops :shutdown and delivers NOTHING", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: yielding_llm_call("idle")))

      assert await_phase(pid, :awaiting_input) == true

      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000

      refute_terminal(agent_id, pid, 300)
      refute_closed(agent_id, pid, 300)
      assert Session.inspect(pid) == :error
    end
  end

  # ---------------------------------------------------------------------------
  # Pure unit contracts
  # ---------------------------------------------------------------------------
  describe "Session.Input.policy/1" do
    test "the phase matrix is exact" do
      assert Input.policy(:awaiting_input) == :resume
      assert Input.policy(:running) == :queue
      assert Input.policy(:cancelling) == {:error, :finished}
      assert Input.policy(:finalizing) == {:error, :finished}
      assert Input.policy(:done) == {:error, :finished}
      assert Input.policy(:starting) == {:error, {:bad_state, :starting}}
    end
  end

  describe "Session.Input.resume_state/1" do
    test "sets exchange_turn_base to the current turn and touches nothing else" do
      state = %State{
        agent_id: 42,
        agent_module: __MODULE__,
        depth: 0,
        node_path: "./",
        context: ReqLLM.Context.new([]),
        mode: :interactive,
        repo_path: "/tmp/worker",
        worktree: "/tmp/worker",
        prompt_cache_key: "genesis-x",
        turn: 7,
        exchange_turn_base: 0,
        phase: :awaiting_input,
        cancel: %{requested: true},
        in_grace_period: true,
        grace_turns_remaining: 2
      }

      resumed = Input.resume_state(state)

      assert resumed.exchange_turn_base == 7
      assert resumed.phase == :running
      assert resumed.cancel == nil
      assert resumed.in_grace_period == false
      assert resumed.grace_turns_remaining == 0
      # Identity / worktree / cache identity are untouched.
      assert resumed.agent_id == 42
      assert resumed.repo_path == "/tmp/worker"
      assert resumed.worktree == "/tmp/worker"
      assert resumed.prompt_cache_key == "genesis-x"
      assert resumed.context == state.context
      assert resumed.turn == 7
    end
  end

  describe "Session.Outcome.classify/3" do
    test "yield is idle only for a RUNNING INTERACTIVE session, finalizing while cancelling" do
      state = %State{
        agent_id: 1,
        agent_module: __MODULE__,
        depth: 0,
        node_path: "./",
        context: ReqLLM.Context.new([])
      }

      result = %Result{result: "done", commit_sha: nil}

      assert Outcome.classify(:running, :interactive, {:yield, state, "text"}) ==
               {:idle, state, "text"}

      # A one-shot agent must never yield: it is a loud protocol surprise.
      assert Outcome.classify(:running, :oneshot, {:yield, state, "text"}) ==
               {:unexpected, {:yield, state, "text"}}

      # Cancelling ALWAYS finalizes a yield with the last text.
      assert Outcome.classify(:cancelling, :interactive, {:yield, state, "text"}) ==
               {:finalize_yield, state, "text"}

      assert Outcome.classify(:cancelling, :oneshot, {:yield, state, "text"}) ==
               {:finalize_yield, state, "text"}

      # A non-binary yield text cannot be a report.
      assert Outcome.classify(:running, :interactive, {:yield, state, nil}) ==
               {:unexpected, {:yield, state, nil}}

      # Finish is accepted from running AND cancelling, for both modes.
      for phase <- [:running, :cancelling], mode <- [:interactive, :oneshot] do
        assert Outcome.classify(phase, mode, {:finish, state, result}) ==
                 {:finish, state, result}
      end

      # Errors are accepted from running AND cancelling.
      for phase <- [:running, :cancelling], mode <- [:interactive, :oneshot] do
        assert Outcome.classify(phase, mode, {:error, :boom}) == {:error, :boom}
      end

      # A yield from a phase that must never see one is loud in every mode.
      for phase <- [:awaiting_input, :finalizing, :starting, :done] do
        assert Outcome.classify(phase, :interactive, {:yield, state, "text"}) ==
                 {:unexpected, {:yield, state, "text"}}
      end

      for phase <- [:awaiting_input, :finalizing, :starting, :done] do
        assert Outcome.classify(phase, :interactive, {:finish, state, result}) ==
                 {:unexpected, {:finish, state, result}}
      end

      for phase <- [:awaiting_input, :finalizing, :starting, :done] do
        assert Outcome.classify(phase, :oneshot, {:error, :boom}) ==
                 {:unexpected, {:error, :boom}}
      end
    end
  end

  describe "Session.start_input/3 admission" do
    test "unknown agent id is :not_found" do
      assert Session.start_input(9_999_999_999, "hello", :queue) == {:error, :not_found}
    end

    test "a RUNNING session accepts input on the queue policy" do
      # Covered structurally by the phase matrix above; pinned here so the
      # public contract for `:running` cannot silently become :finished.
      assert Input.policy(:running) == :queue
    end

    test "a :cancelling session refuses input with :finished",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # A RUNNING session parked in its seam is put into :cancelling by a
      # graceful cancel (the worker stays alive for the grace budget).
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000
      assert :ok = Session.cancel(pid, :graceful)
      assert await_phase(pid, :cancelling) == true

      assert Session.start_input(pid, "too late", :queue) == {:error, :finished}
      assert Session.start_input(pid, "too late", :interrupt) == {:error, :finished}

      send(worker, :release)
      assert await_phase(pid, :done, 5_000) == true or not Process.alive?(pid)
    end

    test "a FINALIZING (or already gone) session refuses input",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: yielding_llm_call("bye")))

      assert await_phase(pid, :awaiting_input) == true
      assert :ok = Session.close(pid)

      # `:finalizing` answers `{:error, :finished}`; once the process is gone
      # the documented answer is `{:error, :not_found}`. Either is a refusal —
      # never `:ok`.
      assert Session.start_input(pid, "after close", :queue) in [
               {:error, :finished},
               {:error, :not_found}
             ]
    end
  end

  describe "one-shot negative case" do
    test "a :oneshot agent never parks in :awaiting_input — it finishes",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      ctx =
        dispatch_ctx(agent_id, tmp_dir,
          llm_call: yielding_llm_call("not a yield"),
          agent_module: EvoGit.Agent.Session.InteractiveTest.OneshotAgent
        )

      {:ok, pid, ref} = start_session(ctx)

      assert {:ok, %Result{}} = await_terminal(agent_id, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # A finished one-shot run DOES deliver the closed notice (exactly once),
      # unlike a yield, which delivers nothing.
      assert_receive {:agent_session_closed, ^agent_id, {:ok, %Result{}}}, 1_000
      refute_receive {:agent_session_closed, ^agent_id, _other}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------
  defp agent_state(agent_id, cache_key \\ nil) do
    key = cache_key || "genesis-fixture-#{agent_id}"

    %AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      objective: "registration objective sentinel",
      parent_id: nil,
      archive: false,
      llm_model: nil,
      model_id: "session-interactive-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: nil,
      repo_id: "primary",
      llm_context_window: 200_000,
      # The cache identity has no dedicated row field: `Session` PROJECTS it
      # from the account's provider options, exactly where registration puts it.
      llm_generation_params: [
        temperature: 0.2,
        provider_options: [prompt_cache_key: key]
      ]
    }
  end

  defp sched_meta(agent_id) do
    %EvoGit.AgentScheduler.SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: "task-#{agent_id}",
      from: {self(), make_ref()},
      spec: %EvoGit.AgentSpec{
        context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
        phylo_node: nil,
        agent_module: EvoGit.Agent.Session.InteractiveTest.InteractiveAgent,
        objective: "interactive session test objective",
        opts: [repo_less: true]
      }
    }
  end

  defp dispatch_ctx(agent_id, tmp_dir, exchange_opts) do
    agent_module =
      Keyword.get(
        exchange_opts,
        :agent_module,
        EvoGit.Agent.Session.InteractiveTest.InteractiveAgent
      )

    spec = %EvoGit.AgentSpec{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      agent_module: agent_module,
      objective: "interactive session test objective",
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
      notify: self(),
      # A TEST-OWNED scheduler sink: `send_scheduler/2` prefers it over the
      # app-global scheduler, which cannot handle a yield notice yet.
      scheduler: self(),
      exchange_opts: Keyword.delete(exchange_opts, :agent_module)
    ]
  end

  defp start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, pid, ref}
  end

  # Every scripted turn answers with the next text in the list and yields.
  defp yielding_llm_call(first) do
    texts = [first, "yield two", "yield three"]

    fn context, _tools, _params, _agent_id, _retries ->
      index = Process.get(:interactive_test_turn, 0) |> min(length(texts) - 1)
      Process.put(:interactive_test_turn, index + 1)
      text = Enum.at(texts, index)
      {:implicit_completion, response(context, text), text}
    end
  end

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

      {:implicit_completion, response(context, "released yield"), "released yield"}
    end
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "session-interactive-test-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  # ---------------------------------------------------------------------------
  # Observation helpers — every session message (yield, resumed, result,
  # closed) lands in THIS process' mailbox via the test-owned scheduler sink.
  # ---------------------------------------------------------------------------
  defp await_terminal(agent_id, session_pid, timeout \\ 5_000) do
    assert_receive {:agent_session_result, ^agent_id, ^session_pid, result}, timeout
    result
  end

  defp refute_terminal(agent_id, session_pid, timeout) do
    refute_receive {:agent_session_result, ^agent_id, ^session_pid, result},
                   timeout,
                   "expected NO terminal result, got #{inspect(result)}"
  end

  defp refute_closed(agent_id, _session_pid, timeout) do
    refute_receive {:agent_session_closed, ^agent_id, result},
                   timeout,
                   "expected NO {:agent_session_closed, ...}, got #{inspect(result)}"
  end

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

  defp await_yield(pid, text, timeout \\ 2_000) do
    do_await_yield(pid, text, deadline(timeout))
  end

  defp do_await_yield(pid, text, deadline) do
    receive do
      {:agent_session_yield, _agent_id, ^pid, ^text} ->
        true

      _other ->
        if remaining(deadline) > 0 do
          do_await_yield(pid, text, deadline)
        else
          false
        end
    after
      remaining(deadline) ->
        # The notice may already have been consumed; the observable state of a
        # finished resume is the parked session.
        await_phase(pid, :awaiting_input, max(remaining(deadline), 200))
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # `%ReqLLM.Message{}` STRUCT equality, in order.
  defp prefix?(earlier, later) when length(earlier) <= length(later) do
    Enum.take(later, length(earlier)) == earlier
  end

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp text_of(_other), do: ""
end
