defmodule EvoGit.TaskRegistry.InteractiveTaskTest do
  @moduledoc """
  The REAL task path of P3 interactive sessions: a `:reflect` task whose opts
  carry `session_mode: "interactive"` is routed by
  `EvoGit.TaskRegistry.TaskExecutor` into `EvoGit.Runtime.Assistant`, which
  starts ONE scheduler session and awaits its close.

  Pinned here, end to end:

    * the submitted `session_mode` is PERSISTED as `"interactive"` (the
      `tasks.session_mode` column) and survives the round trip;
    * the session's yield flips the TASK ROW to the non-terminal
      `:awaiting_input` — live, lease-renewable (the heartbeat renews it) and
      NOT part of the finished/cleanup set;
    * a second `send_session_message/3` resumes the SAME agent id and flips the
      row back to `:running`, then to `:awaiting_input` again;
    * a graceful `cancel_task/1` from `:awaiting_input` ends it `:cancelled`
      immediately, releasing the session and touching no `result`;
    * a task WITHOUT `session_mode` stays on the one-shot default
      (`"oneshot"`, `Runtime.SelfReflective`, never `:awaiting_input`).

  ## Why the APP-GLOBAL registry

  The mid-run flip is a CAST from the app-global `EvoGit.AgentScheduler` to
  `EvoGit.TaskRegistry.update_task_status/2`. That cast resolves the registry
  name in the SCHEDULER's process dictionary, which carries no
  `:evogit_task_registry_server` seam, so it always targets the app-global
  singleton. The `EvoGit.TaskRegistryCase` fixture's isolated registry therefore
  could never observe it — this module drives the global registry/store pair the
  way production does, and deletes only its OWN per-test-unique row afterwards.
  The structural lifecycle halves (heartbeat renewal, cleanup exclusion, boot
  reconciliation, force kill) are covered separately in
  `test/evo_git/task_registry/awaiting_input_test.exs` on isolated instances.

  ## Why `async: false`

  Named forcing GLOBALS:

    * the app-global `EvoGit.TaskRegistry` and `EvoGit.Store` GenServers (this
      module writes a real task row into the app-level database);
    * the app-global `EvoGit.AgentScheduler` (its `model_profiles` /
      `llm_model` are set for a resolvable selection and restored in
      `on_exit`) and its BEAM-global ETS rows;
    * the app-env engine seam `:agent_exchange_llm_call`, read at CALL time by
      every session's exchange worker;
    * the `EvoGit.PubSub` `"tasks"` topic this module asserts on.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler
  alias EvoGit.Store
  alias EvoGit.TaskRegistry

  # The awaited events are real scheduling events, but the shared host's
  # scheduling swings several-fold under parallel load, so the budget absorbs
  # that latency — the wait still fails (never passes silently) when the event
  # never happens.
  @wait_budget_ms 30_000

  setup do
    original_profiles = GenServer.call(AgentScheduler, {:get_config, :model_profiles})
    original_model = GenServer.call(AgentScheduler, {:get_config, :llm_model})
    old_llm_call = Application.get_env(:evo_git, :agent_exchange_llm_call)

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
    source_root = Path.join(System.tmp_dir!(), "evogit_interactive_task_#{unique}")
    File.mkdir_p!(source_root)
    File.write!(Path.join(source_root, "CONTEXT.md"), "# Interactive task fixture root\n")

    on_exit(fn ->
      restore_env(:agent_exchange_llm_call, old_llm_call)

      GenServer.call(AgentScheduler, {:update_config, [model_profiles: original_profiles]})

      # `update_config` rejects a nil llm_model — skip the key when it was nil.
      if original_model != nil do
        GenServer.call(AgentScheduler, {:update_config, [llm_model: original_model]})
      end

      File.rm_rf(source_root)
    end)

    # A REPO-LESS :reflect task's opts — no :path, which is exactly the shape
    # `TaskExecutor`'s `:reflect` clause must tolerate.
    %{
      task_opts: [
        objective: "interactive assistant objective",
        session_mode: "interactive",
        source_root: source_root
      ]
    }
  end

  describe "an interactive :reflect task" do
    test "persists session_mode, awaits input, resumes and cancels from idle", %{
      task_opts: task_opts
    } do
      script_yields(["first yield", "second yield"])
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      assert {:ok, task} = TaskRegistry.start_task(:reflect, task_opts)
      task_id = task.id
      track_task!(task_id)

      # 1. The driver mode is PERSISTED, not just carried in opts: the submitted
      #    STRING is what the `tasks.session_mode` column holds, and it survives
      #    the round trip. (The returned struct keeps the producer's default
      #    field — `Codec.task_session_mode/1` is the ONE write-path resolver, so
      #    an explicit opts value that IS the default spelling is read from the
      #    opts, never from the struct.)
      assert Keyword.get(task.opts, :session_mode) == "interactive"

      persisted = TaskRegistry.get_task(task_id)
      assert persisted.session_mode == "interactive"
      assert persisted.type == :reflect
      # `session_mode` is one of the deliberately STRING-keyed data-plane opts
      # (the dashboard reads `Map.get(Map.new(opts), "session_mode")`).
      assert Map.get(Map.new(persisted.opts), "session_mode") == "interactive"

      # `start_task` announces the task as running...
      assert_receive {:task_updated, ^task_id, :running, _node}, @wait_budget_ms

      # 2. ... and the session's yield flips the TASK ROW to the non-terminal
      #    `:awaiting_input` — the task is NOT finalized, deleted or completed.
      assert_receive {:task_updated, ^task_id, :awaiting_input, _node}, @wait_budget_ms
      assert Store.get_task_status(Store, task_id) == :awaiting_input

      idle = await_idle(task_id)
      assert is_integer(idle.agent_id)
      assert is_pid(idle.session_pid)
      assert {:ok, %{phase: :awaiting_input}} = Session.inspect(idle.session_pid, 500)

      # A waiting session is LIVE: it is in the lease set (boot reconciliation
      # and the heartbeat still see it) and NOT in the finished set that
      # `clear_finished_tasks` deletes from.
      lease_entry = Enum.find(lease_info(), &(&1.id == task_id))
      assert lease_entry.status == :awaiting_input
      refute task_id in Store.select_finished_task_ids(Store)

      # The heartbeat RENEWS its lease like a running task's (no one-shot sweep
      # may fail an idle session whose wrapper is alive).
      expired = System.system_time(:second) - 300
      :ok = Store.update_lease_expires_at(Store, task_id, expired)
      send(TaskRegistry.server(), :heartbeat)
      # Sync on the registry (same sender ⇒ FIFO) before reading the store.
      TaskRegistry.list_tasks()
      %{lease_expires_at: renewed} = Store.select_task_update_info(Store, task_id)
      assert renewed > expired

      # 3. A second message resumes the SAME session: the row flips to
      #    `:running` and back to `:awaiting_input` on the SAME agent id/pid.
      assert :ok = AgentScheduler.send_session_message(idle.agent_id, "second message")

      assert_receive {:task_updated, ^task_id, :running, _node}, @wait_budget_ms
      assert_receive {:task_updated, ^task_id, :awaiting_input, _node}, @wait_budget_ms

      resumed = await_idle(task_id)
      assert resumed.agent_id == idle.agent_id
      assert resumed.session_pid == idle.session_pid

      # 4. A graceful cancel from `:awaiting_input` ends the task immediately as
      #    `:cancelled` — the session is released and the row is terminal.
      assert :ok = TaskRegistry.cancel_task(task_id)

      assert_receive {:task_updated, ^task_id, :cancelled, _node}, @wait_budget_ms

      cancelled = TaskRegistry.get_task(task_id)
      assert cancelled.status == :cancelled
      assert cancelled.finished_at != nil
      assert cancelled.lease_expires_at == nil
      # A cancel never clobbers a session's result.
      assert cancelled.result == nil

      refute Enum.any?(idle_entries(), &(&1.task_id == task_id))
      wait_until(fn -> not Process.alive?(idle.session_pid) end, @wait_budget_ms)
    end

    test "a task WITHOUT session_mode keeps the one-shot default", %{task_opts: task_opts} do
      # Same task type, no :session_mode key: the persisted column defaults to
      # "oneshot" and the one-shot `SelfReflective` engine is the driver. With
      # the model profiles emptied it fails fast instead of yielding.
      assert :ok = GenServer.call(AgentScheduler, {:update_config, [model_profiles: []]})

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")

      assert {:ok, task} =
               TaskRegistry.start_task(:reflect, Keyword.delete(task_opts, :session_mode))

      track_task!(task.id)

      assert task.session_mode == "oneshot"
      assert TaskRegistry.get_task(task.id).session_mode == "oneshot"

      assert_receive {:task_updated, task_id, :failed, _node}, @wait_budget_ms
      assert task_id == task.id
      refute_received {:task_updated, ^task_id, :awaiting_input, _node}

      # The one-shot path never starts a session, so nothing can be awaiting.
      refute Enum.any?(idle_entries(), &(&1.task_id == task_id))
    end
  end

  # --- fixtures -------------------------------------------------------------

  # Per-test teardown for the ONE task this test created: kill anything left
  # behind, then remove its row. `on_exit` runs in a DIFFERENT process, so the
  # task id is captured here instead of read from the registry's state.
  defp track_task!(task_id) do
    on_exit(fn ->
      try do
        AgentScheduler.force_kill_task_agents_for_task(task_id)
      catch
        :exit, _reason -> :ok
      end

      TaskRegistry.delete_task(task_id)
    end)
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
      id: "interactive-task-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # --- observation helpers ---------------------------------------------------

  defp idle_entries, do: AgentScheduler.list_awaiting_input()

  defp await_idle(task_id, timeout \\ @wait_budget_ms) do
    wait_until(fn -> Enum.any?(idle_entries(), &(&1.task_id == task_id)) end, timeout)

    idle_entries()
    |> Enum.find(&(&1.task_id == task_id))
    |> assert_present()
  end

  defp lease_info, do: Store.select_running_lease_info(Store)

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
