defmodule EvoGit.Agent do
  @moduledoc """
  An Agent is a stateless function: NewState = Agent(State, Objective).
  """
  alias EvoGit.Adapters.Git
  alias EvoGit.Adapters.Gemini
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  require Logger

  @type state :: %{commit_sha: String.t(), node_path: String.t()}
  @type objective :: String.t()

  @doc """
  Executes the agent logic using the Gemini Pool.
  """
  def mutate(%{commit_sha: sha, node_path: node_path} = state, objective) do
    Logger.info("Agent starting for #{node_path} on #{String.slice(sha, 0, 7)}")

    Gemini.Pool.run(fn worktree_path ->
      # 1. Checkout the correct commit in the assigned worktree
      # Clean first to be safe
      Git.clean(worktree_path)
      Git.checkout(worktree_path, sha)

      # 2. Construct Context
      abs_node_path = Path.join(worktree_path, node_path)

      # Ensure the path exists (it should, as it's from the commit)
      # But if we are creating a NEW directory, it might not exist yet?
      # Genesis phase might ask for a new dir.
      # "For every new directory created... a new Agent is spawned"
      # So the directory should exist in the commit.

      context_nodes = ContextNode.hier_context(abs_node_path, worktree_path)

      context_files =
        Enum.map(context_nodes, fn node ->
          if node.type == :directory do
            Path.join(node.path, "CONTEXT.md")
          else
            node.path
          end
        end)
        |> Enum.filter(&File.exists?/1)

      # 3. Call Gemini
      prompt =
        "Objective: #{objective}\n" <>
          "You are an EvoGit Agent. Your task is to modify the code to satisfy the objective.\n" <>
          "You have access to the files in the current directory.\n" <>
          "Modify the files as needed."

      case Gemini.call(prompt, context_files, nil, cd: worktree_path) do
        {:ok, _response} ->
          # 4. Commit changes
          # We use PhyloGraphNode to encapsulate the "Commit" logic
          # But PhyloGraphNode.new/2 expects a path and a commit.
          # Here we are already IN the state.

          # We can just create a node representing this worktree
          # The SHA is what we started with
          node = PhyloGraphNode.new(worktree_path, sha)

          case PhyloGraphNode.add_and_commit(node, "Agent: #{objective}") do
            {:ok, updated_node} ->
              {:ok, %{state | commit_sha: updated_node.current_commit}}

            error ->
              Logger.error("Agent commit failed: #{inspect(error)}")
              {:error, :commit_failed}
          end

        error ->
          Logger.error("Gemini call failed: #{inspect(error)}")
          {:error, :gemini_failed}
      end
    end)
  end

  @doc """
  Resolves conflicts between the current state and an incoming commit SHA.
  """
  def resolve_conflict(%{commit_sha: current_sha, node_path: node_path} = state, incoming_sha) do
    Logger.info(
      "Agent resolving conflict between #{String.slice(current_sha, 0, 7)} and #{String.slice(incoming_sha, 0, 7)}"
    )

    Gemini.Pool.run(fn worktree_path ->
      # 1. Setup
      Git.clean(worktree_path)
      Git.checkout(worktree_path, current_sha)

      # 2. Merge
      case Git.merge(worktree_path, incoming_sha) do
        {:ok, _} ->
          # Auto-merge successful
          {:ok, new_sha} = Git.rev_parse(worktree_path)
          {:ok, %{state | commit_sha: new_sha}}

        {:conflict, _} ->
          # 3. Context
          abs_node_path = Path.join(worktree_path, node_path)
          context_nodes = ContextNode.hier_context(abs_node_path, worktree_path)

          context_files =
            Enum.map(context_nodes, fn node ->
              if node.type == :directory, do: Path.join(node.path, "CONTEXT.md"), else: node.path
            end)
            |> Enum.filter(&File.exists?/1)

          # 4. Resolve
          {:ok, conflicts} = Git.conflict_files(worktree_path)

          Enum.each(conflicts, fn file ->
            abs_file = Path.join(worktree_path, file)

            prompt =
              "Objective: Resolve the merge conflicts in '#{file}'.\n" <>
                "The file contains git conflict markers.\n" <>
                "You are an expert software architect. Analyze the divergent changes and unify them logically.\n" <>
                "1. Understand the intent of both branches.\n" <>
                "2. Synergize the changes if possible.\n" <>
                "3. Select the best implementation if mutually exclusive.\n" <>
                "4. Modify the file to contain ONLY the resolved code (remove markers)."

            # Pass absolute path of conflict file as context
            Gemini.call(prompt, context_files ++ [abs_file], nil, cd: worktree_path)
          end)

          # 5. Commit
          node = PhyloGraphNode.new(worktree_path, current_sha)

          msg =
            "Agent: Resolved conflicts between #{String.slice(current_sha, 0, 7)} and #{String.slice(incoming_sha, 0, 7)}"

          case PhyloGraphNode.add_and_commit(node, msg) do
            {:ok, updated_node} ->
              {:ok, %{state | commit_sha: updated_node.current_commit}}

            error ->
              Logger.error("Agent resolve commit failed: #{inspect(error)}")
              {:error, :commit_failed}
          end

        error ->
          Logger.error("Merge setup failed: #{inspect(error)}")
          {:error, :merge_failed}
      end
    end)
  end
end
