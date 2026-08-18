defmodule EvoDashWeb.ReviewLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskRegistry
  alias EvoGit.TaskInfo

  setup do
    # Test-seam stub (read by EvoDashWeb.ReviewLive.MergeCheck.start/4): the
    # auto-spawned async merge check resolves to :clean immediately and never
    # touches the file system, so mounted pages can't perform real git
    # worktree operations that race ExUnit's temp-repo teardown. Tests that
    # assert on :checking or inject their own results override this stub with
    # a blocking runner.
    Application.put_env(:evo_dash, :merge_check_runner, fn _node, _repo, _branch, _target ->
      {:ok, :clean}
    end)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :merge_check_runner)
    end)

    :ok
  end

  describe "review for non-existent task" do
    test "shows error for non-existent task id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/review/nonexistent-task-id")

      # The task lookup now runs in the async load task — flush it before
      # asserting on the error state.
      html = flush_review_load(view)

      assert html =~ "Review Not Available"
      assert html =~ "Task not found"
    end

    test "renders back to dashboard link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/review/nonexistent-task-id")

      html = flush_review_load(view)

      assert html =~ "Back to Dashboard"
      assert html =~ "href=\"/\""
    end
  end

  describe "ignore action" do
    setup do
      task_id = "review_test_ignore_#{System.unique_integer([:positive])}"

      # A completed task whose result references a branch that does NOT exist in
      # any real repository (repo_path points nowhere). This simulates an
      # orphaned/merged/deleted branch — the exact scenario the Ignore escape
      # hatch is designed for.
      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        result:
          {:ok,
           %{
             commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
             branch_name: "evogit/test-branch",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil
           }}
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        # Synchronize the deletion cast.
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "ignore button is always shown, even when branch does not exist", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      # The review actions only render after the async load completes.
      html = flush_review_load(view)

      # The Ignore button is rendered (phx-click="ignore") regardless of
      # whether the branch exists.
      assert html =~ ~s(phx-click="ignore")
      assert html =~ "Ignore"
    end

    test "clicking ignore sets review status and navigates to dashboard", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      # Click the ignore button — this triggers a navigation, so we assert the
      # LiveView process terminates and the browser is redirected to "/".
      view |> element("button[phx-click='ignore']") |> render_click()

      assert_redirect(view, "/")

      # The cast runs async, but a synchronous get_task call guarantees all
      # prior casts to the registry have been processed.
      assert TaskRegistry.get_task(task_id).review_status == :ignored
    end
  end

  describe "cancelled task review flow" do
    # A gracefully-cancelled task preserves its result, so it must be
    # reviewable exactly like a completed task. This task's result references
    # a branch that does NOT exist in any real repository (repo_path points
    # nowhere) — the orphaned-branch scenario the Ignore escape hatch is
    # designed for.
    setup do
      task_id = "review_test_cancelled_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :cancelled,
        opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        result:
          {:ok,
           %{
             commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
             branch_name: "evogit/test-branch",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil
           }}
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        # Synchronize the deletion cast.
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "review page renders for a cancelled task with action buttons", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      html = flush_review_load(view)

      # The page mounts without crashing and shows the review actions
      # (Ignore) just like a completed task.
      assert html =~ ~s(phx-click="ignore")
      assert html =~ "Ignore"
      assert html =~ "This branch no longer exists"
    end

    test "clicking ignore on a cancelled task sets review status and navigates", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      view |> element("button[phx-click='ignore']") |> render_click()

      assert_redirect(view, "/")

      assert TaskRegistry.get_task(task_id).review_status == :ignored
    end
  end

  describe "completed task with nil branch name" do
    # This test guards against an ArgumentError at :erlang.not(nil) that
    # crashed the review page on mount. The bug: when branch_name is nil,
    # the `branch_exists` computation yielded nil (not a boolean), and the
    # cond clause `not branch_exists` raised ArgumentError because `not`
    # strictly requires a boolean argument.
    setup do
      task_id = "review_test_nil_branch_#{System.unique_integer([:positive])}"

      # A completed task whose result does NOT include a branch_name
      # (result is an error tuple, so the pattern match falls through and
      # branch_name is nil). repo_path IS set via opts[:path], which is
      # the exact condition that triggered the crash: branch_exists was nil,
      # cond clause 1 was falsy, and clause 2 did `not nil` -> ArgumentError.
      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        result: {:error, "Something went wrong"}
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "mounts without crashing when branch_name is nil", %{
      conn: conn,
      task_id: task_id
    } do
      # Before the fix, this live/2 call raised ArgumentError: not nil.
      assert {:ok, _view, html} = live(conn, ~p"/review/#{task_id}")

      # The page renders normally (the "no changes" / review-not-available
      # path) rather than crashing.
      refute html =~ "ArgumentError"
    end
  end

  describe "archive tab with string-keyed metadata" do
    # This test guards against the infinite-recursion / OOM bug where archive
    # records arrive with STRING keys (after a DB round-trip through
    # Jason.decode) but the tree-building code read them with ATOM keys.
    # Before the fix, switching to the Archive tab would infinite-loop and
    # OOM-kill the BEAM. The key assertion is that the render TERMINATES.
    setup do
      task_id = "review_test_archive_#{System.unique_integer([:positive])}"

      # Seed the task store with a completed task whose archive_metadata uses
      # STRING keys — exactly as it looks after decode_archive runs
      # Jason.decode/1 on the persisted JSON.
      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        archive_metadata: [
          %{
            "agent_id" => "agent-1",
            "parent_id" => nil,
            "objective" => "Root agent objective",
            "depth" => 0
          },
          %{
            "agent_id" => "agent-2",
            "parent_id" => "agent-1",
            "objective" => "Child agent objective",
            "depth" => 1
          }
        ],
        result:
          {:ok,
           %{
             commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
             branch_name: "evogit/test-branch",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil
           }}
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "archive tab renders without hanging and shows agent ids", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      # The archive_metadata assign only arrives with the async load — flush
      # before switching to the Archive tab so the agent ids are present.
      flush_review_load(view)

      # Switch to the Archive tab — before the fix this would infinite-loop.
      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='archive']")
        |> render_click()

      # The render terminated (didn't OOM). Now verify the agent ids appear.
      assert html =~ "agent-1"
      assert html =~ "agent-2"
    end
  end

  describe "merge into target branch selector" do
    # These tests cover the "Merge into" target-branch selector feature: the
    # review page renders a <select> next to the Merge button, populated from
    # the repo's local branches with the default merge target pre-selected,
    # and the merge event merges the agent branch into the selected target.
    setup do
      {repo_path, task_id, change_sha} = create_review_task_with_repo!("main", "dev")

      {:ok, repo_path: repo_path, task_id: task_id, change_sha: change_sha}
    end

    test "renders a target-branch selector with the default target pre-selected", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      # The merge form only renders after the async load populates
      # merge_targets / default_merge_target.
      html = flush_review_load(view)

      # The "Merge into" selector appears next to the Merge button when the
      # repo has local branches.
      assert html =~ "Merge into"

      select_html = target_branch_select(html)
      assert select_html != "", "expected a target-branch <select> to be rendered"

      # Both local branches are offered, and the default target (main — first
      # of the ["main", "master", "dev", "prod"] candidates) is pre-selected.
      assert select_html =~ ~r{<option[^>]*value="main"[^>]*>}
      assert select_html =~ ~r{<option[^>]*value="dev"[^>]*>}
      assert selected_option_value(select_html) == "main"
    end

    test "merges the task branch into the selected target branch", %{
      conn: conn,
      task_id: task_id,
      repo_path: repo_path,
      change_sha: change_sha
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      render_click(view, "merge", %{"target_branch" => "dev"})

      # The success flash mentions the chosen target branch.
      flash = assert_redirect(view, "/")

      assert flash["success"] =~ "dev",
             "expected the success flash to mention the target branch, got: #{inspect(flash["success"])}"

      # The agent branch is deleted after a successful merge.
      {branches, 0} = System.cmd("git", ["branch"], cd: repo_path)
      refute branches =~ "task-branch", "expected the agent branch to be deleted after merge"

      # The change commit landed on the selected target (dev), not on the
      # default target (main).
      {_out, status} =
        System.cmd(
          "git",
          ["merge-base", "--is-ancestor", change_sha, "dev"],
          cd: repo_path,
          stderr_to_stdout: true
        )

      assert status == 0, "expected the change commit to be an ancestor of dev"
    end
  end

  describe "merge into target branch selector (single branch repo)" do
    setup do
      {repo_path, task_id, change_sha} = create_review_task_with_repo!("dev", nil)

      {:ok, repo_path: repo_path, task_id: task_id, change_sha: change_sha}
    end

    test "pre-selects dev when it is the only default-candidate branch", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      html = flush_review_load(view)

      select_html = target_branch_select(html)
      assert select_html != "", "expected a target-branch <select> to be rendered"
      assert select_html =~ ~r{<option[^>]*value="dev"[^>]*>}

      # main/master are absent, so the default target resolves to dev.
      assert selected_option_value(select_html) == "dev"
    end
  end

  describe "async merge check on the review page" do
    # The async dry-run merge check is spawned on mount for mergeable repos.
    # The runner is stubbed via the :merge_check_runner test seam: the
    # describe-level blocking runner keeps the status at :checking until the
    # LiveView dies at test end (the spawned task is linked to the view), so
    # no auto-generated result can race a manually injected
    # {:merge_check_result, ...} message. Results are injected directly via
    # send/2, making the state machine fully deterministic.
    setup do
      {repo_path, task_id, change_sha} = create_review_task_with_repo!("main", "dev")

      # Fully deterministic blocking runner — override the module-level fast
      # :clean stub so tests that assert on :checking (or inject their own
      # results) never race an auto-generated result message.
      Application.put_env(:evo_dash, :merge_check_runner, fn _node, _repo, _branch, _target ->
        receive do
          :release_merge_check -> {:ok, :clean}
        end
      end)

      {:ok, repo_path: repo_path, task_id: task_id, change_sha: change_sha}
    end

    test "starts a merge check on mount", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      # The merge check is only started AFTER the async review-data load
      # completes (MergeCheck.maybe_start runs from the load's handle_info,
      # never from handle_params) — flush the load first.
      flush_review_load(view)

      assert %{state: :checking, target: "main", files: []} = assigns(view)[:merge_status]
    end

    test "renders the clean state and keeps the merge form", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      send(view.pid, {:merge_check_result, task_id, node(), "main", {:ok, :clean}})
      html = render(view)

      assert html =~ "Merge check passed"
      assert assigns(view)[:merge_status] == %{state: :clean, target: "main", files: []}

      # The manual merge form/selector is untouched.
      assert html =~ "Merge into"
      assert target_branch_select(html) != ""
    end

    test "renders conflicting file names and the auto-resolve button", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      send(
        view.pid,
        {:merge_check_result, task_id, node(), "main",
         {:ok, {:conflict, ["src/app.ex", "lib/util.ex"]}}}
      )

      html = render(view)

      assert html =~ "src/app.ex"
      assert html =~ "lib/util.ex"
      assert html =~ "Auto-resolve conflict"
      assert assigns(view)[:merge_status].state == :conflict
    end

    test "ignores stale results (wrong target or wrong task id)", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      # Wrong target — the running check targets "main".
      send(view.pid, {:merge_check_result, task_id, node(), "other-target", {:ok, :clean}})
      html = render(view)

      assert assigns(view)[:merge_status].state == :checking
      refute html =~ "Merge check passed"

      # Wrong task id.
      send(view.pid, {:merge_check_result, "other-task-id", node(), "main", {:ok, :clean}})
      html = render(view)

      assert assigns(view)[:merge_status].state == :checking
      refute html =~ "Merge check passed"
    end

    test "changing the target branch re-checks and ignores old-target results", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      render_change(view, "merge_target_change", %{"target_branch" => "dev"})

      assert assigns(view)[:default_merge_target] == "dev"
      assert %{state: :checking, target: "dev"} = assigns(view)[:merge_status]

      # Result for the NEW target is applied.
      send(view.pid, {:merge_check_result, task_id, node(), "dev", {:ok, :clean}})
      html = render(view)

      assert assigns(view)[:merge_status].state == :clean
      assert html =~ "Merge check passed"

      # Result for the OLD target arrives afterwards — ignored.
      send(
        view.pid,
        {:merge_check_result, task_id, node(), "main", {:ok, {:conflict, ["old.txt"]}}}
      )

      html = render(view)

      assert assigns(view)[:merge_status].state == :clean
      refute html =~ "old.txt"
    end
  end

  describe "auto merge conflict resolution" do
    # These fixtures use a NONEXISTENT repo path (same pattern as the
    # ignore-test fixture), so no async check is started on mount
    # (merge_status stays nil) — results are injected directly via send/2.
    # The auto-resolve action starts a real :evolve task; its worker fails
    # fast on the invalid path with no LLM calls (same documented pattern as
    # projects_live_test's nonexistent-node-path submission).
    setup do
      task_id = "review_test_auto_resolve_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        result:
          {:ok,
           %{
             commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
             branch_name: "evogit/test-branch",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil
           }}
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "auto-resolve starts a merge-resolution task and redirects", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      # Flush the async load first so the injected merge result cannot be
      # clobbered by the load's assigns map (which resets merge_status to nil).
      flush_review_load(view)

      send(
        view.pid,
        {:merge_check_result, task_id, node(), "main",
         {:ok, {:conflict, ["file_a.txt", "file_b.txt"]}}}
      )

      html = render(view)

      assert html =~ "Auto-resolve conflict"
      assert html =~ "file_a.txt"
      assert html =~ "file_b.txt"

      render_click(view, "auto_resolve")

      assert_redirect(view, "/")

      # The original task is marked :continued (mirroring the resume flow).
      assert TaskRegistry.get_task(task_id).review_status == :continued

      # A new :evolve merge-resolution task was started with the merge opts.
      new_task =
        Enum.find(TaskRegistry.list_tasks(), &(merge_opt(&1.opts, :merge_from) == task_id))

      assert new_task, "expected a merge-resolution task to be started"

      on_exit(fn ->
        if new_task, do: TaskRegistry.delete_task(new_task.id)
        # Synchronize the deletion cast.
        TaskRegistry.list_tasks()
      end)

      assert new_task.type == :evolve
      assert merge_opt(new_task.opts, :merge_from) == task_id
      assert merge_opt(new_task.opts, :merge_target) == "main"
      assert new_task.opts[:mode] == "simple"
      assert new_task.opts[:path] == "/nonexistent/repo/path"
      assert new_task.opts[:starting_commit] == "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    end

    test "auto-resolve refuses when no conflict is detected (clean state)", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      send(view.pid, {:merge_check_result, task_id, node(), "main", {:ok, :clean}})
      html = render(view)
      assert html =~ "Merge check passed"

      html = render_click(view, "auto_resolve")
      assert html =~ "Auto-resolve unavailable"
      refute_redirected(view)

      # No review-status change, no spawned merge task.
      assert TaskRegistry.get_task(task_id).review_status == nil
      refute Enum.any?(TaskRegistry.list_tasks(), &(merge_opt(&1.opts, :merge_from) == task_id))
    end

    test "auto-resolve refuses when no check ran at all (nil state)", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      html = render_click(view, "auto_resolve")
      assert html =~ "Auto-resolve unavailable"
      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == nil
      refute Enum.any?(TaskRegistry.list_tasks(), &(merge_opt(&1.opts, :merge_from) == task_id))
    end
  end

  describe "auto merge conflict resolution on an unreachable remote node" do
    # Same XDG_CONFIG_HOME isolation + fake ConnectionManager seam as the
    # remote-node describe above.
    setup do
      original = System.get_env("XDG_CONFIG_HOME")

      tmp_config =
        Path.join(
          System.tmp_dir!(),
          "evogit_test_config_review_auto_" <> to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(tmp_config)
      System.put_env("XDG_CONFIG_HOME", tmp_config)

      on_exit(fn ->
        File.rm_rf(tmp_config)

        if original do
          System.put_env("XDG_CONFIG_HOME", original)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end
      end)

      :ok
    end

    test "auto-resolve against an unreachable node fails with an error flash", %{conn: conn} do
      id = "review-auto-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Review Auto Target"
        })

      start_supervised!(
        {EvoDashWeb.ReviewLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      # The task does not exist on the (unreachable) remote node — the page
      # renders the graceful error state, but merge_check_result injection and
      # the auto_resolve event still operate on the assigns.
      {:ok, view, _html} = live(conn, "/review/some-remote-task-id?node=" <> id)

      # Flush the async load (it fails fast with :nodedown → error state) so
      # the injected merge result cannot be clobbered by the load's assigns
      # map (which resets merge_status to nil).
      flush_review_load(view)

      remote_node = assigns(view)[:current_node]
      assert remote_node != node()

      send(
        view.pid,
        {:merge_check_result, "some-remote-task-id", remote_node, "main",
         {:ok, {:conflict, ["file_a.txt"]}}}
      )

      render(view)

      # The set_review_status and start_task RPCs both fail fast with
      # :nodedown → error flash, no navigation.
      html = render_click(view, "auto_resolve")

      assert html =~ "Failed to start auto-resolve"
      refute_redirected(view)
    end
  end

  describe "remote node review (unreachable node)" do
    # A remote node that cannot be reached must degrade to the existing
    # graceful "Review Not Available" state instead of crashing. The seam:
    # a fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under the target id with a :connected
    # phase, so NodeAware resolves `?node=` to the remote BEAM node atom
    # "genesis_remote@127.0.0.1" — an unreachable fake node (same pattern as
    # settings_live_test). The subsequent `:erpc` calls fail fast with
    # :nodedown, so NodeContext.get_task returns nil → the existing
    # "Task not found" error state renders.
    #
    # XDG_CONFIG_HOME is isolated so the saved target never touches the
    # developer's real ~/.config/genesis/ (same pattern as settings_live_test).
    setup do
      original = System.get_env("XDG_CONFIG_HOME")

      tmp_config =
        Path.join(
          System.tmp_dir!(),
          "evogit_test_config_review_" <> to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(tmp_config)
      System.put_env("XDG_CONFIG_HOME", tmp_config)

      on_exit(fn ->
        File.rm_rf(tmp_config)

        if original do
          System.put_env("XDG_CONFIG_HOME", original)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end
      end)

      :ok
    end

    test "unreachable remote node renders the graceful not-available state", %{conn: conn} do
      id = "review-test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Review Test Target"
        })

      start_supervised!(
        {EvoDashWeb.ReviewLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      # The task does not exist on the (unreachable) remote node — the RPC
      # fails fast with :nodedown, so the page must render the existing
      # "Review Not Available" error state without crashing. The task fetch
      # now runs in the async load task; flush it.
      {:ok, view, _html} = live(conn, "/review/some-remote-task-id?node=" <> id)

      html = flush_review_load(view)

      assert html =~ "Review Not Available"
      assert html =~ "Task not found"
      refute html =~ "ArgumentError"
    end

    test "unknown node param falls back to local (task not found locally)", %{conn: conn} do
      # An unknown `?node=` id resolves to the local context (NodeAware
      # semantics) — the task is not in the local store, so the existing
      # not-found error state renders.
      {:ok, view, _html} = live(conn, ~p"/review/nonexistent-task-id?node=unknown-target-id")

      html = flush_review_load(view)

      assert html =~ "Review Not Available"
      assert html =~ "Task not found"
    end
  end

  describe "async review-data load" do
    # The review page now loads its data asynchronously: handle_params spawns
    # a supervised task (EvoDashWeb.ReviewLive.LoadData) that sends
    # {:review_data_loaded, task_id, node, generation, result} back to the
    # LiveView. The page renders a spinner ("Loading review data...") until
    # the result arrives, and the handle_info applies it under a stale-guard
    # (task id / node / monotonic load_generation).

    test "async load shows the loading state then populates the page", %{conn: conn} do
      {_repo_path, task_id, change_sha} = create_review_task_with_repo!("main", "dev")

      {:ok, view, html} = live(conn, ~p"/review/#{task_id}")

      # The initial render happens before the spawned load task can be
      # processed, so the page always mounts in the loading state.
      assert html =~ "Loading review data..."
      assert html =~ "loading-spinner"

      # Flush the async load: the review content replaces the spinner.
      html = flush_review_load(view)

      # Title (objective fallback), branch badge, and commit-sha badge.
      assert html =~ "Test objective"
      assert html =~ "task-branch"
      assert html =~ String.slice(change_sha, 0..7)

      # The commits list is populated by the load too.
      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='commits']")
        |> render_click()

      assert html =~ "Agent change commit"
    end

    test "drops stale async load results", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      gen = assigns(view)[:load_generation]

      # Wrong task id.
      send(
        view.pid,
        {:review_data_loaded, "wrong-task-id", node(), gen, {:ok, %{title: "INJECTED"}}}
      )

      # Right task id, but a different node.
      send(
        view.pid,
        {:review_data_loaded, task_id, :review_other_node, gen, {:ok, %{title: "INJECTED"}}}
      )

      # Right task + node, but a stale generation.
      send(
        view.pid,
        {:review_data_loaded, task_id, node(), gen - 1, {:ok, %{title: "INJECTED"}}}
      )

      # Synchronization: a VALID result for the current generation is applied
      # AFTER the stale ones (FIFO mailbox). It touches a different assign
      # (summary_raw), so a wrongly-applied stale title would remain visible
      # once the marker lands — poll for it.
      send(view.pid, {:review_data_loaded, task_id, node(), gen, {:ok, %{summary_raw: true}}})

      wait_until(fn -> assigns(view)[:summary_raw] == true end)

      # None of the stale results were applied.
      assert assigns(view)[:title] == "Test objective"
      html = render(view)
      refute html =~ "INJECTED"
      assert html =~ "Test objective"
    end

    test "broadcast for a different task does not trigger a review-data reload", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      gen_before = assigns(view)[:load_generation]

      # A PubSub "tasks" broadcast for ANOTHER task on the viewed node
      # (message shape: {:task_updated, task_id, status, node}). Direct send is
      # equivalent to the broadcast for handle_info.
      send(view.pid, {:task_updated, "some_other_task_id", :finalizing, node()})

      # Past the 300ms trailing-edge debounce. The sidebar reload must have
      # run by now (tasks_reload_pending cleared) — otherwise the unchanged
      # generation assertion below would be vacuous.
      Process.sleep(400)
      wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)

      # No new load was started: the broadcast-guard skipped the reload for
      # a non-reviewed task.
      assert assigns(view)[:load_generation] == gen_before

      # A stale result from the old generation is still dropped.
      send(
        view.pid,
        {:review_data_loaded, task_id, node(), gen_before - 1, {:ok, %{title: "INJECTED"}}}
      )

      Process.sleep(100)

      assert assigns(view)[:title] == "Test objective"

      # The page still renders normally.
      html = render(view)
      refute html =~ "INJECTED"
      assert html =~ "Test objective"
      assert html =~ ~s(phx-click="ignore")
    end

    test "broadcast for the reviewed task triggers a review-data reload", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      gen_before = assigns(view)[:load_generation]

      # The reviewed task's own broadcast (from the viewed node) warrants a
      # page reload.
      send(view.pid, {:task_updated, task_id, :finalizing, node()})

      # Past the 300ms debounce — wait for the new load to have started
      # (generation incremented by start_async_load).
      Process.sleep(400)
      wait_until(fn -> assigns(view)[:load_generation] == gen_before + 1 end)

      # Flush the reload and assert the page still renders the review content.
      html = flush_review_load(view)

      assert html =~ "Test objective"
      assert html =~ ~s(phx-click="ignore")
    end

    test "broadcast from a foreign node triggers no reload at all", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      gen_before = assigns(view)[:load_generation]

      # A broadcast published by a DIFFERENT BEAM node is dropped by the node
      # filter BEFORE the debounce is scheduled: neither the sidebar reload
      # (tasks_reload_pending stays false) nor the stash/guarded review-data
      # reload may fire.
      send(view.pid, {:task_updated, task_id, :finalizing, :remote@elsewhere})

      # Past the 300ms debounce window.
      Process.sleep(400)

      # No debounce was ever scheduled and no review-data load was started.
      refute assigns(view)[:tasks_reload_pending]
      assert assigns(view)[:load_generation] == gen_before

      # The page still renders normally.
      html = render(view)
      assert html =~ "Test objective"
      assert html =~ ~s(phx-click="ignore")
    end

    test "task_deleted broadcast does not trigger a review-data reload", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      gen_before = assigns(view)[:load_generation]

      # A deleted task — even the reviewed task itself — can never warrant a
      # review-data reload (nothing is left to review): the stash is never
      # set, only the sidebar refresh runs (matching node).
      send(view.pid, {:task_deleted, task_id, node()})

      # Past the 300ms trailing-edge debounce. The sidebar reload must have
      # run by now (tasks_reload_pending cleared) — otherwise the unchanged
      # generation assertion below would be vacuous.
      Process.sleep(400)
      wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)

      # No new load was started: deleted tasks are never stashed.
      assert assigns(view)[:load_generation] == gen_before

      # The page still renders normally.
      html = render(view)
      assert html =~ "Test objective"
      assert html =~ ~s(phx-click="ignore")
    end
  end

  # --- Helpers for the merge-target selector tests ---

  # Reads the LiveView's socket assigns (same pattern as projects_live_test).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Opt keys round-trip through the Store codec: known keys stay atoms, but
  # unknown keys (merge_from/merge_target) come back as STRING keys. Read
  # either form.
  defp merge_opt(opts, key) do
    # The Store codec round-trips unknown opt keys (merge_from/merge_target)
    # as STRING keys, so look up both forms without Access (which raises on
    # string-keyed keyword lists) and without Keyword.get/3 (atom-key-only).
    find_opt(opts, key) || find_opt(opts, Atom.to_string(key))
  end

  defp find_opt(opts, key) do
    Enum.find_value(opts, fn
      {^key, value} -> value
      _ -> nil
    end)
  end

  # Runs a git command in `repo`, asserting it succeeds.
  defp git!(repo, args) do
    {output, status} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
  end

  # Creates a temp git repo with the given primary branch (plus an optional
  # secondary branch pointing at the base commit), an agent `task-branch` with
  # a change commit on top of the primary branch, and a completed review task
  # pointing at it. Returns {repo_path, task_id, change_sha} and registers
  # on_exit cleanup.
  defp create_review_task_with_repo!(primary, secondary) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_review_merge_test_" <> to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp_dir)
    git!(tmp_dir, ["init"])
    git!(tmp_dir, ["config", "user.email", "test@example.com"])
    git!(tmp_dir, ["config", "user.name", "Test User"])

    # Base commit, then rename the branch to the primary name (the machine's
    # init.defaultBranch may vary).
    File.write!(Path.join(tmp_dir, "base.txt"), "base\n")
    git!(tmp_dir, ["add", "base.txt"])
    git!(tmp_dir, ["commit", "-m", "Initial commit"])
    {current, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: tmp_dir)

    if String.trim(current) != primary do
      git!(tmp_dir, ["branch", "-m", primary])
    end

    if secondary do
      git!(tmp_dir, ["branch", secondary])
    end

    # Agent task branch with a change commit, then back to the primary branch.
    git!(tmp_dir, ["checkout", "-b", "task-branch"])
    File.write!(Path.join(tmp_dir, "feature.txt"), "feature change\n")
    git!(tmp_dir, ["add", "feature.txt"])
    git!(tmp_dir, ["commit", "-m", "Agent change commit"])
    {change_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
    git!(tmp_dir, ["checkout", primary])

    task_id = seed_review_task!(tmp_dir, String.trim(change_sha))

    on_exit(fn ->
      rm_rf_retry(tmp_dir)
    end)

    {tmp_dir, task_id, String.trim(change_sha)}
  end

  # Removes a temp repo dir with retries (defense in depth): a spawned merge
  # check can briefly touch the repo while ExUnit tears it down, which makes
  # File.rm_rf!/1 raise intermittently. Never raises.
  defp rm_rf_retry(path, attempts \\ 5) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, _, _} when attempts > 1 ->
        Process.sleep(50)
        rm_rf_retry(path, attempts - 1)

      other ->
        other
    end
  end

  # Seeds a completed review task pointing at `repo_path` with the agent
  # branch `task-branch` (which must exist in the repo).
  defp seed_review_task!(repo_path, change_sha) do
    task_id = "review_test_merge_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      opts: [path: repo_path, objective: "Test objective"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      review_status: nil,
      result:
        {:ok,
         %{
           commit_sha: change_sha,
           branch_name: "task-branch",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil
         }}
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      TaskRegistry.delete_task(task_id)
      # Synchronize the deletion cast.
      TaskRegistry.list_tasks()
    end)

    task_id
  end

  # Seeds a completed task whose result references a branch that does NOT
  # exist in any real repository (repo_path points nowhere) — the same
  # orphaned-branch scenario as the ignore-test fixture, but self-contained
  # for the async-load describe. Returns the task id.
  defp seed_orphaned_review_task! do
    task_id = "review_test_async_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      opts: [path: "/nonexistent/repo/path", objective: "Test objective"],
      ref: nil,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      logs: [],
      review_status: nil,
      result:
        {:ok,
         %{
           commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
           branch_name: "evogit/test-branch",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil
         }}
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      TaskRegistry.delete_task(task_id)
      # Synchronize the deletion cast.
      TaskRegistry.list_tasks()
    end)

    task_id
  end

  # Delegates to the shared flush helper (EvoDashWeb.TestHelpers.flush_loading/4).
  defp flush_review_load(view, timeout \\ 5000),
    do:
      EvoDashWeb.TestHelpers.flush_loading(
        view,
        "Loading review data...",
        "timed out waiting for the async review-data load to finish",
        timeout
      )

  # Polls `fun` until it returns a truthy value (or the timeout elapses).
  # Used to synchronize on LiveView state changes that follow directly-sent
  # messages (mailbox FIFO guarantees the preceding messages were processed).
  defp wait_until(fun, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for condition after #{timeout}ms")
        else
          Process.sleep(10)
          wait_loop.(wait_loop)
        end
      end
    end

    wait_loop.(wait_loop)
  end

  # Extracts the "Merge into" target-branch <select> block, or "" if absent.
  defp target_branch_select(html) do
    case Regex.run(~r{<select[^>]*name="target_branch"[^>]*>.*?</select>}s, html) do
      [select_html] -> select_html
      _ -> ""
    end
  end

  # Returns the value of the pre-selected <option> inside a select block, or
  # nil. Tolerates `selected` appearing before or after the value attribute:
  # first find the option tag carrying `selected` anywhere in its attribute
  # list, then extract its `value` attribute. (A single Regex.run with
  # alternation would only return the capture groups that participated, so the
  # two-step approach is required.)
  defp selected_option_value(select_html) do
    case Regex.run(~r{<option\b[^>]*selected[^>]*>}, select_html) do
      [option_tag] ->
        case Regex.run(~r/value="([^"]+)"/, option_tag) do
          [_, v] -> v
          _ -> nil
        end

      _ ->
        nil
    end
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.SettingsLiveTest.ConnectionManager). The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.ReviewLiveTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end
