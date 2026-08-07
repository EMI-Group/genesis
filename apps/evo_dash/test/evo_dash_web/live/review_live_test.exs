defmodule EvoDashWeb.ReviewLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskRegistry
  alias EvoGit.TaskInfo

  describe "review for non-existent task" do
    test "shows error for non-existent task id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review/nonexistent-task-id")

      assert html =~ "Review Not Available"
      assert html =~ "Task not found"
    end

    test "renders back to dashboard link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/review/nonexistent-task-id")

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
      {:ok, _view, html} = live(conn, ~p"/review/#{task_id}")

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

      # Click the ignore button — this triggers a navigation, so we assert the
      # LiveView process terminates and the browser is redirected to "/".
      view |> element("button[phx-click='ignore']") |> render_click()

      assert_redirect(view, "/")

      # The cast runs async, but a synchronous get_task call guarantees all
      # prior casts to the registry have been processed.
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
    #
    # NOTE: the feature itself is being implemented in a parallel worktree and
    # is NOT present here yet, so the feature-specific assertions below are
    # expected to fail until that work lands.
    setup do
      {repo_path, task_id, change_sha} = create_review_task_with_repo!("main", "dev")

      {:ok, repo_path: repo_path, task_id: task_id, change_sha: change_sha}
    end

    test "renders a target-branch selector with the default target pre-selected", %{
      conn: conn,
      task_id: task_id
    } do
      {:ok, _view, html} = live(conn, ~p"/review/#{task_id}")

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
      {:ok, _view, html} = live(conn, ~p"/review/#{task_id}")

      select_html = target_branch_select(html)
      assert select_html != "", "expected a target-branch <select> to be rendered"
      assert select_html =~ ~r{<option[^>]*value="dev"[^>]*>}

      # main/master are absent, so the default target resolves to dev.
      assert selected_option_value(select_html) == "dev"
    end
  end

  # --- Helpers for the merge-target selector tests ---

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
      File.rm_rf!(tmp_dir)
    end)

    {tmp_dir, task_id, String.trim(change_sha)}
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

  # Extracts the "Merge into" target-branch <select> block, or "" if absent.
  defp target_branch_select(html) do
    case Regex.run(~r{<select[^>]*name="target_branch"[^>]*>.*?</select>}s, html) do
      [select_html] -> select_html
      _ -> ""
    end
  end

  # Returns the value of the pre-selected <option> inside a select block, or
  # nil. Tolerates `selected` appearing before or after the value attribute.
  defp selected_option_value(select_html) do
    case Regex.run(
           ~r{<option[^>]*value="([^"]+)"[^>]*selected[^>]*>|<option[^>]*selected[^>]*value="([^"]+)"[^>]*>},
           select_html
         ) do
      [_, v1, v2] -> v1 || v2
      _ -> nil
    end
  end
end
