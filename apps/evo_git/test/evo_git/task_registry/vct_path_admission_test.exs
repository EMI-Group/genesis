defmodule EvoGit.TaskRegistry.VctPathAdmissionTest do
  @moduledoc """
  A VCT point is METADATA, never an execution path — the task-admission guard
  that says so.

  A `vct:///…` point binds a point to an OS path; it is not a filesystem and it
  never names a worktree. A WORKSPACE mount (`vct:///workspaces/<slug>`) is the
  strictest case: it is a pure grouping point with NO OS path at all, so a task
  whose `:path` is a workspace point has nowhere to execute. This module pins
  the three layers of the guard:
    * `EvoGit.TaskRegistry.RuntimeOpts.admit_task_path/1` — the non-raising
      registry gate (absent/`nil` path stays valid for the repo-less `:reflect`
      task, a VCT point is refused, a non-binary path is refused, and every
      ordinary binary keeps passing UNCHANGED — absoluteness is deliberately
      still not validated);
    * `EvoGit.TaskRegistry.RuntimeOpts.build_common_runtime_opts/3` — the
      raising defense-in-depth helper for direct callers that bypass admission;
    * the two registry call sites, `start_task/2` and `resume_task/1`, which
      refuse before anything is enqueued, spawned or persisted.

  Runs `async: true`: every test gets its OWN isolated `EvoGit.Store` +
  `EvoGit.VCT` + `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase`, and the
  two registry tests never reach an app-global resource — the admission gate
  runs BEFORE the config read, the durable-roster read and the wrapper spawn, so
  no scheduler, agent-state or PubSub state is touched (every assertion is
  scoped to this test's own isolated store and registry). No `Process.sleep/1`
  is used: `GenServer.call` replies are the barrier.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.TaskRegistry.RuntimeOpts
  alias EvoGit.VCT.Table

  @workspace "vct:///workspaces/foo"
  @project "vct:///projects/foo"
  @reserved "vct:///genesis-source"

  describe "the workspace-point predicate the guard relies on" do
    test "is TOTAL and PROCESS-FREE: no VCT server is needed to answer" do
      # The guard must never depend on a running `EvoGit.VCT` GenServer (task
      # admission runs inside the registry, which may precede or outlive it), so
      # the predicate lives in the pure `EvoGit.VCT.Table` rules module: no I/O,
      # no process, no data directory. Answering here — without ever calling the
      # server — is the proof.
      assert Table.workspace_point?(@workspace)
      assert Table.workspace_point?("vct:///workspaces/foo/sub")
      # A workspace needs a NAME; a project, a reserved and a garbage point are
      # all refused as workspaces (they are handled by their own rules).
      refute Table.workspace_point?("vct:///workspaces")
      refute Table.workspace_point?(@project)
      refute Table.workspace_point?(@reserved)
      refute Table.workspace_point?("vct:garbage")
      refute Table.workspace_point?(nil)
      refute Table.workspace_point?("/tmp/ordinary/dir")
    end
  end

  describe "RuntimeOpts.admit_task_path/1" do
    test "an ABSENT path is admitted unchanged (the repo-less :reflect task)" do
      opts = [objective: "introspect the runtime", session_mode: "oneshot"]
      assert {:ok, ^opts} = RuntimeOpts.admit_task_path(opts)
      assert RuntimeOpts.admit_task_path([]) == {:ok, []}
    end

    test "a NIL path is admitted unchanged" do
      opts = [path: nil, objective: "introspect"]
      assert {:ok, ^opts} = RuntimeOpts.admit_task_path(opts)
    end

    test "a workspace point is refused: a workspace has no OS path and no worktree" do
      assert RuntimeOpts.admit_task_path(path: @workspace) == {:error, :workspace_not_executable}

      assert RuntimeOpts.admit_task_path(path: "vct:///workspaces/foo/sub/dir") ==
               {:error, :workspace_not_executable}
    end

    test "every OTHER vct: binary is refused as a metadata-only point" do
      for point <- [@project, @reserved, "vct:garbage", "vct:", "vct:///workspaces"] do
        assert RuntimeOpts.admit_task_path(path: point) == {:error, :vct_point_not_executable},
               "expected :vct_point_not_executable for #{inspect(point)}"
      end
    end

    test "a present NON-BINARY path is refused as :invalid_path" do
      for path <- [:nowhere, 42, %{dir: "/tmp"}, ["/tmp"], {:ok, "/tmp"}] do
        assert RuntimeOpts.admit_task_path(path: path) == {:error, :invalid_path},
               "expected :invalid_path for #{inspect(path)}"
      end
    end

    test "ordinary binaries pass UNCHANGED — absoluteness and existence stay unvalidated" do
      # Out of scope on purpose: this gate only refuses VCT points, so no
      # existing caller's path handling changes (a relative path is passed to the
      # runtime exactly like an absolute one).
      for path <- [
            "/tmp/test",
            "/tmp/does-not-exist-#{System.unique_integer([:positive])}",
            "relative/dir"
          ] do
        opts = [path: path, mode: "simple"]
        assert {:ok, ^opts} = RuntimeOpts.admit_task_path(opts)
      end
    end

    test "unrelated task opts are preserved verbatim" do
      opts = [path: "/tmp/test", mode: "simple", objective: "o", archive: true]
      assert {:ok, ^opts} = RuntimeOpts.admit_task_path(opts)
    end
  end

  describe "RuntimeOpts.build_common_runtime_opts/3" do
    test "raises for a WORKSPACE point, naming the point and the missing worktree" do
      error =
        assert_raise ArgumentError, fn ->
          RuntimeOpts.build_common_runtime_opts([path: @workspace], "task_1", :evolve)
        end

      assert error.message =~ @workspace
      assert error.message =~ "workspace"
      assert error.message =~ "not an executable path"
    end

    test "raises for any OTHER VCT point: points are metadata-only" do
      for point <- [@project, @reserved] do
        error =
          assert_raise ArgumentError, fn ->
            RuntimeOpts.build_common_runtime_opts([path: point], "task_1", :evolve)
          end

        assert error.message =~ point
        assert error.message =~ "metadata-only"
        assert error.message =~ "OS path"
      end
    end

    test "an ordinary path still builds the usual runtime opts" do
      assert {nil, runtime_opts} =
               RuntimeOpts.build_common_runtime_opts([path: "/tmp/test"], "task_1", :evolve)

      assert runtime_opts[:repo_path] == "/tmp/test"
      assert runtime_opts[:mode] == :simple
      assert runtime_opts[:task_id] == "task_1"
      assert runtime_opts[:persistent_state] == true
    end

    test "a RELATIVE path is still built (absoluteness is not this guard's job)" do
      assert {nil, runtime_opts} =
               RuntimeOpts.build_common_runtime_opts(
                 [path: "relative/dir", mode: "existing"],
                 "task_1",
                 :genesis
               )

      assert runtime_opts[:repo_path] == "relative/dir"
    end
  end

  describe "TaskRegistry.start_task/2" do
    test "a workspace point is refused, nothing is enqueued or persisted, registry stays alive",
         %{registry: registry} do
      assert TaskRegistry.start_task(:evolve,
               path: @workspace,
               mode: "simple",
               objective: "must never run"
             ) == {:error, :workspace_not_executable}

      assert TaskRegistry.list_tasks() == []
      assert EvoGit.Store.safe_select_all_tasks(store()) == []
      # No wrapper task was left behind, and the refusal did not take the
      # registry down with it (a raise here would have killed it).
      assert :sys.get_state(registry).task_refs == %{}
      assert Process.whereis(registry) != nil
    end

    test "any other VCT point is refused the same way", %{registry: registry} do
      for point <- [@project, @reserved] do
        assert TaskRegistry.start_task(:evolve, path: point, mode: "simple") ==
                 {:error, :vct_point_not_executable},
               "expected :vct_point_not_executable for #{inspect(point)}"
      end

      assert TaskRegistry.list_tasks() == []
      assert :sys.get_state(registry).task_refs == %{}
      assert Process.whereis(registry) != nil
    end

    test "a non-binary path is refused as :invalid_path", %{registry: registry} do
      assert TaskRegistry.start_task(:evolve, path: :nowhere, mode: "simple") ==
               {:error, :invalid_path}

      assert TaskRegistry.list_tasks() == []
      assert Process.whereis(registry) != nil
    end
  end

  describe "TaskRegistry.resume_task/1" do
    test "a paused row whose persisted path is a VCT point is refused and stays :paused" do
      task_id = "resume_vct_#{System.unique_integer([:positive])}"
      seed_paused!(task_id, path: @workspace)

      # The path gate runs BEFORE the durable-roster gate, so a row with no
      # durable ROOT run answers the path reason — never `:not_resumable`.
      assert TaskRegistry.resume_task(task_id) == {:error, :workspace_not_executable}

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.finished_at == nil
      assert Keyword.get(fetched.opts, :path) == @workspace
      # Admission wrote nothing: no lease was granted to the refused resume.
      assert fetched.lease_expires_at == nil
    end

    test "a resumed row carrying any other VCT point is refused too" do
      task_id = "resume_vct_project_#{System.unique_integer([:positive])}"
      seed_paused!(task_id, path: @project)

      assert TaskRegistry.resume_task(task_id) == {:error, :vct_point_not_executable}
      assert reload(task_id).status == :paused
    end
  end

  ## Helpers

  # Seeds one `:paused` row (a `:clean` pause: no `finished_at`, no lease) with
  # the given persisted opts straight into the isolated store.
  defp seed_paused!(task_id, opts) do
    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :paused,
      opts: opts,
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      logs: [],
      result: nil,
      session_mode: "oneshot",
      pause_kind: :clean,
      lease_expires_at: nil
    }

    :ok = EvoGit.Store.put_task(store(), task)
    task
  end

  defp reload(task_id), do: EvoGit.Store.get_task(store(), task_id)
end
