defmodule EvoGit.Agent.SubagentProcessingTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.Core.ForeignRepo

  describe "resolve_subagent_path/3" do
    setup do
      parent_state = %{
        phylo_node: %{
          repo: "/home/user/projects/my_app"
        }
      }

      foreign_repos = [
        ForeignRepo.new(:primary, "/home/user/projects/my_app"),
        ForeignRepo.new(:original, "/Source/original-proj"),
        ForeignRepo.new(:reference, "/Source/rust-rewrite")
      ]

      %{parent_state: parent_state, foreign_repos: foreign_repos}
    end

    test "resolves relative path to primary repo", %{parent_state: parent_state, foreign_repos: foreign_repos} do
      {repo_id, repo_root, rel_path} =
        SubagentProcessing.resolve_subagent_path("./src/auth", parent_state, foreign_repos)

      assert repo_id == :primary
      assert repo_root == "/home/user/projects/my_app"
      assert rel_path == "./src/auth"
    end

    test "resolves absolute path to foreign repo", %{parent_state: parent_state, foreign_repos: foreign_repos} do
      {repo_id, repo_root, rel_path} =
        SubagentProcessing.resolve_subagent_path("/Source/original-proj/src/auth", parent_state, foreign_repos)

      assert repo_id == :original
      assert repo_root == "/Source/original-proj"
      # Note: the deep path is returned here; build_subagent_specs overrides it to "./"
      assert rel_path == "./src/auth"
    end

    test "resolves absolute path to foreign repo root", %{parent_state: parent_state, foreign_repos: foreign_repos} do
      {repo_id, repo_root, rel_path} =
        SubagentProcessing.resolve_subagent_path("/Source/original-proj", parent_state, foreign_repos)

      assert repo_id == :original
      assert repo_root == "/Source/original-proj"
      assert rel_path == "./"
    end

    test "falls back to primary for unknown absolute path", %{parent_state: parent_state, foreign_repos: foreign_repos} do
      # Unknown absolute paths are gracefully handled by stripping the leading "/"
      # and normalizing as a relative path under the primary repo.
      {repo_id, repo_root, rel_path} =
        SubagentProcessing.resolve_subagent_path("/unknown/path", parent_state, foreign_repos)

      assert repo_id == :primary
      assert repo_root == "/home/user/projects/my_app"
      assert rel_path == "./unknown/path"
    end

    test "resolves deep absolute path to second foreign repo", %{parent_state: parent_state, foreign_repos: foreign_repos} do
      {repo_id, repo_root, rel_path} =
        SubagentProcessing.resolve_subagent_path("/Source/rust-rewrite/src/lib.rs", parent_state, foreign_repos)

      assert repo_id == :reference
      assert repo_root == "/Source/rust-rewrite"
      assert rel_path == "./src/lib.rs"
    end
  end
end
