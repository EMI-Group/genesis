defmodule EvoGit.Task do
  @moduledoc """
  An Agent is a stateless function: NewState = Agent(State, Objective).

  Task orchestrates agent execution through the AgentScheduler, which handles
  worktree preparation and state management via ETS.
  """
  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Generalist
  alias EvoGit.AgentSpec
  alias EvoGit.Core.PhyloGraphNode
  require Logger

  @type state :: EvoGit.Agent.state()
  @type objective :: String.t()

  @doc """
  Dispatches an agent through the AgentScheduler to mutate the codebase.

  The scheduler handles worktree assignment, Git checkout, and ETS state storage.
  The agent reads its spatial/temporal state from ETS during execution.

  The phylo_node's base_commit is preserved across mutations. Only current_commit
  advances as the agent commits changes.
  """
  def mutate(
        %{context_node: context_node, phylo_node: phylo_node} = _state,
        objective,
        opts \\ []
      ) do
    sha = phylo_node.current_commit

    Logger.info(
      "Agent starting for #{context_node.path} on #{String.slice(sha, 0, 7)}" <>
        " (base: #{String.slice(phylo_node.base_commit, 0, 7)})"
    )

    prompt =
      "Objective: #{objective}\n" <>
        "You are an EvoGit Agent. Your task is to modify the code to satisfy the objective.\n" <>
        "You have access to the files in the current directory.\n" <>
        "Modify the files as needed."

    agent_module = Keyword.get(opts, :agent_module, Generalist)
    caller_pid = Keyword.get(opts, :caller_pid, self())

    spec = AgentSpec.new(context_node, phylo_node, agent_module, prompt, caller_pid: caller_pid)

    EvoGit.AgentScheduler.run_agent(spec)
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

    caller_pid = Keyword.get(opts, :caller_pid, self())
    {:ok, context_node} = EvoGit.Core.ContextNode.load(".", phylo_node.repo)

    result =
      AgentSpec.new(context_node, phylo_node, Generalist, diag_prompt, caller_pid: caller_pid)
      |> EvoGit.AgentScheduler.run_agent()

    case result do
      {:ok, %{"path" => path}} ->
        validate_path(String.trim(path), files)

      {:ok, %{"response" => path}} ->
        validate_path(String.trim(path), files)

      {:ok, text} when is_binary(text) ->
        path = text |> String.split() |> List.last() |> String.trim()
        validate_path(path, files)

      error ->
        Logger.error("Diagnosis failed: #{inspect(error)}")
        "."
    end
  end

  defp validate_path(path, files) do
    if path == "." or path in files or (path <> "/") in files or
         Enum.any?(files, &String.starts_with?(&1, path <> "/")) do
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

        updated_phylo_node = %PhyloGraphNode{
          repo: worktree_path,
          base_commit: phylo_node.base_commit,
          current_commit: new_sha
        }

        {:ok, %{state | phylo_node: updated_phylo_node}}

      {:conflict, _} ->
        {:ok, conflicts} = Git.conflict_files(worktree_path)
        caller_pid = Keyword.get(opts, :caller_pid, self())

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

          conflict_phylo = PhyloGraphNode.new(worktree_path, current_sha)

          AgentSpec.new(context_node, conflict_phylo, Generalist, prompt, caller_pid: caller_pid)
          |> EvoGit.AgentScheduler.run_agent()
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
