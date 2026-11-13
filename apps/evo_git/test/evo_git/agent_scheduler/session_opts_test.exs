defmodule EvoGit.AgentScheduler.SessionOptsTest do
  @moduledoc """
  Pins the OPTION THREADING of `EvoGit.AgentScheduler.SessionOpts.build/1` — the
  pure `keyword() -> %EvoGit.AgentSpec{}` seam behind
  `EvoGit.AgentScheduler.start_session/1`.

  Two shapes are covered: a REPO-BACKED session (`:path` at a real git repo, so
  the spec is anchored on a `%EvoGit.Core.PhyloGraphNode{}` at HEAD) and a
  REPO-LESS one (`repo_less: true`, no `:path`, so `phylo_node` is `nil`).

  ## What is pinned here

    * `:persistent_state` — the boolean that enables the durable per-agent
      checkpoints in `agent_state.sqlite` — reaches `%EvoGit.AgentSpec{}.opts`
      VERBATIM in BOTH shapes (`true` repo-backed, `false` repo-less). It is the
      scheduler-side half of the durability contract: if this builder dropped
      the key, `EvoGit.Agent.Session.Setup.build_initial_state/3` would fall back
      to its `true` default and a task opt-out would silently stop working.
    * every other documented forwarded key (`:task_id`, `:model_id`, `:archive`,
      `:attachments`, `:quality_level`, `:foreign_repos`, `:repo_notes`,
      `:notify`) arrives with its exact value, and `:repo_notes` /
      `:foreign_repos` are ALSO hoisted onto the struct by `AgentSpec.new/5`.
    * the keys the builder CONSUMES (`:agent_module`, `:objective`, `:path`,
      `:node_path`, `:depth`, `:parent_id`) never leak into the spec opts.
    * `:session_mode` is normalized, not forwarded as given: `"interactive"`
      arrives as the atom `:interactive`.

  ## Why `async: true`

  Nothing here touches a BEAM global: the builder is a pure function, the git
  fixture is a private `@moduletag :tmp_dir` directory per test, and no
  scheduler is started and no app env is written. The only cross-process write
  is the `EvoGit.GitEnv` identity memo, keyed by that unique per-test repo path.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler.SessionOpts
  alias EvoGit.AgentSpec
  alias EvoGit.Core.PhyloGraphNode

  @moduletag :tmp_dir

  @attachments [
    %{"type" => "image", "name" => "a.png", "media_type" => "image/png", "data" => "AAAA"}
  ]

  # A minimal `EvoGit.Agent` role: `build/1` only needs a module that implements
  # the behaviour, and `AgentSpec` stores the module verbatim.
  #
  # Defined ABOVE the test module on purpose: `mix test` starts the async ExUnit
  # runner before every file finishes loading, so a helper defined AFTER an
  # `async: true` test module can be unloaded when its first test runs.
  defmodule StubAgent do
    use EvoGit.Agent

    @doc "The role's fixed system prompt."
    def system_prompt, do: "You are the session-opts test role."

    @doc "No tools: the builder never inspects the tool set."
    def available_tools, do: []
  end

  describe "build/1 forwards :persistent_state (repo-backed)" do
    test "keeps :persistent_state and every documented forwarded key, drops the consumed ones",
         %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      {:ok, head_sha} = init_repo(repo)

      opts = [
        agent_module: StubAgent,
        objective: "session opts objective",
        path: repo,
        task_id: "task-opts-1",
        model_id: "opts-profile",
        archive: true,
        attachments: @attachments,
        quality_level: :high,
        persistent_state: true,
        foreign_repos: [],
        repo_notes: "notes block",
        notify: {self(), :tag},
        session_mode: "interactive",
        model_id_locked: true
      ]

      assert {:ok, %AgentSpec{} = spec} = SessionOpts.build(opts)

      # The headline forwarding: the durability flag is NOT swallowed.
      assert Keyword.get(spec.opts, :persistent_state) == true

      # Every documented forwarded key, with its exact value.
      assert Keyword.get(spec.opts, :task_id) == "task-opts-1"
      assert Keyword.get(spec.opts, :model_id) == "opts-profile"
      assert Keyword.get(spec.opts, :model_id_locked) == true
      assert Keyword.get(spec.opts, :archive) == true
      assert Keyword.get(spec.opts, :attachments) == @attachments
      assert Keyword.get(spec.opts, :quality_level) == :high
      assert Keyword.get(spec.opts, :repo_notes) == "notes block"
      assert Keyword.get(spec.opts, :foreign_repos) == []
      assert Keyword.get(spec.opts, :notify) == {self(), :tag}

      # `:session_mode` is normalized (the string form is never forwarded).
      assert Keyword.get(spec.opts, :session_mode) == :interactive

      # Consumed keys are never forwarded.
      for key <- [:agent_module, :objective, :path, :node_path, :depth, :parent_id] do
        refute Keyword.has_key?(spec.opts, key),
               "expected consumed key #{inspect(key)} to be absent"
      end

      # Struct-level shape: the hoisted fields plus a real temporal anchor.
      assert spec.agent_module == StubAgent
      assert spec.objective == "session opts objective"
      assert spec.repo_id == "primary"
      assert spec.repo_notes == "notes block"
      assert spec.foreign_repos == []
      assert %PhyloGraphNode{repo: ^repo, base_commit: ^head_sha} = spec.phylo_node
      assert spec.context_node.path == "./"
      assert spec.context_node.repo == repo
    end
  end

  describe "build/1 forwards :persistent_state (repo-less)" do
    test "forwards :persistent_state: false and keeps the repo-less system shape",
         %{tmp_dir: _tmp_dir} do
      opts = [
        agent_module: StubAgent,
        objective: "repo-less objective",
        repo_less: true,
        task_id: "task-opts-2",
        persistent_state: false
      ]

      assert {:ok, %AgentSpec{} = spec} = SessionOpts.build(opts)

      assert Keyword.get(spec.opts, :persistent_state) == false
      assert Keyword.get(spec.opts, :repo_less) == true
      assert Keyword.get(spec.opts, :task_id) == "task-opts-2"
      assert spec.phylo_node == nil
      assert spec.context_node.repo == "[system]"

      for key <- [:agent_module, :objective, :path, :node_path, :depth, :parent_id] do
        refute Keyword.has_key?(spec.opts, key),
               "expected consumed key #{inspect(key)} to be absent"
      end
    end
  end

  # One real repo: init + write + add + commit + rev-parse (the same cheap
  # fixture `session_dispatch_test.exs` uses).
  defp init_repo(root) do
    {:ok, _} = Git.init(root)
    File.write!(Path.join(root, "README.md"), "initial\n")
    {:ok, _} = Git.add(root)
    {:ok, _} = Git.commit(root, "initial")
    Git.rev_parse(root)
  end
end
