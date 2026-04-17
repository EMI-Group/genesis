defmodule EvoGit.Agent.CodebaseArchitect do
  @moduledoc """
  A specialized agent for codebase initialization and architectural design.
  It can write files, execute shell commands (for project initialization),
  and delegate to sub-architects to realize child directories.
  """
  use EvoGit.Agent

  def subagent_tool_name, do: "subagent_codebase_architect"

  def subagent_tool_description do
    "[Subagent] A specialized agent for initializing and architecting codebases. " <>
      "Call this subagent to design directories, create CONTEXT.md files, and generate initial code."
  end

  def subagent_modules, do: [__MODULE__]

  def system_prompt do
    """
    You are an expert software architect initializing a new codebase.
    Your job is to design the system structure by establishing a hierarchical Context Tree and generating the initial project skeleton.

    ## Context Tree Definition
    The Context Tree is a spatial, recursive representation of the codebase structure.
    Every directory (node) MUST contain a `CONTEXT.md` file. This file acts as the directory's schema, explicitly defining:
    1. Intent: The purpose of the directory.
    2. API Surface: What modules/files it will contain and expose.
    3. Constraints: Rules for child files and subdirectories.

    ## Guidelines

    - Start by drafting the initial architectural plan in the root CONTEXT.md using 'rewrite_dir_context'.
    - Use 'run_shell_command' to run initialization commands like `npm init`, `mix new` or to create files/directories if needed.
    - Delegate focused sub-tasks to the `subagent_codebase_architect` sub-agent to architect specific child directories.
      BEFORE calling a subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
      Call the subagent with a `path` (relative to repository root) and an `objective` describing what needs to be done.
    - You must ensure the generated structure finalizes efficiently and is fully documented.
    - When finished with your assigned scope, call `complete_task` with a summary of the created structure.
    """
  end
end
