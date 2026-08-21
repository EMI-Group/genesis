defmodule EvoGit.Runtime.SelfReflective do
  @moduledoc "Self-reflective (repo-less) agent runtime — chatbot-style system introspection"

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode

  require Logger

  @doc """
  Resolves the Genesis source root — the directory the reflective agent reads.

  Delegates to `EvoGit.SelfReflectiveSource.reference_path/0` — the single
  source of truth for the chain: `:self_reflective_source_root` app env →
  `GENESIS_SOURCE_ROOT` env var → the managed clone at
  `EvoGit.SelfReflectiveSource.source_dir/0` when it exists and is a valid
  Genesis checkout (auto-reference) → `nil`. Falls back to `File.cwd!()`
  (dev: the genesis repo itself) when the chain resolves to nil. The
  scheduler resolves the repo-less agent's repo root from the SAME chain via
  `EvoGit.AgentScheduler.Dispatch.resolve_repo_less_root/0` — both delegate
  to `SelfReflectiveSource.reference_path/0` so they always agree.
  """
  def source_root do
    EvoGit.SelfReflectiveSource.reference_path() || File.cwd!()
  end

  @doc """
  Runs a self-reflective (repo-less) task. Two entry arities:

    * `run(opts)` — opts keyword; objective read from `opts[:objective]` (default "")
    * `run(objective, opts)` — objective positional

  No git ops: no ensure_repo, no merge_and_report, no PR. Returns
  `{:ok, %{result: ..., commit_sha: nil, branch_name: nil, tag: nil}}` on
  success; propagates `{:error, reason}` otherwise (TaskRegistry maps
  non-`{:ok, _}` results to `:failed`).
  """
  def run(opts) when is_list(opts) do
    run(Keyword.get(opts, :objective, ""), opts)
  end

  def run(objective, opts) when is_binary(objective) and is_list(opts) do
    node_path = Keyword.get(opts, :node_path, "./")

    Logger.info("SelfReflective: Starting for objective: #{objective} (node: #{node_path})")

    spec = build_spec(objective, opts)

    case AgentScheduler.run_agent(spec) do
      {:ok, %Result{} = result} ->
        {:ok, %{result: result.result, commit_sha: nil, branch_name: nil, tag: nil}}

      error ->
        Logger.error("SelfReflective failed: #{inspect(error)}")
        error
    end
  end

  @doc """
  Builds the repo-less `%AgentSpec{}` for a self-reflective run WITHOUT
  dispatching. Exposed as a test seam: asserts `spec.opts[:repo_less] == true`,
  `phylo_node` is nil, and the context-node shape — loaded over the source root
  when it is a real directory (the agent then sees the Genesis CONTEXT.md tree,
  genuinely self-reflective), otherwise a bare minimal `%ContextNode{}` with a
  `"[system]"` placeholder repo.
  """
  def build_spec(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    node_path = Keyword.get(opts, :node_path, "./")
    source_root = resolve_source_root(opts)

    context_node =
      if is_binary(source_root) and File.dir?(source_root) do
        ContextNode.load(node_path, source_root)
      else
        %ContextNode{path: node_path, repo: source_root || "[system]"}
      end

    # Strip the keys consumed here; keep :task_id, :model_id (the scheduler
    # reads them). repo_less: true is put LAST so it always wins.
    spec_opts =
      opts
      |> Keyword.drop([:objective, :source_root, :node_path])
      |> Keyword.put(:repo_less, true)

    AgentSpec.new(context_node, nil, EvoGit.Agents.SelfReflective, objective, spec_opts)
  end

  # opts[:source_root] (a real dir) wins; otherwise fall back to the standard
  # source_root()/nil chain.
  defp resolve_source_root(opts) do
    case Keyword.get(opts, :source_root) do
      path when is_binary(path) and path != "" ->
        if File.dir?(path), do: path, else: source_root()

      _ ->
        source_root()
    end
  end
end
