defmodule EvoGit.Agent.SubagentProcessingTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.Core.ForeignRepo

  describe "resolve_subagent_path/3" do
    setup do
      foreign_repos = [
        ForeignRepo.new("primary", "/home/user/primary-repo"),
        ForeignRepo.new("original", "/home/user/original-proj"),
        ForeignRepo.new("reference", "/home/user/reference-proj")
      ]

      repo_path = "/home/user/primary-repo"

      %{foreign_repos: foreign_repos, repo_path: repo_path}
    end

    test "absolute path matching a foreign repo returns that repo's id, root, and relative path",
         %{foreign_repos: foreign_repos, repo_path: repo_path} do
      assert {:ok, "original", "/home/user/original-proj", "./src/main.py"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/original-proj/src/main.py",
                 repo_path,
                 foreign_repos
               )
    end

    test "absolute path matching the primary repo returns \"primary\" with relative path",
         %{foreign_repos: foreign_repos, repo_path: repo_path} do
      assert {:ok, "primary", "/home/user/primary-repo", "./lib/app.ex"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/primary-repo/lib/app.ex",
                 repo_path,
                 foreign_repos
               )
    end

    test "absolute path not in any repo returns an error tuple with helpful message",
         %{foreign_repos: foreign_repos, repo_path: repo_path} do
      assert {:error, msg} =
               SubagentProcessing.resolve_subagent_path(
                 "/tmp/unknown/project",
                 repo_path,
                 foreign_repos
               )

      assert msg =~ "Absolute path"
      assert msg =~ "/tmp/unknown/project"
      assert msg =~ "not within"
    end

    test "absolute path not in any repo with empty foreign_repos still matches primary repo",
         %{repo_path: repo_path} do
      assert {:ok, "primary", "/home/user/primary-repo", "./lib/app.ex"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/primary-repo/lib/app.ex",
                 repo_path,
                 []
               )
    end

    test "relative path stays in primary repo as \"primary\"",
         %{foreign_repos: foreign_repos, repo_path: repo_path} do
      assert {:ok, "primary", "/home/user/primary-repo", "./src/lib"} =
               SubagentProcessing.resolve_subagent_path(
                 "src/lib",
                 repo_path,
                 foreign_repos
               )
    end

    test "nil path raises because normalize_relpath does not accept nil",
         %{foreign_repos: foreign_repos, repo_path: repo_path} do
      assert_raise FunctionClauseError, fn ->
        SubagentProcessing.resolve_subagent_path(nil, repo_path, foreign_repos)
      end
    end

    test "dot-slash relative path stays in primary repo, normalized",
         %{foreign_repos: foreign_repos, repo_path: repo_path} do
      assert {:ok, "primary", "/home/user/primary-repo", "./src/lib"} =
               SubagentProcessing.resolve_subagent_path(
                 "./src/lib",
                 repo_path,
                 foreign_repos
               )
    end

    test "multiple foreign repos, path matches the correct one" do
      foreign_repos = [
        ForeignRepo.new("primary", "/home/user/primary-repo"),
        ForeignRepo.new("original", "/home/user/original-proj"),
        ForeignRepo.new("reference", "/home/user/reference-proj")
      ]

      repo_path = "/home/user/primary-repo"

      assert {:ok, "reference", "/home/user/reference-proj", "./docs/README.md"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/reference-proj/docs/README.md",
                 repo_path,
                 foreign_repos
               )
    end

    test "absolute path exactly at repo root returns relative path ./" do
      foreign_repos = [
        ForeignRepo.new("primary", "/home/user/primary-repo"),
        ForeignRepo.new("original", "/home/user/original-proj")
      ]

      repo_path = "/home/user/primary-repo"

      assert {:ok, "original", "/home/user/original-proj", "./"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/original-proj",
                 repo_path,
                 foreign_repos
               )
    end
  end

  describe "format_subagent_result/1" do
    test "foreign_repo_read_only error returns the custom message" do
      msg = "Custom message"

      result = SubagentProcessing.format_subagent_result({:error, {:foreign_repo_read_only, msg}})

      assert result == "Error: Custom message"
    end

    test "foreign_repo_read_only error with real message mentions read-write restriction" do
      msg = "Read-write agents cannot be spawned in foreign repositories"

      result = SubagentProcessing.format_subagent_result({:error, {:foreign_repo_read_only, msg}})

      assert result =~ "Read-write agents cannot be spawned"
    end

    test "path_ignored error mentions ignored folder and gitignore hint" do
      result = SubagentProcessing.format_subagent_result({:error, :path_ignored})

      assert result =~ "Cannot spawn subagent in an ignored folder"
      assert result =~ "gitignore"
    end

    test "path_not_exist error mentions does not exist and tool hints" do
      result = SubagentProcessing.format_subagent_result({:error, :path_not_exist})

      assert result =~ "does not exist"
      assert result =~ "make_dir"
      assert result =~ "create_files"
    end

    test "generic error includes unexpected error and retry suggestion" do
      result = SubagentProcessing.format_subagent_result({:error, :some_other_reason})

      assert result =~ "unexpected error"
      assert result =~ "retry"
    end

    test "spatial_contract_violation error returns the custom message exactly" do
      msg = "some rich remediation message"

      result =
        SubagentProcessing.format_subagent_result({:error, {:spatial_contract_violation, msg}})

      assert result == "Error: some rich remediation message"
      refute result =~ "{:spatial"
      refute result =~ "spatial_contract_violation"
    end

    test "max_depth_exceeded error mentions recursion depth and a suggestion" do
      result = SubagentProcessing.format_subagent_result({:error, :max_depth_exceeded})

      assert result =~ "recursion depth"
      assert result =~ "current level"
    end

    test "worktree_creation_failed error mentions retry and report" do
      result = SubagentProcessing.format_subagent_result({:error, :worktree_creation_failed})

      assert result =~ "retry"
      assert result =~ "report"
    end

    test "agent_max_retries_exceeded error mentions retry and report" do
      result = SubagentProcessing.format_subagent_result({:error, :agent_max_retries_exceeded})

      assert result =~ "retry"
      assert result =~ "report"
    end

    test "unknown_error mentions retry" do
      result = SubagentProcessing.format_subagent_result({:error, :unknown_error})

      assert result =~ "retry"
    end

    test "ok result with commit_sha includes result text and commit info" do
      agent_result = %Result{result: "Done successfully", commit_sha: "abc123def456"}

      result = SubagentProcessing.format_subagent_result({:ok, agent_result})

      assert result =~ "Done successfully"
      assert result =~ "abc123def456"
      assert result =~ "# Result"
      assert result =~ "# Final Commit"
    end

    test "ok result is properly trimmed" do
      agent_result = %Result{result: "Hello", commit_sha: "sha1"}

      result = SubagentProcessing.format_subagent_result({:ok, agent_result})

      refute String.ends_with?(result, "\n")
    end

    test "plain string returns the string as-is" do
      text = "Just a plain result string"

      assert SubagentProcessing.format_subagent_result(text) == text
    end

    test "non-standard value returns inspected representation" do
      result = SubagentProcessing.format_subagent_result(:atom)

      assert result == inspect(:atom)
    end
  end

  describe "build_subagent_specs/3 — model_id inheritance" do
    alias EvoGit.Agent.LoopState
    alias EvoGit.AgentSpec
    alias EvoGit.AgentScheduler.AgentState
    alias EvoGit.Agents.CodebaseInvestigator
    alias EvoGit.Core.ContextNode
    alias EvoGit.Core.PhyloGraphNode

    # A dummy agent module that lists CodebaseInvestigator as a subagent module,
    # so subagent_module_for/2 can resolve the tool name.
    defmodule DummyAgentModule do
      def subagent_modules, do: [CodebaseInvestigator]
    end

    setup do
      # Ensure the ETS table exists (app may already create it)
      if :ets.whereis(:evogit_agent_state) == :undefined do
        :ets.new(:evogit_agent_state, [:set, :public, :named_table])
      end

      agent_id = 99_999

      # Insert a parent AgentState with a specific model_id
      parent_state = %AgentState{
        context_node: %ContextNode{path: "./", repo: "/test/repo"},
        phylo_node: %PhyloGraphNode{repo: "/test/repo", base_commit: "abc123", current_commit: "abc123"},
        llm_model: "test-model",
        max_retries: 3,
        max_depth: 5,
        model_id: "claude-sonnet"
      }

      :ets.insert(:evogit_agent_state, {agent_id, parent_state})

      # Set the repo_path in the process dictionary
      previous_repo_path = Process.get(:repo_path)
      Process.put(:repo_path, "/test/repo")

      on_exit(fn ->
        :ets.delete(:evogit_agent_state, agent_id)
        # Restore previous repo_path
        if previous_repo_path do
          Process.put(:repo_path, previous_repo_path)
        else
          Process.delete(:repo_path)
        end
      end)

      %{agent_id: agent_id}
    end

    test "child spec inherits parent's model_id", %{agent_id: agent_id} do
      state = %LoopState{
        agent_id: agent_id,
        agent_module: DummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: []
      }

      call = %{
        id: "call_1",
        name: "subagent_codebase_investigator",
        arguments: %{"path" => "./src", "objective" => "investigate src"}
      }

      [spec] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert %AgentSpec{} = spec
      assert spec.model_id == "claude-sonnet"
    end

    test "child spec inherits default model_id when parent uses default", %{agent_id: agent_id} do
      # Override the parent state to use the default model_id
      parent_state = %AgentState{
        context_node: %ContextNode{path: "./", repo: "/test/repo"},
        phylo_node: %PhyloGraphNode{repo: "/test/repo", base_commit: "abc123", current_commit: "abc123"},
        llm_model: "test-model",
        max_retries: 3,
        max_depth: 5,
        model_id: "default"
      }

      :ets.insert(:evogit_agent_state, {agent_id, parent_state})

      state = %LoopState{
        agent_id: agent_id,
        agent_module: DummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: []
      }

      call = %{
        id: "call_1",
        name: "subagent_codebase_investigator",
        arguments: %{"path" => "./lib", "objective" => "investigate lib"}
      }

      [spec] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert %AgentSpec{} = spec
      assert spec.model_id == "default"
    end
  end

  describe "format_subagent_result/1 with repo_id" do
    test "ok result with repo_id formats the same as without repo_id" do
      agent_result = %Result{
        result: "Foreign investigation done",
        commit_sha: "abc123",
        repo_id: "original"
      }

      result = SubagentProcessing.format_subagent_result({:ok, agent_result})

      assert result =~ "Foreign investigation done"
      assert result =~ "abc123"
      assert result =~ "# Result"
      assert result =~ "# Final Commit"
    end
  end
end
