defmodule EvoGit.Runtime.SelfReflective do
  @moduledoc "Self-reflective (repo-less) agent runtime — a Genesis operator that understands and operates the running Genesis system"

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode

  require Logger

  @doc "Returns the optional Genesis reference checkout; never uses the launch directory."
  def source_root, do: EvoGit.SelfReflectiveSource.reference_path()

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
    # Resolve the node path once here and thread it through opts — build_spec/2
    # derives its node_path from the same key (it drops :node_path from the spec
    # opts, so the resolved value never leaks into the AgentSpec).
    opts = Keyword.put_new(opts, :node_path, "./")
    node_path = opts[:node_path]

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
  `phylo_node` is nil. The minimal `[system]` context never loads reference or
  launch-directory files. Source is an optional tool capability.
  """
  def build_spec(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    node_path = Keyword.get(opts, :node_path, "./")
    context_node = %ContextNode{path: node_path, repo: "[system]"}

    # Strip keys consumed here; retain task/model selection for the scheduler.
    # Explicit selections are locked, and model_spec beats a legacy model_id.
    # repo_less: true is put LAST so it always wins.
    spec_opts =
      opts
      |> Keyword.drop([:objective, :source_root, :node_path])
      |> EvoGit.Runtime.Helpers.normalize_model_selection_opts()
      |> Keyword.put(:repo_less, true)

    AgentSpec.new(context_node, nil, EvoGit.Agents.SelfReflective, objective, spec_opts)
  end
end
