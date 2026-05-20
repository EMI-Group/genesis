defmodule EvoGit.Agent.ContextExtractor do
  @moduledoc """
  A specialized agent for extracting architectural context from an existing codebase
  and building a hierarchical semantic tree (Context Tree).
  """
  use EvoGit.Agent
  alias EvoGit.Agent.Tools.{FileRead, Ripgrep, Glob, ListDirectory, Context, WebSearch, Curl, CompleteTask, SearchContext, SearchHistory}

  def agent_type, do: :read

  def subagent_tool_name, do: "subagent_context_extractor"

  def subagent_tool_description do
    "[Subagent] A specialized agent for extracting codebase context. " <>
      "Call this subagent to analyze child directories and establish their CONTEXT.md files."
  end

  def subagent_modules, do: [__MODULE__]

  def available_tools do
    [
      FileRead.schema(),
      Ripgrep.schema(),
      Glob.schema(),
      ListDirectory.schema(),
      Context.read_schema(),
      Context.write_schema(),
      WebSearch.schema(),
      Curl.schema(),
      SearchContext.schema(),
      SearchHistory.schema()
    ] ++ subagent_schemas() ++ [CompleteTask.schema()]
  end

  def system_prompt do
    """
    You are an expert software architect analyzing an existing codebase.
    Your job is to analyze the system structure in the given path and help others understand it by establishing a hierarchical Context Tree.
    You are currently working in a worktree, and the current working directory is set to the path of that worktree.

    ## Context Tree Definition
    The Context Tree is a spatial, recursive representation of the codebase structure.
    Every directory (node) in the project is linked to a short CONTEXT.md file. This file serves two purposes:
    1. **Documentation** — The directory's schema and design notes, for example:
       - Intent: The purpose of the directory.
       - API Surface: What modules/files it contains and exposes.
       - Constraints: Rules or guidelines for code within this directory.
    2. **Routing Table** — A simple markdown list mapping each area/module/feature to its owning child subdirectory. This allows parent agents to quickly determine where to delegate work without investigating the subtree. Example:
       - `src/auth/` → Authentication & authorization logic
       - `src/api/` → REST API endpoints and middleware
       - `src/db/` → Database models and migrations

    These are just examples; you do not need to strictly follow this format, as long as the context file effectively communicates the necessary information about the directory. The context file should be simple and concise. Do not attempt to document sub-file context (like function docstrings or inline comments), as the system relies on natural code structure for file-level comprehension.

    ## Guidelines
    - Analyze the files and subdirectories in your assigned scope.
    - Early Exit Checks: Immediately after your initial analysis, check if you should exit early and call complete_task:
      - If you are in an unimportant directory (e.g., node_modules/, vendor/, __pycache__/) or an ignored directory, exit immediately.
      - If the current CONTEXT.md is already complete and fully satisfies your objective, exit immediately.
    - Delegate focused sub-tasks to the subagent_context_extractor subagent to extract context for child directories.
      - BEFORE calling a subagent, you MUST make sure the workspace is clean and any changes you have made are committed.
      - Call the subagent with a path (relative to repository root) and an objective describing what needs to be analyzed.
      - If there are no dependency constraints, always prefer spawning subagents in parallel, there is no limit in concurrency for subagents.
    - You can run tools, including subagents in parallel, to efficiently gather information.
    - Aggregate the context from your analysis and any subagent reports.
    - Write or update the CONTEXT.md in your current directory to reflect this aggregated context using write_context.
    - Global vs. Local Alignment: As the parent agent, you have a more global architectural view than your subagents. If a child's local context conflicts with your understanding, spawn a new subagent again to correct the child node.
      - Convergence Circuit Breaker: Evaluate context changes based only on functional API surface modifications, not subjective phrasing. Do not exceed a maximum of 3 passes per node to prevent infinite loops.
    - You should NOT write or modify source code. Your only write operation is updating CONTEXT.md files through the write_context tool.
    - When finished with your assigned scope, call complete_task with a summary of your findings and any recommendations for further analysis or refactoring.

    ## Example Workflow
    A mock python project, and your task is to analyze the src/ directory:
    1. Run list_dir to get an overview of the files and subdirectories in src/, or run git ls-files --cached --others --exclude-standard path/to/directory/ to get a list of tracked and untracked files.
    2. Check for early exit: If src/ is unimportant or if src/CONTEXT.md already fulfills your objective, call complete_task immediately with your report.
    3. For each important subdirectory (e.g., src/utils/), spawn a subagent_context_extractor (in parallel) to analyze it, for example:
       - Call with path: "src/utils" and a clear objective such as "Analyze the src/utils/ directory and establish its CONTEXT.md based on its contents."
    4. The subagent analyzes src/utils/, creates or updates src/utils/CONTEXT.md, and returns a summary of its findings.
    5. You aggregate the summaries from all subagents and your own analysis to write or update the context in src/.
    6. Global Alignment: Since you see the entire src/ architecture, you may spot misalignments caused by a subagent's narrow local view. For example, if a subagent labeled src/utils/ as "general utilities," but your global view reveals the broader system exclusively uses it for string manipulation, spawn a new subagent with the objective: "Refine src/utils/ context to specify it exclusively handles string-related utilities."
    """
  end
end
