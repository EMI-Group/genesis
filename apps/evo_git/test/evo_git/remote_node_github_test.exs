defmodule EvoGit.RemoteNodeGitHubTest do
  @moduledoc """
  Tests for the GitHub gh-CLI RPC wrappers on `EvoGit.RemoteNode`.

  Mirrors `EvoGit.RemoteNodeTest` style (unreachable-remote error fallbacks +
  local-node RemoteAPI delegation), but kept in a SEPARATE file because the
  gh-dependent local-path tests manipulate the BEAM-global `PATH` env var —
  appending them to `remote_node_test.exs` would force that whole
  `async: true` module to `async: false`.

  Note: `github_upstream/2`, `list_github_issues/3` and
  `github_issue_markdown/3` on `EvoGit.RemoteNode` (and their
  `EvoGit.AgentScheduler.RemoteAPI` delegates) are added in a coordinated
  parallel lib change — this file will not compile/run standalone until that
  change lands.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.FakeGh
  alias EvoGit.RemoteNode

  # A node name that definitely does not exist on this machine.
  # On a non-distributed local node (:nonode@nohost), :erpc.call to any foreign
  # node fails immediately with {:erpc, :noconnection} — no TCP timeout wait.
  @fake_remote :"nonexistent@127.0.0.1"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit-test-remote-node-gh-" <> to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(tmp_dir)
    {:ok, _} = Git.init(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  defp add_origin(tmp_dir, url) do
    {:ok, _} = Git.run(["remote", "add", "origin", url], tmp_dir)
    :ok
  end

  describe "github_upstream/2" do
    test "returns {:error, _} when the remote node is unreachable", %{tmp_dir: tmp_dir} do
      assert {:error, _} = RemoteNode.github_upstream(@fake_remote, tmp_dir)
    end

    test "local path delegates to RemoteAPI (repo with origin)", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

      assert {:ok, upstream} = RemoteNode.github_upstream(node(), tmp_dir)
      assert upstream.owner == "octocat"
      assert upstream.repo == "hello-world"
      assert upstream.url == "https://github.com/octocat/hello-world.git"
    end

    test "local path delegates to RemoteAPI (repo without origin)", %{tmp_dir: tmp_dir} do
      assert RemoteNode.github_upstream(node(), tmp_dir) == {:error, :no_github_upstream}
    end
  end

  describe "list_github_issues/3" do
    test "returns {:error, _} when the remote node is unreachable", %{tmp_dir: tmp_dir} do
      assert {:error, _} = RemoteNode.list_github_issues(@fake_remote, tmp_dir)
    end
  end

  describe "github_issue_markdown/3" do
    test "returns {:error, _} when the remote node is unreachable", %{tmp_dir: tmp_dir} do
      assert {:error, _} = RemoteNode.github_issue_markdown(@fake_remote, tmp_dir, 42)
    end
  end

  # The fake gh is a POSIX shell script on PATH — the gh-dependent local-path
  # tests run on POSIX platforms only.
  if not match?({:win32, _}, :os.type()) do
    describe "local path with fake gh (POSIX)" do
      test "list_github_issues/3 returns normalized issues", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, issues} = RemoteNode.list_github_issues(node(), tmp_dir)
          assert [%{number: number} | _] = issues
          assert number == 1
        end)
      end

      test "github_issue_markdown/3 returns the issue markdown", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, markdown} = RemoteNode.github_issue_markdown(node(), tmp_dir, 42)
          assert markdown =~ "Refactor scheduler core"
        end)
      end
    end
  end
end
