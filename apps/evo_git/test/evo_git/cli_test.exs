defmodule EvoGit.CLITest do
  use ExUnit.Case, async: true

  describe "foreign repo parsing" do
    test "parses name:path format" do
      opts = [foreign_repo: "original:/Source/original-proj"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 1
      repo = hd(repos)
      assert repo.id == :original
      assert repo.root == Path.expand("/Source/original-proj")
      assert repo.name == "original"
    end

    test "parses path-only format (uses basename as id)" do
      opts = [foreign_repo: "/Source/my-project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 1
      repo = hd(repos)
      assert repo.id == :"my-project"
      assert repo.root == Path.expand("/Source/my-project")
    end

    test "parses multiple -R flags" do
      opts = [foreign_repo: "original:/Source/a", foreign_repo: "reference:/Source/b"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 2
      ids = Enum.map(repos, & &1.id) |> Enum.sort()
      assert ids == [:original, :reference]
    end

    test "returns empty list when no -R flags" do
      opts = []
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)
      assert repos == []
    end

    test "handles name with underscores" do
      opts = [foreign_repo: "my_repo:/Source/project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      repo = hd(repos)
      assert repo.id == :my_repo
    end

    test "handles path with nested directories" do
      opts = [foreign_repo: "proj:/Source/deep/nested/project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      repo = hd(repos)
      assert repo.root == Path.expand("/Source/deep/nested/project")
    end

    test "mixed formats: some with name, some without" do
      opts = [foreign_repo: "original:/Source/a", foreign_repo: "/Source/b-project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 2

      original = Enum.find(repos, &(&1.id == :original))
      assert original.root == Path.expand("/Source/a")

      basename = Enum.find(repos, &(&1.id == :"b-project"))
      assert basename.root == Path.expand("/Source/b-project")
    end
  end
end
