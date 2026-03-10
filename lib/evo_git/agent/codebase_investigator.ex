defmodule EvoGit.Agent.CodebaseInvestigator do
  @moduledoc """
  A specialized agent for codebase investigation, possessing read-only and search tools.
  """
  use EvoGit.Agent.Coder

  # Override available_tools to restrict to read-only/search tools
  def available_tools do
    [
      EvoGit.Agent.Tools.schema("read_file"),
      EvoGit.Agent.Tools.schema("read_many_files"),
      EvoGit.Agent.Tools.schema("rg"),
      EvoGit.Agent.Tools.schema("glob"),
      EvoGit.Agent.Tools.schema("list_directory"),
      # injected by use EvoGit.Agent.Coder
      completion_schema()
    ]
  end

  # We use the default execute_tool(call, state) implementation from Coder
end
