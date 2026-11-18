defmodule EvoGit.AgentScheduler.PauseResumeDispatchTest.StubAgent do
  @moduledoc """
  The role a pause-resume dispatch runs AS: only a well-formed spec matters —
  these tests call `Dispatch.resume_plan/5` directly and never start a session.
  """

  use EvoGit.Agent

  @doc "The role's canned system prompt."
  def system_prompt, do: "You are the pause-resume dispatch stub agent."

  @doc "No tools: nothing here executes."
  def available_tools, do: []
end

defmodule EvoGit.AgentScheduler.PauseResumeDispatchTest do
  @moduledoc """
  The DISPATCH half of task-level pause & resume: the ctx facts a resumed
  dispatch carries and the worktree base it restores from.

  `EvoGit.AgentScheduler.Dispatch.resume_plan/5` is the ONE production decision
  point (`do_try_dispatch/4` calls it and only consumes the result), exposed
  `@doc false` so this contract is pinned without starting a session.

  Pinned here:

    * a `:clean_pause` / `:dirty_pause` resume sets `restore_agent_state: true`
      and carries `resume_kind` — with NO retries involved;
    * the base precedence is `spec.opts[:pause_commit]` (then
      `spec.opts[:resume_current_commit]`, then `meta.crash_commit`, then the
      task base), and every candidate is VERIFIED against the repo
      (`git cat-file -e`) — an unusable sha degrades to the NEXT candidate
      instead of guessing;
    * a missing / unknown sha degrades to the task base (`worktree_resume_from`
      `nil`, spec untouched, dispatch still usable);
    * a `nil` `resume_kind` keeps today's crash-retry semantics byte-identical;
    * `persistent_state: false` never restores.

  `async: true`: each test starts its OWN unnamed `EvoGit.AgentState` server
  (pinned on the process dictionary) and builds its own git repo under
  `:tmp_dir`; no app env, ETS table, `:persistent_term` or PubSub topic is
  touched.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.PauseResumeDispatchTest.StubAgent
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentSpec
  alias EvoGit.AgentState
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

    {:ok, repo: repo, base: base, pause: pause}
  end

  describe "a pause resume" do
    test "a clean pause bases the worktree on the per-agent pause checkpoint", %{
      repo: repo,
      base: base,
      pause: pause
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      seed_pause_checkpoint!(task_id, agent_id, pause)
      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :clean_pause)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.resume_kind == :clean_pause
      assert plan.restore_agent_state == true
      assert plan.persistent_state == true
      assert plan.worktree_resume_from == pause

      # The base the worktree is created from IS the pause checkpoint, and the
      # rewritten spec is what gets persisted/dispatched.
      assert plan.spec.phylo_node.current_commit == pause
      assert plan.meta.spec.phylo_node.current_commit == pause
    end

    test "a pause checkpoint wins over a restart salvage commit", %{
      repo: repo,
      base: base,
      pause: pause
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      seed_pause_checkpoint!(task_id, agent_id, pause)
      salvage = commit!(repo, "salvaged.txt", "salvaged\n", "salvage after restart")

      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :dirty_pause)
      # A restart may ALSO have salvaged the paused worktree (`crash_commit`).
      # Both are usable, and the PAUSE CHECKPOINT is the one the pause finalizer
      # recorded for this agent, so it wins.
      meta = %{meta | retries: 1, crash_commit: salvage, crash_reason: {:error, :restart}}

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 1)

      assert plan.resume_kind == :dirty_pause
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == pause
      assert plan.spec.phylo_node.current_commit == pause
    end

    test "degrades to the restart salvage commit when the pause checkpoint is unusable", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      # The stored checkpoint sha resolves to nothing in this repo (a pruned
      # commit, a different repo): the salvage commit of the crashed attempt is
      # then the best base available.
      seed_pause_checkpoint!(task_id, agent_id, "0123456789abcdef0123456789abcdef01234567")
      salvage = commit!(repo, "salvaged.txt", "salvaged\n", "salvage after restart")

      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :dirty_pause)
      meta = %{meta | retries: 1, crash_commit: salvage, crash_reason: {:error, :restart}}

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 1)

      assert plan.resume_kind == :dirty_pause
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == salvage
      assert plan.spec.phylo_node.current_commit == salvage
    end

    test "degrades to the task base when no pause checkpoint row exists", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :clean_pause)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      # The restore still happens (the transcript is what matters most), but the
      # unverifiable base degrades instead of guessing.
      assert plan.resume_kind == :clean_pause
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == nil
      assert plan.spec.phylo_node.current_commit == base
    end

    test "degrades to the task base when the checkpoint sha is not a commit", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      # A row whose sha resolves to nothing in this repo (a pruned commit, a
      # different repo): `git cat-file -e` says no.
      seed_pause_checkpoint!(task_id, agent_id, "0123456789abcdef0123456789abcdef01234567")

      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :dirty_pause)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.resume_kind == :dirty_pause
      assert plan.worktree_resume_from == nil
      assert plan.spec.phylo_node.current_commit == base
    end

    test "never restores when the task opted out of persistent state", %{
      repo: repo,
      base: base,
      pause: pause
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      seed_pause_checkpoint!(task_id, agent_id, pause)

      {spec, meta} =
        build(agent_id, task_id, repo, base, resume_kind: :clean_pause, persistent_state: false)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.persistent_state == false
      assert plan.restore_agent_state == false
      # The base rewrite is independent of the durability flag: the worktree
      # still starts where the pause left it.
      assert plan.worktree_resume_from == pause
    end
  end

  describe "the pause checkpoint is PRE-RESOLVED outside the scheduler" do
    test "spec.opts[:pause_commit] wins without any durable read", %{
      repo: repo,
      base: base,
      pause: pause
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      # NOTHING is stored for this run: a dispatch that read the store would
      # degrade to the task base. The pre-resolved opt is the only source.
      {spec, meta} =
        build(agent_id, task_id, repo, base, resume_kind: :clean_pause, pause_commit: pause)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.worktree_resume_from == pause
      assert plan.spec.phylo_node.current_commit == pause
    end

    test "a nil pre-resolved opt means \"nothing stored\" and skips the read too",
         %{repo: repo, base: base, pause: pause} do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      # A row DOES exist, but the resume already resolved it to `nil`: the
      # scheduler must not second-guess that decision by reading again.
      seed_pause_checkpoint!(task_id, agent_id, pause)

      {spec, meta} =
        build(agent_id, task_id, repo, base, resume_kind: :clean_pause, pause_commit: nil)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.worktree_resume_from == nil
      assert plan.spec.phylo_node.current_commit == base
    end

    test "the direct-dispatch fallback still resolves the stored checkpoint", %{
      repo: repo,
      base: base,
      pause: pause
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      seed_pause_checkpoint!(task_id, agent_id, pause)
      # NO `:pause_commit` key: a direct dispatch (a non-resume path). That read
      # is BOUNDED and OFFLOADED (never inline in the scheduler) and still
      # finds the stored checkpoint.
      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :clean_pause)

      {micros, plan} =
        :timer.tc(fn -> Dispatch.resume_plan(agent_id, spec, meta, repo, 0) end)

      assert div(micros, 1000) < 2_000
      assert plan.resume_kind == :clean_pause
      assert plan.worktree_resume_from == pause
      assert plan.spec.phylo_node.current_commit == pause
    end
  end

  describe "a run with no resume_kind (today's behaviour, byte-identical)" do
    test "a first attempt restores nothing and keeps the task base", %{repo: repo, base: base} do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      {spec, meta} = build(agent_id, task_id, repo, base)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.resume_kind == nil
      assert plan.restore_agent_state == false
      assert plan.worktree_resume_from == nil
      assert plan.spec == spec
      assert plan.spec.phylo_node.current_commit == base
    end

    test "a crash retry still bases the worktree on the salvaged commit", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()
      salvage = commit!(repo, "crash.txt", "crash work\n", "salvage")

      {spec, meta} = build(agent_id, task_id, repo, base)
      meta = %{meta | retries: 1, crash_commit: salvage, crash_reason: {:error, :boom}}

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 1)

      assert plan.resume_kind == nil
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == salvage
      assert plan.spec.phylo_node.current_commit == salvage
    end

    test "a crash retry with no usable salvage commit keeps the task base", %{
      repo: repo,
      base: base
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      {spec, meta} = build(agent_id, task_id, repo, base)
      meta = %{meta | retries: 1, crash_commit: nil}

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 1)

      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == nil
      assert plan.spec.phylo_node.current_commit == base
    end

    test "an unrecognized resume_kind is ignored", %{repo: repo, base: base} do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      {spec, meta} = build(agent_id, task_id, repo, base, resume_kind: :something_else)

      plan = Dispatch.resume_plan(agent_id, spec, meta, repo, 0)

      assert plan.resume_kind == nil
      assert plan.restore_agent_state == false
      assert plan.worktree_resume_from == nil
    end
  end

  describe "the runtime → dispatch hand-off" do
    test "a runtime :resume_kind reaches spec.opts and therefore the resume plan", %{
      repo: repo,
      base: base,
      pause: pause
    } do
      agent_id = unique_agent_id()
      task_id = unique_task_id()

      seed_pause_checkpoint!(task_id, agent_id, pause)

      spec =
        EvoGit.Runtime.Helpers.build_root_agent_spec(
          %ContextNode{path: "./", repo: repo},
          %PhyloGraphNode{repo: repo, base_commit: base, current_commit: base},
          StubAgent,
          "pause resume hand-off",
          [task_id: task_id, resume_kind: :clean_pause],
          [],
          nil
        )

      assert spec.opts[:resume_kind] == :clean_pause

      plan = Dispatch.resume_plan(agent_id, spec, meta(agent_id, task_id, spec), repo, 0)

      assert plan.resume_kind == :clean_pause
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == pause
    end

    test "a normal run carries NO :resume_kind key at all", %{repo: repo, base: base} do
      spec =
        EvoGit.Runtime.Helpers.build_root_agent_spec(
          %ContextNode{path: "./", repo: repo},
          %PhyloGraphNode{repo: repo, base_commit: base, current_commit: base},
          StubAgent,
          "normal run",
          [task_id: unique_task_id()],
          [],
          nil
        )

      refute Keyword.has_key?(spec.opts, :resume_kind)

      plan = Dispatch.resume_plan(unique_agent_id(), spec, meta(1, "t", spec), repo, 0)

      assert plan.resume_kind == nil
      assert plan.restore_agent_state == false
      assert plan.worktree_resume_from == nil
    end
  end

  ## Fixtures

  defp unique_agent_id, do: 9_980_000 + System.unique_integer([:positive])
  defp unique_task_id, do: "pause-dispatch-#{System.unique_integer([:positive])}"

  defp build(agent_id, task_id, repo, base_sha, opts \\ []) do
    spec_opts =
      [model_id_locked: true]
      |> put_if(:persistent_state, Keyword.get(opts, :persistent_state))
      |> put_if(:resume_kind, Keyword.get(opts, :resume_kind))
      |> put_if(:pause_commit, Keyword.get(opts, :pause_commit), fn _value ->
        Keyword.has_key?(opts, :pause_commit)
      end)

    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: base_sha, current_commit: base_sha},
      agent_module: StubAgent,
      objective: "pause resume dispatch test",
      repo_id: "primary",
      opts: spec_opts
    }

    {spec,
     %SchedMeta{id: agent_id, depth: 0, spec: spec, retries: 0, task_number: 1, task_id: task_id}}
  end

  defp meta(agent_id, task_id, spec) do
    %SchedMeta{id: agent_id, depth: 0, spec: spec, retries: 0, task_number: 1, task_id: task_id}
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  # `nil` is a VALUE here (a resolved "nothing stored"), so presence is decided
  # by the caller's `has_key?`, not by the value.
  defp put_if(opts, key, value, present?) do
    if present?.(value), do: Keyword.put(opts, key, value), else: opts
  end

  # One durable run row + its pause checkpoint sha, exactly as the pause path
  # leaves them.
  defp seed_pause_checkpoint!(task_id, agent_id, sha) do
    :ok =
      AgentState.checkpoint(task_id, agent_id, %{
        kind: :rewrite,
        base_seq: 0,
        messages: [%ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("hi")]}],
        fields: %{turn: 1},
        owner: self()
      })

    # `put_pause_commit/3` is a CALL through the same serialized writer, so it
    # lands after the cast above without any sleep.
    assert :ok = AgentState.put_pause_commit(task_id, agent_id, sha)
    AgentState.flush(agent_id)
    assert AgentState.pause_commit(task_id, agent_id) == sha
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
