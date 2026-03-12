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
    base_prompt = """
    Target Directory: '#{node_path}'.
    User Request: #{instruction}
    Task: Your job is to define the architectural context for this specific directory.
    1. Create or update a 'CONTEXT.md' file inside this directory (i.e. at '#{if node_path == ".", do: "", else: node_path <> "/"}CONTEXT.md'). This file must clearly define the Intent (purpose), API Surface (what modules/files it will contain), and Constraints (rules for child files/directories) for this level of the architecture.
    2. Execute any necessary shell commands to initialize boilerplate or directory structure (e.g., package managers, project generators).
    Important Constraints: Do NOT implement the actual code or content of any source files yet. Do NOT modify any files or directories outside of '#{node_path}'.
    """

    # If we are at the root level, we must instructure the LLM to init .gitignore
    if node_path == "." do
      base_prompt <>
        "\n" <>
        """
        Since this is the root directory, also initialize a .gitignore file with standard entries for the project type.
        In addition, please include project management guidelines in the 'CONTEXT.md', such as how to run tests, linting, or formatters if applicable, and how to run the main entry point if any, etc.
        """
    else
      base_prompt
    end
  end

  def genesis_plan(:file, node_path, instruction) do
    """
    Target File: '#{node_path}'.
    User Request: #{instruction}
    Task: Your job is to define the context and purpose of this specific file.
    Write a comprehensive header comment, docstring, or module-level documentation at the top of the file (located at '#{node_path}') that clearly explains its intent, responsibilities, and any constraints.
    Important Constraints: Do NOT implement the actual logic or code body yet. Just write the structural documentation/comments. Do NOT modify any other files.
    """
  end

  @doc """
  Genesis Stage: Realization Prompt for a Directory.
  """
  def genesis_realize(:directory, node_path) do
    """
    Target Directory: '#{node_path}'.
    Task: Read the 'CONTEXT.md' file in this directory (i.e. '#{if node_path == ".", do: "", else: node_path <> "/"}CONTEXT.md') to understand its intended structure.
    Based on that context, create the immediate subdirectories and empty placeholder files that are supposed to exist inside this directory.
    Important Constraints: Do NOT write any implementation code inside these newly created files yet; just create the empty files. Do NOT modify anything outside of this directory. Remember to prepend your target directory path ('#{if node_path == ".", do: "", else: node_path <> "/"}') to all files and directories you create!
    CRITICAL: Git does not track empty directories! For every subdirectory you create, you MUST create an empty '.gitkeep' file inside it so that it is tracked by version control.
    """
  end

  def genesis_realize(:file, node_path) do
    """
    Target File: '#{node_path}'.
    Task: Read the header comment, docstring, or module documentation at the top of this file (located at '#{node_path}').
    Based on that context and intended purpose, implement the complete code logic for this file. Ensure the implementation fully satisfies the stated responsibilities.
    """
  end
end
