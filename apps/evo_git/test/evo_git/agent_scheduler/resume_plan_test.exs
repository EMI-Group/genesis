defmodule EvoGit.AgentScheduler.ResumePlanTest.StubAgent do
  @moduledoc """
  The role a planned dispatch runs AS: only a well-formed spec matters - these
  tests exercise `EvoGit.AgentScheduler.ResumePlan.plan/5` and the worktree
  pipeline directly and never start a session.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the resume-plan stub agent."

  @doc "No tools: nothing here executes."
  def available_tools, do: []
end

defmodule EvoGit.AgentScheduler.ResumePlanTest do
  @moduledoc """
  The ONE resume/retry decision a dispatch makes
  (`EvoGit.AgentScheduler.ResumePlan.plan/5`, delegated from
  `EvoGit.AgentScheduler.Dispatch.resume_plan/5`): the worktree BASE, the
  BRANCH the run keeps and whether the durable conversation is restored.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.ResumePlanTest.StubAgent
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec

  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  setup %{tmp_dir: tmp_dir} do
    store_dir = Path.join(tmp_dir, "state")
    File.mkdir_p!(store_dir)

    store =
      start_supervised!(
        {EvoGit.AgentState, database: Path.join(store_dir, "agent_state.sqlite"), name: nil},
        id: {EvoGit.AgentState, System.unique_integer([:positive])}
      )

    Process.put(:evogit_agent_state_server, store)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"}
        ] do
      git!(repo, ["config", key, value])
    end

    base = commit!(repo, "base.txt", "base\n", "base")
    pause = commit!(repo, "paused.txt", "paused work\n", "pause checkpoint")
    resumed = commit!(repo, "resumed.txt", "resumed work\n", "resumed run commit")
    salvage = commit!(repo, "salvaged.txt", "salvaged work\n", "salvage after restart")

    {:ok,
     repo: repo,
     base: base,
     pause: pause,
     resumed: resumed,
     salvage: salvage,
     missing: String.duplicate("a", 40),
     missing_2: String.duplicate("b", 40)}
  end

  describe "base selection order (first USABLE candidate wins)" do
    test "a usable pause checkpoint wins over resume_current_commit and crash_commit", %{
      repo: repo,
      base: base,
      pause: pause,
      resumed: resumed,
      salvage: salvage
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec =
        spec(repo, base,
          resume_kind: :clean_pause,
          pause_commit: pause,
          resume_current_commit: resumed
        )

      plan =
        Dispatch.resume_plan(
          agent_id,
          spec,
          meta(agent_id, task_id, spec, retries: 1, crash_commit: salvage),
          repo,
          1
        )

      assert plan.resume_kind == :clean_pause
      assert plan.worktree_resume_from == pause
      assert plan.spec.phylo_node.current_commit == pause
      assert plan.meta.spec.phylo_node.current_commit == pause
    end

    test "an unusable pause checkpoint degrades to resume_current_commit", %{
      repo: repo,
      base: base,
      resumed: resumed,
      salvage: salvage,
      missing: missing
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec =
        spec(repo, base,
          resume_kind: :clean_pause,
          pause_commit: missing,
          resume_current_commit: resumed
        )

      plan =
        Dispatch.resume_plan(
          agent_id,
          spec,
          meta(agent_id, task_id, spec, retries: 1, crash_commit: salvage),
          repo,
          1
        )

      assert plan.worktree_resume_from == resumed
      assert plan.spec.phylo_node.current_commit == resumed
    end

    test "unusable pause checkpoint AND resume commit degrade to crash_commit", %{
      repo: repo,
      base: base,
      salvage: salvage,
      missing: missing,
      missing_2: missing_2
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec =
        spec(repo, base,
          resume_kind: :dirty_pause,
          pause_commit: missing,
          resume_current_commit: missing_2
        )

      plan =
        Dispatch.resume_plan(
          agent_id,
          spec,
          meta(agent_id, task_id, spec, retries: 1, crash_commit: salvage),
          repo,
          1
        )

      assert plan.worktree_resume_from == salvage
      assert plan.spec.phylo_node.current_commit == salvage
    end

    test "every candidate unusable keeps the task base untouched", %{
      repo: repo,
      base: base,
      missing: missing,
      missing_2: missing_2
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec =
        spec(repo, base,
          resume_kind: :dirty_pause,
          pause_commit: missing,
          resume_current_commit: missing_2
        )

      meta = meta(agent_id, task_id, spec, retries: 1, crash_commit: String.duplicate("c", 40))

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 1)

      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == nil
      assert plan.spec.phylo_node.current_commit == base
      assert plan.meta.spec == spec
    end

    test "resume_current_commit ALONE becomes the base (explicit nil pause checkpoint)", %{
      repo: repo,
      base: base,
      resumed: resumed,
      missing: missing
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec =
        spec(repo, base,
          resume_kind: :clean_pause,
          pause_commit: nil,
          resume_current_commit: resumed
        )

      plan =
        Dispatch.resume_plan(
          agent_id,
          spec,
          meta(agent_id, task_id, spec, retries: 1, crash_commit: missing),
          repo,
          1
        )

      assert plan.worktree_resume_from == resumed
      assert plan.spec.phylo_node.current_commit == resumed
    end

    test "a crash retry resolves through the same order (pause checkpoint first)", %{
      repo: repo,
      base: base,
      pause: pause,
      salvage: salvage
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec = spec(repo, base, pause_commit: pause)

      plan =
        Dispatch.resume_plan(
          agent_id,
          spec,
          meta(agent_id, task_id, spec, retries: 1, crash_commit: salvage),
          repo,
          1
        )

      assert plan.resume_kind == nil
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == pause
      assert plan.spec.phylo_node.current_commit == pause
    end

    test "a crash retry with no salvage and no resume facts is a no-op", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      spec = spec(repo, base)
      meta = meta(agent_id, task_id, spec, retries: 1)

      {_micros, plan} = :timer.tc(fn -> Dispatch.resume_plan(agent_id, spec, meta, repo, 1) end)

      assert plan.worktree_resume_from == nil
      assert plan.spec == spec
      assert plan.meta == meta
      assert plan.restore_agent_state == true
    end
  end

  describe "the dispatch ctx :branch" do
    test "a pause resume keeps the PERSISTED branch", %{repo: repo, base: base} do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      seed_summary!(agent_id, task_local_id: 1)

      persisted = "evogit-agent-T2-A5"

      spec =
        spec(repo, base,
          resume_kind: :clean_pause,
          pause_commit: nil,
          resume_branch: persisted
        )

      meta = meta(agent_id, task_id, spec, task_number: 1)
      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.branch == persisted
      assert plan.spec.opts[:worktree_branch] == persisted

      ctx = dispatch_ctx(agent_id, meta, plan, repo)
      assert ctx[:branch] == persisted
    end

    test "a child carrying restore_agent_state keeps its persisted branch too", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      seed_summary!(agent_id, task_local_id: 2)

      persisted = "evogit-agent-T4-A2"

      spec = spec(repo, base, restore_agent_state: true, resume_branch: persisted)
      meta = meta(agent_id, task_id, spec, task_number: 4, depth: 1)
      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.resume_kind == nil
      assert plan.restore_agent_state == true
      assert plan.branch == persisted

      ctx = dispatch_ctx(agent_id, meta, plan, repo)
      assert ctx[:branch] == persisted
    end

    test "a normal run derives the fresh branch and records nothing", %{repo: repo, base: base} do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      seed_summary!(agent_id, task_local_id: 3)

      spec = spec(repo, base)
      meta = meta(agent_id, task_id, spec, task_number: 5)
      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      fresh = Worktrees.branch_name(5, 3)

      assert plan.branch == fresh
      refute Keyword.has_key?(plan.spec.opts, :worktree_branch)
      assert Worktrees.branch_for(meta, 3, plan.spec) == fresh

      ctx = dispatch_ctx(agent_id, meta, plan, repo)
      assert ctx[:branch] == fresh
    end
  end

  describe "anchor-based branch recreation (real git)" do
    test "prepare_new_worktree/5 recreates a wiped branch at the anchored sha", %{
      repo: repo,
      base: base,
      missing: missing
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      branch = "evogit-agent-T1-A1"

      git!(repo, ["checkout", "-q", "-b", branch])
      anchored = commit!(repo, "resume-work.txt", "resume work\n", "resume work")
      git!(repo, ["checkout", "-q", "--detach", base])

      EvoGit.AgentState.Anchor.anchor(repo, task_id, agent_id, anchored)
      anchor_ref = EvoGit.AgentState.Anchor.ref(task_id, agent_id)
      assert wait_for_sha(repo, anchor_ref, anchored) == anchored

      git!(repo, ["branch", "-D", branch])
      refute Git.branch_exists?(repo, branch)

      persisted = spec(repo, missing, worktree_branch: branch)
      meta = meta(agent_id, task_id, persisted, task_number: 1)
      Store.put_agent_state(agent_id, summary_row(1))
      Store.put_sched_meta(agent_id, meta)
      cleanup_agent(agent_id)

      File.mkdir_p!(Worktrees.workers_dir(repo))
      wt_path = Path.join(Worktrees.workers_dir(repo), "worker_T1_A1")
      on_exit(fn -> File.rm_rf(wt_path) end)

      assert {:ok, ^wt_path} =
               Worktrees.prepare_new_worktree(agent_id, repo, wt_path, persisted, meta)

      assert Git.branch_exists?(repo, branch)
      assert {:ok, ^anchored} = Git.rev_parse(repo, branch)
    end

    test "ensure_resume_base/4 answers nil, the anchor sha, then a warned nil", %{
      repo: repo,
      base: base,
      missing: missing
    } do
      anchored_agent = unique_agent_id()
      anchored_task = unique_task_id()
      branch = "evogit-agent-T1-A1"

      git!(repo, ["checkout", "-q", "-b", branch])
      anchored = commit!(repo, "anchor-work.txt", "anchor work\n", "anchor work")
      git!(repo, ["checkout", "-q", "--detach", base])

      EvoGit.AgentState.Anchor.anchor(repo, anchored_task, anchored_agent, anchored)
      anchor_ref = EvoGit.AgentState.Anchor.ref(anchored_task, anchored_agent)
      assert wait_for_sha(repo, anchor_ref, anchored) == anchored

      git!(repo, ["branch", "-D", branch])

      verified = spec(repo, base, worktree_branch: branch)
      verified_meta = meta(anchored_agent, anchored_task, verified, task_number: 1)

      assert Worktrees.ensure_resume_base(repo, branch, verified, verified_meta) == nil

      unverifiable = spec(repo, missing, worktree_branch: branch)
      unverifiable_meta = meta(anchored_agent, anchored_task, unverifiable, task_number: 1)

      assert Worktrees.ensure_resume_base(repo, branch, unverifiable, unverifiable_meta) ==
               anchored

      orphan = spec(repo, missing, worktree_branch: "evogit-agent-T1-A2")
      orphan_meta = meta(unique_agent_id(), unique_task_id(), orphan, task_number: 1)

      log =
        capture_log(fn ->
          assert Worktrees.ensure_resume_base(repo, "evogit-agent-T1-A2", orphan, orphan_meta) ==
                   nil
        end)

      assert log =~ "could not re-establish the resume base"
    end
  end

  describe "persistent_state: false" do
    test "never restores and never pins a branch", %{repo: repo, base: base} do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      seed_summary!(agent_id, task_local_id: 1)

      spec =
        spec(repo, base,
          persistent_state: false,
          resume_kind: :clean_pause,
          pause_commit: nil,
          resume_branch: "evogit-agent-T2-A5"
        )

      meta = meta(agent_id, task_id, spec, task_number: 1)
      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.persistent_state == false
      assert plan.restore_agent_state == false
      refute Keyword.has_key?(plan.spec.opts, :worktree_branch)
      assert Worktrees.branch_for(meta, 1, plan.spec) == Worktrees.branch_name(1, 1)
    end
  end

  describe "Dispatch.resume_registration_opts/1" do
    test "passes a positive persisted id through", %{repo: repo, base: base} do
      assert Dispatch.resume_registration_opts(spec(repo, base, resume_agent_id: 7)) ==
               [agent_id: 7]
    end

    test "answers no opts for an absent or invalid id", %{repo: repo, base: base} do
      assert Dispatch.resume_registration_opts(spec(repo, base)) == []

      for bogus <- [nil, 0, -1, "7"] do
        assert Dispatch.resume_registration_opts(spec(repo, base, resume_agent_id: bogus)) == [],
               "expected no registration opts for #{inspect(bogus)}"
      end
    end

    test "is total for a non-spec input (only a real spec is read)" do
      # A map carrying an id is NOT a spec: the total fallback answers no opts
      # rather than trusting an unvalidated shape.
      assert Dispatch.resume_registration_opts(%{opts: [resume_agent_id: 11]}) == []
      assert Dispatch.resume_registration_opts(nil) == []
      assert Dispatch.resume_registration_opts(%{}) == []
      assert Dispatch.resume_registration_opts(:nope) == []
    end
  end

  defp unique_agent_id, do: 8_800_000 + System.unique_integer([:positive])
  defp unique_task_id, do: "resume-plan-#{System.unique_integer([:positive])}"

  defp spec(repo, base_sha, extra_opts \\ []) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: base_sha, current_commit: base_sha},
      agent_module: StubAgent,
      objective: "resume plan test",
      repo_id: "primary",
      opts: [model_id_locked: true] ++ extra_opts
    }
  end

  defp meta(agent_id, task_id, spec, opts) do
    %SchedMeta{
      id: agent_id,
      depth: Keyword.get(opts, :depth, 0),
      spec: spec,
      retries: Keyword.get(opts, :retries, 0),
      task_number: Keyword.get(opts, :task_number, 1),
      task_id: task_id,
      crash_commit: Keyword.get(opts, :crash_commit)
    }
  end

  defp dispatch_ctx(agent_id, meta, plan, repo) do
    Dispatch.build_dispatch_ctx(
      agent_id,
      meta,
      summary_row(1),
      plan,
      repo,
      Path.join([repo, ".genesis/workers", "worker_T#{meta.task_number}_A1"])
    )
  end

  defp summary_row(task_local_id) do
    %EvoGit.AgentScheduler.AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/primary"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8,
      task_local_id: task_local_id,
      current_commit: nil
    }
  end

  defp seed_summary!(agent_id, opts) do
    Store.put_agent_state(agent_id, summary_row(Keyword.fetch!(opts, :task_local_id)))
    on_exit(fn -> Store.delete_agent_state(agent_id) end)
  end

  defp cleanup_agent(agent_id) do
    on_exit(fn ->
      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
    end)
  end

  defp wait_for_sha(repo, ref, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    case Git.rev_parse(repo, ref) do
      {:ok, ^expected} ->
        expected

      _not_yet ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("anchor ref #{ref} never reached #{expected} in #{repo}")
        else
          Process.sleep(20)
          wait_for_sha(repo, ref, expected, deadline)
        end
    end
  end

  defp commit!(repo, path, content, message) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    git!(repo, ["add", path])
    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
