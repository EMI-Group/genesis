defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase"
  alias EvoGit.Agent
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.WorkerPool
  alias EvoGit.Prompts
  require Logger

  def run(root_prompt, opts \\ []) do
    Logger.info("Genesis: Starting with root prompt: #{root_prompt}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
         {:ok, head_sha} <- PhyloGraphNode.current_head(repo_path) do
      # Start recursion from root "."
      evolve_node(head_sha, ".", root_prompt, opts)
    else
      error ->
        Logger.error("Genesis failed to initialize: #{inspect(error)}")
        error
    end
  end

  defp ensure_repo(repo_path) do
    if File.dir?(Path.join(repo_path, ".git")) do
      :ok
    else
      Logger.info("Genesis: Initializing Git repository at #{repo_path}...")
      File.mkdir_p!(repo_path)
      Git.init(repo_path)
      # Create initial commit to allow branching
      File.write!(Path.join(repo_path, "README.md"), "")
      Git.add(repo_path, "README.md")

      case Git.commit(repo_path, "Initial commit") do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  # The Core Recursive Function
  defp evolve_node(current_sha, node_path, context_instruction, opts) do
    Logger.info("Genesis: Evolving #{node_path} from #{String.slice(current_sha, 0, 7)}")

    evolution_result =
      WorkerPool.run(fn worktree_path ->
        abs_node_path = Path.join(worktree_path, node_path)
        type = if File.dir?(abs_node_path), do: :directory, else: :file

        # Construct Initial State
        phylo_node = PhyloGraphNode.new(worktree_path, current_sha)

        # We need to ensure the context node can be loaded.
        # Since we are just planning/realizing, we use the path.
        context_node = ContextNode.load(abs_node_path, worktree_path)

        state = %{context_node: context_node, phylo_node: phylo_node}

        # Step 2: Plan
        plan_objective = Prompts.genesis_plan(type, node_path, context_instruction)

        with {:ok, plan_state} <- Agent.mutate(state, plan_objective, opts),
             # Step 3: Realize
             realize_objective = Prompts.genesis_realize(type, node_path),
             {:ok, realize_state} <- Agent.mutate(plan_state, realize_objective, opts) do
          {:ok, realize_state}
        end
      end)

    case evolution_result do
      {:ok, realize_state} ->
        # Step 4: Recursion
        # Find children created/present in the new commit
        new_sha = realize_state.phylo_node.current_commit
        recurse_children(new_sha, node_path, opts)

      error ->
        error
    end
  end

  @ignored_names [".git", "node_modules", ".venv", "__pycache__", "CONTEXT.md"]

  defp recurse_children(base_sha, node_path, opts) do
    Logger.debug("Recursive down to child nodes of #{base_sha} #{node_path}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()
    node = PhyloGraphNode.new(repo_path, base_sha)

    case PhyloGraphNode.list_immediate_children(node, node_path) do
      {:ok, children} ->
        # Filter children by hardcoded names and self
        pre_filtered =
          children
          |> Enum.reject(fn p ->
            name = Path.basename(p)
            name in @ignored_names or p == node_path
          end)

        # Further filter with .gitignore if there are any children left
        valid_children =
          if pre_filtered == [] do
            []
          else
            case Git.check_ignore(repo_path, pre_filtered) do
              {:ok, ignored} -> pre_filtered -- ignored
              _ -> pre_filtered
            end
          end

        Logger.debug("Found children of #{node_path}: #{inspect(children)}")

        if valid_children == [] do
          {:ok, base_sha}
        else
          Logger.info(
            "Genesis: Recursing into children of #{node_path}: #{inspect(valid_children)}"
          )

          process_children_parallel(base_sha, valid_children, opts)
        end

      error ->
        error
    end
  end

  defp process_children_parallel(base_sha, children, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)

    # Use Task.async_stream for parallel agents
    results =
      Task.async_stream(
        children,
        fn child_path ->
          evolve_node(base_sha, child_path, "Inherit context from parent", opts)
        end,
        timeout: :infinity,
        max_concurrency: max_concurrency
      )

    # Collect results and merge them sequentially into the base
    Enum.reduce_while(results, base_sha, fn
      {:ok, {:ok, child_sha}}, current_base ->
        Logger.info(
          "Genesis: Merging child #{String.slice(child_sha, 0, 7)} into #{String.slice(current_base, 0, 7)}"
        )

        case merge_branch(current_base, child_sha, opts) do
          {:ok, new_base} -> {:cont, new_base}
          error -> {:halt, error}
        end

      {:ok, {:error, reason}}, _ ->
        {:halt, {:error, reason}}

      {:exit, reason}, _ ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:error, _} = err -> err
      sha when is_binary(sha) -> {:ok, sha}
    end
  end

  defp merge_branch(base_sha, other_sha, opts) do
    WorkerPool.run(fn worktree_path ->
      phylo_node = PhyloGraphNode.new(worktree_path, base_sha)
      context_node = ContextNode.load(worktree_path, worktree_path)
      state = %{context_node: context_node, phylo_node: phylo_node}

      case Agent.resolve_conflict(state, other_sha, opts) do
        {:ok, %{phylo_node: updated_phylo_node}} -> {:ok, updated_phylo_node.current_commit}
        error -> error
      end
    end)
    |> case do
      {:ok, sha} -> {:ok, sha}
      error -> error
    end
  end
end
