defmodule EvoGit.AgentScheduler.SubagentReattachTest do
  @moduledoc """
  Pins the SUBAGENT RE-ATTACH half of "crash-resume after a tool call": a
  parent's subagent batch must survive its exchange worker's death, and
  `EvoGit.AgentScheduler.reattach_sub_agents/3` must be able to hand it to the
  retried parent exactly once.

  Contract pinned here:

    * `Subagents.dispatch_ready_parent/3` never `GenServer.reply/2`s a nil or
      DEAD waiter; it RETAINS the results (`sub_agent_from: nil` marker,
      `status: :running`) instead of dropping them.
    * `Subagents.maybe_resume_parent/2` never re-dispatches a retained batch.
    * `reattach_sub_agents/3` answers a fully resolved batch immediately, hands a
      partially resolved one to the LAST child's completion, and reports the
      still-missing slots as `{:error, :subagent_result_lost}` on its timeout —
      the parent is never left `:waiting`.
    * The waiter + its timer survive `State.do_update_config/2`'s non-LLM merge.

  ## Why `async: true`

  No app-env seam, no WorktreeManager and no real session is involved: every
  fixture is a `%SchedMeta{}` row written directly into the app-global
  `:evogit_sched_meta` table under this module's OWN ids (9400-9405, deleted in
  `on_exit`), exactly like `lifecycle_test.exs`. Nothing is asserted about table
  size and no test reuses another module's ids. The `reattach_sub_agents/3`
  cases go through the real app-global scheduler, which only ever touches the
  row of the unique agent id named by the call.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.SubagentReattach
  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @parent 9400
  @child_a 9401
  @child_b 9402
  @other 9403
  @all_ids [@parent, @child_a, @child_b, @other]

  @result_a {:ok, %Result{result: "a done", commit_sha: "aaa"}}
  @result_b {:ok, %Result{result: "b done", commit_sha: "bbb"}}
  @lost {:error, :subagent_result_lost}

  setup do
    on_exit(fn ->
      for id <- @all_ids do
        :ets.delete(:evogit_sched_meta, id)
        :ets.delete(:evogit_agent_summary, id)
      end
    end)

    :ok
  end

  # --- Fixtures ---

  defp sched_meta(id, attrs) do
    base = %SchedMeta{
      id: id,
      depth: 1,
      parent_id: nil,
      task_id: "reattach-task",
      task_number: 1,
      worktree: "/tmp/reattach_wt",
      status: :waiting,
      spec: %AgentSpec{
        context_node: %ContextNode{path: "./", repo: "/test"},
        phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "abc", current_commit: "abc"},
        agent_module: nil,
        objective: "reattach test",
        repo_id: "primary"
      }
    }

    struct(base, attrs)
  end

  # A LIVE child: its `%SchedMeta{}` row exists, so its slot is PENDING.
  defp put_child(id) do
    :ets.insert(:evogit_sched_meta, {id, sched_meta(id, parent_id: @parent, depth: 2)})
    :ok
  end

  defp put_batch(parent_id, indices, results, total, attrs \\ []) do
    meta =
      sched_meta(
        parent_id,
        [
          total_sub_specs: total,
          sub_agent_indices: indices,
          sub_agent_results: results,
          pending_sub_agents: MapSet.new(Map.keys(indices)),
          sub_agent_from: nil,
          status: :running
        ] ++ attrs
      )

    :ets.insert(:evogit_sched_meta, {parent_id, meta})
    meta
  end

  defp row(id), do: :ets.lookup_element(:evogit_sched_meta, id, 2)

  # A pid that is guaranteed dead: `Process.alive?/1` is the exact predicate
  # `Subagents.dispatch_ready_parent/3` uses to decide retain-vs-reply.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  # --- (a) a child completes while the parent's waiter is DEAD ---

  test "a batch that completed for a DEAD waiter is RETAINED, then delivered by reattach once" do
    put_child(@child_a)
    put_child(@child_b)

    dead = dead_pid()

    put_batch(@parent, %{@child_a => 0, @child_b => 1}, %{}, 2,
      sub_agent_from: {dead, make_ref()}
    )

    state = %State{}

    # The first child leaves the batch incomplete: nothing is retained yet.
    :ok = Subagents.store_sub_result(@parent, @child_a, @result_a)
    assert %State{} = Subagents.maybe_resume_parent(state, @parent)
    assert row(@parent).sub_agent_from != nil

    # The second child completes the batch — but the waiter is dead, so the
    # results must be retained instead of replied to (a nil/dead `from` must
    # never reach `GenServer.reply/2`).
    :ok = Subagents.store_sub_result(@parent, @child_b, @result_b)
    assert %State{} = Subagents.maybe_resume_parent(state, @parent)

    retained = row(@parent)
    assert retained.sub_agent_from == nil
    assert retained.status == :running
    assert retained.total_sub_specs == 2
    assert retained.sub_agent_results == %{0 => @result_a, 1 => @result_b}
    assert retained.sub_agent_indices == %{@child_a => 0, @child_b => 1}
    assert retained.pending_sub_agents == MapSet.new()

    # The resumed parent re-attaches and gets the REAL results, once.
    ref = make_ref()

    assert {:reply, {:ok, [@result_a, @result_b]}, _state} =
             SubagentReattach.handle_reattach(@parent, 2, 60_000, {self(), ref}, state)

    # Exactly once: the batch is cleared, so a second re-attach is refused.
    assert {:reply, {:error, :no_pending_batch}, _state} =
             SubagentReattach.handle_reattach(@parent, 2, 60_000, {self(), make_ref()}, state)

    cleared = row(@parent)
    assert cleared.total_sub_specs == 0
    assert cleared.sub_agent_results == %{}
    assert cleared.sub_agent_indices == %{}
    assert cleared.status == :running
  end

  # --- (b) the child completed BEFORE the re-attach ---

  test "results retained with a nil waiter are delivered by reattach_sub_agents/3" do
    put_child(@child_a)
    put_batch(@parent, %{@child_a => 0}, %{}, 1, status: :waiting, sub_agent_from: nil)

    :ok = Subagents.store_sub_result(@parent, @child_a, @result_a)
    assert %State{} = Subagents.maybe_resume_parent(%State{}, @parent)

    retained = row(@parent)
    assert retained.status == :running
    assert retained.sub_agent_results == %{0 => @result_a}

    # The app-global scheduler serves the real call.
    assert {:ok, [@result_a]} = EvoGit.AgentScheduler.reattach_sub_agents(@parent, 1)
    assert row(@parent).total_sub_specs == 0

    assert {:error, :no_pending_batch} = EvoGit.AgentScheduler.reattach_sub_agents(@parent, 1)
  end

  # --- (c) nothing to re-attach ---

  test "no batch, an empty batch and a count mismatch all refuse without touching the row" do
    # No row at all.
    assert {:error, :no_pending_batch} = EvoGit.AgentScheduler.reattach_sub_agents(@other, nil)

    # A row with no batch in flight.
    :ets.insert(:evogit_sched_meta, {@other, sched_meta(@other, total_sub_specs: 0)})

    assert {:reply, {:error, :no_pending_batch}, _state} =
             SubagentReattach.handle_reattach(@other, nil, 1_000, {self(), make_ref()}, %State{})

    # A count mismatch leaves the batch untouched and installs NO waiter.
    put_child(@child_a)
    put_batch(@parent, %{@child_a => 0}, %{0 => @result_a}, 2)
    before = row(@parent)
    state = %State{}

    assert {:reply, {:error, :no_pending_batch}, ^state} =
             SubagentReattach.handle_reattach(@parent, 3, 1_000, {self(), make_ref()}, state)

    assert row(@parent) == before
    assert state.reattach_waiters == %{}
  end

  # --- (d) a genuinely lost child ---

  test "a child with no SchedMeta row and no stored result is reported lost, without waiting" do
    # @child_a has no row of its own — it can never deliver a result.
    put_batch(@parent, %{@child_a => 0}, %{}, 1)

    ref = make_ref()

    assert {:reply, {:ok, [@lost]}, state} =
             SubagentReattach.handle_reattach(@parent, 1, 60_000, {self(), ref}, %State{})

    # Immediate answer: no waiter, no timer, nothing left blocked.
    assert state.reattach_waiters == %{}
    assert state.reattach_timers == %{}
    assert row(@parent).total_sub_specs == 0
    refute_received {^ref, _anything}
  end

  # --- (e) the timeout path, end to end through the public API ---

  test "reattach_sub_agents/3 times out into :subagent_result_lost and leaves the parent :running" do
    # Slot 0 already has its result; slot 1's child is still running.
    put_child(@child_b)
    put_batch(@parent, %{@child_a => 0, @child_b => 1}, %{0 => @result_a}, 2)

    assert {:ok, [@result_a, @lost]} =
             EvoGit.AgentScheduler.reattach_sub_agents(@parent, 2, timeout: 60)

    expired = row(@parent)
    assert expired.status == :running
    assert expired.sub_agent_from == nil
    assert expired.total_sub_specs == 0
    assert expired.sub_agent_results == %{}
  end

  # --- the LAST child's completion resumes a re-attached parent ---

  test "the last child's completion answers an installed re-attach waiter and cancels its timer" do
    put_child(@child_a)
    put_child(@child_b)
    put_batch(@parent, %{@child_a => 0, @child_b => 1}, %{0 => @result_a}, 2)

    ref = make_ref()
    from = {self(), ref}

    assert {:noreply, state} =
             SubagentReattach.handle_reattach(@parent, 2, 60_000, from, %State{})

    assert state.reattach_waiters[@parent] == from
    {token, _timer_ref} = state.reattach_timers[@parent]

    waiting = row(@parent)
    assert waiting.status == :waiting
    assert waiting.sub_agent_from == from

    # The last child lands: the ordinary resume path answers the re-attach call.
    :ok = Subagents.store_sub_result(@parent, @child_b, @result_b)
    returned = Subagents.maybe_resume_parent(state, @parent)

    assert_receive {^ref, {:ok, [@result_a, @result_b]}}

    assert returned.reattach_waiters == %{}
    assert returned.reattach_timers == %{}

    # The cancelled timer's token no longer matches: it cannot clear a batch
    # that a LATER spawn installed.
    assert {:noreply, ^returned} = SubagentReattach.handle_timeout(@parent, token, returned)

    resumed = row(@parent)
    assert resumed.status == :running
    assert resumed.total_sub_specs == 0
  end

  # --- the waiter survives a config reload ---

  test "an installed re-attach waiter is carried across State.do_update_config/2" do
    put_child(@child_b)
    put_batch(@parent, %{@child_a => 0, @child_b => 1}, %{0 => @result_a}, 2)

    from = {self(), make_ref()}

    assert {:noreply, state} =
             SubagentReattach.handle_reattach(@parent, 2, 60_000, from, %State{})

    assert {:reply, :ok, reloaded} = State.do_update_config([max_depth: 3], state)

    assert reloaded.max_depth == 3
    assert reloaded.reattach_waiters == state.reattach_waiters
    assert reloaded.reattach_timers == state.reattach_timers

    {token, _timer_ref} = reloaded.reattach_timers[@parent]
    assert {:noreply, _state} = SubagentReattach.handle_timeout(@parent, token, reloaded)
    assert row(@parent).total_sub_specs == 0
  end
end
