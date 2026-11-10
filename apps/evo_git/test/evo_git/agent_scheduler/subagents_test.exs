defmodule EvoGit.AgentScheduler.SubagentsTest do
  @moduledoc """
  Pins the `EvoGit.AgentScheduler.Subagents` contracts: the spatial contract
  gates, the writable-foreign-repo delegation gates, `store_sub_result/3,4`
  roll-up and the parent resume paths.

  ## Why `async: false`

  One forcing GLOBAL: the app-env seam `:worktree_create_fun`, read at create
  admission by the app-global `EvoGit.AgentScheduler.WorktreeManager`. Every
  `spawn_validated_subagents/5` case that ACCEPTS a spec now dispatches a REAL
  `EvoGit.Agent.Session`, and each session's `:internal, :start` event asks
  WorktreeManager for a worktree (`EvoGit.Agent.Session.Setup.bind_worktree/2`).
  The module installs a refusing create safety net and the gating describe
  overrides it with a PARKED probe, so no create pipeline, worktree copy or LLM
  call ever runs here — and a concurrently running module would observe that
  seam. Every ETS row is written under this module's fixed ids (9000-9002,
  9100-9101) and deleted in `on_exit`; no test wipes a table or asserts on its
  size.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Subagents
  alias EvoGit.Agent.Result
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  # The agent ids this module dispatches (`%State{next_agent_id: 9100}` plus at
  # most one more spec). The parent fixture ids (9000-9002) are never sessions.
  @dispatched_agent_ids [9100, 9101]

  # Safety net for the WHOLE module: unless a describe installs its own probe,
  # ANY accidental session start fails the create immediately (the session
  # raises on that error and dies) instead of copying a worktree into a fixture
  # repo or reaching a real LLM call.
  setup do
    old_create = Application.get_env(:evo_git, :worktree_create_fun)
    Application.put_env(:evo_git, :worktree_create_fun, &refusing_create/5)
    on_exit(fn -> restore_app_env(:worktree_create_fun, old_create) end)
    :ok
  end

  # Dummy agent modules for testing agent_type dispatch

  defmodule DummyReadOnlyAgent do
    def agent_type, do: :read
    def delegation_level, do: :high
    def run(_objective, _ctx), do: :ok
  end

  defmodule DummyReadWriteAgent do
    def agent_type, do: :read_write
    def delegation_level, do: :high
    def run(_objective, _ctx), do: :ok
  end

  # --- Helpers ---

  defp parent_state(path: path, repo: repo, repo_id: repo_id) do
    %{
      context_node: %ContextNode{path: path, repo: repo},
      repo_id: repo_id
    }
  end

  defp spec(path: path, repo: repo, repo_id: repo_id, agent_module: agent_module) do
    spec(
      path: path,
      repo: repo,
      repo_id: repo_id,
      agent_module: agent_module,
      foreign_repos: []
    )
  end

  defp spec(
         path: path,
         repo: repo,
         repo_id: repo_id,
         agent_module: agent_module,
         foreign_repos: foreign_repos
       ) do
    %AgentSpec{
      context_node: %ContextNode{path: path, repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: "abc123", current_commit: "abc123"},
      agent_module: agent_module,
      objective: "test objective",
      repo_id: repo_id,
      foreign_repos: foreign_repos
    }
  end

  # A cross-repo `:read_write` spec whose target repo id is marked writable at
  # the task level (the pre-condition for root-only + one-at-a-time gating).
  defp writable_foreign_spec(path: path, repo: repo, repo_id: repo_id) do
    spec(
      path: path,
      repo: repo,
      repo_id: repo_id,
      agent_module: DummyReadWriteAgent,
      foreign_repos: [%ForeignRepo{id: repo_id, root: repo, writable: true}]
    )
  end

  # A real git repo with one commit. The spawn path runs
  # `validate_subagent_not_ignored` → `Git.check_ignore(repo, ...)` on every
  # spec, spawning the `git` executable with `cd: <repo path>` — a missing
  # fixture directory makes the ERTS port program print
  # `spawn: Could not cd to <path>` straight to stderr (invisible to
  # ExUnit.CaptureLog), so fixture repos used through `spawn_validated_subagents/5`
  # must exist on disk.
  defp fixture_repo(root) do
    File.mkdir_p!(root)
    {:ok, _} = Git.init(root)
    File.write!(Path.join(root, "README.md"), "# fixture repo\n")
    {:ok, _} = Git.add(root, "README.md")
    {:ok, _} = Git.commit(root, "initial commit")
    root
  end

  # --- Session seams (see `@moduledoc`) ---

  # The module-level default: refuse every create, so an accidental session
  # start dies immediately (the session raises on the create error) instead of
  # running real worktree I/O.
  defp refusing_create(_agent_id, _repo_root, _worktree_path, _spec, _meta) do
    {:error, {:worktree_create_failed, "no create expected in this test"}}
  end

  # A PARKED create probe: it reports the request it was handed (so "the
  # session, not the scheduler, asked for this worktree" is a handshake rather
  # than a race), materializes NOTHING, and then blocks until its OWN session
  # dies. The session is registered in `EvoGit.Agent.Session.Registry` before
  # its `:start` event runs, so the probe can always find it.
  defp parked_create_probe(test_pid) do
    fn agent_id, _repo_root, worktree_path, _spec, _meta ->
      [{session_pid, _value}] = Registry.lookup(Session.Registry, agent_id)
      ref = Process.monitor(session_pid)
      send(test_pid, {:create_parked, agent_id, worktree_path})

      receive do
        {:DOWN, ^ref, :process, ^session_pid, _reason} ->
          {:error, {:worktree_create_failed, "session stopped before the create ran"}}
      after
        30_000 -> {:error, {:worktree_create_failed, "parked create probe timed out"}}
      end
    end
  end

  # Deterministic session teardown: kill every session this test dispatched and
  # WAIT for it, because a live session keeps touching the fixture dir (its
  # worktree request, its retries) and would race the `File.rm_rf!/1` below.
  # Killing the session also unblocks its parked create probe.
  defp stop_sessions(agent_ids) do
    for agent_id <- agent_ids,
        [{session_pid, _value}] <- [Registry.lookup(Session.Registry, agent_id)],
        Process.alive?(session_pid) do
      ref = Process.monitor(session_pid)
      Process.exit(session_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^session_pid, _reason} -> :ok
      after
        10_000 -> flunk("session for agent #{agent_id} did not stop")
      end
    end

    :ok
  end

  # The killed session's WorktreeManager cleanup is deferred until its parked
  # create task finishes (the create task replies to the dead caller and fires
  # `{:create_finished, agent_id}`); wait for that registration to be released
  # so no manager cleanup touches the fixture repos after they are removed.
  defp await_manager_release(agent_ids) do
    wait_until(
      fn ->
        manager_state = :sys.get_state(EvoGit.AgentScheduler.WorktreeManager)

        Enum.all?(agent_ids, fn agent_id ->
          not Map.has_key?(manager_state.agents, agent_id)
        end)
      end,
      10_000
    )
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, original_timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline, original_timeout)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)

  # --- Cross-repo delegation ---

  describe "validate_spatial_contract_for_spec/3 — cross-repo delegation" do
    test "allows read-only agent when repo ids differ" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadOnlyAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write agent when repo ids differ" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent
        )

      assert {:error, {:foreign_repo_read_only, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "This foreign repository is read-only for this task"
    end

    test "error message mentions read-only alternatives" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent
        )

      {:error, {:foreign_repo_read_only, msg}} =
        Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "subagent_investigator"
      assert msg =~ "subagent_task_scheduler"
    end

    test "cross-repo rules apply even between two different foreign repos" do
      # Parent is in :original, child targets :reference
      parent = parent_state(path: "./", repo: "/home/user/original", repo_id: "original")

      read_only_spec =
        spec(
          path: "./src",
          repo: "/home/user/reference",
          repo_id: "reference",
          agent_module: DummyReadOnlyAgent
        )

      read_write_spec =
        spec(
          path: "./src",
          repo: "/home/user/reference",
          repo_id: "reference",
          agent_module: DummyReadWriteAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, read_only_spec) == :ok

      assert {:error, {:foreign_repo_read_only, _}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, read_write_spec)
    end

    test "allows read-write agent when the foreign repo is marked writable at task level" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: [
            %ForeignRepo{id: "original", root: "/home/user/original", writable: true}
          ]
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write agent when the foreign repo is marked read-only at task level" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: [
            %ForeignRepo{id: "original", root: "/home/user/original", writable: false}
          ]
        )

      assert {:error, {:foreign_repo_read_only, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "read-only for this task"
    end

    test "rejects read-write agent when foreign_repos is empty or the repo id is unknown" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      empty_spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: []
        )

      assert {:error, {:foreign_repo_read_only, _}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, empty_spec)

      # A writable entry for a DIFFERENT repo does not help — the target repo id
      # must itself be listed as writable.
      other_repo_spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: [
            %ForeignRepo{
              id: "some_other_repo",
              root: "/home/user/some_other_repo",
              writable: true
            }
          ]
        )

      assert {:error, {:foreign_repo_read_only, _}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, other_repo_spec)
    end

    test "allows read-only agent into a foreign repo regardless of foreign_repos" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadOnlyAgent,
          foreign_repos: []
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end
  end

  # --- Same-repo delegation ---

  describe "validate_spatial_contract_for_spec/3 — same-repo delegation" do
    test "allows read-write child at descendant path" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./src",
          repo: "/home/user/primary",
          repo_id: "primary",
          agent_module: DummyReadWriteAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "rejects read-write child at sibling path" do
      parent = parent_state(path: "./src", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./lib",
          repo: "/home/user/primary",
          repo_id: "primary",
          agent_module: DummyReadWriteAgent
        )

      assert {:error, {:spatial_contract_violation, msg}} =
               Subagents.validate_spatial_contract_for_spec(1, parent, spec)

      assert msg =~ "read-write"
    end

    test "allows read-only child at any path regardless of parent" do
      parent = parent_state(path: "./src", repo: "/home/user/primary", repo_id: "primary")

      spec =
        spec(
          path: "./lib",
          repo: "/home/user/primary",
          repo_id: "primary",
          agent_module: DummyReadOnlyAgent
        )

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end
  end

  # --- Writable foreign repo delegation rules ---

  describe "validate_spatial_contract_for_spec/4 — writable foreign repo delegation rules" do
    test "allows a writable cross-repo read-write spawn from a depth-0 parent (3-arity)" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        writable_foreign_spec(path: "./src", repo: "/home/user/original", repo_id: "original")

      # The 3-arity entry point treats the parent as the ROOT agent (depth 0)
      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec) == :ok
    end

    test "allows a writable cross-repo read-write spawn from a depth-0 parent (4-arity)" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        writable_foreign_spec(path: "./src", repo: "/home/user/original", repo_id: "original")

      assert Subagents.validate_spatial_contract_for_spec(1, parent, spec, 0) == :ok
    end

    test "rejects a writable cross-repo read-write spawn from a nested parent (depth >= 1)" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      spec =
        writable_foreign_spec(path: "./src", repo: "/home/user/original", repo_id: "original")

      for depth <- [1, 3] do
        assert {:error, {:foreign_repo_write_not_root, msg}} =
                 Subagents.validate_spatial_contract_for_spec(1, parent, spec, depth)

        # The message teaches the root-only delegation model
        assert msg =~ "ROOT agent"
        assert msg =~ "report"
        assert msg =~ "read-only"
      end
    end

    test "allows read-only cross-repo spawns into foreign repos at any depth" do
      parent = parent_state(path: "./", repo: "/home/user/primary", repo_id: "primary")

      read_spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadOnlyAgent
        )

      # Depth 0 (3-arity backward-compat entry point)
      assert Subagents.validate_spatial_contract_for_spec(1, parent, read_spec) == :ok
      # Nested parents via the 4-arity entry point — read-only is unrestricted
      assert Subagents.validate_spatial_contract_for_spec(1, parent, read_spec, 2) == :ok
    end

    test "allows read-write same-repo spawns within a foreign repo at any depth" do
      parent = parent_state(path: "./", repo: "/home/user/original", repo_id: "original")

      same_repo_spec =
        spec(
          path: "./src",
          repo: "/home/user/original",
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: [
            %ForeignRepo{id: "original", root: "/home/user/original", writable: true}
          ]
        )

      # Same-repo spawns within a foreign repo are never restricted — even at
      # nested depths (the foreign-repo Manager's own internal parallelism).
      assert Subagents.validate_spatial_contract_for_spec(1, parent, same_repo_spec, 2) == :ok
    end
  end

  describe "spawn_validated_subagents/5 — writable foreign repo one-at-a-time gating" do
    setup %{tmp_dir: tmp_dir} do
      # Real temp git repos — the spawn path runs `Git.check_ignore` with
      # `cd: <repo path>` on every spec; a missing fixture dir makes the ERTS
      # port program print `spawn: Could not cd to <path>` to stderr.
      primary = fixture_repo(Path.join(tmp_dir, "primary"))
      original = fixture_repo(Path.join(tmp_dir, "original"))
      reference = fixture_repo(Path.join(tmp_dir, "reference"))

      ensure_ets_table(:evogit_sched_meta)
      ensure_ets_table(:evogit_agent_summary)

      # Hermetic dispatch (overrides the module's refusing net): every accepted
      # spec becomes a real session whose `:start` event requests a worktree, so
      # the probe PARKS that request. No create pipeline runs, nothing is copied
      # into a fixture repo, and no exchange (hence no LLM call) ever starts.
      old_create = Application.get_env(:evo_git, :worktree_create_fun)
      Application.put_env(:evo_git, :worktree_create_fun, parked_create_probe(self()))

      on_exit(fn ->
        # Teardown order is load-bearing: stop every session this test
        # dispatched (and wait for it), then wait for WorktreeManager to release
        # those agent registrations, and only THEN remove the fixture dirs and
        # the ETS rows — so nothing races the removal and a removal failure can
        # never skip the ETS cleanup.
        ExUnit.CaptureLog.capture_log(fn ->
          stop_sessions(@dispatched_agent_ids)
          await_manager_release(@dispatched_agent_ids)
        end)

        for id <- [9000 | @dispatched_agent_ids] do
          :ets.delete(:evogit_sched_meta, id)
          :ets.delete(:evogit_agent_summary, id)
        end

        restore_app_env(:worktree_create_fun, old_create)

        File.rm_rf!(primary)
        File.rm_rf!(original)
        File.rm_rf!(reference)
      end)

      %{
        primary: primary,
        original: original,
        reference: reference
      }
    end

    test "accepts a single writable foreign spec in a batch (no false rejection)", %{
      primary: primary,
      original: original
    } do
      parent_meta = %{base_sched_meta(9000, %{}) | depth: 0}
      :ets.insert(:evogit_sched_meta, {9000, parent_meta})

      :ets.insert(:evogit_agent_summary, {
        9000,
        parent_state(path: "./", repo: primary, repo_id: "primary")
      })

      specs = [
        writable_foreign_spec(path: "./src", repo: original, repo_id: "original")
      ]

      state = %State{next_agent_id: 9100}
      ref = make_ref()
      from = {self(), ref}

      assert {:noreply, _} =
               Subagents.spawn_validated_subagents(9000, parent_meta, specs, from, state)

      # The accepted spec became a real session whose OWN start event requested
      # the worktree — and the request is PARKED, so nothing was materialized.
      assert_receive {:create_parked, 9100, worktree_path}, 5_000
      assert String.starts_with?(worktree_path, original)
      refute File.exists?(worktree_path)

      updated = :ets.lookup_element(:evogit_sched_meta, 9000, 2)
      assert updated.status == :waiting
      assert updated.total_sub_specs == 1
      assert updated.pending_sub_agents == MapSet.new([9100])
      assert updated.sub_agent_results == %{}
      assert updated.sub_agent_indices == %{9100 => 0}

      # The accepted spec was registered and dispatched
      assert :ets.lookup(:evogit_agent_summary, 9100) != []
      assert :ets.lookup_element(:evogit_sched_meta, 9100, 2).parent_id == 9000
    end

    test "rejects the second writable foreign spec in a batch (one-at-a-time)", %{
      primary: primary,
      original: original,
      reference: reference
    } do
      parent_meta = %{base_sched_meta(9000, %{}) | depth: 0}
      :ets.insert(:evogit_sched_meta, {9000, parent_meta})

      :ets.insert(:evogit_agent_summary, {
        9000,
        parent_state(path: "./", repo: primary, repo_id: "primary")
      })

      specs = [
        writable_foreign_spec(path: "./src", repo: original, repo_id: "original"),
        writable_foreign_spec(path: "./src", repo: reference, repo_id: "reference")
      ]

      state = %State{next_agent_id: 9100}
      ref = make_ref()
      from = {self(), ref}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, _} =
                   Subagents.spawn_validated_subagents(9000, parent_meta, specs, from, state)
        end)

      assert log =~ "foreign_repo_write_serialized"

      # Only the FIRST spec became a session, and its parked worktree request
      # proves no real create ever ran.
      assert_receive {:create_parked, 9100, worktree_path}, 5_000
      refute File.exists?(worktree_path)

      updated = :ets.lookup_element(:evogit_sched_meta, 9000, 2)
      assert updated.status == :waiting
      assert updated.total_sub_specs == 2
      # Only the FIRST writable spec was accepted
      assert updated.pending_sub_agents == MapSet.new([9100])
      assert updated.sub_agent_indices == %{9100 => 0}

      # The second writable spec lands in invalid_results with the
      # serialization error — the message teaches one-at-a-time delegation
      assert %{1 => {:error, {:foreign_repo_write_serialized, msg}}} = updated.sub_agent_results
      assert msg =~ "ONE write-capable subagent"
      assert msg =~ "at a time"
      assert msg =~ "Manager"

      # The rejected second spec was never registered
      assert :ets.lookup(:evogit_agent_summary, 9101) == []
    end

    test "accepts multiple same-repo writable specs within a foreign repo (no serialization)", %{
      original: original
    } do
      parent_meta = %{base_sched_meta(9000, %{}) | depth: 1}
      :ets.insert(:evogit_sched_meta, {9000, parent_meta})

      :ets.insert(:evogit_agent_summary, {
        9000,
        parent_state(path: "./", repo: original, repo_id: "original")
      })

      # Two writable specs targeting the SAME foreign repo the parent runs in —
      # same-repo spawns are unrestricted and NOT serialization-gated.
      specs = [
        spec(
          path: "./src",
          repo: original,
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: [%ForeignRepo{id: "original", root: original, writable: true}]
        ),
        spec(
          path: "./lib",
          repo: original,
          repo_id: "original",
          agent_module: DummyReadWriteAgent,
          foreign_repos: [%ForeignRepo{id: "original", root: original, writable: true}]
        )
      ]

      state = %State{next_agent_id: 9100}
      ref = make_ref()
      from = {self(), ref}

      assert {:noreply, _} =
               Subagents.spawn_validated_subagents(9000, parent_meta, specs, from, state)

      # BOTH same-repo specs were accepted and dispatched as real sessions, each
      # of which requested (and parked) its own worktree — no copy was made.
      assert_receive {:create_parked, 9100, worktree_path}, 5_000
      assert_receive {:create_parked, 9101, other_worktree_path}, 5_000
      assert String.starts_with?(worktree_path, original)
      assert String.starts_with?(other_worktree_path, original)
      refute File.exists?(worktree_path)
      refute File.exists?(other_worktree_path)

      updated = :ets.lookup_element(:evogit_sched_meta, 9000, 2)
      assert updated.total_sub_specs == 2
      assert updated.pending_sub_agents == MapSet.new([9100, 9101])
      assert updated.sub_agent_results == %{}
      assert updated.sub_agent_indices == %{9100 => 0, 9101 => 1}

      # BOTH specs were registered
      assert :ets.lookup(:evogit_agent_summary, 9100) != []
      assert :ets.lookup(:evogit_agent_summary, 9101) != []
    end
  end

  # --- Foreign repo commit tracking ---

  describe "store_sub_result/3,4 — foreign repo commit tracking" do
    setup do
      # Ensure ETS tables exist (app may already create them)
      ensure_ets_table(:evogit_sched_meta)
      ensure_ets_table(:evogit_agent_summary)

      on_exit(fn ->
        # Clean up test entries (don't delete the tables themselves)
        :ets.delete(:evogit_sched_meta, 1)
      end)

      :ok
    end

    defp ensure_ets_table(name) do
      if :ets.whereis(name) == :undefined do
        :ets.new(name, [:set, :public, :named_table])
      end
    end

    defp base_sched_meta(parent_id, sub_indices) do
      %SchedMeta{
        id: parent_id,
        depth: 0,
        spec: %AgentSpec{
          context_node: %ContextNode{path: "./", repo: "/test"},
          phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "abc", current_commit: "abc"},
          agent_module: nil,
          objective: "test",
          repo_id: "primary"
        },
        sub_agent_indices: sub_indices,
        sub_agent_results: %{},
        foreign_repo_commits: %{}
      }
    end

    test "tracks foreign repo commit SHA when subagent result has repo_id" do
      parent_id = 1
      sub_id = 2

      parent_meta = base_sched_meta(parent_id, %{sub_id => 0})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result = {:ok, %Result{result: "done", commit_sha: "def456", repo_id: "original"}}

      Subagents.store_sub_result(
        parent_id,
        sub_id,
        result,
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "original")
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "def456"}
      assert updated.sub_agent_results == %{0 => result}
    end

    test "accumulates commits from multiple foreign repos" do
      parent_id = 1

      parent_meta = base_sched_meta(parent_id, %{10 => 0, 11 => 1})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result1 = {:ok, %Result{result: "done1", commit_sha: "sha1", repo_id: "original"}}
      result2 = {:ok, %Result{result: "done2", commit_sha: "sha2", repo_id: "reference"}}

      Subagents.store_sub_result(
        parent_id,
        10,
        result1,
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "original")
      )

      Subagents.store_sub_result(
        parent_id,
        11,
        result2,
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "reference")
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "sha1", "reference" => "sha2"}
    end

    test "does not track primary repo commits" do
      parent_id = 1
      sub_id = 2

      parent_meta = base_sched_meta(parent_id, %{sub_id => 0})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result = {:ok, %Result{result: "done", commit_sha: "abc123", repo_id: "primary"}}

      Subagents.store_sub_result(parent_id, sub_id, result)

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{}
    end

    test "does not track error results" do
      parent_id = 1
      sub_id = 2

      parent_meta = %SchedMeta{
        base_sched_meta(parent_id, %{sub_id => 0})
        | foreign_repo_commits: %{"original" => "existing_sha"}
      }

      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      Subagents.store_sub_result(parent_id, sub_id, {:error, :some_error})

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      # Existing commits preserved, no new entry added
      assert updated.foreign_repo_commits == %{"original" => "existing_sha"}
    end

    test "updates existing foreign repo commit to latest SHA" do
      parent_id = 1

      parent_meta = base_sched_meta(parent_id, %{10 => 0, 11 => 1})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result1 = {:ok, %Result{result: "first", commit_sha: "sha_v1", repo_id: "original"}}
      result2 = {:ok, %Result{result: "second", commit_sha: "sha_v2", repo_id: "original"}}

      Subagents.store_sub_result(
        parent_id,
        10,
        result1,
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "original")
      )

      Subagents.store_sub_result(
        parent_id,
        11,
        result2,
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "original")
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      # Second result overwrites first for same repo
      assert updated.foreign_repo_commits == %{"original" => "sha_v2"}
    end

    test "local/primary child does not overwrite a pre-seeded foreign commit" do
      parent_id = 1
      sub_id = 2

      parent_meta = %SchedMeta{
        base_sched_meta(parent_id, %{sub_id => 0})
        | foreign_repo_commits: %{"original" => "advanced_sha"}
      }

      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      # A STALE sha arrives through a local/primary child (repo_id "primary"),
      # which is never authorized to advance a foreign repo's tracked commit.
      result =
        {:ok,
         %Result{
           result: "done",
           commit_sha: "stale_sha",
           repo_id: "original",
           foreign_repo_commits: %{"original" => "stale_sha"}
         }}

      Subagents.store_sub_result(
        parent_id,
        sub_id,
        result,
        spec(path: "./", repo: "/test", repo_id: "primary", agent_module: DummyReadWriteAgent)
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "advanced_sha"}
    end

    test "read-only child targeting a writable foreign repo records nothing" do
      parent_id = 1
      sub_id = 2

      parent_meta = base_sched_meta(parent_id, %{sub_id => 0})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result =
        {:ok,
         %Result{
           result: "done",
           commit_sha: "ro_sha",
           repo_id: "original",
           foreign_repo_commits: %{"original" => "ro_sha"}
         }}

      # The target repo IS marked writable, but the child is read-only — it may
      # not advance the tracked commit.
      Subagents.store_sub_result(
        parent_id,
        sub_id,
        result,
        spec(
          path: "./",
          repo: "/test",
          repo_id: "original",
          agent_module: DummyReadOnlyAgent,
          foreign_repos: [%ForeignRepo{id: "original", root: "/test", writable: true}]
        )
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{}
    end

    test "writable foreign-repo child records its advanced SHA" do
      parent_id = 1
      sub_id = 2

      parent_meta = base_sched_meta(parent_id, %{sub_id => 0})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      result = {:ok, %Result{result: "done", commit_sha: "adv_sha", repo_id: "original"}}

      Subagents.store_sub_result(
        parent_id,
        sub_id,
        result,
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "original")
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "adv_sha"}
    end

    test "writable foreign child's advance survives a later stale primary child" do
      parent_id = 1

      # Two children: the writable foreign agent (index 0) and a primary child
      # (index 1) that completes afterwards carrying a stale sha.
      parent_meta = base_sched_meta(parent_id, %{10 => 0, 11 => 1})
      :ets.insert(:evogit_sched_meta, {parent_id, parent_meta})

      Subagents.store_sub_result(
        parent_id,
        10,
        {:ok, %Result{result: "wrote", commit_sha: "advanced_sha", repo_id: "original"}},
        writable_foreign_spec(path: "./", repo: "/test", repo_id: "original")
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.foreign_repo_commits == %{"original" => "advanced_sha"}

      Subagents.store_sub_result(
        parent_id,
        11,
        {:ok,
         %Result{
           result: "local",
           commit_sha: "stale_sha",
           repo_id: "original",
           foreign_repo_commits: %{"original" => "stale_sha"}
         }},
        spec(path: "./", repo: "/test", repo_id: "primary", agent_module: DummyReadWriteAgent)
      )

      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      # The primary child's stale sha must NOT clobber the writable agent's advance.
      assert updated.foreign_repo_commits == %{"original" => "advanced_sha"}
    end
  end

  # --- Error paths: recycled parent entries ---
  #
  # These fire when ETS entries are missing — e.g. the parent was recycled by
  # `cancel_agent` while a subagent completes in flight. Uses distinctive
  # ids (9000+) so they never collide with the entries of sibling describes.

  describe "error paths — recycled parent entries" do
    setup do
      ensure_ets_table(:evogit_sched_meta)
      ensure_ets_table(:evogit_agent_summary)

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, 9000)
        :ets.delete(:evogit_sched_meta, 9001)
        :ets.delete(:evogit_sched_meta, 9002)
        :ets.delete(:evogit_agent_summary, 9000)
      end)

      :ok
    end

    test "store_sub_result/3 drops the result when the parent entry is missing" do
      parent_id = 9000
      sub_id = 9001

      # A pre-existing unrelated entry must survive untouched
      existing = base_sched_meta(9002, %{})
      :ets.insert(:evogit_sched_meta, {9002, existing})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Subagents.store_sub_result(
                     parent_id,
                     sub_id,
                     {:ok, %Result{result: "done", commit_sha: "abc"}}
                   )
        end)

      assert log =~ "recycled"
      # No entry was created for the recycled parent — the result was dropped
      assert :ets.lookup(:evogit_sched_meta, parent_id) == []
      # Pre-existing entries are untouched
      assert :ets.lookup_element(:evogit_sched_meta, 9002, 2) == existing
    end

    test "maybe_resume_parent/2 leaves the state unchanged when the parent entry is missing" do
      state = %State{}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ^state = Subagents.maybe_resume_parent(state, 9000)
        end)

      assert log =~ "recycled"
    end

    test "spawn_validated_subagents/5 replies with errors when the parent agent_state is missing" do
      parent_id = 9000
      sub_id = 9001

      parent = base_sched_meta(parent_id, %{})
      :ets.insert(:evogit_sched_meta, {parent_id, parent})

      specs = [
        %AgentSpec{
          context_node: %ContextNode{path: "./", repo: "/test"},
          phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "abc", current_commit: "abc"},
          agent_module: DummyReadOnlyAgent,
          objective: "test"
        }
      ]

      state = %State{}
      ref = make_ref()
      from = {self(), ref}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, ^state} =
                   Subagents.spawn_validated_subagents(parent_id, parent, specs, from, state)
        end)

      assert log =~ "recycled"
      # The blocked caller gets an error reply for every spec
      assert_receive {^ref, [{:error, :parent_recycled}]}
      # Nothing was spawned or registered for any subagent id
      assert :ets.lookup(:evogit_sched_meta, sub_id) == []
      # The parent entry itself is untouched
      assert :ets.lookup_element(:evogit_sched_meta, parent_id, 2) == parent
    end

    test "dispatch_ready_parent/3 resumes with ordered results when the agent_state is missing" do
      parent_id = 9000
      ref = make_ref()

      meta = %{
        base_sched_meta(parent_id, %{})
        | worktree: "/tmp/wt",
          sub_agent_from: {self(), ref},
          total_sub_specs: 1,
          sub_agent_results: %{0 => {:ok, %Result{result: "done", commit_sha: "abc"}}}
      }

      :ets.insert(:evogit_sched_meta, {parent_id, meta})
      state = %State{}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ^state = Subagents.dispatch_ready_parent(state, parent_id, meta)
        end)

      # Agent state missing → commit_sha falls back to "unknown"
      assert log =~ "state missing on resume"
      assert log =~ "commit unknown"

      # The blocked caller still receives the ordered results
      assert_receive {^ref, [{:ok, %Result{result: "done"}}]}

      # The sched_meta entry is reset for the resumed run
      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.status == :running
      assert updated.sub_agent_from == nil
      assert updated.sub_agent_results == %{}
      assert updated.pending_sub_agents == MapSet.new()
      assert updated.sub_agent_indices == %{}
      assert updated.total_sub_specs == 0
    end

    test "dispatch_ready_parent/3 resumes with a repo-less parent state (current_commit nil)" do
      parent_id = 9000
      ref = make_ref()

      meta = %{
        base_sched_meta(parent_id, %{})
        | worktree: "/tmp/wt",
          sub_agent_from: {self(), ref},
          total_sub_specs: 1,
          sub_agent_results: %{0 => {:ok, %Result{result: "done", commit_sha: "abc"}}}
      }

      :ets.insert(:evogit_sched_meta, {parent_id, meta})

      # The PRODUCTION row shape with no temporal identity: the merged
      # `dispatch_ready_parent/3` has a `%AgentState{current_commit: nil}` arm
      # (repo-less parents), so the commit used for its log is "unknown".
      :ets.insert(:evogit_agent_summary, {
        parent_id,
        %AgentState{
          parent_id: nil,
          current_commit: nil,
          mode: :oneshot,
          context_node: %ContextNode{path: "./", repo: "/test", repo_id: "primary"},
          llm_model: nil,
          max_retries: 15,
          max_depth: 8
        }
      })

      state = %State{}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ^state = Subagents.dispatch_ready_parent(state, parent_id, meta)
        end)

      # The row WAS found and the repo-less arm handled the nil temporal
      # identity: no "state missing" warning, and no struct-field crash (the
      # defect this case pins). The "commit unknown" label itself is an
      # `info` line, filtered out by the suite's `:warning` log level.
      refute log =~ "state missing on resume"
      refute log =~ "KeyError"

      # The blocked caller still receives the ordered results.
      assert_receive {^ref, [{:ok, %Result{result: "done"}}]}

      # The sched_meta entry is reset for the resumed run, exactly as on the
      # missing-state path.
      updated = :ets.lookup_element(:evogit_sched_meta, parent_id, 2)
      assert updated.status == :running
      assert updated.sub_agent_from == nil
      assert updated.sub_agent_results == %{}
      assert updated.pending_sub_agents == MapSet.new()
      assert updated.sub_agent_indices == %{}
      assert updated.total_sub_specs == 0
    end
  end
end
