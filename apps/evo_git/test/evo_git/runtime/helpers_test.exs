defmodule EvoGit.Runtime.HelpersTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Runtime.Helpers
  alias EvoGit.Store.Codec

  # --------------------------------------------------------------------------
  # Shared temp git-repo setup (mirrors test/evo_git/adapters/git_test.exs)
  # --------------------------------------------------------------------------
  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_helpers_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    Git.init(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  # Creates a fresh temp git repo with one commit and returns its absolute
  # path. `Path.expand/1` mirrors `ForeignRepo.new/3` normalization so equality
  # assertions against parsed TOML entries hold on all platforms (e.g. macOS
  # /var -> /private/var symlink). Cleaned up via on_exit.
  defp make_git_repo!(label) do
    dir =
      Path.expand(
        Path.join(
          System.tmp_dir!(),
          "evogit_helpers_fr_#{label}_#{System.unique_integer()}"
        )
      )

    File.mkdir_p!(dir)
    Git.init(dir)
    File.write!(Path.join(dir, "file.txt"), "content")
    {:ok, _} = Git.add(dir, "file.txt")
    {:ok, _} = Git.commit(dir, "Initial commit")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Sets up the standard "primary repo with agent changes" shape used by the
  # merge_and_report tests: two commits, HEAD reset back to the first so the
  # repo's base differs from the agent's final_sha. Returns {final_sha, base_sha}.
  defp setup_primary_with_changes!(tmp_dir) do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial")
    {:ok, _} = Git.add(tmp_dir, "test.txt")
    {:ok, _} = Git.commit(tmp_dir, "Initial commit")

    File.write!(Path.join(tmp_dir, "test.txt"), "updated")
    {:ok, _} = Git.add(tmp_dir, "test.txt")
    {:ok, _} = Git.commit(tmp_dir, "Second commit")
    {:ok, final_sha} = Git.rev_parse(tmp_dir)

    assert match?({:ok, _}, Git.reset_hard(tmp_dir, "HEAD~1"))
    {:ok, base_sha} = Git.rev_parse(tmp_dir)
    refute base_sha == final_sha

    {final_sha, base_sha}
  end

  # ==========================================================================
  # generate_branch_name/1
  # ==========================================================================
  describe "generate_branch_name/1" do
    test "starts with the expected prefix" do
      name = Helpers.generate_branch_name("genesis")

      assert String.starts_with?(name, "genesis/agent_")
    end

    test "suffix after the last underscore is exactly 8 lowercase hex chars" do
      name = Helpers.generate_branch_name("evolve")
      suffix = name |> String.split("_") |> List.last()

      assert Regex.match?(~r/^[0-9a-f]{8}$/, suffix)
    end

    test "two calls produce different names (randomness)" do
      name1 = Helpers.generate_branch_name("genesis")
      name2 = Helpers.generate_branch_name("genesis")

      refute name1 == name2
    end

    test "does not contain the legacy evogit namespace" do
      name = Helpers.generate_branch_name("genesis")

      refute String.contains?(name, "evogit")
    end
  end

  # ==========================================================================
  # new_codebase?/1
  #
  # NOTE: The bulk of new_codebase?/1 behavior is covered in
  # genesis_test.exs. Here we only add a couple of edge cases.
  # ==========================================================================
  describe "new_codebase?/1 edge cases" do
    test "returns false for a directory containing an unknown subdirectory" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "evogit_helpers_test_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(Path.join(tmp_dir, "some_pkg"))

      assert Helpers.new_codebase?(tmp_dir) == false

      File.rm_rf!(tmp_dir)
    end

    test "returns true for a nonexistent directory" do
      nonexistent =
        Path.join(
          System.tmp_dir!(),
          "evogit_helpers_test_nonexistent_" <> to_string(System.unique_integer())
        )

      assert Helpers.new_codebase?(nonexistent) == true
    end
  end

  # ==========================================================================
  # validate_node_path/2
  # ==========================================================================
  describe "validate_node_path/2" do
    test "\"./\" always returns :ok", %{tmp_dir: tmp_dir} do
      assert :ok = Helpers.validate_node_path("./", tmp_dir)
    end

    test "an absolute path returns an error mentioning \"absolute path\"", %{
      tmp_dir: tmp_dir
    } do
      abs_path = Path.join(tmp_dir, "lib")

      assert {:error, {:invalid_node_path, msg}} =
               Helpers.validate_node_path(abs_path, tmp_dir)

      assert String.contains?(msg, "absolute path")
    end

    test "a relative path to a non-existent directory returns an error mentioning \"Directory does not exist\"",
         %{tmp_dir: tmp_dir} do
      assert {:error, {:invalid_node_path, msg}} =
               Helpers.validate_node_path("./does_not_exist", tmp_dir)

      assert String.contains?(msg, "Directory does not exist")
    end

    test "a relative path to a directory without CONTEXT.md returns an error mentioning \"No CONTEXT.md found\"",
         %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "no_context"))

      assert {:error, {:invalid_node_path, msg}} =
               Helpers.validate_node_path("./no_context", tmp_dir)

      assert String.contains?(msg, "No CONTEXT.md found")
    end

    test "a relative path to a directory with CONTEXT.md returns :ok", %{
      tmp_dir: tmp_dir
    } do
      dir = Path.join(tmp_dir, "with_context")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "CONTEXT.md"), "# Context")

      assert :ok = Helpers.validate_node_path("./with_context", tmp_dir)
    end
  end

  # ==========================================================================
  # resolve_starting_commit/2
  # ==========================================================================
  describe "resolve_starting_commit/2" do
    test "with nil returns the current HEAD sha", %{tmp_dir: tmp_dir} do
      # Create at least one commit so HEAD resolves
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      {:ok, head_sha} = Git.rev_parse(tmp_dir)

      assert {:ok, ^head_sha} = Helpers.resolve_starting_commit(tmp_dir, nil)
    end

    test "with \"HEAD\" returns the current HEAD sha", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      {:ok, head_sha} = Git.rev_parse(tmp_dir)

      assert {:ok, ^head_sha} = Helpers.resolve_starting_commit(tmp_dir, "HEAD")
    end

    test "with a nonexistent ref returns an error tuple", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      result = Helpers.resolve_starting_commit(tmp_dir, "nonexistent-branch")

      # Must be an error, never {:ok, _}
      refute match?({:ok, _}, result)
    end
  end

  # ==========================================================================
  # notify_finalizing/1
  # ==========================================================================
  describe "notify_finalizing/1" do
    test "does not crash with a task_id string" do
      assert Helpers.notify_finalizing("t123") in [:ok, nil]
    end

    test "does not crash with nil" do
      assert Helpers.notify_finalizing(nil) in [:ok, nil]
    end
  end

  # ==========================================================================
  # merge_and_report/3
  # ==========================================================================
  describe "merge_and_report/3" do
    test "returns no_changes: true with nil branch_name when commit_sha is nil", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      agent_output = %Result{
        commit_sha: nil,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1
      }

      assert {:ok, report} = Helpers.merge_and_report(tmp_dir, agent_output, "genesis")
      assert report.no_changes == true
      assert report.branch_name == nil
    end

    test "returns no_changes: true when commit_sha equals the base (HEAD) sha", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      {:ok, base_sha} = Git.rev_parse(tmp_dir)

      agent_output = %Result{
        commit_sha: base_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1
      }

      assert {:ok, report} = Helpers.merge_and_report(tmp_dir, agent_output, "genesis")
      assert report.no_changes == true
      assert report.branch_name == nil
    end

    test "returns a genesis branch name when commit_sha differs from base", %{
      tmp_dir: tmp_dir
    } do
      # First (base) commit
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")

      # Second commit — produces a different sha that the "agent" will have produced
      File.write!(Path.join(tmp_dir, "test.txt"), "updated")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Second commit")

      {:ok, final_sha} = Git.rev_parse(tmp_dir)

      # The agent's worktree is separate from this repo. merge_and_report compares
      # the agent's commit_sha against the repo's current HEAD (base_sha), so we
      # reset HEAD back to the first commit to make final_sha differ from base.
      assert match?({:ok, _}, Git.reset_hard(tmp_dir, "HEAD~1"))
      {:ok, base_sha} = Git.rev_parse(tmp_dir)
      refute base_sha == final_sha

      agent_output = %Result{
        commit_sha: final_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1
      }

      assert {:ok, report} = Helpers.merge_and_report(tmp_dir, agent_output, "genesis")
      branch_name = report.branch_name

      assert branch_name != nil
      assert String.starts_with?(branch_name, "genesis/agent_")

      suffix = branch_name |> String.split("_") |> List.last()
      assert Regex.match?(~r/^[0-9a-f]{8}$/, suffix)
    end
  end

  # ==========================================================================
  # merge_and_report/4
  # ==========================================================================
  describe "merge_and_report/4" do
    test "creates one shared branch in the primary and writable foreign repos", %{
      tmp_dir: tmp_dir
    } do
      {final_sha, _base_sha} = setup_primary_with_changes!(tmp_dir)

      fid_root = make_git_repo!("fid")
      {:ok, foreign_sha} = Git.rev_parse(fid_root)

      agent_output = %Result{
        commit_sha: final_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1,
        foreign_repo_commits: %{"fid" => foreign_sha}
      }

      foreign_repos = [%ForeignRepo{id: "fid", root: fid_root, writable: true}]

      assert {:ok, report} =
               Helpers.merge_and_report(tmp_dir, agent_output, "genesis", foreign_repos)

      branch = report.branch_name
      assert branch != nil
      assert String.starts_with?(branch, "genesis/agent_")

      # ONE branch name reused across BOTH repos
      assert Git.branch_exists?(tmp_dir, branch)
      assert Git.branch_exists?(fid_root, branch)

      # Top-level commit_sha/branch_name remain the PRIMARY's values
      assert report.commit_sha == final_sha
      assert report.branch_name == branch

      assert report.repos == %{
               "primary" => %{commit_sha: final_sha, branch_name: branch},
               "fid" => %{commit_sha: foreign_sha, branch_name: branch}
             }
    end

    test "writable foreign branch creation does not move the foreign main working-copy HEAD", %{
      tmp_dir: tmp_dir
    } do
      {final_sha, _base_sha} = setup_primary_with_changes!(tmp_dir)

      # Foreign repo with TWO commits on its default branch (requirement d
      # scenario), then main reset back to the first commit so the second commit
      # is a "new" foreign commit NOT on main — the branch must point at it
      # WITHOUT checking it out or moving the main working copy.
      foreign_dir =
        Path.expand(
          Path.join(System.tmp_dir!(), "evogit_helpers_fr_main_#{System.unique_integer()}")
        )

      File.mkdir_p!(foreign_dir)
      Git.init(foreign_dir)
      File.write!(Path.join(foreign_dir, "file.txt"), "v1")
      {:ok, _} = Git.add(foreign_dir, "file.txt")
      {:ok, _} = Git.commit(foreign_dir, "First commit")
      File.write!(Path.join(foreign_dir, "file.txt"), "v2")
      {:ok, _} = Git.add(foreign_dir, "file.txt")
      {:ok, _} = Git.commit(foreign_dir, "Second commit")
      {:ok, foreign_new_sha} = Git.rev_parse(foreign_dir)

      assert match?({:ok, _}, Git.reset_hard(foreign_dir, "HEAD~1"))
      {:ok, main_head} = Git.rev_parse(foreign_dir)
      {:ok, original_branch} = Git.current_branch(foreign_dir)
      refute main_head == foreign_new_sha

      on_exit(fn -> File.rm_rf!(foreign_dir) end)

      agent_output = %Result{
        commit_sha: final_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1,
        foreign_repo_commits: %{"foreign" => foreign_new_sha}
      }

      foreign_repos = [%ForeignRepo{id: "foreign", root: foreign_dir, writable: true}]

      assert {:ok, report} =
               Helpers.merge_and_report(tmp_dir, agent_output, "evolve", foreign_repos)

      branch = report.branch_name
      assert branch != nil
      assert String.starts_with?(branch, "genesis/agent_")

      # The report carries the foreign entry under its string repo id
      assert report.repos["foreign"] == %{commit_sha: foreign_new_sha, branch_name: branch}

      # Requirement d — the branch create (git branch <name> <sha>) did NOT move
      # the foreign main working copy:
      # - HEAD is unchanged (still the original main HEAD)
      assert {:ok, ^main_head} = Git.rev_parse(foreign_dir)
      # - still on the original branch, not the new one
      assert {:ok, ^original_branch} = Git.current_branch(foreign_dir)
      refute original_branch == branch
      # - working tree is clean
      assert {:ok, ""} = Git.status(foreign_dir)
      # - the genesis/agent_* branch EXISTS and points at the foreign commit sha,
      #   but the main copy is NOT on it
      assert Git.branch_exists?(foreign_dir, branch)
      assert {:ok, ^foreign_new_sha} = Git.rev_parse(foreign_dir, branch)
    end

    test "read-only foreign repos produce no entry and no branch", %{tmp_dir: tmp_dir} do
      {final_sha, _base_sha} = setup_primary_with_changes!(tmp_dir)

      ro_root = make_git_repo!("ro")
      {:ok, ro_sha} = Git.rev_parse(ro_root)

      agent_output = %Result{
        commit_sha: final_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1,
        foreign_repo_commits: %{"ro" => ro_sha}
      }

      foreign_repos = [%ForeignRepo{id: "ro", root: ro_root, writable: false}]

      assert {:ok, report} =
               Helpers.merge_and_report(tmp_dir, agent_output, "genesis", foreign_repos)

      branch = report.branch_name
      assert branch != nil

      refute Map.has_key?(report.repos, "ro")
      assert report.repos == %{"primary" => %{commit_sha: final_sha, branch_name: branch}}
      refute Git.branch_exists?(ro_root, branch)
    end

    test "creates foreign branches when the primary produced no changes", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial")
      {:ok, _} = Git.add(tmp_dir, "test.txt")
      {:ok, _} = Git.commit(tmp_dir, "Initial commit")
      {:ok, base_sha} = Git.rev_parse(tmp_dir)

      fid_root = make_git_repo!("fid")
      {:ok, foreign_sha} = Git.rev_parse(fid_root)

      agent_output = %Result{
        commit_sha: base_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1,
        foreign_repo_commits: %{"fid" => foreign_sha}
      }

      foreign_repos = [%ForeignRepo{id: "fid", root: fid_root, writable: true}]

      assert {:ok, report} =
               Helpers.merge_and_report(tmp_dir, agent_output, "genesis", foreign_repos)

      assert report.no_changes == true
      assert report.branch_name == nil
      assert report.commit_sha == base_sha

      # The primary produced no branch; the writable foreign repo got one under
      # a freshly generated name.
      {:ok, branches} = Git.list_branches(fid_root)
      assert [branch] = Enum.filter(branches, &String.starts_with?(&1, "genesis/agent_"))

      assert report.repos == %{
               "primary" => %{commit_sha: base_sha, branch_name: nil},
               "fid" => %{commit_sha: foreign_sha, branch_name: branch}
             }
    end

    test "3-arity reports only the primary repo", %{tmp_dir: tmp_dir} do
      {final_sha, _base_sha} = setup_primary_with_changes!(tmp_dir)

      agent_output = %Result{
        commit_sha: final_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1
      }

      assert {:ok, report} = Helpers.merge_and_report(tmp_dir, agent_output, "genesis")
      branch = report.branch_name
      assert branch != nil

      assert report.repos == %{"primary" => %{commit_sha: final_sha, branch_name: branch}}
      assert report.commit_sha == final_sha
    end

    test "report.repos survives the Store.Codec round-trip with string keys", %{
      tmp_dir: tmp_dir
    } do
      {final_sha, _base_sha} = setup_primary_with_changes!(tmp_dir)

      fid_root = make_git_repo!("fid")
      {:ok, foreign_sha} = Git.rev_parse(fid_root)

      agent_output = %Result{
        commit_sha: final_sha,
        result: "test",
        tag: nil,
        usage: nil,
        agent_count: 1,
        foreign_repo_commits: %{"fid" => foreign_sha}
      }

      foreign_repos = [%ForeignRepo{id: "fid", root: fid_root, writable: true}]

      assert {:ok, report} =
               Helpers.merge_and_report(tmp_dir, agent_output, "genesis", foreign_repos)

      branch = report.branch_name

      encoded = Codec.encode_result({:ok, report})
      {:ok, decoded} = Codec.decode_result(encoded)

      # "repos" is not a known atomized field, so it stays a STRING key; the
      # per-repo inner maps round-trip with string keys too (JSON-safe).
      assert Map.get(decoded, "repos") == %{
               "primary" => %{"commit_sha" => final_sha, "branch_name" => branch},
               "fid" => %{"commit_sha" => foreign_sha, "branch_name" => branch}
             }
    end
  end

  # ==========================================================================
  # load_foreign_repos/2
  #
  # Every entry is validated UP FRONT: the root must exist AND be a git repo,
  # and a non-nil base_sha must resolve — otherwise an ArgumentError is raised
  # naming the id/path/problem (spec-error style, never a mid-run crash). All
  # tests therefore use REAL temp git repos (see make_git_repo!/1).
  # ==========================================================================
  describe "load_foreign_repos/2" do
    test "returns only the CLI-provided repo when no genesis.toml exists", %{
      tmp_dir: tmp_dir
    } do
      cli_root = make_git_repo!("cli1")
      cli_repo = %ForeignRepo{id: "cli1", root: cli_root}

      assert Helpers.load_foreign_repos(tmp_dir, foreign_repos: [cli_repo]) == [cli_repo]
    end

    test "returns the TOML-declared repo when opts has no :foreign_repos", %{
      tmp_dir: tmp_dir
    } do
      toml_root = make_git_repo!("toml1")

      File.write!(
        Path.join(tmp_dir, "genesis.toml"),
        """
        [foreign_repos.toml1]
        path = "#{toml_root}"
        description = "toml1 description"
        """
      )

      assert Helpers.load_foreign_repos(tmp_dir, []) == [
               %ForeignRepo{
                 id: "toml1",
                 root: toml_root,
                 description: "toml1 description"
               }
             ]
    end

    test "merges TOML and CLI repos when there is no id conflict", %{tmp_dir: tmp_dir} do
      toml1 = make_git_repo!("toml1")
      toml2 = make_git_repo!("toml2")
      cli1 = make_git_repo!("cli1")

      File.write!(
        Path.join(tmp_dir, "genesis.toml"),
        """
        [foreign_repos.toml1]
        path = "#{toml1}"

        [foreign_repos.toml2]
        path = "#{toml2}"
        description = "second toml repo"
        """
      )

      result =
        Helpers.load_foreign_repos(
          tmp_dir,
          foreign_repos: [%ForeignRepo{id: "cli1", root: cli1}]
        )

      assert length(result) == 3
      assert MapSet.new(Enum.map(result, & &1.id)) == MapSet.new(["toml1", "toml2", "cli1"])
    end

    test "CLI repo takes precedence over TOML repo on id conflict", %{tmp_dir: tmp_dir} do
      toml_shared = make_git_repo!("tomlshared")
      cli_shared = make_git_repo!("clishared")

      File.write!(
        Path.join(tmp_dir, "genesis.toml"),
        """
        [foreign_repos.shared]
        path = "#{toml_shared}"
        description = "toml shared repo"
        """
      )

      result =
        Helpers.load_foreign_repos(
          tmp_dir,
          foreign_repos: [%ForeignRepo{id: "shared", root: cli_shared}]
        )

      assert length(result) == 1
      shared = Enum.find(result, &(&1.id == "shared"))
      assert shared.root == cli_shared
      assert shared.description == nil
    end

    test "normalizes string-keyed maps from persisted-shape opts", %{tmp_dir: tmp_dir} do
      toml_root = make_git_repo!("toml1")
      cli_root = make_git_repo!("cli1")

      File.write!(
        Path.join(tmp_dir, "genesis.toml"),
        """
        [foreign_repos.toml1]
        path = "#{toml_root}"
        """
      )

      result =
        Helpers.load_foreign_repos(
          tmp_dir,
          foreign_repos: [%{"id" => "cli1", "root" => cli_root, "description" => nil}]
        )

      assert length(result) == 2
      assert Enum.all?(result, &match?(%ForeignRepo{}, &1))

      assert %ForeignRepo{id: "cli1", root: ^cli_root, description: nil} =
               Enum.find(result, &(&1.id == "cli1"))
    end

    test "raises ArgumentError naming the id and path when the path does not exist", %{
      tmp_dir: tmp_dir
    } do
      missing =
        Path.join(
          System.tmp_dir!(),
          "evogit_helpers_fr_missing_#{System.unique_integer()}"
        )

      err =
        assert_raise ArgumentError, fn ->
          Helpers.load_foreign_repos(
            tmp_dir,
            foreign_repos: [%ForeignRepo{id: "gone", root: missing}]
          )
        end

      assert String.contains?(err.message, "gone")
      assert String.contains?(err.message, missing)
      assert String.contains?(err.message, "not a valid git repository")
    end

    test "raises ArgumentError when the path is a directory but not a git repo", %{
      tmp_dir: tmp_dir
    } do
      not_git =
        Path.join(
          System.tmp_dir!(),
          "evogit_helpers_fr_notgit_#{System.unique_integer()}"
        )

      File.mkdir_p!(not_git)
      on_exit(fn -> File.rm_rf!(not_git) end)

      err =
        assert_raise ArgumentError, fn ->
          Helpers.load_foreign_repos(
            tmp_dir,
            foreign_repos: [%ForeignRepo{id: "plain", root: not_git}]
          )
        end

      assert String.contains?(err.message, "plain")
      assert String.contains?(err.message, not_git)
      assert String.contains?(err.message, "not a valid git repository")
    end

    test "raises ArgumentError when base_sha does not resolve in the repo", %{
      tmp_dir: tmp_dir
    } do
      root = make_git_repo!("badsha")

      # NOTE: a FULL 40-hex string is accepted by `git rev-parse` without
      # existence verification (git returns it as-is), so an abbreviated
      # nonexistent sha is the minimal value that actually fails to resolve.
      err =
        assert_raise ArgumentError, fn ->
          Helpers.load_foreign_repos(
            tmp_dir,
            foreign_repos: [
              %ForeignRepo{
                id: "f",
                root: root,
                base_sha: "deadbee"
              }
            ]
          )
        end

      assert String.contains?(err.message, "f")
      assert String.contains?(err.message, "base_sha")
      assert String.contains?(err.message, "does not resolve")
    end

    test "validates and returns structs with writable and base_sha set", %{
      tmp_dir: tmp_dir
    } do
      root = make_git_repo!("valid")
      {:ok, sha} = Git.rev_parse(root)

      assert [
               %ForeignRepo{id: "f", root: ^root, writable: true, base_sha: ^sha}
             ] =
               Helpers.load_foreign_repos(
                 tmp_dir,
                 foreign_repos: [
                   %ForeignRepo{id: "f", root: root, writable: true, base_sha: sha}
                 ]
               )
    end

    test "parses writable and base_sha from genesis.toml", %{tmp_dir: tmp_dir} do
      toml_root = make_git_repo!("tomlvalid")
      {:ok, sha} = Git.rev_parse(toml_root)

      File.write!(
        Path.join(tmp_dir, "genesis.toml"),
        """
        [foreign_repos.toml1]
        path = "#{toml_root}"
        writable = true
        base_sha = "#{sha}"
        """
      )

      assert [%ForeignRepo{id: "toml1", root: ^toml_root, writable: true, base_sha: ^sha}] =
               Helpers.load_foreign_repos(tmp_dir, [])
    end
  end

  # ==========================================================================
  # resolve_foreign_repo_starting_commit/2
  # ==========================================================================
  describe "resolve_foreign_repo_starting_commit/2" do
    test "returns base_sha when set", %{tmp_dir: _tmp_dir} do
      root = make_git_repo!("resolve_base")
      {:ok, sha} = Git.rev_parse(root)

      entry = %ForeignRepo{id: "f", root: root, base_sha: sha}

      assert {:ok, ^sha} = Helpers.resolve_foreign_repo_starting_commit(entry, root)
    end

    test "returns the foreign repo HEAD when base_sha is nil", %{tmp_dir: _tmp_dir} do
      root = make_git_repo!("resolve_head")
      {:ok, head} = Git.rev_parse(root, "HEAD")

      entry = %ForeignRepo{id: "f", root: root}

      assert {:ok, ^head} = Helpers.resolve_foreign_repo_starting_commit(entry, root)
    end
  end

  # ==========================================================================
  # merge_foreign_repos/2
  # ==========================================================================
  describe "merge_foreign_repos/2" do
    test "accepts structs in both positions" do
      result =
        Helpers.merge_foreign_repos(
          [%ForeignRepo{id: "a", root: "/toml/a"}],
          [%ForeignRepo{id: "b", root: "/cli/b"}]
        )

      assert Enum.map(result, & &1.id) |> Enum.sort() == ["a", "b"]
      assert Enum.all?(result, &match?(%ForeignRepo{}, &1))
    end

    test "accepts atom-keyed maps" do
      result =
        Helpers.merge_foreign_repos(
          [%{id: "a", root: "/toml/a", description: "toml desc"}],
          [%{id: "b", root: "/cli/b"}]
        )

      assert [
               %ForeignRepo{id: "a", root: "/toml/a", description: "toml desc"},
               %ForeignRepo{id: "b", root: "/cli/b", description: nil}
             ] = result
    end

    test "accepts string-keyed maps" do
      result =
        Helpers.merge_foreign_repos(
          [%{"id" => "a", "root" => "/toml/a"}],
          [%{"id" => "b", "path" => "/cli/b", "description" => "cli desc"}]
        )

      assert [
               %ForeignRepo{id: "a", root: "/toml/a"},
               %ForeignRepo{id: "b", root: "/cli/b", description: "cli desc"}
             ] = result
    end

    test "accepts mixed lists in both positions" do
      result =
        Helpers.merge_foreign_repos(
          [%ForeignRepo{id: "s1", root: "/toml/s1"}, %{"id" => "s2", "root" => "/toml/s2"}],
          [%{id: "s3", root: "/cli/s3"}, %{"id" => "s4", "path" => "/cli/s4"}]
        )

      assert Enum.map(result, & &1.id) |> Enum.sort() == ["s1", "s2", "s3", "s4"]
      assert Enum.all?(result, &match?(%ForeignRepo{}, &1))
    end

    test "dedupes by id with CLI precedence across shapes" do
      # TOML carries a string-keyed map, CLI carries a struct for the same id —
      # the CLI struct must win.
      result =
        Helpers.merge_foreign_repos(
          [%{"id" => "x", "root" => "/toml/x", "description" => "toml desc"}],
          [%ForeignRepo{id: "x", root: "/cli/x"}]
        )

      assert [%ForeignRepo{id: "x", root: "/cli/x", description: nil}] = result
    end

    test "drops unparseable entries from both lists" do
      result =
        Helpers.merge_foreign_repos(
          [%{"id" => "a", "root" => "/toml/a"}, %{"id" => "no-root"}, nil, "junk"],
          [%ForeignRepo{id: "b", root: "/cli/b"}, %{root: "/no/id"}]
        )

      assert Enum.map(result, & &1.id) |> Enum.sort() == ["a", "b"]
    end
  end

  # ==========================================================================
  # load_repo_notes/2
  # ==========================================================================
  describe "load_repo_notes/2" do
    test "renders the note with gitlink paths when submodules exist", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")
      EvoGit.TestSupport.Submodule.add_gitlink(tmp_dir, "vendor/Sub")
      Git.add(tmp_dir, ".")
      Git.commit(tmp_dir, "Add submodule gitlink")
      {:ok, sha} = Git.rev_parse(tmp_dir, "HEAD")

      note = Helpers.load_repo_notes(tmp_dir, sha)

      assert is_binary(note)
      assert note =~ "## Git Submodules"
      assert note =~ "This repository has git submodules at:"
      assert note =~ "- `vendor/Sub`"
      assert note =~ "git submodule update --init"
      assert note =~ "empty placeholder directories"
      assert note =~ "Never delete the placeholder dirs"
      assert note =~ "do not commit inside submodules"
    end

    test "returns nil when the repo has no gitlinks", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")
      Git.add(tmp_dir, "file.txt")
      Git.commit(tmp_dir, "Initial commit")
      {:ok, sha} = Git.rev_parse(tmp_dir, "HEAD")

      assert Helpers.load_repo_notes(tmp_dir, sha) == nil
    end

    test "returns nil on a bogus treeish (graceful degradation)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "content")
      Git.add(tmp_dir, "file.txt")
      Git.commit(tmp_dir, "Initial commit")

      assert Helpers.load_repo_notes(tmp_dir, "bogus-treeish") == nil
    end
  end
end
