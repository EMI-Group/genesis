defmodule EvoGit.Runtime.HelpersTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Result
  alias EvoGit.Runtime.Helpers

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

  # ==========================================================================
  # generate_branch_name/1
  # ==========================================================================
  describe "generate_branch_name/1" do
    test "starts with the expected prefix" do
      name = Helpers.generate_branch_name("genesis")

      assert String.starts_with?(name, "evogit/genesis_")
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
    test "does not crash with :task_id key" do
      assert Helpers.notify_finalizing(task_id: "t123") in [:ok, nil]
    end

    test "does not crash without :task_id key" do
      assert Helpers.notify_finalizing([]) in [:ok, nil]
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
      assert String.starts_with?(branch_name, "evogit/genesis_")

      suffix = branch_name |> String.split("_") |> List.last()
      assert Regex.match?(~r/^[0-9a-f]{8}$/, suffix)
    end
  end
end
