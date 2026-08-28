defmodule EvoGit.Runtime.Evolution do
  @moduledoc "Stage 2: Evolutionary Loop"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
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

    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, current_sha} <- Helpers.resolve_starting_commit(repo_path, starting_commit),
         :ok <- Helpers.validate_node_path(node_path, repo_path) do
      case mode do
        :simple -> run_simple_mode(objective, repo_path, current_sha, node_path, opts)
        :custom -> run_custom_mode(objective, repo_path, current_sha, node_path, opts)
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

  # Mode A: Top-Down Evolution (Simple)
  defp run_simple_mode(objective, repo_path, current_sha, node_path, opts) do
    Logger.info("Evolution: Running Mode A (Top-Down)")

    {agent_module, agent_opts} =
      Helpers.resolve_root_agent(opts, EvoGit.Agents.Manager)

    run_resolved_root_agent(
      objective,
      repo_path,
      current_sha,
      node_path,
      opts,
      agent_module,
      agent_opts
    )
  end

  # Mode C: Custom Root Agent (agents.toml) — `opts[:agent]` is guaranteed
  # non-nil/non-empty here (checked in run/2); unknown ids raise in
  # Helpers.resolve_root_agent/2.
  defp run_custom_mode(objective, repo_path, current_sha, node_path, opts) do
    Logger.info("Evolution: Running custom mode with agent '#{Keyword.get(opts, :agent)}'")

    {agent_module, agent_opts} =
      Helpers.resolve_root_agent(opts, EvoGit.Agents.Custom)

    run_resolved_root_agent(
      objective,
      repo_path,
      current_sha,
      node_path,
      opts,
      agent_module,
      agent_opts
    )
  end

  # Shared flow for both modes: build the phylo/context nodes and foreign-repo
  # list, run the resolved root agent, and merge/report on success.
  defp run_resolved_root_agent(
         objective,
         repo_path,
         current_sha,
         node_path,
         opts,
         agent_module,
         agent_opts
       ) do
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load(node_path, repo_path)
    foreign_repos = Helpers.load_foreign_repos(repo_path, opts)
    repo_notes = Helpers.load_repo_notes(repo_path, current_sha)

    case AgentSpec.new(context_node, phylo_node, agent_module, objective,
           foreign_repos: foreign_repos,
           repo_notes: repo_notes,
           archive: Keyword.get(opts, :archive, false),
           task_id: Keyword.get(opts, :task_id),
           model_id: Keyword.get(opts, :model_id),
           model_id_locked: Helpers.model_id_locked?(opts)
         )
         |> then(fn spec ->
           # merge custom_agent_id into the spec opts when present
           %{spec | opts: Keyword.merge(spec.opts, agent_opts)}
         end)
         |> AgentScheduler.run_agent() do
      {:ok, %Result{} = agent_output} ->
        Helpers.notify_finalizing(Keyword.get(opts, :task_id))
        Helpers.merge_and_report(repo_path, agent_output, "evolve", foreign_repos)

      error ->
        Logger.error("Evolution failed: #{inspect(error)}")
        error
    end
  end
end
