defmodule EvoGit.AgentScheduler.WorktreeAdmissionTest do
  @moduledoc """
  Focused coverage for the bounded worktree-creation ADMISSION QUEUE in
  `EvoGit.AgentScheduler.WorktreeManager`.

  `create_worktree_for_agent/6` requests are registered `:queued` on a FIFO
  `admission_queue`; `admit_next/1` starts create pipelines (each its own
  offloaded `Task.start`) only while `creating_count < max_concurrent_creation()`.
  A permit is released by the `{:create_finished, agent_id}` cast fired from the
  create task's `try/after` (so it fires even on a raise). Agent entries carry
  `status: :queued | :creating | :live`.

  Two GLOBAL app-env seams drive these tests (both read by the manager):

    * `:max_concurrent_worktree_creation` — the create-pipeline cap, read at
      ADMISSION time.
    * `:worktree_create_fun` — arity-5 create-fun override
      `fn agent_id, repo_root, worktree_path, spec, meta -> {:ok, path} | {:error, reason} end`,
      used INSTEAD of `&Worktrees.prepare_new_worktree/5` when set.

  Because both seams are global, this module is `async: false` and saves +
  restores (or deletes) both in `on_exit`.
  """
  # async: false — WorktreeManager is a named singleton GenServer with shared
  # state across tests, the tests manipulate the global named ETS tables
  # (:evogit_agent_state / :evogit_sched_meta), and the two seams above are
  # global app env.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.WorktreeManager
  alias EvoGit.AgentScheduler.Worktrees
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # The create pipeline never calls the agent module — this only needs to exist
  # so the %AgentSpec{} is well-formed and the %Task{} below is constructible
  # (Elixir >= 1.18 Task enforces [:mfa, :owner, :ref]).
  defmodule DummyAgent do
  end

  # A create call can block for up to the manager's 1h call timeout. Caller
  # processes stay alive until told to stop so the manager's monitor-driven
  # cleanup cannot race the assertions.
  @caller_stop_timeout 60_000

  # The injected create fun reports entry and then blocks until the test
  # releases it, so tests control exactly when each create completes (no
  # time-based sleeps). Both bounds are generous safety nets — a wedged
  # handshake fails the test loudly instead of hanging until the ExUnit
  # timeout.
  @create_entry_timeout 10_000
  @release_timeout 10_000

  setup %{tmp_dir: tmp_dir} do
    # Real git repo so the manager's lazy per-repo init (rm_rf workers dir +
    # prune + orphaned-branch cleanup) and its :DOWN cleanup (rm_rf + prune +
    # branch delete) run cleanly and warning-free.
    {:ok, _} = Git.init(tmp_dir)
    File.write!(Path.join(tmp_dir, "README.md"), "# test")
    {:ok, _} = Git.add(tmp_dir, "README.md")
    {:ok, _} = Git.commit(tmp_dir, "initial commit")
    {:ok, base_sha} = Git.rev_parse(tmp_dir)

    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    # The WorktreeManager's persistent per-repo init-marker table. The app owns
    # it (created in EvoGit.Application.start/2); create it only as a fallback
    # for an environment where the app did not start.
    create_worktree_repos_ets()
    clear_ets()

    # GLOBAL seams — capture the originals now (before the test body mutates
    # them) and restore them in on_exit.
    old_cap = Application.get_env(:evo_git, :max_concurrent_worktree_creation)
    old_fun = Application.get_env(:evo_git, :worktree_create_fun)

    on_exit(fn ->
      restore_app_env(:max_concurrent_worktree_creation, old_cap)
      restore_app_env(:worktree_create_fun, old_fun)
      clear_ets()
    end)

    {:ok, base_sha: base_sha}
  end

  describe "bounded worktree-creation admission queue" do
    test "(a) create concurrency never exceeds the cap", %{tmp_dir: tmp_dir, base_sha: base_sha} do
      install_cap(2)
      parent = self()

      # Shared overlap tracker. The Agent serializes updates, so the recorded
      # max is the true peak number of concurrently-running create pipelines.
      {:ok, tracker} = Agent.start_link(fn -> %{current: 0, max: 0} end)

      install_create_fun(fn agent_id, _repo_root, wt_path, _spec, _meta ->
        Agent.update(tracker, fn s ->
          current = s.current + 1
          %{s | current: current, max: max(s.max, current)}
        end)

        # Event-driven hold: report entry (AFTER counting), then block until the
        # test releases THIS create. Because a create only completes when the
        # test says so, an over-cap admission surfaces as extra entered messages
        # (tracker peak > cap) instead of racing a fixed timer.
        send(parent, {:create_entered, agent_id, self()})

        receive do
          :release -> :ok
        after
          @release_timeout -> :ok
        end

        Agent.update(tracker, fn s -> %{s | current: s.current - 1} end)
        {:ok, wt_path}
      end)

      ids = for _ <- 1..6, do: unique_agent_id()

      callers =
        for {id, i} <- Enum.with_index(ids, 1) do
          {spec, meta, wt_path} = register_agent(id, tmp_dir, base_sha, i)
          {id, spawn_caller(id, tmp_dir, wt_path, spec, meta)}
        end

      # Release the creates in cap-sized waves: only releasing a create frees a
      # permit, so at most `cap` creates are ever in flight at once.
      release_waves(length(ids), 2)

      results = collect_results(ids)
      assert_all_ok_once(results, ids)

      # The whole point: overlap peaked at exactly the cap, never above it.
      assert Agent.get(tracker, & &1.max) == 2

      stop_callers(callers)
      await_manager_idle(ids)
    end

    test "(b) the queue drains and every caller is replied exactly once", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      install_cap(2)
      parent = self()

      install_create_fun(fn agent_id, _repo_root, wt_path, _spec, _meta ->
        # Hold each create until the test releases it, so the cap is genuinely
        # saturated and the remaining requests really sit in the admission
        # queue (rather than racing a fixed sleep).
        send(parent, {:create_entered, agent_id, self()})

        receive do
          :release -> :ok
        after
          @release_timeout -> :ok
        end

        {:ok, wt_path}
      end)

      ids = for _ <- 1..6, do: unique_agent_id()

      callers =
        for {id, i} <- Enum.with_index(ids, 1) do
          {spec, meta, wt_path} = register_agent(id, tmp_dir, base_sha, i)
          {id, spawn_caller(id, tmp_dir, wt_path, spec, meta)}
        end

      # Drive the creates in cap-sized waves so the queue is drained wave by
      # wave (2 in flight, the rest queued).
      release_waves(length(ids), 2)

      # Queuing only DELAYS the reply, never drops it — 6 queued requests at a
      # cap of 2 must all drain well within a sane bound.
      results = collect_results(ids, 20_000)
      assert_all_ok_once(results, ids)

      stop_callers(callers)
      await_manager_idle(ids)
    end

    test "(c) an agent dying while QUEUED is dropped without starting a create", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      install_cap(1)
      parent = self()
      {:ok, tracker} = Agent.start_link(fn -> %{started: []} end)

      agent_a = unique_agent_id()
      agent_b = unique_agent_id()
      agent_c = unique_agent_id()

      install_create_fun(fn agent_id, _repo_root, wt_path, _spec, _meta ->
        Agent.update(tracker, fn s -> %{s | started: [agent_id | s.started]} end)
        send(parent, {:create_started, agent_id, self()})

        # A holds the only permit until the test releases it.
        if agent_id == agent_a do
          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end

        {:ok, wt_path}
      end)

      {spec_a, meta_a, wt_a} = register_agent(agent_a, tmp_dir, base_sha, 1)
      caller_a = spawn_caller(agent_a, tmp_dir, wt_a, spec_a, meta_a)

      # A is admitted and now holds the single permit.
      assert_receive {:create_started, ^agent_a, task_a}, 10_000
      assert agent_status(agent_a) == :creating

      # B arrives while A holds the permit → it goes :queued, no create starts.
      {spec_b, meta_b, wt_b} = register_agent(agent_b, tmp_dir, base_sha, 2)
      caller_b = spawn_caller(agent_b, tmp_dir, wt_b, spec_b, meta_b)

      wait_until(fn -> agent_status(agent_b) == :queued end)

      # Kill B while it is still queued → dropped from the admission queue.
      Process.exit(caller_b, :kill)
      wait_until(fn -> agent_status(agent_b) == :absent end)

      # C arrives while A STILL holds the permit → queued behind it.
      {spec_c, meta_c, wt_c} = register_agent(agent_c, tmp_dir, base_sha, 3)
      caller_c = spawn_caller(agent_c, tmp_dir, wt_c, spec_c, meta_c)
      wait_until(fn -> agent_status(agent_c) == :queued end)

      # Release A — its permit frees and the queue drains to C (not wedged).
      send(task_a, :release)

      results = collect_results([agent_a, agent_c])
      assert_all_ok_once(results, [agent_a, agent_c])

      # The create fun ran for A and C, NEVER for the killed queued B.
      started = Agent.get(tracker, & &1.started) |> Enum.sort()
      assert started == Enum.sort([agent_a, agent_c])
      refute agent_b in started

      stop_callers([{agent_a, caller_a}, {agent_c, caller_c}])
      await_manager_idle([agent_a, agent_b, agent_c])
    end

    test "(d) under-cap requests are admitted immediately (cap 4)", %{
      tmp_dir: tmp_dir,
      base_sha: base_sha
    } do
      install_cap(4)

      install_create_fun(fn _agent_id, _repo_root, wt_path, _spec, _meta ->
        {:ok, wt_path}
      end)

      agent_id = unique_agent_id()
      {spec, meta, wt_path} = register_agent(agent_id, tmp_dir, base_sha, 1)
      caller = spawn_caller(agent_id, tmp_dir, wt_path, spec, meta)

      assert [{^agent_id, {:ok, ^wt_path}}] = collect_results([agent_id], 10_000)

      # Admitted without queueing: the create pipeline completed and flipped the
      # entry to :live.
      wait_until(fn -> agent_status(agent_id) == :live end)

      stop_callers([{agent_id, caller}])
      await_manager_idle([agent_id])
    end
  end

  # --------------------------------------------------------------------------
  # App-env seam helpers (GLOBAL — restored by the setup's on_exit)
  # --------------------------------------------------------------------------

  defp install_cap(cap),
    do: Application.put_env(:evo_git, :max_concurrent_worktree_creation, cap)

  defp install_create_fun(fun), do: Application.put_env(:evo_git, :worktree_create_fun, fun)

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)

  # --------------------------------------------------------------------------
  # ETS helpers (mirrors worktrees_test.exs)
  # --------------------------------------------------------------------------

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  defp create_worktree_repos_ets do
    if :ets.whereis(:evogit_worktree_repos) == :undefined do
      :ets.new(:evogit_worktree_repos, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  defp clear_ets do
    if :ets.whereis(:evogit_agent_state) != :undefined,
      do: :ets.delete_all_objects(:evogit_agent_state)

    if :ets.whereis(:evogit_sched_meta) != :undefined,
      do: :ets.delete_all_objects(:evogit_sched_meta)

    :ok
  end

  # --------------------------------------------------------------------------
  # Agent registration (mirrors worktrees_test.exs)
  # --------------------------------------------------------------------------

  defp unique_agent_id, do: :erlang.unique_integer([:positive])

  defp build_spec(tmp_dir, base_sha) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: tmp_dir},
      phylo_node: %PhyloGraphNode{repo: tmp_dir, base_commit: base_sha, current_commit: base_sha},
      agent_module: DummyAgent,
      objective: "test",
      repo_id: "primary"
    }
  end

  defp build_meta(agent_id, spec, task_number) do
    %SchedMeta{id: agent_id, depth: 0, spec: spec, retries: 0, task_number: task_number}
  end

  defp build_agent_state(tmp_dir, task_local_id) do
    %AgentState{
      context_node: %ContextNode{path: "./", repo: tmp_dir},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8,
      repo_root: tmp_dir,
      task_local_id: task_local_id
    }
  end

  # Writes both ETS rows (the create handler requires
  # `Store.get_agent_state/1` → `{:ok, %{task_local_id: ...}}`) and returns
  # `{spec, meta, worktree_path}` for the create call.
  defp register_agent(agent_id, tmp_dir, base_sha, task_local_id, task_number \\ 1) do
    spec = build_spec(tmp_dir, base_sha)
    meta = build_meta(agent_id, spec, task_number)
    Store.put_agent_state(agent_id, build_agent_state(tmp_dir, task_local_id))
    Store.put_sched_meta(agent_id, meta)

    wt_path =
      Path.join(Worktrees.workers_dir(tmp_dir), "worker_T#{task_number}_A#{task_local_id}")

    {spec, meta, wt_path}
  end

  # --------------------------------------------------------------------------
  # Caller-process helpers
  # --------------------------------------------------------------------------

  # Spawns a caller process that issues the create call from its OWN process
  # (passing itself as `agent_pid`, exactly like the Runner does) and reports
  # the reply to the test process. It stays alive until `:stop` so the
  # manager's monitor-driven cleanup cannot race the assertions.
  defp spawn_caller(agent_id, repo_root, wt_path, spec, meta) do
    parent = self()

    spawn(fn ->
      result =
        WorktreeManager.create_worktree_for_agent(
          agent_id,
          repo_root,
          wt_path,
          spec,
          meta,
          self()
        )

      send(parent, {:create_result, agent_id, result})

      receive do
        :stop -> :ok
      after
        @caller_stop_timeout -> :ok
      end
    end)
  end

  defp stop_callers(callers), do: Enum.each(callers, fn {_id, pid} -> send(pid, :stop) end)

  # Collects exactly `length(expected_ids)` create replies, failing loudly on a
  # hang (a dropped reply would otherwise wedge the test until its timeout).
  defp collect_results(expected_ids, timeout \\ 30_000) do
    n = length(expected_ids)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(n, deadline, [])
  end

  defp do_collect(n, _deadline, acc) when length(acc) >= n, do: acc

  defp do_collect(n, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("timed out waiting for #{n} create replies (got #{length(acc)}): #{inspect(acc)}")
    else
      receive do
        {:create_result, agent_id, result} ->
          do_collect(n, deadline, [{agent_id, result} | acc])
      after
        remaining ->
          flunk("timed out waiting for #{n} create replies (got #{length(acc)})")
      end
    end
  end

  # Asserts every expected agent received exactly one reply and that every
  # reply was `{:ok, _}` — no dropped and no duplicated replies.
  defp assert_all_ok_once(results, expected_ids) do
    grouped = Enum.group_by(results, fn {id, _} -> id end, fn {_, r} -> r end)

    for id <- expected_ids do
      replies = Map.get(grouped, id, [])
      assert length(replies) == 1, "agent #{id} got #{inspect(replies)} replies"
      assert match?([{:ok, _}], replies)
    end

    assert map_size(grouped) == length(expected_ids),
           "unexpected extra reply ids: #{inspect(Map.keys(grouped) -- expected_ids)}"
  end

  # Releases create pipelines in waves of `wave_size`. Waiting for a FULL wave
  # to report entry BEFORE releasing it is what pins the observed peak to the
  # cap: the manager can only have `wave_size` creates in flight, and an
  # over-cap admission would deliver extra `:create_entered` messages.
  defp release_waves(remaining, wave_size) when remaining > 0 do
    n = min(remaining, wave_size)
    n |> await_create_entries() |> Enum.each(&send(&1, :release))
    release_waves(remaining - n, wave_size)
  end

  defp release_waves(_remaining, _wave_size), do: :ok

  defp await_create_entries(n, acc \\ [])
  defp await_create_entries(0, acc), do: acc

  defp await_create_entries(n, acc) do
    receive do
      {:create_entered, _agent_id, pid} -> await_create_entries(n - 1, [pid | acc])
    after
      @create_entry_timeout ->
        flunk("timed out waiting for a create to enter (#{n} still outstanding)")
    end
  end

  # --------------------------------------------------------------------------
  # Manager introspection / polling helpers
  # --------------------------------------------------------------------------

  defp agent_status(agent_id) do
    case Map.get(:sys.get_state(WorktreeManager).agents, agent_id) do
      %{status: status} -> status
      nil -> :absent
    end
  end

  # Waits until the manager is idle: no create pipeline running, empty
  # admission queue, and none of the given agents still registered. Keeps the
  # shared singleton clean for the next test.
  defp await_manager_idle(ids, timeout \\ 10_000) do
    wait_until(
      fn ->
        state = :sys.get_state(WorktreeManager)

        state.creating_count == 0 and
          :queue.len(state.admission_queue) == 0 and
          Enum.all?(ids, fn id -> not Map.has_key?(state.agents, id) end)
      end,
      timeout
    )
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(15)
        do_wait_until(fun, deadline)

      true ->
        flunk("wait_until timed out")
    end
  end
end
