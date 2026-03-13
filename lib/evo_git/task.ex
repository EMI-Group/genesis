defmodule EvoGit.Task do
  @moduledoc """
  An Agent is a stateless function: NewState = Agent(State, Objective).
  """
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Generalist
  alias EvoGit.Core.PhyloGraphNode
  require Logger

  @type state :: EvoGit.Agent.state()
  @type objective :: String.t()

  @doc """
  Executes the agent logic inside the given worktree.
  """
  def mutate(%{context_node: context_node, phylo_node: phylo_node} = state, objective, opts \\ []) do
    worktree_path = phylo_node.repo
    sha = phylo_node.current_commit

    Logger.info("Agent starting for #{context_node.path} on #{String.slice(sha, 0, 7)}")

    # 1. Checkout the correct commit in the assigned worktree
    # Clean first to be safe
    Git.clean(worktree_path)
    Git.checkout(worktree_path, sha)

    # 2. Construct Context (delegated to Agent.Coder)
    # The inner coding agent will dynamically load the Context Tree
    # 3. Call Generalist
    prompt =
      "Objective: #{objective}\n" <>
        "You are an EvoGit Agent. Your task is to modify the code to satisfy the objective.\n" <>
        "You have access to the files in the current directory.\n" <>
        "Modify the files as needed."

    caller_pid = Keyword.get(opts, :caller_pid, self())
    agent_opts = Keyword.merge(opts, repo_path: worktree_path, node_path: context_node.path)

    agent_module = Keyword.get(opts, :agent_module, Generalist)

    case agent_module.run(prompt, caller_pid, agent_opts) do
      {:ok, response} ->
        # 4. Commit changes
        case PhyloGraphNode.add_and_commit(phylo_node, "Agent: #{objective}") do
          {:ok, updated_phylo_node} ->
            Logger.info("Agent: Committed changes")
            {:ok, %{state | phylo_node: updated_phylo_node}, response}

          error ->
            Logger.error("Agent commit failed: #{inspect(error)}")
            {:error, :commit_failed}
        end

      error ->
        Logger.error("Agent call failed: #{inspect(error)}")
        {:error, :agent_call_failed}
    end
  end

  @doc """
  Identifies the most relevant target path for the given objective in the context of the commit.
  Acts as an "Analyst Agent".
  """
  def diagnose(%PhyloGraphNode{current_commit: commit_sha} = phylo_node, objective, opts \\ []) do
    Logger.info("Agent diagnosing objective on #{String.slice(commit_sha, 0, 7)}: #{objective}")

    # Use PhyloGraphNode to get the file tree
    {:ok, files} = PhyloGraphNode.list_files(phylo_node)
    file_tree = Enum.join(files, "\n")

    diag_prompt =
      "Objective: #{objective}\n" <>
        "File Tree:\n#{file_tree}\n" <>
        "Identify the single most relevant directory or file path to modify.\n" <>
        "Return ONLY the path as a JSON string under key 'path'."

    # Diagnosis uses Generalist directly on the current context
    caller_pid = Keyword.get(opts, :caller_pid, self())
    agent_opts = Keyword.merge(opts, repo_path: File.cwd!(), node_path: ".")

    case Generalist.run(diag_prompt, caller_pid, agent_opts) do
      {:ok, %{"path" => path}} ->
        validate_path(String.trim(path), files)

      {:ok, %{"response" => path}} ->
        validate_path(String.trim(path), files)

      {:ok, text} when is_binary(text) ->
        # Heuristic extraction
        path = text |> String.split() |> List.last() |> String.trim()
        validate_path(path, files)

      error ->
        Logger.error("Diagnosis failed: #{inspect(error)}")
        # Fallback to root if diagnosis fails
        "."
    end
  end

  defp validate_path(path, files) do
    if path == "." or path in files or (path <> "/") in files or
         Enum.any?(files, &String.starts_with?(&1, path <> "/")) do
      # It's a valid file or directory (prefix of some file)
      path
    else
      Logger.warning("Agent: Diagnosed path '#{path}' not found in tree, falling back to root.")
      "."
    end
  end

  @doc """
  Resolves conflicts between the current state and an incoming commit SHA.
  """
  def resolve_conflict(
        %{context_node: context_node, phylo_node: phylo_node} = state,
        incoming_sha,
        opts \\ []
      ) do
    worktree_path = phylo_node.repo
    current_sha = phylo_node.current_commit

    Logger.info(
      "Agent resolving conflict between #{String.slice(current_sha, 0, 7)} and #{String.slice(incoming_sha, 0, 7)}"
    )

    # 1. Setup
    Git.clean(worktree_path)
    Git.checkout(worktree_path, current_sha)

    # 2. Merge
    case Git.merge(worktree_path, incoming_sha) do
      {:ok, _} ->
        # Auto-merge successful
        {:ok, new_sha} = Git.rev_parse(worktree_path)
        updated_phylo_node = PhyloGraphNode.new(worktree_path, new_sha)
        {:ok, %{state | phylo_node: updated_phylo_node}}

      {:conflict, _} ->
        # 3. Context (delegated to Agent.Coder)
        # The inner coding agent will dynamically load the Context Tree

        # 4. Resolve
        {:ok, conflicts} = Git.conflict_files(worktree_path)

        caller_pid = Keyword.get(opts, :caller_pid, self())
        agent_opts = Keyword.merge(opts, repo_path: worktree_path, node_path: context_node.path)

        Enum.each(conflicts, fn file ->
          abs_file = Path.join(worktree_path, file)

          file_content =
            case File.read(abs_file) do
              {:ok, content} -> "File: #{abs_file}\n```\n#{content}\n```"
              _ -> ""
            end

          prompt =
            "Objective: Resolve the merge conflicts in '#{file}'.\n" <>
              "Conflicting File Content:\n#{file_content}\n\n" <>
              "The file contains git conflict markers.\n" <>
              "You are an expert software architect. Analyze the divergent changes and unify them logically.\n" <>
              "1. Understand the intent of both branches.\n" <>
              "2. Synergize the changes if possible.\n" <>
              "3. Select the best implementation if mutually exclusive.\n" <>
              "4. Modify the file to contain ONLY the resolved code (remove markers)."

          Generalist.run(prompt, caller_pid, agent_opts)
        end)

        # 5. Commit
        msg =
          "Agent: Resolved conflicts between #{String.slice(current_sha, 0, 7)} and #{String.slice(incoming_sha, 0, 7)}"

        case PhyloGraphNode.add_and_commit(phylo_node, msg) do
          {:ok, updated_phylo_node} ->
            {:ok, %{state | phylo_node: updated_phylo_node}}

          error ->
            Logger.error("Agent resolve commit failed: #{inspect(error)}")
            {:error, :commit_failed}
        end

      error ->
        Logger.error("Merge setup failed: #{inspect(error)}")
        {:error, :merge_failed}
    end
  end
end
