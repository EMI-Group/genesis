defmodule EvoGit.Agent.Tools do
  @moduledoc """
  Tool implementations for the coding agent.

  This module coordinates all available tools, delegating their implementation
  to specialized modules in the `EvoGit.Agent.Tools` namespace.
  """

  alias EvoGit.Agent.Tools.FileRead
  alias EvoGit.Agent.Tools.FileCreate
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
      FileCreate.schema(),
      FileWrite.schema(),
      FileEdit.schema(),
      MakeDir.schema(),
      Context.read_schema(),
      Context.write_schema(),
      Bash.schema(),
      Ripgrep.schema(),
      Glob.schema(),
      ListDirectory.schema(),
      WebSearch.schema(),
      # Git.schema(),
      # Curl.schema()
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
  - `node_path` - Optional path to the agent's assigned node for spatial
    contract validation. Used to ensure file operations stay within scope.

  """
  def execute(tool_name, args, repo_path, repo_root \\ nil, node_path \\ nil) do
    execute_tool(tool_name, args, repo_path, repo_root, node_path)
  end

  # Tool execution dispatch

  defp execute_tool("read_file", args, repo_path, repo_root, _node_path) do
    FileRead.execute(args, repo_path, repo_root)
  end

  defp execute_tool("create_files", args, repo_path, repo_root, node_path) do
    FileCreate.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("write_file", args, repo_path, repo_root, node_path) do
    FileWrite.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("edit_file", args, repo_path, repo_root, node_path) do
    FileEdit.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("make_dir", args, repo_path, repo_root, node_path) do
    MakeDir.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("read_context", args, repo_path, repo_root, _node_path) do
    Context.execute_read(args, repo_path, repo_root)
  end

  defp execute_tool("write_context", args, repo_path, repo_root, _node_path) do
    Context.execute_write(args, repo_path, repo_root)
  end

  defp execute_tool("run_bash", args, repo_path, repo_root, _node_path) do
    Bash.execute(args, repo_path, repo_root)
  end

  defp execute_tool("rg", args, repo_path, repo_root, _node_path) do
    Ripgrep.execute(args, repo_path, repo_root)
  end

  defp execute_tool("run_git", args, repo_path, repo_root, _node_path) do
    Git.execute(args, repo_path, repo_root)
  end

  defp execute_tool("glob", args, repo_path, repo_root, _node_path) do
    Glob.execute(args, repo_path, repo_root)
  end

  defp execute_tool("list_dir", args, repo_path, repo_root, _node_path) do
    ListDirectory.execute(args, repo_path, repo_root)
  end

  defp execute_tool("search_web", args, repo_path, repo_root, _node_path) do
    WebSearch.execute(args, repo_path, repo_root)
  end

  defp execute_tool("curl", args, repo_path, repo_root, _node_path) do
    Curl.execute(args, repo_path, repo_root)
  end

  defp execute_tool(unknown_tool, _args, _repo_path, _repo_root, _node_path) do
    "Error: Unknown tool '#{unknown_tool}'"
  end
end
