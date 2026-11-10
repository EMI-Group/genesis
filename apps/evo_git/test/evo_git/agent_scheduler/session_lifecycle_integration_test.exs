defmodule EvoGit.AgentScheduler.SessionLifecycleIntegrationTest do
  @moduledoc """
  P2 session-lifecycle invariants, end to end through
  `EvoGit.AgentScheduler.run_agent/2` (the app-global scheduler, real sessions,
  real git worktrees) — never a real LLM call.

  Two scenarios, both scripted through the exchange engine seams:

    1. **A crashing exchange re-dispatches a NEW session.** The first scripted
       call RAISES inside the exchange worker. The worker dies abnormally, the
       session propagates that crash (`{:stop, reason, data}` — no result is
       delivered), and the scheduler's crash-retry path re-dispatches a FRESH
       session for the SAME agent id. That retry requests a fresh worktree,
       calls the LLM again and completes the run to the ORIGINAL blocked
       caller. The retry is bounded by `:agent_max_retries`, so exactly ONE
       retry happens (never a retry storm).

    2. **A graceful cancel keeps the run alive and preserves its result.**
       While the first exchange is parked inside its LLM call, the owning task
       is gracefully cancelled (`begin_graceful_cancel/1`): the session enters
       `:cancelling` and its summary row follows, but the WORKER is never
       killed. Releasing the parked call lets the save-work grace run — the
       cancel message is drained into the context, at least one MORE LLM call
       happens — and the run finishes with its OWN plain-text report (never
       `{:error, :cancelled}`).

  ## Why `async: false`

  Named forcing GLOBALS:

    * the app-env engine seam `:agent_exchange_llm_call` — read at CALL time by
      EVERY session's exchange worker, so a concurrently running module's agent
      would observe this module's scripted replies (scenario 2 additionally sets
      `:agent_exchange_tool_batch`, the same kind of global);
    * the app-global `EvoGit.AgentScheduler` GenServer, whose `:agent_max_retries`
      value this module changes and restores;
    * its global ETS rows (`:evogit_sched_meta` / `:evogit_agent_summary`) and
      the `:evogit_cancelling_tasks` marker this module drives.

  Every agent id is per-test unique (it is discovered from the scheduler's own
  `:evogit_sched_meta` diff and recycled by production), every seam is restored
  (the key is DELETED when it was unset) and every repo is a per-test temp dir.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.Summary
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A minimal `EvoGit.Agent` role: the SESSION builds the agent state from these
  # callbacks and the scripted seams replace the LLM/tool plane, so the role is
  # a system prompt plus an EMPTY tool list (the scripted model's `noop` call is
  # served by the tool-batch seam, never by the role's schemas).
  defmodule LifecycleAgent do
    use EvoGit.Agent

    @doc "The role's fixed system prompt."
    def system_prompt, do: "You are the session lifecycle test role."

    @doc "No tools: the scripted seams serve every call."
    def available_tools, do: []
  end

  setup do
    # The app-global scheduler's crash-retry budget: scenario 1 sets it to ONE
    # retry so the bound is pinned instead of the production default of 3.
    original_retries = GenServer.call(EvoGit.AgentScheduler, {:get_config, :agent_max_retries})
    original_profiles = GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles})
    original_model = GenServer.call(EvoGit.AgentScheduler, {:get_config, :llm_model})

    old_llm = Application.get_env(:evo_git, :agent_exchange_llm_call)
    old_batch = Application.get_env(:evo_git, :agent_exchange_tool_batch)

    # A resolvable model profile: registration resolves a concrete selection
    # before the session can start (same shape as agent_scheduler_test.exs).
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
      restore_env(:agent_exchange_llm_call, old_llm)
      restore_env(:agent_exchange_tool_batch, old_batch)

      GenServer.call(
        EvoGit.AgentScheduler,
        {:update_config, [agent_max_retries: original_retries, model_profiles: original_profiles]}
      )

      # `update_config` rejects a nil llm_model — skip the key when it was nil.
      if original_model != nil do
        GenServer.call(EvoGit.AgentScheduler, {:update_config, [llm_model: original_model]})
      end
    end)

    :ok
  end

  test "a crashing exchange re-dispatches a NEW session and the retry completes" do
    {repo_root, sha} = init_repo!("a")
    before_ids = sched_meta_ids()
    test_pid = self()

    assert :ok =
             GenServer.call(EvoGit.AgentScheduler, {:update_config, [agent_max_retries: 1]})

    # Cross-process mutable state: the seam runs in the exchange WORKER, so a
    # plain captured closure local would not be shared with the test. One atomic
    # counter carries the attempt index.
    counter = :counters.new(1, [:atomics])

    Application.put_env(:evo_git, :agent_exchange_llm_call, fn context,
                                                               _tools,
                                                               _params,
                                                               agent_id,
                                                               _retries ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      # `:evogit_agent_pid` is the SESSION pid the worker runs for.
      session_pid = Process.get(:evogit_agent_pid)

      registered? =
        match?([{^session_pid, _}], Registry.lookup(Session.Registry, agent_id))

      send(test_pid, {:attempt, n, session_pid, registered?})

      if n == 1 do
        raise "boom"
      else
        text = "retry report"
        {:implicit_completion, llm_response(context, text), text}
      end
    end)

    caller =
      Task.async(fn -> EvoGit.AgentScheduler.run_agent(spec_for(repo_root, sha), 60_000) end)

    assert_receive {:attempt, 1, pid1, true}, 30_000
    # The retry's session start pays the production crash-retry settle sleep
    # (`Session.Setup.bind_worktree/2` sleeps 30_000 × retries), so this budget
    # covers a real, slow-but-correct retry rather than shrinking it.
    assert_receive {:attempt, 2, pid2, true}, 60_000

    # A NEW session process — never a reused one — serves the retry.
    assert is_pid(pid1) and is_pid(pid2)
    assert pid1 != pid2

    agent_id = new_agent_id(before_ids)
    assert {:ok, %{retries: 1}} = Store.get_sched_meta(agent_id)

    assert {:ok, %EvoGit.Agent.Result{result: "retry report"}} = Task.await(caller, 60_000)

    # Exactly ONE retry: the counter is read AFTER the run returned, so a second
    # re-dispatch (a retry storm) could not hide behind a race.
    assert :counters.get(counter, 1) == 2

    # Cleanup boundary: both ETS rows are recycled and every session is gone.
    wait_until(
      fn ->
        not MapSet.member?(sched_meta_ids(), agent_id) and
          match?(:error, Store.get_agent_state(agent_id))
      end,
      10_000
    )

    assert Registry.lookup(Session.Registry, agent_id) == []
    refute Process.alive?(pid1)
    refute Process.alive?(pid2)
  end

  test "graceful cancel keeps the run alive and preserves its result through run_agent/2" do
    {repo_root, sha} = init_repo!("b")
    before_ids = sched_meta_ids()
    test_pid = self()

    # The cross-process attempt index (the seam runs in the exchange worker).
    counter = :counters.new(1, [:atomics])

    Application.put_env(:evo_git, :agent_exchange_llm_call, fn context,
                                                               _tools,
                                                               _params,
                                                               _agent_id,
                                                               _retries ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      ref = make_ref()
      worker = self()

      if n == 1 do
        # Hand shake: the session's exchange worker is live and its worktree
        # exists. PARK so the test can cancel while the run is genuinely in
        # flight (a plain-text reply would end the run and never see the flag).
        repo_path = Process.get(:repo_path)

        send(
          test_pid,
          {ref, :agent_running, worker, repo_path, Git.rev_parse(repo_path)}
        )

        receive do
          {^ref, :release} -> :ok
        after
          10_000 -> :ok
        end
      end

      send(test_pid, {:llm_call, n, context_text(context)})

      if n == 1 do
        # A tool call keeps the run alive, so the loop reaches the cancel check
        # at the top of the next turn.
        call = ReqLLM.ToolCall.new("call_cancel_1", "noop", "{}")
        {:ok, llm_response(context, "", [call])}
      else
        # The grace turn: a plain-text reply ends the run and IS the report.
        text = "cancel grace report"
        {:implicit_completion, llm_response(context, text), text}
      end
    end)

    # The `:tool_batch` seam REPLACES the whole standard-call batch: no
    # `EvoGit.ToolRuntime` call, no real tool. The 4-tuple shape is the contract
    # `ToolDispatch.batch_execute_tools/5` returns.
    Application.put_env(:evo_git, :agent_exchange_tool_batch, fn indexed_calls, _state ->
      Enum.map(indexed_calls, fn {call, index} ->
        {index, call.id, ReqLLM.ToolCall.name(call), "ok"}
      end)
    end)

    caller =
      Task.async(fn -> EvoGit.AgentScheduler.run_agent(spec_for(repo_root, sha), 60_000) end)

    assert_receive {ref, :agent_running, worker_pid, worktree_path, head}, 30_000
    assert File.dir?(worktree_path)
    assert head == {:ok, sha}

    agent_id = new_agent_id(before_ids)
    assert {:ok, meta} = Store.get_sched_meta(agent_id)
    session_pid = meta.session_pid
    assert is_pid(session_pid)
    assert is_binary(meta.task_id)
    on_exit(fn -> EvoGit.AgentScheduler.clear_cancelling_task(meta.task_id) end)

    # --- the graceful cancel, while the exchange is parked in its LLM call ---
    assert :ok = EvoGit.AgentScheduler.begin_graceful_cancel(meta.task_id)

    assert Store.cancel_requested?(agent_id) == true
    assert await_phase(session_pid, :cancelling) == true

    # The WORKER is not killed, and the run is still in flight.
    assert Process.alive?(session_pid)
    assert Process.alive?(worker_pid)
    assert %AgentState{status: :cancelling} = Summary.read(agent_id)
    refute Task.yield(caller, 0)

    # Releasing the parked call lets the save-work grace run on this SAME run.
    send(worker_pid, {ref, :release})

    # The seam text is preserved: a graceful cancel is NOT an error outcome.
    assert {:ok, %EvoGit.Agent.Result{} = result} = Task.await(caller, 60_000)
    assert result.result == "cancel grace report"

    # The grace turn re-invoked the LLM AFTER the cancel flag was set, and the
    # cancel message had been drained into that turn's context.
    assert_receive {:llm_call, 2, grace_context_text}, 5_000
    assert grace_context_text =~ "being cancelled by the user"
    assert :counters.get(counter, 1) >= 2

    # NOT asserted here (deliberately out of scope): the task status mapping
    # (`:cancelled` lives in TaskRegistry), and a post-completion summary row.
    # The session publishes its final `:done` row and `recycle_agent/2` deletes
    # it on the `:DOWN`, so the row is not observable from outside — the
    # deterministic terminal observables are the delivered `{:ok, %Result{}}`
    # (never `{:error, :cancelled}`) and the `:cancelling` status seen while
    # parked.
  end

  # --- fixtures -------------------------------------------------------------

  # ONE real git repo per test, at a per-test-unique path.
  defp init_repo!(label) do
    repo_root =
      Path.join(
        System.tmp_dir!(),
        "session_lifecycle_#{label}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo_root)
    on_exit(fn -> File.rm_rf!(repo_root) end)

    {:ok, _} = Git.init(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "initial")
    {:ok, _} = Git.add(repo_root)
    {:ok, _} = Git.commit(repo_root, "initial")
    {:ok, sha} = Git.rev_parse(repo_root)

    {repo_root, sha}
  end

  defp spec_for(repo_root, sha) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: repo_root},
      phylo_node: %PhyloGraphNode{repo: repo_root, base_commit: sha, current_commit: sha},
      agent_module: LifecycleAgent,
      objective: "session lifecycle",
      repo_id: "primary"
    }
  end

  # A plain-text completion response (the shape ReqLLM produces: the assistant
  # message is already appended to the response's own context).
  defp llm_response(context, text, tool_calls \\ nil) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: tool_calls
    }

    %ReqLLM.Response{
      id: "session-lifecycle-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # Every text content part of every message, joined — enough to observe what a
  # scripted LLM call was handed.
  defp context_text(%ReqLLM.Context{messages: messages}) when is_list(messages) do
    messages
    |> Enum.map(&message_text/1)
    |> Enum.join("\n")
  end

  defp context_text(_context), do: ""

  defp message_text(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp message_text(%ReqLLM.Message{content: content}) when is_binary(content), do: content
  defp message_text(_message), do: ""

  # --- scheduler row discovery ---------------------------------------------

  defp sched_meta_ids do
    MapSet.new(Store.list_sched_meta(), fn {id, _meta} -> id end)
  end

  defp new_agent_id(before_ids) do
    ids =
      sched_meta_ids()
      |> MapSet.difference(before_ids)
      |> MapSet.to_list()

    assert [agent_id] = ids
    agent_id
  end

  # --- bounded waits --------------------------------------------------------

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

  # Bounded poll on the session's own phase (`:cancelling` is set synchronously
  # by `begin_graceful_cancel/1`, so this only absorbs scheduling latency).
  defp await_phase(pid, phase, timeout \\ 2_000) do
    do_await_phase(pid, phase, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_await_phase(pid, phase, deadline) do
    case Session.inspect(pid, 200) do
      {:ok, %{phase: ^phase}} ->
        true

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_await_phase(pid, phase, deadline)
        else
          false
        end
    end
  end

  # --- app env --------------------------------------------------------------

  # Restore a seam nil-aware: delete the key when it was originally unset, so
  # the production (default-inert) path is left byte-identical.
  defp restore_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_env(key, value), do: Application.put_env(:evo_git, key, value)
end
