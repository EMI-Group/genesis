defmodule EvoGit.AgentScheduler.WholeTreeResumeTest do
  @moduledoc """
  The WHOLE durable whole-tree resume chain, walked end to end for ONE real
  task with a durable ROOT row and two durable CHILD rows.

  Every link of the chain is pinned here, in the order production walks it:

    1. the task is parked `:paused` (a user pause writes `pause_kind: :clean`,
       a boot/lease-sweep restart writes `:dirty`);
    2. `EvoGit.TaskRegistry.resume_task/1` — the public entry point — accepts
       the row and re-enqueues the SAME task id;
    3. the spawn opts handed to the wrapper carry the resume facts the
       registry resolved from the durable ROOT row (`:resume_kind`,
       `:resume_agent_id`, `:pause_commit`, `:resume_current_commit`,
       `:resume_branch`, `:resume_anchor_ref`);
    4. `EvoGit.AgentScheduler.Dispatch` registers the ROOT under its PERSISTED
       `agent_id` (asserted on the real `%SchedMeta{}` ETS row, with nothing
       allocated at the counter);
    5. `EvoGit.AgentScheduler.ResumePlan` + `Dispatch.build_dispatch_ctx/6` +
       `EvoGit.Agent.Session.Setup.build_initial_state/3` restore the ROOT's
       FULL transcript and scalars from the durable row while the NEW dispatch's
       worktree/branch/base win;
    6. the parent's dangling subagent batch is rebuilt from the durable roster
       (`RosterBatch.plan/4` → `SubagentRebuild.handle_rebuild/6`): the `done`
       slot contributes its STORED result with no re-spawn, the `running` slot
       is re-registered under its PERSISTED `agent_id` with its own persisted
       spawn position and `restore_agent_state: true`;
    7. the child results merge into the PARENT WORKTREE through the ordinary
       `EvoGit.Agent.SubagentProcessing` merge path — asserted with real git
       objects: both child files land, HEAD advances onto a merge commit, and
       the child branches are deleted as merged.

  ## Why `async: true`
  Everything is per-test isolated: `EvoGit.TaskRegistryCase` gives this test its
  OWN `EvoGit.Store` + `EvoGit.VCT` + registry (unique names, own SQLite file),
  the durable agent state is a private unnamed `EvoGit.AgentState` server
  injected through the registry's `:agent_state_server` init option (and pointed
  at from the test process through the `:evogit_agent_state_server` seam), the
  wrapper and rebuild spawns are explicit function seams, and the scheduler is
  an UNNAMED PAUSED instance of this test's own. The only app-global tables
  touched are `:evogit_sched_meta` / `:evogit_agent_summary`, written under this
  test's own high id range and deleted BY ID in `on_exit`.
  No LLM is ever called: the paused scheduler registers and QUEUES, the rebuild
  spawn is a seam that performs the real `Dispatch.register_agent/8` but never
  `try_dispatch/2`, and no `EvoGit.Agent.Session` is started.
  """
  use EvoGit.TaskRegistryCase, async: true

  @moduletag :tmp_dir

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Resume.RosterBatch
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State, as: SchedulerState
  alias EvoGit.AgentScheduler.Store, as: SchedulerStore
  alias EvoGit.AgentScheduler.SubagentRebuild
  alias EvoGit.AgentSpec
  alias EvoGit.AgentState
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A real `EvoGit.Agent` role: `build_initial_state/3` needs `system_prompt/0`
  # and the durable rows carry this module so a rebuild can reconstruct a spec.
  #
  # Defined ABOVE the test bodies on purpose (`mix test` starts the async runner
  # before the file finishes loading).
  defmodule StubAgent do
    use EvoGit.Agent

    @doc "The role's fixed system prompt."
    def system_prompt, do: "You are the whole-tree resume test role."

    @doc "No tools: nothing here ever runs a turn."
    def available_tools, do: []
  end

  @turn 4

  setup %{tmp_dir: tmp_dir, data_dir: data_dir} do
    repo = Path.join(tmp_dir, "repo")
    fixture = init_repo!(repo)

    # The durable store this task's runs live in — NEVER the app-global writer.
    state_pid =
      start_supervised!(
        {EvoGit.AgentState,
         database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000},
        id: :whole_tree_resume_agent_state
      )

    Process.put(:evogit_agent_state_server, state_pid)
    registry = start_registry!(state_pid, data_dir)
    id_base = 96_000_000 + System.unique_integer([:positive]) * 10
    ids = Enum.to_list(id_base..(id_base + 9))

    on_exit(fn ->
      for id <- ids do
        SchedulerStore.delete_agent_state(id)
        SchedulerStore.delete_sched_meta(id)
      end
    end)

    {:ok,
     fixture
     |> Map.merge(%{
       repo: repo,
       state_pid: state_pid,
       registry: registry,
       id_base: id_base,
       root_id: id_base + 1,
       done_child_id: id_base + 2,
       running_child_id: id_base + 3
     })}
  end

  describe "a CLEAN pause resumes the whole tree" do
    test "task -> dispatch -> restore -> rebuild -> merge", ctx do
      %{
        repo: repo,
        state_pid: state_pid,
        root_id: root_id,
        done_child_id: done_child_id,
        running_child_id: running_child_id,
        pause_sha: pause_sha,
        base_sha: base_sha,
        branch: branch
      } = ctx

      task_id = unique_task_id("whole_tree_clean")
      done_branch = "evogit-agent-done-#{root_id}"
      running_branch = "evogit-agent-running-#{root_id}"

      done_sha =
        add_child_branch!(repo, base_sha, done_branch, "src/done.txt", "done child work\n")

      running_sha =
        add_child_branch!(repo, base_sha, running_branch, "src/running.txt", "running work\n")

      # --- (1) the task was parked :paused with pause_kind :clean -------------
      seed_task!(task_id, :paused,
        pause_kind: :clean,
        lease_expires_at: nil,
        opts: [
          path: repo,
          mode: "simple",
          archive: true,
          persistent_state: true
        ],
        result: "paused run report",
        usage: %EvoGit.Agent.Usage{total_tokens: 77},
        commit_sha: pause_sha,
        base_sha: base_sha,
        branch_name: branch
      )

      anchor_ref = seed_root_run!(state_pid, task_id, root_id, ctx, branch)

      seed_child_run!(state_pid, task_id, done_child_id, %{
        parent_id: root_id,
        depth: 1,
        spawn_turn: @turn,
        spawn_index: 0,
        status: "done",
        objective: "durable done child",
        branch: done_branch,
        current_commit: done_sha,
        result: %{"text" => "done child report", "commit" => done_sha, "repo_id" => "primary"}
      })

      seed_child_run!(state_pid, task_id, running_child_id, %{
        parent_id: root_id,
        depth: 1,
        spawn_turn: @turn,
        spawn_index: 1,
        status: "running",
        objective: "durable running child",
        branch: running_branch,
        base_commit: base_sha,
        current_commit: running_sha,
        anchor_ref: EvoGit.AgentState.Anchor.ref(task_id, running_child_id),
        redispatch: %{
          "agent_type" => "read_write",
          "delegation_level" => "high",
          "objective" => "durable running child",
          "node_path" => "./src",
          "repo_id" => "primary",
          "parent_id" => root_id,
          "depth" => 1,
          "spawn_turn" => @turn,
          "spawn_index" => 1
        }
      })

      # --- (2) + (3) resume_task/1 re-enqueues the SAME id with the facts ----
      assert :ok = TaskRegistry.resume_task(task_id)
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id}, 2_000

      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause
      assert Keyword.get(spawn_opts, :resume_agent_id) == root_id
      assert Keyword.get(spawn_opts, :pause_commit) == pause_sha
      assert Keyword.get(spawn_opts, :resume_current_commit) == pause_sha
      assert Keyword.get(spawn_opts, :resume_branch) == branch
      assert Keyword.get(spawn_opts, :resume_anchor_ref) == anchor_ref

      resumed = reload_task!(task_id)
      assert resumed.status == :running
      assert resumed.pause_kind == nil
      # The SAME task id: the resume minted no second row.
      assert Enum.map(TaskRegistry.list_tasks(), & &1.id) == [task_id]

      # --- (4) the dispatch registers the ROOT under its PERSISTED id --------
      counter = ctx.id_base + 20
      scheduler = start_scheduler!(counter)
      dispatch_root!(scheduler, root_spec(repo, task_id, base_sha, spawn_opts))

      assert wait_for_registered_id(task_id) == root_id
      ## The real scheduler row — never a helper's return value.
      assert {:ok,
              %SchedMeta{id: ^root_id, depth: 0, parent_id: nil, task_id: ^task_id, spec: stored}} =
               SchedulerStore.get_sched_meta(root_id)

      ## Nothing was allocated at the counter, so this can only be an adoption —
      ## and since the counter sat ABOVE the persisted id it did not even move
      ## (an allocation would have handed out `counter` and moved past it).
      assert SchedulerStore.get_sched_meta(counter) == :error
      assert %SchedulerState{next_agent_id: next} = :sys.get_state(scheduler)
      assert next == counter

      ## The resume facts survived registration on the STORED spec.
      assert Keyword.get(stored.opts, :resume_kind) == :clean_pause
      assert Keyword.get(stored.opts, :resume_agent_id) == root_id
      assert Keyword.get(stored.opts, :pause_commit) == pause_sha

      # --- (5) the resumed session restores the ROOT's durable state ---------
      assert {:ok, meta} = SchedulerStore.get_sched_meta(root_id)
      assert {:ok, row} = SchedulerStore.get_agent_state(root_id)
      assert row.parent_id == nil

      plan = Dispatch.resume_plan(root_id, meta.spec, meta, repo, 0)
      assert plan.resume_kind == :clean_pause
      assert plan.restore_agent_state == true
      assert plan.persistent_state == true
      assert plan.worktree_resume_from == pause_sha
      ## The PERSISTED branch is reused, not the fresh name a first attempt gets.
      assert plan.branch == branch
      refute plan.branch == EvoGit.AgentScheduler.Worktrees.branch_name(meta.task_number, 1)
      assert plan.spec.opts[:worktree_branch] == branch
      assert plan.spec.phylo_node.current_commit == pause_sha

      ## The resumed run's OWN worktree: a real checkout of the persisted branch
      ## at the checkpoint commit (exactly what the WorktreeManager creates).
      worktree = Path.join([ctx.tmp_dir, ".genesis", "workers", "worker_T1_A1"])
      git!(repo, ["worktree", "add", "-q", "-b", branch, worktree, pause_sha])

      dispatch_ctx = Dispatch.build_dispatch_ctx(root_id, meta, row, plan, repo, worktree)
      assert dispatch_ctx[:restore_agent_state] == true
      assert dispatch_ctx[:persistent_state] == true
      assert dispatch_ctx[:resume_kind] == :clean_pause
      assert dispatch_ctx[:branch] == branch
      assert dispatch_ctx[:base_commit] == pause_sha
      assert dispatch_ctx[:worktree_path] == worktree

      state = build_initial_state!(dispatch_ctx, row)
      ## The durable transcript is AUTHORITATIVE — it replaces `[system, user]`.
      assert state.context.messages == persisted_root_messages()
      assert state.turn == @turn
      assert state.usage.input_tokens == 10
      assert state.usage.output_tokens == 2
      assert state.total_tokens == 1234
      assert state.compression_count == 2
      assert state.prompt_cache_key == "persisted-cache-key"
      assert state.pending_inputs == ["restored pending input"]
      assert state.objective == "durable root objective"
      assert state.current_commit == pause_sha
      ## …while the NEW dispatch's identity, worktree and branch win.
      assert state.agent_id == root_id
      assert state.task_id == task_id
      assert state.repo_root == repo
      assert state.repo_path == worktree
      assert state.branch == branch
      assert state.base_commit == pause_sha
      assert state.spawn_turn == nil
      assert state.persistent_state == true

      # --- (6) the dangling subagent batch is rebuilt from the roster --------
      assert {:ok, rebuild} = RosterBatch.plan(state, @turn, 2)
      assert [done_slot, running_slot] = rebuild.entries

      assert done_slot.status == :done
      assert done_slot.agent_id == done_child_id
      assert done_slot.spec == nil
      assert {:ok, %Result{} = stored_result} = done_slot.result
      assert stored_result.result == "done child report"
      assert stored_result.commit_sha == done_sha

      assert running_slot.status == :running
      assert running_slot.agent_id == running_child_id
      assert running_slot.result == nil
      assert running_slot.spec.opts[:resume_agent_id] == running_child_id
      assert running_slot.spec.opts[:restore_agent_state] == true
      assert running_slot.spec.opts[:resume_current_commit] == running_sha
      assert running_slot.spec.opts[:resume_branch] == running_branch
      ## A re-spawned child is a crash retry of ITS OWN run, never a pause.
      refute Keyword.has_key?(running_slot.spec.opts, :resume_kind)

      from = {self(), make_ref()}

      assert {:noreply, reattached} =
               SubagentRebuild.handle_rebuild(
                 root_id,
                 rebuild,
                 5_000,
                 from,
                 [spawn_fun: rebuild_spawn(self())],
                 :sys.get_state(scheduler)
               )

      assert_received {:rebuild_spawned, 1, ^running_child_id, registration_opts, child_spec}
      assert registration_opts[:agent_id] == running_child_id
      assert registration_opts[:spawn_index] == 1
      assert registration_opts[:spawn_turn] == @turn
      assert child_spec.opts[:resume_agent_id] == running_child_id

      ## The re-spawn really registered the child — under its PERSISTED id, one
      ## level below the ROOT, still un-dispatched (the scheduler is paused).
      assert {:ok,
              %SchedMeta{id: ^running_child_id, parent_id: ^root_id, depth: 1, spec: child_stored}} =
               SchedulerStore.get_sched_meta(running_child_id)

      assert Keyword.get(child_stored.opts, :resume_agent_id) == running_child_id
      assert Keyword.get(child_stored.opts, :restore_agent_state) == true
      ## The counter value was free the whole time and stayed unregistered: the
      ## child came back under its PERSISTED id, never a freshly allocated one.
      assert SchedulerStore.get_sched_meta(counter) == :error

      ## …and the batch installed exactly the scheduler state a live batch does:
      ## the done slot's STORED result in place, one waiter, one live child.
      assert {:ok, parent} = SchedulerStore.get_sched_meta(root_id)
      assert parent.status == :waiting
      assert parent.total_sub_specs == 2
      assert parent.sub_agent_results == %{0 => {:ok, stored_result}}
      assert parent.sub_agent_indices == %{running_child_id => 1}
      assert parent.pending_sub_agents == MapSet.new([running_child_id])
      assert reattached.reattach_waiters[root_id] == from

      # --- (7) the child results merge into the PARENT WORKTREE --------------
      ## The ONE production sequence (`SubagentProcessing`): collect the
      ## mergeable same-repo children, merge them, drop the merged branches.
      specs_with_index = [
        {0, merge_spec(repo, "durable done child", done_branch)},
        {1, running_slot.spec}
      ]

      ## The re-spawned child's own completion: the sha its persisted branch
      ## carries (produced by the run this batch awaits).
      results = [
        done_slot.result,
        {:ok,
         %Result{
           result: "re-spawned",
           commit_sha: running_sha,
           branch: running_branch,
           repo_id: "primary"
         }}
      ]

      {children, cross_repo} =
        SubagentProcessing.collect_mergeable_results(specs_with_index, results, "primary")

      assert cross_repo == []
      assert Enum.map(children, & &1.commit_sha) == [done_sha, running_sha]

      report = SubagentProcessing.perform_merge(worktree, children, "./")
      assert report.status == :clean
      assert Enum.all?(report.entries, &(&1.status == :merged))
      :ok = SubagentProcessing.delete_merged_branches(report, worktree)

      ## Real git objects: both children's files are IN the parent worktree,
      ## HEAD moved onto a merge commit that has both children as parents.
      assert File.read!(Path.join(worktree, "src/done.txt")) == "done child work\n"
      assert File.read!(Path.join(worktree, "src/running.txt")) == "running work\n"
      head = git!(worktree, ["rev-parse", "HEAD"])
      refute head == pause_sha
      parents = String.split(git!(worktree, ["rev-list", "--parents", "-n", "1", "HEAD"]))
      ## An OCTOPUS merge of the two children: three parents.
      assert [^head | merged_parents] = parents
      assert length(merged_parents) == 3
      assert pause_sha in merged_parents
      assert done_sha in merged_parents
      assert running_sha in merged_parents
      assert git!(repo, ["branch", "--list", done_branch]) == ""
      assert git!(repo, ["branch", "--list", running_branch]) == ""
    end
  end

  describe "a DIRTY (restart-classified) pause resumes the same task" do
    test "boot parks the live row :paused/:dirty and resume carries :dirty_pause", ctx do
      %{
        repo: repo,
        state_pid: state_pid,
        registry: registry,
        root_id: root_id,
        pause_sha: pause_sha,
        base_sha: base_sha,
        branch: branch
      } = ctx

      task_id = unique_task_id("whole_tree_dirty")
      # The registry must boot AFTER the row exists (a fresh instance's `init/1`
      # is the restart classification), and this instance needs the durable
      # seams, so the case-provided one is replaced.
      stop_supervised(registry)

      seed_task!(task_id, :running,
        lease_expires_at: System.system_time(:second) + 300,
        opts: [path: repo, mode: "simple", persistent_state: true],
        result: "pre-restart report"
      )

      seed_root_run!(state_pid, task_id, root_id, ctx, branch)

      start_registry!(state_pid, ctx.data_dir)

      parked = reload_task!(task_id)
      assert parked.status == :paused
      assert parked.pause_kind == :dirty
      assert parked.lease_expires_at == nil
      assert parked.result == "pre-restart report"

      assert :ok = TaskRegistry.resume_task(task_id)
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id}, 2_000

      assert Keyword.get(spawn_opts, :resume_kind) == :dirty_pause
      assert Keyword.get(spawn_opts, :resume_agent_id) == root_id
      assert Keyword.get(spawn_opts, :pause_commit) == pause_sha
      assert reload_task!(task_id).status == :running
      assert Enum.map(TaskRegistry.list_tasks(), & &1.id) == [task_id]

      # The dispatch agrees: a dirty pause still restores the durable run.
      scheduler = start_scheduler!(ctx.id_base + 20)
      dispatch_root!(scheduler, root_spec(repo, task_id, base_sha, spawn_opts))
      assert wait_for_registered_id(task_id) == root_id

      assert {:ok, meta} = SchedulerStore.get_sched_meta(root_id)
      plan = Dispatch.resume_plan(root_id, meta.spec, meta, repo, 0)
      assert plan.resume_kind == :dirty_pause
      assert plan.restore_agent_state == true
      assert plan.worktree_resume_from == pause_sha
      assert plan.branch == branch
    end
  end

  # --- Fixtures ------------------------------------------------------------

  # A REAL git repo: `main` at the pause checkpoint, plus two child branches
  # forked from the task base (so both merges are genuine three-way merges,
  # never fast-forwards).
  defp init_repo!(repo) do
    File.mkdir_p!(Path.join(repo, "src"))
    File.write!(Path.join(repo, "CONTEXT.md"), "# Whole-tree resume fixture\n")
    File.write!(Path.join(repo, "src/base.txt"), "base\n")

    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "whole-tree-resume@example.com"])
    git!(repo, ["config", "user.name", "Whole Tree Resume"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    base_sha = commit_all!(repo, "base")
    main = git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"])

    File.write!(Path.join(repo, "paused.txt"), "the paused run's own work\n")
    pause_sha = commit_all!(repo, "pause checkpoint")

    %{main_branch: main, base_sha: base_sha, pause_sha: pause_sha, branch: "evogit-agent-T1-A1"}
  end

  # One child branch forked from the task BASE, carrying one committed file.
  defp add_child_branch!(repo, base, branch, path, content) do
    main = git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    git!(repo, ["checkout", "-q", "-b", branch, base])
    File.mkdir_p!(Path.dirname(Path.join(repo, path)))
    File.write!(Path.join(repo, path), content)
    sha = commit_all!(repo, "child work on #{branch}")
    git!(repo, ["checkout", "-q", main])
    sha
  end

  defp commit_all!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end

  # The durable ROOT run: full transcript + every scalar the restore owns, plus
  # the run facts a resume carries (`pause_commit`, `branch`, `anchor_ref`).
  defp seed_root_run!(server, task_id, root_id, ctx, branch) do
    anchor_ref = EvoGit.AgentState.Anchor.ref(task_id, root_id)

    :ok =
      AgentState.checkpoint(
        task_id,
        root_id,
        %{
          kind: :rewrite,
          messages: persisted_root_messages(),
          fields: %{
            depth: 0,
            agent_module: StubAgent,
            objective: "durable root objective",
            node_path: "./",
            repo_id: "primary",
            phase: "paused",
            turn: @turn,
            usage: %{
              "input_tokens" => 10,
              "output_tokens" => 2,
              "total_tokens" => 12,
              "input_cost" => 0,
              "output_cost" => 0,
              "total_cost" => 0,
              "cached_tokens" => 0,
              "cache_creation_tokens" => 0
            },
            total_tokens: 1234,
            compression_count: 2,
            prompt_cache_key: "persisted-cache-key",
            pending_inputs: ["restored pending input"],
            current_commit: ctx.pause_sha,
            pause_commit: ctx.pause_sha,
            branch: branch,
            base_commit: ctx.base_sha,
            anchor_ref: anchor_ref,
            archive: false,
            repo_root: ctx.repo
          }
        },
        store: server
      )

    :ok = AgentState.flush(server)
    assert {:ok, %EvoGit.AgentState.Record{}} = AgentState.load(task_id, root_id, store: server)
    anchor_ref
  end

  defp seed_child_run!(server, task_id, child_id, fields) do
    :ok =
      AgentState.checkpoint(
        task_id,
        child_id,
        %{
          kind: :rewrite,
          messages: persisted_child_messages(child_id),
          fields:
            Map.merge(
              %{agent_module: StubAgent, node_path: "./src", repo_id: "primary", archive: false},
              fields
            )
        },
        store: server
      )

    :ok = AgentState.flush(server)
    :ok
  end

  defp persisted_root_messages do
    [
      message(:system, "persisted root system prompt"),
      message(:user, "durable root turn"),
      message(:assistant, "persisted root reply")
    ]
  end

  defp persisted_child_messages(child_id), do: [message(:user, "durable child #{child_id}")]

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [ReqLLM.Message.ContentPart.text(text)]}
  end

  # --- Task-store fixtures -------------------------------------------------

  defp seed_task!(task_id, status, extra) do
    task = %TaskInfo{
      id: task_id,
      type: :genesis,
      status: status,
      opts: Keyword.fetch!(extra, :opts),
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: Keyword.get(extra, :result),
      usage: Keyword.get(extra, :usage),
      review_status: nil,
      base_sha: Keyword.get(extra, :base_sha),
      commit_sha: Keyword.get(extra, :commit_sha),
      branch_name: Keyword.get(extra, :branch_name),
      session_mode: "oneshot",
      pause_kind: Keyword.get(extra, :pause_kind),
      lease_expires_at: Keyword.get(extra, :lease_expires_at)
    }

    :ok = EvoGit.Store.put_task(store(), task)
    task
  end

  defp reload_task!(task_id) do
    case EvoGit.Store.get_task(store(), task_id) do
      %TaskInfo{} = task -> task
      other -> flunk("expected a persisted task row, got #{inspect(other)}")
    end
  end

  # --- Registry seams ------------------------------------------------------

  # A per-test registry carrying BOTH seams: the agent-state store a resume
  # admission reads inside the REGISTRY process, and a wrapper spawn that
  # reports the propagated opts instead of running a real runtime.
  defp start_registry!(state_pid, data_dir) do
    unique = System.unique_integer([:positive])
    name = :"evogit_whole_tree_registry_#{unique}"
    test_pid = self()

    spawn_fun = fn task_type, spawn_opts, task_id, _server ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:wrapper_spawned, task_type, spawn_opts, task_id})

      %Task{
        pid: pid,
        ref: make_ref(),
        owner: test_pid,
        mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [task_type, spawn_opts, task_id]}
      }
    end

    start_supervised!(
      Supervisor.child_spec(
        {TaskRegistry,
         task_store: store(),
         data_dir: data_dir,
         name: name,
         agent_state_server: state_pid,
         wrapper_spawn_fun: spawn_fun},
        id: name
      )
    )

    Process.put(:evogit_task_registry_server, name)
    name
  end

  # --- Scheduler seams -----------------------------------------------------

  # ONE UNNAMED, PAUSED scheduler instance of this test's own: `{:run_agent,
  # spec}` REGISTERS the root and then QUEUES it, so no session, worktree or
  # LLM work ever happens. The counter starts BELOW the persisted id so an
  # adoption is distinguishable from an allocation.
  defp start_scheduler!(counter) do
    {:ok, pid} = GenServer.start(EvoGit.AgentScheduler, [])
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)

    :sys.replace_state(pid, fn _state ->
      %{
        SchedulerState.from_model_profiles([%{id: "default", model: "provider:default"}])
        | next_agent_id: counter,
          paused: true
      }
    end)

    pid
  end

  # The production root entrance: the caller blocks in `{:run_agent, spec}` for
  # the whole run (killed at test exit rather than promised a terminal term
  # this fixture deliberately never produces).
  defp dispatch_root!(scheduler, spec) do
    caller = spawn(fn -> GenServer.call(scheduler, {:run_agent, spec}, :infinity) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    caller
  end

  # The ROOT spec a resumed task builds: the wrapper's OWN spawn opts (which
  # carry every resume fact) plus the locked legacy selection and the task id.
  defp root_spec(repo, task_id, base_sha, spawn_opts) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: base_sha, current_commit: base_sha},
      agent_module: StubAgent,
      objective: "whole-tree resume root",
      repo_id: "primary",
      opts: [model_id_locked: true, task_id: task_id] ++ spawn_opts
    }
  end

  defp merge_spec(repo, objective, branch) do
    %AgentSpec{
      context_node: %ContextNode{path: "./src", repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: "unused", current_commit: "unused"},
      agent_module: StubAgent,
      objective: objective,
      repo_id: "primary",
      opts: [worktree_branch: branch]
    }
  end

  # The rebuild spawn: the REAL `Dispatch.register_agent/8` under the child's
  # persisted id (exactly `SubagentRebuild`'s production `default_spawn/4`),
  # minus `try_dispatch/2` — the scheduler is paused, so the child is queued
  # rather than started.
  defp rebuild_spawn(test_pid) do
    fn state, parent_meta, entry, registration_opts ->
      send(
        test_pid,
        {:rebuild_spawned, entry.index, entry.agent_id, registration_opts, entry.spec}
      )

      case Dispatch.register_agent(
             state,
             entry.spec,
             nil,
             parent_meta.id,
             parent_meta.depth + 1,
             parent_meta.task_id,
             parent_meta.task_number,
             registration_opts
           ) do
        {:error, reason} -> {:error, reason, state}
        {child_id, next_state} -> {:ok, child_id, next_state}
      end
    end
  end

  # --- State projection ----------------------------------------------------

  # Mirrors the session's production `state_ctx` (`EvoGit.Agent.Session.build_state/2`)
  # with every key `Setup.build_initial_state/3` fetches, taken from the REAL
  # dispatch context and the REAL scheduler row.
  defp build_initial_state!(ctx, row) do
    spec = Keyword.fetch!(ctx, :spec)
    meta = Keyword.fetch!(ctx, :meta)

    state_ctx = [
      agent_id: Keyword.fetch!(ctx, :agent_id),
      depth: Keyword.fetch!(ctx, :depth),
      context_node: row.context_node,
      repo_path: Keyword.fetch!(ctx, :worktree_path),
      current_commit: row.current_commit,
      repo_root: Keyword.fetch!(ctx, :repo_root),
      repo_id: Keyword.fetch!(ctx, :repo_id),
      repo_less: false,
      task_id: meta.task_id,
      parent_id: row.parent_id,
      archive: row.archive,
      persistent_state: Keyword.fetch!(ctx, :persistent_state),
      restore_agent_state: Keyword.fetch!(ctx, :restore_agent_state),
      foreign_repos: row.foreign_repos || [],
      repo_notes: row.repo_notes,
      max_turns: row.max_turns,
      max_depth: row.max_depth,
      max_retries: row.max_retries,
      compression_count: row.compression_count,
      llm_context_window: row.llm_context_window,
      llm_model: row.llm_model,
      llm_generation_params: row.llm_generation_params,
      model_spec: row.model_spec,
      provider_profile_id: row.provider_profile_id,
      model_id: row.model_id,
      model_id_locked: row.model_id_locked,
      # No provider cache identity was minted for this non-OpenAI model; the
      # durable row's own key is what the restore must surface.
      prompt_cache_key: nil,
      session_mode: Keyword.fetch!(ctx, :session_mode),
      quality_level: Keyword.get(spec.opts, :quality_level),
      custom_agent_id: Keyword.get(spec.opts, :custom_agent_id),
      attachments: Keyword.get(spec.opts, :attachments),
      assistant_workspace: Keyword.get(spec.opts, :assistant_workspace),
      branch: Keyword.get(ctx, :branch),
      base_commit: Keyword.get(ctx, :base_commit),
      spawn_turn: Keyword.get(ctx, :spawn_turn),
      spawn_index: Keyword.get(ctx, :spawn_index),
      redispatch: nil
    ]

    assert {:ok, %State{} = state} =
             Setup.build_initial_state(spec.agent_module, spec.objective, state_ctx)

    state
  end

  # --- Awaiting ------------------------------------------------------------

  defp wait_for_registered_id(task_id) do
    wait_until(fn -> registered_id(task_id) != nil end)

    case registered_id(task_id) do
      nil -> flunk("no agent was registered for task #{inspect(task_id)}")
      id -> id
    end
  end

  defp registered_id(task_id) do
    SchedulerStore.list_sched_meta()
    |> Enum.find_value(fn
      {id, %SchedMeta{task_id: ^task_id}} -> id
      _other_row -> nil
    end)
  end

  defp wait_until(fun, timeout \\ 5_000) do
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

  defp unique_task_id(label), do: "#{label}_#{System.unique_integer([:positive])}"
end
