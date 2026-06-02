defmodule EvoGit.Core.ForeignRepoTest do
  use ExUnit.Case, async: true
  alias EvoGit.Core.ForeignRepo

  describe "new/3" do
    test "creates a ForeignRepo with expanded root path" do
      repo = ForeignRepo.new(:test, "/tmp/test-repo")
      assert repo.id == :test
      assert repo.root == Path.expand("/tmp/test-repo")
      assert repo.name == "test"
    end

    test "accepts custom name" do
      repo = ForeignRepo.new(:orig, "/tmp/orig", name: "Original Project")
      assert repo.name == "Original Project"
    end

    test "defaults name to stringified id" do
      repo = ForeignRepo.new(:my_repo, "/tmp/my")
      assert repo.name == "my_repo"
    end

    test "expands relative paths via Path.expand" do
      repo = ForeignRepo.new(:test, "/tmp/evo_git_test")
      assert repo.root == Path.expand("/tmp/evo_git_test")
    end
  end

  describe "primary_id/0" do
    test "returns :primary" do
      assert ForeignRepo.primary_id() == :primary
    end
  end

  describe "primary?/1" do
    test "returns true for :primary" do
      assert ForeignRepo.primary?(:primary)
    end

    test "returns false for other atoms" do
      refute ForeignRepo.primary?(:foreign)
      refute ForeignRepo.primary?(:original)
    end
  end

  describe "absolute_path?/1" do
    test "returns true for absolute paths" do
      assert ForeignRepo.absolute_path?("/Source/proj/src")
      assert ForeignRepo.absolute_path?("/")
    end

    test "returns false for relative paths" do
      refute ForeignRepo.absolute_path?("./src")
      refute ForeignRepo.absolute_path?("src/main.ex")
      refute ForeignRepo.absolute_path?("lib/app.ex")
    end

    test "returns false for nil" do
      refute ForeignRepo.absolute_path?(nil)
    end

    test "returns false for empty string" do
      refute ForeignRepo.absolute_path?("")
    end
  end

  describe "normalize_path/2" do
    test "converts absolute path to relative within repo" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      assert {:ok, "./src/lib.rs"} = ForeignRepo.normalize_path(repo, "/Source/proj/src/lib.rs")
    end

    test "returns error for path outside repo" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      assert {:error, :not_in_repo} = ForeignRepo.normalize_path(repo, "/Other/path")
    end

    test "handles repo root itself" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      assert {:ok, "./"} = ForeignRepo.normalize_path(repo, "/Source/proj")
    end

    test "handles deeply nested paths" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      assert {:ok, "./a/b/c/d/e.ex"} =
               ForeignRepo.normalize_path(repo, "/Source/proj/a/b/c/d/e.ex")
    end

    test "does not match partial prefix" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      assert {:error, :not_in_repo} =
               ForeignRepo.normalize_path(repo, "/Source/project-other/file.ex")
    end

    test "handles path with trailing slash" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      # normalize_relative trims trailing slashes
      assert {:ok, "./src"} = ForeignRepo.normalize_path(repo, "/Source/proj/src/")
    end

    test "handles path with parent directory segments" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      # Path.expand resolves .. segments, so the result is the resolved path
      assert {:ok, "./lib/app.ex"} = ForeignRepo.normalize_path(repo, "/Source/proj/src/../lib/app.ex")
    end

    test "handles empty string path" do
      repo = ForeignRepo.new(:test, "/Source/proj")
      assert {:error, :not_in_repo} = ForeignRepo.normalize_path(repo, "")
    end
  end

  describe "resolve_path/2" do
    test "finds correct repo for absolute path" do
      repos = [
        ForeignRepo.new(:primary, "/Source/proj"),
        ForeignRepo.new(:original, "/Source/original-proj")
      ]

      assert {:ok, :original, "./src/main.py"} =
               ForeignRepo.resolve_path(repos, "/Source/original-proj/src/main.py")
    end

    test "returns error for unknown paths" do
      repos = [ForeignRepo.new(:primary, "/Source/proj")]
      assert {:error, :not_in_any_repo} = ForeignRepo.resolve_path(repos, "/unknown/path")
    end

    test "resolves to primary repo" do
      repos = [ForeignRepo.new(:primary, "/Source/proj")]
      assert {:ok, :primary, "./lib/app.ex"} = ForeignRepo.resolve_path(repos, "/Source/proj/lib/app.ex")
    end

    test "with multiple repos, returns correct one" do
      repos = [
        ForeignRepo.new(:primary, "/Source/rust-proj"),
        ForeignRepo.new(:original, "/Source/original-proj"),
        ForeignRepo.new(:reference, "/Source/reference-proj")
      ]

      assert {:ok, :reference, "./README.md"} =
               ForeignRepo.resolve_path(repos, "/Source/reference-proj/README.md")
    end

    test "foreign repos take precedence over primary" do
      repos = [
        ForeignRepo.new(:primary, "/Source/proj"),
        ForeignRepo.new(:fork, "/Source/proj-fork")
      ]

      assert {:ok, :fork, "./lib/app.ex"} =
               ForeignRepo.resolve_path(repos, "/Source/proj-fork/lib/app.ex")
    end

    test "returns error for empty repo list" do
      assert {:error, :not_in_any_repo} = ForeignRepo.resolve_path([], "/Source/any/file.ex")
    end

    test "disambiguates overlapping repo paths" do
      repos = [
        ForeignRepo.new(:short, "/Source/proj"),
        ForeignRepo.new(:long, "/Source/proj-extended")
      ]
      # Path under the longer repo should NOT match the shorter one
      assert {:ok, :long, "./lib/app.ex"} = ForeignRepo.resolve_path(repos, "/Source/proj-extended/lib/app.ex")
    end

    test "resolves repo root to ./" do
      repos = [ForeignRepo.new(:primary, "/Source/proj")]
      assert {:ok, :primary, "./"} = ForeignRepo.resolve_path(repos, "/Source/proj")
    end

    test "resolves deeply nested path" do
      repos = [ForeignRepo.new(:primary, "/Source/proj")]
      assert {:ok, :primary, "./a/b/c/d/e/f/g/h.ex"} =
               ForeignRepo.resolve_path(repos, "/Source/proj/a/b/c/d/e/f/g/h.ex")
    end

    test "resolves paths in all registered repos" do
      repos = [
        ForeignRepo.new(:primary, "/Source/proj-a"),
        ForeignRepo.new(:secondary, "/Source/proj-b"),
        ForeignRepo.new(:tertiary, "/Source/proj-c")
      ]

      assert {:ok, :primary, "./README.md"} = ForeignRepo.resolve_path(repos, "/Source/proj-a/README.md")
      assert {:ok, :secondary, "./README.md"} = ForeignRepo.resolve_path(repos, "/Source/proj-b/README.md")
      assert {:ok, :tertiary, "./README.md"} = ForeignRepo.resolve_path(repos, "/Source/proj-c/README.md")
    end
  end
end
