defmodule EvoGit.Agent.Resume.RosterBatchTest do
  @moduledoc """
  Pins the WORKER-SIDE rebuild plan of whole-tree resume
  (`EvoGit.Agent.Resume.RosterBatch`): a parent's dangling subagent batch is
  rebuilt from the children's DURABLE rows, one slot per expected subagent call,
  in model call order.

  Contract pinned here:

    * a `status: "done"` row CONTRIBUTES its stored result (text, commit, repo
      id, branch) and needs no re-spawn;
    * a `status: "running"` row becomes a rebuilt `%AgentSpec{}` carrying the
      resume opts (persisted id, own base/branch/anchor, `restore_agent_state`);
      the resume KIND of the parent's batch decides the child's `:pause_commit`
      (clean: its OWN checkpoint; dirty: an explicit `nil` that suppresses the
      stale durable one) and adds its own `:resume_kind`, while a crash retry
      (`nil`) adds neither key;
    * a slot with no usable row is `:missing` (the scheduler answers it as
      `{:error, :subagent_result_lost}`);
    * slots are ordered by `spawn_index`, NOT by roster order, and a row from an
      EARLIER turn is never adopted;
    * `persistent_state: false`, a missing task id and an unknown turn all
      decline without touching the store.

  ## Why `async: true`

  Nothing global is touched: the roster is injected through the explicit
  `:roster_fun` option, no ETS/app-env/`:persistent_term` state is read or
  written, and no git command runs (`ContextNode.load/3` is pure and
  `EvoGit.AgentState.roster/1` is never called).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Resume.RosterBatch
  alias EvoGit.Agent.State
  alias EvoGit.AgentState.Record

  @task_id "roster-batch-task"
  @parent 700
  @child_a 701
  @child_b 702

  # --- Fixtures ---

  defp state(attrs \\ []) do
    struct!(
      %State{
        agent_id: @parent,
        agent_module: EvoGit.Agents.Executor,
        depth: 0,
        node_path: "./",
        context: ReqLLM.Context.new([]),
        task_id: @task_id,
        persistent_state: true,
        repo_id: "primary",
        repo_path: "/tmp/roster-batch-repo"
      },
      attrs
    )
  end

  defp record(agent_id, fields) do
    %Record{task_id: @task_id, agent_id: agent_id, fields: Map.new(fields)}
  end

  defp done_row(agent_id, index, opts \\ []) do
    record(
      agent_id,
      Keyword.merge(
        [
          parent_id: @parent,
          depth: 1,
          spawn_turn: 4,
          spawn_index: index,
          status: "done",
          agent_module: EvoGit.Agents.Executor,
          objective: "child #{agent_id}",
          node_path: "./src",
          repo_id: "primary",
          branch: "evogit-agent-child-#{agent_id}",
          current_commit: "commit-#{agent_id}",
          result: %{
            "text" => "done #{agent_id}",
            "commit" => "commit-#{agent_id}",
            "repo_id" => "primary"
          }
        ],
        opts
      )
    )
  end

  defp running_row(agent_id, index, opts \\ []) do
    record(
      agent_id,
      Keyword.merge(
        [
          parent_id: @parent,
          depth: 1,
          spawn_turn: 4,
          spawn_index: index,
          status: "running",
          agent_module: EvoGit.Agents.Executor,
          objective: "child #{agent_id}",
          node_path: "./src",
          repo_id: "primary",
          branch: "evogit-agent-child-#{agent_id}",
          base_commit: "base-#{agent_id}",
          current_commit: "commit-#{agent_id}",
          anchor_ref: "refs/genesis/agent-state/#{@task_id}/#{agent_id}",
          model_spec: %{"provider_profile_id" => "acct", "model" => "m"},
          redispatch: %{
            "agent_type" => "read_write",
            "delegation_level" => "high",
            "objective" => "child #{agent_id}",
            "node_path" => "./src",
            "repo_id" => "primary",
            "parent_id" => @parent,
            "depth" => 1,
            "spawn_turn" => 4,
            "spawn_index" => index
          }
        ],
        opts
      )
    )
  end

  defp plan(records, expected \\ 2, opts \\ []) do
    state = Keyword.get(opts, :state, state())
    turn = Keyword.get(opts, :turn, 4)
    plan_opts = Keyword.get(opts, :plan_opts, []) ++ [roster_fun: fn @task_id -> records end]

    RosterBatch.plan(state, turn, expected, plan_opts)
  end

  # --- slots ---

  test "a done child contributes its stored result without needing a re-spawn" do
    assert {:ok, %{turn: 4, expected_count: 2, entries: [first, second]}} =
             plan([done_row(@child_a, 0), done_row(@child_b, 1)])

    assert first.index == 0
    assert first.status == :done
    assert first.agent_id == @child_a
    assert first.spec == nil

    assert {:ok, result} = first.result
    assert result.result == "done #{@child_a}"
    assert result.commit_sha == "commit-#{@child_a}"
    assert result.repo_id == "primary"
    assert result.branch == "evogit-agent-child-#{@child_a}"

    assert {:ok, second_result} = second.result
    assert second_result.result == "done #{@child_b}"
  end

  test "a running child is rebuilt as a spec carrying its persisted identity and resume opts" do
    assert {:ok, %{entries: [entry]}} = plan([running_row(@child_a, 0)], 1)

    assert entry.status == :running
    assert entry.agent_id == @child_a
    assert entry.result == nil

    spec = entry.spec
    assert %EvoGit.AgentSpec{} = spec
    assert spec.agent_module == EvoGit.Agents.Executor
    assert spec.objective == "child #{@child_a}"
    assert spec.repo_id == "primary"
    assert spec.context_node.path == "./src"
    # The worktree base the spec carries is the child's OWN anchored base; the
    # newest commit travels as `:resume_current_commit` and
    # `EvoGit.AgentScheduler.ResumePlan` VERIFIES and applies it as the base.
    assert spec.phylo_node.base_commit == "base-#{@child_a}"
    assert spec.phylo_node.current_commit == "base-#{@child_a}"

    opts = spec.opts
    assert opts[:resume_agent_id] == @child_a
    assert opts[:resume_current_commit] == "commit-#{@child_a}"
    assert opts[:resume_branch] == "evogit-agent-child-#{@child_a}"
    assert opts[:resume_anchor_ref] == "refs/genesis/agent-state/#{@task_id}/#{@child_a}"
    assert opts[:restore_agent_state] == true
    assert opts[:persistent_state] == true
    # A child is a CRASH RETRY of its own run, never a pause resume.
    refute Keyword.has_key?(opts, :resume_kind)
  end

  test "a CLEAN pause resume carries the child's own pause checkpoint and its kind" do
    row = running_row(@child_a, 0, pause_commit: "pause-#{@child_a}")

    assert {:ok, %{entries: [entry]}} =
             plan([row], 1, plan_opts: [resume_kind: :clean_pause])

    # The clean-frozen child is still RUNNING: it is re-spawned with its OWN id.
    assert entry.status == :running
    assert entry.agent_id == @child_a
    spec = entry.spec
    assert %EvoGit.AgentSpec{} = spec
    opts = spec.opts
    assert opts[:resume_agent_id] == @child_a
    # Its worktree bases on its OWN pause checkpoint (the KEY's presence wins in
    # `ResumePlan`), and it takes the clean (no-repair) path itself.
    assert opts[:pause_commit] == "pause-#{@child_a}"
    assert opts[:resume_kind] == :clean_pause
    assert opts[:restore_agent_state] == true
  end

  test "a DIRTY pause resume SUPPRESSES a stale pause checkpoint" do
    # A `pause_commit` column left over from an EARLIER pause must never be used
    # after a crash: the key is present with `nil`, which wins over the durable
    # fallback read.
    row = running_row(@child_a, 0, pause_commit: "stale-pause")

    assert {:ok, %{entries: [entry]}} =
             plan([row], 1, plan_opts: [resume_kind: :dirty_pause])

    assert entry.status == :running
    opts = entry.spec.opts
    assert Keyword.has_key?(opts, :pause_commit)
    assert opts[:pause_commit] == nil
    assert opts[:resume_kind] == :dirty_pause
  end

  test "a slot with no row is missing, and a mixed batch keeps every slot in place" do
    assert {:ok, %{entries: [first, second]}} = plan([done_row(@child_a, 0)], 2)

    assert first.status == :done
    assert second.status == :missing
    assert second.index == 1
    assert second.agent_id == nil
    assert second.result == nil
  end

  test "a running row without a rebuildable module declines as missing" do
    row = running_row(@child_a, 0, agent_module: nil, objective: nil)

    assert {:ok, %{entries: [entry]}} = plan([row], 1)
    assert entry.status == :missing
    assert entry.agent_id == @child_a
  end

  # --- ordering + turn filtering ---

  test "slots follow spawn_index, not the roster order" do
    records = [done_row(@child_b, 1), done_row(@child_a, 0)]

    assert {:ok, %{entries: [first, second]}} = plan(records)
    assert first.index == 0
    assert first.agent_id == @child_a
    assert second.index == 1
    assert second.agent_id == @child_b
  end

  test "a child spawned by an EARLIER turn is not adopted" do
    earlier = done_row(@child_a, 0, spawn_turn: 3)
    current = done_row(@child_b, 1)

    assert {:ok, %{entries: [first, second]}} = plan([earlier, current])
    assert first.status == :missing
    assert second.status == :done
    assert second.agent_id == @child_b
  end

  test "a child of ANOTHER parent is not adopted" do
    foreign = done_row(@child_a, 0, parent_id: 999)

    assert {:ok, %{entries: [entry]}} = plan([foreign], 1)
    assert entry.status == :missing
  end

  # --- inert paths ---

  test "persistent_state: false declines WITHOUT reading the roster" do
    parent = self()

    result =
      RosterBatch.plan(state(persistent_state: false), 4, 1,
        roster_fun: fn task_id ->
          send(parent, {:roster_read, task_id})
          []
        end
      )

    assert result == {:error, :persistent_state_disabled}
    refute_received {:roster_read, _task_id}
  end

  test "an unknown turn, no task id and an empty batch all decline" do
    roster = fn _task_id -> [done_row(@child_a, 0)] end

    assert {:error, :unknown_spawn_turn} = RosterBatch.plan(state(), nil, 1, roster_fun: roster)
    assert {:error, :no_task_id} = RosterBatch.plan(state(task_id: nil), 4, 1, roster_fun: roster)
    assert {:error, :no_expected_slots} = RosterBatch.plan(state(), 4, 0, roster_fun: roster)
  end

  test "a raising roster read is contained" do
    raising = fn _task_id -> raise "store exploded" end

    assert {:error, {:plan_failed, _detail}} =
             RosterBatch.plan(state(), 4, 1, roster_fun: raising)
  end
end
