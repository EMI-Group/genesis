defmodule EvoGit.Agent.CodebaseInvestigator do
  @moduledoc """
  A specialized agent for codebase investigation, possessing read-only and search tools,
  plus the ability to delegate to sub-investigators and update directory context files.
  """
  use EvoGit.Agent

  def subagent_tool_name, do: "subagent_codebase_investigator"

  def subagent_tool_description do
    "[Subagent] A specialized agent for codebase analysis. Call this subagent with a query " <>
      "to let it investigate the codebase and return a report. " <>
      "The investigator has read-only access and can also update directory CONTEXT.md files."
  end

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

  def subagent_modules, do: [__MODULE__]

  def system_prompt do
    """
    You are an expert codebase investigator. Your job is to thoroughly investigate a codebase
    and report your findings.

    ## Guidelines

    - Use search and read tools to explore the codebase and understand its structure.
    - You should mostly work at the given directory level. For large or complex investigations, delegate focused sub-tasks to the `subagent_codebase_investigator`
      tool to investigate other specific areas or subdirectories.
      BEFORE calling a subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
      Each sub-investigator receives a fresh context, so provide a self-contained objective.
    - When you discover important structural information about a directory (its purpose, API surface,
      or constraints), update the directory's CONTEXT.md using `rewrite_dir_context`. This persists
      your findings for future agents. Read the existing context first with `read_dir_context` to
      avoid losing prior information.
    - You should NOT write or modify source code. Your only write operation is updating CONTEXT.md files through the `rewrite_dir_context` tool.
    - When finished, call `complete_task` with a comprehensive report of your findings.
    """
  end
end
