defmodule EvoGit.AgentScheduler.SessionApiTest.StubAgent do
  @moduledoc """
  The interactive stub role for the scheduler's session API tests.

  Defined ABOVE the `async: false` test module on purpose: `mix test` starts the
  ExUnit runner BEFORE requiring test files, so a helper defined after the test
  module can still be unloaded when the first test runs.

  `available_tools/0` is EMPTY: every exchange is driven by the
  `:agent_exchange_llm_call` engine seam (a scripted plain-text reply yields in
  interactive mode), so no tool schema and no real LLM is ever involved.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the scheduler session API test role."

  @doc "No tools: the scripted seams serve every call."
  def available_tools, do: []

  @doc """
  The P3 opt-in. `Setup.resolve_session_mode/3` falls back to this role callback
  (an interactive role can never be flipped to one-shot by a missing ctx key),
  which is exactly how the Assistant role is wired.
  """
  def session_mode, do: :interactive
end

defmodule EvoGit.AgentScheduler.SessionApiTest do
  @moduledoc """
  The `EvoGit.AgentScheduler` INTERACTIVE-SESSION API, end to end:
  `start_session/1` → the session yields to `:awaiting_input` →
  `send_session_message/3` resumes it → `close_session/1` finalizes it →
  `await_close/2` returns `{:ok, %EvoGit.Agent.Result{}}` exactly once, plus its
  documented degraded answers (an unknown agent id and an expired wait budget).

  Everything goes through the REAL app-global scheduler and a real
  `EvoGit.Agent.Session`; only the LLM/tool plane is scripted, so the session
  registers a `from = nil` agent and parks idle exactly as in production.

  ## Why `async: false`

  Named forcing GLOBALS:

    * the app-env engine seam `:agent_exchange_llm_call`, read at CALL time by
      every session's exchange worker — a concurrently running module's agent
      would observe this module's scripted replies;
    * the app-global `EvoGit.AgentScheduler` GenServer (its `model_profiles` /
      `llm_model` are set for a resolvable selection and restored in `on_exit`);
    * its BEAM-global ETS rows (`:evogit_sched_meta` / `:evogit_agent_summary`)
      and the `EvoGit.TaskRegistry` casts the yield/resume signals trigger.

  Every fixture is per-test unique (task ids and agent ids are allocated by the
  scheduler itself and torn down in `on_exit`), and the seam key is DELETED on
  exit when it was originally unset, so the production path stays byte-identical.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler.Store

  # Every wait budget in this module, in one place. The awaited events are real
  # scheduling events (a session yield, a resumed exchange, a recycle), but the
  # shared host's scheduling swings several-fold under parallel load, so the
  # budget absorbs that latency — the wait still fails (never passes silently)
  # when the event never happens.
  @wait_budget_ms 30_000

  setup do
    original_profiles = GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})
    original_model = GenServer.call(EvoGit.AgentScheduler, {:get_config, :llm_model})
    old_llm_call = Application.get_env(:evo_git, :agent_exchange_llm_call)

    # A resolvable model profile: `start_session/1` resolves a concrete selection
    # before the agent can be registered.
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

      # `update_config` rejects a nil llm_model — skip the key when it was nil.
      if original_model != nil do
        GenServer.call(EvoGit.AgentScheduler, {:update_config, [llm_model: original_model]})
      end
    end)

    :ok
  end

  describe "a session yields, resumes and closes" do
    test "one agent id, the resumed exchange, and ONE terminal result from await_close/2" do
      counter = script_yields(["first yield", "second yield", "third yield"])
      {_task_id, agent_id} = start_interactive!()
      session_pid = session_pid!(agent_id)

      # 1. The first scripted turn YIELDS: the session parks at `:awaiting_input`
      #    instead of finishing, and the scheduler reports it as idle.
      assert await_idle(agent_id)
      assert Process.alive?(session_pid)
      assert :counters.get(counter, 1) == 1

      # 2. A message RESUMES the SAME session: a second exchange runs and yields
      #    again, on the SAME pid (one agent id, one worktree, one context).
      assert :ok = EvoGit.AgentScheduler.send_session_message(agent_id, "second message")

      wait_until(
        fn ->
          :counters.get(counter, 1) >= 2 and idle?(agent_id)
        end,
        @wait_budget_ms
      )

      assert session_pid!(agent_id) == session_pid
      assert Process.alive?(session_pid)

      # 3. Close finalizes the LAST yielded text — no extra exchange is run.
      assert :ok = EvoGit.AgentScheduler.close_session(agent_id)

      assert {:ok, %Result{result: "second yield"}} =
               EvoGit.AgentScheduler.await_close(agent_id, @wait_budget_ms)

      # The close is a finalization, not another turn.
      assert :counters.get(counter, 1) == 2

      # 4. EXACTLY ONCE: the agent is recycled, the session is gone, no longer
      #    idle, and a second await finds nothing to wait for.
      wait_until(fn -> Store.get_sched_meta(agent_id) == :error end, @wait_budget_ms)
      wait_until(fn -> not Process.alive?(session_pid) end, @wait_budget_ms)

      refute idle?(agent_id)
      assert EvoGit.AgentScheduler.await_close(agent_id, 1_000) == {:error, :not_found}
    end
  end

  describe "await_close/2 degraded answers" do
    test "an unknown agent id answers {:error, :not_found} immediately" do
      unknown_id = 9_960_000 + System.unique_integer([:positive])

      assert EvoGit.AgentScheduler.await_close(unknown_id) == {:error, :not_found}
      assert EvoGit.AgentScheduler.await_close(unknown_id, :infinity) == {:error, :not_found}
    end

    test "an expired budget answers {:error, :timeout} and the session keeps running" do
      counter = script_yields(["still here"])
      {_task_id, agent_id} = start_interactive!()

      assert await_idle(agent_id)
      session_pid = session_pid!(agent_id)

      assert EvoGit.AgentScheduler.await_close(agent_id, 100) == {:error, :timeout}

      # The WAIT expired, not the session: it is still alive, still idle, and it
      # paid no extra turn.
      assert Process.alive?(session_pid)
      assert idle?(agent_id)
      assert :counters.get(counter, 1) == 1

      assert {:ok, %{phase: :awaiting_input}} = EvoGit.Agent.Session.inspect(session_pid, 500)
    end
  end

  # --- fixtures -------------------------------------------------------------

  # One app-global scheduler session per test, REPO-LESS so no worktree or git
  # repo is involved, with a per-test-unique task id and a cleanup hook.
  defp start_interactive! do
    task_id = "session-api-#{System.unique_integer([:positive])}"

    assert {:ok, agent_id} =
             EvoGit.AgentScheduler.start_session(
               agent_module: EvoGit.AgentScheduler.SessionApiTest.StubAgent,
               objective: "interactive session API objective",
               repo_less: true,
               task_id: task_id
             )

    on_exit(fn ->
      # Best-effort teardown: kill anything the failing test left behind.
      EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id)
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
      id: "session-api-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # --- observation helpers ---------------------------------------------------

  defp idle_entries(agent_id) do
    Enum.filter(EvoGit.AgentScheduler.list_awaiting_input(), &(&1.agent_id == agent_id))
  end

  defp idle?(agent_id), do: idle_entries(agent_id) != []

  defp await_idle(agent_id, timeout \\ @wait_budget_ms) do
    wait_until(fn -> idle?(agent_id) end, timeout)
  end

  defp session_pid!(agent_id) do
    assert {:ok, %{session_pid: pid}} = Store.get_sched_meta(agent_id)
    assert is_pid(pid)
    pid
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
