defmodule EvoGit.Prompts do
  @moduledoc """
  Centralized repository for all LLM prompts used in EvoGit.
  """

  @doc """
  Constructs the main instruction for the Agent loop.
  """
  def agent_mutation(objective) do
    """
    Objective: #{objective}
    You are an EvoGit Agent. Your task is to modify the code to satisfy the objective.
    You have access to the files in the current directory.
    Modify the files as needed.
    """
  end

  @doc """
  Constructs the diagnosis prompt for the Analyst Agent.
  """
  def agent_diagnosis(objective, file_tree) do
    """
    Objective: #{objective}
    File Tree:
    #{file_tree}
    Identify the single most relevant directory or file path to modify.
    Return ONLY the path as a JSON string under key 'path'.
    """
  end

  @doc """
  Constructs the conflict resolution prompt.
  """
  def agent_conflict_resolution(file) do
    """
    Objective: Resolve the merge conflicts in '#{file}'.
    The file contains git conflict markers.
    You are an expert software architect. Analyze the divergent changes and unify them logically.
    1. Understand the intent of both branches.
    2. Synergize the changes if possible.
    3. Select the best implementation if mutually exclusive.
    4. Modify the file to contain ONLY the resolved code (remove markers).
    """
  end

  @doc """
  Genesis Stage: Planning Prompt for a Directory.
  """
  def genesis_plan(:directory, node_path, instruction) do
    """
    Planning Phase for directory '#{node_path}'.
    Instruction: #{instruction}
    Task: Create or update 'CONTEXT.md' inside this directory.
    Define Intent, API Surface, and Constraints for this architectural level.
    """
  end

  def genesis_plan(:file, node_path, instruction) do
    """
    Planning Phase for file '#{node_path}'.
    Instruction: #{instruction}
    Task: Add a header comment to this file defining its purpose and constraints.
    """
  end

  @doc """
  Genesis Stage: Realization Prompt for a Directory.
  """
  def genesis_realize(:directory, node_path) do
    """
    Realization Phase for directory '#{node_path}'.
    Context is defined in CONTEXT.md of this node.
    Task: Create the immediate subdirectories and empty files specified in the context.
    Do NOT implement the content of the children files yet, just create them.
    """
  end

  def genesis_realize(:file, node_path) do
    """
    Realization Phase for file '#{node_path}'.
    Context is defined in the header comment of this node.
    Task: Implement the full code according to the header.
    """
  end
end
