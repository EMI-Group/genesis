defmodule EvoGit.Agent.Session.PauseTest.StubAgent do
  @moduledoc """
  The role a paused session runs AS.

  A real `EvoGit.Agent` implementation is required because
  `EvoGit.Agent.Session.Setup.build_initial_state/3` calls the role's
  `system_prompt/0`, `available_tools/0` and `delegation_level/0`. The tool list
  is deliberately EMPTY: every exchange here is driven end-to-end by the engine
  seams (`:llm_call` / `:tool_batch`), so no tool schema is ever dispatched
  against a real callback.

  Defined ABOVE the `async: true` test module on purpose: `mix test` starts the
  ExUnit async runner BEFORE requiring the test files, so a helper defined after
  the test module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the session-pause stub agent."

  @doc "No tools: the scripted turns come from the seams, never from a schema."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.PauseTest do
  @moduledoc """
  The SESSION half of TASK-LEVEL PAUSE: what a real `EvoGit.Agent.Session`
  process does with the engine's `{:pause, %State{}}` outcome.

  ## What these tests pin

  1. `EvoGit.Agent.Session.Outcome.classify/3` — `:running` + `{:pause, state}`
     is `{:pause, state}` for BOTH modes, while the same outcome in
     `:cancelling` / `:awaiting_input` / `:finalizing` is `{:unexpected, _}`.
  2. A REAL repo-backed paused run delivers exactly ONE terminal
     `{:agent_session_result, agent_id, pid, {:paused, info}}` to the scheduler
     pid of the dispatch context, where `info` carries a NON-NIL `checkpoint`
     commit that is REACHABLE (anchored under `refs/genesis/salvage/<branch>`)
     and whose tree contains the file the run wrote.
  3. The same sha is the run's durable `pause_commit`, the durable row keeps the
     conversation, the run is still RESUMABLE (never marked completed) and the
     agent summary row is `:done` — no `%EvoGit.Agent.Result{}` is produced.
  4. The pause finalizer's worktree checkpoint is anchored, so it survives the
     reclaim that follows the session's stop.
  5. An exchange worker killed ABRUPTLY while the pause flag is set converts to
     a PAUSE (the scheduler's pause slot purge shape) instead of a crash; the
     SAME kill without the flag keeps today's crash behaviour (the scheduler
     sees the abnormal exit and no result is delivered).

  ## Why `async: true` is safe

  The pinned tables (`:evogit_agent_summary`, `:evogit_sched_meta`,
  `:evogit_agent_control`, `task_agent_archives`) are BEAM-global, so every test
  uses a PER-TEST UNIQUE agent id (`10_020_000 + unique_integer`) and task id,
  works in its own temp git repository (so the app-global `WorktreeManager`'s
  per-repo state is keyed to a unique path), and deletes exactly the rows it
  created in `on_exit`; nothing here wipes or counts a table wholesale, mutates
  an app-env key or touches `:persistent_term`.
  The durable `agent_state.sqlite` is per-RUN scratch (`config/test.exs` pins a
  unique `:data_dir`), and each test owns a unique `task_id`, so the app-booted
  `EvoGit.AgentState` server is shared safely.
  Every session is given `scheduler: self()` in its dispatch context, so a run's
  ONE terminal result is delivered to the TEST instead of the app-global
  scheduler, and every wait is EVENT-DRIVEN (the terminal message, the monitor
  `:DOWN`) or a bounded poll that only absorbs scheduling latency.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.Outcome
  alias EvoGit.Agent.Session.PauseTest.StubAgent
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentScheduler.AgentState, as: SchedulerRow
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentScheduler.Salvage
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A range of its own: the summary/control tables are shared with every
  # concurrently running module, so the only safe key is a unique one.
  @agent_id_base 10_020_000

  # The shared host's scheduling swings several-fold under parallel load, so
  # EVERY wait in this module uses this one budget. It only absorbs that
  # latency — each awaited event is reachable by construction, and every wait
  # still FAILS (never silently passes) when it is not.
  @async_wait_budget_ms 30_000

  @objective "session pause objective sentinel"
  @pause_file "pause_notes.txt"
  @pause_content "work done before the pause\n"

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    task_id = "session-pause-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_pause_#{agent_id}")
    File.mkdir_p!(tmp_dir)
    repo_root = Path.join(tmp_dir, "repo")
    base_commit = init_repo!(repo_root)
    worktree_path = Path.join([repo_root, ".genesis/workers", "worker_T1_A1"])

    spec = repo_backed_spec(repo_root, base_commit, tmp_dir)
    meta = sched_meta(agent_id, task_id, spec)

    :ok = SchedStore.put_agent_state(agent_id, agent_state(repo_root, task_id))
    :ok = SchedStore.put_sched_meta(agent_id, meta)

    # A session process can only reach the NAMED durable-state server, so pin
    # THAT pid here and make every read-backed assertion go through it.
    server = Process.whereis(EvoGit.AgentState.Server)
    assert is_pid(server)
    Process.put(:evogit_agent_state_server, server)

    on_exit(fn ->
      # `on_exit` runs in a DIFFERENT process, so it passes the server
      # explicitly instead of relying on the pinned process dictionary.
      AgentState.delete(task_id, agent_id, store: server)
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{
      agent_id: agent_id,
      task_id: task_id,
      tmp_dir: tmp_dir,
      repo_root: repo_root,
      base_commit: base_commit,
      worktree_path: worktree_path,
      spec: spec,
      meta: meta,
      server: server
    }
  end

  describe "Outcome.classify/3 — the pause verdict" do
    test "a pause while RUNNING is the pause verdict in BOTH modes" do
      state = pause_state()

      assert Outcome.classify(:running, :oneshot, {:pause, state}) == {:pause, state}
      assert Outcome.classify(:running, :interactive, {:pause, state}) == {:pause, state}
    end

    test "a pause in any other phase is LOUD (never a silent park)" do
      state = pause_state()

      for phase <- [:cancelling, :awaiting_input, :finalizing] do
        for mode <- [:oneshot, :interactive] do
          assert Outcome.classify(phase, mode, {:pause, state}) ==
                   {:unexpected, {:pause, state}}
        end
      end
    end
  end

  describe "a real paused run" do
    test "delivers ONE paused outcome with a reachable checkpoint and stays resumable",
         %{
           agent_id: agent_id,
           task_id: task_id,
           repo_root: repo_root,
           base_commit: base_commit,
           worktree_path: worktree_path,
           server: server
         } = ctx do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(ctx,
            llm_call: tool_calling_llm(self()),
            tool_batch: pausing_tool_batch(agent_id, worktree_path, self())
          )
        )

      # (a) ONE terminal delivery, and it is the PAUSED term — never a
      # `%Result{}` and never an error.
      assert_receive {:agent_session_result, ^agent_id, ^pid, {:paused, info}},
                     @async_wait_budget_ms

      # (b) The checkpoint commit is real, REACHABLE and contains the file the
      # run wrote. `checkpoint_for_pause/1` anchors it under
      # `refs/genesis/salvage/<branch>`, which is what survives the reclaim.
      assert %{agent_id: ^agent_id, task_id: ^task_id, reason: :task_pause} = info
      checkpoint = info.checkpoint
      assert is_binary(checkpoint)
      assert Salvage.commit_exists?(repo_root, checkpoint)

      assert {:ok, anchored} =
               Git.run(["rev-parse", "refs/genesis/salvage/#{info.branch}"], repo_root)

      assert String.trim(anchored) == checkpoint

      assert {:ok, content} = Git.run(["show", "#{checkpoint}:#{@pause_file}"], repo_root)
      assert String.trim(content) == String.trim(@pause_content)

      # The commit is NOT the task base: the pause preserved real work.
      refute checkpoint == base_commit

      # (c) The same sha is the durable pause marker of the run.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @async_wait_budget_ms
      AgentState.flush(server)
      assert AgentState.pause_commit(task_id, agent_id) == checkpoint

      # (d) The conversation is durable: system + objective + the assistant
      # tool-call message + its tool result.
      assert {:ok, %EvoGit.AgentState.Record{} = record} =
               AgentState.load(task_id, agent_id)

      assert Enum.map(record.messages, & &1.role) == [:system, :user, :assistant, :tool]

      assert hd(record.messages).content |> Enum.map_join(&(Map.get(&1, :text) || "")) =~
               "session-pause stub agent"

      # (e) Still RESUMABLE: the pause path never marks the run completed
      # (`maybe_mark_completed/1` skips a `{:paused, _}` result).
      assert record.completed_at == nil
      assert record.fields[:status] == "running"

      assert [%EvoGit.AgentState.Record{agent_id: ^agent_id, fields: %{status: "running"}}] =
               AgentState.roster(task_id)

      # (f) The agent summary row lands `:done` with the checkpoint sha surfaced
      # and no `%Result{}` anywhere in the terminal delivery.
      row = EvoGit.Agent.Session.Summary.read(agent_id)
      assert %SchedulerRow{status: :done, current_commit: ^checkpoint} = row
      # ONE delivery only, and never the `{:ok, %Result{}}` success term.
      refute_receive {:agent_session_result, ^agent_id, ^pid, {:ok, %Result{}}}, 100
      refute_receive {:agent_session_result, ^agent_id, ^pid, _other}, 0
    end

    test "the anchored checkpoint survives the worktree reclaim",
         %{agent_id: agent_id, repo_root: repo_root, worktree_path: worktree_path} = ctx do
      {:ok, pid, ref} =
        start_session(
          dispatch_ctx(ctx,
            llm_call: tool_calling_llm(self()),
            tool_batch: pausing_tool_batch(agent_id, worktree_path, self())
          )
        )

      assert_receive {:agent_session_result, ^agent_id, ^pid, {:paused, info}},
                     @async_wait_budget_ms

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @async_wait_budget_ms
      checkpoint = info.checkpoint
      assert is_binary(checkpoint)

      # The manager reclaims the worktree as its reaction to the session's
      # `:DOWN`; the branch dies with it, the anchored commit does not.
      wait_until(fn -> not File.exists?(worktree_path) end, @async_wait_budget_ms)
      refute File.exists?(worktree_path)
      assert Salvage.commit_exists?(repo_root, checkpoint)
      assert {:ok, content} = Git.run(["show", "#{checkpoint}:#{@pause_file}"], repo_root)
      assert String.trim(content) == String.trim(@pause_content)
    end
  end

  describe "an exchange worker aborted abnormally" do
    test "converts to a pause when the pause flag is set",
         %{agent_id: agent_id, repo_root: repo_root} = ctx do
      {:ok, pid, ref} = start_session(dispatch_ctx(ctx, llm_call: blocking_llm_call(self())))

      # The worker is parked inside its LLM call: this is the shape the
      # scheduler's pause slot purge produces (`{:error, :paused}` raised inside
      # `with_llm_slot/2`), i.e. an ABNORMAL exit instead of a `{:pause, _}`.
      assert_receive {:llm_blocked, worker}, @async_wait_budget_ms
      :ok = ControlPlane.set_pause(agent_id, true)
      Process.exit(worker, :kill)

      # The flag wins over the exit reason: a paused delivery, never a crash.
      assert_receive {:agent_session_result, ^agent_id, ^pid, {:paused, info}},
                     @async_wait_budget_ms

      assert %{agent_id: ^agent_id, reason: :task_pause} = info
      # The last CHECKPOINTED state is the pause base; the worktree is clean, so
      # the checkpoint is the current HEAD sha of the (still owned) worktree.
      assert is_binary(info.checkpoint)
      assert Salvage.commit_exists?(repo_root, info.checkpoint)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @async_wait_budget_ms
      refute_receive {:agent_session_result, ^agent_id, ^pid, _other}, 100
    end

    test "keeps today's crash behaviour when no pause is requested",
         %{agent_id: agent_id} = ctx do
      {:ok, pid, ref} = start_session(dispatch_ctx(ctx, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, @async_wait_budget_ms
      assert ControlPlane.pause_requested?(agent_id) == false
      Process.exit(worker, :kill)

      # The abnormal exit is what the scheduler's crash/retry path must see: the
      # session dies with it and NO result is delivered.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, @async_wait_budget_ms
      assert reason != :normal
      refute_receive {:agent_session_result, ^agent_id, ^pid, _other}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # Harness — a repo-backed session with real ETS registration rows
  # ---------------------------------------------------------------------------

  # A minimal, VALID `%State{}` for the pure classification units (`%State{}`
  # enforces its identity/conversation keys).
  defp pause_state do
    %State{
      agent_id: 1,
      agent_module: StubAgent,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([ReqLLM.Context.user(@objective)])
    }
  end

  defp agent_state(repo_root, _task_id) do
    %SchedulerRow{
      context_node: context_node(repo_root),
      objective: @objective,
      parent_id: nil,
      # Archive is read from THIS row by the completion builder; `false` keeps
      # the archive writer out of a paused run entirely.
      archive: false,
      llm_model: "test:model",
      model_id: "session-pause-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: 8,
      repo_id: "primary",
      repo_root: repo_root,
      # `WorktreeManager` derives the branch name from these two numbers.
      task_local_id: 1,
      llm_context_window: 200_000
    }
  end

  defp repo_backed_spec(repo_root, sha, tmp_dir) do
    %AgentSpec{
      context_node: context_node(repo_root),
      phylo_node: %PhyloGraphNode{repo: repo_root, base_commit: sha, current_commit: sha},
      agent_module: StubAgent,
      objective: @objective,
      repo_id: "primary",
      opts: [task_tmpdir: tmp_dir]
    }
  end

  defp sched_meta(agent_id, task_id, spec) do
    %SchedMeta{
      id: agent_id,
      depth: 0,
      task_id: task_id,
      task_number: 1,
      spec: spec,
      from: {self(), make_ref()}
    }
  end

  defp dispatch_ctx(ctx, opts) do
    [
      agent_id: ctx.agent_id,
      depth: 0,
      repo_root: ctx.repo_root,
      repo_id: "primary",
      worktree_path: ctx.worktree_path,
      retries: 0,
      spec: ctx.spec,
      meta: ctx.meta,
      # NO `repo_less` key: `Session.Setup.bind_worktree/2` performs the REAL
      # `WorktreeManager` create, whose owner pid is this SESSION.
      notify: self(),
      # A TEST-OWNED scheduler sink, so the ONE terminal result lands in the
      # test instead of the app-global scheduler.
      scheduler: self(),
      exchange_opts:
        [llm_call: Keyword.fetch!(opts, :llm_call)]
        |> maybe_put_tool_batch(Keyword.get(opts, :tool_batch))
    ]
  end

  defp maybe_put_tool_batch(seams, nil), do: seams
  defp maybe_put_tool_batch(seams, tool_batch), do: seams ++ [tool_batch: tool_batch]

  defp start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, pid, ref}
  end

  # Turn 1 asks for ONE tool call (the pause is honoured at the BATCH boundary,
  # i.e. after a real batch ran); a second turn would reply with plain text and
  # must never be reached.
  defp tool_calling_llm(test_pid) do
    fn context, _tools, _params, agent_id, _retries ->
      send(test_pid, {:llm_call, agent_id})

      if assistant_message_count(context) == 0 do
        {:ok,
         response(
           context,
           assistant_message("Writing the pause notes.", [
             ReqLLM.ToolCall.new(
               "call_pause_write",
               "read",
               Jason.encode!(%{"path" => "./#{@pause_file}"})
             )
           ])
         )}
      else
        {:implicit_completion, response(context, assistant_message("done", nil)), "done"}
      end
    end
  end

  # The `:tool_batch` engine seam REPLACES the whole standard-call batch: this is
  # where the run does its REAL work (a file in its own worktree) and where the
  # task-level pause is requested — DURING the batch, so the pause is honoured
  # at the BATCH boundary right after both results are appended.
  defp pausing_tool_batch(agent_id, worktree_path, test_pid) do
    fn indexed_calls, _state ->
      File.write!(Path.join(worktree_path, @pause_file), @pause_content)
      :ok = ControlPlane.set_pause(agent_id, true)
      send(test_pid, {:tool_batch, length(indexed_calls)})

      Enum.map(indexed_calls, fn {call, index} ->
        {index, call.id, ReqLLM.ToolCall.name(call), "wrote ./#{@pause_file}"}
      end)
    end
  end

  defp response(context, message) do
    %ReqLLM.Response{
      id: "session-pause-response",
      model: "test:model",
      # ReqLLM's response builder appends the assistant message to the context.
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  defp assistant_message(text, tool_calls) do
    %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: tool_calls
    }
  end

  defp assistant_message_count(%ReqLLM.Context{messages: messages}),
    do: Enum.count(messages, &(&1.role == :assistant))

  defp blocking_llm_call(test_pid) do
    fn _context, _tools, _params, _agent_id, _retries ->
      send(test_pid, {:llm_blocked, self()})

      receive do
        :release -> {:error, :released}
      after
        30_000 -> {:error, :release_timeout}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Repository fixtures
  # ---------------------------------------------------------------------------

  defp context_node(repo), do: %ContextNode{path: "./", repo: repo}

  defp init_repo!(repo_root) do
    File.mkdir_p!(repo_root)
    {:ok, _} = Git.init(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "initial\n")
    {:ok, _} = Git.add(repo_root)
    {:ok, _} = Git.commit(repo_root, "initial")
    {:ok, sha} = Git.rev_parse(repo_root)
    sha
  end

  # ---------------------------------------------------------------------------
  # Bounded waits
  # ---------------------------------------------------------------------------

  defp wait_until(fun, timeout), do: wait_until_loop(fun, deadline(timeout))

  defp wait_until_loop(fun, deadline) do
    cond do
      fun.() -> :ok
      remaining(deadline) <= 0 -> flunk("condition not met within the wait budget")
      true -> Process.sleep(10) && wait_until_loop(fun, deadline)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
