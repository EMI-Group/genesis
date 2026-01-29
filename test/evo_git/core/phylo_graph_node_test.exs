defmodule EvoGit.Core.PhyloGraphNodeTest do
  use ExUnit.Case
  alias EvoGit.Core.PhyloGraphNode

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a git repo
    git_run(tmp_dir, ["init"])
    # Set default branch to main to avoid confusion
    git_run(tmp_dir, ["symbolic-ref", "HEAD", "refs/heads/main"])
    git_run(tmp_dir, ["config", "user.email", "you@example.com"])
    git_run(tmp_dir, ["config", "user.name", "Your Name"])

    # Initial commit
    File.write!(Path.join(tmp_dir, "README.md"), "# Hello\n")
    git_run(tmp_dir, ["add", "."])
    git_run(tmp_dir, ["commit", "-m", "Initial commit"])
    {base_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
    base_sha = String.trim(base_sha)

    # Branch A (main) - evolve it
    File.write!(Path.join(tmp_dir, "README.md"), "# Hello\nWorld\n")
    git_run(tmp_dir, ["commit", "-am", "Main evolve"])
    {main_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
    main_sha = String.trim(main_sha)

    # Branch B (feature) - from base
    git_run(tmp_dir, ["checkout", "-b", "feature", base_sha])
    File.write!(Path.join(tmp_dir, "README.md"), "# Hello\nElixir\n")
    git_run(tmp_dir, ["commit", "-am", "Feature evolve"])
    {feature_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
    feature_sha = String.trim(feature_sha)

    # Switch back to main for testing
    git_run(tmp_dir, ["checkout", "main"])

    %{
      repo_path: tmp_dir,
      base_sha: base_sha,
      main_sha: main_sha,
      feature_sha: feature_sha
    }
  end

  defp git_run(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end

  test "find_merge_base", %{repo_path: path, base_sha: base, main_sha: main, feature_sha: feature} do
    node_main = PhyloGraphNode.new(path, main)
    node_feature = PhyloGraphNode.new(path, feature)

    {:ok, merge_base} = PhyloGraphNode.find_merge_base(node_main, node_feature)
    assert merge_base == base
  end

  test "add_and_commit", %{repo_path: path, main_sha: main} do
    node = PhyloGraphNode.new(path, main)

    File.write!(Path.join(path, "new_file.txt"), "New content")

    {:ok, new_node} = PhyloGraphNode.add_and_commit(node, "Add new file")

    assert new_node.path == path
    assert new_node.current_commit != main

    {head_sha, _} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    assert String.trim(head_sha) == new_node.current_commit
  end

  test "merge with conflict", %{repo_path: path, main_sha: main, feature_sha: feature} do
    node_main = PhyloGraphNode.new(path, main)
    node_feature = PhyloGraphNode.new(path, feature)

    # This should conflict on README.md
    assert {:conflict, _node, files} = PhyloGraphNode.crossover(node_main, node_feature)
    assert "README.md" in files

    # Check conflict files again
    {:ok, conflicts} = PhyloGraphNode.get_conflict_files(node_main)
    assert "README.md" in conflicts
  end

  test "merge clean", %{repo_path: path, base_sha: base} do
    # Create a non-conflicting branch
    git_run(path, ["checkout", "-b", "clean-feat", base])
    File.write!(Path.join(path, "clean.txt"), "Clean")
    git_run(path, ["add", "."])
    git_run(path, ["commit", "-m", "Clean feat"])
    {feat_sha, _} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    feat_sha = String.trim(feat_sha)

    # Go back to main
    git_run(path, ["checkout", "main"])
    {main_sha, _} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    main_sha = String.trim(main_sha)

    node_main = PhyloGraphNode.new(path, main_sha)
    node_feat = PhyloGraphNode.new(path, feat_sha)

    {:ok, new_node} = PhyloGraphNode.crossover(node_main, node_feat)

    assert new_node.current_commit != main_sha
    assert File.exists?(Path.join(path, "clean.txt"))
  end
end
