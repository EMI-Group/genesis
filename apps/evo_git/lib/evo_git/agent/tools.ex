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
  alias EvoGit.Agent.Tools.RunCommand

  # Tools that mutate the system (files, git, shell, skills). Repo-less agents
  # (chatbot-style, no worktree) must never touch git or write files, and
  # agents operating inside a READ-ONLY foreign repo must not modify anything —
  # `execute/5` blocks these for such agents as defense-in-depth.
  # NOTE: `run_command` (the task-control shell tool) is deliberately NOT here —
  # it is a control tool, not a write tool, and must NOT be blocked by the
  # repo-less guard: the self-reflective agent IS the repo-less agent that
  # needs it to control tasks.
  @write_tools [
    "create_files",
    "write_file",
    "edit_file",
    "make_dir",
    "write_context",
    "edit_context",
    "run_bash",
    "run_powershell",
    "run_git",
    "curl",
    "skill_add",
    "skill_edit",
    "skill_remove",
    "skill_enable",
    "skill_disable"
  ]

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
        #
        # NOTE: `run_command` (the task-control shell tool) is deliberately
        # NOT listed here — it is dispatch-registered only (execute_tool/5)
        # and exposed to agents via the SelfReflective agent's own explicit
        # available_tools/0 list. It MUST NOT be added to schemas/0 or
        # read_only_schemas/0: giving every coding agent task-control access
        # would be a scope/security violation (mirrors the old dispatch-only
        # contract of the per-function task-control tools).
      ]

    maybe_append_web_search(schemas)
  end

  @doc """
  Returns the list of read-only tool schemas shared by read-only agents
  (Investigator, ContextExtractor).

  ## Reconciliation with the foreign-repo role gate

  `Curl.schema()` was REMOVED — `curl` has no legitimate read-only role (it is
  not part of the default `schemas/0` set either) and it is a write-capable
  tool. `Context.write_schema()`/`Context.edit_schema()` and
  `ShellTool.schema()` are KEPT by design: read-only agents (Investigator,
  ContextExtractor) must still (a) update CONTEXT.md in their OWN repo — the
  documented investigator contract — and (b) run tests/diagnostics
  (`mix test`) in their own repo via ShellTool. Their WRITE usage inside
  READ-ONLY foreign repos is now blocked by the dispatch-level foreign-repo
  role gate (`maybe_block_read_only_foreign_repo/5`), which treats
  `run_git`/`curl` as write tools alongside the file/shell/skill writers.
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
        ShellTool.schema(),
        SearchContext.schema(),
        SearchHistory.schema()
      ]

    maybe_append_web_search(schemas)
  end

  # Web search is gated behind the `[tools] search_enabled` config. Both the
  # full `schemas/0` set and the read-only `read_only_schemas/0` set append the
  # WebSearch schema under the same condition — defined ONCE here so the gating
  # literal lives in a single place. Evaluated at call time (not a module
  # attribute) because the config can change at runtime.
  defp maybe_append_web_search(schemas) do
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

  ## Return value

  A tool MAY return any of:

  - `String.t()` — the plain all-text result (the shape every built-in tool
    produces today). `EvoGit.Agent.ToolDispatch` threads it through the
    BINARY-ONLY sanitize / truncate / hint pipeline and materializes it as a
    single `ContentPart.text/1` — byte-identical to the legacy path.
  - `%EvoGit.Agent.ToolOutput{}` — text PLUS optional multimodal media (images /
    audio as the string-keyed base64 maps of `EvoGit.Attachments`). The media
    ride the tool-result message as real content parts
    (`[ContentPart.text(text) | media parts…]`); the wrap boundary lives in
    `EvoGit.Agent.ToolDispatch` (see `EvoGit.Agent.ToolOutput`).
  - `{:error, reason}` — the dispatch/tool failed; the caller surfaces it as an
    `"Error: …"` string.

  The two write guards (`maybe_block_repo_less/5`,
  `maybe_block_read_only_foreign_repo/5`) and every other guard path return a
  plain `String.t()` `"Error: …"` message, never a `%ToolOutput{}`.
  """
  @spec execute(
          String.t(),
          map() | String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: String.t() | EvoGit.Agent.ToolOutput.t() | {:error, term()}
  def execute(tool_name, args, repo_path, repo_root \\ nil, node_path \\ nil)

  # Compile-time tool name for dispatch (matches ShellTool's compile-time @tool_name)
  @shell_tool_name if(EvoGit.Platform.os() == :windows, do: "run_powershell", else: "run_bash")

  # Well-known shell-tool aliases (matched case-insensitively). LLMs
  # sometimes call a shell tool by a familiar external name ("Bash",
  # "Shell", ...) instead of the platform tool name. All of these normalize
  # to @shell_tool_name so the call actually runs instead of failing with
  # "Unknown tool". Includes the platform tool names themselves so
  # case variants ("RUN_BASH") normalize too.
  @shell_tool_aliases ~w(
    bash shell sh
    execute_bash bash_command run_shell shell_command
    run_bash run_powershell
  )

  @unknown_tool_similarity_threshold 0.7

  def execute(tool_name, args, repo_path, repo_root, node_path) when is_map(args) do
    maybe_block_repo_less(normalize_tool_name(tool_name), args, repo_path, repo_root, node_path)
  end

  # Fallback: some LLMs double-encode the ENTIRE arguments object as a JSON
  # string (e.g. "{\"args\": [...]}") instead of a real JSON object. Try to
  # transparently decode it before failing, so the tool call proceeds normally.
  def execute(tool_name, args, repo_path, repo_root, node_path) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        maybe_block_repo_less(
          normalize_tool_name(tool_name),
          decoded,
          repo_path,
          repo_root,
          node_path
        )

      _ ->
        "Error: tool arguments were received as a JSON-encoded string instead of a JSON object. " <>
          "Pass the arguments as a real JSON object, " <>
          "e.g. {\"args\": [\"-n\", \"pattern\"]}, not a string."
    end
  end

  # Normalizes well-known shell-tool aliases to the platform's shell tool
  # name. MUST run at the TOP of execute/5 BEFORE the write guards:
  # run_bash/run_powershell are in @write_tools, so normalizing after the
  # guards would let a repo-less (or read-only-foreign-repo) agent bypass
  # the write block by calling "Bash". Keep this ordering.
  defp normalize_tool_name(tool_name) when is_binary(tool_name) do
    if String.downcase(tool_name) in @shell_tool_aliases, do: @shell_tool_name, else: tool_name
  end

  defp normalize_tool_name(tool_name), do: tool_name

  # Classifies a tool name as a WRITE tool for the two dispatch write gates.
  # Extends the built-in write set with user-defined custom tools: a loaded
  # custom tool whose `read_only?/0` is false/absent must be gated exactly like
  # a built-in writer (blocked for repo-less agents and inside read-only foreign
  # repos). Unknown names are never write tools, so this never blocks built-ins
  # or hallucinated tool calls.
  defp write_tool?(tool_name) do
    tool_name in @write_tools or EvoGit.CustomTools.write_tool?(tool_name)
  end

  # Tools that mutate the agent worktree through a NON-ATOMIC read-modify-write
  # (read the original bytes, transform, write the whole file back). Two such
  # calls targeting the SAME file must never overlap: each would read the
  # ORIGINAL bytes and the last write would win, silently discarding the other
  # while both still report success. Their execution is therefore SERIALIZED by
  # the dispatcher (`ToolDispatch.batch_execute_tools/4` runs them one at a time
  # in the parent agent process) — file I/O is not a performance bottleneck.
  #
  # DERIVED FROM `@write_tools` BY SUBTRACTION so the classification has a
  # single source of truth and cannot drift: the serial set is exactly the
  # write set MINUS the shell/exec/network tools, which are not read-modify-write
  # file operations (they may write files, but they are opaque whole commands
  # rather than read-modify-write cycles) and which agents legitimately run
  # several of concurrently — serializing them would be an unrelated
  # performance regression.
  @non_serial_write_tools ["run_bash", "run_powershell", "run_git", "curl"]

  @serial_tools @write_tools -- @non_serial_write_tools

  @doc """
  Returns `true` for tool names whose execution performs a non-atomic
  read-modify-write on files in the agent worktree and therefore must not
  overlap another such call in the same LLM tool-call batch.

  This is the SINGLE classification source of truth for serial tool execution
  (the dispatcher partitions a batch on it). The built-in set is the
  `@write_tools` set minus the shell/exec/network tools (`run_bash`,
  `run_powershell`, `run_git`, `curl`), derived by subtraction so it cannot
  drift. A user-defined custom tool that declares itself a write tool
  (`EvoGit.CustomTools.write_tool?/1`) is conservatively included: it is opaque
  user code that may mutate files.

  Read-only tools (`read_file`, `read_context`, `glob`, `list_dir`, `rg`,
  `search_context`, `search_history`, `skill_list`, `skill_read`,
  `skill_where`), the shell/exec/network tools (`run_bash`, `run_powershell`,
  `run_git`, `curl`, `run_command`, `search_web`/`web_search`) and any unknown
  name return `false`.
  """
  def serial_tool?(tool_name) when is_binary(tool_name) do
    tool_name in @serial_tools or EvoGit.CustomTools.write_tool?(tool_name)
  end

  def serial_tool?(_tool_name), do: false

  # Defense-in-depth write guard: repo-less agents (marked via
  # `Process.get(:repo_less)` — chatbot-style agents without a git worktree)
  # must never touch git or write files. Block write tools for them before
  # dispatching; every execution path in `execute/5` routes through here so
  # there is no bypass. The repo-less guard runs FIRST (ordered before the
  # foreign-repo gate), then the foreign-repo gate, then `execute_tool`.
  defp maybe_block_repo_less(tool_name, args, repo_path, repo_root, node_path) do
    if Process.get(:repo_less) && write_tool?(tool_name) do
      "Error: this agent has read-only access to the system — the #{tool_name} tool is disabled."
    else
      maybe_block_read_only_foreign_repo(tool_name, args, repo_path, repo_root, node_path)
    end
  end

  # Defense-in-depth write gate for agents operating inside a READ-ONLY
  # foreign repo. The agent's current repo role is resolved from the process
  # dict: `:evogit_repo_id` is matched against the `:foreign_repos` entries by
  # id (primary lookup); when that finds nothing (nil/"primary" id, or an id
  # not in the list) the agent's repo path is resolved against the foreign
  # repos via `EvoGit.Core.ForeignRepo.resolve_path/2` (root-path fallback —
  # agent worktree paths live under `<root>/.genesis/workers/...`, which the
  # prefix logic handles robustly). When the agent runs inside a foreign repo
  # whose `writable` is not literally `true`, every write tool is blocked
  # before dispatch. Only `true` is writable — `ForeignRepo.new/3` coerces.
  defp maybe_block_read_only_foreign_repo(tool_name, args, repo_path, repo_root, node_path) do
    foreign_repos =
      Process.get(:foreign_repos, [])
      |> Enum.map(&EvoGit.Core.ForeignRepo.normalize/1)
      |> Enum.reject(&is_nil/1)

    repo_id = Process.get(:evogit_repo_id)

    resolved_repo =
      Enum.find(foreign_repos, fn repo -> repo.id == repo_id end) ||
        case EvoGit.Core.ForeignRepo.resolve_path(
               foreign_repos,
               Process.get(:repo_path) || repo_path
             ) do
          {:ok, resolved_id, _rel} ->
            Enum.find(foreign_repos, fn repo -> repo.id == resolved_id end)

          {:error, :not_in_any_repo} ->
            nil
        end

    if resolved_repo && resolved_repo.writable != true && write_tool?(tool_name) do
      "Error: this agent operates in a read-only foreign repository (#{resolved_repo.root}) — " <>
        "the #{tool_name} tool is disabled. Writable foreign repos are the only foreign repos " <>
        "that accept modifications; read-only foreign repos are for investigation only."
    else
      case test_tool_override(tool_name) do
        nil -> execute_tool(tool_name, args, repo_path, repo_root, node_path)
        fun -> fun.(args, repo_path, repo_root, node_path)
      end
    end
  end

  # Test-only seam (app env `:evo_git, :tool_dispatch_test_tools`): maps a tool
  # NAME to a `fun.(args, repo_path, repo_root, node_path)` whose return value is
  # passed through verbatim — including a `%EvoGit.Agent.ToolOutput{}` carrying
  # media. It is consulted AFTER the two write guards and BEFORE built-in
  # dispatch, so an integration test can drive the REAL dispatch plumbing
  # (serial/parallel batch phases, sanitize/truncate, hint tracking, message
  # assembly) end-to-end. Overriding a built-in name is deliberate: the real
  # name-driven behaviours (the serial/parallel partition, the delegation hints,
  # the redundant-cd warning) are then exercised too. The registry is EMPTY in
  # production (the app env is unset), so dispatch is byte-identical there — and
  # a `nil`/non-map env value is treated as "no override" rather than crashing.
  defp test_tool_override(tool_name) when is_binary(tool_name) do
    case Application.get_env(:evo_git, :tool_dispatch_test_tools) do
      tools when is_map(tools) -> Map.get(tools, tool_name)
      _ -> nil
    end
  end

  defp test_tool_override(_tool_name), do: nil

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

  # `run_command` is the single task-control shell tool: the self-reflective
  # agent dispatches command strings (list_tasks, get_task, start_task,
  # cancel_task, force_kill_task, delete_task, guide_user,
  # subagent_investigator, list_recent_projects, system_info) through it via
  # the EvoGit.CommandShell registry. It is a control tool, NOT a write tool —
  # see the @write_tools note above (it must not be blocked by the repo-less
  # guard; the self-reflective agent is the repo-less agent that needs it).
  defp execute_tool("run_command", args, repo_path, repo_root, _node_path) when is_map(args) do
    RunCommand.execute(args, repo_path, repo_root)
  end

  defp execute_tool(unknown_tool, args, repo_path, repo_root, node_path)
       when is_binary(unknown_tool) and is_map(args) do
    # An explicitly configured custom tool (EvoGit.CustomTools, loaded from
    # `<config_dir>/tools/`) MUST win over a same-named dynamic skill, so the
    # custom lookup runs FIRST. Built-in tool name clauses match earlier, so a
    # built-in always wins (intended). `:unknown` (name is not a loaded custom
    # tool) falls through to the existing dynamic-skill lookup and then the
    # unknown-tool error. `EvoGit.CustomTools.execute/3` error strings are
    # never "Error: "-prefixed, so a plain prepend is correct.
    case EvoGit.CustomTools.execute(unknown_tool, args, %{
           repo_path: repo_path,
           repo_root: repo_root,
           node_path: node_path
         }) do
      {:ok, output} ->
        output

      {:error, reason} ->
        "Error: " <> reason

      :unknown ->
        # Try dynamic skill execution — skills are loaded from .agents/skills/
        # in the agent's WORKTREE (`repo_path`), mirroring the schema load in
        # Runner.do_run/2, so skills created/edited by the agent are found.
        if repo_root && is_binary(repo_root) do
          skills = EvoGit.Skills.load_skills(repo_path)

          if EvoGit.Skills.find_skill(skills, unknown_tool) do
            EvoGit.Skills.execute(skills, unknown_tool, args, repo_path)
          else
            unknown_tool_error(unknown_tool)
          end
        else
          unknown_tool_error(unknown_tool)
        end
    end
  end

  # Actionable unknown-tool error: suggest the closest valid tool name so the
  # LLM can self-correct next turn instead of repeating the bad call, and
  # list the available tool names as a fallback.
  defp unknown_tool_error(name) do
    suggestion =
      case closest_tool_name(name) do
        nil -> ""
        closest -> " Did you mean '#{closest}'?"
      end

    "Error: Unknown tool '#{name}'.#{suggestion} Available tools: #{Enum.join(available_tool_names(), ", ")}."
  end

  # Advertised tool names, DERIVED at runtime from the real schema set so the
  # unknown-tool hint can never drift from what coding agents are actually
  # offered. Evaluated at call time (not a module attribute) because
  # `schemas/0` reads runtime config (`maybe_append_web_search/1`). This keeps
  # `run_command` deliberately absent (it is not in `schemas/0`) and excludes
  # the schema-commented-out `curl`/`run_git`.
  defp available_tool_names do
    schemas() |> Enum.map(& &1.name)
  end

  defp closest_tool_name(name) do
    name = String.downcase(name)

    available_tool_names()
    |> Enum.map(&{&1, String.jaro_distance(name, &1)})
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
    |> case do
      {tool, score} when score >= @unknown_tool_similarity_threshold -> tool
      _ -> nil
    end
  end
end
