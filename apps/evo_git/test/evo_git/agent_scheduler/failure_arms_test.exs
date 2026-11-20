defmodule EvoGit.AgentScheduler.FailureArmsTest do
  @moduledoc """
  The scheduler's FAILURE ARMS — the paths that must answer a DOCUMENTED error
  instead of crashing — pinned for the arms that used to raise:

    * the subagent-SPAWN handler (`handle_call({:spawn_sub_agents, …}, …)`):
      `EvoGit.AgentScheduler.Store.get_sched_meta/1` is a best-effort mirror
      read, and a mid-spawn reap answers `:error`. The handler must then reply
      `{:error, :not_found}` with the state UNTOUCHED — never raise a
      `MatchError` inside the shared scheduler GenServer (which would take every
      running agent's slots and waiters down with it).
    * `EvoGit.AgentScheduler.Worktrees` with a reaped `Store` row: the producer
      (`assign_and_prepare_worktree/3`) answers
      `{:error, {:worktree_prepare_failed, {:rows_missing, agent_id}}}`, and its
      only caller (`prepare_new_worktree/5`) surfaces the same reason without
      raising — as a bare `{:worktree_prepare_failed, {:rows_missing, id}}`,
      because that caller's else clause binds the REASON rather than the whole
      error tuple (see the in-test note: a shape defect, reported, `lib/` is
      out of scope here).
    * the summary-status vocabulary: `EvoGit.AgentScheduler.AgentState.live?/1`
      is the ONE owner of "this agent's session is still alive", so `:done`,
      `:failed` and the unpublished `nil` are NOT live.

  ## Why `async: true`

  The spawn arm is PURE: `handle_call/3` is called DIRECTLY with an in-process
  `%EvoGit.AgentScheduler.State{}`, so no application GenServer is called, no
  slot or waiter is touched and nothing is broadcast. Everything else either
  READS the scheduler's global named ETS tables (an absent row is exactly the
  `:error` these arms drive) or writes ONE row keyed by THIS module's per-test
  unique id (`9_910_000 +`), deleted in `on_exit` — never a wholesale table
  wipe and never an assertion on table emptiness. The config directory is
  isolated PER PROCESS (`EvoGit.TestSupport.ConfigDir`), so the worktree
  fixture's `[git] cow_worktree_creation = "disabled"` choice never reads the
  developer's real `config.toml` and never memoizes the BEAM-global CoW flag.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Config
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.TestSupport.ConfigDir

  # This module's own agent-id band: unique rows, invisible to every other
  # module even when this one leaves one behind.
  @agent_id_base 9_910_000

  # The create pipeline never calls the agent module — this only needs to exist
  # so the `%AgentSpec{}` is well-formed.
  defmodule DummyAgent do
  end

  setup do
    ConfigDir.isolate!("evogit-failure-arms")
    # Take the PLAIN `git worktree add` create path WITHOUT touching the
    # BEAM-global CoW flag (`:auto` would memoize it via `CowWorktree.enable/0`).
    # The config dir above is this process' own, so the write is invisible to
    # every concurrent module.
    assert :ok = Config.save_user_config(%{git: %{cow_worktree_creation: :disabled}})
    assert Config.resolve([:git, :cow_worktree_creation]) == :disabled
    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. Subagent spawn with a reaped parent SchedMeta row
  # ---------------------------------------------------------------------------
  describe "subagent SPAWN handler with a reaped parent row" do
    test "answers {:error, :not_found} and leaves the state untouched (no MatchError)" do
      agent_id = unique_agent_id()
      # The driving condition: the best-effort mirror row is GONE. The old code
      # pattern-matched `{:ok, parent}` here, so this `:error` raised.
      assert Store.get_sched_meta(agent_id) == :error

      state = %State{}
      from = {self(), make_ref()}

      # A raise would fail this match; the state must come back UNCHANGED (no
      # half-registered child, no waiter, no counter bump).
      assert {:reply, {:error, :not_found}, ^state} =
               AgentScheduler.handle_call({:spawn_sub_agents, agent_id, []}, from, state)
    end

    test "the paused short-circuit wins BEFORE the row read" do
      # Order is part of the contract: a paused scheduler refuses the spawn even
      # for a parent id whose row would answer `:error` (so a paused scheduler
      # never reports `:not_found` for a live parent it merely refuses to serve).
      paused = %State{paused: true}
      from = {self(), make_ref()}

      assert {:reply, {:error, :scheduler_paused}, ^paused} =
               AgentScheduler.handle_call(
                 {:spawn_sub_agents, unique_agent_id(), []},
                 from,
                 paused
               )
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Worktree prepare with reaped Store rows
  # ---------------------------------------------------------------------------
  describe "worktree prepare with reaped Store rows" do
    test "assign_and_prepare_worktree/3 answers the rows_missing shape for EITHER row" do
      agent_id = unique_agent_id()
      # The producer runs no git at all before both rows are read: a plain dir
      # and a plain "repo root" are enough.
      dir = Path.join(System.tmp_dir!(), "evogit-failure-arms-#{agent_id}")

      # (a) Neither row exists.
      assert {:error, {:worktree_prepare_failed, {:rows_missing, ^agent_id}}} =
               Worktrees.assign_and_prepare_worktree(agent_id, dir, dir)

      # (b) The SchedMeta row exists but the summary row is gone: the SECOND
      # `with` clause degrades to the SAME documented shape.
      put_sched_meta_row(agent_id)
      on_exit(fn -> delete_row(:evogit_sched_meta, agent_id) end)

      assert {:error, {:worktree_prepare_failed, {:rows_missing, ^agent_id}}} =
               Worktrees.assign_and_prepare_worktree(agent_id, dir, dir)
    end

    test "prepare_new_worktree/5 surfaces the same reason instead of raising" do
      repo = new_repo!()
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, base_sha} = Git.rev_parse(repo)

      agent_id = unique_agent_id()
      # The SUMMARY row exists (so the pipeline gets past its first read and
      # really creates the worktree); the SchedMeta row does not, which is the
      # reaped-row race `assign_and_prepare_worktree/3` reports.
      put_agent_state_row(agent_id)
      on_exit(fn -> delete_row(:evogit_agent_summary, agent_id) end)
      assert Store.get_sched_meta(agent_id) == :error

      spec = %AgentSpec{
        agent_module: __MODULE__.DummyAgent,
        context_node: %ContextNode{path: ".", repo: repo},
        objective: "failure-arms fixture",
        repo_id: "primary",
        phylo_node: %PhyloGraphNode{repo: repo, current_commit: base_sha},
        opts: []
      }

      meta = %SchedMeta{id: agent_id, task_number: 7, depth: 0, spec: spec}
      workers = Worktrees.workers_dir(repo)
      File.mkdir_p!(workers)
      worktree_path = Path.join(workers, "wt-#{agent_id}")

      # The caller surfaces the SAME reason without raising — pinned EXACTLY as
      # it behaves today. NOTE the shape: `prepare_new_worktree/5`'s else clause
      # binds `error` to the REASON (`{:worktree_prepare_failed, _}`), not to
      # the whole error tuple, so the returned term DROPS the `:error` tag.
      # `Session.Setup.request_worktree/2` only matches `{:ok, path}` /
      # `{:error, reason}`, so in production a reaped-row race reaches it as a
      # `CaseClauseError` (still a session-fatal error, but not the descriptive
      # `RuntimeError`). Reported to the source owner; the shape is not matched
      # with a wildcard, so fixing it flips exactly this assertion.
      assert Worktrees.prepare_new_worktree(agent_id, repo, worktree_path, spec, meta) ==
               {:worktree_prepare_failed, {:rows_missing, agent_id}}

      # The pipeline reached the ASSIGN step (it created the worktree) and the
      # error was passed through unchanged — not re-tagged into
      # `:worktree_create_failed` and not swallowed into `:ok`.
      assert File.dir?(worktree_path)
    end

    test "prepare_new_worktree/5 keeps its separate agent_state_missing shape" do
      # The OTHER documented degradation of the same caller: with no summary row
      # the pipeline stops BEFORE any worktree/git work and answers the distinct
      # `:agent_state_missing` shape (both shapes are total, neither is a raise).
      agent_id = unique_agent_id()
      dir = Path.join(System.tmp_dir!(), "evogit-failure-arms-#{agent_id}")

      spec = %AgentSpec{
        agent_module: __MODULE__.DummyAgent,
        context_node: %ContextNode{path: ".", repo: dir},
        objective: "failure-arms fixture",
        repo_id: "primary",
        phylo_node: %PhyloGraphNode{repo: dir, current_commit: String.duplicate("0", 40)},
        opts: []
      }

      meta = %SchedMeta{id: agent_id, task_number: 1, depth: 0, spec: spec}

      assert {:error, {:agent_state_missing, ^agent_id}} =
               Worktrees.prepare_new_worktree(agent_id, dir, Path.join(dir, "wt"), spec, meta)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. The live status vocabulary (owner: AgentState)
  # ---------------------------------------------------------------------------
  describe "the live status vocabulary" do
    test "every advertised live status is live — :done, :failed and nil are not" do
      live = AgentState.live_statuses()

      # Positives come from the OWNER's list, never a copy of it in this file.
      assert :running in live
      for status <- live, do: assert(AgentState.live?(status))

      # The three negatives: settled or not yet published, so no live session.
      for status <- [:done, :failed, nil] do
        refute AgentState.live?(status)
        refute status in live
      end

      # Unknown values are total (`false`), never a raise.
      refute AgentState.live?(:no_such_status)
      refute AgentState.live?("running")
      refute AgentState.live?(self())
    end

    test "terminal?/1 is the disjoint counterpart of live?/1" do
      for status <- AgentState.terminal_statuses(), do: assert(AgentState.terminal?(status))

      assert AgentState.terminal?(:done)
      assert AgentState.terminal?(:failed)
      refute AgentState.terminal?(nil)

      # Disjoint, and every status is classified as exactly one of the two
      # (nil is the only third state: not yet published).
      assert MapSet.disjoint?(
               MapSet.new(AgentState.live_statuses()),
               MapSet.new(AgentState.terminal_statuses())
             )

      for status <- AgentState.live_statuses(), do: refute(AgentState.terminal?(status))
      for status <- AgentState.terminal_statuses(), do: refute(AgentState.live?(status))
    end

    test ":done and :failed stay inside the full vocabulary" do
      # They are STATUSES — just not live ones — so a reader can still name them.
      for status <- [:done, :failed] do
        assert status in AgentState.statuses()
        refute AgentState.live?(status)
      end

      assert :awaiting_input in AgentState.live_statuses()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  # A throw-away git repo with ONE commit, so `git worktree add` has a base.
  defp new_repo! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "evogit-failure-arms-repo-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {:ok, _} = Git.init(dir)
    File.write!(Path.join(dir, "README.md"), "# failure-arms fixture")
    {:ok, _} = Git.add(dir, "README.md")
    {:ok, _} = Git.commit(dir, "initial commit")
    dir
  end

  # PRODUCTION-SHAPED rows (a plain map would make a concurrent module's
  # whole-table scan crash), inserted RAW so a fixture emits no
  # `:agent_registered` broadcast on the shared `"agents"` topic.
  defp put_agent_state_row(agent_id) do
    :ets.insert(
      :evogit_agent_summary,
      {agent_id,
       %AgentState{
         context_node: %ContextNode{path: "./", repo: "[system]"},
         llm_model: nil,
         max_retries: 3,
         max_depth: nil,
         parent_id: nil,
         repo_id: "primary",
         task_local_id: 7,
         foreign_repos: [],
         mode: :oneshot,
         status: :running
       }}
    )
  end

  defp put_sched_meta_row(agent_id) do
    # A PRODUCTION-SHAPED meta row (spec included, not just an enforce key): a
    # concurrent module scanning the table must never meet a half-built row.
    # This row is only read for its EXISTENCE — the failing `with` clause is the
    # missing SUMMARY row.
    spec = %AgentSpec{
      agent_module: __MODULE__.DummyAgent,
      context_node: %ContextNode{path: "./", repo: "[system]"},
      objective: "failure-arms fixture",
      repo_id: "primary",
      phylo_node: %PhyloGraphNode{repo: "[system]", current_commit: String.duplicate("0", 40)},
      opts: []
    }

    meta = %SchedMeta{id: agent_id, depth: 0, status: :running, spec: spec}
    :ets.insert(:evogit_sched_meta, {agent_id, meta})
  end

  defp delete_row(table, id) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table, id)
    :ok
  end

  defp unique_agent_id, do: @agent_id_base + System.unique_integer([:positive])
end
