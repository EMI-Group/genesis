defmodule EvoGit.TaskRegistry.TaskTmpdirTestHelpers do
  @moduledoc false

  # Shared fixtures for the managed per-task tmpdir suite in this file. The
  # suite runs `async: false` on `EvoGit.TaskRegistryCase`, so the "current"
  # isolated Store is resolved from the test process dictionary via
  # `EvoGit.TaskRegistryCase.store/0`.

  alias EvoGit.TaskInfo

  @doc """
  Seeds a task row in the isolated store with `status` and `opts`.

  In `:per_repo` tmpdir mode `opts[:path]` is the task's PRIMARY repo path and
  therefore the managed root's parent — callers there MUST pass it, otherwise a
  reclaim would target the real system tmp root.
  """
  def seed_task(task_id, status, opts) do
    :ok =
      EvoGit.Store.put_task(EvoGit.TaskRegistryCase.store(), %TaskInfo{
        id: task_id,
        type: :evolve,
        status: status,
        opts: opts,
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: System.system_time(:second) + 300
      })
  end

  @doc """
  Creates a fresh unique temp dir to act as a task's primary repo path.
  """
  def tmp_repo! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_tmpdir_repo_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  @doc """
  A fake `%Task{}` ref pointing at `pid` — the shape `force_kill_task/1` needs
  in `state.task_refs` before it treats a row as "owned".
  """
  def fake_task(pid) do
    %Task{
      pid: pid,
      ref: make_ref(),
      owner: self(),
      mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [:evolve, [], "test"]}
    }
  end
end

