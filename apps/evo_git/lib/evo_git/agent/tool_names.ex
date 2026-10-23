defmodule EvoGit.Agent.ToolNames do
  @moduledoc """
  The tool-name ALIAS SPINE: the single source of truth mapping every ACCEPTED
  tool-name spelling a model may emit onto the INTERNAL dispatch key that
  `EvoGit.Agent.Tools.execute/5` dispatches on.

  ## Why this module exists

  Models emit the tool name they memorised during training
  (Claude-Code style `Read`/`Write`/`Edit`/`Bash`/`Grep`/`WebSearch`/`Task`, the
  DeepSeek-harness style `read`/`write`/`edit`/`bash`/`grep`/`web_search`, or one
  of our historical shell spellings `shell`/`sh`/`execute_bash`/…). A rejected
  name costs a whole round-trip: the call falls into the "Unknown tool … Did you
  mean" path and the work is lost. Accepting the spelling is a zero-risk
  compatibility shim (see `docs/harness-alignment.md` §1.2 / proposal 1.7).

  The MODEL-FACING schema names (what the LLM is offered) and the INTERNAL
  dispatch keys (what `Tools.execute_tool/5` pattern-matches) are therefore two
  different things. This round renames the model-facing schema names to the
  trained canonical names in the individual schema modules, while the internal
  dispatch keys keep today's names — so this table is the bridge.

  ## The canonical reference table

  For every concept: (a) the model-facing schema name, (b) the internal dispatch
  key, (c) every accepted spelling/alias. Matching is CASE-INSENSITIVE (the name
  is down-cased before lookup), so `READ`, `Read` and `read` all resolve.

  | Concept | (a) Model-facing schema name | (b) Internal dispatch key | (c) Accepted spellings |
  |---|---|---|---|
  | read | `read` | `read_file` | `read`, `read_file` |
  | write | `write` | `write_file` | `write`, `write_file` |
  | edit | `edit` | `edit_file` | `edit`, `edit_file` |
  | shell | `bash` | `run_bash` (POSIX) / `run_powershell` (Windows) | `bash`, `shell`, `sh`, `execute_bash`, `bash_command`, `run_shell`, `shell_command`, `run_bash`, `run_powershell` |
  | grep | `rg` | `rg` | `grep`, `ripgrep`, `rg` |
  | glob | `glob` | `glob` | `glob` |
  | web search | `web_search` | `search_web` | `websearch`, `web_search`, `search_web` |
  | delegate (subagent) | `subagent_manager` (+ `subagent_executor`, … — generated per module, NOT renamed this round) | `subagent_manager` | `task`, `subagent`, `subagent_manager` |

  Notes:

    * `rg` deliberately STAYS the canonical model-facing name for grep (explicit
      product decision — `grep`/`ripgrep` are accepted as aliases only).
    * The platform shell tool's internal key is compile-time pinned
      (`run_powershell` on Windows, `run_bash` everywhere else) and exposed by
      `shell_tool_name/0`; the alias table stores a `:platform_shell` sentinel
      that `normalize/1` resolves.
    * The delegation (`task` / `subagent`) entries are ACCEPTED SPELLINGS only:
      the subagent tool-name matching lives in `EvoGit.Agent.SubagentSchemas`
      (not this module's call site) and `model_name/1` returns the generated
      `subagent_*` names unchanged until that file renames them. The table entry
      is ready for that call site.
    * UNKNOWN names are returned UNCHANGED by `normalize/1` — user-defined
      custom tools (`EvoGit.CustomTools`) and dynamic skills
      (`EvoGit.Skills`) depend on that passthrough. A custom tool deliberately
      named after an alias (e.g. a tool literally called `read`) is therefore
      shadowed by the built-in concept; names not in this table are unaffected.
    * Every function here is PURE and TOTAL: no I/O, no raises — non-binary input
      passes through untouched.
  """

  # Compile-time platform detection — the shell tool NAME is pinned per platform
  # (mirrors `EvoGit.Agent.Tools.ShellTool.@tool_name`).
  @os EvoGit.Platform.os()
  @shell_tool_name if(@os == :windows, do: "run_powershell", else: "run_bash")

  # Sentinel value for "resolve to the platform's shell tool name".
  @platform_shell :platform_shell

  # The ONE alias table: down-cased accepted spelling => internal dispatch key
  # (or the `:platform_shell` sentinel). Data-driven on purpose — adding an
  # accepted spelling is a one-line change with no new code path.
  @aliases %{
    # read
    "read" => "read_file",
    "read_file" => "read_file",
    # write
    "write" => "write_file",
    "write_file" => "write_file",
    # edit
    "edit" => "edit_file",
    "edit_file" => "edit_file",
    # shell (platform-pinned at resolution time)
    "bash" => @platform_shell,
    "shell" => @platform_shell,
    "sh" => @platform_shell,
    "execute_bash" => @platform_shell,
    "bash_command" => @platform_shell,
    "run_shell" => @platform_shell,
    "shell_command" => @platform_shell,
    "run_bash" => @platform_shell,
    "run_powershell" => @platform_shell,
    # grep (canonical model-facing name stays `rg`)
    "grep" => "rg",
    "ripgrep" => "rg",
    "rg" => "rg",
    # glob
    "glob" => "glob",
    # web search
    "websearch" => "search_web",
    "web_search" => "search_web",
    "search_web" => "search_web",
    # delegation (accepted spelling only — see the moduledoc note)
    "task" => "subagent_manager",
    "subagent" => "subagent_manager",
    "subagent_manager" => "subagent_manager"
  }

  # Internal dispatch key => model-facing schema name. Keys absent here keep their
  # own name as the model-facing name (identity).
  @model_names %{
    "read_file" => "read",
    "write_file" => "write",
    "edit_file" => "edit",
    "run_bash" => "bash",
    "run_powershell" => "bash",
    "rg" => "rg",
    "glob" => "glob",
    "search_web" => "web_search"
  }

  @doc """
  The platform's shell tool name — `"run_powershell"` on Windows, `"run_bash"`
  everywhere else. Compile-time pinned, mirroring
  `EvoGit.Agent.Tools.ShellTool`.
  """
  @spec shell_tool_name() :: String.t()
  def shell_tool_name, do: @shell_tool_name

  @doc """
  The raw alias table (`%{downcased accepted spelling => internal key |
  :platform_shell}`) — exposed for documentation and tests, never for dispatch.
  Resolve a value through `normalize/1` (the `:platform_shell` sentinel is not a
  dispatchable name).
  """
  @spec table() :: %{optional(String.t()) => String.t() | :platform_shell}
  def table, do: @aliases

  @doc """
  Normalises an accepted tool-name spelling (any case) to the INTERNAL dispatch
  key. An unknown name is returned UNCHANGED (custom tools and dynamic skills
  rely on that); non-binary input is returned untouched.
  """
  @spec normalize(term()) :: term()
  def normalize(name) when is_binary(name) do
    case Map.fetch(@aliases, String.downcase(name)) do
      {:ok, @platform_shell} -> @shell_tool_name
      {:ok, internal_key} -> internal_key
      :error -> name
    end
  end

  def normalize(other), do: other

  @doc """
  The MODEL-FACING schema name for an internal dispatch key (or for any
  accepted spelling of it — the name is normalised first). A name with no
  model-facing mapping is returned UNCHANGED, so unknown/custom tool names are
  safe.
  """
  @spec model_name(term()) :: term()
  def model_name(name) when is_binary(name) do
    key = normalize(name)
    Map.get(@model_names, key, key)
  end

  def model_name(other), do: other

  @doc """
  `true` when `name` and any entry of `whitelist` resolve to the SAME internal
  dispatch key. BOTH sides are normalised, so a whitelist entry `"read"` matches
  the name `"read_file"` and vice versa (that is what keeps `agents.toml`
  `tools` lists written with either spelling working); the comparison is
  case-insensitive too.

  Total: a non-list whitelist or non-binary name simply yields `false` for the
  entries that do not match.
  """
  @spec matches_any?(term(), term()) :: boolean()
  def matches_any?(name, whitelist) when is_list(whitelist) do
    key = normalize(name)
    Enum.any?(whitelist, fn entry -> normalize(entry) == key end)
  end

  def matches_any?(_name, _whitelist), do: false
end
