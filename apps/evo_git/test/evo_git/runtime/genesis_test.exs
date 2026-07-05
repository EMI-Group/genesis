defmodule EvoGit.Runtime.GenesisTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Runtime.Helpers

  describe "new_codebase?/1 auto-detection" do
    test "returns true for a repo with only .gitignore and .genesis" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("evogit-genesis-new-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, ".gitignore"), "/.genesis\n")
      File.mkdir_p!(Path.join(tmp_dir, ".genesis"))

      assert Helpers.new_codebase?(tmp_dir) == true

      File.rm_rf!(tmp_dir)
    end

    test "returns true for a completely empty directory" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("evogit-genesis-empty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      assert Helpers.new_codebase?(tmp_dir) == true

      File.rm_rf!(tmp_dir)
    end

    test "returns false when real source files are present" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("evogit-genesis-files-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, ".gitignore"), "/.genesis\n")
      File.write!(Path.join(tmp_dir, "main.py"), "print('hello')")

      assert Helpers.new_codebase?(tmp_dir) == false

      File.rm_rf!(tmp_dir)
    end

    test "returns true for a repo with .gitignore, .genesis, and README.md" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("evogit-genesis-readme-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, ".gitignore"), "/.genesis\n")
      File.mkdir_p!(Path.join(tmp_dir, ".genesis"))
      File.write!(Path.join(tmp_dir, "README.md"), "# Project")

      assert Helpers.new_codebase?(tmp_dir) == true

      File.rm_rf!(tmp_dir)
    end
  end

  describe "model_id threading through AgentSpec" do
    test "AgentSpec.new/5 stores model_id in opts when provided" do
      context_node = %ContextNode{path: "./", repo: "/tmp/fake"}
      phylo_node = %PhyloGraphNode{repo: "/tmp/fake", base_commit: "abc", current_commit: "abc"}

      spec =
        AgentSpec.new(context_node, phylo_node, SomeAgent, "do thing",
          model_id: "fast"
        )

      assert spec.opts[:model_id] == "fast"
    end

    test "AgentSpec.new/5 defaults model_id to nil when not provided" do
      context_node = %ContextNode{path: "./", repo: "/tmp/fake"}
      phylo_node = %PhyloGraphNode{repo: "/tmp/fake", base_commit: "abc", current_commit: "abc"}

      spec =
        AgentSpec.new(context_node, phylo_node, SomeAgent, "do thing",
          foreign_repos: []
        )

      assert spec.opts[:model_id] == nil
    end
  end
end
