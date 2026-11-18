defmodule EvoGit.Agent.Session.DurableRunSessionTest.StubAgent do
  @moduledoc """
  The `:oneshot` role the durable-run session fixtures execute AS.

  A real `EvoGit.Agent` implementation is required because
  `EvoGit.Agent.Session.Setup.build_initial_state/3` calls the role's
  `system_prompt/0`, `available_tools/0` and `delegation_level/0`. The tool list
  is deliberately EMPTY: every exchange is driven by the engine seams
  (`:llm_call` / `:tool_batch`), so no tool schema is ever dispatched.

  Defined ABOVE the test module on purpose — `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the one-shot stub role."
  def system_prompt, do: "You are the durable-run session stub agent."

  @doc "No tools: the scripted turns come from the seams, never from a schema."
  def available_tools, do: []
end

defmodule EvoGit.Agent.Session.DurableRunSessionTest.InteractiveAgent do
  @moduledoc """
  The `:interactive` role: a tool-free reply YIELDS, so the session parks in
  `:awaiting_input` instead of completing — the state in which a run's durable
  row (and its `anchor_ref`) must still be readable.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the interactive stub role."
  def system_prompt, do: "You are the durable-run session interactive stub agent."

  @doc "No tools: the scripted turns come from the seams, never from a schema."
  def available_tools, do: []

  @doc "The opt-in: this role can be parked and resumed across exchanges."
  def session_mode, do: :interactive
end

