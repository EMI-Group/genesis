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
  alias EvoGit.Agent.Tools.ShellTool
  alias EvoGit.Agent.Tools.Ripgrep
  alias EvoGit.Agent.Tools.Git
  alias EvoGit.Agent.Tools.Glob
  alias EvoGit.Agent.Tools.ListDirectory
  alias EvoGit.Agent.Tools.WebSearch
  alias EvoGit.Agent.Tools.Curl
  alias EvoGit.Agent.Tools.SearchHistory
  alias EvoGit.Agent.Tools.SearchContext
  alias EvoGit.Agent.Tools.SkillList
  alias EvoGit.Agent.Tools.SkillRead
  alias EvoGit.Agent.Tools.SkillAdd
  alias EvoGit.Agent.Tools.SkillEdit
  alias EvoGit.Agent.Tools.SkillRemove
  alias EvoGit.Agent.Tools.SkillEnable
  alias EvoGit.Agent.Tools.SkillDisable
  alias EvoGit.Agent.Tools.SkillWhere

  @doc """
  Returns a list of all available tool schemas for ReqLLM.

  Note: The CompleteTask schema is NOT included here as it is handled
  specially in the agent loop. It is manually injected in available_tools/0.
  """
  def schemas do
    schemas =
      [
        FileRead.schema(),
        FileCreate.schema(),
        FileWrite.schema(),
        FileEdit.schema(),
        MakeDir.schema(),
        Context.read_schema(),
        Context.write_schema(),
        Context.edit_schema(),
        ShellTool.schema(),
        Ripgrep.schema(),
        Glob.schema(),
        ListDirectory.schema(),
        SearchContext.schema(),
        SearchHistory.schema(),
        SkillList.schema(),
        SkillRead.schema(),
        SkillAdd.schema(),
        SkillEdit.schema(),
        SkillRemove.schema(),
        SkillEnable.schema(),
        SkillDisable.schema(),
        SkillWhere.schema()
        # Git.schema(),
        # Curl.schema()
      ]

    if EvoGit.Config.tools_search_enabled?() do
      schemas ++ [WebSearch.schema()]
    else
      schemas
    end
  end

  @doc """
  Returns the list of read-only tool schemas shared by read-only agents
  (CodebaseInvestigator, ContextExtractor).
  """
  def read_only_schemas do
    schemas =
      [
        FileRead.schema(),
        Ripgrep.schema(),
        Glob.schema(),
        ListDirectory.schema(),
        Context.read_schema(),
        Context.write_schema(),
        Context.edit_schema(),
        Curl.schema(),
        ShellTool.schema(),
        SearchContext.schema(),
        SearchHistory.schema()
      ]

    if EvoGit.Config.tools_search_enabled?() do
      schemas ++ [WebSearch.schema()]
    else
      schemas
    end
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
  # Compile-time tool name for dispatch (matches ShellTool's compile-time @tool_name)
  @shell_tool_name if(EvoGit.Platform.os() == :windows, do: "run_powershell", else: "run_bash")

  def execute(tool_name, args, repo_path, repo_root \\ nil, node_path \\ nil)

  def execute(tool_name, args, repo_path, repo_root, node_path) when is_map(args) do
    execute_tool(tool_name, args, repo_path, repo_root, node_path)
  end

  # Fallback: some LLMs double-encode the ENTIRE arguments object as a JSON
  # string (e.g. "{\"args\": [...]}") instead of a real JSON object. Try to
  # transparently decode it before failing, so the tool call proceeds normally.
  def execute(tool_name, args, repo_path, repo_root, node_path) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        execute_tool(tool_name, decoded, repo_path, repo_root, node_path)

      _ ->
        "Error: tool arguments were received as a JSON-encoded string instead of a JSON object. " <>
          "Pass the arguments as a real JSON object, " <>
          "e.g. {\"args\": [\"-n\", \"pattern\"]}, not a string."
    end
  end

  # Tool execution dispatch

  defp execute_tool("read_file", args, repo_path, repo_root, _node_path) when is_map(args) do
    FileRead.execute(args, repo_path, repo_root)
  end

  defp execute_tool("create_files", args, repo_path, repo_root, node_path) when is_map(args) do
    FileCreate.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("write_file", args, repo_path, repo_root, node_path) when is_map(args) do
    FileWrite.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("edit_file", args, repo_path, repo_root, node_path) when is_map(args) do
    FileEdit.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("make_dir", args, repo_path, repo_root, node_path) when is_map(args) do
    MakeDir.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("read_context", args, repo_path, repo_root, _node_path) when is_map(args) do
    Context.execute_read(args, repo_path, repo_root)
  end

  defp execute_tool("write_context", args, repo_path, repo_root, _node_path) when is_map(args) do
    Context.execute_write(args, repo_path, repo_root)
  end

  defp execute_tool("edit_context", args, repo_path, repo_root, _node_path) when is_map(args) do
    Context.execute_edit(args, repo_path, repo_root)
  end

  defp execute_tool(@shell_tool_name, args, repo_path, repo_root, _node_path) when is_map(args) do
    ShellTool.execute(args, repo_path, repo_root)
  end

  defp execute_tool("rg", args, repo_path, repo_root, _node_path) when is_map(args) do
    Ripgrep.execute(args, repo_path, repo_root)
  end

  defp execute_tool("run_git", args, repo_path, repo_root, _node_path) when is_map(args) do
    Git.execute(args, repo_path, repo_root)
  end

  defp execute_tool("glob", args, repo_path, repo_root, _node_path) when is_map(args) do
    Glob.execute(args, repo_path, repo_root)
  end

  defp execute_tool("list_dir", args, repo_path, repo_root, _node_path) when is_map(args) do
    ListDirectory.execute(args, repo_path, repo_root)
  end

  defp execute_tool("search_web", args, repo_path, repo_root, _node_path) when is_map(args) do
    WebSearch.execute(args, repo_path, repo_root)
  end

  defp execute_tool("curl", args, repo_path, repo_root, _node_path) when is_map(args) do
    Curl.execute(args, repo_path, repo_root)
  end

  defp execute_tool("search_context", args, repo_path, repo_root, _node_path) when is_map(args) do
    SearchContext.execute(args, repo_path, repo_root)
  end

  defp execute_tool("search_history", args, repo_path, repo_root, _node_path) when is_map(args) do
    SearchHistory.execute(args, repo_path, repo_root)
  end

  defp execute_tool("skill_list", args, repo_path, repo_root, _node_path) when is_map(args) do
    SkillList.execute(args, repo_path, repo_root)
  end

  defp execute_tool("skill_read", args, repo_path, repo_root, _node_path) when is_map(args) do
    SkillRead.execute(args, repo_path, repo_root)
  end

  defp execute_tool("skill_add", args, repo_path, repo_root, _node_path) when is_map(args) do
    SkillAdd.execute(args, repo_path, repo_root)
  end

  defp execute_tool("skill_edit", args, repo_path, repo_root, _node_path) when is_map(args) do
    SkillEdit.execute(args, repo_path, repo_root)
  end

  defp execute_tool("skill_remove", args, repo_path, repo_root, _node_path) when is_map(args) do
    SkillRemove.execute(args, repo_path, repo_root)
  end

  defp execute_tool("skill_enable", args, repo_path, repo_root, node_path) when is_map(args) do
    SkillEnable.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("skill_disable", args, repo_path, repo_root, node_path) when is_map(args) do
    SkillDisable.execute(args, repo_path, repo_root, node_path)
  end

  defp execute_tool("skill_where", args, repo_path, repo_root, _node_path) when is_map(args) do
    SkillWhere.execute(args, repo_path, repo_root)
  end

  defp execute_tool(unknown_tool, args, repo_path, repo_root, _node_path)
       when is_binary(unknown_tool) and is_map(args) do
    # Try dynamic skill execution — skills are loaded from .agents/skills/
    # and injected as tool schemas at agent startup
    if repo_root && is_binary(repo_root) do
      skills = EvoGit.Skills.load_skills(repo_root)

      if EvoGit.Skills.find_skill(skills, unknown_tool) do
        EvoGit.Skills.execute(skills, unknown_tool, args, repo_path)
      else
        "Error: Unknown tool '#{unknown_tool}'"
      end
    else
      "Error: Unknown tool '#{unknown_tool}'"
    end
  end
end
