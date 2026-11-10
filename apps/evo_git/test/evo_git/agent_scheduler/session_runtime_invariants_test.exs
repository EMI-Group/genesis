defmodule EvoGit.AgentScheduler.SessionRuntimeInvariantsTest.StubAgent do
  @moduledoc """
  The role a session-invariants run executes AS.

  A real `EvoGit.Agent.Session` needs a module implementing the `EvoGit.Agent`
  behaviour (`system_prompt/0`, `available_tools/0`, `delegation_level/0`). The
  tool list is deliberately EMPTY: every exchange below is driven end-to-end by
  the `:llm_call` engine seam (a plain-text reply with no tool calls finishes
  the run), so no tool schema is ever dispatched.

  Defined ABOVE the test module on purpose: `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """

  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the session-invariants stub agent."

  @doc "No tools: the scripted model always answers in plain text."
  def available_tools, do: []
end

defmodule EvoGit.AgentScheduler.SessionRuntimeInvariantsTest do
  @moduledoc """
  The P2 INVARIANT matrix for the agent-runtime refactor: a session is the ONE
  agent lifecycle, so the invariants that used to live across a `Task` + a
  duplicated ETS conversation must hold for the session too.

  ## What is pinned here

  1. **The summary row is a read model with no conversation** — the
     `:evogit_agent_summary` row carries no `context`, no injected-message queue,
     no cancel flag and no phylo node, `Session.history/1` is the ONLY source of
     `%ReqLLM.Message{}`s, and the same absence is guaranteed at the SOURCE
     level (the `AgentState` `defstruct` never declares those fields, and the
     summary WRITER never names a conversation atom) so a future field cannot be
     added silently. The source check PARSES the file (`Code.string_to_quoted!`)
     instead of matching prose, so comments and moduledocs can neither make it
     pass nor fail by accident.
  2. **Read paths stay answerable mid-exchange** — `list_agents/0` returns
     promptly while an exchange worker is blocked inside its LLM call, and
     `get_agent_history/1` serves the session-owned conversation the whole time.
  3. **The worktree lease belongs to the session and is released when it ends**
     — a repo-backed session performs the REAL `WorktreeManager` create (no
     app-env create seam: that is a BEAM-global and would force
     `async: false`), owns the worktree while it runs, and the manager reclaims
     the directory AND the branch when the session dies; a SECOND create for the
     same agent id/path is admitted afterwards, which is what proves the lease
     was released exactly once instead of leaked.
  4. **Force kill kills the worker AND the session, and delivers no result** —
     `EvoGit.AgentScheduler.Lifecycle.cancel_agent/2` goes through
     `Session.cancel(pid, :force)` (the `:shutdown` exit, NOT the `Process.exit/2`
     fallback's `:killed`), leaves no orphaned worker behind, clears both ETS
     rows and answers both blocked callers, and no `{:agent_session_result, …}`
     ever reaches the dispatch context's scheduler.

  ## Why `async: true` is safe

  The pinned tables (`:evogit_agent_summary`, `:evogit_sched_meta`,
  `:evogit_cancelling_tasks`) are BEAM-global, so every test uses a PER-TEST
  UNIQUE agent id (`9_970_000 + unique_integer`) and deletes exactly the rows it
  created in `on_exit`. Nothing here wipes or counts a table, mutates an app-env
  key (`.agents/skills` seams included), changes the global `Logger` level, or
  touches `:persistent_term` / the scheduler's configuration: every engine seam
  travels through `dispatch_ctx[:exchange_opts]` (`:llm_call`), which production
  never sets. The `WorktreeManager` lease test uses its own temp git repository,
  so the app-global manager's per-repo markers are keyed to a unique path.
  No assertion is weakened for parallelism: every wait is event-driven (the
  blocked-LLM notification, the monitor `:DOWN`, the caller reply) or a bounded
  poll that only absorbs scheduling latency — never a fixed sleep as the
  assertion.

  ## Reference suites it complements

  `test/evo_git/agent/session_test.exs` (session behaviour, seeded repo-less
  `dispatch_ctx`), `test/evo_git/agent_scheduler/session_dispatch_test.exs` (the
  dispatch/registration shape) and
  `test/evo_git/agent_scheduler/lifecycle_test.exs` (`cancel_agent/2`). This
  module adds the invariant + source-level assertions those three leave implicit.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentScheduler.SessionRuntimeInvariantsTest.StubAgent
  alias EvoGit.AgentScheduler.WorktreeManager
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A range of its own: `:evogit_agent_summary` is shared with every
  # concurrently running module, so the only safe key is a unique one.
  @agent_id_base 9_970_000

  # The fields that MUST NOT exist on the summary row (or in its defstruct):
  # the conversation, the P2 injected-message queue, the graceful-cancel flag
  # and the spatial/temporal node.
  @not_summary_fields [:context, :pending_user_messages, :cancel_requested, :phylo_node]

  @agent_state_source "../../../lib/evo_git/agent_scheduler/agent_state.ex"
  @summary_source "../../../lib/evo_git/agent/session/summary.ex"

  # The two definitions that SHAPE the published row. `message_count/1`
  # deliberately reads `%State{context: …}` to count messages — a READ, which is
  # why the atom check is scoped to the write path (see the moduledoc).
  @summary_write_functions [:publish, :merge]

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_invariants_#{agent_id}")
    File.mkdir_p!(tmp_dir)

    # The REGISTRATION rows: production dispatch writes both before a session
    # can exist, and the session builds its identity/model state from the
    # agent-state row (a missing row finalizes with `{:error, :not_registered}`).
    :ok = SchedStore.put_agent_state(agent_id, agent_state_row(tmp_dir))

    :ok =
      SchedStore.put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        task_id: "task-#{agent_id}",
        spec: repo_less_spec(tmp_dir)
      })

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{agent_id: agent_id, tmp_dir: tmp_dir}
  end

  # ---------------------------------------------------------------------------
  # 1. The summary row is a read model with no conversation
  # ---------------------------------------------------------------------------

  describe "the summary row is a read model with no conversation" do
    test "carries no conversation or control state, at runtime AND at the source level",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(repo_less_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000

      # --- runtime: the row the dashboard/RPC reads ---
      assert [{^agent_id, %AgentState{} = row}] =
               :ets.lookup(:evogit_agent_summary, agent_id)

      # `Session.Summary.read/1` is the documented reader of that same row.
      assert %AgentState{} = summary = Session.Summary.read(agent_id)
      assert summary == row

      for field <- @not_summary_fields do
        refute Map.has_key?(row, field),
               "the summary row must not carry #{inspect(field)} — it is state the session owns"
      end

      assert row.status == :running
      assert row.message_count >= 2

      # --- runtime: history is the ONLY source of the conversation ---
      messages = Session.history(pid)
      assert is_list(messages)
      assert Enum.all?(messages, &match?(%ReqLLM.Message{}, &1))
      assert Enum.map(messages, & &1.role) == [:system, :user]
      assert hd(messages).role == :system

      # Read, not drained: the same conversation is served twice.
      assert Session.history(pid) == messages

      # --- source level: the struct cannot grow a conversation field ---
      struct_fields = defstruct_keys!(@agent_state_source)

      # Non-vacuity: the extraction really found the summary projection.
      assert :llm_model in struct_fields
      assert :message_count in struct_fields
      assert :objective_preview in struct_fields
      assert length(struct_fields) > 20

      for field <- @not_summary_fields do
        refute field in struct_fields,
               "EvoGit.AgentScheduler.AgentState must not DECLARE a #{inspect(field)} field"
      end

      # --- source level: the WRITER never names a conversation atom ---
      atoms = write_path_atoms!(@summary_source)

      # Non-vacuity: the publish/merge pair really is what shaped this row.
      assert MapSet.member?(atoms, :objective_preview)
      assert MapSet.member?(atoms, :message_count)
      assert MapSet.member?(atoms, :status)
      assert MapSet.member?(atoms, :current_commit)

      for atom <- @not_summary_fields do
        refute MapSet.member?(atoms, atom),
               "EvoGit.Agent.Session.Summary must never write #{inspect(atom)} onto the row"
      end

      # …while its PROSE does discuss the conversation. Docstrings are BINARY
      # literals in the AST and comments are dropped by `Code.string_to_quoted!/1`
      # entirely, so the prose cannot satisfy (or break) the atom check above —
      # which is the whole point of parsing instead of matching text.
      assert File.read!(source_path(@summary_source)) =~ "`context`"

      send(worker, :release)
      # The stop is asynchronous with the release: the budget only absorbs the
      # completion path's own work plus suite-wide scheduling latency.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Read paths answer while an exchange is blocked
  # ---------------------------------------------------------------------------

  describe "read paths while a session is mid-exchange" do
    test "list_agents/0 answers promptly and get_agent_history/1 still serves the conversation",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, ref} =
        start_session(repo_less_ctx(agent_id, tmp_dir, llm_call: blocking_llm_call(self())))

      assert_receive {:llm_blocked, worker}, 5_000
      assert worker != pid

      # The DISPATCH-TIME bookkeeping shape: `Dispatch.do_try_dispatch/4` records
      # the session pid, `:starting` and `:running` on the sched-meta row. The
      # test starts the session directly, so it mirrors that write — otherwise
      # `list_agents/0` would report the registration default (`:pending`).
      {:ok, live_meta} = SchedStore.get_sched_meta(agent_id)

      :ok =
        SchedStore.put_sched_meta(agent_id, %{
          live_meta
          | status: :running,
            session_pid: pid,
            phase: :starting
        })

      # The worker is parked inside its LLM call for the WHOLE measurement, so
      # the call cannot be fast because the agent finished.
      started_at = System.monotonic_time(:millisecond)
      rows = RemoteAPI.list_agents()
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert is_list(rows)

      assert elapsed < 2_000,
             "list_agents/0 took #{elapsed}ms while one exchange was blocked — " <>
               "the read path must not wait on the agent loop"

      row = Enum.find(rows, &(&1.id == agent_id))
      assert row, "list_agents/0 must include the running agent #{agent_id}"
      assert row.status == :running

      # History is fetched from the session, not from the row: it survives the
      # list read and is byte-identical to the session's own view.
      messages = RemoteAPI.get_agent_history(agent_id)
      assert is_list(messages)
      assert messages != []
      assert Enum.all?(messages, &match?(%ReqLLM.Message{}, &1))
      assert hd(Enum.map(messages, & &1.role)) == :system
      assert messages == Session.history(pid)

      # Still the same live session: nothing was recycled by the reads.
      assert Process.alive?(pid)

      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000
    end
  end

  # ---------------------------------------------------------------------------
  # 3. The worktree lease belongs to the session
  # ---------------------------------------------------------------------------

  describe "the worktree lease" do
    test "is released when the session ends, and a second create for the same agent is admitted",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      repo_root = Path.join(tmp_dir, "repo")
      sha = init_repo!(repo_root)

      worktree_path = Path.join([repo_root, ".genesis/workers", "worker_T1_A1"])
      branch = "evogit-agent-T1-A1"

      :ok =
        SchedStore.put_agent_state(agent_id, %AgentState{
          context_node: context_node(repo_root),
          objective: "session runtime invariants objective",
          llm_model: "test:model",
          model_id: "session-invariants",
          max_turns: 128,
          max_retries: 3,
          max_depth: 8,
          repo_id: "primary",
          repo_root: repo_root,
          # `WorktreeManager` derives the branch from these two numbers.
          task_local_id: 1,
          llm_context_window: 200_000
        })

      spec = repo_backed_spec(repo_root, sha, tmp_dir)

      meta = %SchedMeta{
        id: agent_id,
        depth: 0,
        task_id: "task-#{agent_id}",
        task_number: 1,
        spec: spec,
        from: {self(), make_ref()}
      }

      :ok = SchedStore.put_sched_meta(agent_id, meta)

      # NO `repo_less` key: `Session.Setup.bind_worktree/2` performs the REAL
      # `WorktreeManager.create_worktree_for_agent/6` create (the manager
      # monitors the SESSION pid, so the lease's owner is the session).
      {:ok, pid, ref} =
        start_session(
          agent_id: agent_id,
          depth: 0,
          repo_root: repo_root,
          repo_id: "primary",
          worktree_path: worktree_path,
          retries: 0,
          spec: spec,
          meta: meta,
          exchange_opts: [llm_call: blocking_llm_call(self())]
        )

      # The create pipeline runs before the first exchange worker starts.
      assert_receive {:llm_blocked, worker}, 30_000

      # The session OWNS a real, checked-out worktree at the dispatched commit
      # while it runs.
      assert File.dir?(worktree_path)
      assert Git.rev_parse(worktree_path) == {:ok, sha}
      assert Git.branch_exists?(repo_root, branch)
      assert {:ok, %{phase: :running}} = Session.inspect(pid, 1_000)

      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000

      # Monitor-driven reclamation: the lease is released when its owner (the
      # session) dies. Event-driven bounded waits — the destroy is the manager's
      # reaction to the `:DOWN`, not a synchronous part of the session's stop.
      wait_until(fn -> not File.exists?(worktree_path) end, 10_000)
      wait_until(fn -> not Git.branch_exists?(repo_root, branch) end, 10_000)

      refute File.exists?(worktree_path)
      refute Git.branch_exists?(repo_root, branch)

      # The lease was released EXACTLY ONCE, not leaked: a second create for the
      # same agent id + path is admitted and materializes a fresh worktree
      # (a still-live registration would answer about the in-flight create
      # instead of starting one).
      assert {:ok, ^worktree_path} =
               WorktreeManager.create_worktree_for_agent(
                 agent_id,
                 repo_root,
                 worktree_path,
                 spec,
                 meta,
                 self()
               )

      assert File.dir?(worktree_path)
      assert Git.rev_parse(worktree_path) == {:ok, sha}
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Force kill through Lifecycle.cancel_agent/2
  # ---------------------------------------------------------------------------

  describe "force kill through Lifecycle.cancel_agent/2" do
    test "kills the worker AND the session, clears both rows and delivers no result",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      # The dispatch context's `:scheduler` pid is where a session would deliver
      # its ONE terminal result: point it at this test so the ABSENCE of a
      # delivery is directly observable. (The `:scheduler` key INSIDE
      # `exchange_opts` is a different thing — the engine's `fun/3` seam — so it
      # is deliberately not set here: the default engine scheduler is used.)
      {:ok, pid, ref} =
        start_session(
          repo_less_ctx(agent_id, tmp_dir, [llm_call: blocking_llm_call(self())],
            scheduler: self()
          )
        )

      assert_receive {:llm_blocked, worker}, 5_000
      assert worker != pid
      assert [{^pid, _value}] = Registry.lookup(Session.Registry, agent_id)

      # The dispatch-time shape: the session is recorded, and the top-level
      # caller (`from`) is a real `GenServer.from/0` value whose reply lands in
      # this test process.
      from_ref = make_ref()
      {:ok, live_meta} = SchedStore.get_sched_meta(agent_id)

      :ok =
        SchedStore.put_sched_meta(agent_id, %{
          live_meta
          | status: :running,
            session_pid: pid,
            from: {self(), from_ref},
            sub_agent_from: nil
        })

      state = State.from_model_profiles([%{id: "session-invariants", model: "test:model"}])

      assert Lifecycle.cancel_agent(state, agent_id) == state

      # The top-level caller is answered with the documented cancellation reply.
      assert_receive {^from_ref, {:error, :cancelled}}, 1_000

      # The session died through its OWN force-cancel path: `:shutdown`. A
      # `:killed` here would mean the `Process.exit/2` fallback ran instead.
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000
      refute Process.alive?(pid)

      # …and the blocked exchange worker went with it: no orphan left behind.
      refute Process.alive?(worker)

      # Both bookkeeping rows are gone (recycle is terminal here).
      assert SchedStore.get_sched_meta(agent_id) == :error
      assert SchedStore.get_agent_state(agent_id) == :error

      # A force kill reports NO outcome at all.
      refute_receive {:agent_session_result, ^agent_id, _pid, _result}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Session lifecycle helpers
  # ---------------------------------------------------------------------------

  defp start_session(ctx) do
    {:ok, pid} = Session.start_link(ctx)

    # Some paths stop the session abnormally; the link must not take the test
    # process down with it, while the monitor keeps the exit observable.
    Process.unlink(pid)
    ref = Process.monitor(pid)

    # A failed assertion must not leave a live session (and its worker) behind.
    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, pid, ref}
  end

  # A repo-less `dispatch_ctx` (no worktree, no git, no `WorktreeManager`).
  defp repo_less_ctx(agent_id, tmp_dir, exchange_opts, extra \\ []) do
    spec = repo_less_spec(tmp_dir)

    [
      agent_id: agent_id,
      depth: 0,
      repo_root: tmp_dir,
      repo_id: "primary",
      worktree_path: Path.join(tmp_dir, "worker"),
      retries: 0,
      spec: spec,
      meta: %SchedMeta{id: agent_id, depth: 0, task_id: "task-#{agent_id}", spec: spec},
      repo_less: true,
      repo_less_repo_path: tmp_dir,
      exchange_opts: exchange_opts
    ] ++ extra
  end

  defp repo_less_spec(tmp_dir) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: "[system]"},
      phylo_node: nil,
      agent_module: StubAgent,
      objective: "session runtime invariants objective",
      opts: [repo_less: true, task_tmpdir: tmp_dir]
    }
  end

  # A repo-BACKED spec: a real phylo node at the dispatched commit, so the real
  # create pipeline and the completion path's `rev_parse` have a repository.
  defp repo_backed_spec(repo_root, sha, tmp_dir) do
    %AgentSpec{
      context_node: context_node(repo_root),
      phylo_node: %PhyloGraphNode{repo: repo_root, base_commit: sha, current_commit: sha},
      agent_module: StubAgent,
      objective: "session runtime invariants objective",
      repo_id: "primary",
      opts: [task_tmpdir: tmp_dir]
    }
  end

  # The registration row the session builds its state from (identity + model
  # fields come from this row, never from the dispatch context).
  defp agent_state_row(repo_root) do
    %AgentState{
      context_node: context_node(repo_root),
      objective: "session runtime invariants objective",
      parent_id: nil,
      archive: false,
      llm_model: "test:model",
      model_id: "session-invariants",
      max_turns: 128,
      max_retries: 3,
      max_depth: nil,
      repo_id: "primary",
      llm_context_window: 200_000
    }
  end

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
  # Scripted LLM seam (passed through `dispatch_ctx[:exchange_opts]`)
  # ---------------------------------------------------------------------------

  # Parks THIS worker in its LLM call until the test releases it. A plain-text
  # reply with no tool calls ENDS the run, so a released worker terminates
  # promptly; any later call (a grace turn, a retry) returns immediately.
  defp blocking_llm_call(test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      unless Process.get(:session_invariants_released) do
        send(test_pid, {:llm_blocked, self()})

        receive do
          :release -> Process.put(:session_invariants_released, true)
        after
          10_000 -> Process.put(:session_invariants_released, true)
        end
      end

      {:implicit_completion, response(context), "session runtime invariants report"}
    end
  end

  defp response(context) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("session runtime invariants report")],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "session-invariants-response",
      model: "test:model",
      # The engine advances the conversation from the response's own context.
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # ---------------------------------------------------------------------------
  # Source-level AST inspection (parsed — never prose-matched)
  # ---------------------------------------------------------------------------

  defp source_path(relative) do
    path = Path.expand(relative, __DIR__)
    assert File.exists?(path), "expected the pinned source file to exist at #{path}"
    path
  end

  defp parse_source!(relative) do
    relative |> source_path() |> File.read!() |> Code.string_to_quoted!()
  end

  # The fields a `defstruct` declares: `defstruct a: nil, b: nil` and
  # `defstruct [:a, :b]` are both handled, and only the declared NAMES are
  # returned (never a default value).
  defp defstruct_keys!(relative) do
    ast = parse_source!(relative)

    {_ast, keys} =
      Macro.prewalk(ast, [], fn
        {:defstruct, _meta, [args]} = node, acc when is_list(args) ->
          {node, acc ++ declared_fields(args)}

        node, acc ->
          {node, acc}
      end)

    keys
  end

  defp declared_fields(args) do
    Enum.flat_map(args, fn
      keyword when is_list(keyword) -> for({key, _default} <- keyword, is_atom(key), do: key)
      {key, _default} when is_atom(key) -> [key]
      key when is_atom(key) -> [key]
      _other -> []
    end)
  end

  # Every atom the summary WRITE path mentions. Variable names and alias parts
  # are atoms in the AST too, which only makes the check stricter: the writer has
  # no reason to name any forbidden field — not even as a variable.
  defp write_path_atoms!(relative) do
    relative
    |> parse_source!()
    |> module_body!()
    |> Enum.filter(&definition_of?(&1, @summary_write_functions))
    |> Enum.reduce(MapSet.new(), fn definition, acc -> collect_atoms(definition, acc) end)
  end

  defp module_body!({:defmodule, _meta, [_name, body]}) do
    case Keyword.fetch(body, :do) do
      {:ok, {:__block__, _meta, nodes}} -> nodes
      {:ok, single} -> [single]
    end
  end

  defp module_body!(ast) do
    flunk("expected a defmodule AST, got: #{inspect(ast, limit: 3)}")
  end

  defp definition_of?({kind, _meta, [head | _]} = _node, names) when kind in [:def, :defp],
    do: head_name(head) in names

  defp definition_of?(_node, _names), do: false

  # A definition head is a call tuple (`{:publish, meta, args}`), optionally
  # wrapped in a `:when` guard.
  defp head_name({:when, _meta, [head | _]}), do: head_name(head)
  defp head_name({name, _meta, _args}) when is_atom(name), do: name
  defp head_name(_head), do: nil

  defp collect_atoms(node, acc) do
    {_node, acc} =
      Macro.prewalk(node, acc, fn
        atom, inner when is_atom(atom) -> {atom, MapSet.put(inner, atom)}
        other, inner -> {other, inner}
      end)

    acc
  end

  # ---------------------------------------------------------------------------
  # Bounded, event-driven waiting
  # ---------------------------------------------------------------------------

  # A bounded poll: only absorbs scheduling latency between the event and this
  # process observing it — never a fixed sleep standing in for an assertion.
  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{timeout}ms")

      true ->
        Process.sleep(5)
        do_wait_until(fun, deadline, timeout)
    end
  end
end
