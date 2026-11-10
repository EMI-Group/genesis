defmodule EvoGit.Agent.Session.InteractiveCloseTest.StubAgent do
  @moduledoc """
  The role an interactive-close run executes AS: an INTERACTIVE session
  (`session_mode/0` = `:interactive`) whose tool list is EMPTY, so every
  exchange is driven end-to-end by the `:llm_call` engine seam (a plain-text
  reply yields instead of finishing).
  Defined ABOVE the test module on purpose: `mix test` starts the ExUnit async
  runner BEFORE requiring the test files, so a helper defined after the test
  module can still be unloaded when the first test runs.
  """
  use EvoGit.Agent

  @doc "The fixed system prompt of the stub role."
  def system_prompt, do: "You are the interactive-close stub agent."

  @doc "No tools: the scripted model always answers in plain text."
  def available_tools, do: []

  @doc "Opt this role into the interactive session driver."
  def session_mode, do: :interactive
end

defmodule EvoGit.Agent.Session.InteractiveCloseTest do
  @moduledoc """
  The two REAL-REPO P3 invariants that the repo-less `interactive_test.exs`
  harness cannot pin.

  1. **(c) `close/2` while idle reclaims the worktree EXACTLY once** — a
     repo-backed session performs the REAL `WorktreeManager` create (no app-env
     create seam), keeps that worktree for its whole life (it exists while the
     session is parked in `:awaiting_input`), and `close/2` replies `:ok`
     immediately, delivers exactly ONE terminal `%Result{}` plus exactly ONE
     `:agent_session_closed`, stops the session `:normal`, and the manager then
     reclaims the worktree DIRECTORY exactly once (a later bounded window finds
     it still absent, and `git worktree list` carries no entry for the path).
     The repository itself is untouched (same HEAD, still a repo).
  2. **(g) completion happens ONCE across many exchanges** — three yields
     driven by `start_input/3` followed by `close/2` produce exactly ONE
     `%Result{}`, exactly ONE `:agent_session_closed`, exactly ONE git note on
     the base commit, and exactly ONE `task_agent_archives` row whose archived
     `result` is the LAST yielded text (`"three"`), which is also the `%Result{}`
     `result`.

  ## Why `async: true` is safe
  The pinned tables (`:evogit_agent_summary`, `:evogit_sched_meta`,
  `:evogit_cancelling_tasks`, `task_agent_archives`) are BEAM-global, so every
  test uses a PER-TEST UNIQUE agent id (`9_960_000 + unique_integer`) and a
  unique task id, works in its own temp git repository (so the app-global
  `WorktreeManager`'s per-repo markers are keyed to a unique path), deletes
  exactly the rows it created in `on_exit`, and never wipes or counts a table,
  mutates an app-env key or touches `:persistent_term`. Every session is given
  `scheduler: self()` in its dispatch context, so a run's ONE terminal result is
  delivered to the TEST instead of the app-global scheduler. The engine seam
  travels through `dispatch_ctx[:exchange_opts]` (`:llm_call`), which production
  never sets. No assertion is weakened for parallelism: every wait is
  event-driven (the yield notice, the monitor `:DOWN`, the terminal message) or
  a bounded poll that only absorbs scheduling latency, never a fixed sleep used
  as the assertion. The archive row is written by the SESSION's finalizer, which
  carries no test process dictionary, so it lands in the app-global task store
  under the unique task id — exactly where the assertions read it back from.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Session.InteractiveCloseTest.StubAgent
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A range of its own: the summary/sched tables are shared with every
  # concurrently running module, so the only safe key is a unique one.
  @agent_id_base 9_960_000
  # The shared host's scheduling swings several-fold under parallel load, so
  # EVERY wait in this module uses this one budget. It only absorbs that
  # latency — each awaited event is reachable by construction, and every wait
  # still FAILS (never silently passes) when it is not.
  @async_wait_budget_ms 30_000
  # A bounded ABSENCE window: the session is already dead and its `:DOWN` has
  # been observed, so this proves the worktree does not come BACK.
  @no_reappearance_window_ms 500

  setup do
    agent_id = @agent_id_base + System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "evogit_session_close_#{agent_id}")
    File.mkdir_p!(tmp_dir)
    repo_root = Path.join(tmp_dir, "repo")
    base_commit = init_repo!(repo_root)
    worktree_path = Path.join([repo_root, ".genesis/workers", "worker_T1_A1"])
    task_id = "task-#{agent_id}"

    spec = repo_backed_spec(repo_root, base_commit, tmp_dir)
    meta = sched_meta(agent_id, task_id, spec)

    :ok = SchedStore.put_agent_state(agent_id, agent_state(agent_id, repo_root, task_id))
    :ok = SchedStore.put_sched_meta(agent_id, meta)

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
      SchedStore.clear_cancel_requested(agent_id)
      File.rm_rf(tmp_dir)
    end)

    %{
      agent_id: agent_id,
      tmp_dir: tmp_dir,
      repo_root: repo_root,
      base_commit: base_commit,
      worktree_path: worktree_path,
      task_id: task_id,
      spec: spec,
      meta: meta
    }
  end

  describe "invariant (c) — close/2 while idle" do
    test "(c) reclaims the worktree EXACTLY once and answers the close contract",
         %{
           agent_id: agent_id,
           repo_root: repo_root,
           base_commit: base_commit,
           worktree_path: worktree_path
         } = ctx do
      {:ok, pid, ref} = start_session(dispatch_ctx(ctx, ["done one"]))

      # ONE exchange yields: the session parks, it does NOT finish.
      assert_receive {:agent_session_yield, ^agent_id, ^pid, "done one"},
                     @async_wait_budget_ms

      assert await_phase(pid, :awaiting_input)
      # The worktree OUTLIVES the exchange: an idle session still owns it.
      assert File.dir?(worktree_path)
      assert Git.rev_parse(worktree_path) == {:ok, base_commit}

      # `close/2` at `:awaiting_input` replies IMMEDIATELY (`:ok`) ...
      assert :ok = Session.close(pid)

      # ... and while the session still lives a second close is REFUSED as
      # already finished. The finalizer may already have finished the session
      # on a fast machine, in which case the same refusal comes back as
      # `:not_found` (never a second finalization).
      case Session.close(pid) do
        {:error, :finished} ->
          :ok

        {:error, :not_found} ->
          refute Process.alive?(pid)
      end

      # Exactly ONE terminal result and ONE closed notice for the whole session.
      assert {:ok, %Result{}} = await_terminal(agent_id, pid)

      assert_receive {:agent_session_closed, ^agent_id, {:ok, %Result{}}},
                     @async_wait_budget_ms

      refute_receive {:agent_session_result, ^agent_id, ^pid, _other}, @no_reappearance_window_ms
      refute_receive {:agent_session_closed, ^agent_id, _other}, @no_reappearance_window_ms

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @async_wait_budget_ms

      # The manager reclaims the worktree as its reaction to the session's
      # `:DOWN` — a bounded, event-driven wait, never a fixed sleep.
      wait_until(fn -> not File.exists?(worktree_path) end, @async_wait_budget_ms)
      refute File.exists?(worktree_path)

      # The repository survives untouched: same HEAD, no worktree registration
      # left behind for the reclaimed path.
      assert File.dir?(repo_root)
      assert Git.rev_parse(repo_root) == {:ok, base_commit}
      assert {:ok, worktrees} = Git.run(["worktree", "list"], repo_root)
      refute String.contains?(worktrees, worktree_path)

      # EXACTLY ONE reclamation: nothing recreates the directory afterwards.
      refute appears_within?(fn -> File.exists?(worktree_path) end, @no_reappearance_window_ms)

      # A closed session answers `:not_found` instead of finalizing again.
      assert Session.close(pid) == {:error, :not_found}
    end
  end

  describe "invariant (g) — completion ONCE across many exchanges" do
    test "(g) archives and reports only the LAST yielded text, exactly once",
         %{
           agent_id: agent_id,
           repo_root: repo_root,
           base_commit: base_commit,
           task_id: task_id
         } = ctx do
      {:ok, pid, ref} = start_session(dispatch_ctx(ctx, ["one", "two", "three"]))
      assert_receive {:agent_session_yield, ^agent_id, ^pid, "one"}, @async_wait_budget_ms

      # TWO more exchanges on the SAME session (a yield is non-terminal).
      assert :ok = Session.start_input(pid, "two")
      assert_receive {:agent_session_yield, ^agent_id, ^pid, "two"}, @async_wait_budget_ms
      assert :ok = Session.start_input(pid, "three")
      assert_receive {:agent_session_yield, ^agent_id, ^pid, "three"}, @async_wait_budget_ms
      assert await_phase(pid, :awaiting_input)

      assert :ok = Session.close(pid)

      # ONE completion for THREE exchanges, carrying the LAST yielded text.
      assert {:ok, %Result{result: "three"}} = await_terminal(agent_id, pid)

      assert_receive {:agent_session_closed, ^agent_id, {:ok, %Result{result: "three"}}},
                     @async_wait_budget_ms

      refute_receive {:agent_session_result, ^agent_id, ^pid, _other}, @no_reappearance_window_ms
      refute_receive {:agent_session_closed, ^agent_id, _other}, @no_reappearance_window_ms
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @async_wait_budget_ms

      # ONE git note on the base commit (git notes is keyed by object, so a
      # second write would OVERWRITE rather than add — its presence is the pin).
      assert {:ok, note} = EvoGit.Agent.Completion.get_agent_metadata(repo_root, base_commit)
      assert is_map(note)

      # ONE archive row for (task_id, agent_id), archived with the last text.
      wait_until(fn -> archive_entry(task_id, agent_id) != nil end, @async_wait_budget_ms)

      %{entries: entries} = list_archives(task_id)
      mine = Enum.filter(entries, &(&1["agent_id"] == agent_id))
      assert [entry] = mine
      assert entry["task_id"] == task_id
      assert entry["result"] == "three"
      assert entry["base_commit"] == base_commit
    end
  end

  # ---------------------------------------------------------------------------
  # Harness — a repo-backed session with real ETS registration rows
  # ---------------------------------------------------------------------------
  defp agent_state(_agent_id, repo_root, _task_id) do
    %AgentState{
      context_node: context_node(repo_root),
      objective: "interactive close objective sentinel",
      parent_id: nil,
      # Archive is read from THIS row by the completion builder, so it must be
      # on the registration row (never only on the spec).
      archive: true,
      llm_model: "test:model",
      model_id: "session-interactive-close-test",
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
      objective: "interactive close objective sentinel",
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

  defp dispatch_ctx(ctx, texts) do
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
      exchange_opts: [llm_call: sequenced_llm_call(texts)]
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

  # Every scripted turn answers with the NEXT text in the list, so an exchange
  # is a yield whose text identifies which exchange it was. The list lives in a
  # linked Agent because each exchange runs in a FRESH worker process (its own
  # empty process dictionary), while this closure was built in the test.
  defp sequenced_llm_call(texts) do
    {:ok, seq} = Agent.start_link(fn -> texts end)

    fn context, _tools, _params, _agent_id, _retries ->
      text =
        Agent.get_and_update(seq, fn
          [last] -> {last, [last]}
          [head | tail] -> {head, tail}
          [] -> {nil, []}
        end)

      {:implicit_completion, response(context, text), text}
    end
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "session-interactive-close-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
    }
  end

  # ---------------------------------------------------------------------------
  # Observation helpers
  # ---------------------------------------------------------------------------
  defp await_terminal(agent_id, session_pid, timeout \\ @async_wait_budget_ms) do
    assert_receive {:agent_session_result, ^agent_id, ^session_pid, result}, timeout
    result
  end

  defp await_phase(pid, phase, timeout \\ 5_000) do
    wait_until(fn -> match?({:ok, %{phase: ^phase}}, Session.inspect(pid, 200)) end, timeout)
  end

  defp wait_until(fun, timeout) do
    if appears_within?(fun, timeout) do
      true
    else
      flunk("condition not met within #{timeout}ms")
    end
  end

  defp appears_within?(fun, timeout) do
    appears_within_loop?(fun, deadline(timeout))
  end

  defp appears_within_loop?(fun, deadline) do
    cond do
      fun.() ->
        true

      remaining(deadline) <= 0 ->
        false

      true ->
        Process.sleep(10)
        appears_within_loop?(fun, deadline)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # ---------------------------------------------------------------------------
  # Task-store archive reads (the finalizer writes to the app-global store)
  # ---------------------------------------------------------------------------
  defp list_archives(task_id) do
    EvoGit.TaskRegistry.list_task_archives(task_id, include_results: true, include_total: false)
  end

  defp archive_entry(task_id, agent_id) do
    case list_archives(task_id) do
      %{entries: entries} -> Enum.find(entries, &(&1["agent_id"] == agent_id))
      _other -> nil
    end
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
end
