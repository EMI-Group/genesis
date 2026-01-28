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
  def run(%{commit_sha: sha, node_path: node_path} = state, objective) do
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
end
