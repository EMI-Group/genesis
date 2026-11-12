defmodule EvoGit.Agent.Tools.ElixirEval.LiveSessionAuthorizationTest do
  @moduledoc """
  The REAL `/assistant` session shape: one genuinely registered interactive session admits `elixir_eval`.
  No fixture authority, no hand-written `$callers`/`$ancestors`: the scheduler registers the session, the session spawns its exchange worker, the worker spawns the tool task, and `EvoGit.Agent.Tools.ElixirEval.Authorization.authorize/0` decides from that real process chain alone.
  The registry lookup for the session's scheduler-minted task id answers `nil` (a session creates no `tasks` row), so admission can only come from the row-absent interactive-root branch.
  ## Why `async: false`
  Named forcing GLOBALS:
  * the app-env engine seam `:agent_exchange_llm_call`, read at CALL time by every session's exchange worker — a concurrently running module's agent would observe this module's scripted replies;
  * the app-global `EvoGit.AgentScheduler` GenServer (`:model_profiles` and `:llm_model` are pinned for a resolvable selection and restored in `on_exit`);
  * its BEAM-global ETS rows (`:evogit_sched_meta` / `:evogit_agent_summary`), which this module writes through the scheduler itself and deletes in `on_exit`;
  * the app-global `EvoGit.TaskRegistry` reads/casts the yield and the task-id lookup trigger.
  Every wait is event-driven: the scripted seam SENDS the observed tool messages, and every other assertion polls a bounded monotonic deadline.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  # The denial text `Authorization` answers when the tool task is not admitted;
  # its absence in the tool result is the positive proof of admission.
  @denial "requires a live root reflective assistant"

  # Generous budgets: Dune boots the interpreter plus a shared host's scheduling
  # latency. The awaited events are real scheduling events (a tool result, a
  # session yield), so a budget expiry still FLUNKS rather than passing silently.
  @tool_budget_ms 120_000
  @wait_budget_ms 120_000

  setup do
    original_profiles = GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})
    original_model = GenServer.call(EvoGit.AgentScheduler, {:get_config, :llm_model})
    old_llm_call = Application.get_env(:evo_git, :agent_exchange_llm_call)

    # A resolvable model profile: `start_session/1` resolves a concrete
    # selection before the agent can be registered.
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

  test "a live /assistant session is admitted by its own spawned tool task" do
    test_pid = self()
    turns = :counters.new(1, [:atomics])

    # The seam runs inside the exchange WORKER, so the counter and the test pid
    # are cross-process. Turn 1 asks for the tool; every later turn reports the
    # tool messages it was handed and then replies with text (an interactive
    # `{:implicit_completion, …}` is a `{:yield, …}`, parking the session).
    Application.put_env(:evo_git, :agent_exchange_llm_call, fn context,
                                                               _tools,
                                                               _params,
                                                               _agent_id,
                                                               _retries ->
      :counters.add(turns, 1, 1)

      case :counters.get(turns, 1) do
        1 ->
          {:ok, tool_call_response(context)}

        _ ->
          send(test_pid, {:tool_messages, tool_texts(context)})
          {:implicit_completion, text_response(context, "Computed 42."), "Computed 42."}
      end
    end)

    assert {:ok, agent_id} =
             AgentScheduler.start_session(
               agent_module: EvoGit.Agents.SelfReflective,
               repo_less: true,
               session_mode: :interactive,
               objective: "Use elixir_eval to compute 40 + 2."
             )

    # Registered from INSIDE the test body (after the session exists) so it runs
    # BEFORE the setup `on_exit` that restores the engine seam.
    on_exit(fn -> teardown(agent_id) end)

    # The proof of admission: a real tool task descended from the session ran
    # `elixir_eval` read tier and got the value back, with no denial text.
    assert_receive {:tool_messages, texts}, @tool_budget_ms
    assert Enum.any?(texts, &String.contains?(&1, "Result: 42"))
    refute Enum.any?(texts, &String.contains?(&1, @denial))

    # The session parked idle after the yield; every shape assertion below is
    # the REAL registered one, never a fixture-written row.
    wait_until(
      fn ->
        match?({:ok, %SchedMeta{status: :awaiting_input}}, SchedStore.get_sched_meta(agent_id))
      end,
      @wait_budget_ms
    )

    assert {:ok, %SchedMeta{} = meta} = SchedStore.get_sched_meta(agent_id)
    assert meta.mode == :interactive
    assert meta.depth == 0
    assert meta.parent_id == nil
    assert meta.result_sent == false
    assert meta.status in [:running, :blocked, :awaiting_input]
    assert is_binary(meta.task_id) and meta.task_id != ""
    assert is_pid(meta.session_pid) and Process.alive?(meta.session_pid)

    # The scheduler-minted task id is the agent's task id everywhere, and it owns
    # NO `tasks` row — that absent row is what selects the interactive branch.
    assert AgentScheduler.task_id_for_agent(agent_id) == meta.task_id
    assert EvoGit.TaskRegistry.get_task_lite(meta.task_id) == nil

    opts = meta.spec.opts
    assert opts[:repo_less] == true
    assert opts[:session_mode] == :interactive
    refute Keyword.has_key?(opts, :task_id)
    assert meta.spec.agent_module == EvoGit.Agents.SelfReflective
    assert meta.spec.repo_id == "primary"
    assert meta.spec.foreign_repos == []
    assert meta.spec.phylo_node == nil

    assert [{^agent_id, %EvoGit.AgentScheduler.AgentState{} = summary}] =
             :ets.lookup(:evogit_agent_summary, agent_id)

    assert summary.parent_id == nil
    assert summary.repo_id == "primary"
    assert summary.foreign_repos == []
  end

  # --- scripted LLM turns -----------------------------------------------------

  # Turn 1: ONE `elixir_eval` call at the read tier (no approval involved). The
  # assistant message is appended to the context because the loop reads
  # `response.context` (never the request it sent).
  defp tool_call_response(context) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [],
      tool_calls: [
        ReqLLM.ToolCall.new(
          "call_1",
          "elixir_eval",
          ~s({"code":"40 + 2","tier":"read","timeout_ms":5000})
        )
      ]
    }

    %ReqLLM.Response{
      id: "live-session-tool-call",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # Turns 2+: a plain-text reply, which is an interactive yield.
  defp text_response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "live-session-text",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # Every `:tool` message's text parts, joined per message. Total: a part without
  # a binary `:text` contributes nothing.
  defp tool_texts(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(fn message ->
      message.content
      |> List.wrap()
      |> Enum.map_join("", &part_text/1)
    end)
  end

  defp part_text(%{type: :text, text: text}) when is_binary(text), do: text
  defp part_text(_part), do: ""

  # --- teardown ---------------------------------------------------------------

  # Best effort ONLY: a failing assertion must never turn into a teardown error.
  # The session is closed (its ONE terminal outcome, `await_close/2`), anything
  # still registered for the task is force-killed, and only THIS test's ETS rows
  # and control row are removed.
  defp teardown(agent_id) do
    try do
      case AgentScheduler.close_session(agent_id) do
        :ok -> AgentScheduler.await_close(agent_id, 5_000)
        _other -> :ok
      end

      task_id =
        case SchedStore.get_sched_meta(agent_id) do
          {:ok, %SchedMeta{task_id: task_id}} -> task_id
          :error -> nil
        end

      if is_binary(task_id), do: AgentScheduler.force_kill_task_agents_for_task(task_id)

      delete_row(:evogit_sched_meta, agent_id)
      delete_row(:evogit_agent_summary, agent_id)
      AgentScheduler.ControlPlane.delete(agent_id)
      :ok
    catch
      # A scheduler/session that is already down must not fail the suite.
      :exit, _reason -> :ok
    end
  end

  defp delete_row(table, id) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table, id)
    :ok
  end

  # --- waits ------------------------------------------------------------------

  # Bounded, event-driven wait: the predicate IS the assertion. The interval
  # backs off 10 ms → 50 ms so a long wait costs little while a short one stays
  # responsive.
  defp wait_until(fun, timeout) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout, 10)
  end

  defp do_wait_until(fun, deadline, original_timeout, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        Process.sleep(interval)
        do_wait_until(fun, deadline, original_timeout, min(interval * 2, 50))
    end
  end

  # Restore a seam nil-aware: delete the key when it was originally unset.
  defp restore_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_env(key, value), do: Application.put_env(:evo_git, key, value)
end
