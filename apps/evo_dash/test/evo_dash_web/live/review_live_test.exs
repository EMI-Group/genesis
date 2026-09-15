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

      # Reset on EXIT as well as on entry. Every page mount asynchronously
      # writes a sidebar snapshot into this global hub; the start-of-test reset
      # above only protects THIS module's tests, so the LAST test's snapshot
      # (e.g. the sidebar-visible review fixtures) would survive into a later
      # suite that mounts pages without resetting the hub (PageControllerTest
      # does a dead render through Layouts.app and reads the hub). Clear it so
      # this module never leaks hub state into a sibling suite.
      EvoDash.ActiveTasks.reset()
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

      # The page mounts without crashing and still shows the always-available
      # Ignore action, just like a completed task.
      assert html =~ ~s(phx-click="ignore")
      assert html =~ "Ignore"

      # The branch no longer exists, so the primary repo card is seeded into the
      # terminal :handled resolution: its badge reads "Already handled" and the
      # card offers no per-repo merge/reject actions (those live on each repo's
      # own card now, replacing the old shared merge box).
      assert html =~ "Already handled"
      refute html =~ ~s(phx-click="reject")
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

      # Dispatch the PRIMARY repo card's merge form: `repo_id` names the ONE
      # repo the submit acts on (the redesign replaced the shared merge box
      # with one card per repository).
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})

      # A single-repo review is complete once its only repo resolves: merging
      # no longer navigates — the success flash carries the chosen target and
      # the aggregate review status is persisted.
      refute_redirected(view)

      flash = assigns(view)[:flash]["success"]

      assert flash =~ "dev",
             "expected the success flash to mention the target branch, got: #{inspect(flash)}"

      assert TaskRegistry.get_task(task_id).review_status == :merged

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
    # describe-level blocking runner holds the status at :checking for the
    # whole test (it only unblocks on its long timeout, far beyond any test
    # here), so no auto-generated result can race a manually injected
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
        after
          # Nothing ever sends :release_merge_check, and the spawned check Task
          # lives on EvoDash.TaskSupervisor (Task.Supervisor.start_child does
          # NOT link it to the LiveView), so an unbounded receive would block
          # that process forever — leaking one per test. The bound is far
          # longer than any test here, so a late result can only ever be sent
          # to the already-dead view's pid.
          30_000 -> {:ok, :clean}
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
      # Inject a primary repo entry whose branch EXISTS (so the per-repo card
      # renders its merge-status block) but with NO merge targets — the async
      # merge check then never spawns, keeping the injected conflict result
      # race-free.
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [])
          |> Map.merge(%{branch_exists: true, merge_targets: [], default_merge_target: nil})
        ])

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
      # branch_exists: true + no merge targets → the card renders its
      # merge-status block and no async check spawns, so the injected clean
      # result is race-free.
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [])
          |> Map.merge(%{branch_exists: true, merge_targets: [], default_merge_target: nil})
        ])

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

    test "resume on a remote review navigates to /projects with project + node (URL-driven landing)",
         %{
           conn: conn
         } do
      # The task does not exist on the (unreachable) remote node, so the real
      # async load fails fast with :nodedown. Inject a VALID load result
      # carrying a primary review-repo entry (branch_exists: false,
      # merge_targets: [] so MergeCheck.maybe_start does NOT spawn an async
      # check — fully deterministic), then click Continue task: the resume
      # handler must still navigate to /projects with the project/commit/resume
      # query params PLUS a manual `&node=` suffix (URL-driven landing whose
      # activation is covered by projects_live_test).
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
                repo_path: "/remote/repo/path",
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
            can_resume: true,
            active_repo_id: "primary",
            loading: false,
            error: nil
          }}}
      )

      render(view)

      # The resume handler builds the query with Keyword.put/3 (project FIRST —
      # same key order as the local multi-repo resume tests) and appends the
      # manual `&node=` suffix because current_node_id is non-nil.
      render_click(view, "resume")

      expected =
        "/projects?" <>
          Plug.Conn.Query.encode(
            project: "/remote/repo/path",
            starting_commit: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            resume_from: "some-remote-task-id"
          ) <>
          "&node=" <> id

      assert_redirect(view, expected)
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

      # `assigns/1` is a `:sys.get_state` round-trip, so the broadcast sent
      # above has already been processed: the 300ms trailing-edge debounce is
      # scheduled (pending true). Poll for it to fire and the sidebar reload to
      # run — otherwise the unchanged generation assertion below would be
      # vacuous.
      assert assigns(view)[:tasks_reload_pending] == true
      wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)

      # No new load was started: the broadcast-guard skipped the reload for
      # a non-reviewed task.
      assert assigns(view)[:load_generation] == gen_before

      # A stale result from the old generation is still dropped. The
      # `assigns/1` read in the assertion below is itself the synchronization
      # (FIFO mailbox: the send is processed before the :sys.get_state request).
      send(
        view.pid,
        {:review_data_loaded, task_id, node(), gen_before - 1, {:ok, %{title: "INJECTED"}}}
      )

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
      # page reload. The generation is bumped only once the 300ms debounce has
      # fired and start_async_load ran, so polling for it is the event-driven
      # wait (no fixed pre-sleep).
      send(view.pid, {:task_updated, task_id, :finalizing, node()})

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

      # No debounce was ever scheduled and no review-data load was started.
      # `assigns/1` (:sys.get_state) is the synchronization: FIFO mailbox means
      # the send was already processed (and dropped) before this read.
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

      # The broadcast has been processed (assigns/1 syncs): the 300ms
      # trailing-edge debounce is scheduled. Poll for the sidebar reload to
      # run — otherwise the unchanged generation assertion below would be
      # vacuous.
      assert assigns(view)[:tasks_reload_pending] == true
      wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)

      # No new load was started: deleted tasks are never stashed.
      assert assigns(view)[:load_generation] == gen_before

      # The page still renders normally.
      html = render(view)
      assert html =~ "Test objective"
      assert html =~ ~s(phx-click="ignore")
    end
  end

  describe "objective tab" do
    # The objective moved OFF the conversation pane onto its own dedicated
    # "Objective" tab (always rendered, no count badge). The card mirrors
    # agent_summary's header contract: a Markdown/Raw join toggle
    # (toggle_objective_view) + a ClipboardCopy button.
    setup do
      task_id = seed_orphaned_review_task!()
      {:ok, task_id: task_id}
    end

    test "objective tab button exists and switching renders the objective pane", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      # The tab button is always present (no count badge on it).
      assert has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='objective']")
      assert html =~ "Objective"

      # Switching to it renders the objective card with the objective text.
      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='objective']")
        |> render_click()

      assert assigns(view)[:review_tab] == :objective
      assert html =~ "Test objective"
      assert html =~ ~s(id="objective-copy-btn")
    end

    test "objective pane has the markdown/raw toggle and the copy button", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='objective']")
      |> render_click()

      # The copy button carries the ClipboardCopy hook + the objective payload.
      assert has_element?(view, "button[id='objective-copy-btn'][phx-hook='ClipboardCopy']")

      # Markdown is the default view; raw renders the single-line <pre>.
      assert has_element?(
               view,
               "button[phx-click='toggle_objective_view'][phx-value-mode='raw']"
             )

      html =
        view
        |> element("button[phx-click='toggle_objective_view'][phx-value-mode='raw']")
        |> render_click()

      assert assigns(view)[:objective_raw] == true
      assert html =~ "<pre"

      # Toggling back to markdown restores the rendered content container.
      html =
        view
        |> element("button[phx-click='toggle_objective_view'][phx-value-mode='markdown']")
        |> render_click()

      assert assigns(view)[:objective_raw] == false
      assert html =~ "md-content"
    end

    test "objective card is no longer rendered inside the conversation pane", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      # The conversation tab (the default) has the agent report but NOT the
      # objective card — the copy button id is unique to the objective card.
      assert html =~ ~s(id="summary-copy-btn")
      refute html =~ ~s(id="objective-copy-btn")

      # Sanity: the objective pane DOES render it (the button lives there).
      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='objective']")
        |> render_click()

      assert html =~ ~s(id="objective-copy-btn")
    end

    test "nil objective renders the in-card empty state", %{conn: conn} do
      # A task with neither opts prompt nor objective → objective assign is "".
      task_id = seed_review_task_no_objective!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      assert assigns(view)[:objective] == ""

      html =
        view
        |> element("button[phx-click='switch_tab'][phx-value-tab='objective']")
        |> render_click()

      # The empty-state card renders; no toggle/copy controls (nil-safe hide).
      assert html =~ "No objective recorded for this task."
      refute html =~ ~s(id="objective-copy-btn")
      refute html =~ ~s(phx-click="toggle_objective_view")
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

      # Repo selection is GATED in the redesign: the merge box renders its
      # <select phx-change="switch_repo"> only when the branch exists, and the
      # Files-changed toolbar only alongside diff data. This orphaned fixture
      # (nonexistent paths) opens NEITHER gate — switching to the Files-changed
      # tab shows the empty-state panel and no selector. The positive
      # multi-repo selector render is pinned in the per-repo merge-check
      # describe below (real-repo fixture, branch_exists true).
      html = render_click(view, "switch_tab", %{"tab" => "files_changed"})
      assert html =~ "No diff data available for this review."
      refute html =~ ~s(phx-change="switch_repo")
    end

    test "legacy tasks without a repos key yield exactly one primary entry", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      repos = assigns(view)[:review_repos]

      assert length(repos) == 1
      assert hd(repos).repo_id == "primary"

      # Single-repo pages render NO repo selector (pixel-identical to before).
      refute render(view) =~ ~s(phx-change="switch_repo")
    end
  end

  describe "multi-repo review — per-repo merge scoping" do
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

    test "merges each review repo into its own target and marks the task merged", %{
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

      # The PRIMARY card's form submits for the primary repo ONLY — the runner
      # runs exactly once, for that repo's path/branch/target, never a fan-out.
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})

      assert_receive {:merged_call, call_node, call_path, "task-branch", "dev"}
      assert call_node == node()
      assert call_path == primary_dir
      refute_receive {:merged_call, _, _, _, _}, 100

      # One repo resolved, the other pending — the page STAYS (no navigation).
      refute_redirected(view)

      repos = assigns(view)[:review_repos]
      primary = Enum.find(repos, &(&1.repo_id == "primary"))
      foreign = Enum.find(repos, &(&1.repo_id == "original"))

      assert primary.resolution == %{state: :merged, target: "dev"}
      assert primary.branch_exists == false
      assert foreign.resolution == nil
      assert foreign.branch_exists == true

      # Resolving the LAST repo completes the review: the aggregate status is
      # persisted, the completion banner renders, the hub snapshot is
      # invalidated — and the page STILL does not navigate.
      html = render_click(view, "merge", %{"repo_id" => "original", "target_branch" => "dev"})

      assert_receive {:merged_call, call_node, call_path, "task-branch", "dev"}
      assert call_node == node()
      assert call_path == foreign_dir
      refute_receive {:merged_call, _, _, _, _}, 100

      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == :merged

      assert html =~ "All repositories merged."
      assert html =~ ~s(id="review-completion-banner")
      assert html =~ ~s(id="review-completion-back")
      assert assigns(view)[:flash]["success"] =~ "dev"

      # Completion invalidates the hub snapshot (review_live.ex
      # invalidate_active_tasks/1) so a later /projects mount comes up COLD.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "merging from the foreign card targets the foreign repo's chosen branch", %{
      conn: conn,
      task_id: task_id,
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
      # (validated against ITS merge_targets); the primary is untouched.
      render_click(view, "merge", %{"repo_id" => "original", "target_branch" => "dev"})

      assert_receive {:merged_call, call_node, call_path, "task-branch", "dev"}
      assert call_node == node()
      assert call_path == foreign_dir
      refute_receive {:merged_call, _, _, _, _}, 100

      refute_redirected(view)

      repos = assigns(view)[:review_repos]
      primary = Enum.find(repos, &(&1.repo_id == "primary"))
      foreign = Enum.find(repos, &(&1.repo_id == "original"))

      assert foreign.resolution == %{state: :merged, target: "dev"}
      assert foreign.branch_exists == false
      assert primary.resolution == nil
      assert primary.branch_exists == true

      # Still one repo pending → the review is not complete yet.
      assert TaskRegistry.get_task(task_id).review_status == nil
    end
  end

  describe "multi-repo review — merge partial failure" do
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "reports the conflict on the conflicting repo's card and stays", %{
      conn: conn,
      task_id: task_id,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn node, repo_path, branch, target ->
        send(test_pid, {:merged_call, node, repo_path, branch, target})

        if repo_path == foreign_dir do
          # A real merge returns raw git output (a STRING) as the conflict
          # detail — truncate_string/2 requires a binary.
          {:conflict, "CONFLICT (content): merge conflict in foreign_conflict.txt"}
        else
          {:ok, "deadbeef"}
        end
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Wait for the hub snapshot, then capture it: the partial-failure branch
      # must NOT invalidate (the page stays mounted), so the snapshot has to
      # survive the clicks byte-for-byte.
      wait_hub_warm()
      assert {:ok, {_running, _pending}} = pre_hub = EvoDash.ActiveTasks.get(nil, node())

      # Resolve the primary (ok), then the foreign repo (conflict) — one repo
      # per click, no fan-out.
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})
      html = render_click(view, "merge", %{"repo_id" => "original", "target_branch" => "dev"})

      # Each repo card carries its OWN outcome: the primary merged, the foreign
      # repo conflicted with the detail rendered on its card.
      primary_card = repo_card_html(html, "primary")
      foreign_card = repo_card_html(html, "original")

      assert primary_card =~ "Merged into dev"
      assert foreign_card =~ "Merge conflict"
      assert foreign_card =~ "foreign_conflict.txt"

      assert assigns(view)[:flash]["error"] =~ "Merge conflict in task-branch"

      # The old fan-out results panel is gone, and the page STAYS.
      refute html =~ "Merge results"
      refute_redirected(view)

      # The primary resolved but the foreign repo did not → the review is NOT
      # complete: no status persisted, hub snapshot unchanged (the task is
      # still pending review in the sidebar's pending partition).
      assert TaskRegistry.get_task(task_id).review_status == nil
      assert EvoDash.ActiveTasks.get(nil, node()) == pre_hub
    end
  end

  describe "multi-repo review — per-repo reject scoping" do
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "rejects each repo's branch and marks the task rejected once all resolve", %{
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
      # non-vacuous (same mechanism as the merge completion test).
      wait_hub_warm()

      # One repo per click — the runner runs exactly once for that repo, never
      # a fan-out.
      render_click(view, "reject", %{"repo_id" => "primary"})

      assert_receive {:reject_call, call_node, call_path, "task-branch"}
      assert call_node == node()
      assert call_path == primary_dir
      refute_receive {:reject_call, _, _, _}, 100

      # One repo rejected, the other pending — the page STAYS.
      refute_redirected(view)

      html = render_click(view, "reject", %{"repo_id" => "original"})

      assert_receive {:reject_call, call_node, call_path, "task-branch"}
      assert call_node == node()
      assert call_path == foreign_dir
      refute_receive {:reject_call, _, _, _}, 100

      # All repos rejected → review complete: persisted, completion banner,
      # hub invalidated — and STILL no navigation.
      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == :rejected
      assert html =~ "All repositories rejected."
      assert html =~ ~s(id="review-completion-banner")
      assert assigns(view)[:flash]["success"] =~ "Changes rejected"
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "reports the failure on the failing repo's card and stays", %{
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

      render_click(view, "reject", %{"repo_id" => "primary"})
      html = render_click(view, "reject", %{"repo_id" => "original"})

      # Each repo card carries its OWN outcome: the primary rejected, the
      # foreign repo's failure rendered on its card.
      primary_card = repo_card_html(html, "primary")
      foreign_card = repo_card_html(html, "original")

      assert primary_card =~ "Rejected"
      assert foreign_card =~ "Merge failed"
      assert foreign_card =~ "reject failed"

      assert assigns(view)[:flash]["error"] =~ "Failed to reject changes"

      # The old fan-out results panel is gone, and the page STAYS.
      refute html =~ "Reject results"
      refute_redirected(view)

      # The primary rejected but the foreign repo did not → the review is NOT
      # complete and the hub snapshot is unchanged.
      assert TaskRegistry.get_task(task_id).review_status == nil
      assert EvoDash.ActiveTasks.get(nil, node()) == pre_hub
    end
  end

  describe "multi-repo review — per-repo merge check" do
    # Same deterministic pattern as the single-repo "async merge check" describe:
    # a BLOCKING :merge_check_runner holds every repo's status at :checking for
    # the whole test (it only unblocks on its long timeout, far beyond any test
    # here), so injected 6-tuple results cannot race an auto-generated message.
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      Application.put_env(:evo_dash, :merge_check_runner, fn _node, _repo, _branch, _target ->
        receive do
          :release_merge_check -> {:ok, :clean}
        after
          # Nothing ever sends :release_merge_check, and the spawned check Task
          # lives on EvoDash.TaskSupervisor (Task.Supervisor.start_child does
          # NOT link it to the LiveView), so an unbounded receive would block
          # that process forever — leaking one per test. The bound is far
          # longer than any test here, so a late result can only ever be sent
          # to the already-dead view's pid.
          30_000 -> {:ok, :clean}
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

      # Each repo card renders its OWN async merge-check status (the redesign
      # moved merge status off the single active-repo projection onto the
      # per-repo cards): the primary card is clean, the foreign card carries
      # the conflict + file.
      html = render(view)

      assert repo_card_html(html, "primary") =~ "Merge check passed"
      refute repo_card_html(html, "primary") =~ "foreign.txt"
      assert repo_card_html(html, "original") =~ "foreign.txt"
      assert repo_card_html(html, "original") =~ "Merge conflict"
    end

    test "each repo card renders its own merge status and conflict files", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Resolve the primary's check clean, inject a conflict for the foreign
      # repo only.
      send(view.pid, {:merge_check_result, task_id, node(), "primary", "main", {:ok, :clean}})

      send(
        view.pid,
        {:merge_check_result, task_id, node(), "original", "main",
         {:ok, {:conflict, ["foreign.txt"]}}}
      )

      html = render(view)

      # The per-repo cards render each repo's status independently: the primary
      # stays clean, the foreign card shows the conflict file.
      assert repo_card_html(html, "primary") =~ "Merge check passed"
      refute repo_card_html(html, "primary") =~ "foreign.txt"
      assert repo_card_html(html, "original") =~ "foreign.txt"
      assert repo_card_html(html, "original") =~ "Merge conflict"

      # The repo switcher itself now lives in the Files-changed / Commits tab
      # toolbars, each inside its own <form phx-change="switch_repo">.
      files_html = open_files_tab(view)
      assert files_html =~ ~s(id="diff-repo-switch-form")

      assert repo_select_state(files_html) == %{
               values: ["primary", "original"],
               selected: ["primary"]
             }

      commits_html = open_commits_tab(view)
      assert commits_html =~ ~s(id="commits-repo-switch-form")

      # switch_repo updates the active repo and re-projects the flat
      # merge_status from it.
      render_change(view, "switch_repo", %{"repo_id" => "original"})

      assert assigns(view)[:active_repo_id] == "original"
      assert assigns(view)[:merge_status].state == :conflict

      # Back on the conversation tab the flat projection is foreign-scoped.
      html = render_click(view, "switch_tab", %{"tab" => "conversation"})
      assert html =~ "foreign.txt"
      assert html =~ "Merge conflict"
    end
  end

  describe "multi-repo review — repo selector presence and switch semantics" do
    # Pins the repo-selector fix: every repo <select name="repo_id"
    # phx-change="switch_repo"> (the Files-changed toolbar and the Commits
    # tab) is wrapped in its own <form phx-change="switch_repo"> so the event
    # actually reaches ReviewLive.handle_event — a form-less input-level
    # phx-change throws in phoenix_live_view's JS ("form events require the
    # input to be inside a form"). These LiveView-level tests pin the
    # server-side gating + handling: selector presence per tab, the
    # %{"value" => repo_id} legacy form-less shape, and the @commits
    # projection tracking active_repo_id.
    setup do
      task_id = seed_orphaned_review_task!()
      {:ok, task_id: task_id}
    end

    test "multi-repo reviews render a repo selector on BOTH the Files-changed and Commits tabs",
         %{
           conn: conn,
           task_id: task_id
         } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)], [
            commit_info("a", "Primary only commit")
          ]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)], [
            commit_info("c", "Foreign only commit")
          ])
        ])

      # Files-changed tab: split_diff_layout renders its repo-selector toolbar
      # (a <select name="repo_id"> inside <form phx-change="switch_repo">)
      # whenever more than one review repo exists — one option per repo, the
      # active repo's option preselected.
      html = open_files_tab(view)
      assert repo_select_state(html) == %{values: ["primary", "original"], selected: ["primary"]}

      # Commits tab: commits_list renders the SAME gated selector above the
      # commit card — the new multi-repo affordance on this tab.
      html = open_commits_tab(view)
      assert repo_select_state(html) == %{values: ["primary", "original"], selected: ["primary"]}
    end

    test "single-repo reviews render no repo selector on either tab even with diff/commit data",
         %{
           conn: conn,
           task_id: task_id
         } do
      # Data present (files + commits) so the length gate is the ONLY thing
      # suppressing the toolbar — 1 review repo → no selector anywhere.
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)], [
            commit_info("a", "Primary only commit")
          ])
        ])

      html = open_files_tab(view)
      assert repo_select_state(html) == %{values: [], selected: []}
      refute html =~ ~s(phx-change="switch_repo")

      html = open_commits_tab(view)
      assert repo_select_state(html) == %{values: [], selected: []}
      refute html =~ ~s(phx-change="switch_repo")
    end

    test "legacy tasks (no repos key) render no repo selector on either tab", %{
      conn: conn,
      task_id: task_id
    } do
      # The orphaned-path task is a legacy single-repo review (no `repos`
      # key in its result → exactly one primary review repo) — the commits
      # tab must stay selector-free too, not just the Files-changed toolbar.
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      assert length(assigns(view)[:review_repos]) == 1

      html = open_commits_tab(view)
      assert repo_select_state(html) == %{values: [], selected: []}
      refute html =~ ~s(phx-change="switch_repo")

      html = open_files_tab(view)
      assert html =~ "No diff data available for this review."
      assert repo_select_state(html) == %{values: [], selected: []}
      refute html =~ ~s(phx-change="switch_repo")
    end

    test "switch_repo with the form-less %{\"value\" => repo_id} shape switches repos and resets the file filter",
         %{
           conn: conn,
           task_id: task_id
         } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)], [
            commit_info("a", "Primary only commit")
          ]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)], [
            commit_info("c", "Foreign only commit")
          ])
        ])

      open_files_tab(view)

      # Set a non-empty filter, then switch via the legacy shape.
      render_change(view, "filter_files", %{"filter" => "one"})
      assert assigns(view)[:file_filter] == "one"
      assert assigns(view)[:active_repo_id] == "primary"

      html = render_change(view, "switch_repo", %{"value" => "original"})

      # Same semantics as the %{"repo_id" => ...} form shape: active id
      # updated, file filter reset, and the flat projections re-pointed at
      # the newly active repo.
      assert assigns(view)[:active_repo_id] == "original"
      assert assigns(view)[:file_filter] == ""
      assert Enum.map(assigns(view)[:review_data].files, & &1.path) == ["src/two.rs"]
      assert Enum.map(assigns(view)[:commits], & &1.message) == ["Foreign only commit"]

      # The rendered selector reflects the new active repo.
      assert repo_select_state(html) == %{values: ["primary", "original"], selected: ["original"]}
    end

    test "switch_repo with an unknown repo id in the %{\"value\" => ...} shape is a harmless no-op",
         %{
           conn: conn,
           task_id: task_id
         } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)])
        ])

      assert assigns(view)[:active_repo_id] == "primary"

      # The Files-changed tab is where the toolbar <select> renders with the
      # branch_exists: false fixture (the merge box gates on branch_exists).
      open_files_tab(view)

      # "ghost" is not whitelisted against review_repos — the handler returns
      # the socket unchanged (no crash, no state mutation).
      html = render_change(view, "switch_repo", %{"value" => "ghost"})

      assert assigns(view)[:active_repo_id] == "primary"
      assert Enum.map(assigns(view)[:review_data].files, & &1.path) == ["lib/one.ex"]
      assert repo_select_state(html) == %{values: ["primary", "original"], selected: ["primary"]}
    end

    test "commits tab lists the ACTIVE repo's commits after switching via both shapes", %{
      conn: conn,
      task_id: task_id
    } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)], [
            commit_info("a", "Primary only commit")
          ]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)], [
            commit_info("c", "Foreign only commit")
          ])
        ])

      # Default active repo (primary): its commit is the one listed.
      html = open_commits_tab(view)
      assert html =~ "Primary only commit"
      refute html =~ "Foreign only commit"
      assert Enum.map(assigns(view)[:commits], & &1.message) == ["Primary only commit"]

      # Form-wrapped %{"repo_id"} shape → the foreign repo's commit replaces it.
      html = render_change(view, "switch_repo", %{"repo_id" => "original"})
      assert html =~ "Foreign only commit"
      refute html =~ "Primary only commit"
      assert Enum.map(assigns(view)[:commits], & &1.message) == ["Foreign only commit"]

      # Legacy %{"value"} shape → back to the primary repo's commit.
      html = render_change(view, "switch_repo", %{"value" => "primary"})
      assert html =~ "Primary only commit"
      refute html =~ "Foreign only commit"
      assert Enum.map(assigns(view)[:commits], & &1.message) == ["Primary only commit"]
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

      # The load builds a multi-repo entry list from the previous task's
      # foreign_repos + per-repo `repos` map (both entry branches are gone).
      repos = assigns(view)[:review_repos]
      assert Enum.map(repos, & &1.repo_id) == ["primary", "original"]

      # Enable the primary's per-repo conflict affordances: branch_exists true
      # (so the card renders its merge-status block) with NO merge targets (so
      # no async check spawns — the injected conflict result is race-free).
      gen = assigns(view)[:load_generation]

      modded =
        Enum.map(repos, fn repo ->
          if repo.repo_id == "primary" do
            Map.merge(repo, %{
              branch_exists: true,
              merge_targets: [],
              default_merge_target: nil,
              # The load seeds :handled for the nonexistent fixture branches;
              # clear it so the card renders its merge-status block instead of
              # the terminal presentation.
              resolution: nil
            })
          else
            repo
          end
        end)

      send(
        view.pid,
        {:review_data_loaded, task_id, node(), gen,
         {:ok, %{review_repos: modded, active_repo_id: "primary", loading: false, error: nil}}}
      )

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

      # Switch to the foreign repo via the selector — resume must NOT pick up
      # the foreign repo's path/commit (PRIMARY-scoped by design).
      render_change(view, "switch_repo", %{"repo_id" => "original"})
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

  describe "files-changed tree and filter" do
    # LiveView-level wiring for the redesigned Files-changed tab: the
    # server-driven file tree (dirs collapsed by default; toggle_dir /
    # collapse_all_dirs / expand_all_dirs) and the flat filter mode
    # (filter_files, switch_repo resetting it). Component-internal markup
    # (tree_node rendering, aggregate dir stats) is covered by
    # diff_viewer_test.exs — these tests assert the EVENT wiring only.
    # select_file / toggle_dir buttons exist ONLY inside the sidebar (the
    # diff column's own phx-value-path buttons fire toggle_file_expansion),
    # so the unscoped selectors below are inherently sidebar-scoped.
    #
    # Fixture: the orphaned-path task (repo_path points nowhere) + a
    # generation-current injection of a full review-data assigns map. The
    # injected repos use branch_exists: false and merge_targets: [] so
    # MergeCheck.maybe_start never spawns (fully deterministic), and the
    # file paths deliberately live under directories ("lib/foo/bar.ex") —
    # the deep file is hidden until its dir chain is expanded.
    setup do
      task_id = seed_orphaned_review_task!()
      {:ok, task_id: task_id}
    end

    test "deep files are hidden until their directory chain is expanded", %{
      conn: conn,
      task_id: task_id
    } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [
            file_info("lib/foo/bar.ex", 10, 4),
            file_info("README.md")
          ])
        ])

      open_files_tab(view)

      deep_file = "button[phx-click='select_file'][phx-value-path='lib/foo/bar.ex']"

      # Collapsed by default: the root-level file is visible, the deep file
      # is hidden, and the root dir's toggle carries the FULL dir path.
      assert has_element?(view, "button[phx-click='select_file'][phx-value-path='README.md']")
      refute has_element?(view, deep_file)
      assert has_element?(view, "button[phx-click='toggle_dir'][phx-value-dir='lib']")

      # Expanding "lib" reveals the nested "lib/foo" dir row — but the file
      # under it stays hidden (nested dirs stay collapsed).
      render_click(view, "toggle_dir", %{"dir" => "lib"})

      assert has_element?(view, "button[phx-click='toggle_dir'][phx-value-dir='lib/foo']")
      refute has_element?(view, deep_file)

      # Expanding the nested dir reveals the file row.
      render_click(view, "toggle_dir", %{"dir" => "lib/foo"})
      assert has_element?(view, deep_file)

      # Toggling the nested dir again collapses it (delete path). The
      # expansion state is repo-keyed on the show route.
      render_click(view, "toggle_dir", %{"dir" => "lib/foo"})

      refute has_element?(view, deep_file)
      assert assigns(view)[:tree_expanded_dirs] == %{"primary" => %{"lib" => true}}
    end

    test "expand_all_dirs / collapse_all_dirs open and close the whole tree", %{
      conn: conn,
      task_id: task_id
    } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/foo/bar.ex", 10, 4)])
        ])

      open_files_tab(view)

      deep_file = "button[phx-click='select_file'][phx-value-path='lib/foo/bar.ex']"
      refute has_element?(view, deep_file)

      # Expand all marks every ancestor dir chain segment of every file true.
      render_click(view, "expand_all_dirs")

      assert has_element?(view, deep_file)
      assert assigns(view)[:tree_expanded_dirs]["primary"] == %{"lib" => true, "lib/foo" => true}

      # Collapse all empties the active repo's submap.
      render_click(view, "collapse_all_dirs")

      refute has_element?(view, deep_file)
      assert assigns(view)[:tree_expanded_dirs] == %{"primary" => %{}}
    end

    test "filter_files switches to the flat list and back to the tree", %{
      conn: conn,
      task_id: task_id
    } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [
            file_info("lib/foo/bar.ex", 10, 4),
            file_info("README.md")
          ])
        ])

      open_files_tab(view)

      # A matching (case-insensitive) filter renders the flat list: the
      # matching file is directly visible with NO dir toggle buttons.
      render_change(view, "filter_files", %{"filter" => "readme"})

      assert has_element?(view, "button[phx-click='select_file'][phx-value-path='README.md']")
      refute has_element?(view, "button[phx-click='toggle_dir']")
      # The deep file does not match the filter → absent from the flat list.
      refute has_element?(
               view,
               "button[phx-click='select_file'][phx-value-path='lib/foo/bar.ex']"
             )

      # A bogus filter renders the empty state (unique sidebar string).
      html = render_change(view, "filter_files", %{"filter" => "no-such-file"})
      assert html =~ "No matching files"

      # Clearing the filter returns the normal tree (dir toggles back).
      html = render_change(view, "filter_files", %{"filter" => ""})

      assert has_element?(view, "button[phx-click='toggle_dir'][phx-value-dir='lib']")
      refute html =~ "No matching files"
    end

    test "switch_repo resets the file filter", %{conn: conn, task_id: task_id} do
      # Multi-repo fixture so the repo selector renders in the Files-changed
      # toolbar; the foreign repo needs its own files so the reset is
      # observable on the rendered file list.
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/foo/bar.ex", 10, 4)]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/baz.rs", 2, 0)])
        ])

      open_files_tab(view)

      # Set a filter, then switch repos — the filter must reset to "".
      render_change(view, "filter_files", %{"filter" => "lib"})
      assert assigns(view)[:file_filter] == "lib"

      html = render_change(view, "switch_repo", %{"repo_id" => "original"})

      assert assigns(view)[:active_repo_id] == "original"
      assert assigns(view)[:file_filter] == ""

      # The filter input's value attribute reflects the reset.
      [input] =
        html
        |> Floki.parse_document!()
        |> Floki.find("input[name='filter'][phx-change='filter_files']")

      assert Floki.attribute(input, "value") == [""]
    end
  end

  describe "task actions — overflow menu and Continue button" do
    # branch_exists: true (real repo) so the per-repo action row + the full
    # overflow menu render. The merge-check stub is already the fast :clean one
    # from the module setup — with merge_targets present it spawns and resolves
    # immediately, so the page is deterministic.
    setup do
      archive = [
        %{"agent_id" => "agent-1", "parent_id" => nil, "objective" => "Root agent", "depth" => 0}
      ]

      {_repo_path, task_id, _change_sha} = create_review_task_with_repo!("main", nil, archive)

      {:ok, task_id: task_id}
    end

    test "Continue task button fires resume", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      # The secondary Continue button (task-actions row) fires resume —
      # presence + event attr only (the navigation itself is covered by the
      # multi-repo resume describe).
      assert has_element?(view, "button[phx-click='resume']")
      assert html =~ "Continue task"
    end

    test "overflow menu carries the full action set with ignore as a plain always-available item last",
         %{
           conn: conn,
           task_id: task_id
         } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      menu = overflow_menu(html)

      # branch_exists: true entries — Reject is now a per-repo card action, NOT
      # a menu item, so the menu must NOT carry it.
      refute menu =~ ~s(phx-click="reject")
      refute menu =~ "Reject"
      assert menu =~ ~s(phx-click="create_pr")
      assert menu =~ "Create GitHub PR"
      assert menu =~ ~s(phx-click="extract_skills")
      assert menu =~ "Extract Skills"

      # Export JSON renders because the fixture task has archive_metadata —
      # a plain download link to the export URL (local node → no ?node=).
      assert menu =~ ~s(href="/tasks/#{task_id}/export")
      assert menu =~ "Export JSON"

      # Ignore is a plain, always-available menu item rendered LAST — there is
      # no danger-zone divider anymore.
      refute menu =~ "Danger zone"
      assert menu =~ ~s(phx-click="ignore")

      # The full item set, pinned: exactly Create GitHub PR → Extract Skills →
      # Export JSON → Ignore (in that DOM order), with Ignore last.
      assert {create_idx, _} = :binary.match(menu, "Create GitHub PR")
      assert {extract_idx, _} = :binary.match(menu, "Extract Skills")
      assert {export_idx, _} = :binary.match(menu, "Export JSON")
      assert {ignore_idx, _} = :binary.match(menu, ~s(phx-click="ignore"))
      assert create_idx < extract_idx
      assert extract_idx < export_idx
      assert export_idx < ignore_idx

      # Ignore no longer carries the danger red styling (scope to the ignore
      # button element only).
      [ignore_btn] =
        menu
        |> Floki.parse_document!()
        |> Floki.find("button[phx-click='ignore']")

      refute ignore_btn
             |> Floki.attribute("class")
             |> Enum.any?(&String.contains?(&1, "text-error"))
    end

    test "Export JSON is hidden without archive metadata", %{conn: conn} do
      # A second task WITHOUT archive_metadata — the export entry must not
      # render, while Ignore still does (always-available escape hatch).
      {_repo_path, task_id, _change_sha} = create_review_task_with_repo!("main", nil)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      menu = overflow_menu(html)

      refute menu =~ "Export JSON"
      assert menu =~ ~s(phx-click="ignore")
    end
  end

  describe "aggregate stats across repos" do
    # aggregate_stats/1 sums files_count/additions/deletions/commits across
    # ALL review repos — the page header's stat row, the page-tabs count
    # badges, and the conversation tab's diff-stats bar read the SUMS, never
    # the active repo alone. Injected multi-repo fixture with DISTINCT
    # per-repo numbers so a primary-only read would fail.
    setup do
      task_id = seed_orphaned_review_task!()
      {:ok, task_id: task_id}
    end

    test "header stats row, diff stats bar, and tab badges show the sums", %{
      conn: conn,
      task_id: task_id
    } do
      # changed_files_count deliberately differs from length(files) per repo,
      # so the assertions prove the COUNT fields (not the file lists) drive
      # the numbers.
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)], [
            commit_info("a", "Primary commit"),
            commit_info("b", "Primary commit 2")
          ])
          |> put_in([:review_data, :changed_files_count], 3),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)], [
            commit_info("c", "Foreign commit")
          ])
          |> put_in([:review_data, :changed_files_count], 2)
        ])

      html = render(view)

      # Expected sums: 3+2=5 files, 30+12=42 additions, 10+5=15 deletions,
      # 2+1=3 commits.
      assert html =~ "5 files changed"
      assert html =~ "3 commits"

      # The conversation tab's diff-stats bar (the unique gap-x-4 stats
      # container on this page) shows the summed additions/deletions — never
      # the primary's alone. A primary-only read ("3 files changed") must
      # not appear anywhere.
      bar_text = stats_bar_text(html)
      assert bar_text =~ "42"
      assert bar_text =~ "15"
      refute html =~ "3 files changed"

      # The page-tabs count badges reflect the same sums.
      assert badge_text(html, "files_changed") == "5"
      assert badge_text(html, "commits") == "3"

      # The sums are ACTIVE-REPO-INDEPENDENT: switching to the foreign repo
      # must not change the badges.
      render_change(view, "switch_repo", %{"repo_id" => "original"})
      assert assigns(view)[:active_repo_id] == "original"
      assert badge_text(render(view), "files_changed") == "5"
    end
  end

  describe "page header title truncation" do
    test "long first-line objective is truncated with an ellipsis, full text in title attr", %{
      conn: conn
    } do
      # 120-char first line → short_title shows the first 100 chars + "…",
      # while the h1's title attribute carries the FULL text.
      first_line = String.duplicate("a", 120)
      second_line = "second line"
      long_objective = first_line <> "\n" <> second_line

      task_id = seed_review_task_with_objective!(long_objective)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      # The page header's h1 (text-lg) is the only h1 on the show page.
      [h1] =
        html
        |> Floki.parse_document!()
        |> Floki.find("h1.text-lg")

      assert Floki.attribute(h1, "title") == [long_objective]

      assert Floki.text(h1) |> String.trim() == String.slice(first_line, 0, 100) <> "…"

      # The truncated display never shows the second line (the tail beyond
      # char 100 is all "a"s, covered by the exact-equality assert above).
      refute Floki.text(h1) =~ second_line
    end
  end

  describe "multi-repo review — overall completion status" do
    # completion_status/2 is PRIVATE — it is driven here through REAL merge /
    # reject event dispatches. Once EVERY repo's resolution is terminal the
    # aggregate status is persisted via NodeContext.set_review_status/3, the
    # completion banner renders, the sidebar hub snapshot is invalidated — and
    # the page NEVER navigates on a settle (only Ignore / resume navigate).
    test "all repos terminal with no merged repo completes as :rejected", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      Application.put_env(:evo_dash, :review_reject_runner, fn _node, _path, _branch -> :ok end)
      on_exit(fn -> Application.delete_env(:evo_dash, :review_reject_runner) end)

      # One actionable repo + one ALREADY-terminal repo whose `:handled`
      # resolution was seeded at load time (a branch that once existed no
      # longer does).
      handled =
        Map.put(review_repo("original", "/nonexistent/foreign/path", []), :resolution, %{
          state: :handled
        })

      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          handled
        ])

      wait_hub_warm()

      html = render_click(view, "reject", %{"repo_id" => "primary"})

      # No merged repo anywhere → the aggregate completes as :rejected.
      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == :rejected
      assert html =~ "All repositories rejected."
      assert html =~ ~s(id="review-completion-banner")
      assert html =~ ~s(id="review-completion-back")
      assert assigns(view)[:flash]["success"] =~ "Changes rejected"

      # Completion invalidates the sidebar hub snapshot.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "a mixed merge + reject completes as :merged (≥1 merged wins)", %{conn: conn} do
      {primary_dir, _foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        {:ok, "deadbeef"}
      end)

      Application.put_env(:evo_dash, :review_reject_runner, fn _n, _p, _b -> :ok end)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :review_merge_runner)
        Application.delete_env(:evo_dash, :review_reject_runner)
      end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)
      wait_hub_warm()

      # Merge the primary (one merged entry), then reject the foreign repo:
      # every repo is terminal, and the ≥1-merged rule beats all-rejected.
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})
      html = render_click(view, "reject", %{"repo_id" => "original"})

      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == :merged
      assert html =~ "All repositories merged."
      assert html =~ ~s(id="review-completion-banner")
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "a persisted review status wins over a later computed value", %{conn: conn} do
      {primary_dir, _foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      # Pre-seed the persisted aggregate as :merged (as a prior visit would
      # have), then run a REJECT-ONLY resolution: every repo ends :rejected,
      # but reload coherence keeps the already-persisted :merged.
      TaskRegistry.set_review_status(task_id, :merged)
      # Synchronize the cast.
      TaskRegistry.list_tasks()

      Application.put_env(:evo_dash, :review_reject_runner, fn _n, _p, _b -> :ok end)
      on_exit(fn -> Application.delete_env(:evo_dash, :review_reject_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      assert assigns(view)[:review_status] == :merged

      render_click(view, "reject", %{"repo_id" => "primary"})
      html = render_click(view, "reject", %{"repo_id" => "original"})

      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == :merged
      assert html =~ "All repositories merged."
      refute html =~ "All repositories rejected."
    end

    test "does not complete while one repo stays unresolved", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          review_repo("original", "/nonexistent/foreign/path", [])
        ])

      html = render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "main"})

      # The primary resolved, the foreign repo is still `resolution: nil` — NOT
      # all terminal, so no aggregate status is written and no banner renders.
      refute_redirected(view)
      refute html =~ ~s(id="review-completion-banner")
      assert TaskRegistry.get_task(task_id).review_status == nil
    end

    test "a non-terminal :conflict entry keeps the review open", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      # :conflict / :error look "resolved" but are NOT terminal — neither counts
      # toward completion nor triggers the aggregate write.
      conflict =
        Map.put(review_repo("original", "/nonexistent/foreign/path", []), :resolution, %{
          state: :conflict,
          detail: "boom"
        })

      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          conflict
        ])

      html = render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "main"})

      refute_redirected(view)
      refute html =~ ~s(id="review-completion-banner")
      assert TaskRegistry.get_task(task_id).review_status == nil
    end
  end

  describe "multi-repo review — ActiveTasks hub invalidation" do
    # invalidate_active_tasks/1 fires ONLY on the completion path
    # (settle_repo_action/4). A partial resolution stays on the page and must
    # leave the warmed sidebar snapshot byte-for-byte unchanged.
    setup do
      {primary_dir, _foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        {:ok, "deadbeef"}
      end)

      Application.put_env(:evo_dash, :review_reject_runner, fn _n, _p, _b -> :ok end)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :review_merge_runner)
        Application.delete_env(:evo_dash, :review_reject_runner)
      end)

      {:ok, task_id: task_id}
    end

    test "a partial resolution leaves the hub snapshot unchanged", %{conn: conn, task_id: task_id} do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      wait_hub_warm()
      assert {:ok, {_running, _pending}} = pre_hub = EvoDash.ActiveTasks.get(nil, node())

      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})

      # One repo resolved, the other pending → no completion → NO invalidation.
      assert EvoDash.ActiveTasks.get(nil, node()) == pre_hub
    end

    test "the final terminal resolution invalidates the hub snapshot", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      wait_hub_warm()
      assert {:ok, {_running, _pending}} = pre_hub = EvoDash.ActiveTasks.get(nil, node())

      # Partial resolution (merge) → the snapshot survives untouched.
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})
      assert EvoDash.ActiveTasks.get(nil, node()) == pre_hub

      # The LAST repo reaching a terminal state completes the review → the
      # snapshot is invalidated so a later /projects mount comes up cold.
      render_click(view, "reject", %{"repo_id" => "original"})
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end
  end

  describe "open_repo_diff" do
    setup do
      task_id = seed_orphaned_review_task!()
      {:ok, task_id: task_id}
    end

    test "switches to the named repo's diff on the files-changed tab", %{
      conn: conn,
      task_id: task_id
    } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)])
        ])

      # The default conversation tab renders the per-repo cards, never the diff.
      assert render(view) =~ ~s(id="repo-card-primary")
      refute has_element?(view, "#diff-viewer")

      html = render_click(view, "open_repo_diff", %{"repo_id" => "original"})

      # The FOREIGN repo's file list is now the rendered one, the diff viewer is
      # mounted, and the files-changed toolbar's repo selector marks it active.
      assert html =~ "src/two.rs"
      refute html =~ "lib/one.ex"
      assert html =~ ~s(id="diff-viewer")
      refute html =~ ~s(id="repo-card-primary")
      assert repo_select_state(html) == %{values: ["primary", "original"], selected: ["original"]}
    end

    test "an unknown repo id is a harmless no-op", %{conn: conn, task_id: task_id} do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)]),
          review_repo("original", "/nonexistent/foreign/path", [file_info("src/two.rs", 12, 5)])
        ])

      html = render_click(view, "open_repo_diff", %{"repo_id" => "ghost"})

      # Not whitelisted → the socket is returned unchanged: still on the
      # conversation tab, still no repo selector (the diff toolbar never renders).
      assert html =~ ~s(id="repo-card-primary")
      refute html =~ ~s(id="diff-viewer")
      assert repo_select_state(html) == %{values: [], selected: []}
    end

    test "missing / malformed params hit the catch-all no-op clause", %{
      conn: conn,
      task_id: task_id
    } do
      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", [file_info("lib/one.ex", 30, 10)])
        ])

      # %{} and %{"other" => _} reach the catch-all clause; a nil id is rejected
      # by find_review_repo/2 (non-binary) — all three are no-ops.
      for params <- [%{}, %{"other" => "x"}, %{"repo_id" => nil}] do
        html = render_click(view, "open_repo_diff", params)

        assert html =~ ~s(id="repo-card-primary")
        refute html =~ ~s(id="diff-viewer")
      end
    end
  end

  describe "multi-repo review — per-repo action whitelist and terminal guards" do
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "merge with an unknown repo_id never calls the runner", %{conn: conn, task_id: task_id} do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      html = render_click(view, "merge", %{"repo_id" => "ghost", "target_branch" => "dev"})

      # Whitelist miss → no runner call, no state change, no navigation.
      refute_received {:merged_call, _, _, _, _}
      refute_redirected(view)
      refute html =~ "Changes merged successfully"

      assert Enum.all?(assigns(view)[:review_repos], &(&1.resolution == nil))
      assert TaskRegistry.get_task(task_id).review_status == nil
    end

    test "reject with an unknown repo_id never calls the runner", %{conn: conn, task_id: task_id} do
      test_pid = self()

      Application.put_env(:evo_dash, :review_reject_runner, fn n, p, b ->
        send(test_pid, {:reject_call, n, p, b})
        :ok
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_reject_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      render_click(view, "reject", %{"repo_id" => "ghost"})

      refute_received {:reject_call, _, _, _}
      refute_redirected(view)
      assert Enum.all?(assigns(view)[:review_repos], &(&1.resolution == nil))
    end

    test "merge/reject on an already-terminal repo are no-ops", %{conn: conn, task_id: task_id} do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      Application.put_env(:evo_dash, :review_reject_runner, fn n, p, b ->
        send(test_pid, {:reject_call, n, p, b})
        :ok
      end)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :review_merge_runner)
        Application.delete_env(:evo_dash, :review_reject_runner)
      end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Resolve the primary, then act on it again — the terminal guard must
      # short-circuit BEFORE the runner.
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})
      assert_received {:merged_call, _, _, "task-branch", "dev"}

      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "dev"})
      render_click(view, "reject", %{"repo_id" => "primary"})

      refute_received {:merged_call, _, _, _, _}
      refute_received {:reject_call, _, _, _}

      primary = Enum.find(assigns(view)[:review_repos], &(&1.repo_id == "primary"))
      assert primary.resolution == %{state: :merged, target: "dev"}
      assert primary.branch_exists == false
    end

    test "merge/reject on a load-seeded :handled repo are no-ops", %{conn: conn} do
      task_id = seed_orphaned_review_task!()
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      Application.put_env(:evo_dash, :review_reject_runner, fn n, p, b ->
        send(test_pid, {:reject_call, n, p, b})
        :ok
      end)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :review_merge_runner)
        Application.delete_env(:evo_dash, :review_reject_runner)
      end)

      handled =
        Map.put(review_repo("primary", "/nonexistent/repo/path", []), :resolution, %{
          state: :handled
        })

      view = mount_with_repos(conn, task_id, [handled])

      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "main"})
      render_click(view, "reject", %{"repo_id" => "primary"})

      refute_received {:merged_call, _, _, _, _}
      refute_received {:reject_call, _, _, _}

      primary = Enum.find(assigns(view)[:review_repos], &(&1.repo_id == "primary"))
      assert primary.resolution == %{state: :handled}
    end

    test "a blank or unknown target_branch falls back to the repo's default target", %{
      conn: conn,
      task_id: task_id,
      primary_dir: primary_dir,
      foreign_dir: foreign_dir
    } do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Blank target → the repo's default ("main" here).
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => ""})

      assert_received {:merged_call, _, call_path, "task-branch", "main"}
      assert call_path == primary_dir

      # Unknown target (not a member of this repo's merge_targets) → the default.
      render_click(view, "merge", %{"repo_id" => "original", "target_branch" => "no-such-branch"})

      assert_received {:merged_call, _, call_path, "task-branch", "main"}
      assert call_path == foreign_dir
    end
  end

  describe "repo card resolution seeding (load-time)" do
    # build_repo_entry/2 seeds a TERMINAL %{state: :handled} resolution when a
    # non-blank branch_name is paired with branch_exists: false (the branch
    # vanished) — rendered as the terminal row with NO merge form / actions.
    # A blank / nil branch_name NEVER seeds :handled and stays unresolved.
    test "a vanished branch renders as :handled with no actions", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      card = repo_card_html(html, "primary")

      # The resolution badge carries the terminal :handled label...
      [badge] = Floki.find(Floki.parse_document!(card), "#repo-resolution-primary")
      assert Floki.text(badge) |> String.trim() == "Already handled"

      # ...and the card offers neither a merge form nor a Reject button.
      refute card =~ ~s(id="merge-form-primary")
      refute card =~ ~s(phx-click="reject")
      refute card =~ ~s(phx-click="merge")
    end

    test "a nil branch name stays unresolved and renders no merge form", %{conn: conn} do
      task_id = "review_test_nil_branch_seeding_#{System.unique_integer([:positive])}"

      # A completed task whose result does not carry a branch_name (an error
      # tuple) — branch_name is nil, so no :handled resolution is seeded.
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
        # Synchronize the deletion cast.
        TaskRegistry.list_tasks()
      end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      card = repo_card_html(html, "primary")

      # `#repo-resolution-<id>` is ALWAYS rendered — empty when unresolved.
      [badge] = Floki.find(Floki.parse_document!(card), "#repo-resolution-primary")
      assert Floki.text(badge) |> String.trim() == ""

      refute card =~ ~s(id="merge-form-primary")
      refute card =~ ~s(phx-click="reject")
      refute card =~ "Already handled"
    end
  end

  describe "multi-repo review — per-repo target selection" do
    setup do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      {:ok, primary_dir: primary_dir, foreign_dir: foreign_dir, task_id: task_id}
    end

    test "merge_target_change updates only the changed repo's selected target", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      # Each card owns its own <select> inside #merge-form-<repo_id>, both
      # preselecting their own default ("main").
      assert repo_target_selection(html, "primary") == "main"
      assert repo_target_selection(html, "original") == "main"

      html =
        render_change(view, "merge_target_change", %{
          "repo_id" => "original",
          "target_branch" => "dev"
        })

      # Only the foreign repo's select moved to "dev" — the primary's own
      # default target is untouched (never a shared, page-level target).
      assert repo_target_selection(html, "original") == "dev"
      assert repo_target_selection(html, "primary") == "main"
    end

    test "merge reads the per-repo select value", %{conn: conn, task_id: task_id} do
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)

      # Move the FOREIGN repo's select to "dev" through its own per-repo form...
      render_change(view, "merge_target_change", %{
        "repo_id" => "original",
        "target_branch" => "dev"
      })

      # ...then merge each repo into ITS OWN select value: the primary stays on
      # "main", the foreign repo on "dev".
      render_click(view, "merge", %{"repo_id" => "primary", "target_branch" => "main"})
      assert_received {:merged_call, _, primary_path, "task-branch", "main"}

      render_click(view, "merge", %{"repo_id" => "original", "target_branch" => "dev"})
      assert_received {:merged_call, _, foreign_path, "task-branch", "dev"}

      refute primary_path == foreign_path
    end
  end

  describe "multi-repo review — merge all (accept-all shortcut)" do
    # The batch shortcut (#merge-all-repositories, phx-click="merge_all", NO
    # params) folds EVERY unresolved repo through the SHARED merge_one_repo/3
    # path (the exact same path as the per-repo "merge" event), best-effort per
    # repo. It is gated on >= 2 repos AND >= 2 still unresolved.

    test "is hidden for a single-repo task", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      html =
        conn
        |> mount_with_repos(task_id, [review_repo("primary", "/nonexistent/repo/path", [])])
        |> render()

      refute html =~ ~s(id="merge-all-repositories")
      refute html =~ ~s(id="merge-all-toolbar")

      # Sanity: the single repo's own card still rendered.
      assert html =~ ~s(id="repo-card-primary")
    end

    test "is hidden when fewer than 2 repos are still unresolved", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      # One actionable repo + one ALREADY-terminal repo (`:handled`): only ONE
      # unresolved remains, so the shortcut must not render.
      handled =
        Map.put(review_repo("original", "/nonexistent/foreign/path", []), :resolution, %{
          state: :handled
        })

      html =
        conn
        |> mount_with_repos(task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          handled
        ])
        |> render()

      refute html =~ ~s(id="merge-all-repositories")
      refute html =~ ~s(id="merge-all-toolbar")
    end

    test "renders with a phx-confirm gate, after the banner slot and before the cards", %{
      conn: conn
    } do
      task_id = seed_orphaned_review_task!()

      html =
        conn
        |> mount_with_repos(task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          review_repo("original", "/nonexistent/foreign/path", [])
        ])
        |> render()

      assert html =~ ~s(id="merge-all-toolbar")
      assert html =~ ~s(id="merge-all-repositories")

      [button] = Floki.find(Floki.parse_document!(html), "#merge-all-repositories")

      assert Floki.attribute(button, "phx-click") == ["merge_all"]
      assert Floki.text(button) =~ "Merge all repositories"

      assert Floki.attribute(button, "class") == [
               "btn btn-success btn-sm rounded-lg gap-1.5"
             ]

      # Confirmation is attribute-based (phx-confirm), NOT a modal.
      assert Floki.attribute(button, "phx-confirm") == [
               "Merge ALL remaining repositories into their target branches? This cannot be undone."
             ]

      # Ordered INSIDE #review-repo-cards, AFTER the (absent here) completion
      # banner slot and BEFORE the first repo card.
      toolbar_index = :binary.match(html, ~s(id="merge-all-toolbar")) |> elem(0)
      first_card_index = :binary.match(html, ~s(id="repo-card-primary")) |> elem(0)
      assert toolbar_index < first_card_index

      refute html =~ ~s(id="review-completion-banner")
    end

    test "a direct merge_all dispatch with zero unresolved repos is a no-op", %{conn: conn} do
      task_id = seed_orphaned_review_task!()
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        send(test_pid, :merged_call)
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      # Every repo already terminal → nothing to fold (the button is hidden).
      primary =
        Map.put(review_repo("primary", "/nonexistent/repo/path", []), :resolution, %{
          state: :handled
        })

      foreign =
        Map.put(review_repo("original", "/nonexistent/foreign/path", []), :resolution, %{
          state: :merged,
          target: "main"
        })

      view = mount_with_repos(conn, task_id, [primary, foreign])

      refute render(view) =~ ~s(id="merge-all-repositories")

      # Event dispatch bypassing the (hidden) button: no runner call, no flash.
      render_click(view, "merge_all")

      refute_receive :merged_call, 100
      refute assigns(view)[:flash]["success"]
      refute assigns(view)[:flash]["error"]
    end

    test "merges every unresolved repo (one runner call each, respecting per-repo targets)", %{
      conn: conn
    } do
      {primary_dir, foreign_dir, task_id, _primary_sha, _foreign_sha} =
        create_multi_repo_review_task!("main", "dev")

      on_exit(fn -> rm_rf_retry(primary_dir) end)

      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      flush_review_load(view)
      wait_hub_warm()

      assert render(view) =~ ~s(id="merge-all-repositories")

      # Both cards default to "main"; move the FOREIGN repo's own select to
      # "dev" through its per-repo form, so the batch must read each repo's
      # target independently (never one shared, page-level target).
      render_change(view, "merge_target_change", %{
        "repo_id" => "original",
        "target_branch" => "dev"
      })

      render_click(view, "merge_all")

      # ONE runner call per unresolved repo, each with ITS OWN target: the
      # primary on its default "main", the foreign repo on its selected "dev".
      assert_receive {:merged_call, call_node, call_path, "task-branch", "main"}
      assert call_node == node()
      assert call_path == primary_dir

      assert_receive {:merged_call, call_node, call_path, "task-branch", "dev"}
      assert call_node == node()
      assert call_path == foreign_dir

      refute_receive {:merged_call, _, _, _, _}, 100

      # Both repos settled :merged into their own target; branches cleared.
      repos = assigns(view)[:review_repos]

      assert Enum.map(repos, &Map.get(&1, :resolution)) == [
               %{state: :merged, target: "main"},
               %{state: :merged, target: "dev"}
             ]

      assert Enum.all?(repos, &(&1.branch_exists == false))

      # The last repo reaching terminal completes the review (no navigation).
      refute_redirected(view)

      assert TaskRegistry.get_task(task_id).review_status == :merged

      html = render(view)
      assert html =~ ~s(id="review-completion-banner")
      assert html =~ "All repositories merged."
      assert assigns(view)[:flash]["success"] =~ "Successfully merged 2 repositories."
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "a conflict on one repo settles that card and the others still merge", %{conn: conn} do
      task_id = seed_orphaned_review_task!()
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})

        if p == "/nonexistent/foreign/path" do
          # A real merge returns raw git output (a STRING) as the conflict
          # detail — truncate_string/2 requires a binary.
          {:conflict, "CONFLICT (content): merge conflict in foreign_conflict.txt"}
        else
          {:ok, "deadbeef"}
        end
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          review_repo("original", "/nonexistent/foreign/path", [])
        ])

      html = render_click(view, "merge_all")

      # ONE runner call per repo — the foreign repo's conflict did NOT abort the
      # primary's merge (best-effort per repo).
      assert_receive {:merged_call, _, "/nonexistent/repo/path", "evogit/test-branch", nil}
      assert_receive {:merged_call, _, "/nonexistent/foreign/path", "evogit/test-branch", nil}
      refute_receive {:merged_call, _, _, _, _}, 100

      primary_card = repo_card_html(html, "primary")
      foreign_card = repo_card_html(html, "original")

      assert primary_card =~ "Merged"
      assert foreign_card =~ "Merge conflict"
      assert foreign_card =~ "foreign_conflict.txt"

      # Partial batch summary overwrites the fold's per-repo flashes.
      assert assigns(view)[:flash]["error"] =~ "Merged 1 of 2 repositories."

      # The conflict is NON-terminal → the review stays open and the page STAYS.
      refute_redirected(view)
      refute html =~ ~s(id="review-completion-banner")
      assert TaskRegistry.get_task(task_id).review_status == nil
    end

    test "all repos erroring reports a batch failure and keeps every card retryable", %{
      conn: conn
    } do
      task_id = seed_orphaned_review_task!()

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        {:error, :boom}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          review_repo("original", "/nonexistent/foreign/path", [])
        ])

      html = render_click(view, "merge_all")

      assert repo_card_html(html, "primary") =~ "Merge failed"
      assert repo_card_html(html, "original") =~ "Merge failed"

      assert assigns(view)[:flash]["error"] =~ "Could not merge any of the 2 repositories"

      # No repo reached terminal → no completion, no navigation.
      refute_redirected(view)
      refute html =~ ~s(id="review-completion-banner")
      assert TaskRegistry.get_task(task_id).review_status == nil
    end

    test "all repos resolving through the shortcut completes the review once", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      Application.put_env(:evo_dash, :review_merge_runner, fn _n, _p, _b, _t ->
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      view =
        mount_with_repos(conn, task_id, [
          review_repo("primary", "/nonexistent/repo/path", []),
          review_repo("original", "/nonexistent/foreign/path", [])
        ])

      wait_hub_warm()
      assert {:ok, {_running, _pending}} = EvoDash.ActiveTasks.get(nil, node())

      render_click(view, "merge_all")

      refute_redirected(view)

      # The aggregate review status is written through the shared settle path
      # (set_review_status/3 — :merged since both landed); completion is the
      # ONLY path that invalidates the sidebar hub snapshot.
      assert TaskRegistry.get_task(task_id).review_status == :merged

      html = render(view)
      assert html =~ ~s(id="review-completion-banner")
      assert html =~ ~s(id="review-completion-back")
      assert html =~ "All repositories merged."
      assert assigns(view)[:flash]["success"] =~ "Successfully merged 2 repositories."
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end
  end

  describe "multi-repo review — no-change repos" do
    # A repo whose `branch_name` is nil/blank produced no changes. Such a repo
    # must NEVER be handed to the merge runner (the core crashes with a
    # FunctionClauseError on a nil branch), must not count toward the accept-all
    # gate, and must not block aggregate completion — while a task with NO
    # changes in ANY repo is dismissed via the promoted "Mark as read" action.

    test "merge_all merges only the change-bearing repos and still completes the review", %{
      conn: conn
    } do
      task_id = seed_orphaned_review_task!()
      test_pid = self()

      Application.put_env(:evo_dash, :review_merge_runner, fn n, p, b, t ->
        send(test_pid, {:merged_call, n, p, b, t})
        {:ok, "deadbeef"}
      end)

      on_exit(fn -> Application.delete_env(:evo_dash, :review_merge_runner) end)

      no_change_primary =
        Map.put(review_repo("primary", "/nonexistent/repo/path", []), :branch_name, nil)

      view =
        mount_with_repos(conn, task_id, [
          no_change_primary,
          review_repo("original", "/nonexistent/foreign/path", [])
        ])

      # Only ONE change-bearing unresolved repo → the accept-all shortcut is
      # hidden, but a direct dispatch still folds the repos that DO have changes.
      refute render(view) =~ ~s(id="merge-all-repositories")

      html = render_click(view, "merge_all")

      # EXACTLY ONE runner call — for the foreign (change-bearing) repo. The
      # nil-branch primary is skipped entirely, so its nil branch never reaches
      # the runner (which would crash in the core).
      assert_receive {:merged_call, call_node, path, "evogit/test-branch", _target}
      assert call_node == node()
      assert path == "/nonexistent/foreign/path"
      refute_receive {:merged_call, _, _, _, _}, 100

      # Completion fires despite the primary never resolving: the no-change repo
      # needs no action, so it never blocks the aggregate.
      refute_redirected(view)
      assert TaskRegistry.get_task(task_id).review_status == :merged
      assert html =~ ~s(id="review-completion-banner")
      assert html =~ "All repositories merged."
    end

    test "a no-change repo never blocks aggregate completion", %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      Application.put_env(:evo_dash, :review_reject_runner, fn _node, _path, _branch -> :ok end)
      on_exit(fn -> Application.delete_env(:evo_dash, :review_reject_runner) end)

      no_change_primary =
        Map.put(review_repo("primary", "/nonexistent/repo/path", []), :branch_name, nil)

      view =
        mount_with_repos(conn, task_id, [
          no_change_primary,
          review_repo("original", "/nonexistent/foreign/path", [])
        ])

      html = render_click(view, "reject", %{"repo_id" => "original"})

      # Rejecting the ONLY change-bearing repo completes the review as
      # :rejected — the no-change primary never holds it open.
      refute_redirected(view)
      assert TaskRegistry.get_task(task_id).review_status == :rejected
      assert html =~ ~s(id="review-completion-banner")
      assert html =~ "All repositories rejected."
    end

    test "the accept-all shortcut is hidden when fewer than two CHANGE-BEARING repos are unresolved",
         %{conn: conn} do
      task_id = seed_orphaned_review_task!()

      # THREE repos but only ONE change-bearing: neither a nil branch nor a
      # blank ("") branch counts, so the >= 2 change-bearing gate fails.
      html =
        conn
        |> mount_with_repos(task_id, [
          Map.put(review_repo("primary", "/nonexistent/repo/path", []), :branch_name, nil),
          Map.put(review_repo("extra", "/nonexistent/extra/path", []), :branch_name, ""),
          review_repo("original", "/nonexistent/foreign/path", [])
        ])
        |> render()

      refute html =~ ~s(id="merge-all-repositories")
      refute html =~ ~s(id="merge-all-toolbar")

      # Sanity: the no-change primary card still rendered.
      assert html =~ ~s(id="repo-card-primary")
    end

    test "a fully no-change task renders 'Mark as read' as the primary action and keeps the info notice",
         %{conn: conn} do
      task_id = seed_no_change_review_task!()

      {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
      html = flush_review_load(view)

      # NO repo has a branch → the whole review is a no-change review.
      assert assigns(view)[:is_no_changes] == true

      # The dismissal is promoted to a PRIMARY "Mark as read" action carrying
      # the same ignore event + its own confirmation copy.
      [button] = Floki.find(Floki.parse_document!(html), "button[phx-click='ignore']")
      assert Floki.text(button) =~ "Mark as read"

      assert Floki.attribute(button, "phx-confirm") == [
               "Mark this review as read? It will be dismissed from pending reviews."
             ]

      # NB: this fixture carries no archive metadata, so `show_export` is false
      # and the overflow menu is never rendered at all — this refute is only a
      # page-level sanity check, NOT a real exercise of the menu-item
      # suppression. The actual `show_ignore: false` contract (menu rendered but
      # WITHOUT the Ignore item) is pinned by the component-level test in the
      # "component surface pins (repo_cards / task_actions)" describe block.
      refute html =~ "Ignore this review?"

      # The informational no-changes notice is still shown.
      assert html =~ "The agent completed without making any code changes."
    end
  end

  describe "RepoCards.repo_has_changes?/1" do
    alias EvoDashWeb.ReviewComponents.RepoCards

    test "true iff branch_name is a non-blank binary (atom- or string-keyed)" do
      assert RepoCards.repo_has_changes?(%{branch_name: "task-branch"})
      assert RepoCards.repo_has_changes?(%{"branch_name" => "task-branch"})

      refute RepoCards.repo_has_changes?(%{branch_name: nil})
      refute RepoCards.repo_has_changes?(%{branch_name: ""})
      refute RepoCards.repo_has_changes?(%{branch_name: "   "})
      refute RepoCards.repo_has_changes?(%{"branch_name" => nil})
      refute RepoCards.repo_has_changes?(%{branch_name: :not_a_binary})
      refute RepoCards.repo_has_changes?(nil)
      refute RepoCards.repo_has_changes?(%{})
      refute RepoCards.repo_has_changes?("nope")
    end
  end

  describe "component surface pins (repo_cards / task_actions)" do
    # The components themselves live in the sibling components/ test node
    # (read-only here), so the surface contract is pinned in this file.
    test "repo_cards renders the completion banner only when completion is set" do
      repos = [
        review_repo("primary", "/repo/path", [file_info("lib/one.ex", 1, 0)]),
        review_repo("original", "/other/path", [])
      ]

      back_url = "/projects?node=remote-1"

      none =
        render_component(&EvoDashWeb.ReviewComponents.repo_cards/1, %{
          repos: repos,
          completion: nil,
          back_url: back_url
        })

      refute none =~ ~s(id="review-completion-banner")
      refute none =~ ~s(id="review-completion-back")

      merged =
        render_component(&EvoDashWeb.ReviewComponents.repo_cards/1, %{
          repos: repos,
          completion: :merged,
          back_url: back_url
        })

      assert merged =~ ~s(id="review-completion-banner")
      assert merged =~ "All repositories merged."
      assert completion_back_href(merged) == back_url

      rejected =
        render_component(&EvoDashWeb.ReviewComponents.repo_cards/1, %{
          repos: repos,
          completion: :rejected,
          back_url: back_url
        })

      assert rejected =~ ~s(id="review-completion-banner")
      assert rejected =~ "All repositories rejected."
      assert completion_back_href(rejected) == back_url
    end

    test "repo_cards always renders an empty resolution badge when unresolved" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.repo_cards/1, %{
          repos: [review_repo("primary", "/repo/path", [])],
          completion: nil,
          back_url: "/projects"
        })

      [badge] = Floki.find(Floki.parse_document!(html), "#repo-resolution-primary")
      assert Floki.text(badge) |> String.trim() == ""
    end

    test "task_actions renders the primary-scoped set with Reject absent from the menu" do
      html =
        render_component(&EvoDashWeb.ReviewComponents.task_actions/1, %{
          can_resume: true,
          loading: false,
          branch_exists: true,
          has_pr: false,
          pr_url: nil,
          show_export: false,
          export_url: nil
        })

      assert html =~ ~s(phx-click="resume")
      assert html =~ "Continue task"

      menu = overflow_menu(html)

      # Reject moved to the per-repo cards — the task-level menu must NOT carry
      # it, while the primary-scoped actions stay.
      refute menu =~ ~s(phx-click="reject")
      refute menu =~ "Reject"
      assert menu =~ ~s(phx-click="create_pr")
      assert menu =~ "Create GitHub PR"
      assert menu =~ ~s(phx-click="extract_skills")
      assert menu =~ ~s(phx-click="ignore")
      refute menu =~ "Export JSON"
    end

    test "task_actions with no_changes promotes 'Mark as read' and drops the menu's Ignore item" do
      base = %{
        can_resume: false,
        loading: false,
        branch_exists: false,
        has_pr: false,
        pr_url: nil,
        show_export: true,
        export_url: "/tasks/x/export"
      }

      # `no_changes: true` promotes the dismissal to a PRIMARY "Mark as read"
      # action (the `ignore` event). With `show_export: true` the overflow menu
      # IS still rendered — but it MUST NOT carry the now-redundant Ignore item.
      no_changes =
        render_component(
          &EvoDashWeb.ReviewComponents.task_actions/1,
          Map.put(base, :no_changes, true)
        )

      assert no_changes =~ "Mark as read"

      [button] = Floki.find(Floki.parse_document!(no_changes), "button[phx-click='ignore']")
      assert Floki.text(button) =~ "Mark as read"

      menu = overflow_menu(no_changes)
      assert menu =~ "Export JSON"
      refute menu =~ "Ignore this review?"
      refute menu =~ ~s(phx-click="ignore")

      # POSITIVE CONTROL: with the default `no_changes: false` the overflow menu
      # still carries the plain Ignore item — proving the refute above keys off
      # the promotion, not a missing menu/helper.
      control =
        render_component(
          &EvoDashWeb.ReviewComponents.task_actions/1,
          Map.put(base, :no_changes, false)
        )

      refute control =~ "Mark as read"

      control_menu = overflow_menu(control)
      assert control_menu =~ "Ignore this review?"
      assert control_menu =~ ~s(phx-click="ignore")
    end
  end

  # --- Helpers for the merge-target selector tests ---

  # Extracts the review page's "…" overflow menu — the ONLY
  # <details class="dropdown dropdown-end dropdown-top ml-auto"> on the page
  # (the layout's theme-toggle dropdowns build their class list dynamically
  # and carry no ml-auto; dropdown-top opens the menu upward since it sits at
  # the bottom of the page). Fails loudly when absent (the caller's assertions
  # would otherwise be vacuous on "").
  defp overflow_menu(html) do
    case Regex.run(
           ~r{<details class="dropdown dropdown-end dropdown-top ml-auto">.*?</details>}s,
           html
         ) do
      [menu] -> menu
      nil -> flunk("expected the overflow menu <details> to be rendered")
    end
  end

  # Returns the OUTER HTML of the per-repo card #repo-card-<repo_id>, so
  # per-repo assertions never accidentally match content on a sibling card.
  # Fails loudly when the card is absent.
  defp repo_card_html(html, repo_id) do
    case Floki.find(Floki.parse_document!(html), "#repo-card-#{repo_id}") do
      [card | _] -> Floki.raw_html(card)
      [] -> flunk("expected the repo card #repo-card-#{repo_id} to be rendered")
    end
  end

  # Mounts the review page for `task_id`, flushes the real async load, then
  # injects a review-data result at the CURRENT generation carrying the given
  # hand-built review_repos list (see review_repo/4). The injected repos keep
  # whatever branch_exists/merge_targets the caller sets — build them with
  # branch_exists: false + merge_targets: [] for fully deterministic mounts
  # (no async merge check ever spawns). Returns the view.
  defp mount_with_repos(conn, task_id, repos) do
    {:ok, view, _html} = live(conn, ~p"/review/#{task_id}")
    flush_review_load(view)

    gen = assigns(view)[:load_generation]

    send(
      view.pid,
      {:review_data_loaded, task_id, node(), gen,
       {:ok, %{review_repos: repos, active_repo_id: "primary", loading: false, error: nil}}}
    )

    render(view)
    view
  end

  # A hand-built review-repo entry for injected assigns maps: no real
  # repository, no merge targets (merge check never spawns), review_data
  # whose aggregate counts default to the file list's sums.
  defp review_repo(repo_id, repo_path, files, commits \\ []) do
    %{
      repo_id: repo_id,
      repo_path: repo_path,
      branch_name: "evogit/test-branch",
      commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
      base_sha: nil,
      branch_exists: false,
      review_data: %{
        files: files,
        changed_files_count: length(files),
        total_additions: Enum.sum(Enum.map(files, & &1.additions)),
        total_deletions: Enum.sum(Enum.map(files, & &1.deletions))
      },
      commits: commits,
      merge_targets: [],
      default_merge_target: nil,
      merge_status: nil
    }
  end

  defp file_info(path, additions \\ 0, deletions \\ 0) do
    %EvoGit.Review.FileInfo{
      path: path,
      status: "modified",
      additions: additions,
      deletions: deletions
    }
  end

  # Switches the review page to the Files-changed tab (returns the html).
  defp open_files_tab(view) do
    view
    |> element("button[phx-click='switch_tab'][phx-value-tab='files_changed']")
    |> render_click()
  end

  # Switches the review page to the Commits tab (returns the html).
  defp open_commits_tab(view) do
    view
    |> element("button[phx-click='switch_tab'][phx-value-tab='commits']")
    |> render_click()
  end

  # Extracts the repo selector's state from a rendered page: %{values: [...]}
  # (the option values in DOM order) + %{selected: [...]} (the preselected
  # option value(s)) — or %{values: [], selected: []} when no repo selector
  # renders. Every repo <select> shares name="repo_id" + the "selected" boolean
  # attr across the merge box, Files-changed toolbar, and Commits tab, and only
  # the ACTIVE tab's content is in the DOM at any time, so an unscoped find is
  # unambiguous.
  defp repo_select_state(html) do
    case Floki.find(Floki.parse_document!(html), "select[name='repo_id']") do
      [] ->
        %{values: [], selected: []}

      [select | _] ->
        options = Floki.find(select, "option")

        values =
          Enum.map(options, fn option ->
            option |> Floki.attribute("value") |> List.first()
          end)

        selected =
          options
          |> Enum.filter(&(Floki.attribute(&1, "selected") != []))
          |> Enum.map(fn option ->
            option |> Floki.attribute("value") |> List.first()
          end)

        %{values: values, selected: selected}
    end
  end

  # Extracts the conversation tab's diff-stats bar text (the unique gap-x-4
  # stats container on the review page) so summed additions/deletions are
  # asserted within the bar, not anywhere in the page.
  defp stats_bar_text(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("div.flex.flex-wrap.items-center.gap-x-4")
    |> Floki.text()
    |> String.replace(~r/\s+/, " ")
  end

  # Extracts a page-tabs count badge's text ("files_changed" | "commits").
  defp badge_text(html, tab) do
    [badge] =
      html
      |> Floki.parse_document!()
      |> Floki.find("button[phx-click='switch_tab'][phx-value-tab='#{tab}'] span.badge")

    badge |> Floki.text() |> String.trim()
  end

  # A hand-built CommitInfo with a distinct sha per `prefix`.
  defp commit_info(prefix, message) do
    %EvoGit.Review.CommitInfo{
      sha: prefix <> String.duplicate("0", 39),
      short_sha: prefix <> String.duplicate("0", 7),
      message: message,
      author_name: "Test User",
      author_email: "test@example.com",
      date: DateTime.utc_now()
    }
  end

  # Seeds a completed orphaned-path review task with NO objective/prompt in
  # its opts — the LoadData objective falls back to `to_string(nil) |> trim()`
  # → "" (blank, never nil), which the objective card renders as the
  # empty-state card. Returns the task id.
  defp seed_review_task_no_objective! do
    task_id = "review_test_noobj_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      opts: [path: "/nonexistent/repo/path"],
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

  # Seeds a completed orphaned-path review task with a custom objective (for
  # page-header title assertions). Returns the task id.
  defp seed_review_task_with_objective!(objective) do
    task_id = "review_test_title_#{System.unique_integer([:positive])}"

    task = %TaskInfo{
      id: task_id,
      type: :evolve,
      status: :completed,
      opts: [path: "/nonexistent/repo/path", objective: objective],
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
  # pointing at it. The optional `archive_metadata` seeds the archive-export
  # affordances. Returns {repo_path, task_id, change_sha} and registers
  # on_exit cleanup.
  defp create_review_task_with_repo!(primary, secondary, archive_metadata \\ nil) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit_review_merge_test_" <> to_string(System.unique_integer([:positive]))
      )

    {change_sha, _primary} = build_repo_with_task_branch!(tmp_dir, primary, secondary)
    task_id = seed_review_task!(tmp_dir, change_sha, archive_metadata)

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
        Process.sleep(20)
        rm_rf_retry(path, attempts - 1)

      other ->
        other
    end
  end

  # Seeds a completed review task pointing at `repo_path` with the agent
  # branch `task-branch` (which must exist in the repo). The optional
  # `archive_metadata` seeds the archive-export affordances.
  defp seed_review_task!(repo_path, change_sha, archive_metadata) do
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
      archive_metadata: archive_metadata,
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

  # Seeds a completed review task in which NO repo produced changes: the top
  # result carries a STRING-keyed `repos` map whose primary entry has both a nil
  # commit_sha and a nil branch_name (no `foreign_repos` → no normalize work).
  # Drives the fully-no-change review state (`is_no_changes` → "Mark as read").
  defp seed_no_change_review_task! do
    seed_multi_repo_task!(
      "/nonexistent/repo/path",
      nil,
      [],
      %{"primary" => %{"commit_sha" => nil, "branch_name" => nil}}
    )
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
            Process.sleep(10)
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

  # The <option value> preselected inside a SINGLE repo card's own merge form
  # (#merge-form-<repo_id>). Scoping to the card first (repo_card_html/2) keeps
  # a sibling card's select out of the match — each card owns its own target.
  defp repo_target_selection(html, repo_id) do
    html
    |> repo_card_html(repo_id)
    |> target_branch_select()
    |> selected_option_value()
  end

  # The href of the completion banner's back link (#review-completion-back), or
  # nil when the link is absent.
  defp completion_back_href(html) do
    case Floki.find(Floki.parse_document!(html), "#review-completion-back") do
      [link | _] -> link |> Floki.attribute("href") |> List.first()
      [] -> nil
    end
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
