defmodule EvoGit.Agent.Tools.ShellTool do
  @moduledoc """
  Tool for executing shell commands.

  Resolves the effective shell at runtime (configurable via the `[tools] shell`
  config key, defaulting to bash on Linux/macOS and PowerShell on Windows):
  - POSIX shells (bash, sh, zsh, ...): invoked with `-c`
  - PowerShell (powershell, pwsh, ...): invoked with `-EncodedCommand`
  """

  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Platform

  # Compile-time platform detection — used for the tool NAME only (dispatch
  # clauses and the @write_tools block pin the name per platform).
  @os Platform.os()
  @on_windows @os == :windows

  # Compile-time tool name — pinned per platform (run_powershell on Windows,
  # run_bash otherwise).
  @tool_name if(@on_windows, do: "run_powershell", else: "run_bash")

  # 3 minutes timeout for running complex commands
  @default_timeout 180_000

  # Matches `cd` targets: absolute paths (`/foo`), dot-relative escapes
  # (`.`, `..`, `./foo`, `../foo`, `../../../`) and plain relative paths
  # (`foo`, `foo/bar`). Conservative: stops at whitespace/quotes/`&;|` and
  # never matches a bare `cd` (requires a target).
  @cd_regex ~r/\bcd\s+["']?((?:\/|\.\.?(?:\/|$)|[^\/\s"'&;|])[^\s"'&;|]*)/

  # Mutating git subcommands that must never run against the repository's MAIN
  # working copy (the repo root, as opposed to the agent's worktree).
  @mutating_git_regex ~r/\bgit\s+(checkout|switch|reset|merge|pull)\b/

  # Effective shell predicate/identity — runtime-aware, honoring the
  # `[tools] shell` config override via EvoGit.Platform.shell/0.
  defp powershell?, do: EvoGit.Powershell.powershell_executable?(Platform.shell())
  defp shell_name, do: if(powershell?(), do: "PowerShell", else: Platform.shell())
  defp shell_flag, do: if(powershell?(), do: "-Command", else: "-c")
  defp tmp_var, do: if(powershell?(), do: "$env:TEMP", else: "$TMPDIR")

  # Runtime descriptions that differ by shell
  defp command_description, do: "The #{shell_name()} command to execute"

  # Runtime prompt sections that differ by shell
  defp shell_intro, do: "Executes a command via #{shell_name()} #{shell_flag()}."

  defp file_search_alt, do: if(powershell?(), do: "Get-ChildItem", else: "find")
  defp read_file_alt, do: if(powershell?(), do: "Get-Content", else: "cat/head/tail")
  defp edit_file_alt, do: if(powershell?(), do: "string replacement", else: "sed/awk")
  defp write_file_alt, do: if(powershell?(), do: "Set-Content/Out-File", else: "echo/cat EOF")
  defp output_alt, do: if(powershell?(), do: "Write-Host/Write-Output", else: "echo/printf")
  defp ls_command, do: if(powershell?(), do: "Get-ChildItem -Force", else: "ls -la")

  defp no_shell_for_reads do
    if powershell?() do
      "Do NOT use PowerShell for file operations unless dedicated tools fail."
    else
      "Do NOT use bash for file operations unless dedicated tools fail."
    end
  end

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: @tool_name,
      description: generate_description(),
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => command_description()},
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Timeout in milliseconds for this tool execution. Default: #{@default_timeout}",
            "default" => @default_timeout
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
            "default" => 16_384
          }
        },
        "required" => ["command"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp generate_description do
    find_line =
      if powershell?() do
        ""
      else
        "- Use find for complex file searching with regex\n      "
      end

    tmp_suffix =
      if powershell?() do
        "."
      else
        ", never /tmp."
      end

    find_regex_line =
      if powershell?() do
        ""
      else
        "\n      - In `find -regex` alternations, place the longest alternative first (e.g., `'.*\\.(tsx|ts)'`)."
      end

    ls_with_args =
      if powershell?() do
        "Get-ChildItem with args"
      else
        "ls with args"
      end

    """
    #{shell_intro()}
    Useful for running scripts, building, testing, git or executing common command-line tools.
    The current working directory is automatically set to the repo path (the current git worktree path). Avoid using `cd` — the cwd is already correct.

    ## General Guidelines
    STRICT CONSTRAINTS:
    - #{no_shell_for_reads()}
    - File search: Use glob (not #{file_search_alt()})
    - Directory creation: Use make_dir (not mkdir)
    - Read files: Use file_read (not #{read_file_alt()})
    - Edit files: Use edit_file (not #{edit_file_alt()})
    - Write files: Use write_file (not #{write_file_alt()})
    - Communication: Output directly (not #{output_alt()})
    Aside from these exceptions, you can use #{shell_name()} to run tools for file operations:
    - Use #{ls_with_args} for listing files with specific needs (e.g., `#{ls_command()}` for detailed listing).
    #{find_line}- Use project level package managers (e.g., uv, npm, mix, cargo) for managing dependencies.

    EXECUTION RULES:
    - Prefer relative paths for in-repo operations and absolute paths for external operations.
    - Double-quote all paths containing spaces.
    - Verify parent directories exist before creating files/folders.
    - Always use #{tmp_var()} for temporary files#{tmp_suffix}#{find_regex_line}

    ## Git Specific Guidelines
    Use #{shell_name()} for all git operations
    - NEVER update the git config
    - NEVER run destructive git commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly
    requests these actions. Taking unauthorized destructive actions is unhelpful and can result in lost work, so it's best to ONLY run these
    commands when given direct instructions.
    - CRITICAL: Commit the changes before calling any tools or subagents. Changes will be LOST if not committed.
    - CRITICAL: Always create NEW commits rather than amending
    - IMPORTANT: Never use git commands with the -i flag (like git rebase -i or git add -i) since they require interactive input which is not supported.
    - IMPORTANT: Do not use --no-edit with git rebase commands, as the --no-edit flag is not a valid option for git rebase.

    ### Git Tips
    - Run git status to check the current state of the repo
    - Run git add / git commit to save changes before they get lost
    - Run git status to see all untracked files and changes to tracked files
    - Run git diff to see the specific changes to tracked files
    - Run git log to see the commit history and understand recent changes
    #{co_author_tip()}
    """
  end

  defp co_author_tip do
    if EvoGit.Config.resolve([:git, :co_authored_by_enabled]) != false do
      "- When committing, append `Genesis <noreply@evogit.ai>` as a co-author on git commits using a second `-m` flag (e.g., `git commit -m \"message\" -m \"Co-authored-by: Genesis <noreply@evogit.ai>\"`)."
    else
      ""
    end
  end

  @doc """
  Executes the shell tool.
  """
  def execute(args, repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "command") do
      {:ok, command} ->
        timeout = Map.get(args, "timeout", @default_timeout)

        max_bytes =
          Map.get(
            args,
            "max_bytes",
            EvoGit.Config.resolve([:truncation, :tool_output_default_max_bytes])
          )

        do_execute(command, repo_path, repo_root, timeout, max_bytes)

      {:error, message} ->
        message
    end
  end

  @doc """
  Converts milliseconds to a human-readable duration string.

  ## Examples

      iex> format_duration(0)
      "0 ms"

      iex> format_duration(456)
      "456 ms"

      iex> format_duration(1234)
      "1.23 s"

      iex> format_duration(65000)
      "1m 5s"

      iex> format_duration(3723000)
      "1h 2m 3s"

  """
  def format_duration(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1000 ->
        "#{ms} ms"

      ms < 60_000 ->
        seconds = ms / 1000
        "#{:erlang.float_to_binary(seconds, decimals: 2)} s"

      ms < 3_600_000 ->
        minutes = div(ms, 60_000)
        seconds = div(rem(ms, 60_000), 1000)
        "#{minutes}m #{seconds}s"

      true ->
        hours = div(ms, 3_600_000)
        remaining = rem(ms, 3_600_000)
        minutes = div(remaining, 60_000)
        seconds = div(rem(remaining, 60_000), 1000)
        "#{hours}h #{minutes}m #{seconds}s"
    end
  end

  defp do_execute(command, repo_path, repo_root, timeout, max_bytes) do
    case main_copy_mutation_error(command, repo_path, repo_root) do
      nil -> do_execute_allowed(command, repo_path, repo_root, timeout, max_bytes)
      error -> error
    end
  end

  # Hard-block: a command that `cd`s into the repository's MAIN working copy
  # (`repo_root`) AND runs a mutating git command could move the main copy's
  # HEAD onto an agent branch (e.g. `cd <foreign_root> && git checkout
  # evogit-agent-T<task>-A<agent>` from inside a writable-foreign-repo worktree
  # switches the MAIN copy — `git checkout` with cwd outside a registered
  # linked worktree targets the main tree). Such mutations are blocked before
  # anything executes; agents must work inside their own worktree. Returns an
  # error string, or nil when the command is allowed.
  defp main_copy_mutation_error(command, repo_path, repo_root) do
    root = Platform.safe_expand(repo_root)

    if cd_targets(command, repo_path) |> Enum.any?(&(&1 == root)) and
         String.match?(command, @mutating_git_regex) do
      "Error: This command changes directory into the repository's MAIN working copy (`#{repo_root}`) and runs a mutating git command (checkout/switch/reset/merge/pull). Mutating the main working copy is blocked — your worktree is at `#{repo_path}`. Run git commands from inside your worktree instead."
    end
  end

  defp do_execute_allowed(command, repo_path, repo_root, timeout, max_bytes) do
    shell = Platform.shell()
    shell_args = Platform.shell_args(command)

    start = System.monotonic_time(:millisecond)

    case EvoGit.Sandbox.run_with_partial(
           repo_path,
           shell,
           shell_args,
           repo_root,
           timeout,
           max_bytes
         ) do
      {:ok, output, exit_code} ->
        elapsed = System.monotonic_time(:millisecond) - start
        timing = format_duration(elapsed)

        base =
          cond do
            exit_code == 0 ->
              "[Took: #{timing}] [Exit Code: 0] Command executed successfully. Output:\n#{output}"

            desc = describe_exit_code(exit_code) ->
              "[Took: #{timing}] [Exit Code: #{exit_code}] #{desc.header} #{desc.description} Output:\n#{output}"

            true ->
              "[Took: #{timing}] [Exit Code: #{exit_code}] Command failed. Output:\n#{output}"
          end

        append_hints(base, command, repo_path, repo_root)

      {:timeout, partial_output} ->
        elapsed = System.monotonic_time(:millisecond) - start
        timing = format_duration(elapsed)

        base =
          "Command timed out after #{timeout}ms (actual: #{timing}). Partial output:\n#{partial_output}"

        append_hints(base, command, repo_path, repo_root)
    end
  end

  # Appends non-fatal guidance hints about the command (cd warnings + redundant
  # nested-shell detection) to the tool output, regardless of exit code.
  defp append_hints(base, command, repo_path, repo_root) do
    [
      detect_cd_warnings(command, repo_path, repo_root),
      detect_redundant_shell(command)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> base
      hints -> base <> "\n\n" <> Enum.join(hints, "\n")
    end
  end

  # Unix exit codes >= 128 indicate the process was terminated by a signal.
  # The signal number is `exit_code - 128`. This map covers well-known signals;
  # any other code >= 128 falls back to a generic signal explanation.
  @known_signal_exits %{
    129 => {1, "SIGHUP", "hangup"},
    130 => {2, "SIGINT", "interrupt (typically Ctrl+C)"},
    131 => {3, "SIGQUIT", "quit"},
    132 => {4, "SIGILL", "illegal instruction"},
    133 => {5, "SIGTRAP", "trace/breakpoint trap"},
    134 =>
      {6, "SIGABRT",
       "an assertion failure, a fatal internal error, or an explicit call to abort()"},
    135 => {7, "SIGBUS", "a bus error — typically an unaligned memory access or mapping error"},
    136 =>
      {8, "SIGFPE",
       "a floating point exception — typically an integer division by zero or an invalid arithmetic operation"},
    137 =>
      {9, "SIGKILL",
       "an **Out-Of-Memory (OOM)** condition — the process consumed too much memory and was terminated by the kernel's OOM killer or the sandbox memory limit (MemoryMax). The output below is everything captured before the process was killed. Consider reducing memory usage"},
    138 => {10, "SIGUSR1", "user-defined signal 1"},
    139 =>
      {11, "SIGSEGV",
       "a segmentation fault — a memory access violation. The process tried to read or write an invalid memory address. This is a crash in the program itself, not a normal error"},
    140 => {12, "SIGUSR2", "user-defined signal 2"},
    141 => {13, "SIGPIPE", "a broken pipe — writing to a pipe with no readers"},
    142 => {14, "SIGALRM", "an alarm clock signal"},
    143 =>
      {15, "SIGTERM",
       "a termination signal. This can be sent by the system, a process manager, or another process"}
  }

  @doc """
  Detects when an exit code indicates the process was terminated by a Unix signal
  (exit codes >= 128, where signal number = exit_code - 128).

  Returns `%{header: ..., description: ...}` for signal-based exits, or `nil` for
  exit codes that are not signal-based (0, or non-zero codes below 128). The result
  is only meaningful on Unix shells (bash); on Windows, exit codes don't follow
  this convention, but since signal-based codes are rare in PowerShell the detection
  is harmless to apply universally.
  """
  def describe_exit_code(exit_code) when exit_code >= 128 do
    {signal_num, signame, detail} =
      case Map.get(@known_signal_exits, exit_code) do
        nil ->
          signal_number = exit_code - 128
          {signal_number, nil, "an abnormal termination, not a normal error exit"}

        {num, name, desc} ->
          {num, name, desc}
      end

    header =
      case signame do
        nil ->
          "Command was killed by signal (exit code #{exit_code} — signal #{signal_num})."

        name ->
          "Command was killed by signal (exit code #{exit_code} — #{name})."
      end

    description =
      case signame do
        nil ->
          "The process was terminated by signal #{signal_num} (exit code #{exit_code}). This is #{detail}."

        name ->
          "The process was killed by the operating system (#{name}). This is typically #{detail}."
      end

    %{header: header, description: description}
  end

  def describe_exit_code(_exit_code), do: nil

  @doc false
  def detect_cd_warnings(command, repo_path, repo_root) do
    worktree_base = EvoGit.AgentScheduler.Worktrees.workers_dir(repo_root)
    root = Platform.safe_expand(repo_root)

    command
    |> cd_targets(repo_path)
    |> Enum.reduce([], fn target, acc ->
      cond do
        not EvoGit.Platform.path_under?(target, repo_path) and
            EvoGit.Platform.path_under?(target, worktree_base) ->
          [
            "⚠️ You are trying to `cd` into another agent's worktree. Your worktree is at `#{repo_path}`. Double-check if this is the right path. If this is intentional, you can ignore this warning."
            | acc
          ]

        target == root ->
          [
            "⚠️ You are trying to `cd` into the repository root, which is NOT your worktree. Your worktree is at `#{repo_path}`. Double-check if this is the right path. If this is intentional, you can ignore this warning."
            | acc
          ]

        true ->
          acc
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
    |> case do
      [] -> nil
      warnings -> Enum.join(warnings, "\n")
    end
  end

  @doc """
  Returns true if the command contains a `cd` into the agent's own worktree
  (`repo_path`), which is redundant since the working directory is already set.
  """
  def redundant_cd?(command, repo_path, _repo_root) do
    worktree = Platform.safe_expand(repo_path)

    cd_targets(command, repo_path)
    |> Enum.any?(&(&1 == worktree))
  end

  @doc """
  Returns the redundant-cd warning message for the given worktree path.
  """
  def redundant_cd_warning(repo_path) do
    "⚠️ You don't need to `cd` into your worktree — your working directory is already set to it (`#{repo_path}`). Just run commands directly without changing directory."
  end

  # Absolute shell path prefixes, e.g. `/bin/sh`, `/usr/bin/bash`.
  @absolute_shell_path_regex ~r{^/(usr/)?bin/(sh|bash|zsh|dash|ksh|fish)$}

  # Bare shell names, e.g. `sh`, `bash`.
  @bare_shell_name_regex ~r/^(sh|bash|zsh|dash|ksh|fish)$/

  # `-c`-style invocation flags: `-c`, `-ec`, `-lc`, `-ic`, `--command`.
  @shell_flag_regex ~r/^-(?:c|ec|lc|ic)(?:\s|$)|^--command(?:\s|$)/

  @doc """
  Detects when a command redundantly invokes a nested shell (e.g. `/bin/sh -c 'ls'`).

  The shell tool already runs the command inside the effective shell, so
  spawning another shell is unnecessary. Returns a short hint string when the
  command (trimmed of leading whitespace) starts with an absolute shell path
  (e.g. `/bin/sh`, `/usr/bin/bash`) optionally followed by a `-c`-style flag
  (`-c`, `-ec`, `-lc`, `-ic`, `--command`) or nothing at all, or with a bare
  shell name (`sh`, `bash`, ...) followed by a `-c`-style flag. Returns `nil`
  otherwise.

  Legitimate cases are NOT flagged: absolute shell paths or bare shell names
  followed by a non-flag argument (e.g. `/bin/bash script.sh`, `sh script.sh`),
  and normal commands (`ls -la`, `mix test`).

  `shell_name` defaults to the effective shell from `EvoGit.Platform.shell/0`
  and is used in the hint's parenthetical.
  """
  @spec detect_redundant_shell(String.t(), String.t() | nil) :: String.t() | nil
  def detect_redundant_shell(command, shell_name \\ nil) when is_binary(command) do
    shell_name = shell_name || Platform.shell()

    case redundant_shell_prefix(String.trim_leading(command)) do
      nil ->
        nil

      prefix ->
        "💡 You don't need to invoke `#{prefix}` — this tool already runs your command in a shell (`#{shell_name}`). Just run the command directly."
    end
  end

  # Extracts the detected redundant shell prefix (e.g. "/bin/sh -c", "sh -c",
  # or just "/bin/sh" for a bare absolute path). Returns nil when the command
  # does not redundantly invoke a nested shell.
  defp redundant_shell_prefix(command) do
    {shell, rest} = split_first_token(command)

    cond do
      # Absolute shell path: flagged with a -c-style flag OR with nothing
      # after it (e.g. bare `/bin/sh`).
      absolute_shell_path?(shell) and
          (rest == "" or String.match?(rest, @shell_flag_regex)) ->
        redundant_shell_prefix_for(shell, rest)

      # Bare shell name: flagged ONLY when followed by a -c-style flag
      # (e.g. `sh -c 'ls'`); `sh script.sh` and bare `sh` are not flagged.
      bare_shell_name?(shell) and String.match?(rest, @shell_flag_regex) ->
        redundant_shell_prefix_for(shell, rest)

      true ->
        nil
    end
  end

  defp redundant_shell_prefix_for(shell, rest) do
    case split_first_token(rest) do
      {"", ""} -> shell
      {flag, _} -> shell <> " " <> flag
    end
  end

  defp split_first_token(command) do
    case String.split(command, ~r/\s+/, parts: 2) do
      [token] -> {token, ""}
      [token, rest] -> {token, rest}
    end
  end

  defp absolute_shell_path?(token), do: String.match?(token, @absolute_shell_path_regex)
  defp bare_shell_name?(token), do: String.match?(token, @bare_shell_name_regex)

  # Extracts the `cd` targets from a command, resolving relative targets
  # against the worktree cwd (`repo_path`) so consumers can compare them with
  # absolute paths (`repo_path`, `repo_root`, the worktree base).
  defp cd_targets(command, repo_path) do
    @cd_regex
    |> Regex.scan(command, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&Platform.safe_expand(&1, repo_path))
  end
end
