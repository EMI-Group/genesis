defmodule EvoGit.Agent.ContextExtractor do
  @moduledoc """
  A specialized agent for extracting architectural context from an existing codebase
  and building a hierarchical semantic tree (Context Tree).
  """
  use EvoGit.Agent

  def subagent_tool_name, do: "subagent_context_extractor"

  def subagent_tool_description do
    "[Subagent] A specialized agent for extracting codebase context. " <>
      "Call this subagent to analyze child directories and establish their CONTEXT.md files."
  end

  def subagent_modules, do: [__MODULE__]

  def available_tools do
    [
      EvoGit.Agent.Tools.schema("read_file"),
      EvoGit.Agent.Tools.schema("read_many_files"),
      EvoGit.Agent.Tools.schema("rg"),
      EvoGit.Agent.Tools.schema("glob"),
      EvoGit.Agent.Tools.schema("list_directory"),
      EvoGit.Agent.Tools.schema("read_dir_context"),
      EvoGit.Agent.Tools.schema("rewrite_dir_context"),
      completion_schema()
    ] ++ subagent_schemas()
  end

  def system_prompt do
    """
    You are an expert software architect analyzing an existing codebase.
    Your job is to analyze the system structure in the given path and help others understand it by establishing a hierarchical Context Tree.

    ## Context Tree Definition
    The Context Tree is a spatial, recursive representation of the codebase structure.
    Every directory (node) in the project is linked to a `CONTEXT.md` file. This file acts as the directory's schema, documentation, for example:
    1. Intent: The purpose of the directory.
    2. API Surface: What modules/files it contains and exposes, and basic examples of how to use them.
    3. Constraints: Rules for child files and subdirectories, such as naming conventions, coding standards etc.
    Everything that belongs to that directory should be described in its context.

    ## Guidelines

    - Analyze the files and subdirectories in your assigned scope.
    - Delegate focused sub-tasks to the `subagent_context_extractor` sub-agent to extract context for child directories.
      - BEFORE calling a subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
      - Each sub-extractor receives a fresh context, so provide a self-contained objective describing what it needs to analyze within its assigned directory.
      - You should NOT recurse into unimportant directories (e.g., `node_modules/`, `vendor/`, `__pycache__/`) or files (e.g., compiled binaries, logs) or ignored directories. Focus on source code and relevant documentation.
    - Aggregate the context from your analysis and any sub-agent reports.
    - Write or update the `CONTEXT.md` in your current directory to reflect this aggregated context using `rewrite_dir_context`.
    - If discrepancies exist between a parent and child context, spawn sub-agents to modify the child nodes.
    - You should NOT write or modify source code. Your only write operation is updating CONTEXT.md files through the `rewrite_dir_context` tool.
    - When finished with your assigned scope, call `complete_task` with a summary of your findings and any recommendations for further analysis or refactoring.

    # Example Workflow
    A mock python project, and your task is to analyze the `src/` directory:
    1. run `list_directory` to get an overview of the files and subdirectories in `src/`, or run `git ls-files --cached --others --exclude-standard path/to/directory/` to get a list of tracked and untracked files.
    2. For each important subdirectory (e.g., `src/utils/`), spawn a `subagent_context_extractor` to analyze it:
       - Provide the sub-agent with a clear objective, such as "Analyze the `src/utils/` directory and establish its CONTEXT.md based on its contents."
    3. The sub-agent analyzes `src/utils/`, creates or updates `src/utils/CONTEXT.md`, and returns a summary of its findings.
    4. You aggregate the summaries from all sub-agents and your own analysis to write or update `src/CONTEXT.md`.
    5. Based on your findings, you might find certain sub-agents' contexts are misaligned with the parent context. You can then spawn additional sub-agents to resolve these discrepancies by modifying the child contexts.
    """
  end
end
