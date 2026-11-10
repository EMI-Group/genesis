defmodule EvoGit.AgentScheduler.SessionForceKillTest.StubAgent do
  @moduledoc """
  The interactive stub role for the session cancellation/force-kill tests.

  Defined ABOVE the `async: false` test module on purpose: `mix test` starts the
  ExUnit runner BEFORE requiring test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the session force-kill test role."

  @doc "No tools: the scripted `:llm_call` seam serves every call."
  def available_tools, do: []

  @doc """
  The P3 opt-in. `Setup.resolve_session_mode/3` falls back to this role callback,
  which is how the Assistant role is wired.
  """
  def session_mode, do: :interactive
end

defmodule EvoGit.AgentScheduler.SessionForceKillTest do
  @moduledoc """
  Cancelling an IDLE (`:awaiting_input`) interactive session through the
  scheduler, and the TASK-ID-addressed force kill.

  Three scenarios:

    1. **Graceful cancel while idle** — `begin_graceful_cancel/1` terminates the
       session immediately (nothing to save but the transcript), finalizes the
       last yielded text as its ONE result, and `await_close/2` returns that
       `{:ok, %EvoGit.Agent.Result{}}` exactly once.
    2. **Force kill while idle** — `force_kill_task_agents_for_task/1` stops the
       session with `:shutdown` and delivers NO result; a registered
       `await_close/2` waiter is answered `{:error, :cancelled}`.
    3. **`force_kill_task_agents_for_task/1` finds a `from = nil` session** — a
       `start_session/1` agent has no caller pid, so the caller-pid-addressed
       `force_kill_task_agents/1` cannot see it while the task-id form can; an
       unknown task id answers `{:error, :not_found}`.

  Each scenario also pins that the session pid is gone (no dangling session) and
  that exactly ONE terminal outcome exists (a second `await_close/2` answers
  `{:error, :not_found}`).

  ## Why `async: false`

  Named forcing GLOBALS:

    * the app-env engine seam `:agent_exchange_llm_call`, read at CALL time by
      every session's exchange worker — a concurrently running module's agent
      would observe this module's scripted replies;
    * the app-global `EvoGit.AgentScheduler` GenServer (its `model_profiles` /
      `llm_model` are set for a resolvable selection and restored in `on_exit`),
      whose `State.close_waiters` this module observes through `:sys.get_state/1`
      to register its waiters race-free;
    * its BEAM-global ETS rows (`:evogit_sched_meta` / `:evogit_agent_summary`)
      and the `:evogit_cancelling_tasks` marker this module drives.

  Every fixture is per-test unique (task ids are per-test strings, agent ids are
  allocated by the scheduler) and torn down in `on_exit`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler.Store

  # Every wait budget in this module, in one place: the awaited events are real
  # scheduling events (a session finalize, a monitor `:DOWN`, a recycle), and the
  # shared host's scheduling swings several-fold under parallel load. The budget
  # absorbs that latency; a missing event still fails, never passes silently.
  @wait_budget_ms 30_000

  setup do
    original_profiles = GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})
    original_model = GenServer.call(EvoGit.AgentScheduler, {:get_config, :llm_model})
    old_llm_call = Application.get_env(:evo_git, :agent_exchange_llm_call)

    assert :ok =
             GenServer.call(
               EvoGit.AgentScheduler,
               {:update_config,
                [
                  model_profiles: [%{id: "default", model: "test:model", concurrency: 1}],
                  llm_model: "test:model"
                ]}
             )

    on_exit(fn ->
      restore_env(:agent_exchange_llm_call, old_llm_call)

      GenServer.call(
        EvoGit.AgentScheduler,
        {:update_config, [model_profiles: original_profiles]}
      )

      if original_model != nil do
        GenServer.call(EvoGit.AgentScheduler, {:update_config, [llm_model: original_model]})
      end
    end)

    :ok
  end

  describe "graceful cancel while :awaiting_input" do
    test "terminates the idle session and delivers its ONE result to an await_close/2 waiter" do
      counter = script_yields(["idle before cancel"])
      {task_id, agent_id} = start_interactive!()
      assert await_idle(agent_id)

      session_pid = session_pid!(agent_id)
      monitor = Process.monitor(session_pid)

      waiter = Task.async(fn -> EvoGit.AgentScheduler.await_close(agent_id, @wait_budget_ms) end)
      assert await_waiter_registered(waiter.pid, agent_id)

      assert :ok = EvoGit.AgentScheduler.begin_graceful_cancel(task_id)

      # An idle cancel is immediate: the last yielded text becomes the report and
      # NO extra turn is paid for it.
      assert {:ok, %Result{result: "idle before cancel"}} = Task.await(waiter, @wait_budget_ms)
      assert :counters.get(counter, 1) == 1

      assert_receive {:DOWN, ^monitor, :process, ^session_pid, :normal}, @wait_budget_ms

      wait_until(fn -> Store.get_sched_meta(agent_id) == :error end, @wait_budget_ms)
      refute idle?(agent_id)

      # Exactly ONE terminal outcome: nothing is left to await afterwards.
      assert EvoGit.AgentScheduler.await_close(agent_id, 1_000) == {:error, :not_found}
    end
  end

  describe "force kill while :awaiting_input" do
    test "stops the session with :shutdown and delivers NO result" do
      _counter = script_yields(["never delivered"])
      {task_id, agent_id} = start_interactive!()
      assert await_idle(agent_id)

      session_pid = session_pid!(agent_id)
      monitor = Process.monitor(session_pid)

      waiter = Task.async(fn -> EvoGit.AgentScheduler.await_close(agent_id, @wait_budget_ms) end)
      assert await_waiter_registered(waiter.pid, agent_id)

      assert :ok = EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id)

      # A force kill delivers NO session result: the registered waiter is answered
      # the cancel error, and the session stops with `:shutdown` (never a
      # finalize), so no `%Result{}` can exist for this agent.
      assert {:error, :cancelled} = Task.await(waiter, @wait_budget_ms)
      assert_receive {:DOWN, ^monitor, :process, ^session_pid, :shutdown}, @wait_budget_ms

      wait_until(fn -> Store.get_sched_meta(agent_id) == :error end, @wait_budget_ms)
      refute idle?(agent_id)
      assert EvoGit.AgentScheduler.await_close(agent_id, 1_000) == {:error, :not_found}
    end
  end

  describe "force_kill_task_agents_for_task/1" do
    test "finds a `from = nil` session by task id, which the caller-pid form cannot" do
      _counter = script_yields(["idle session"])
      {task_id, agent_id} = start_interactive!()
      assert await_idle(agent_id)

      session_pid = session_pid!(agent_id)
      monitor = Process.monitor(session_pid)

      # A `start_session/1` agent is registered with `from: nil`, so the
      # caller-pid-addressed lookup has no depth-0 row to match.
      assert EvoGit.AgentScheduler.force_kill_task_agents(self()) == {:error, :not_found}
      assert Process.alive?(session_pid)

      # An unknown task id is the documented miss.
      assert EvoGit.AgentScheduler.force_kill_task_agents_for_task(
               "no-such-task-#{System.unique_integer([:positive])}"
             ) == {:error, :not_found}

      assert :ok = EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id)

      assert_receive {:DOWN, ^monitor, :process, ^session_pid, :shutdown}, @wait_budget_ms

      wait_until(fn -> Store.get_sched_meta(agent_id) == :error end, @wait_budget_ms)
      refute idle?(agent_id)

      # Idempotent miss once the agents are gone.
      assert EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id) ==
               {:error, :not_found}
    end
  end

  # --- fixtures -------------------------------------------------------------

  # One app-global scheduler session per test, REPO-LESS (no worktree, no git
  # repo), with a per-test-unique task id and cancellation cleanup.
  defp start_interactive! do
    task_id = "session-kill-#{System.unique_integer([:positive])}"

    assert {:ok, agent_id} =
             EvoGit.AgentScheduler.start_session(
               agent_module: EvoGit.AgentScheduler.SessionForceKillTest.StubAgent,
               objective: "session force-kill objective",
               repo_less: true,
               task_id: task_id
             )

    on_exit(fn ->
      # Best-effort teardown for a failing test, and never leave the graceful
      # cancel marker behind.
      EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id)
      EvoGit.AgentScheduler.clear_cancelling_task(task_id)
    end)

    {task_id, agent_id}
  end

  # Every scripted turn answers with the next text in the list and YIELDS (an
  # interactive `{:implicit_completion, …}` is a `{:yield, …}`). The counter is
  # cross-process: the seam runs inside the exchange WORKER.
  defp script_yields(texts) do
    counter = :counters.new(1, [:atomics])

    Application.put_env(:evo_git, :agent_exchange_llm_call, fn context,
                                                               _tools,
                                                               _params,
                                                               _agent_id,
                                                               _retries ->
      :counters.add(counter, 1, 1)
      index = :counters.get(counter, 1) - 1
      text = Enum.at(texts, min(index, length(texts) - 1))
      {:implicit_completion, response(context, text), text}
    end)

    counter
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "session-kill-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # --- observation helpers ---------------------------------------------------

  defp idle?(agent_id) do
    Enum.any?(EvoGit.AgentScheduler.list_awaiting_input(), &(&1.agent_id == agent_id))
  end

  defp await_idle(agent_id, timeout \\ @wait_budget_ms) do
    wait_until(fn -> idle?(agent_id) end, timeout)
  end

  defp session_pid!(agent_id) do
    assert {:ok, %{session_pid: pid}} = Store.get_sched_meta(agent_id)
    assert is_pid(pid)
    pid
  end

  # Registers the waiter RACE-FREE: `await_close/2` is a scheduler `handle_call`,
  # so poll the scheduler's own `close_waiters` bookkeeping until this caller is
  # in it before triggering the terminal event.
  defp await_waiter_registered(waiter_pid, agent_id, timeout \\ @wait_budget_ms) do
    wait_until(
      fn ->
        case :sys.get_state(EvoGit.AgentScheduler) do
          %{close_waiters: waiters} ->
            waiters
            |> Map.get(agent_id, [])
            |> Enum.any?(fn {pid, _from} -> pid == waiter_pid end)
        end
      end,
      timeout
    )
  end

  # Bounded, event-driven wait: the predicate is the assertion.
  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout, 1)
  end

  defp do_wait_until(fun, deadline, original_timeout, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        beat = min(interval, 15)
        Process.sleep(beat)
        do_wait_until(fun, deadline, original_timeout, beat * 2)
    end
  end

  # Restore a seam nil-aware: delete the key when it was originally unset.
  defp restore_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_env(key, value), do: Application.put_env(:evo_git, key, value)
end
