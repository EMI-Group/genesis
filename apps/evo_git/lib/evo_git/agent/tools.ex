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
  alias EvoGit.Agent.Tools.WebFetch
  alias EvoGit.Agent.Tools.Lsp
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
  alias EvoGit.Agent.Tools.JobOutput
  alias EvoGit.Agent.Tools.JobList
  alias EvoGit.Agent.Tools.JobKill
  alias EvoGit.Agent.ToolNames

  # Tools that mutate the system (files, git, shell, skills). Repo-less agents
  # (chatbot-style, no worktree) must never touch git or write files, and
  # agents operating inside a READ-ONLY foreign repo must not modify anything —
  # `execute/5` blocks these for such agents as defense-in-depth.
  # NOTE: `run_command` (the task-control shell tool) is deliberately NOT here —
  # it is a control tool, not a write tool, and must NOT be blocked by the
  # repo-less guard: the self-reflective agent IS the repo-less agent that
  # needs it to control tasks. The three background-job control tools
  # (`job_output`, `job_list`, `job_kill`) are control tools for the same
  # reason — see `write_call?/2` below for the ONE write capability that is an
  # ARGUMENT rather than a tool name.
  #
  # The MODEL-FACING spellings (`write`, `edit`, `bash` — the trained canonical
  # names, see `EvoGit.Agent.ToolNames`) are listed alongside the internal
  # dispatch keys as belt-and-braces: every write check normalises its input
  # through `ToolNames.normalize/1` first, so these entries are redundant in the
  # normal path — but they keep the set correct even if a raw model-facing name
  # ever reaches a check that has not normalised yet.
  @write_tools [
    "create_files",
    "write",
    "write_file",
    "edit",
    "edit_file",
    "bash",
    "make_dir",
    "write_context",
    "edit_context",
    "run_bash",
    "run_powershell",
    "run_git",
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
        # Read-only network READER — strictly read-only, so it is also part of
        # `read_only_schemas/0` and is NEVER a write tool (`web_fetch` performs
        # one HTTP GET and writes nothing). It is NOT config-gated at the
        # schema-list level: `web_fetch` always works.
        #
        # `lsp` (the read-only language-intelligence reader) is DIFFERENT: its
        # schema is offered only when the user configures a server —
        # `[lsp] enabled = true` plus a non-empty `[lsp] command` — see
        # `EvoGit.Config.lsp_enabled?/0` and `maybe_append_lsp/1` below. Without
        # a configured server the tool would be dead weight in every agent's
        # tool list, so it is appended (last) by config rather than listed here.
        # The tool's own runtime gate still returns a self-explaining `Error:`
        # if it is somehow called while unconfigured. Contrast `search_web`,
        # also gated (`[tools] search_enabled`, `maybe_append_web_search/1`).
        WebFetch.schema(),
        SkillList.schema(),
        SkillRead.schema(),
        SkillAdd.schema(),
        SkillEdit.schema(),
        SkillRemove.schema(),
        SkillEnable.schema(),
        SkillDisable.schema(),
        SkillWhere.schema(),
        # Background-job CONTROL tools (output / list / kill for detached shell
        # jobs started with the shell tool's `run_in_background` argument).
        # Control tools like `run_command` — NOT write tools, NOT serial tools
        # (they never read-modify-write a file). Every agent that can run a
        # command in its own worktree may legitimately start and manage jobs
        # there, so they belong in BOTH the full and the read-only sets.
        JobOutput.schema(),
        JobList.schema(),
        JobKill.schema()
        # Git.schema()
        #
        # NOTE: `run_command` (the task-control shell tool) is deliberately
        # NOT listed here — it is dispatch-registered only (execute_tool/5)
        # and exposed to agents via the SelfReflective agent's own explicit
        # available_tools/0 list. It MUST NOT be added to schemas/0 or
        # read_only_schemas/0: giving every coding agent task-control access
        # would be a scope/security violation (mirrors the old dispatch-only
        # contract of the per-function task-control tools).
      ]

    schemas
    |> maybe_append_web_search()
    |> maybe_append_lsp()
  end

  @doc """
  Returns the list of read-only tool schemas shared by read-only agents
  (Investigator, ContextExtractor).

  ## Reconciliation with the foreign-repo role gate

  `Context.write_schema()`/`Context.edit_schema()` and
  `ShellTool.schema()` are KEPT by design: read-only agents (Investigator,
  ContextExtractor) must still (a) update CONTEXT.md in their OWN repo — the
  documented investigator contract — and (b) run tests/diagnostics
  (`mix test`) in their own repo via ShellTool. Their WRITE usage inside
  READ-ONLY foreign repos is now blocked by the dispatch-level foreign-repo
  role gate (`maybe_block_read_only_foreign_repo/5`), which treats
  `run_git` as a write tool alongside the file/shell/skill writers.
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
        SearchHistory.schema(),
        # Read-only network reader, shared with the full set — see the matching
        # note in `schemas/0` above. `web_fetch` is ungated; `lsp` is appended
        # by `maybe_append_lsp/1` only when a language server is configured.
        WebFetch.schema(),
        # Background-job CONTROL tools, shared with the full set: a read-only
        # agent still owns a worktree and may start + manage detached jobs in
        # it (`job_output`/`job_list`/`job_kill` mutate no file and are never
        # classified as write tools — see `write_call?/2`).
        JobOutput.schema(),
        JobList.schema(),
        JobKill.schema()
      ]

    schemas
    |> maybe_append_web_search()
    |> maybe_append_lsp()
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

  # The `lsp` tool is gated behind a CONFIGURED language server —
  # `EvoGit.Config.lsp_enabled?/0` is true only when `[lsp] enabled = true` AND
  # `[lsp] command` is non-empty. Appended LAST in both schema sets so an agent
  # only ever sees it when it can actually do something; the dispatch clause
  # (`execute_tool("lsp", ...)`) stays registered so the tool still works when
  # enabled (and still self-explains with an `Error:` if called unconfigured).
  # Evaluated at call time (not a module attribute) because the config can
  # change at runtime.
  defp maybe_append_lsp(schemas) do
    if EvoGit.Config.lsp_enabled?() do
      schemas ++ [Lsp.schema()]
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

  # Compile-time tool name for dispatch (matches ShellTool's compile-time
  # @tool_name). Derived from `EvoGit.Agent.ToolNames` so the platform pin has a
  # SINGLE source of truth.
  @shell_tool_name ToolNames.shell_tool_name()

  @unknown_tool_similarity_threshold 0.7

  # Default per-tool timeout (ms) for the platform shell tool, exposed through
  # `default_timeout_ms/1` as a read-only seam for the dispatcher.
  @shell_tool_default_timeout_ms 120_000

  # Default per-tool timeout (ms) for `job_output`: a bounded `wait` blocks up
  # to 60 s INSIDE the tool, so the generic 10 s default would abort a
  # legitimate wait. 65 s = the 60 s wait budget + headroom for reading output.
  @job_output_default_timeout_ms 65_000

  def execute(tool_name, args, repo_path, repo_root, node_path) when is_map(args) do
    maybe_block_repo_less(
      ToolNames.normalize(tool_name),
      args,
      repo_path,
      repo_root,
      node_path
    )
  end

  # Fallback: some LLMs double-encode the ENTIRE arguments object as a JSON
  # string (e.g. "{\"args\": [...]}") instead of a real JSON object. Try to
  # transparently decode it before failing, so the tool call proceeds normally.
  def execute(tool_name, args, repo_path, repo_root, node_path) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        maybe_block_repo_less(
          ToolNames.normalize(tool_name),
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

  # Tool-name aliasing lives ENTIRELY in `EvoGit.Agent.ToolNames` (the alias
  # spine): `normalize/1` maps every accepted spelling — `Read`/`read`,
  # `Write`/`write`, `Edit`/`edit`, `Bash`/`bash`/`shell`/… , `Grep`/`grep`/
  # `ripgrep`, `WebSearch`/`web_search`, `Task`/`subagent` — onto the internal
  # dispatch key, and returns unknown names UNCHANGED (custom tools + dynamic
  # skills rely on that passthrough).
  #
  # LOAD-BEARING ORDERING: normalisation MUST happen at the TOP of `execute/5`,
  # BEFORE the two write guards (`maybe_block_repo_less/5`,
  # `maybe_block_read_only_foreign_repo/5`). `run_bash`/`run_powershell` are
  # write tools, so normalising AFTER the guards would let a repo-less (or
  # read-only-foreign-repo) agent bypass the write block by calling `Bash`/`sh`.
  # Every write classification (`write_tool?/1`, `serial_tool?/1`,
  # `default_timeout_ms/1`) normalises too, because the dispatcher hands them
  # the RAW model-facing name.

  # Classifies a tool name as a WRITE tool for the two dispatch write gates.
  # Extends the built-in write set with user-defined custom tools: a loaded
  # custom tool whose `read_only?/0` is false/absent must be gated exactly like
  # a built-in writer (blocked for repo-less agents and inside read-only foreign
  # repos). Unknown names are never write tools, so this never blocks built-ins
  # or hallucinated tool calls. The name is normalised first (aliases like
  # `Bash`/`write` are write tools); an unknown name normalises to itself, so
  # the custom-tool lookup is unchanged.
  defp write_tool?(tool_name) do
    normalized = ToolNames.normalize(tool_name)
    normalized in @write_tools or EvoGit.CustomTools.write_tool?(normalized)
  end

  @doc """
  `true` when this tool CALL is a WRITE capability — what the two dispatch write
  guards (`maybe_block_repo_less/5`, `maybe_block_read_only_foreign_repo/5`)
  consult.

  ## Why a call-level predicate (and not just `write_tool?/1`)

  Starting a BACKGROUND process is a write capability: a detached job can
  mutate anything a foreground command could (files, git state, the whole
  repo), and it outlives the tool call that started it. But `run_in_background`
  is an ARGUMENT of the shell tool (`bash`), not a tool name, so it cannot be
  expressed in the `@write_tools` name set at all — a name-only guard would let
  a repo-less (or read-only-foreign-repo) agent start a detached job through the
  very tool the guard already allows for reads/tests.

  A background START is therefore classified as a write call here, while a
  FOREGROUND shell command stays exactly as classified before (it is a write
  tool in `@write_tools`, unchanged).

  `write_tool?/1` itself stays UNCHANGED — it is the NAME-only classification
  used by `serial_tool?/1` and by the custom-tool gate.

  Total and side-effect free: non-binary names and non-map args simply yield
  `false` for the parts that cannot match.
  """
  @spec write_call?(term(), term()) :: boolean()
  def write_call?(tool_name, args) do
    # == `write_tool?(tool_name) or
    #     (ToolNames.normalize(tool_name) == @shell_tool_name and
    #        background_start?(args))`
    write_tool?(tool_name) or shell_background_start?(tool_name, args)
  end

  # The ONE narrowing of a write call to its background-start form: the shell
  # tool (the platform compile-time name — `run_bash` / `run_powershell`; every
  # accepted spelling normalises onto it) called with a truthy
  # `run_in_background`. Used both by `write_call?/2` and by the two guards, so
  # a blocked background start gets a message that NAMES the argument mode
  # instead of the generic "tool is disabled".
  defp shell_background_start?(tool_name, args) do
    ToolNames.normalize(tool_name) == @shell_tool_name and background_start?(args)
  end

  @doc false
  # Lenient truthy check of the shell tool's `run_in_background` argument: the
  # model may emit a real JSON boolean (`true`) or the string `"true"`; anything
  # else (absent, `false`, `"false"`, other junk, non-map args) is NOT a
  # background start. Deliberately lenient in the BLOCKING direction only —
  # dispatch must still let `args` be passed through untouched.
  @spec background_start?(term()) :: boolean()
  def background_start?(args) when is_map(args) do
    case Map.get(args, "run_in_background") do
      true -> true
      "true" -> true
      _other -> false
    end
  end

  def background_start?(_args), do: false

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
  #
  # `bash` (the model-facing shell name) is listed here as the belt-and-braces
  # counterpart of its `@write_tools` entry: the shell tool may write files, but
  # it is an opaque whole command, not a read-modify-write cycle, so it must NOT
  # be serialised. `write`/`edit` are model-facing aliases of two genuine
  # read-modify-write tools, so they correctly stay in the serial set.
  @non_serial_write_tools ["run_bash", "run_powershell", "run_git", "bash"]

  @serial_tools @write_tools -- @non_serial_write_tools
  @doc """
  Returns `true` for tool names whose execution performs a non-atomic
  read-modify-write on files in the agent worktree and therefore must not
  overlap another such call in the same LLM tool-call batch.

  This is the SINGLE classification source of truth for serial tool execution
  (the dispatcher partitions a batch on it). The built-in set is the
  `@write_tools` set minus the shell/exec/network tools (`run_bash`,
  `run_powershell`, `run_git`), derived by subtraction so it cannot
  drift. A user-defined custom tool that declares itself a write tool
  (`EvoGit.CustomTools.write_tool?/1`) is conservatively included: it is opaque
  user code that may mutate files.

  Read-only tools (`read_file`, `read_context`, `glob`, `list_dir`, `rg`,
  `search_context`, `search_history`, `skill_list`, `skill_read`,
  `skill_where`, `web_fetch`, `lsp`), the shell/exec/network tools (`run_bash`,
  `run_powershell`, `run_git`, `run_command`, `search_web`/`web_search`), the
  background-job control tools (`job_output`, `job_list`, `job_kill`) and any
  unknown name return `false`.

  The incoming name is normalised through `EvoGit.Agent.ToolNames.normalize/1`
  first, because the dispatcher passes the RAW model-facing name (`write`,
  `edit`, `bash`, `Read`, …) straight from the LLM response: `serial_tool?("write")`
  and `serial_tool?("edit")` are `true`, `serial_tool?("bash")` is `false`.
  """
  def serial_tool?(tool_name) when is_binary(tool_name) do
    normalized = ToolNames.normalize(tool_name)
    normalized in @serial_tools or EvoGit.CustomTools.write_tool?(normalized)
  end

  def serial_tool?(_tool_name), do: false

  @doc """
  `true` when `schema_or_name` matches ANY entry of `whitelist`, comparing
  ALIAS-AWARE: both sides are normalised through
  `EvoGit.Agent.ToolNames.matches_any?/2`, so a whitelist entry written with the
  old spelling (`"read_file"`) matches the new model-facing name (`"read"`) and
  vice versa — case-insensitively.

  `EvoGit.Agents.Custom.available_tools/0` (not part of this module) SHOULD use
  this function so `agents.toml` `tools` whitelists written with either spelling
  keep resolving; today it compares names literally.
  """
  @spec whitelist_match?(term(), term()) :: boolean()
  def whitelist_match?(schema_or_name, whitelist),
    do: ToolNames.matches_any?(schema_or_name, whitelist)

  @doc """
  The DEFAULT timeout (ms) a tool should get when the caller does not request one
  explicitly: `120_000` for the platform shell tool (any accepted spelling of it
  — `bash`, `shell`, `run_bash`, `run_powershell`, …), `65_000` for
  `job_output` (its `wait` argument may block up to 60 s inside the tool, so the
  generic 10 s default would cut a bounded wait short — 65 s leaves the wait's
  own 60 s budget plus headroom for reading the output file), and `nil` for
  every other tool (meaning "no per-tool default — the dispatcher's generic
  default applies"). `job_list` / `job_kill` are fast registry calls and
  deliberately keep the generic default.

  Pure, read-only seam: it changes no dispatch behaviour by itself; the
  dispatcher (a file this module does not own) is expected to consult it for its
  per-tool default timeout.
  """
  @spec default_timeout_ms(term()) :: pos_integer() | nil
  def default_timeout_ms(tool_name) do
    case ToolNames.normalize(tool_name) do
      @shell_tool_name -> @shell_tool_default_timeout_ms
      "job_output" -> @job_output_default_timeout_ms
      _other -> nil
    end
  end

  # Defense-in-depth write guard: repo-less agents (marked via
  # `Process.get(:repo_less)` — chatbot-style agents without a git worktree)
  # must never touch git or write files. Block write CALLS for them before
  # dispatching (`write_call?/2`: the name-based write set PLUS the shell's
  # `run_in_background` start argument — a detached job is a write capability
  # even though it is not a tool name); every execution path in `execute/5`
  # routes through here so there is no bypass. The repo-less guard runs FIRST
  # (ordered before the foreign-repo gate), then the foreign-repo gate, then
  # `execute_tool`.
  defp maybe_block_repo_less(tool_name, args, repo_path, repo_root, node_path) do
    cond do
      # Boolean-safe on purpose (`!= true` / `not`, never bare `nil && …` inside
      # `not/1`): `Process.get(:repo_less)` is simply UNSET for ordinary agents.
      Process.get(:repo_less) != true or not write_call?(tool_name, args) ->
        maybe_block_read_only_foreign_repo(tool_name, args, repo_path, repo_root, node_path)

      # The NARROW case is tested FIRST, deliberately: the shell tool is itself
      # in `@write_tools`, so a purely name-based arm placed before it would
      # shadow it and a background START would be reported only as "the tool is
      # disabled" — losing the one actionable fact (the detached-job ARGUMENT is
      # what makes it a write capability).
      shell_background_start?(tool_name, args) ->
        "Error: this agent has read-only access to the system — " <>
          "starting a BACKGROUND process (bash's `run_in_background` mode) is disabled: " <>
          "a detached job is a write capability that outlives the tool call and can modify " <>
          "anything a foreground command could. The shell tool is itself a write tool, so it " <>
          "is disabled for this agent in every mode."

      true ->
        # `write_call?/2` held and the call is not a background start, so the
        # name-based write set is what matched (plus custom write tools).
        "Error: this agent has read-only access to the system — the #{tool_name} tool is disabled."
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
  # whose `writable` is not literally `true`, every write CALL is blocked before
  # dispatch — `write_call?/2`, i.e. the write tool set PLUS a background shell
  # start (`run_in_background`), which is a write capability expressed as an
  # ARGUMENT rather than as a tool name. Only `true` is writable —
  # `ForeignRepo.new/3` coerces.
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

    cond do
      # Boolean-safe on purpose: `resolved_repo` is nil for the vast majority of
      # agents (not inside any foreign repo), so it must never be fed to `not/1`.
      is_nil(resolved_repo) or resolved_repo.writable == true or
          not write_call?(tool_name, args) ->
        case test_tool_override(tool_name) do
          nil -> execute_tool(tool_name, args, repo_path, repo_root, node_path)
          fun -> fun.(args, repo_path, repo_root, node_path)
        end

      # Same ordering rule as `maybe_block_repo_less/5`: the narrow
      # background-start case is tested BEFORE the name-based arm, because the
      # shell tool is itself in `@write_tools` and would otherwise shadow it.
      shell_background_start?(tool_name, args) ->
        # Background shell start in a read-only foreign repo — a detached job is
        # a write capability (see `write_call?/2`), so name the argument mode.
        "Error: this agent operates in a read-only foreign repository (#{resolved_repo.root}) — " <>
          "starting a BACKGROUND process (bash's `run_in_background` mode) is disabled: " <>
          "a detached job is a write capability that can modify the repository. " <>
          "The shell tool is itself a write tool, so it is disabled here in every mode."

      true ->
        "Error: this agent operates in a read-only foreign repository (#{resolved_repo.root}) — " <>
          "the #{tool_name} tool is disabled. Writable foreign repos are the only foreign repos " <>
          "that accept modifications; read-only foreign repos are for investigation only."
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

  # `web_fetch` (one HTTP GET → readable Markdown) and `lsp` (Elixir diagnostics /
  # hover / definition over the user's configured language server) are READ-ONLY
  # tools: their model-facing schema name and their internal dispatch key are the
  # same string, so no `EvoGit.Agent.ToolNames` entry is needed — an unknown name
  # passes through that alias table unchanged.
  defp execute_tool("web_fetch", args, repo_path, repo_root, _node_path) when is_map(args) do
    WebFetch.execute(args, repo_path, repo_root)
  end

  defp execute_tool("lsp", args, repo_path, repo_root, _node_path) when is_map(args) do
    Lsp.execute(args, repo_path, repo_root)
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

  # Background-job CONTROL tools (`job_output` / `job_list` / `job_kill`) —
  # control tools exactly like `run_command`, dispatched with the same
  # `(args, repo_path, repo_root)` shape. They manage the detached shell jobs
  # started with the shell tool's `run_in_background` argument; their owner
  # identity comes from the process dictionary the dispatcher installs in every
  # tool task (`:evogit_agent_pid` / `:evogit_agent_id` / `:evogit_task_id` —
  # see `EvoGit.Agent.ToolDispatch.execute_tool_task/7`), so the repo paths are
  # accepted but unused.
  defp execute_tool("job_output", args, repo_path, repo_root, _node_path) when is_map(args) do
    JobOutput.execute(args, repo_path, repo_root)
  end

  defp execute_tool("job_list", args, repo_path, repo_root, _node_path) when is_map(args) do
    JobList.execute(args, repo_path, repo_root)
  end

  defp execute_tool("job_kill", args, repo_path, repo_root, _node_path) when is_map(args) do
    JobKill.execute(args, repo_path, repo_root)
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
  # the schema-commented-out `run_git`.
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
