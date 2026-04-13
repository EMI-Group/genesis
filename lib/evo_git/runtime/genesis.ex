defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.Prompts
  require Logger

  def run(root_prompt, opts \\ []) do
    Logger.info("Genesis: Starting with root prompt: #{root_prompt}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- ensure_repo(repo_path),
         {:ok, head_sha} <- PhyloGraphNode.current_head(repo_path) do
      # Start recursion from root "."
      case evolve_node(head_sha, ".", root_prompt, opts) do
        {:ok, final_sha} ->
          Logger.info(
            "Genesis: Evolution complete. Updating main repository to #{String.slice(final_sha, 0, 7)}"
          )

          Git.reset_hard(repo_path, final_sha)
          {:ok, final_sha}

        error ->
          error
      end
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
      AgentScheduler.run_agent(fn worktree_path ->
        # Ensure worktree is at the correct commit before checking if node is a directory
        Git.clean(worktree_path)
        Git.checkout(worktree_path, current_sha)

        abs_node_path = Path.join(worktree_path, node_path)
        type = if File.dir?(abs_node_path), do: :directory, else: :file

        # Construct Initial State
        phylo_node = PhyloGraphNode.new(worktree_path, current_sha)

        # We need to ensure the context node can be loaded.
        # Since we are just planning/realizing, we use the path.
        context_node = ContextNode.load(node_path, worktree_path)

        state = %{context_node: context_node, phylo_node: phylo_node}

        # Step 2: Plan
        plan_objective = Prompts.genesis_plan(type, node_path, context_instruction)

        agent_module =
          if type == :directory,
            do: EvoGit.Agent.Genesis.Directory,
            else: EvoGit.Agent.Genesis.File

        agent_opts = Keyword.put_new(opts, :agent_module, agent_module)

        with {:ok, plan_state, _plan_response} <-
               EvoGit.Task.mutate(state, plan_objective, agent_opts),
             # Step 3: Realize
             realize_objective = Prompts.genesis_realize(type, node_path),
             {:ok, realize_state, realize_response} <-
               EvoGit.Task.mutate(plan_state, realize_objective, agent_opts) do
          has_readme? =
            type == :directory and File.exists?(Path.join(abs_node_path, "README.md"))

          {:ok, realize_state, realize_response, has_readme?}
        else
          error ->
            Logger.error("Genesis: Failed to evolve #{node_path}: #{inspect(error)}")
            {:error, error}
        end
      end)

    case evolution_result do
      {:ok, realize_state, agent_response, has_readme?} ->
        # Step 4: Recursion
        # Find children returned by the agent
        new_sha = realize_state.phylo_node.current_commit
        children = agent_response

        children =
          cond do
            is_binary(children) ->
              case JSON.decode(children) do
                {:ok, decoded} when is_list(decoded) -> decoded
                _ -> []
              end

            is_list(children) ->
              children

            true ->
              []
          end

        # Only keep valid string paths
        children = Enum.filter(children, &is_binary/1)

        # Ensure paths are relative to root if they are just basenames
        children =
          Enum.map(children, fn child ->
            if node_path == "." or String.starts_with?(child, node_path <> "/") do
              child
            else
              Path.join(node_path, child)
            end
          end)

        children =
          if has_readme? do
            readme_path =
              if node_path == ".", do: "README.md", else: Path.join(node_path, "README.md")

            if readme_path in children do
              children
            else
              [readme_path | children]
            end
          else
            children
          end

        recurse_children(new_sha, node_path, children, opts)

      error ->
        error
    end
  end

  @ignored_names [
    ".git",
    "node_modules",
    ".venv",
    "__pycache__",
    "CONTEXT.md",
    "package-lock.json",
    "yarn.lock",
    "uv.lock"
  ]

  # We also ignore any paths that start with "." to avoid hidden files/directories
  @ignore_prefixes "."

  defp recurse_children(base_sha, node_path, explicit_children, opts) do
    Logger.debug("Recursive down to explicitly provided child nodes of #{base_sha} #{node_path}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    # Filter children by hardcoded names and self
    pre_filtered =
      explicit_children
      |> Enum.reject(fn p ->
        name = Path.basename(p)

        name in @ignored_names or p == node_path or
          String.starts_with?(name, @ignore_prefixes)
      end)

    # Further filter with .gitignore if there are any children left
    valid_children =
      if pre_filtered == [] do
        []
      else
        not_ignored =
          case Git.check_ignore(repo_path, pre_filtered) do
            {:ok, ignored} -> pre_filtered -- ignored
            _ -> pre_filtered
          end

        if not_ignored == [] do
          []
        else
          args = ["ls-tree", "--name-only", base_sha, "--" | not_ignored]

          case Git.run(args, repo_path) do
            {:ok, output} ->
              existing_paths = String.split(output, "\n", trim: true)
              Enum.filter(not_ignored, &(&1 in existing_paths))

            _ ->
              []
          end
        end
      end

    Logger.debug("Found children of #{node_path}: #{inspect(explicit_children)}")

    if valid_children == [] do
      {:ok, base_sha}
    else
      Logger.info(
        "Genesis: Recursing into explicitly provided children of #{node_path}: #{inspect(valid_children)}"
      )

      process_children_parallel(base_sha, valid_children, opts)
    end
  end

  defp process_children_parallel(base_sha, children, opts) do
    # Build sub-agent functions for each child
    funs =
      Enum.map(children, fn child_path ->
        fn _worktree_path ->
          evolve_node(base_sha, child_path, "Inherit context from parent", opts)
        end
      end)

    # Spawn all children through the scheduler.
    # The parent agent becomes :waiting, its worktree is reclaimable.
    results =
      if AgentScheduler.current_agent_id() do
        AgentScheduler.spawn_sub_agents(funs)
      else
        # Fallback for top-level calls not inside a scheduled agent:
        # run each as a top-level agent
        Enum.map(funs, fn fun -> AgentScheduler.run_agent(fun) end)
      end

    # Collect results and merge them sequentially into the base
    Enum.reduce_while(results, base_sha, fn
      {:ok, child_sha}, current_base ->
        Logger.info(
          "Genesis: Merging child #{String.slice(child_sha, 0, 7)} into #{String.slice(current_base, 0, 7)}"
        )

        case merge_branch(current_base, child_sha, opts) do
          {:ok, new_base} -> {:cont, new_base}
          error -> {:halt, error}
        end

      {:error, reason}, _ ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:error, _} = err -> err
      sha when is_binary(sha) -> {:ok, sha}
    end
  end

  defp merge_branch(base_sha, other_sha, opts) do
    AgentScheduler.run_agent(fn worktree_path ->
      phylo_node = PhyloGraphNode.new(worktree_path, base_sha)
      {:ok, context_node} = ContextNode.load(".", worktree_path)
      state = %{context_node: context_node, phylo_node: phylo_node}

      case EvoGit.Task.resolve_conflict(state, other_sha, opts) do
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