defmodule EvoGit.Agent.Session.DurableRunSessionTest do
  @moduledoc """
  SESSION-LEVEL wiring of the durable RUN FACTS
  (`docs/agent-run-durability.md`): what a REAL `EvoGit.Agent.Session` process
  writes into `agent_state.sqlite`.

  Pinned here:

    1. the INITIAL snapshot exists BEFORE the first turn — one durable row per
       running agent from the moment it starts — carrying the durable run facts
       (`branch`, `base_commit`, `spawn_turn`, `spawn_index`) from the dispatch
       context plus the `redispatch` blob, with `status: "running"`;
    2. a ROOT's row is DROPPED at completion while a CHILD keeps its `done` row
       (and its spawn position) until the parent's batch-clearing checkpoint;
    3. `persistent_state: false` writes nothing at all — no row and no anchor —
       even on a real repository whose HEAD an agent moved;
    4. a checkpoint that ADVANCES `current_commit` anchors the commit at
       `refs/genesis/agent-state/<task_id>/<agent_id>` (fire-and-forget), and
       that ref keeps the work reachable after the worktree, the
       `evogit-agent-*` branch and `.genesis/workers` are gone.

  ## Why `async: true` is safe

  The pinned tables (`:evogit_agent_summary`, `:evogit_sched_meta`,
  `:evogit_agent_control`) and `agent_state.sqlite` are BEAM-global, so every
  test uses a PER-TEST UNIQUE agent id (`10_060_000 + unique_integer`) and task
  id, works in its own temp git repository (so the app-global
  `WorktreeManager`'s per-repo state is keyed to a unique path), and deletes
  exactly the rows it created in `on_exit`. No app-env key, Logger level,
  `:persistent_term` entry or PubSub topic is mutated, and nothing asserts on a
  table as a whole.

  ## Event-driven waits only

  Every wait is anchored on a persistent fact: the terminal delivery, the
  worker's own notice, the monitor `:DOWN`, or a bounded poll of
  `EvoGit.AgentState.load/3` / the anchored ref — never a sleep as an
  assertion. The single `@wait_ms` budget only absorbs host scheduling latency.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.DurableRunSessionTest.InteractiveAgent
  alias EvoGit.Agent.Session.DurableRunSessionTest.StubAgent
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Anchor
  alias EvoGit.AgentScheduler.AgentState, as: SchedulerRow
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A range of its own: the summary/meta tables are shared with every
  # concurrently running module, so the only safe key is a unique one.
  @agent_id_base 10_060_000
  @wait_ms 30_000
  @objective "durable run session objective sentinel"
  @report "durable run session report"
  @work_file "durable_run_work.txt"
  @work_content "work committed by the agent's tool batch\n"
  # A synthetic parent for the CHILD fixtures (no session ever starts for it).
  @parent_id 424_242

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    task_id = "durable-run-session-#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_durable_run_session_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    repo_root = Path.join(tmp_dir, "repo")
    base_commit = init_repo!(repo_root)

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
      server: server
    }
  end

  describe "the initial snapshot at session start" do
    test "writes ONE durable row with its run facts BEFORE the first turn", ctx do
      {:ok, pid, ref} =
        start_session(
          repo_less_ctx(ctx,
            llm_call: blocking_llm_call(self()),
            branch: "evogit-agent-T1-A1",
            base_commit: ctx.base_commit
          )
        )

      # The run parks INSIDE its first LLM call: no turn boundary has happened
      # yet, so anything on disk right now came from the initial snapshot.
      assert_receive {:llm_blocked, worker}, @wait_ms

      record = await_row!(ctx.task_id, ctx.agent_id)

      assert record.fields[:status] == "running"
      assert record.fields[:turn] == 0
      assert record.completed_at == nil
      # The whole (system + objective) conversation, in ONE rewrite chunk.
      assert record.message_count == 2
      assert record.chunk_count == 1
      assert Enum.map(record.messages, & &1.role) == [:system, :user]

      # The durable run facts of a ROOT: no spawn position, but the branch and
      # base its worktree was created from.
      assert record.fields[:branch] == "evogit-agent-T1-A1"
      assert record.fields[:base_commit] == ctx.base_commit
      assert record.fields[:spawn_turn] == nil
      assert record.fields[:spawn_index] == nil

      # The rebuild blob is a non-empty STRING-keyed map (JSON-clean by
      # construction — the column is Jason-encoded).
      redispatch = record.fields[:redispatch]
      assert is_map(redispatch) and map_size(redispatch) > 0
      assert redispatch["parent_id"] == nil
      assert redispatch["objective"] == @objective
      assert redispatch["repo_less"] == true
      assert redispatch["task_number"] == 1
      assert redispatch["spawn_turn"] == nil

      # Release the turn: the run completes, and a ROOT's row is dropped —
      # nothing consumes a root's result.
      send(worker, :release)
      assert_receive {:agent_session_result, agent_id, ^pid, {:ok, _result}}, @wait_ms
      assert agent_id == ctx.agent_id
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @wait_ms

      assert await_gone!(ctx.task_id, ctx.agent_id)
      assert AgentState.roster(ctx.task_id) == []
    end

    test "carries the SPAWN TURN/INDEX of a child batch", ctx do
      :ok = SchedStore.put_agent_state(ctx.agent_id, scheduler_row(ctx, parent_id: @parent_id))

      {:ok, pid, ref} =
        start_session(
          repo_less_ctx(ctx,
            agent_module: InteractiveAgent,
            llm_call: blocking_llm_call(self()),
            parent_id: @parent_id,
            depth: 1,
            spawn_turn: 3,
            spawn_index: 1
          )
        )

      assert_receive {:llm_blocked, _worker}, @wait_ms

      record = await_row!(ctx.task_id, ctx.agent_id)

      assert record.fields[:status] == "running"
      assert record.fields[:parent_id] == @parent_id
      assert record.fields[:depth] == 1
      assert record.fields[:spawn_turn] == 3
      assert record.fields[:spawn_index] == 1

      # The spawn position a later resume cannot re-derive also lives in the
      # rebuild blob.
      assert record.fields[:redispatch]["parent_id"] == @parent_id
      assert record.fields[:redispatch]["spawn_turn"] == 3
      assert record.fields[:redispatch]["spawn_index"] == 1

      # A force kill is NOT a completion: the row survives with the live status
      # and no completed marking.
      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, @wait_ms

      AgentState.flush()
      assert {:ok, record} = AgentState.load(ctx.task_id, ctx.agent_id)
      assert record.fields[:status] == "running"
      assert record.completed_at == nil
    end
  end

  describe "persistent_state: false" do
    test "writes no row and no anchor, even on a repository the run moved", ctx do
      {:ok, pid, ref} =
        start_session(
          repo_backed_ctx(ctx,
            agent_module: InteractiveAgent,
            llm_call: committing_llm(self()),
            tool_batch: committing_tool_batch(ctx),
            persistent_state: false
          )
        )

      assert_receive {:tool_batch, _batch_size}, @wait_ms
      assert await_phase(pid, :awaiting_input)
      # The worktree HEAD really moved (the run committed real work).
      assert {:ok, head} = Git.rev_parse(ctx.repo_root, "evogit-agent-T1-A1")
      assert head != ctx.base_commit

      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, @wait_ms

      AgentState.flush()

      # FULLY inert: no durable row at all, and no anchor ref for this task.
      assert AgentState.roster(ctx.task_id) == []
      assert AgentState.load(ctx.task_id, ctx.agent_id) == {:error, :not_found}
      refute anchored?(ctx.repo_root, ctx.task_id)
    end
  end

  describe "git anchoring through the session path" do
    test "anchors the commit a tool batch advanced and it survives reclamation", ctx do
      {:ok, pid, ref} =
        start_session(
          repo_backed_ctx(ctx,
            agent_module: InteractiveAgent,
            llm_call: committing_llm(self()),
            tool_batch: committing_tool_batch(ctx)
          )
        )

      assert_receive {:tool_batch, _batch_size}, @wait_ms
      assert await_phase(pid, :awaiting_input)

      anchor_ref = "refs/genesis/agent-state/#{ctx.task_id}/#{ctx.agent_id}"
      assert Anchor.ref(ctx.task_id, ctx.agent_id) == anchor_ref

      {:ok, head} = Git.rev_parse(ctx.repo_root, "evogit-agent-T1-A1")
      assert head != ctx.base_commit
      assert wait_for_ref(ctx.repo_root, anchor_ref, head) == {:ok, head}

      # The row records the ref, so a later resume knows where the work is.
      record = await_row!(ctx.task_id, ctx.agent_id)
      assert record.fields[:anchor_ref] == anchor_ref
      assert record.fields[:current_commit] == head
      assert record.fields[:branch] == "evogit-agent-T1-A1"
      assert record.fields[:base_commit] == ctx.base_commit

      # Simulate a BEAM restart + reclamation: the session stops (the manager
      # reclaims its worktree and the agent branch), the workers tree is wiped
      # and the repository is garbage collected.
      assert :ok = Session.cancel(pid, :force)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, @wait_ms
      wait_until(fn -> not File.exists?(ctx.repo_root |> worktree_path()) end, @wait_ms)
      _ = Git.delete_branch(ctx.repo_root, "evogit-agent-T1-A1")
      File.rm_rf!(Path.join(ctx.repo_root, ".genesis/workers"))
      assert {:ok, _} = Git.run(["gc", "--prune=now", "--quiet"], ctx.repo_root)

      # The anchor still names the commit and the commit object is alive —
      # the session's checkpoint is what kept it reachable.
      assert Git.rev_parse(ctx.repo_root, anchor_ref) == {:ok, head}
      assert commit_exists?(ctx.repo_root, head)
      assert {:ok, content} = Git.run(["show", "#{head}:#{@work_file}"], ctx.repo_root)
      assert String.trim(content) == String.trim(@work_content)
    end
  end

  # ---------------------------------------------------------------------------
  # Harness — dispatch contexts, real ETS registration rows, sessions
  # ---------------------------------------------------------------------------

  # A repo-less run: no worktree, but the ctx still carries the run facts.
  defp repo_less_ctx(ctx, opts) do
    agent_module = Keyword.get(opts, :agent_module, StubAgent)

    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      agent_module: agent_module,
      objective: @objective,
      opts: [repo_less: true, task_tmpdir: ctx.tmp_dir]
    }

    :ok = SchedStore.put_agent_state(ctx.agent_id, scheduler_row(ctx, opts))
    :ok = SchedStore.put_sched_meta(ctx.agent_id, sched_meta(ctx, spec))

    base_ctx(ctx, spec, opts) ++
      [
        repo_less: true,
        repo_less_repo_path: ctx.tmp_dir,
        worktree_path: Path.join(ctx.tmp_dir, "worker")
      ]
  end

  # A repo-backed run: `Session.Setup.bind_worktree/2` performs the REAL
  # `WorktreeManager` create, whose owner pid is the session.
  defp repo_backed_ctx(ctx, opts) do
    agent_module = Keyword.get(opts, :agent_module, StubAgent)

    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: ctx.repo_root},
      phylo_node: %PhyloGraphNode{
        repo: ctx.repo_root,
        base_commit: ctx.base_commit,
        current_commit: ctx.base_commit
      },
      agent_module: agent_module,
      objective: @objective,
      repo_id: "primary",
      opts: [task_tmpdir: ctx.tmp_dir]
    }

    :ok = SchedStore.put_agent_state(ctx.agent_id, scheduler_row(ctx, opts))
    :ok = SchedStore.put_sched_meta(ctx.agent_id, sched_meta(ctx, spec))

    base_ctx(ctx, spec, opts) ++ [worktree_path: worktree_path(ctx.repo_root)]
  end

  # The keys BOTH contexts share. `:branch` / `:base_commit` / `:spawn_turn` /
  # `:spawn_index` are the dispatch-ctx contract the session turns into durable
  # run facts.
  defp base_ctx(ctx, spec, opts) do
    [
      agent_id: ctx.agent_id,
      depth: Keyword.get(opts, :depth, 0),
      repo_root: ctx.repo_root,
      repo_id: "primary",
      retries: 0,
      spec: spec,
      meta: sched_meta(ctx, spec),
      branch: Keyword.get(opts, :branch, "evogit-agent-T1-A1"),
      base_commit: Keyword.get(opts, :base_commit, ctx.base_commit),
      spawn_turn: Keyword.get(opts, :spawn_turn),
      spawn_index: Keyword.get(opts, :spawn_index),
      persistent_state: Keyword.get(opts, :persistent_state, true),
      # Test-owned sinks: the terminal result/yield notices land in THIS process
      # instead of the app-global scheduler, which this direct start never uses.
      notify: self(),
      scheduler: self(),
      exchange_opts:
        [llm_call: Keyword.fetch!(opts, :llm_call)] ++
          maybe_seam(:tool_batch, Keyword.get(opts, :tool_batch))
    ]
  end

  defp maybe_seam(_key, nil), do: []
  defp maybe_seam(key, fun), do: [{key, fun}]

  defp worktree_path(repo_root), do: Path.join([repo_root, ".genesis/workers", "worker_T1_A1"])

  # The pre-installed scheduler SUMMARY row the session reads its identity/model
  # fields from. A missing row makes the session finalize with
  # `{:error, :not_registered}`.
  defp scheduler_row(ctx, opts) do
    %SchedulerRow{
      context_node: %ContextNode{path: "./", repo: ctx.repo_root},
      objective: @objective,
      parent_id: Keyword.get(opts, :parent_id),
      archive: false,
      llm_model: "test:model",
      model_id: "durable-run-session-test",
      max_turns: 128,
      max_retries: 3,
      max_depth: 8,
      repo_id: "primary",
      repo_root: ctx.repo_root,
      # `WorktreeManager` derives the branch name from these two numbers.
      task_local_id: 1,
      llm_context_window: 200_000
    }
  end

  defp sched_meta(ctx, spec) do
    %SchedMeta{
      id: ctx.agent_id,
      depth: 0,
      task_id: ctx.task_id,
      task_number: 1,
      spec: spec,
      from: {self(), make_ref()}
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
  # Scripted engine seams
  # ---------------------------------------------------------------------------

  # Turn 1 asks for ONE tool call (so a real batch boundary happens); a second
  # turn replies with plain text, which YIELDS for the interactive role.
  defp committing_llm(_test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      if assistant_message_count(context) == 0 do
        {:ok,
         response(
           context,
           assistant_message("Committing the work.", [
             ReqLLM.ToolCall.new(
               "call_durable_run_write",
               "read",
               Jason.encode!(%{"path" => "./#{@work_file}"})
             )
           ])
         )}
      else
        {:implicit_completion, response(context, assistant_message("done", nil)), "done"}
      end
    end
  end

  # The `:tool_batch` engine seam REPLACES the whole standard-call batch: this is
  # where the run does its REAL work — a commit in its own worktree — and where
  # the post-tool HEAD is carried onto the checkpointed state exactly like
  # `EvoGit.Agent.ToolDispatch.sync_current_commit_after_tools/1` does.
  defp committing_tool_batch(ctx) do
    test_pid = self()

    fn indexed_calls, _state ->
      File.write!(Path.join(worktree_path(ctx.repo_root), @work_file), @work_content)
      {:ok, _} = Git.add(worktree_path(ctx.repo_root))
      {:ok, _} = Git.commit(worktree_path(ctx.repo_root), "durable run work")
      {:ok, sha} = Git.rev_parse(worktree_path(ctx.repo_root))
      Process.put(:evogit_current_commit, sha)
      send(test_pid, {:tool_batch, length(indexed_calls)})

      Enum.map(indexed_calls, fn {call, index} ->
        {index, call.id, ReqLLM.ToolCall.name(call), "wrote ./#{@work_file}"}
      end)
    end
  end

  defp blocking_llm_call(test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      send(test_pid, {:llm_blocked, self()})

      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end

      {:implicit_completion, response(context, assistant_message(@report, nil)), @report}
    end
  end

  defp response(context, message) do
    %ReqLLM.Response{
      id: "durable-run-session-response",
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

  # ---------------------------------------------------------------------------
  # Repository fixtures
  # ---------------------------------------------------------------------------

  defp init_repo!(repo_root) do
    File.mkdir_p!(repo_root)
    {:ok, _} = Git.init(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "initial\n")
    {:ok, _} = Git.add(repo_root)
    {:ok, _} = Git.commit(repo_root, "initial")
    {:ok, sha} = Git.rev_parse(repo_root)
    sha
  end

  defp commit_exists?(repo, sha) do
    match?({:ok, _}, Git.run(["cat-file", "-e", sha <> "^{commit}"], repo))
  end

  defp anchored?(repo, task_id) do
    case Git.run(["for-each-ref", "refs/genesis/agent-state"], repo) do
      {:ok, output} -> String.contains?(output, task_id)
      {:error, _} -> false
    end
  end

  # Bounded poll: `Anchor.anchor/4` is fire-and-forget, so the ref lands
  # asynchronously in a supervised task.
  defp wait_for_ref(repo, ref_name, expected, attempts \\ 600) do
    case Git.rev_parse(repo, ref_name) do
      {:ok, ^expected} = ok ->
        ok

      other ->
        if attempts > 0 do
          Process.sleep(10)
          wait_for_ref(repo, ref_name, expected, attempts - 1)
        else
          other
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Bounded, event-driven waits
  # ---------------------------------------------------------------------------

  defp await_row!(task_id, agent_id, attempts \\ 600) do
    AgentState.flush()

    case AgentState.load(task_id, agent_id) do
      {:ok, record} ->
        record

      {:error, :not_found} when attempts > 0 ->
        Process.sleep(10)
        await_row!(task_id, agent_id, attempts - 1)

      other ->
        flunk("expected a durable row for #{task_id}/#{agent_id}, got #{inspect(other)}")
    end
  end

  # A dropped ROOT row: bounded poll for the ABSENCE the completion contract
  # produces (the delete is a cast, so a single read could still see it).
  defp await_gone!(task_id, agent_id, attempts \\ 600) do
    AgentState.flush()

    case AgentState.load(task_id, agent_id) do
      {:error, :not_found} ->
        true

      {:ok, _record} when attempts > 0 ->
        Process.sleep(10)
        await_gone!(task_id, agent_id, attempts - 1)

      other ->
        flunk("expected the ROOT row of #{task_id}/#{agent_id} to be gone, got #{inspect(other)}")
    end
  end

  # The phase transition is synchronous with the yield handling; the poll only
  # absorbs scheduling latency.
  defp await_phase(pid, phase, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_phase(pid, phase, deadline)
  end

  defp do_await_phase(pid, phase, deadline) do
    case Session.inspect(pid, 500) do
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

  defp wait_until(fun, timeout) do
    do_wait_until(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      remaining(deadline) <= 0 -> flunk("condition not met within the wait budget")
      true -> Process.sleep(10) && do_wait_until(fun, deadline)
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
