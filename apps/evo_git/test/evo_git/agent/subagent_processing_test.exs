defmodule EvoGit.Agent.SubagentProcessingTest do
  @moduledoc """
  `async: false` — the two `build_subagent_specs/3` describes insert/delete
  parent `AgentState` rows (fixed agent ids 99_998/99_999) in the app-owned
  BEAM-global `:evogit_agent_state` ETS table, which is shared state; the
  remaining tests use per-test `:tmp_dir` git repos. Kept sync per the
  async-safety policy, matching the other ETS-touching modules.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.ContextMerge.Report
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  alias EvoGit.Agent.Usage

  setup_all do
    template = git_template!()
    on_exit(fn -> File.rm_rf!(template) end)

    # The foreign-repo describes all start from the SAME two repository shapes,
    # and they only READ them (`build_subagent_specs/3` resolves the foreign
    # starting commit; nothing in those tests writes, stages or commits). So the
    # two variants are built ONCE here and COPIED per test — each test still owns
    # an independent repo (its own path, its own `.git`), it just no longer pays
    # `git add` + `git commit` for content every test reproduces identically.
    seed_root = module_scratch_dir!("subagent_processing_fixtures")
    on_exit(fn -> File.rm_rf!(seed_root) end)

    one_commit = Path.join(seed_root, "one_commit")
    one_commit_shas = init_repo(template, one_commit, [{"file.txt", "one", "c1"}])

    two_commits = Path.join(seed_root, "two_commits")

    two_commit_shas =
      init_repo(template, two_commits, [
        {"file.txt", "one", "c1"},
        {"file2.txt", "two", "c2"}
      ])

    %{
      git_template: template,
      one_commit_fixture: {one_commit, one_commit_shas},
      two_commit_fixture: {two_commits, two_commit_shas},
      merge_fixtures: merge_fixtures!(template)
    }
  end

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

    test "UNC-rooted foreign repo + UNC absolute path resolves the relative path" do
      foreign_repos = [
        ForeignRepo.new("primary", "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo"),
        ForeignRepo.new("original", "//wsl.localhost/Ubuntu-22.04/home/user/original-proj")
      ]

      repo_path = "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo"

      assert {:ok, "original", "//wsl.localhost/Ubuntu-22.04/home/user/original-proj",
              "./src/main.py"} =
               SubagentProcessing.resolve_subagent_path(
                 "//wsl.localhost/Ubuntu-22.04/home/user/original-proj/src/main.py",
                 repo_path,
                 foreign_repos
               )
    end

    test "backslash UNC-rooted foreign repo resolves the relative path" do
      foreign_repos = [
        ForeignRepo.new("primary", "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\primary-repo"),
        ForeignRepo.new("original", "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\original-proj")
      ]

      repo_path = "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\primary-repo"

      assert {:ok, "original", "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\original-proj",
              "./src/main.py"} =
               SubagentProcessing.resolve_subagent_path(
                 "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\original-proj\\src\\main.py",
                 repo_path,
                 foreign_repos
               )
    end

    test "UNC absolute path in the primary repo resolves via the primary-root fallback" do
      repo_path = "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo"

      assert {:ok, "primary", "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo",
              "./lib/app.ex"} =
               SubagentProcessing.resolve_subagent_path(
                 "//wsl.localhost/Ubuntu-22.04/home/user/primary-repo/lib/app.ex",
                 repo_path,
                 []
               )
    end

    test "backslash UNC primary-root fallback keeps the marker" do
      repo_path = "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\primary-repo"

      assert {:ok, "primary", "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\primary-repo",
              "./lib/app.ex"} =
               SubagentProcessing.resolve_subagent_path(
                 "\\\\wsl.localhost\\Ubuntu-22.04\\home\\user\\primary-repo\\lib\\app.ex",
                 repo_path,
                 []
               )
    end
  end

  describe "resolve_subagent_path/4 — writable foreign repo persistent worktree" do
    setup do
      root = "/home/user/original-proj"
      repo = ForeignRepo.new("original", root, writable: true)
      worktree = ForeignRepo.worktree_path(repo)

      foreign_repos = [ForeignRepo.new("primary", "/home/user/primary-repo"), repo]
      repo_path = "/home/user/primary-repo"

      %{foreign_repos: foreign_repos, repo_path: repo_path, root: root, worktree: worktree}
    end

    test "path under the persistent worktree resolves to the WORKTREE base with a worktree-relative node path",
         %{foreign_repos: foreign_repos, repo_path: repo_path, worktree: worktree} do
      assert {:ok, "original", ^worktree, "./src/foo"} =
               SubagentProcessing.resolve_subagent_path(
                 Path.join(worktree, "src/foo"),
                 repo_path,
                 foreign_repos
               )
    end

    test "the worktree root itself resolves to \"./\"",
         %{foreign_repos: foreign_repos, repo_path: repo_path, worktree: worktree} do
      assert {:ok, "original", ^worktree, "./"} =
               SubagentProcessing.resolve_subagent_path(worktree, repo_path, foreign_repos)
    end

    test "path under the repo ROOT (not the worktree) keeps the root base and root-relative node path",
         %{foreign_repos: foreign_repos, repo_path: repo_path, root: root} do
      assert {:ok, "original", ^root, "./src/foo"} =
               SubagentProcessing.resolve_subagent_path(
                 Path.join(root, "src/foo"),
                 repo_path,
                 foreign_repos
               )
    end

    test "read-only foreign repo is not given a worktree base — the worktree-shaped path falls through to the root match" do
      root = "/home/user/original-proj"
      read_only = ForeignRepo.new("original", root)

      foreign_repos = [ForeignRepo.new("primary", "/home/user/primary-repo"), read_only]

      assert {:ok, "original", ^root, "./.genesis/foreign_repos/original/src/foo"} =
               SubagentProcessing.resolve_subagent_path(
                 "/home/user/original-proj/.genesis/foreign_repos/original/src/foo",
                 "/home/user/primary-repo",
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

    test "foreign_repo_write_not_root error returns the custom message" do
      msg = "Only the ROOT agent can spawn write-capable subagents in a foreign repository"

      result =
        SubagentProcessing.format_subagent_result({:error, {:foreign_repo_write_not_root, msg}})

      assert result ==
               "Error: Only the ROOT agent can spawn write-capable subagents in a foreign repository"
    end

    test "foreign_repo_write_serialized error returns the custom message" do
      msg = "Only ONE write-capable foreign-repo subagent may be spawned at a time"

      result =
        SubagentProcessing.format_subagent_result({:error, {:foreign_repo_write_serialized, msg}})

      assert result ==
               "Error: Only ONE write-capable foreign-repo subagent may be spawned at a time"
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

    test "recovery_failed error mentions execution limit and smaller sub-tasks hint" do
      result = SubagentProcessing.format_subagent_result({:error, :recovery_failed})

      assert result =~ "execution limit" or result =~ "ran out of turns"
      assert result =~ "smaller"
      refute result =~ "unexpected"
    end

    # NOTE: :worktree_creation_failed is never returned by the runtime — worktree
    # failures raise and become :agent_max_retries_exceeded. It is dead code with
    # no dedicated clause, so it falls through to the generic catch-all below.
    # A dedicated test was therefore removed.

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
    alias EvoGit.Agents.Investigator
    alias EvoGit.Core.ContextNode
    alias EvoGit.Core.PhyloGraphNode

    # A dummy agent module that lists Investigator as a subagent module,
    # so subagent_module_for/2 can resolve the tool name.
    defmodule DummyAgentModule do
      def subagent_modules, do: [Investigator]
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
        phylo_node: %PhyloGraphNode{
          repo: "/test/repo",
          base_commit: "abc123",
          current_commit: "abc123"
        },
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

      call =
        ReqLLM.ToolCall.new(
          "call_1",
          "subagent_investigator",
          ~s({"path":"./src","objective":"investigate src"})
        )

      [spec] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert %AgentSpec{} = spec
      assert spec.model_id == "claude-sonnet"
    end

    test "child spec inherits default model_id when parent uses default", %{agent_id: agent_id} do
      # Override the parent state to use the default model_id
      parent_state = %AgentState{
        context_node: %ContextNode{path: "./", repo: "/test/repo"},
        phylo_node: %PhyloGraphNode{
          repo: "/test/repo",
          base_commit: "abc123",
          current_commit: "abc123"
        },
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

      call =
        ReqLLM.ToolCall.new(
          "call_1",
          "subagent_investigator",
          ~s({"path":"./lib","objective":"investigate lib"})
        )

      [spec] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert %AgentSpec{} = spec
      assert spec.model_id == "default"
    end

    test "child spec inherits the parent's repo_notes", %{agent_id: agent_id} do
      state = %LoopState{
        agent_id: agent_id,
        agent_module: DummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [],
        repo_notes: "## Git Submodules\n\nThis repository has git submodules at:\n- `vendor/Sub`"
      }

      call =
        ReqLLM.ToolCall.new(
          "call_1",
          "subagent_investigator",
          ~s({"path":"./src","objective":"investigate src"})
        )

      [spec] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert %AgentSpec{} = spec
      assert spec.repo_notes == state.repo_notes
    end

    test "child spec repo_notes is nil when the parent has none", %{agent_id: agent_id} do
      state = %LoopState{
        agent_id: agent_id,
        agent_module: DummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: []
      }

      call =
        ReqLLM.ToolCall.new(
          "call_1",
          "subagent_investigator",
          ~s({"path":"./src","objective":"investigate src"})
        )

      [spec] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert %AgentSpec{} = spec
      assert spec.repo_notes == nil
    end
  end

  describe "build_subagent_specs/3 — foreign repo phylo nodes" do
    alias EvoGit.Agent.LoopState
    alias EvoGit.AgentSpec
    alias EvoGit.Adapters.Git
    alias EvoGit.AgentScheduler.AgentState
    alias EvoGit.AgentScheduler.SchedMeta
    alias EvoGit.AgentScheduler.Subagents
    alias EvoGit.Agents.Investigator
    alias EvoGit.Core.ContextNode
    alias EvoGit.Core.PhyloGraphNode

    # A dummy agent module that lists Investigator as a subagent module,
    # so subagent_module_for/2 can resolve the tool name. (Named differently
    # from the model_id-inheritance describe's module to avoid redefinition.)
    defmodule ForeignDummyAgentModule do
      def subagent_modules, do: [Investigator]
    end

    # A dummy agent module declaring the built-in `:read_write` Executor as a
    # subagent module, so `subagent_module_for/2` resolves the
    # "subagent_executor" tool name to a child `agent_module` whose
    # `agent_type()` is `:read_write` — the shape the roll-up authority
    # predicate (`Subagents.writable_foreign_repo_agent?/1`) keys on.
    defmodule ForeignWriteDummyAgentModule do
      def subagent_modules, do: [EvoGit.Agents.Executor]
    end

    setup do
      # Ensure the ETS tables exist (app may already create them)
      if :ets.whereis(:evogit_agent_state) == :undefined do
        :ets.new(:evogit_agent_state, [:set, :public, :named_table])
      end

      if :ets.whereis(:evogit_sched_meta) == :undefined do
        :ets.new(:evogit_sched_meta, [:set, :public, :named_table])
      end

      agent_id = 99_998

      # Insert a parent AgentState with a specific model_id
      parent_state = %AgentState{
        context_node: %ContextNode{path: "./", repo: "/test/repo"},
        phylo_node: %PhyloGraphNode{
          repo: "/test/repo",
          base_commit: "abc123",
          current_commit: "abc123"
        },
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

    # Initializes a real git repository in `dir` from the module's `.git`
    # template (no `git init` / identity-config subprocesses per test), creating
    # one commit per {filename, content, commit_message} triple and returning the
    # SHAs in commit order.
    defp init_repo(template, dir, commits) do
      dir = init_repo(template, dir)

      Enum.map(commits, fn {file, content, msg} ->
        commit_files(dir, [{file, content}], msg)
      end)
    end

    defp foreign_call(path) do
      ReqLLM.ToolCall.new(
        "call_1",
        "subagent_investigator",
        Jason.encode!(%{"path" => path, "objective" => "investigate foreign repo"})
      )
    end

    # A "subagent_executor" delegation — resolves to the built-in `:read_write`
    # `EvoGit.Agents.Executor` child module via subagent_module_for/2.
    defp executor_call(path) do
      ReqLLM.ToolCall.new(
        "call_1",
        "subagent_executor",
        Jason.encode!(%{"path" => path, "objective" => "edit foreign repo"})
      )
    end

    # A minimal `%SchedMeta{}` row for a parent whose (fake) subagent id maps to
    # result index 0 — the shape `Subagents.store_sub_result/4` reads from the
    # `:evogit_sched_meta` ETS table.
    defp sched_meta(parent_id, sub_indices) do
      %SchedMeta{
        id: parent_id,
        depth: 0,
        spec: %AgentSpec{
          context_node: %ContextNode{path: "./", repo: "/test"},
          phylo_node: %PhyloGraphNode{repo: "/test", base_commit: "abc", current_commit: "abc"},
          agent_module: nil,
          objective: "test",
          repo_id: "primary"
        },
        sub_agent_indices: sub_indices,
        sub_agent_results: %{},
        foreign_repo_commits: %{}
      }
    end

    test "missing foreign repo root returns an error tuple, no crash",
         %{agent_id: agent_id, tmp_dir: tmp_dir, git_template: _template} do
      missing_root = Path.join(tmp_dir, "does_not_exist")

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignDummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", missing_root)],
        repo_notes: nil
      }

      call = foreign_call(missing_root)

      assert [{:error, {call_result, 0, msg}}] =
               SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert call_result == call
      assert msg =~ "foreign repository path does not exist or is not a git repository"
    end

    test "per-repo base_sha is honored as the foreign phylo starting commit",
         %{agent_id: agent_id, tmp_dir: tmp_dir, one_commit_fixture: fixture} do
      foreign_root = Path.join(tmp_dir, "foreign")
      [sha1] = copy_fixture!(fixture, foreign_root)

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignDummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, base_sha: sha1)],
        repo_notes: nil
      }

      call = foreign_call(foreign_root)

      assert [
               %AgentSpec{
                 repo_id: "orig",
                 phylo_node: %PhyloGraphNode{
                   repo: ^foreign_root,
                   base_commit: ^sha1,
                   current_commit: ^sha1
                 }
               }
             ] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})
    end

    test "per-repo base_sha takes precedence over the tracked foreign_repo_commits map",
         %{agent_id: agent_id, tmp_dir: tmp_dir, two_commit_fixture: fixture} do
      foreign_root = Path.join(tmp_dir, "foreign")

      [sha1, sha2] = copy_fixture!(fixture, foreign_root)

      refute sha1 == sha2

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignDummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, base_sha: sha1)],
        repo_notes: nil
      }

      call = foreign_call(foreign_root)

      # The tracked commit (sha2) must NOT win over the per-repo base_sha (sha1)
      assert [
               %AgentSpec{
                 phylo_node: %PhyloGraphNode{
                   repo: ^foreign_root,
                   base_commit: ^sha1,
                   current_commit: ^sha1
                 }
               }
             ] = SubagentProcessing.build_subagent_specs([{call, 0}], state, %{"orig" => sha2})
    end

    test "invalid base_sha returns an error tuple", %{
      agent_id: agent_id,
      tmp_dir: tmp_dir,
      one_commit_fixture: fixture
    } do
      foreign_root = Path.join(tmp_dir, "foreign")
      copy_fixture!(fixture, foreign_root)

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignDummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, base_sha: "deadbeef")],
        repo_notes: nil
      }

      call = foreign_call(foreign_root)

      assert [{:error, {call_result, 0, msg}}] =
               SubagentProcessing.build_subagent_specs([{call, 0}], state, %{})

      assert call_result == call
      assert msg =~ "base commit 'deadbeef' for foreign repository 'orig' does not exist"
    end

    # --- Coupling the roll-up authority predicate to the REAL builder ---
    #
    # These tests derive the spec from the production builder
    # `SubagentProcessing.build_subagent_specs/3` (never a hand-built struct)
    # and assert `EvoGit.AgentScheduler.Subagents.writable_foreign_repo_agent?/1`
    # on it, so a future silent regression in the builder's `repo_id` /
    # `agent_module` / `foreign_repos` wiring fails here instead of passing.

    test "absolute path into a writable foreign repo yields an authorized writable-foreign spec",
         %{agent_id: agent_id, tmp_dir: tmp_dir, one_commit_fixture: fixture} do
      foreign_root = Path.join(tmp_dir, "foreign")
      copy_fixture!(fixture, foreign_root)

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignWriteDummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, writable: true)],
        repo_notes: nil
      }

      assert [spec] =
               SubagentProcessing.build_subagent_specs(
                 [{executor_call(foreign_root), 0}],
                 state,
                 %{}
               )

      # Absolute spawn -> resolved to the foreign repo by resolve_subagent_path/3;
      # "subagent_executor" -> the `:read_write` Executor child module.
      assert spec.repo_id == "orig"
      assert spec.agent_module == EvoGit.Agents.Executor
      assert Subagents.writable_foreign_repo_agent?(spec)
    end

    test "relative delegation from a parent inside a writable foreign repo inherits the foreign repo id and is authorized",
         %{agent_id: agent_id, tmp_dir: tmp_dir, one_commit_fixture: fixture} do
      foreign_root = Path.join(tmp_dir, "foreign")
      copy_fixture!(fixture, foreign_root)

      # The parent is itself running INSIDE the foreign repo (the NESTED case),
      # so a RELATIVE path targets the parent's own repo root. Its OWN repo_id
      # is the foreign repo's id — the authoritative source the spawn gate and
      # resolve_subagent_path/4 both read.
      Process.put(:repo_path, foreign_root)
      {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
      :ets.insert(:evogit_agent_state, {agent_id, %{agent_state | repo_id: "orig"}})

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignWriteDummyAgentModule,
        depth: 1,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, writable: true)],
        repo_notes: nil
      }

      assert [spec] =
               SubagentProcessing.build_subagent_specs([{executor_call("src"), 0}], state, %{})

      # The relative child inherits the parent's repo id ("orig"), so the
      # roll-up authority predicate authorizes it — the parent's own root IS the
      # writable foreign repo.
      assert spec.repo_id == "orig"
      assert Subagents.writable_foreign_repo_agent?(spec)
    end

    test "relative delegation from a foreign-repo parent resolves the child's repo id and worktree root to the FOREIGN repo",
         %{agent_id: agent_id, tmp_dir: tmp_dir, one_commit_fixture: fixture} do
      foreign_root = Path.join(tmp_dir, "foreign")
      copy_fixture!(fixture, foreign_root)

      Process.put(:repo_path, foreign_root)
      {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)
      :ets.insert(:evogit_agent_state, {agent_id, %{agent_state | repo_id: "orig"}})

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignWriteDummyAgentModule,
        depth: 1,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, writable: true)],
        repo_notes: nil
      }

      assert [spec] =
               SubagentProcessing.build_subagent_specs([{executor_call("src"), 0}], state, %{})

      # repo id + worktree root resolve to the FOREIGN repo (not "primary") …
      assert spec.repo_id == "orig"
      assert EvoGit.AgentScheduler.Dispatch.resolve_agent_repo_root(spec, nil) == foreign_root

      # … and the phylo node bases off the PARENT's live current commit (the
      # same-repo clause), NOT the foreign repo's base_sha/HEAD.
      assert spec.phylo_node.base_commit == "abc123"
      assert spec.phylo_node.current_commit == "abc123"

      # A same-repo spawn within the foreign repo is UNRESTRICTED by the spawn
      # gate (it is not treated as a cross-repo delegation). The parent's own
      # repo id matches the child's, so the gate's "same repo" branch applies.
      nested_parent = %{
        agent_state
        | context_node: %ContextNode{path: "./", repo: foreign_root},
          repo_id: "orig"
      }

      assert :ok == Subagents.validate_spatial_contract_for_spec(agent_id, nested_parent, spec, 1)
    end

    test "store_sub_result/4 advances the tracked foreign commit only for the real builder's authorized spec",
         %{agent_id: agent_id, tmp_dir: tmp_dir, one_commit_fixture: fixture} do
      foreign_root = Path.join(tmp_dir, "foreign")
      [sha] = copy_fixture!(fixture, foreign_root)

      writable_parent = 99_001
      primary_parent = 99_002

      :ets.insert(
        :evogit_sched_meta,
        {writable_parent, sched_meta(writable_parent, %{101 => 0})}
      )

      :ets.insert(
        :evogit_sched_meta,
        {primary_parent, sched_meta(primary_parent, %{102 => 0})}
      )

      on_exit(fn ->
        :ets.delete(:evogit_sched_meta, writable_parent)
        :ets.delete(:evogit_sched_meta, primary_parent)
      end)

      state = %LoopState{
        agent_id: agent_id,
        agent_module: ForeignWriteDummyAgentModule,
        depth: 0,
        node_path: "./",
        context: nil,
        foreign_repos: [ForeignRepo.new("orig", foreign_root, writable: true)],
        repo_notes: nil
      }

      # Authorized spec: an ABSOLUTE spawn into the writable foreign repo.
      assert [writable_spec] =
               SubagentProcessing.build_subagent_specs(
                 [{executor_call(foreign_root), 0}],
                 state,
                 %{}
               )

      assert Subagents.writable_foreign_repo_agent?(writable_spec)

      result = {:ok, %Result{result: "done", commit_sha: sha, repo_id: "orig"}}

      Subagents.store_sub_result(writable_parent, 101, result, writable_spec)

      assert EvoGit.AgentScheduler.get_foreign_repo_commits(writable_parent) == %{"orig" => sha}

      # Unauthorized spec: a relative delegation from a PRIMARY-repo parent
      # (the setup parent keeps its default repo_id: "primary") resolves to
      # "primary", so the SAME result payload must NOT advance any tracked commit.
      Process.put(:repo_path, foreign_root)

      assert [primary_spec] =
               SubagentProcessing.build_subagent_specs([{executor_call("src"), 0}], state, %{})

      assert primary_spec.repo_id == "primary"
      refute Subagents.writable_foreign_repo_agent?(primary_spec)

      Subagents.store_sub_result(primary_parent, 102, result, primary_spec)

      assert EvoGit.AgentScheduler.get_foreign_repo_commits(primary_parent) == %{}
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

  describe "accumulate_subagent_usages/1" do
    test "returns zero usage for empty list" do
      assert SubagentProcessing.accumulate_subagent_usages([]) == Usage.zero()
    end

    test "accumulates a single subagent's usage correctly" do
      usage = %Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 20,
        cache_creation_tokens: 5
      }

      result = %Result{result: "done", commit_sha: "abc123", usage: usage}

      accumulated = SubagentProcessing.accumulate_subagent_usages([{:ok, result}])

      assert accumulated.input_tokens == 100
      assert accumulated.output_tokens == 50
      assert accumulated.total_tokens == 150
      assert accumulated.input_cost == 0.01
      assert accumulated.output_cost == 0.02
      assert accumulated.total_cost == 0.03
      assert accumulated.cached_tokens == 20
      assert accumulated.cache_creation_tokens == 5
    end

    test "sums usages from multiple subagents" do
      usage1 = %Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 10,
        cache_creation_tokens: 2
      }

      usage2 = %Usage{
        input_tokens: 200,
        output_tokens: 100,
        total_tokens: 300,
        input_cost: 0.02,
        output_cost: 0.04,
        total_cost: 0.06,
        cached_tokens: 15,
        cache_creation_tokens: 3
      }

      result1 = %Result{result: "done1", commit_sha: "abc", usage: usage1}
      result2 = %Result{result: "done2", commit_sha: "def", usage: usage2}

      accumulated =
        SubagentProcessing.accumulate_subagent_usages([{:ok, result1}, {:ok, result2}])

      assert accumulated.input_tokens == 300
      assert accumulated.output_tokens == 150
      assert accumulated.total_tokens == 450
      assert accumulated.input_cost == 0.03
      assert accumulated.output_cost == 0.06
      assert accumulated.total_cost == 0.09
      assert accumulated.cached_tokens == 25
      assert accumulated.cache_creation_tokens == 5
    end

    test "skips {:error, _} results gracefully" do
      usage = %Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 0,
        cache_creation_tokens: 0
      }

      ok_result = %Result{result: "ok", commit_sha: "abc", usage: usage}
      error_result = {:error, :some_reason}

      accumulated =
        SubagentProcessing.accumulate_subagent_usages([{:ok, ok_result}, error_result])

      # Only the ok result's usage should be counted
      assert accumulated.input_tokens == 100
      assert accumulated.output_tokens == 50
      assert accumulated.total_tokens == 150
    end

    test "handles nil usage in Result gracefully" do
      result_with_nil_usage = %Result{result: "done", commit_sha: "abc123", usage: nil}

      accumulated =
        SubagentProcessing.accumulate_subagent_usages([{:ok, result_with_nil_usage}])

      # Should return zero usage, not crash
      assert accumulated == Usage.zero()
    end

    test "handles mixed nil and valid usages" do
      valid_usage = %Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 0,
        cache_creation_tokens: 0
      }

      ok_with_usage = %Result{result: "ok", commit_sha: "abc", usage: valid_usage}
      ok_with_nil = %Result{result: "nil", commit_sha: "def", usage: nil}
      error = {:error, :some_error}

      accumulated =
        SubagentProcessing.accumulate_subagent_usages([
          {:ok, ok_with_usage},
          {:ok, ok_with_nil},
          error
        ])

      # Only the valid usage should be counted
      assert accumulated.input_tokens == 100
      assert accumulated.output_tokens == 50
      assert accumulated.total_tokens == 150
    end

    test "preserves cached_tokens and cache_creation_tokens" do
      usage = %Usage{
        input_tokens: 500,
        output_tokens: 200,
        total_tokens: 700,
        input_cost: 0.05,
        output_cost: 0.04,
        total_cost: 0.09,
        cached_tokens: 300,
        cache_creation_tokens: 50
      }

      result = %Result{result: "done", commit_sha: "abc", usage: usage}

      accumulated = SubagentProcessing.accumulate_subagent_usages([{:ok, result}])

      assert accumulated.cached_tokens == 300
      assert accumulated.cache_creation_tokens == 50

      # Also verify the cache hit rate calculation still works
      # (cached_tokens / input_tokens * 100 = 300/500 * 100 = 60.0)
      assert_in_delta Usage.cache_hit_rate(accumulated), 60.0, 0.01
    end
  end

  describe "subagent result merging (ContextMerge wiring)" do
    test "clean multi-child merge: success note and merged branches deleted", %{
      tmp_dir: tmp_dir,
      merge_fixtures: fixtures
    } do
      %{dir: dir, children: children} =
        merge_repo!(fixtures, :clean, Path.join(tmp_dir, "clean_merge"))

      report = SubagentProcessing.perform_merge(dir, children, "./")

      assert %Report{status: :clean} = report
      assert Enum.map(report.entries, & &1.status) == [:merged, :merged]
      assert report.genuine_conflicts == []

      note = SubagentProcessing.build_merge_message(report, children, "", [])

      assert note =~ "System Note: Successfully auto-merged changes from subagents."
      assert File.read!(Path.join(dir, "src/b.ex")) =~ "defmodule B"
      assert File.read!(Path.join(dir, "doc/x.md")) == "# Doc\n"

      assert Git.branch_exists?(dir, "evogit-agent-T1-A0")
      assert Git.branch_exists?(dir, "evogit-agent-T1-A1")

      assert SubagentProcessing.delete_merged_branches(report, dir) == :ok

      refute Git.branch_exists?(dir, "evogit-agent-T1-A0")
      refute Git.branch_exists?(dir, "evogit-agent-T1-A1")
    end

    test "out-of-scope CONTEXT.md edit is dropped in favour of the parent", %{
      tmp_dir: tmp_dir,
      merge_fixtures: fixtures
    } do
      %{dir: dir, children: children} =
        merge_repo!(fixtures, :out_of_scope, Path.join(tmp_dir, "out_of_scope"))

      [%{commit_sha: child_sha}] = children

      report = SubagentProcessing.perform_merge(dir, children, "./src")

      assert report.status == :clean

      assert [%{status: :auto_resolved, node_path: "./doc", commit_sha: ^child_sha}] =
               report.entries

      note = SubagentProcessing.build_merge_message(report, children, "", [])

      assert note =~ "Dropped out-of-scope edit"
      assert note =~ "child node: ./doc"
      assert note =~ "child src context"

      assert File.read!(Path.join(dir, "src/CONTEXT.md")) == "parent src context\n"
      assert File.read!(Path.join(dir, "doc/x.md")) == "# Doc\n"
      assert clean_worktree?(dir)
    end

    test "in-scope child beats an ancestor-level parent edit", %{
      tmp_dir: tmp_dir,
      merge_fixtures: fixtures
    } do
      %{dir: dir, children: children} =
        merge_repo!(fixtures, :in_scope, Path.join(tmp_dir, "in_scope"))

      report = SubagentProcessing.perform_merge(dir, children, "./")

      assert report.status == :clean
      assert [%{status: :auto_resolved}] = report.entries
      assert report.genuine_conflicts == []

      note = SubagentProcessing.build_merge_message(report, children, "", [])

      assert note =~ "System Note: Successfully auto-merged changes from subagents."
      assert note =~ "src/CONTEXT.md: kept theirs (node ./src)"
      assert File.read!(Path.join(dir, "src/CONTEXT.md")) == "child src context\n"
      assert clean_worktree?(dir)
    end

    test "same-node CONTEXT.md conflict: reported, worktree clean, no branch deleted",
         %{tmp_dir: tmp_dir, merge_fixtures: fixtures} do
      %{dir: dir, children: children} =
        merge_repo!(fixtures, :same_node, Path.join(tmp_dir, "same_node"))

      [child_one, child_two] = Enum.map(children, & &1.commit_sha)

      report = SubagentProcessing.perform_merge(dir, children, "./")

      assert report.status == :conflict

      note = SubagentProcessing.build_merge_message(report, children, "", [])

      assert note =~ "System Note: Auto-merging subagent changes hit conflicts."
      assert note =~ "your worktree is clean at HEAD"
      assert note =~ child_one
      assert note =~ child_two
      assert note =~ "./src"
      assert note =~ "unresolved: both sides own this node"
      refute note =~ "Branches of merged children were deleted"
      assert porcelain(dir) == ""

      assert SubagentProcessing.delete_merged_branches(report, dir) == :ok

      assert Git.branch_exists?(dir, "evogit-agent-T1-A0")
      assert Git.branch_exists?(dir, "evogit-agent-T1-A1")
    end

    test "non-CONTEXT.md conflict is never auto-resolved and keeps both branches",
         %{tmp_dir: tmp_dir, merge_fixtures: fixtures} do
      %{dir: dir, children: children} =
        merge_repo!(fixtures, :source_conflict, Path.join(tmp_dir, "source_conflict"))

      report = SubagentProcessing.perform_merge(dir, children, "./")

      assert report.status == :conflict
      assert report.auto_resolutions == []
      assert [conflict] = report.genuine_conflicts
      assert conflict.file == "src/a.ex"

      note = SubagentProcessing.build_merge_message(report, children, "", [])

      assert note =~ "src/a.ex"
      refute note =~ "Auto-resolutions applied"
      refute note =~ "Branches of merged children were deleted"
      assert porcelain(dir) == ""

      assert SubagentProcessing.delete_merged_branches(report, dir) == :ok

      assert Git.branch_exists?(dir, "evogit-agent-T1-A0")
      assert Git.branch_exists?(dir, "evogit-agent-T1-A1")
    end

    test "cross-repo results only: the cross-repo note is the whole message", %{
      tmp_dir: tmp_dir,
      git_template: template
    } do
      dir = init_repo(template, Path.join(tmp_dir, "cross_repo_only"))

      specs = [{0, subagent_spec(0, "./", repo_id: "original")}]
      results = [{:ok, %Result{result: "done", commit_sha: "abc123", branch: "foreign-branch"}}]

      {children, cross_repo_details} =
        SubagentProcessing.collect_mergeable_results(specs, results, "primary")

      assert children == []
      assert cross_repo_details == [{"original", "abc123"}]

      report = SubagentProcessing.perform_merge(dir, children, "./")
      assert report == nil

      cross_repo_note =
        "\nSystem Note: 1 cross-repo subagent(s) completed in foreign repositories:\n  - original: abc123"

      assert SubagentProcessing.build_merge_message(
               report,
               children,
               cross_repo_note,
               cross_repo_details
             ) == cross_repo_note
    end

    test "no results at all yields no message" do
      assert SubagentProcessing.build_merge_message(nil, [], "", []) == nil
      assert SubagentProcessing.perform_merge("/nonexistent", [], "./") == nil
    end

    test "collect_mergeable_results/3 keeps spawn order and separates cross-repo children" do
      specs = [
        {7, subagent_spec(7, "./src", objective: "seven")},
        {3, subagent_spec(3, "./doc", agent_module: EvoGit.Agents.Investigator)},
        {5, subagent_spec(5, "./", repo_id: "original")},
        {9, subagent_spec(9, "./lib")}
      ]

      results = [
        {:ok, %Result{result: "a", commit_sha: "sha7", branch: "branch7"}},
        {:ok, %Result{result: "b", commit_sha: "sha3", branch: "branch3"}},
        {:ok, %Result{result: "c", commit_sha: "sha5", branch: "branch5"}},
        {:error, :failed}
      ]

      {children, cross_repo_details} =
        SubagentProcessing.collect_mergeable_results(specs, results, "primary")

      assert children == [
               %{
                 index: 7,
                 commit_sha: "sha7",
                 branch: "branch7",
                 node_path: "./src",
                 agent_module: EvoGit.Agents.Executor,
                 objective: "seven"
               },
               %{
                 index: 3,
                 commit_sha: "sha3",
                 branch: "branch3",
                 node_path: "./doc",
                 agent_module: EvoGit.Agents.Investigator,
                 objective: "objective 3"
               }
             ]

      assert cross_repo_details == [{"original", "sha5"}]

      # nil commit shas are skipped; a nil branch is carried through untouched.
      assert {[%{commit_sha: "sha1", branch: nil}], []} =
               SubagentProcessing.collect_mergeable_results(
                 [{1, subagent_spec(1, "./")}],
                 [{:ok, %Result{result: "x", commit_sha: "sha1"}}],
                 "primary"
               )

      assert SubagentProcessing.collect_mergeable_results(
               [{1, subagent_spec(1, "./")}],
               [{:ok, %Result{result: "x", commit_sha: nil}}],
               "primary"
             ) == {[], []}
    end
  end

  # ---------------------------------------------------------------------------
  # Merge-test helpers — real git repos under the ExUnit tmp dir.
  #
  # EVERY repo starts as a copy of the module's `.git` template (built once in
  # `setup_all/1`), so `git init` + the fixture identity config cost 4
  # subprocesses per MODULE rather than per test. The template's identity is
  # also PRIMED into `EvoGit.GitEnv`'s per-repo memo on every copy
  # (`prime_identity!/1`) — the first git invocation in a fresh repo would
  # otherwise spend two extra `git config` subprocesses re-reading the very
  # values the template already pins.
  # ---------------------------------------------------------------------------

  # A module-wide scratch directory (ExUnit's `:tmp_dir` is per test, and these
  # fixtures must outlive a single test).
  defp module_scratch_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  # Builds the per-module repository template: `git init` with an EMPTY template
  # dir (no hook samples / description boilerplate), the fixture commit identity
  # + `commit.gpgsign=false`, and `core.abbrev=40` so `git commit` prints the new
  # commit's FULL sha (see `commit_files/3`).
  defp git_template! do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_git_template_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    empty_template = Path.join(root, "empty_template")
    File.mkdir_p!(empty_template)
    seed = Path.join(root, "seed")

    {_output, 0} =
      System.cmd("git", ["init", "-q", "--template=#{empty_template}", seed],
        stderr_to_stdout: true
      )

    for {key, value} <- [
          {"user.email", "test@example.com"},
          {"user.name", "Test User"},
          {"commit.gpgsign", "false"},
          {"core.abbrev", "40"}
        ] do
      {_output, 0} =
        System.cmd("git", ["config", key, value], cd: seed, stderr_to_stdout: true)
    end

    seed
  end

  defp init_repo(template, dir) do
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(template, ".git"), Path.join(dir, ".git"))
    prime_identity!(dir)
    dir
  end

  # Copies a repository PREPARED in `setup_all/1` (already carrying its commits)
  # into `dir` for one test. `File.cp_r!/2` reproduces the whole tree — `.git`
  # with its objects and refs plus the checked-out files — so the copy is an
  # INDEPENDENT repository at the same commit graph, without paying
  # `git add` + `git commit` for content every test reproduces identically.
  defp copy_fixture!({source, shas}, dir) do
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(source, dir)
    prime_identity!(dir)
    shas
  end

  # Seeds `EvoGit.GitEnv`'s per-repo identity memo with the values the template's
  # config pins, so the repo's first git invocation skips the two `git config`
  # subprocesses. The resolved env is byte-identical to what a real read
  # produces (the template config holds exactly these values).
  defp prime_identity!(dir) do
    EvoGit.GitEnv.prime_config_identity_cache(dir, "Test User", "test@example.com")
  end

  # ---------------------------------------------------------------------------
  # Merge fixtures — one `git fast-import` per MODULE, one `File.cp_r!/2` per
  # test (`merge_repo!/3`).
  #
  # Every ContextMerge test needs the same tiny commit graph: a merge-target
  # ("parent") tree plus one commit per child, laid out on named branches.
  # Building it per test with `git add` + `git commit` + `git checkout` cost 8-9
  # subprocesses PER TEST — the bulk of each test's body time. The whole graph
  # (3 bases + 10 child/parent commits, ~1 KB of loose objects) is therefore
  # imported in a SINGLE `git fast-import` subprocess, each scenario's
  # repository (parent checked out, child branches already in place) is
  # snapshotted ONCE in `setup_all/1` — that snapshot does pay ONE `git
  # checkout` — and a test then only COPIES its snapshot, with no git
  # subprocess at all. Identities and timestamps are pinned, so the fixture
  # SHAs are identical on every run.
  # ---------------------------------------------------------------------------

  # Named commits, PARENTS FIRST: `from <mark>` may only reference a commit
  # declared earlier. `parent: nil` marks a root commit.
  @merge_commits [
    base_root: %{
      parent: nil,
      message: "base",
      files: [{"CONTEXT.md", "# Root\n"}, {"src/a.ex", "defmodule A do\nend\n"}]
    },
    base_src: %{
      parent: nil,
      message: "base",
      files: [{"src/CONTEXT.md", "base src context\n"}, {"src/a.ex", "defmodule A do\nend\n"}]
    },
    base_src_only: %{
      parent: nil,
      message: "base",
      files: [{"src/CONTEXT.md", "base src context\n"}]
    },
    parent_src_edit: %{
      parent: :base_src,
      message: "parent work",
      files: [{"src/CONTEXT.md", "parent src context\n"}]
    },
    parent_root_edit: %{
      parent: :base_src_only,
      message: "parent work",
      files: [{"src/CONTEXT.md", "root parent context\n"}]
    },
    clean_src: %{
      parent: :base_root,
      message: "child one",
      files: [{"src/b.ex", "defmodule B do\nend\n"}]
    },
    clean_doc: %{parent: :base_root, message: "child two", files: [{"doc/x.md", "# Doc\n"}]},
    out_of_scope_child: %{
      parent: :base_src,
      message: "child work",
      files: [{"src/CONTEXT.md", "child src context\n"}, {"doc/x.md", "# Doc\n"}]
    },
    in_scope_child: %{
      parent: :base_src_only,
      message: "child work",
      files: [{"src/CONTEXT.md", "child src context\n"}]
    },
    same_node_one: %{
      parent: :base_root,
      message: "child one",
      files: [{"src/CONTEXT.md", "child one\n"}]
    },
    same_node_two: %{
      parent: :base_root,
      message: "child two",
      files: [{"src/CONTEXT.md", "child two\n"}]
    },
    source_one: %{parent: :base_root, message: "child one", files: [{"src/a.ex", "one\n"}]},
    source_two: %{parent: :base_root, message: "child two", files: [{"src/a.ex", "two\n"}]}
  ]

  # Scenario => %{parent: <commit key>, children: [{index, <commit key>, node_path}]}
  # — the child list is in SPAWN order, which is what `perform_merge/3` wants.
  @merge_scenarios [
    clean: %{
      parent: :base_root,
      children: [{0, :clean_src, "./src"}, {1, :clean_doc, "./doc"}]
    },
    out_of_scope: %{parent: :parent_src_edit, children: [{0, :out_of_scope_child, "./doc"}]},
    in_scope: %{parent: :parent_root_edit, children: [{0, :in_scope_child, "./src"}]},
    same_node: %{
      parent: :base_root,
      children: [{0, :same_node_one, "./src"}, {1, :same_node_two, "./src"}]
    },
    source_conflict: %{
      parent: :base_root,
      children: [{0, :source_one, "./src"}, {1, :source_two, "./src"}]
    }
  ]

  # Pinned commit identity/timestamp for the fast-import graph: identical on
  # every run (and on every host), so fixture SHAs never drift.
  @fixture_epoch 1_600_000_000

  defp merge_fixtures!(template) do
    scratch = module_scratch_dir!("subagent_processing_merge_fixtures")
    on_exit(fn -> File.rm_rf!(scratch) end)

    object_store = Path.join(scratch, "objects")
    init_repo(template, object_store)
    shas = import_merge_graph!(object_store)

    Map.new(@merge_scenarios, fn {name, scenario} ->
      dir = Path.join(scratch, "scenario_#{name}")
      File.mkdir_p!(dir)
      File.cp_r!(Path.join(object_store, ".git"), Path.join(dir, ".git"))
      prime_identity!(dir)

      Enum.each(scenario.children, fn {index, commit, _node_path} ->
        write_branch_ref!(dir, branch_name(index), Map.fetch!(shas, commit))
      end)

      # The ONE `git checkout` a scenario pays: write the merge target into the
      # index + worktree (what `git checkout -B` did in the old per-test setup).
      {:ok, _output} =
        Git.run(["checkout", "-q", "-B", "parent", Map.fetch!(shas, scenario.parent)], dir)

      children =
        Enum.map(scenario.children, fn {index, commit, node_path} ->
          {index, Map.fetch!(shas, commit), node_path}
        end)

      {name, %{dir: dir, children: children}}
    end)
  end

  # One snapshot COPY per test: `File.cp_r!/2` reproduces the whole repository
  # (objects, refs, index, checked-out files), so the test owns an independent
  # repo in exactly the state the scenario describes, at zero git subprocesses.
  defp merge_repo!(fixtures, scenario, dir) do
    snapshot = Map.fetch!(fixtures, scenario)
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(snapshot.dir, dir)
    prime_identity!(dir)

    children =
      Enum.map(snapshot.children, fn {index, sha, node_path} ->
        child(index, sha, node_path, [])
      end)

    %{dir: dir, children: children}
  end

  defp branch_name(index), do: "evogit-agent-T1-A#{index}"

  defp write_branch_ref!(dir, branch, sha) do
    path = Path.join([dir, ".git", "refs", "heads", branch])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, sha <> "\n")
  end

  # Imports `@merge_commits` into `dir`'s object store, returning
  # `%{commit_key => sha}` (read back from the `--export-marks` report, so no
  # `git rev-parse` per commit).
  defp import_merge_graph!(dir) do
    marks_by_name = @merge_commits |> Keyword.keys() |> Enum.with_index(1) |> Map.new()
    marks_path = Path.join(dir, "fixture.marks")

    stream =
      Enum.map(@merge_commits, fn {name, commit} ->
        fixture_commit_stream(name, commit, marks_by_name)
      end)

    run_fast_import!(dir, stream, marks_path)

    by_mark =
      marks_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [":" <> mark, sha] = String.split(line, " ")
        {String.to_integer(mark), sha}
      end)

    Map.new(marks_by_name, fn {name, mark} -> {name, Map.fetch!(by_mark, mark)} end)
  end

  defp fixture_commit_stream(name, commit, marks_by_name) do
    parent =
      case commit.parent do
        nil -> []
        parent -> ["from :", Integer.to_string(Map.fetch!(marks_by_name, parent)), "\n"]
      end

    files =
      Enum.map(commit.files, fn {path, content} ->
        ["M 100644 inline ", path, "\n", fixture_data(content)]
      end)

    [
      "commit refs/fixtures/",
      Atom.to_string(name),
      "\n",
      "mark :",
      Integer.to_string(Map.fetch!(marks_by_name, name)),
      "\n",
      "author Test User <test@example.com> #{@fixture_epoch} +0000\n",
      "committer Test User <test@example.com> #{@fixture_epoch} +0000\n",
      fixture_data(commit.message),
      parent,
      files,
      "\n"
    ]
  end

  # fast-import's counted `data <n>` form: the byte count frames content with or
  # without a trailing newline exactly, and costs no escaping.
  defp fixture_data(content) do
    ["data ", Integer.to_string(byte_size(content)), "\n", content, "\n"]
  end

  # `git fast-import` reads its command stream from STDIN, which `System.cmd/3`
  # cannot write — this Port is the file's only stdin-driven git call. `done`
  # ends the stream; a non-zero exit raises with git's own diagnostics.
  defp run_fast_import!(dir, stream, marks_path) do
    git = System.find_executable("git") || raise "git is not available on PATH"

    port =
      Port.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["fast-import", "--quiet", "--export-marks=#{marks_path}"],
        cd: dir
      ])

    Port.command(port, stream)
    Port.command(port, "done\n")
    await_fast_import!(port, "")
  end

  defp await_fast_import!(port, output) do
    receive do
      {^port, {:data, data}} ->
        await_fast_import!(port, output <> data)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        raise "git fast-import failed (exit #{code}): #{output}"
    after
      30_000 -> raise "git fast-import timed out: #{output}"
    end
  end

  defp commit_files(dir, files, message) do
    Enum.each(files, fn {path, content} ->
      full_path = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)

    {:ok, _output} = Git.add(dir, ".")
    {:ok, output} = Git.commit(dir, message)
    committed_sha(dir, output)
  end

  # `git commit` prints "[<branch> <sha>] <subject>" — the template pins
  # `core.abbrev=40`, so that sha is complete and usable as a merge target
  # without an extra `rev-parse` spawn. If the output shape ever changes, fall
  # back to resolving HEAD (correct, only slower).
  defp committed_sha(dir, commit_output) do
    case Regex.run(~r/^\[[^\]]* ([0-9a-f]{40})\]/m, commit_output) do
      [_, sha] -> sha
      _ -> rev_parse!(dir)
    end
  end

  defp rev_parse!(dir) do
    {:ok, sha} = Git.rev_parse(dir)
    sha
  end

  defp clean_worktree?(dir), do: porcelain(dir) == ""

  defp porcelain(dir) do
    {:ok, output} = Git.status(dir)
    output
  end

  defp child(index, commit_sha, node_path, opts) do
    %{
      index: index,
      commit_sha: commit_sha,
      branch: Keyword.get(opts, :branch, "evogit-agent-T1-A#{index}"),
      node_path: node_path,
      agent_module: Keyword.get(opts, :agent_module, EvoGit.Agents.Executor),
      objective: Keyword.get(opts, :objective, "child #{index}")
    }
  end

  defp subagent_spec(index, node_path, opts \\ []) do
    %AgentSpec{
      context_node: %ContextNode{path: node_path, repo: "/repo"},
      phylo_node: %PhyloGraphNode{repo: "/repo", base_commit: "base", current_commit: "base"},
      agent_module: Keyword.get(opts, :agent_module, EvoGit.Agents.Executor),
      objective: Keyword.get(opts, :objective, "objective #{index}"),
      repo_id: Keyword.get(opts, :repo_id, "primary")
    }
  end
end
