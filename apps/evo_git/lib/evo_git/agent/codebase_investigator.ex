defmodule EvoGit.Agent.CodebaseInvestigator do
  @moduledoc """
  A specialized agent for codebase investigation, possessing read-only and search tools,
  plus the ability to delegate to sub-investigators and update directory context files.
  """
  use EvoGit.Agent
  alias EvoGit.Agent.Tools

  def subagent_tool_name, do: "subagent_codebase_investigator"

  def subagent_tool_description do
    "[Subagent] A specialized agent for codebase analysis. Call this subagent with a query " <>
      "to let it investigate the codebase and return a report. " <>
      "The investigator has read-only access and can also update directory CONTEXT.md files."
  end

  def available_tools do
    [
      Tools.schema(:read_file),
      Tools.schema(:read_many_files),
      Tools.schema(:rg),
      Tools.schema(:glob),
      Tools.schema(:list_directory),
      Tools.schema(:read_dir_context),
      Tools.schema(:rewrite_dir_context),
      Tools.schema(:web_search),
      Tools.schema(:web_read),
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
    - You should mostly work at the given directory level.
      For large, complex investigations or investigations in child directories, delegate focused sub-agents to investigate other specific areas or subdirectories.
      Call the subagent with a `path` (relative to repository root) and an `objective` describing what needs to be investigated.
      If you need to investigate a historical state of the codebase, you can also spawn a subagent with an optional commit SHA or branch name parameter, and the subagent will check out that state in a temporary workspace to perform the investigation.
    - You can run tools, including subagents in parallel, to efficiently gather information.
    - When you discover important structural information about a directory (its purpose, API surface,
      or constraints) that is missing in the context, update the directory's CONTEXT.md using `rewrite_dir_context`. This persists
      your findings for future agents.
    - You should NOT write or modify source code. Your only write operation is updating CONTEXT.md files through the `rewrite_dir_context` tool.
    - When finished, call `complete_task` with a comprehensive report of your findings.

    ## Example
    For example, if your task is to investigate the "API of the database access layer" of an application, and you're in the root `/` directory:
    1. Check your current context tree and identify the relevant directory node(s), use relevant tools to search for relevant files.
    2. Let's say you find some relevant files, `lib/app/db/repo.py`, `lib/app/db/models.py`, `docs/db/access.md` and `docs/db/connection.md`.
    3. Since these files belong to the child nodes, you doesn't need to read them yourself, instead you can spawn two subagents with clear objectives in `lib/app/db` and `docs/db` to investigate these two directories for you.
    4. The two subagents return their findings to you, and you summarize them in one report and call `complete_task` with the report as the result.
    """
  end
end
