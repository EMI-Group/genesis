defmodule EvoGit.Agent.Tools do
  @moduledoc """
  Tool implementations for the coding agent.

  This module coordinates all available tools, delegating their implementation
  to specialized modules in the `EvoGit.Agent.Tools` namespace.
  """

  alias EvoGit.Agent.Tools.FileRead
  alias EvoGit.Agent.Tools.FileWrite
  alias EvoGit.Agent.Tools.FileEdit
  alias EvoGit.Agent.Tools.MakeDir
  alias EvoGit.Agent.Tools.Context
  alias EvoGit.Agent.Tools.Bash
  alias EvoGit.Agent.Tools.Ripgrep
  alias EvoGit.Agent.Tools.Git
  alias EvoGit.Agent.Tools.Glob
  alias EvoGit.Agent.Tools.ListDirectory
  alias EvoGit.Agent.Tools.WebSearch
  alias EvoGit.Agent.Tools.Curl

  @doc """
  Returns a list of all available tool schemas for ReqLLM.

  Note: The CompleteTask schema is NOT included here as it is handled
  specially in the agent loop. It is manually injected in available_tools/0.
  """
  def schemas do
    [
      FileRead.schema(),
      FileWrite.schema(),
      FileEdit.schema(),
      MakeDir.schema(),
      Context.read_schema(),
      Context.write_schema(),
      Bash.schema(),
      Ripgrep.schema(),
      Git.schema(),
      Glob.schema(),
      ListDirectory.schema(),
      WebSearch.schema(),
      Curl.schema()
    ]
  end

  @doc """
  Executes a tool by name with the given arguments.

  ## Parameters

  - `tool_name` - The name of the tool to execute
  - `args` - The arguments to pass to the tool
  - `repo_path` - The working directory path for file operations
  - `repo_root` - Optional path to the git repository root. If provided,
    this is passed to sandbox operations to allow write access to the shared
    git database (needed for git worktrees).

  """
  def execute(tool_name, args, repo_path, repo_root \\ nil) do
    execute_tool(tool_name, args, repo_path, repo_root)
  end

  # Tool execution dispatch

  defp execute_tool("read_file", args, repo_path, repo_root) do
    FileRead.execute(args, repo_path, repo_root)
  end

  defp execute_tool("file_write", args, repo_path, repo_root) do
    FileWrite.execute(args, repo_path, repo_root)
  end

  defp execute_tool("file_edit", args, repo_path, repo_root) do
    FileEdit.execute(args, repo_path, repo_root)
  end

  defp execute_tool("make_dir", args, repo_path, repo_root) do
    MakeDir.execute(args, repo_path, repo_root)
  end

  defp execute_tool("context_read", args, repo_path, repo_root) do
    Context.execute_read(args, repo_path, repo_root)
  end

  defp execute_tool("context_write", args, repo_path, repo_root) do
    Context.execute_write(args, repo_path, repo_root)
  end

  defp execute_tool("bash", args, repo_path, repo_root) do
    Bash.execute(args, repo_path, repo_root)
  end

  defp execute_tool("rg", args, repo_path, repo_root) do
    Ripgrep.execute(args, repo_path, repo_root)
  end

  defp execute_tool("git", args, repo_path, repo_root) do
    Git.execute(args, repo_path, repo_root)
  end

  defp execute_tool("glob", args, repo_path, repo_root) do
    Glob.execute(args, repo_path, repo_root)
  end

  defp execute_tool("list_dir", args, repo_path, repo_root) do
    ListDirectory.execute(args, repo_path, repo_root)
  end

  defp execute_tool("web_search", args, repo_path, repo_root) do
    WebSearch.execute(args, repo_path, repo_root)
  end

  defp execute_tool("curl", args, repo_path, repo_root) do
    Curl.execute(args, repo_path, repo_root)
  end

  defp execute_tool(unknown_tool, _args, _repo_path, _repo_root) do
    "Error: Unknown tool '#{unknown_tool}'"
  end
end
