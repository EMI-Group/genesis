defmodule EvoGit.Runtime.AssistantTest do
  @moduledoc """
  `EvoGit.Runtime.Assistant` — the INTERACTIVE (repo-less) phase: one
  long-lived agent session the caller drives message by message, awaited until
  it is closed, then reported EXACTLY once.

  Everything runs against the REAL app-global `EvoGit.AgentScheduler` and a real
  `EvoGit.Agent.Session`; only the LLM plane is scripted through the
  `:agent_exchange_llm_call` engine seam (a plain-text reply is a `{:yield, …}`
  in interactive mode), so no repository, no worktree and no real LLM is
  involved. The phase's source root is a per-test scratch directory passed as
  `:source_root`, which keeps the repo-less context tree hermetic.

  ## What is pinned here

    * (a) a tool-free reply parks the session at `:awaiting_input` — the phase
      is STILL awaiting its close and nothing is finalized or merged;
    * (b) a second `send_session_message/3` resumes the SAME agent id and
      session pid, and `close_session/1` + `await_close/2` produce the repo-less
      report shape with the finalization broadcast firing exactly ONCE;
    * (c) a start failure is returned verbatim and finalizes/merges NOTHING;
    * (d) an explicit `session_mode: "oneshot"` raises the documented
      `ArgumentError` — this phase is interactive-only.

  ## Why `async: false`

  Named forcing GLOBALS:

    * the app-env engine seam `:agent_exchange_llm_call`, read at CALL time by
      every session's exchange worker — a concurrently running module's agent
      would observe this module's scripted replies;
    * the app-global `EvoGit.AgentScheduler` GenServer, whose `model_profiles` /
      `llm_model` are set for a resolvable selection and restored in `on_exit`;
    * its BEAM-global ETS rows (`:evogit_sched_meta` / `:evogit_agent_summary`)
      and the `EvoGit.PubSub` `"tasks"` topic this module asserts on (the
      finalization broadcast has no task-row filter to scope it with).

  Every fixture is per-test unique (the task id and the scratch source root),
  and the seam key is DELETED on exit when it was originally unset, so the
  production path stays byte-identical.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.Runtime.Assistant

  # The awaited events are real scheduling events (a session yield, a resumed
  # exchange, a close), but the shared host's scheduling swings several-fold
  # under parallel load, so the budget absorbs that latency — the wait still
  # fails (never passes silently) when the event never happens.
  @wait_budget_ms 30_000

  setup do
    original_profiles = GenServer.call(AgentScheduler, {:get_config, :model_profiles})
    original_model = GenServer.call(AgentScheduler, {:get_config, :llm_model})
    old_llm_call = Application.get_env(:evo_git, :agent_exchange_llm_call)

    # A resolvable model profile: `start_session/1` resolves a concrete selection
    # before the agent can be registered.
    assert :ok =
             GenServer.call(
               AgentScheduler,
               {:update_config,
                [
                  model_profiles: [%{id: "default", model: "test:model", concurrency: 1}],
                  llm_model: "test:model"
                ]}
             )

    unique = System.unique_integer([:positive])
    source_root = Path.join(System.tmp_dir!(), "evogit_assistant_#{unique}")
    File.mkdir_p!(source_root)
    File.write!(Path.join(source_root, "CONTEXT.md"), "# Assistant fixture root\n")

    task_id = "assistant-runtime-#{unique}"

    on_exit(fn ->
      restore_env(:agent_exchange_llm_call, old_llm_call)

      GenServer.call(AgentScheduler, {:update_config, [model_profiles: original_profiles]})

      # `update_config` rejects a nil llm_model — skip the key when it was nil.
      if original_model != nil do
        GenServer.call(AgentScheduler, {:update_config, [llm_model: original_model]})
      end

      # Best-effort teardown of anything a failing test left behind. The phase
      # runs in a plain Task (not a registry task), so this is keyed by task id.
      try do
        AgentScheduler.force_kill_task_agents_for_task(task_id)
      catch
        :exit, _reason -> :ok
      end

      File.rm_rf(source_root)
    end)

    %{source_root: source_root, task_id: task_id}
  end

  # ---------------------------------------------------------------------------
  # (a) a tool-free reply parks the session — nothing is finalized
  # ---------------------------------------------------------------------------
  describe "(a) a tool-free reply parks the session" do
    test "Assistant stays awaiting its close and finalizes nothing",
         %{source_root: source_root, task_id: task_id} do
      counter = script_yields(["first yield", "second yield"])
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      phase =
        Task.async(fn ->
          Assistant.run("assistant objective", phase_opts(source_root, task_id))
        end)

      idle = await_idle(task_id)
      session_pid = idle.session_pid

      assert is_integer(idle.agent_id)
      assert is_pid(session_pid)
      assert Process.alive?(session_pid)
      assert {:ok, %{phase: :awaiting_input}} = Session.inspect(session_pid, 500)

      # Exactly ONE exchange was paid: the yield is idle, not a turn loop.
      assert :counters.get(counter, 1) == 1

      # The phase is BLOCKED in `await_close(:infinity)` — it has not returned.
      assert Task.yield(phase, 0) == nil
      assert Process.alive?(phase.pid)

      # ... and nothing was finalized: no `:finalizing` broadcast (the ONE
      # signal `merge_and_report` is preceded by) and no terminal task status.
      for status <- [:finalizing, :completed, :failed, :cancelled] do
        refute_received {:task_updated, ^task_id, ^status, _node}
      end

      # The session is still registered live: dropping it would mean the phase
      # treated the yield as a finish.
      assert {:ok, _meta} = SchedStore.get_sched_meta(idle.agent_id)

      # Cleanup: close it so the phase returns and the scheduler recycles.
      assert :ok = AgentScheduler.close_session(idle.agent_id)
      await_idle_gone(idle.agent_id)
      assert {:ok, _report} = Task.await(phase, @wait_budget_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # (b) resume on the SAME session, then close — finalize exactly once
  # ---------------------------------------------------------------------------
  describe "(b) a resumed message then a close" do
    test "keeps ONE agent id/session, returns the repo-less report and finalizes once",
         %{source_root: source_root, task_id: task_id} do
      counter = script_yields(["first yield", "second yield"])
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      phase =
        Task.async(fn ->
          Assistant.run("assistant objective", phase_opts(source_root, task_id))
        end)

      first = await_idle(task_id)
      assert :counters.get(counter, 1) == 1

      # A second message RESUMES the same session (same pid, same agent id) and
      # pays exactly one more exchange.
      assert :ok = AgentScheduler.send_session_message(first.agent_id, "second message")

      wait_until(
        fn -> :counters.get(counter, 1) >= 2 and idle?(task_id) end,
        @wait_budget_ms
      )

      second = await_idle(task_id)
      assert second.agent_id == first.agent_id
      assert second.session_pid == first.session_pid
      assert Process.alive?(first.session_pid)
      assert {:ok, %{phase: :awaiting_input}} = Session.inspect(second.session_pid, 500)

      # Close finalizes the LAST yielded text — no extra exchange is run.
      assert :ok = AgentScheduler.close_session(first.agent_id)

      assert {:ok, %Result{result: "second yield"}} =
               AgentScheduler.await_close(first.agent_id, @wait_budget_ms)

      # The phase reports the repo-less shape: no branch, no merge, no commit.
      assert {:ok, report} = Task.await(phase, @wait_budget_ms)

      assert report == %{
               result: "second yield",
               commit_sha: nil,
               branch_name: nil,
               tag: nil
             }

      # EXACTLY ONCE: one finalization broadcast, then silence.
      assert_receive {:task_updated, ^task_id, :finalizing, _node}, @wait_budget_ms
      refute_receive {:task_updated, ^task_id, :finalizing, _node}, 300

      # The close is a finalization, not another turn.
      assert :counters.get(counter, 1) == 2
      await_idle_gone(first.agent_id)
    end
  end

  # ---------------------------------------------------------------------------
  # (c) a start failure is returned verbatim and finalizes nothing
  # ---------------------------------------------------------------------------
  describe "(c) a start failure" do
    test "returns the scheduler's error unchanged and finalizes/merges nothing",
         %{source_root: source_root, task_id: task_id} do
      # An empty profile list is the established no-real-LLM idiom for the
      # `:llm_not_configured` admission path.
      assert :ok =
               GenServer.call(AgentScheduler, {:update_config, [model_profiles: []]})

      script_yields(["never used"])
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      assert Assistant.run("assistant objective", phase_opts(source_root, task_id)) ==
               {:error, :llm_not_configured}

      # No session was registered, so nothing can be awaiting, and no
      # finalization/merge ever ran.
      refute Enum.any?(idle_entries(), &(&1.task_id == task_id))

      for status <- [:finalizing, :completed, :failed, :cancelled] do
        refute_received {:task_updated, ^task_id, ^status, _node}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # (d) an explicit one-shot mode is rejected
  # ---------------------------------------------------------------------------
  describe "(d) explicit session_mode" do
    test "an explicit \"oneshot\" raises the documented ArgumentError" do
      assert_raise ArgumentError, ~r/is the interactive phase/, fn ->
        Assistant.run("assistant objective", session_mode: "oneshot")
      end

      # The same rule for the keyword-only arity, and for the atom form.
      assert_raise ArgumentError, ~r/EvoGit\.Runtime\.SelfReflective/, fn ->
        Assistant.run(objective: "assistant objective", session_mode: :oneshot)
      end
    end

    test "an explicit \"interactive\" (or absent) mode is admitted" do
      # No model is required by the guard: it must pass BEFORE any scheduler
      # call, so a bad mode is the only raise.
      assert EvoGit.AgentScheduler.SessionOpts.fetch_session_mode(session_mode: "interactive") ==
               {:ok, :interactive}
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp phase_opts(source_root, task_id) do
    [
      task_id: task_id,
      source_root: source_root,
      session_mode: "interactive"
    ]
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
      id: "assistant-runtime-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # --- observation helpers ---------------------------------------------------

  defp idle_entries do
    AgentScheduler.list_awaiting_input()
  end

  defp idle?(task_id) do
    Enum.any?(idle_entries(), &(&1.task_id == task_id))
  end

  defp await_idle(task_id, timeout \\ @wait_budget_ms) do
    wait_until(fn -> idle?(task_id) end, timeout)

    idle_entries()
    |> Enum.find(&(&1.task_id == task_id))
    |> assert_present()
  end

  defp await_idle_gone(agent_id, timeout \\ @wait_budget_ms) do
    wait_until(
      fn -> not Enum.any?(idle_entries(), &(&1.agent_id == agent_id)) end,
      timeout
    )
  end

  defp assert_present(nil), do: flunk("expected an :awaiting_input session entry, got nil")
  defp assert_present(entry), do: entry

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
