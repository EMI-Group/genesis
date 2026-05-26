defmodule EvoGit.Agent.Tools.SharedTest do
  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.Shared

  describe "normalize_relpath/1" do
    test "normalizes bare path to ./ prefix" do
      assert Shared.normalize_relpath("foo/bar") == "./foo/bar"
    end

    test "keeps ./-prefixed path as-is" do
      assert Shared.normalize_relpath("./foo/bar") == "./foo/bar"
    end

    test "normalizes empty string to ./" do
      assert Shared.normalize_relpath("") == "./"
    end

    test "normalizes dot to ./" do
      assert Shared.normalize_relpath(".") == "./"
    end

    test "raises on absolute paths" do
      assert_raise RuntimeError, ~r/absolute/, fn ->
        Shared.normalize_relpath("/etc/passwd")
      end
    end

    test "strips trailing slashes" do
      assert Shared.normalize_relpath("foo/") == "./foo"
    end

    test "handles single segment" do
      assert Shared.normalize_relpath("lib") == "./lib"
    end

    test "handles root path ./" do
      assert Shared.normalize_relpath("./") == "./"
    end
  end

  describe "is_child_or_same_node?/2" do
    test "root encompasses everything" do
      assert Shared.is_child_or_same_node?("./", "./foo/bar") == true
    end

    test "same path matches" do
      assert Shared.is_child_or_same_node?("./foo", "./foo") == true
    end

    test "child matches parent" do
      assert Shared.is_child_or_same_node?("./foo", "./foo/bar") == true
    end

    test "sibling does not match" do
      assert Shared.is_child_or_same_node?("./foo", "./bar") == false
    end

    test "parent does not match child" do
      assert Shared.is_child_or_same_node?("./foo/bar", "./foo") == false
    end

    test "root matches root" do
      assert Shared.is_child_or_same_node?("./", "./") == true
    end
  end

  describe "validate_file_scope/3" do
    test "allows file within node" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/lib/app.ex"
      assert Shared.validate_file_scope(expanded, "./lib", repo_path) == :ok
    end

    test "allows file at node root" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/lib/app.ex"
      assert Shared.validate_file_scope(expanded, "./lib", repo_path) == :ok
    end

    test "rejects file outside node" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/test/app_test.exs"
      result = Shared.validate_file_scope(expanded, "./lib", repo_path)
      assert {:error, _msg} = result
    end

    test "allows any file when node_path is nil" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/any/path.ex"
      assert Shared.validate_file_scope(expanded, nil, repo_path) == :ok
    end
  end
end