defmodule EvoGit.TaskRegistry.TaskTmpdirReclaimTest do
  use EvoGit.TaskRegistryCase, async: false

  @moduledoc """
  Registry-driven coverage of the managed per-task tmpdir RECLAIM lifecycle:
  every terminal transition must remove the task's `task_<id>` scratch dir while
  never removing the managed root itself.

  All assertions go through the PUBLIC `EvoGit.TaskRegistry` API
  (`update_task_status/3`, `force_kill_task/1`, `cancel_task/1`) against the
  isolated Store + registry pair started by `EvoGit.TaskRegistryCase` — one
  fresh pair per test, resolved through the `:evogit_task_registry_server`
  process-dictionary seam. The private helpers `reclaim_task_tmpdir/2` and
  `task_repo_path/1` are deliberately never called.

  ## Mode: `:per_repo` — a test-owned managed root

  `EvoGit.TaskTmpdir` would otherwise resolve `:system` mode against the REAL
  `/tmp/genesis` (`EvoGit.Platform.tmp_paths/0` is hardcoded
  `["/tmp", "/var/tmp"]`), so `setup_all/1` isolates `XDG_CONFIG_HOME` to a temp
  dir and writes a `config.toml` selecting `[tmp] mode = "per_repo"`. The
  managed root then becomes `<task opts[:path]>/.genesis/tmp` — a per-test temp
  dir, so no reclaim can reach the real `/tmp/genesis`. Driving `opts[:path]` is
  also exactly what exercises the registry's per-task path resolution
  (`opts[:path]` → `TaskTmpdir.reclaim/2`).

  ## `async: false` — forcing globals

  `setup_all/1` mutates the process-wide `XDG_CONFIG_HOME` env var, read live by
  `EvoGit.Config.resolve/1` (through `EvoGit.Platform.config_dir/1`) on every
  concurrently running module — isolating it is precisely what keeps this
  module off the real `/tmp/genesis`.
  """

  import EvoGit.TaskRegistry.TaskTmpdirTestHelpers,
    only: [seed_task: 3, tmp_repo!: 0, fake_task: 1]

  setup_all do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    xdg =
      Path.join(
        System.tmp_dir!(),
        "evogit_tmpdir_reclaim_xdg_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(xdg)
    System.put_env("XDG_CONFIG_HOME", xdg)

    # config.toml lives at <xdg>/genesis/config.toml.
    File.mkdir_p!(EvoGit.Config.config_dir())
    File.write!(EvoGit.Config.config_path(), "[tmp]\nmode = \"per_repo\"\n")

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(xdg)
    end)

    # A misread here would aim every reclaim at the REAL /tmp/genesis — fail the
    # whole module loudly instead of silently deleting system scratch dirs.
    assert EvoGit.TaskTmpdir.mode() == :per_repo

    :ok
  end

  describe "terminal reclaim via update_task_status/3 (the status choke point)" do
    test ":completed removes the per-task tmpdir and keeps the managed root" do
      repo = tmp_repo!()
      on_exit(fn -> File.rm_rf(repo) end)
      task_id = "tmpdir_complete_#{System.unique_integer([:positive])}"

      dir = EvoGit.TaskTmpdir.ensure(task_id, repo)
      root = EvoGit.TaskTmpdir.managed_root(repo)

      assert dir == Path.join(root, "task_#{task_id}")
      assert File.dir?(dir)
      assert File.dir?(root)

      seed_task(task_id, :running, path: repo)

      TaskRegistry.update_task_status(task_id, :completed, "done")
      # update_task_status/3 is a CAST — flush with a synchronous call.
      TaskRegistry.list_tasks()

      refute File.exists?(dir), "the per-task tmpdir must be reclaimed on :completed"
      assert File.dir?(root), "the managed root itself must survive reclaim"
    end

    test ":failed removes the per-task tmpdir" do
      repo = tmp_repo!()
      on_exit(fn -> File.rm_rf(repo) end)
      task_id = "tmpdir_failed_#{System.unique_integer([:positive])}"

      dir = EvoGit.TaskTmpdir.ensure(task_id, repo)
      seed_task(task_id, :running, path: repo)

      TaskRegistry.update_task_status(task_id, :failed, "boom")
      TaskRegistry.list_tasks()

      assert TaskRegistry.get_task(task_id).status == :failed
      refute File.exists?(dir), "the per-task tmpdir must be reclaimed on :failed"
    end

    test "a non-terminal transition keeps the per-task tmpdir" do
      repo = tmp_repo!()
      on_exit(fn -> File.rm_rf(repo) end)
      task_id = "tmpdir_running_#{System.unique_integer([:positive])}"

      dir = EvoGit.TaskTmpdir.ensure(task_id, repo)
      seed_task(task_id, :pending, path: repo)

      TaskRegistry.update_task_status(task_id, :running, nil)
      TaskRegistry.list_tasks()

      # Prove the cast really landed (the transition happened) …
      assert TaskRegistry.get_task(task_id).status == :running
      # … and that a non-terminal status never reclaims the tmpdir.
      assert File.dir?(dir), "a non-terminal status must not reclaim the tmpdir"
    end
  end

  describe "terminal reclaim on the direct writes that bypass the choke point" do
    test "force_kill_task/1 reclaims the tmpdir of a :running task" do
      repo = tmp_repo!()
      on_exit(fn -> File.rm_rf(repo) end)
      task_id = "tmpdir_forcekill_#{System.unique_integer([:positive])}"

      dir = EvoGit.TaskTmpdir.ensure(task_id, repo)
      root = EvoGit.TaskTmpdir.managed_root(repo)
      seed_task(task_id, :running, path: repo)

      wrapper = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> if Process.alive?(wrapper), do: Process.exit(wrapper, :kill) end)

      # Make the task "owned" — force_kill_task/1 requires a live task_refs entry.
      :sys.replace_state(TaskRegistry.server(), fn state ->
        %{state | task_refs: Map.put(state.task_refs, task_id, fake_task(wrapper))}
      end)

      assert :ok = TaskRegistry.force_kill_task(task_id)

      assert TaskRegistry.get_task(task_id).status == :failed
      refute File.exists?(dir), "force_kill_task/1 must reclaim the tmpdir"
      assert File.dir?(root), "the managed root itself must survive reclaim"
    end

    test "cancel_task/1 on a :pending task reclaims the tmpdir" do
      repo = tmp_repo!()
      on_exit(fn -> File.rm_rf(repo) end)
      task_id = "tmpdir_cancel_#{System.unique_integer([:positive])}"

      dir = EvoGit.TaskTmpdir.ensure(task_id, repo)
      seed_task(task_id, :pending, path: repo)

      assert :ok = TaskRegistry.cancel_task(task_id)

      assert TaskRegistry.get_task(task_id).status == :cancelled
      refute File.exists?(dir), "cancel_task/1 on a :pending task must reclaim the tmpdir"
    end
  end

  describe "the periodic cleanup no longer sweeps tmpdirs" do
    test ":periodic_cleanup leaves a non-live task dir untouched" do
      repo = tmp_repo!()
      on_exit(fn -> File.rm_rf(repo) end)
      non_live_id = "tmpdir_nonlive_#{System.unique_integer([:positive])}"

      # A `task_*` dir for a task that is NOT registered in the isolated store —
      # nothing makes it "live", so the removed stale sweep would have deleted it.
      dir = EvoGit.TaskTmpdir.ensure(non_live_id, repo)
      root = EvoGit.TaskTmpdir.managed_root(repo)

      assert File.dir?(dir)
      assert File.dir?(root)

      send(TaskRegistry.server(), :periodic_cleanup)
      # The handler is fire-and-forget — flush with a synchronous call.
      TaskRegistry.list_tasks()

      assert File.dir?(dir),
             "the periodic cleanup must not sweep a non-live task's tmpdir"

      assert File.dir?(root), "the managed root itself must survive"
    end
  end
end
