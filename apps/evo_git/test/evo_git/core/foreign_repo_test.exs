defmodule EvoGit.Core.ForeignRepoTest do
  use ExUnit.Case, async: true
  alias EvoGit.Core.ForeignRepo

  describe "new/3" do
    test "creates a ForeignRepo with expanded root path" do
      repo = ForeignRepo.new("test", "/tmp/test-repo")
      assert repo.id == "test"
      assert repo.root == Path.expand("/tmp/test-repo")
      assert repo.description == nil
    end

    test "accepts custom description" do
      repo = ForeignRepo.new("orig", "/tmp/orig", description: "The original project")
      assert repo.description == "The original project"
    end

    test "defaults description to nil" do
      repo = ForeignRepo.new("my_repo", "/tmp/my")
      assert repo.description == nil
    end

    test "defaults writable to false and base_sha to nil" do
      repo = ForeignRepo.new("orig", "/tmp/orig")
      assert repo.writable == false
      assert repo.base_sha == nil
    end

    test "accepts writable: true and base_sha opts" do
      repo = ForeignRepo.new("orig", "/tmp/orig", writable: true, base_sha: "abc123")
      assert repo.writable == true
      assert repo.base_sha == "abc123"
    end

    test "coerces non-boolean writable to false" do
      assert ForeignRepo.new("a", "/tmp/a", writable: "yes").writable == false
      assert ForeignRepo.new("a", "/tmp/a", writable: 1).writable == false
      assert ForeignRepo.new("a", "/tmp/a", writable: nil).writable == false
    end

    test "coerces blank base_sha to nil" do
      assert ForeignRepo.new("a", "/tmp/a", base_sha: "").base_sha == nil
      assert ForeignRepo.new("a", "/tmp/a", base_sha: "   ").base_sha == nil
      assert ForeignRepo.new("a", "/tmp/a", base_sha: nil).base_sha == nil
    end

    test "expands relative paths via Path.expand" do
      repo = ForeignRepo.new("test", "/tmp/evo_git_test")
      assert repo.root == Path.expand("/tmp/evo_git_test")
    end

    test "preserves a forward-slash UNC root (WSL-shared-folder style)" do
      repo = ForeignRepo.new("primary", "//wsl.localhost/Ubuntu-22.04/home/user/proj")
      assert repo.root == "//wsl.localhost/Ubuntu-22.04/home/user/proj"
    end

    test "preserves a backslash UNC root" do
      repo = ForeignRepo.new("primary", "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\proj")

      # The double-separator marker must never collapse to a single one.
      assert String.starts_with?(repo.root, "\\\\")
      refute String.starts_with?(repo.root, "\\wsl")
      refute String.starts_with?(repo.root, "/wsl")
      assert repo.root =~ "wsl.localhost"
      assert repo.root =~ "Ubuntu-22.04"
      assert repo.root =~ "home"
    end
  end

  describe "normalize/1" do
    test "passes ForeignRepo structs through unchanged" do
      repo = %ForeignRepo{id: "a", root: "/abs/a", description: "desc"}
      assert ForeignRepo.normalize(repo) == repo
    end

    test "converts atom-keyed maps" do
      assert %ForeignRepo{id: "a", root: "/abs/a", description: "desc"} =
               ForeignRepo.normalize(%{id: "a", root: "/abs/a", description: "desc"})
    end

    test "converts string-keyed maps" do
      assert %ForeignRepo{id: "a", root: "/abs/a", description: "desc"} =
               ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/a", "description" => "desc"})
    end

    test "preserves writable and base_sha from string-keyed maps" do
      assert %ForeignRepo{
               id: "a",
               root: "/abs/a",
               description: "desc",
               writable: true,
               base_sha: "abc123"
             } =
               ForeignRepo.normalize(%{
                 "id" => "a",
                 "root" => "/abs/a",
                 "description" => "desc",
                 "writable" => true,
                 "base_sha" => "abc123"
               })
    end

    test "preserves writable and base_sha from atom-keyed maps" do
      assert %ForeignRepo{id: "a", root: "/abs/a", writable: true, base_sha: "abc123"} =
               ForeignRepo.normalize(%{
                 id: "a",
                 root: "/abs/a",
                 writable: true,
                 base_sha: "abc123"
               })
    end

    test "defaults writable to false and base_sha to nil when keys are missing" do
      assert %ForeignRepo{id: "a", root: "/abs/a", writable: false, base_sha: nil} =
               ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/a"})

      assert %ForeignRepo{id: "a", root: "/abs/a", writable: false, base_sha: nil} =
               ForeignRepo.normalize(%{id: "a", root: "/abs/a"})
    end

    test "uses the \"path\" key as a root fallback" do
      assert %ForeignRepo{id: "a", root: "/abs/a", description: nil} =
               ForeignRepo.normalize(%{"id" => "a", "path" => "/abs/a"})
    end

    test "uses the :path key as a root fallback" do
      assert %ForeignRepo{id: "a", root: "/abs/a", description: nil} =
               ForeignRepo.normalize(%{id: "a", path: "/abs/a"})
    end

    test "prefers \"root\" over \"path\" when both are present" do
      assert %ForeignRepo{id: "a", root: "/abs/root"} =
               ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/root", "path" => "/abs/path"})
    end

    test "defaults description to nil when absent or empty" do
      assert %ForeignRepo{description: nil} =
               ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/a"})

      assert %ForeignRepo{description: nil} =
               ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/a", "description" => ""})
    end

    test "expands the root path via new/3" do
      assert %ForeignRepo{root: root} =
               ForeignRepo.normalize(%{"id" => "a", "root" => "/abs/../abs/a"})

      assert root == Path.expand("/abs/../abs/a")
    end

    test "returns nil for non-map input" do
      assert ForeignRepo.normalize(nil) == nil
      assert ForeignRepo.normalize("not-a-repo") == nil
      assert ForeignRepo.normalize([:a]) == nil
    end

    test "returns nil when id is missing or blank" do
      assert ForeignRepo.normalize(%{"root" => "/abs/a"}) == nil
      assert ForeignRepo.normalize(%{"id" => "", "root" => "/abs/a"}) == nil
      assert ForeignRepo.normalize(%{root: "/abs/a"}) == nil
    end

    test "returns nil when no root or path key exists" do
      assert ForeignRepo.normalize(%{"id" => "a"}) == nil
      assert ForeignRepo.normalize(%{"id" => "a", "description" => "desc"}) == nil
      assert ForeignRepo.normalize(%{"id" => "a", "root" => ""}) == nil
    end
  end

  describe "primary_id/0" do
    test "returns \"primary\"" do
      assert ForeignRepo.primary_id() == "primary"
    end
  end

  describe "primary?/1" do
    test "returns true for \"primary\"" do
      assert ForeignRepo.primary?("primary")
    end

    test "returns false for other strings" do
      refute ForeignRepo.primary?("foreign")
      refute ForeignRepo.primary?("original")
    end
  end

  describe "absolute_path?/1" do
    test "returns true for absolute paths" do
      assert ForeignRepo.absolute_path?("/Source/proj/src")
      assert ForeignRepo.absolute_path?("/")
    end

    test "returns true for Windows absolute paths" do
      assert ForeignRepo.absolute_path?("C:\\Source\\proj")
      assert ForeignRepo.absolute_path?("D:/Source/proj")
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
      repo = ForeignRepo.new("test", "/Source/proj")
      assert {:ok, "./src/lib.rs"} = ForeignRepo.normalize_path(repo, "/Source/proj/src/lib.rs")
    end

    test "returns error for path outside repo" do
      repo = ForeignRepo.new("test", "/Source/proj")
      assert {:error, :not_in_repo} = ForeignRepo.normalize_path(repo, "/Other/path")
    end

    test "handles repo root itself" do
      repo = ForeignRepo.new("test", "/Source/proj")
      assert {:ok, "./"} = ForeignRepo.normalize_path(repo, "/Source/proj")
    end

    test "handles deeply nested paths" do
      repo = ForeignRepo.new("test", "/Source/proj")

      assert {:ok, "./a/b/c/d/e.ex"} =
               ForeignRepo.normalize_path(repo, "/Source/proj/a/b/c/d/e.ex")
    end

    test "does not match partial prefix" do
      repo = ForeignRepo.new("test", "/Source/proj")

      assert {:error, :not_in_repo} =
               ForeignRepo.normalize_path(repo, "/Source/project-other/file.ex")
    end

    test "handles path with trailing slash" do
      repo = ForeignRepo.new("test", "/Source/proj")
      # normalize_relative trims trailing slashes
      assert {:ok, "./src"} = ForeignRepo.normalize_path(repo, "/Source/proj/src/")
    end

    test "handles path with parent directory segments" do
      repo = ForeignRepo.new("test", "/Source/proj")
      # Path.expand resolves .. segments, so the result is the resolved path
      assert {:ok, "./lib/app.ex"} =
               ForeignRepo.normalize_path(repo, "/Source/proj/src/../lib/app.ex")
    end

    test "handles empty string path" do
      repo = ForeignRepo.new("test", "/Source/proj")
      assert {:error, :not_in_repo} = ForeignRepo.normalize_path(repo, "")
    end
  end

  describe "resolve_path/2" do
    test "finds correct repo for absolute path" do
      repos = [
        ForeignRepo.new("primary", "/Source/proj"),
        ForeignRepo.new("original", "/Source/original-proj")
      ]

      assert {:ok, "original", "./src/main.py"} =
               ForeignRepo.resolve_path(repos, "/Source/original-proj/src/main.py")
    end

    test "returns error for unknown paths" do
      repos = [ForeignRepo.new("primary", "/Source/proj")]
      assert {:error, :not_in_any_repo} = ForeignRepo.resolve_path(repos, "/unknown/path")
    end

    test "resolves to primary repo" do
      repos = [ForeignRepo.new("primary", "/Source/proj")]

      assert {:ok, "primary", "./lib/app.ex"} =
               ForeignRepo.resolve_path(repos, "/Source/proj/lib/app.ex")
    end

    test "with multiple repos, returns correct one" do
      repos = [
        ForeignRepo.new("primary", "/Source/rust-proj"),
        ForeignRepo.new("original", "/Source/original-proj"),
        ForeignRepo.new("reference", "/Source/reference-proj")
      ]

      assert {:ok, "reference", "./README.md"} =
               ForeignRepo.resolve_path(repos, "/Source/reference-proj/README.md")
    end

    test "foreign repos take precedence over primary" do
      repos = [
        ForeignRepo.new("primary", "/Source/proj"),
        ForeignRepo.new("fork", "/Source/proj-fork")
      ]

      assert {:ok, "fork", "./lib/app.ex"} =
               ForeignRepo.resolve_path(repos, "/Source/proj-fork/lib/app.ex")
    end

    test "returns error for empty repo list" do
      assert {:error, :not_in_any_repo} = ForeignRepo.resolve_path([], "/Source/any/file.ex")
    end

    test "disambiguates overlapping repo paths" do
      repos = [
        ForeignRepo.new("short", "/Source/proj"),
        ForeignRepo.new("long", "/Source/proj-extended")
      ]

      # Path under the longer repo should NOT match the shorter one
      assert {:ok, "long", "./lib/app.ex"} =
               ForeignRepo.resolve_path(repos, "/Source/proj-extended/lib/app.ex")
    end

    test "resolves repo root to ./" do
      repos = [ForeignRepo.new("primary", "/Source/proj")]
      assert {:ok, "primary", "./"} = ForeignRepo.resolve_path(repos, "/Source/proj")
    end

    test "resolves UNC-rooted repos by id" do
      repos = [
        ForeignRepo.new("primary", "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo"),
        ForeignRepo.new("original", "//wsl.localhost/Ubuntu-22.04/home/user/original-proj")
      ]

      assert {:ok, "original", "./src/main.py"} =
               ForeignRepo.resolve_path(
                 repos,
                 "//wsl.localhost/Ubuntu-22.04/home/user/original-proj/src/main.py"
               )

      assert {:ok, "primary", "./lib/app.ex"} =
               ForeignRepo.resolve_path(
                 repos,
                 "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo/lib/app.ex"
               )
    end

    test "resolves deeply nested path" do
      repos = [ForeignRepo.new("primary", "/Source/proj")]

      assert {:ok, "primary", "./a/b/c/d/e/f/g/h.ex"} =
               ForeignRepo.resolve_path(repos, "/Source/proj/a/b/c/d/e/f/g/h.ex")
    end

    test "resolves paths in all registered repos" do
      repos = [
        ForeignRepo.new("primary", "/Source/proj-a"),
        ForeignRepo.new("secondary", "/Source/proj-b"),
        ForeignRepo.new("tertiary", "/Source/proj-c")
      ]

      assert {:ok, "primary", "./README.md"} =
               ForeignRepo.resolve_path(repos, "/Source/proj-a/README.md")

      assert {:ok, "secondary", "./README.md"} =
               ForeignRepo.resolve_path(repos, "/Source/proj-b/README.md")

      assert {:ok, "tertiary", "./README.md"} =
               ForeignRepo.resolve_path(repos, "/Source/proj-c/README.md")
    end
  end

  describe "Jason encode/decode round trip (Store codec path)" do
    test "preserves writable and base_sha" do
      repo = ForeignRepo.new("orig", "/tmp/orig", writable: true, base_sha: "abc123")
      assert repo |> Jason.encode!() |> Jason.decode!() |> ForeignRepo.normalize() == repo
    end

    test "round trips defaults (writable false, base_sha nil)" do
      repo = ForeignRepo.new("orig", "/tmp/orig")
      assert repo |> Jason.encode!() |> Jason.decode!() |> ForeignRepo.normalize() == repo
    end
  end
end
