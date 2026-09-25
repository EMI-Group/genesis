defmodule EvoGit.Agent.RunnerAutoCommitTest do
  @moduledoc """
  Regression tests for the `commit_sha` ordering fix around the Runner's
  auto-commit fallback.

  `EvoGit.Agent.Runner.run/3` runs the agent loop in a `try` whose `after`
  calls `EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree/0` (a
  best-effort `git add --all` + `git commit -m "Agent: auto-commit fallback"`).
  That `after` block may create the ONLY commit of a run, while
  `Result.commit_sha` was captured earlier — inside `do_complete/2`, BEFORE the
  fallback committed. `run/3` now rebinds the `try/after` value and passes it
  through `EvoGit.Agent.Runner.refresh_commit_sha/1` AFTER the fallback ran, so
  the reported sha points at the post-fallback worktree HEAD and
  `Runtime.Helpers.merge_and_report/3,4` (which treats "final == live HEAD" as
  "no changes") still produces a reviewable `genesis/agent_*` branch.

  These tests drive `refresh_commit_sha/1` and the real auto-commit fallback
  against temporary git repositories. `async: true` — every assertion is
  process-local (`Process.get/put(:repo_path | :repo_less)` in the test process)
  or scoped to a per-test temp repo path, which is the only cross-process write
  (`EvoGit.GitEnv`'s per-repo-path identity memo), mirroring
  `commit_graph_test.exs`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Runner
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.Runtime.Helpers

  setup do
    # The pdict is per-test-process and dies with it; delete defensively so an
    # accidental carry-over from a helper can never leak into another test.
    Process.delete(:repo_path)
    Process.delete(:repo_less)

    repo = new_repo!()
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo}
  end

  # ---------------------------------------------------------------------------
  # (a) refresh after the auto-commit fallback
  # ---------------------------------------------------------------------------

  test "refresh_commit_sha/1 picks up the fallback commit's HEAD", %{repo: repo} do
    pre_sha = git!(repo, ["rev-parse", "HEAD"])

    # The agent left work uncommitted; only the fallback will commit it.
    File.write!(Path.join(repo, "work.txt"), "work\n")

    Process.put(:repo_path, repo)
    assert :ok = Dispatch.commit_pending_in_worktree()

    refreshed = Runner.refresh_commit_sha(%Result{result: "done", commit_sha: pre_sha})
    head = git!(repo, ["rev-parse", "HEAD"])

    assert %Result{} = refreshed
    assert refreshed.result == "done"
    assert refreshed.commit_sha == head
    refute refreshed.commit_sha == pre_sha

    # A second refresh is a fixed point (HEAD has not moved again).
    assert Runner.refresh_commit_sha(refreshed) == refreshed
  end

  # ---------------------------------------------------------------------------
  # (b) repo-less guard
  # ---------------------------------------------------------------------------

  test "repo-less agents are returned completely unchanged", %{repo: repo} do
    # Even with a REAL git repo installed as :repo_path, the repo-less flag must
    # short-circuit before any git call.
    Process.put(:repo_path, repo)
    Process.put(:repo_less, true)

    result = %Result{result: "x", commit_sha: "deadbeef"}

    assert Runner.refresh_commit_sha(result) == result
    assert Runner.refresh_commit_sha(result).commit_sha == "deadbeef"

    wrapped = {:ok, result}
    assert Runner.refresh_commit_sha(wrapped) == wrapped
  end

  # ---------------------------------------------------------------------------
  # (c) passthrough / no-raise
  # ---------------------------------------------------------------------------

  test "non-success shapes are returned byte-identical", %{repo: repo} do
    Process.put(:repo_path, repo)

    for input <- [
          {:error, :recovery_failed},
          {:error, {:x, 1}},
          nil,
          :ok,
          %{some: "map"},
          {:ok, :weird}
        ] do
      assert Runner.refresh_commit_sha(input) === input
    end
  end

  test "an unreadable :repo_path returns the input unchanged without raising", %{repo: repo} do
    result = %Result{result: "x", commit_sha: "abc"}

    Process.delete(:repo_path)
    assert Runner.refresh_commit_sha(result) == result

    Process.put(:repo_path, "")
    assert Runner.refresh_commit_sha(result) == result

    Process.put(:repo_path, nil)
    assert Runner.refresh_commit_sha(result) == result

    Process.put(
      :repo_path,
      Path.join(repo, "does-not-exist-#{System.unique_integer([:positive])}")
    )

    assert Runner.refresh_commit_sha(result) == result

    # A plain (non-git) directory is equally a no-op.
    plain =
      Path.join(System.tmp_dir!(), "evogit-runner-nongit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    Process.put(:repo_path, plain)
    assert Runner.refresh_commit_sha(result) == result
  end

  # ---------------------------------------------------------------------------
  # (d) end-to-end reviewability
  # ---------------------------------------------------------------------------

  test "the refreshed result stays reviewable while the stale sha does not", %{repo: repo} do
    # The agent works in a WORKTREE while `merge_and_report/3` is given the repo
    # ROOT (whose base branch stays put) — the split that makes the stale sha a
    # bug in the first place.
    base_sha = git!(repo, ["rev-parse", "HEAD"])

    worktree =
      Path.join(System.tmp_dir!(), "evogit-runner-wt-#{System.unique_integer([:positive])}")

    git!(repo, ["worktree", "add", "-b", "evogit-agent-test", worktree, "HEAD"])
    on_exit(fn -> File.rm_rf!(worktree) end)

    File.write!(Path.join(worktree, "work.txt"), "work\n")
    Process.put(:repo_path, worktree)
    assert :ok = Dispatch.commit_pending_in_worktree()

    head_sha = git!(worktree, ["rev-parse", "HEAD"])
    refute head_sha == base_sha
    # The repo root is still on its base branch — it is NOT the worktree HEAD.
    assert git!(repo, ["rev-parse", "HEAD"]) == base_sha

    refreshed = Runner.refresh_commit_sha(%Result{result: "work", commit_sha: base_sha})
    assert refreshed.commit_sha == head_sha

    assert {:ok, report} = Helpers.merge_and_report(repo, refreshed, "evolve")
    refute Map.has_key?(report, :no_changes)
    assert is_binary(report.branch_name)
    assert String.starts_with?(report.branch_name, "genesis/agent_")
    assert report.repos["primary"].branch_name == report.branch_name
    assert report.repos["primary"].commit_sha == head_sha

    # CONTROL: the STALE pre-fallback sha equals the live repo-root HEAD, so
    # merge_and_report sees "no changes" — no branch, commit unreviewable.
    # This is exactly what the ordering fix prevents.
    stale = %Result{result: "work", commit_sha: base_sha}

    assert {:ok, control} = Helpers.merge_and_report(repo, stale, "evolve")
    assert control.no_changes == true
    assert control.branch_name == nil
    assert control.repos["primary"].branch_name == nil
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Fresh temp git repo with one committed README.md and a deterministic
  # repo-local commit identity.
  defp new_repo! do
    repo =
      Path.join(
        System.tmp_dir!(),
        "evogit-runner-autocommit-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo)
    {:ok, _} = Git.init(repo)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], repo)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {:ok, _} = Git.add(repo, "README.md")
    {:ok, _} = Git.commit(repo, "Initial commit")
    repo
  end

  defp git!(repo, args) do
    {out, code} =
      System.cmd("git", args, cd: repo, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    assert code == 0, "git #{Enum.join(args, " ")} exited #{code}:\n#{out}"
    String.trim(out)
  end
end
