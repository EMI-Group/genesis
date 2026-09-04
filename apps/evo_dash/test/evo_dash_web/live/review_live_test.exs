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

    # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
    # terminated by the per-test isolation above — reset it so one test's
    # sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

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

      # Wait for the hub snapshot so the post-action invalidate assertion is
      # non-vacuous (this orphaned-branch fixture is sidebar-visible too).
      wait_hub_warm()

      # Click the ignore button — this triggers a navigation, so we assert the
      # LiveView process terminates and the browser is redirected to "/projects".
      view |> element("button[phx-click='ignore']") |> render_click()

      assert_redirect(view, "/projects")

      # The cast runs async, but a synchronous get_task call guarantees all
      # prior casts to the registry have been processed.
      assert TaskRegistry.get_task(task_id).review_status == :ignored

      # The ignore success path invalidates the hub snapshot before navigating
      # away (review_live.ex invalidate_active_tasks/1) — the destination
      # /projects mount must come up COLD and re-fetch.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
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

      assert_redirect(view, "/projects")

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
      flash = assert_redirect(view, "/projects")

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

      send(view.pid, {:merge_check_result, task_id, node(), "primary", "main", {:ok, :clean}})
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
        {:merge_check_result, task_id, node(), "primary", "main",
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
      send(
        view.pid,
        {:merge_check_result, task_id, node(), "primary", "other-target", {:ok, :clean}}
      )

      html = render(view)

      assert assigns(view)[:merge_status].state == :checking
      refute html =~ "Merge check passed"

      # Wrong task id.
      send(
        view.pid,
        {:merge_check_result, "other-task-id", node(), "primary", "main", {:ok, :clean}}
      )

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
      send(view.pid, {:merge_check_result, task_id, node(), "primary", "dev", {:ok, :clean}})
      html = render(view)

      assert assigns(view)[:merge_status].state == :clean
      assert html =~ "Merge check passed"

      # Result for the OLD target arrives afterwards — ignored.
      send(
        view.pid,
        {:merge_check_result, task_id, node(), "primary", "main", {:ok, {:conflict, ["old.txt"]}}}
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

      # Wait for the hub snapshot so the post-action invalidate assertion is
      # non-vacuous (this orphaned-branch fixture is still sidebar-visible:
      # completed + branch_name + review_status nil).
      wait_hub_warm()

      send(
        view.pid,
        {:merge_check_result, task_id, node(), "primary", "main",
         {:ok, {:conflict, ["file_a.txt", "file_b.txt"]}}}
      )

      html = render(view)

      assert html =~ "Auto-resolve conflict"
      assert html =~ "file_a.txt"
      assert html =~ "file_b.txt"

      render_click(view, "auto_resolve")

      assert_redirect(view, "/projects")

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

      # Auto-resolve invalidates the hub snapshot before navigating away
      # (merge_check.ex handle_auto_resolve/1) — the destination /projects
      # mount must come up COLD and re-fetch.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "auto-resolve refuses when no conflict is detected (clean state)", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      flush_review_load(view)

      send(view.pid, {:merge_check_result, task_id, node(), "primary", "main", {:ok, :clean}})
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

      # The task does not exist on the (unreachable) remote node — the real
      # async load fails fast with :nodedown and the page renders the graceful
      # error state (review_repos stays []). The merge-check result handler
      # drops results for repo ids absent from @review_repos (per-repo
      # stale-guard), so to reach the auto-resolve RPC-failure path we first
      # inject a VALID load result carrying a primary review-repo entry (with
      # branch_exists: false and merge_targets: [] so MergeCheck.maybe_start
      # does NOT spawn an async check — fully deterministic), then inject the
      # conflict result for "primary".
      {:ok, view, _html} = live(conn, "/review/some-remote-task-id?node=" <> id)

      # Flush the real async load (nodedown → error state) so the injected
      # load result cannot be clobbered by a racing message.
      flush_review_load(view)

      remote_node = assigns(view)[:current_node]
      assert remote_node != node()

      gen = assigns(view)[:load_generation]

      send(
        view.pid,
        {:review_data_loaded, "some-remote-task-id", remote_node, gen,
         {:ok,
          %{
            review_repos: [
              %{
                repo_id: "primary",
                repo_path: "/nonexistent/repo/path",
                branch_name: "evogit/test-branch",
                commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                base_sha: nil,
                branch_exists: false,
                review_data: nil,
                commits: [],
                merge_targets: [],
                default_merge_target: nil,
                merge_status: nil
              }
            ],
            active_repo_id: "primary",
            loading: false,
            error: nil
          }}}
      )

      render(view)

      send(
        view.pid,
        {:merge_check_result, "some-remote-task-id", remote_node, "primary", "main",
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

    test "summary copy button renders with the hook and copied event flashes", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")

      html = flush_review_load(view)

      # The summary copy button (conversation tab, the default) carries the
      # ClipboardCopy hook and the agent summary as its data-content payload.
      assert html =~ ~s(id="summary-copy-btn")
      assert html =~ ~s(phx-hook="ClipboardCopy")
      assert html =~ ~s(data-content="Agent summary")

      # The "copied" event pushed by the hook flashes the confirmation.
      html = render_hook(view, "copied", %{})

      assert html =~ "Copied to clipboard"
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

  describe "multi-repo review — repo list construction" do
    # The review page turns a task's writable-foreign-repo results (the
    # top-level `repos` map, STRING keys after the Store/Codec round trip)
    # into one review entry per repo, primary FIRST. Only writable foreign
    # repos that actually produced commits (a non-nil branch_name in `repos`)
    # get an entry — read-only repos are absent from `repos`, and
    # writable-with-no-commits repos carry a nil branch_name. NONEXISTENT
    # paths keep the fixtures deterministic (branch_exists degrades to false,
    # no async merge check starts).
    test "builds primary-first review repos; drops read-only and no-commits foreign repos", %{
      conn: conn
    } do
      primary_dir = "/nonexistent/primary/path"
      foreign_dir = "/nonexistent/foreign/path"
      primary_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      foreign_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      task_id =
        seed_multi_repo_task!(
          primary_dir,
          primary_sha,
          [
            %{"id" => "original", "root" => foreign_dir, "writable" => true},
            %{"id" => "readonly", "root" => "/nonexistent/readonly/path", "writable" => false},
            %{"id" => "no_commits", "root" => "/nonexistent/no_commits/path", "writable" => true}
          ],
          %{
            "primary" => %{"commit_sha" => primary_sha, "branch_name" => "task-branch"},
            "original" => %{"commit_sha" => foreign_sha, "branch_name" => "task-branch"},
            "no_commits" => %{"commit_sha" => nil, "branch_name" => nil}
          }
        )

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      repos = assigns(view)[:review_repos]

      # Exactly the primary + the writable foreign repo with commits.
      assert length(repos) == 2

      [primary, foreign] = repos

      assert primary.repo_id == "primary"
      assert primary.repo_path == primary_dir
      assert primary.branch_name == "task-branch"
      assert primary.commit_sha == primary_sha

      assert foreign.repo_id == "original"
      assert foreign.repo_path == foreign_dir
      assert foreign.branch_name == "task-branch"
      assert foreign.commit_sha == foreign_sha

      # Read-only repos (absent from `repos`) and writable-with-no-commits
      # repos (nil branch_name) get NO review entry.
      refute Enum.any?(repos, &(&1.repo_id == "readonly"))
      refute Enum.any?(repos, &(&1.repo_id == "no_commits"))

      # With more than one review repo, the per-repo tab bar renders.
      html = render(view)
      assert html =~ ~s(phx-click="switch_repo")
      assert html =~ "original"
    end

    test "legacy tasks without a repos key yield exactly one primary entry", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      repos = assigns(view)[:review_repos]

      assert length(repos) == 1
      assert hd(repos).repo_id == "primary"

      # Single-repo pages render NO repo tab bar (pixel-identical to before).
      refute render(view) =~ ~s(phx-click="switch_repo")
    end
  end

  describe "multi-repo review — merge broadcast" do
    setup do
      {primary_dir, foreign_dir, task_id, primary_sha, foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      # The committed fixture only cleans up the foreign dir; tidy the primary
      # temp repo here too.
      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok,
       primary_dir: primary_dir,
       foreign_dir: foreign_dir,
       task_id: task_id,
       primary_sha: primary_sha,
       foreign_sha: foreign_sha}
    end

    test "merges every review repo into its own target and marks the task merged", %{
      conn: conn,
      task_id: task_id,
      primary_dir: primary_dir,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      # The runner executes synchronously inside handle_event("merge") — a
      # collecting fun captures the test pid and reports each call.
      Application.put_env(:evo_dash, :review_merge_runner, fn node, repo_path, branch, target ->
        send(test_pid, {:merged_call, node, repo_path, branch, target})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Wait for the connected-mount sidebar fetch to warm the ActiveTasks hub
      # (the completed fixture is sidebar-visible: pending review) so the
      # post-action invalidate assertion below is non-vacuous.
      wait_hub_warm()

      # No repo_id param → the submitting repo defaults to the active repo
      # ("primary"); the foreign repo merges into its OWN default target.
      render_click(view, "merge", %{"target_branch" => "dev"})

      calls = for _ <- 1..2, do: assert_receive({:merged_call, _node, _path, _branch, _target})

      assert Enum.member?(calls, {:merged_call, node(), primary_dir, "task-branch", "dev"})
      assert Enum.member?(calls, {:merged_call, node(), foreign_dir, "task-branch", "main"})

      flash = assert_redirect(view, "/projects")
      assert flash["success"] =~ "dev"

      assert TaskRegistry.get_task(task_id).review_status == :merged

      # Full success invalidates the hub snapshot BEFORE navigating away
      # (review_live.ex invalidate_active_tasks/1) — the destination /projects
      # mount must come up COLD and re-fetch instead of seeding the stale
      # pre-merge pending-review snapshot.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "merging from the foreign tab targets the foreign repo's chosen branch", %{
      conn: conn,
      task_id: task_id,
      primary_dir: primary_dir,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn node, repo_path, branch, target ->
        send(test_pid, {:merged_call, node, repo_path, branch, target})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Explicit repo_id: the foreign repo submits with the form target "dev"
      # (validated against ITS merge_targets); the primary merges into its own
      # default "main".
      render_click(view, "merge", %{"repo_id" => "original", "target_branch" => "dev"})

      calls = for _ <- 1..2, do: assert_receive({:merged_call, _node, _path, _branch, _target})

      assert Enum.member?(calls, {:merged_call, node(), primary_dir, "task-branch", "main"})
      assert Enum.member?(calls, {:merged_call, node(), foreign_dir, "task-branch", "dev"})

      assert_redirect(view, "/projects")
      assert TaskRegistry.get_task(task_id).review_status == :merged
    end
  end

  describe "multi-repo review — merge partial failure" do
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "reports per-repo outcomes and stays when one repo conflicts", %{
      conn: conn,
      task_id: task_id,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn node, repo_path, branch, target ->
        send(test_pid, {:merged_call, node, repo_path, branch, target})

        if repo_path == foreign_dir do
          {:conflict, ["foreign_conflict.txt"]}
        else
          {:ok, "deadbeef"}
        end
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Wait for the hub snapshot, then capture it: the partial-failure branch
      # must NOT invalidate (the page stays mounted), so the snapshot has to
      # survive the click byte-for-byte.
      wait_hub_warm()
      assert {:ok, {_running, _pending}} = pre_hub = EvoDash.ActiveTasks.get(nil, node())

      html = render_click(view, "merge", %{"target_branch" => "dev"})

      # The per-repo outcome panel renders a merged row for the primary and a
      # conflict row for the foreign repo — partial-success visibility.
      assert html =~ "Merge results"
      assert html =~ "Merged into dev"
      assert html =~ "Merge conflict"
      assert html =~ "foreign_conflict.txt"
      assert html =~ "Merge failed in 1 of 2 repositories. See the merge results below."
      refute_redirected(view)

      outcomes = assigns(view)[:merge_outcomes]
      assert length(outcomes) == 2

      primary_outcome = Enum.find(outcomes, &(&1.repo_id == "primary"))
      assert primary_outcome.status == :merged
      assert primary_outcome.target == "dev"

      foreign_outcome = Enum.find(outcomes, &(&1.repo_id == "original"))
      assert foreign_outcome.status == :conflict
      assert foreign_outcome.target == "main"
      assert foreign_outcome.detail == ["foreign_conflict.txt"]

      # Partial failure stays on the page — no invalidate ran, so the hub
      # snapshot is unchanged (the task is still pending review in the
      # sidebar's pending partition).
      assert EvoDash.ActiveTasks.get(nil, node()) == pre_hub
    end
  end

  describe "multi-repo review — reject broadcast" do
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "rejects (deletes) the agent branch in every review repo on full success", %{
      conn: conn,
      task_id: task_id,
      primary_dir: primary_dir,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :review_reject_runner, fn node, repo_path, branch ->
        send(test_pid, {:reject_call, node, repo_path, branch})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_reject_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Wait for the hub snapshot so the post-action invalidate assertion is
      # non-vacuous (same mechanism as the merge full-success test).
      wait_hub_warm()

      render_click(view, "reject")

      calls = for _ <- 1..2, do: assert_receive({:reject_call, _node, _path, _branch})

      assert Enum.member?(calls, {:reject_call, node(), primary_dir, "task-branch"})
      assert Enum.member?(calls, {:reject_call, node(), foreign_dir, "task-branch"})

      flash = assert_redirect(view, "/projects")

      assert flash["info"] =~
               "Changes rejected. Branch task-branch, task-branch has been deleted."

      assert TaskRegistry.get_task(task_id).review_status == :rejected

      # Full success invalidates the hub snapshot BEFORE navigating away — the
      # destination /projects mount must come up COLD and re-fetch.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "reports per-repo outcomes and stays when one repo fails to reject", %{
      conn: conn,
      task_id: task_id,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :review_reject_runner, fn node, repo_path, branch ->
        send(test_pid, {:reject_call, node, repo_path, branch})

        if repo_path == foreign_dir do
          {:error, "reject failed"}
        else
          :ok
        end
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_reject_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Wait for the hub snapshot, then capture it: the partial-failure branch
      # must NOT invalidate (the page stays mounted).
      wait_hub_warm()
      assert {:ok, {_running, _pending}} = pre_hub = EvoDash.ActiveTasks.get(nil, node())

      html = render_click(view, "reject")

      # Any :rejected outcome switches the panel title to "Reject results".
      assert html =~ "Reject results"
      assert html =~ "Rejected — branch deleted"

      assert html =~
               "Failed to reject changes in 1 of 2 repositories. See the merge results below."

      refute_redirected(view)

      outcomes = assigns(view)[:merge_outcomes]
      assert length(outcomes) == 2
      assert Enum.find(outcomes, &(&1.repo_id == "primary")).status == :rejected
      assert Enum.find(outcomes, &(&1.repo_id == "original")).status == :error

      # Reject outcomes carry NO target key (only merge outcomes do).
      refute Enum.any?(outcomes, &Map.has_key?(&1, :target))

      # Partial failure stays on the page — no invalidate ran, so the hub
      # snapshot is unchanged.
      assert EvoDash.ActiveTasks.get(nil, node()) == pre_hub
    end
  end

  describe "multi-repo review — per-repo merge check" do
    # Same deterministic pattern as the single-repo "async merge check" describe:
    # a BLOCKING :merge_check_runner keeps every repo's status at :checking until
    # the LiveView dies at test end, so injected 6-tuple results cannot race an
    # auto-generated message.
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      Application.put_env(:evo_dash, :merge_check_runner, fn _node, _repo, _branch, _target ->
        receive do
          :release_merge_check -> {:ok, :clean}
        end
      end)

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "applies per-repo results and drops unknown-repo / wrong-task / wrong-node results", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # One async check per review repo, each against its own default target
      # ("main" — the first default-candidate branch in both repos).
      repos = assigns(view)[:review_repos]
      assert Enum.all?(repos, &(&1.merge_status.state == :checking))
      assert Enum.all?(repos, &(&1.merge_status.target == "main"))

      # Clean result for the primary, conflict for the foreign repo.
      send(view.pid, {:merge_check_result, task_id, node(), "primary", "main", {:ok, :clean}})

      send(
        view.pid,
        {:merge_check_result, task_id, node(), "original", "main",
         {:ok, {:conflict, ["foreign.txt"]}}}
      )

      # Results for a repo id absent from @review_repos ("ghost"), a wrong
      # task id, and a wrong node are all DROPPED by the stale-guards.
      send(view.pid, {:merge_check_result, task_id, node(), "ghost", "main", {:ok, :clean}})

      send(
        view.pid,
        {:merge_check_result, "other-task-id", node(), "primary", "main", {:ok, :clean}}
      )

      send(
        view.pid,
        {:merge_check_result, task_id, :some_other_node, "primary", "main", {:ok, :clean}}
      )

      render(view)

      repos = assigns(view)[:review_repos]

      primary = Enum.find(repos, &(&1.repo_id == "primary"))
      assert primary.merge_status == %{state: :clean, target: "main", files: []}

      foreign = Enum.find(repos, &(&1.repo_id == "original"))
      assert foreign.merge_status == %{state: :conflict, target: "main", files: ["foreign.txt"]}

      # While the primary tab is active, the foreign conflict files are not
      # rendered (the flat merge status is projected from the ACTIVE repo).
      refute render(view) =~ "foreign.txt"
    end

    test "switching repos shows the foreign repo's merge status and conflict files", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # The per-repo tab bar renders with a switch_repo button per repo.
      assert render(view) =~ ~s(phx-click="switch_repo")

      # Inject a conflict for the foreign repo only.
      send(
        view.pid,
        {:merge_check_result, task_id, node(), "original", "main",
         {:ok, {:conflict, ["foreign.txt"]}}}
      )

      render(view)

      refute render(view) =~ "foreign.txt"

      # Switch to the foreign repo tab.
      html = render_click(view, "switch_repo", %{"repo_id" => "original"})

      assert assigns(view)[:active_repo_id] == "original"

      # The flat merge_status is now projected from the foreign repo: its
      # conflict state and the conflicting file names render.
      assert assigns(view)[:merge_status].state == :conflict
      assert html =~ "foreign.txt"
      assert html =~ "Merge conflict"
    end
  end

  describe "auto merge conflict resolution — foreign repos carried from the previous task" do
    # Same NONEXISTENT-path pattern as the "auto merge conflict resolution"
    # describe: no async check starts on mount (branch_exists false), so the
    # injected conflict result is fully deterministic. The previous task is
    # seeded WITH :foreign_repos + a per-repo `repos` map to prove the review
    # page builds a multi-repo entry list even for auto-resolve.
    setup do
      task_id = "review_test_auto_resolve_multi_#{System.unique_integer([:positive])}"

      task = %TaskInfo{
        id: task_id,
        type: :evolve,
        status: :completed,
        opts: [
          path: "/nonexistent/repo/path",
          objective: "Test objective",
          foreign_repos: [
            %{"id" => "original", "root" => "/nonexistent/foreign/path", "writable" => true}
          ]
        ],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        review_status: nil,
        result:
          {:ok,
           %{
             commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
             branch_name: "task-branch",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil,
             repos: %{
               "primary" => %{
                 "commit_sha" => "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                 "branch_name" => "task-branch"
               },
               "original" => %{
                 "commit_sha" => "cafebabecafebabecafebabecafebabecafebabe",
                 "branch_name" => "task-branch"
               }
             }
           }}
      }

      EvoGit.Store.put_task(EvoGit.Store, task)

      on_exit(fn ->
        TaskRegistry.delete_task(task_id)
        TaskRegistry.list_tasks()
      end)

      {:ok, task_id: task_id}
    end

    test "auto-resolve carries merge opts but NOT foreign_repos (runtime-only carry)", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      send(
        view.pid,
        {:merge_check_result, task_id, node(), "primary", "main",
         {:ok, {:conflict, ["file_a.txt"]}}}
      )

      html = render(view)
      assert html =~ "Auto-resolve conflict"
      assert html =~ "file_a.txt"

      render_click(view, "auto_resolve")

      assert_redirect(view, "/projects")

      assert TaskRegistry.get_task(task_id).review_status == :continued

      new_task =
        Enum.find(TaskRegistry.list_tasks(), &(merge_opt(&1.opts, :merge_from) == task_id))

      assert new_task, "expected a merge-resolution task to be started"

      on_exit(fn ->
        if new_task, do: TaskRegistry.delete_task(new_task.id)
        TaskRegistry.list_tasks()
      end)

      assert new_task.type == :evolve
      assert merge_opt(new_task.opts, :merge_from) == task_id
      assert merge_opt(new_task.opts, :merge_target) == "main"
      assert new_task.opts[:mode] == "simple"
      assert new_task.opts[:path] == "/nonexistent/repo/path"
      assert new_task.opts[:starting_commit] == "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

      # NOTE: the foreign-repo carry through auto-resolve is RUNTIME-only —
      # TaskRegistry persists the original submission opts, and the core
      # `EvoGit.TaskRegistry.MergeContext.apply_merge_context/4` threads
      # :foreign_repos into the spawned executor's RUNTIME opts (not the
      # persisted ones). Covered by core merge_context_test.exs — do NOT
      # assert foreign_repos in the new task's persisted opts (it is not
      # there by design).
      refute Enum.any?(new_task.opts, fn
               {:foreign_repos, _} -> true
               {"foreign_repos", _} -> true
               _ -> false
             end)
    end
  end

  describe "multi-repo review — resume is primary-scoped" do
    setup do
      {primary_dir, foreign_dir, task_id, primary_sha, foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok,
       primary_dir: primary_dir,
       foreign_dir: foreign_dir,
       task_id: task_id,
       primary_sha: primary_sha,
       foreign_sha: foreign_sha}
    end

    test "resume redirects with the primary repo's params", %{
      conn: conn,
      task_id: task_id,
      primary_dir: primary_dir,
      primary_sha: primary_sha
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      render_click(view, "resume")

      # The resume URL carries resume_from/starting_commit/project for the
      # PRIMARY repo. The handler builds the query with Keyword.put/3, which
      # PREPENDS keys — so the actual order is
      # [project:, starting_commit:, resume_from:] (project FIRST). The ~p
      # sigil encodes the query with Plug.Conn.Query, so build the expected
      # URL with the same call and the same key order.
      expected =
        "/projects?" <>
          Plug.Conn.Query.encode(
            project: primary_dir,
            starting_commit: primary_sha,
            resume_from: task_id
          )

      assert_redirect(view, expected)

      assert TaskRegistry.get_task(task_id).review_status == :continued
    end

    test "resume stays primary-scoped even with the foreign tab active", %{
      conn: conn,
      task_id: task_id,
      primary_dir: primary_dir,
      primary_sha: primary_sha
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Switch to the foreign repo tab — resume must NOT pick up the foreign
      # repo's path/commit (PRIMARY-scoped by design).
      render_click(view, "switch_repo", %{"repo_id" => "original"})
      assert assigns(view)[:active_repo_id] == "original"

      render_click(view, "resume")

      # Same key order as the handler's Keyword.put/3-built query (project
      # FIRST — see the sibling test above).
      expected =
        "/projects?" <>
          Plug.Conn.Query.encode(
            project: primary_dir,
            starting_commit: primary_sha,
            resume_from: task_id
          )

      assert_redirect(view, expected)
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

    {change_sha, _primary} = build_repo_with_task_branch!(tmp_dir, primary, secondary)
    task_id = seed_review_task!(tmp_dir, change_sha)

    on_exit(fn ->
      rm_rf_retry(tmp_dir)
    end)

    {tmp_dir, task_id, change_sha}
  end

  # Builds a temp git repo at `tmp_dir` with the given primary branch (plus an
  # optional secondary branch at the base commit), an agent `task-branch` with
  # a change commit on top of the primary branch, checked back out to the
  # primary branch. Returns {change_sha, primary_branch}.
  defp build_repo_with_task_branch!(tmp_dir, primary, secondary) do
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

    {String.trim(change_sha), primary}
  end

  # Multi-repo variant of create_review_task_with_repo!: builds a PRIMARY temp
  # repo AND a writable FOREIGN temp repo ("original"), each with its own
  # task-branch + change commit, and seeds a completed review task whose opts
  # carry the foreign_repos and whose result carries the per-repo `repos` map.
  # Returns {primary_dir, foreign_dir, task_id, primary_sha, foreign_sha}.
  defp create_multi_repo_review_task!(primary, secondary) do
    primary_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_review_multi_primary_" <> to_string(System.unique_integer([:positive]))
      )

    {primary_sha, _} = build_repo_with_task_branch!(primary_dir, primary, secondary)

    foreign_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_review_multi_foreign_" <> to_string(System.unique_integer([:positive]))
      )

    {foreign_sha, _} = build_repo_with_task_branch!(foreign_dir, primary, secondary)

    task_id =
      seed_multi_repo_task!(
        primary_dir,
        primary_sha,
        [
          %{"id" => "original", "root" => foreign_dir, "writable" => true}
        ],
        %{
          "primary" => %{"commit_sha" => primary_sha, "branch_name" => "task-branch"},
          "original" => %{"commit_sha" => foreign_sha, "branch_name" => "task-branch"}
        }
      )

    on_exit(fn ->
      rm_rf_retry(foreign_dir)
    end)

    {primary_dir, foreign_dir, task_id, primary_sha, foreign_sha}
  end

  # Seeds a completed review task with per-repo result data: `foreign_repos`
  # (string-keyed maps — the Store-codec round-trip shape the review page
  # reads) in opts and a top-level `repos` map (string keys) in the result.
  # The `repos` key is NOT in the Store codec's known result fields, so it
  # round-trips as a STRING key — matching what the page actually reads.
  defp seed_multi_repo_task!(repo_path, change_sha, foreign_repos, repos_map) do
    task_id = "review_test_multi_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      opts: [path: repo_path, objective: "Test objective", foreign_repos: foreign_repos],
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
           pr_title: nil,
           repos: repos_map
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

  # Polls the LOCAL EvoDash.ActiveTasks hub key ({nil, node()}) until the
  # connected-mount sidebar fetch has landed and written its snapshot (see
  # LiveHooks.NodeAware.on_mount/4: the fetch fires ONLY when the key is cold —
  # guaranteed by the per-test reset — and runs async on EvoDash.TaskSupervisor).
  # The completed review fixtures (branch + review_status: nil) are
  # sidebar-visible, so the snapshot warms with them in the pending partition
  # shortly after mount. Once warm no further fetch fires (warm suppresses), so
  # the hub is stable until the action under test runs. Fails loudly if it
  # stays cold — the hub-cold/unchanged assertions below would be vacuous.
  defp wait_hub_warm(timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      case EvoDash.ActiveTasks.get(nil, node()) do
        {:ok, _snapshot} ->
          :ok

        :empty ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk(
              "ActiveTasks hub never warmed for {nil, #{inspect(node())}} — the " <>
                "connected-mount sidebar fetch did not write a snapshot; the " <>
                "hub assertions in this test would be vacuous"
            )
          else
            Process.sleep(20)
            wait_loop.(wait_loop)
          end
      end
    end

    wait_loop.(wait_loop)
  end

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
