defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.Runtime
  alias EvoGit.Agent.Result
  alias EvoGit.Runtime.Helpers
  require Logger

  def run(objective, opts \\ []) when is_list(opts) do
    mode = mode_atom(Keyword.get(opts, :mode))

    # Custom mode requires an explicit agents.toml agent id. Raise BEFORE any
    # repo/git I/O so spec errors surface immediately (crashing loudly is
    # intentional — a missing agent id is a spec error, mirroring
    # Helpers.resolve_root_agent/2's unknown-id behavior).
    if mode == :custom and Keyword.get(opts, :agent) in [nil, ""] do
      raise ArgumentError,
            "custom mode requires an agent id; pass agent: <id> (defined in agents.toml)"
    end

    node_path = Keyword.get(opts, :node_path, "./")
    starting_commit = Keyword.get(opts, :starting_commit)

    Logger.info(
      "Evolution: Starting for objective: #{objective} (node: #{node_path}, commit: #{starting_commit || "HEAD"})"
    )

    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> EvoGit.Platform.safe_expand()

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, current_sha} <- Helpers.resolve_starting_commit(repo_path, starting_commit),
         :ok <- Helpers.validate_node_path(node_path, repo_path) do
      case mode do
        :simple ->
          run_mode(
            objective,
            repo_path,
            current_sha,
            node_path,
            opts,
            EvoGit.Agents.Manager,
            "Evolution: Running Mode A (Top-Down)"
          )

        :custom ->
          run_mode(
            objective,
            repo_path,
            current_sha,
            node_path,
            opts,
            EvoGit.Agents.Custom,
            "Evolution: Running custom mode with agent '#{Keyword.get(opts, :agent)}'"
          )
      end
    else
      {:error, {:invalid_node_path, message}} ->
        Logger.error("Evolution: Invalid node path: #{message}")
        {:error, {:invalid_node_path, message}}

      error ->
        Logger.error("Evolution failed to initialize: #{inspect(error)}")
        error
    end
  end

  @doc false
  # Public test wrapper for the mode normalization (nil = absent).
  @spec mode_atom(term()) :: :simple | :custom
  def mode_atom(nil), do: :simple
  def mode_atom(:simple), do: :simple
  def mode_atom("simple"), do: :simple
  def mode_atom(:custom), do: :custom
  def mode_atom("custom"), do: :custom

  def mode_atom(other) do
    Logger.warning("Evolution: unknown mode #{inspect(other)}, falling back to simple")
    :simple
  end

  # Both modes share this single flow — they differ only in the default root
  # module and the emitted log line. Simple mode uses the built-in Manager;
  # custom mode runs the agents.toml agent via EvoGit.Agents.Custom (opts[:agent]
  # is guaranteed non-nil/non-empty here — checked in run/2; unknown ids raise
  # in Helpers.resolve_root_agent/2, reached from build_root_agent_spec/7).
  defp run_mode(objective, repo_path, current_sha, node_path, opts, default_module, log_text) do
    Logger.info(log_text)

    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(node_path, repo_path)
    foreign_repos = Helpers.load_foreign_repos(repo_path, opts)
    repo_notes = Helpers.load_repo_notes(repo_path, current_sha)

    spec =
      Helpers.build_root_agent_spec(
        context_node,
        phylo_node,
        default_module,
        objective,
        opts,
        foreign_repos,
        repo_notes
      )

    case AgentScheduler.run_agent(spec) do
      {:ok, %Result{} = agent_output} ->
        Helpers.notify_finalizing(Keyword.get(opts, :task_id))
        Helpers.merge_and_report(repo_path, agent_output, "evolve", foreign_repos)

      error ->
        Logger.error("Evolution failed: #{inspect(error)}")
        error
    end
  end
end
