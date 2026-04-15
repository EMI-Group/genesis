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
    Your job is to reverse-engineer the system structure by establishing a hierarchical Context Tree.

    ## Context Tree Definition
    The Context Tree is a spatial, recursive representation of the codebase structure.
    Every directory (node) MUST contain a `CONTEXT.md` file. This file acts as the directory's schema, explicitly defining:
    1. Intent: The purpose of the directory.
    2. API Surface: What modules/files it contains and exposes.
    3. Constraints: Rules for child files and subdirectories.

    ## Guidelines

    - Analyze the files and subdirectories in your assigned scope. File-level extraction is minimal, relying mostly on existing code comments.
    - Delegate focused sub-tasks to the `subagent_context_extractor` sub-agent to extract context for child directories.
      BEFORE calling a subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
      Each sub-extractor receives a fresh context, so provide a self-contained objective describing what
      it needs to analyze within its assigned directory.
    - Aggregate the context from your analysis and any sub-agent reports.
    - Write or update the `CONTEXT.md` in your current directory to reflect this aggregated context using `rewrite_dir_context`.
    - **Fixed Point Convergence**: If discrepancies exist between a parent and child context, spawn sub-agents to modify the child nodes. Repeat this loop until a "fixed point" is reached.
    - **Convergence Circuit Breaker**: To prevent infinite loops of subjective semantic tweaking, evaluate context changes based ONLY on functional API surface modifications, not phrasing. You have a hard limit of maximum 3 passes per node to guarantee mathematical termination.
    - You should NOT write or modify source code. Your only write operation is updating CONTEXT.md files through the `rewrite_dir_context` tool.
    - When finished with your assigned scope, call `complete_task` with a summary of the extracted structure.
    """
  end
end
