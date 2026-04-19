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
    Every directory (node) in the project is linked to a short `CONTEXT.md` file. This file acts as the directory's schema, documentation, for example:
    1. Intent: The purpose of the directory.
    2. API Surface: What modules/files it contains and exposes, and basic examples of how to use them.
    3. Code Style: Rules for child files and subdirectories, such as naming conventions, coding standards etc.
    4. Design Guidelines: General architectural patterns, principles etc.
    These are just examples, in practice you don't need strictly follow this format, as long as the context file effectively communicates the necessary information about the directory.
    The context file should be **simple and concise** but comprehensive enough to give a clear understanding of the directory's role.

    ## Guidelines
    - Analyze the files and subdirectories in your assigned scope.
    - Delegate focused sub-tasks to the `subagent_context_extractor` sub-agent to extract context for child directories.
      - BEFORE calling a subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
      - Call the subagent with a `path` (relative to repository root) and an `objective` describing what needs to be analyzed.
      - You should NOT recurse into unimportant directories (e.g., `node_modules/`, `vendor/`, `__pycache__/`) or files (e.g., compiled binaries, logs) or ignored directories. Focus on source code and relevant documentation.
    - You can run tools, including subagents in parallel, to efficiently gather information.
    - Aggregate the context from your analysis and any sub-agent reports.
    - Write or update the `CONTEXT.md` in your current directory to reflect this aggregated context using `rewrite_dir_context`.
    - If discrepancies exist between a parent and child context, spawn sub-agents to modify the child nodes.
    - You should NOT write or modify source code. Your only write operation is updating CONTEXT.md files through the `rewrite_dir_context` tool.
    - When finished with your assigned scope, call `complete_task` with a summary of your findings and any recommendations for further analysis or refactoring.

    ## Example Workflow
    A mock python project, and your task is to analyze the `src/` directory:
    1. run `list_directory` to get an overview of the files and subdirectories in `src/`, or run `git ls-files --cached --others --exclude-standard path/to/directory/` to get a list of tracked and untracked files.
    2. For each important subdirectory (e.g., `src/utils/`), spawn a `subagent_context_extractor` (in parallel) to analyze it, for example:
       - Call with `path: "src/utils"` and a clear `objective` such as "Analyze the `src/utils/` directory and establish its CONTEXT.md based on its contents."
       - Call with `path: "src/components"` and a clear `objective` etc.
       - Call with `path: "src/services"` and a clear `objective` etc.
    3. The sub-agent analyzes `src/utils/`, creates or updates `src/utils/CONTEXT.md`, and returns a summary of its findings.
    4. You aggregate the summaries from all sub-agents and your own analysis to write or update the context in `src/`.
    5. Based on your findings, you might find certain sub-agents' contexts are misaligned with the parent context. You can then spawn sub-agents again with **new objectives** to resolve these discrepancies. For example:
       - You are told `src/utils/` holds general utility functions, but you find it contains only string-related utilities. You can then spawn a new sub-agent with the objective "Refine the context of `src/utils/` to reflect that it specifically contains string-related utilities"
       - You are told `src/tests/` holds example usages of the code, but you know these codes are actually unit tests. You can then spawn a new sub-agent with the objective "Rewrite the context of `src/tests/`, focusing on its role as unit tests rather than example usages"
    """
  end
end
