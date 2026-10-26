defmodule EvoGit.Agent.Tools.ShellTool do
  @moduledoc """
  Tool for executing shell commands.

  The MODEL-FACING name is `"bash"` on BOTH platforms — the trained register for
  "run a shell command". The INTERNAL dispatch key stays compile-time pinned per
  platform (`run_bash` on POSIX, `run_powershell` on Windows):
  `EvoGit.Agent.ToolNames.normalize/1` maps the model-facing `"bash"` onto the
  platform's key (so `EvoGit.Agent.Tools.execute/5` dispatches it) and
  `ToolNames.model_name/1` renders both internal keys back as `"bash"`.

  Resolves the effective shell at runtime (configurable via the `[tools] shell`
  config key, defaulting to bash on Linux/macOS and PowerShell on Windows):
  - POSIX shells (bash, sh, zsh, ...): invoked with `-c`
  - PowerShell (powershell, pwsh, ...): invoked with `-EncodedCommand`
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Platform

  # The MODEL-FACING tool name — `"bash"` on BOTH platforms. This is what the
  # LLM is offered; the platform's INTERNAL dispatch key (`run_bash` /
  # `run_powershell`) is resolved from it by `EvoGit.Agent.ToolNames.normalize/1`
  # inside `EvoGit.Agent.Tools.execute/5`.
  @tool_name "bash"

  # Default command timeout: 2 minutes. A longer-running command must pass an
  # explicit `timeout`; `@max_timeout` is the hard cap — a larger requested
  # value is CLAMPED (never rejected), so the advertised cap is the real cap.
  @default_timeout 120_000
  @max_timeout 1_800_000

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
          "description" => %{
            "type" => "string",
            "description" =>
              "Clear, short description of what this command does — supply this first."
          },
          "command" => %{"type" => "string", "description" => command_description()},
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Timeout in milliseconds for a FOREGROUND command. Default: #{@default_timeout}. " <>
                "Maximum: #{@max_timeout} (a larger value is clamped to it). A command still " <>
                "running when the timeout expires is killed. A background command " <>
                "(`run_in_background: true`) has no timeout — this value is ignored for it.",
            "default" => @default_timeout
          },
          "run_in_background" => %{
            "type" => "boolean",
            "description" =>
              "Run in the background and return a job id immediately (collect with job_output, stop with job_kill). " <>
                "No timeout applies. Use this for long-running work — never `&`/`nohup`."
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
    find_regex_line =
      if powershell?() do
        ""
      else
        "\n- In `find -regex` alternations, place the longest alternative first (e.g. `'.*\\.(tsx|ts)'`)."
      end

    ls_with_args =
      if powershell?() do
        "Get-ChildItem with args"
      else
        "ls with args"
      end

    tmp_suffix =
      if powershell?() do
        "."
      else
        ", never /tmp."
      end

    """
    Use the bash tool — not shell commands like cat, sed, grep or find — to run a shell command when the dedicated read/write/edit/glob/rg tools cannot do the job.

    Pass `description` FIRST — a clear, short description of what the command does, echoed back as a `# …` header on the result — then `command`. #{shell_intro()} `timeout` is in milliseconds and applies to FOREGROUND commands: default #{@default_timeout}, maximum #{@max_timeout} (a larger value is clamped to it), and a command still running when the timeout expires is killed.

    For work that should stay alive — a server, a watcher, a long build — or that you want to poll while you do something else, set `run_in_background: true`: it returns a job id immediately, has NO timeout, and notifies you with a `[NOTICE]` when the job finishes; read its output with `job_output`, list your jobs with `job_list`, and stop it with `job_kill`.
    NEVER background a command yourself with `&`, `nohup`, `setsid`, `disown`, `screen` or `tmux`: the sandbox kills the process group as soon as this call returns, so the command silently dies — and because the call still reports success (exit 0) with empty output, that failure is invisible (no job id, output discarded, no notification, not killable). Use `run_in_background: true` instead.
    Do not prefix a command with a shell prompt `$` — the command is already passed to the shell.

    The working directory is already the repo path (the current git worktree path) — do not `cd` into it, and never `cd` into the repository root or another agent's worktree. Use relative paths for in-repo operations and absolute paths for external ones, double-quote paths containing spaces, verify parent directories exist before creating files, and use #{tmp_var()} for temporary files#{tmp_suffix}
    Prefer the dedicated tools, not the shell:
    - #{no_shell_for_reads()}
    - Read files: the read tool (not #{read_file_alt()}). Edit files: the edit tool (not #{edit_file_alt()}). Write files: the write tool (not #{write_file_alt()}).
    - Search: glob or rg (not #{file_search_alt()}). Create directories: make_dir (not mkdir).
    - Listing: #{ls_with_args} for specific needs, e.g. `#{ls_command()}` for a detailed listing.
    - Communicate by outputting your answer directly (not #{output_alt()}).
    - Manage dependencies with the project's own package manager (uv, npm, mix, cargo)#{find_regex_line}

    Git — run all git operations here:
    - Never update the git config. Always create NEW commits rather than amending. Never use the -i flag (git rebase -i, git add -i need interactive input) and never --no-edit with git rebase.
    - NEVER run destructive commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly requests them — unauthorized destructive actions lose work.
    - Commit before delegating to a subagent: uncommitted changes are lost. Inspect state with git status / git diff / git log, then git add + git commit.
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

  A `run_in_background: true` call is handled FIRST — before `timeout` is read or
  validated — so a background start can never be rejected for a bad timeout (a
  background command has no timeout at all).
  """
  def execute(args, repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "command") do
      {:ok, command} ->
        if Shared.get_optional_boolean(args, "run_in_background", false) do
          start_background_job(command, repo_path, repo_root)
        else
          execute_foreground(command, args, repo_path, repo_root)
        end

      {:error, message} ->
        Failure.error(message)
    end
  end

  defp execute_foreground(command, args, repo_path, repo_root) do
    timeout = args |> Map.get("timeout", @default_timeout) |> effective_timeout()

    max_bytes =
      Map.get(
        args,
        "max_bytes",
        EvoGit.Config.resolve([:truncation, :tool_output_default_max_bytes])
      )

    do_execute(
      command,
      description_header(args),
      repo_path,
      repo_root,
      timeout,
      max_bytes
    )
  end

  # Starts a DETACHED background job and returns its id at once. The same
  # main-copy mutation guard as a foreground command applies first: a background
  # start can mutate anything a foreground command could, so it is gated exactly
  # like a write tool.
  defp start_background_job(command, repo_path, repo_root) do
    case main_copy_mutation_error(command, repo_path, repo_root) do
      nil -> do_start_background_job(command, repo_path, repo_root)
      error -> Failure.error(error)
    end
  end

  defp do_start_background_job(command, repo_path, repo_root) do
    case EvoGit.BackgroundJobs.start_job(%{
           command: command,
           cwd: repo_path,
           repo_root: repo_root,
           label: background_label(command),
           owner_pid: EvoGit.BackgroundJobs.current_owner_pid(),
           agent_id: Process.get(:evogit_agent_id),
           task_id: Process.get(:evogit_task_id)
         }) do
      {:ok, job} -> "started background job #{Map.get(job, :id, "unknown")}"
      {:error, message} -> Failure.error(message)
    end
  end

  # A short human label for the job list: the command's first line, bounded.
  defp background_label(command) do
    command
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.slice(0, 60)
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

  # The optional `description` argument as a `# …` header line for the result
  # text. Absent/blank/non-binary descriptions render `""`, so the output stays
  # byte-identical to the behaviour before the argument existed.
  defp description_header(args) do
    case args do
      %{"description" => text} when is_binary(text) ->
        case String.trim(text) do
          "" -> ""
          summary -> "# " <> summary <> "\n"
        end

      _ ->
        ""
    end
  end

  @doc """
  The effective (clamped) timeout for a requested `timeout` argument.

  An integer above the advertised maximum (#{@max_timeout} ms) is reduced to it;
  everything else is returned UNCHANGED (a non-integer value is left for the
  sandbox's own argument guard to report). Never raises.
  """
  def effective_timeout(timeout) when is_integer(timeout), do: min(timeout, @max_timeout)
  def effective_timeout(timeout), do: timeout

  defp do_execute(command, header, repo_path, repo_root, timeout, max_bytes) do
    case main_copy_mutation_error(command, repo_path, repo_root) do
      nil -> do_execute_allowed(command, header, repo_path, repo_root, timeout, max_bytes)
      error -> Failure.error(error)
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

  defp do_execute_allowed(command, header, repo_path, repo_root, timeout, max_bytes) do
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
        base = result_text(exit_code, output, header, format_duration(elapsed))

        append_hints(base, command, repo_path, repo_root)

      {:timeout, partial_output} ->
        elapsed = System.monotonic_time(:millisecond) - start
        timing = format_duration(elapsed)

        base =
          Failure.error(
            "the command timed out after #{timeout} ms (actual: #{timing}).",
            header <> "Partial output:\n" <> partial_output
          )

        append_hints(base, command, repo_path, repo_root)
    end
  end

  # Renders a completed command's result. Exit code 0 keeps the descriptive
  # `[Took: …] [Exit Code: 0] … Output:` envelope; EVERY non-zero exit is a
  # failure and therefore leads with the literal `Error: ` prefix (a signal kill
  # states the signal first and its explanation after the error line). A
  # supplied `description` becomes a `# …` header on the payload block — after
  # the error line on failures, so the failure text always starts with `Error: `.
  defp result_text(0, output, header, timing) do
    "#{header}[Took: #{timing}] [Exit Code: 0] Command executed successfully. Output:\n#{output}"
  end

  defp result_text(exit_code, output, header, _timing) do
    case describe_exit_code(exit_code) do
      %{header: signal_header, description: description} ->
        Failure.error(signal_header, description <> "\n\n" <> header <> "Output:\n" <> output)

      nil ->
        Failure.error(
          "the command failed with exit code #{exit_code}.",
          header <> "Output:\n" <> output
        )
    end
  end

  # Appends non-fatal guidance hints about the command (cd warnings + redundant
  # nested-shell detection + manual-backgrounding detection) as a TRAILING block
  # after a blank line following the payload, regardless of exit code. Rendered
  # through `Failure.notice/1`, so a hint never carries an emoji/marker prefix
  # and can never read as the failure.
  defp append_hints(base, command, repo_path, repo_root) do
    [
      detect_cd_warnings(command, repo_path, repo_root),
      detect_redundant_shell(command),
      detect_manual_background(command)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> base
      hints -> base <> Failure.notice(Enum.join(hints, "\n"))
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
            "You are trying to `cd` into another agent's worktree. Your worktree is at `#{repo_path}`. Double-check if this is the right path. If this is intentional, you can ignore this warning."
            | acc
          ]

        target == root ->
          [
            "You are trying to `cd` into the repository root, which is NOT your worktree. Your worktree is at `#{repo_path}`. Double-check if this is the right path. If this is intentional, you can ignore this warning."
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
    "You don't need to `cd` into your worktree — your working directory is already set to it (`#{repo_path}`). Just run commands directly without changing directory."
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
        "You don't need to invoke `#{prefix}` — this tool already runs your command in a shell (`#{shell_name}`). Just run the command directly."
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

  # Bare shell WORDS that manually background a command. Matched as whole words
  # (never as a path segment or a longer word).
  @manual_background_regexes [
    {"nohup", ~r/(?<![\w.\/-])nohup(?![\w.\/-])/},
    {"disown", ~r/(?<![\w.\/-])disown(?![\w.\/-])/},
    {"setsid", ~r/(?<![\w.\/-])setsid(?![\w.\/-])/}
  ]

  # A STANDALONE `&` on its own: NOT part of `&&`, `&>`, `&>>`, `>&`, `2>&1` or
  # `N>&M` — every one of those has `&` or `>` on the neighbouring side.
  @standalone_ampersand_regex ~r/(?<![&>])&(?![&>])/

  # Shell command separators. Used to split a command line into command
  # POSITIONS so `screen`/`tmux` are only treated as launchers where a command
  # actually starts (`cat tmux` is not a launch).
  @command_separator_regex ~r/[;&|()\n]+/

  # Quoted segments, removed BEFORE detection so `echo "a & b"` never reads as
  # manual backgrounding. Escaped double quotes are honored; single quotes take
  # no escapes (bash semantics).
  @quoted_segment_regex ~r/"(?:[^"\\]|\\.)*"|'[^']*'/

  @doc """
  Detects MANUAL backgrounding in a command string.

  A foreground `bash` call cannot background work: the sandbox tears the whole
  process group down when the call returns, so a `&`/`nohup`/`setsid` child dies
  with its output discarded — while the call still reports success (exit 0) with
  empty output. This returns a short corrective hint naming the detected
  construct (`&`, `nohup`, `disown`, `setsid`, `screen`, `tmux`) and the
  replacement (`run_in_background: true` + the job tools), or `nil` when the
  command does not background anything.

  Detection is deliberately CONSERVATIVE and quote-aware: a standalone `&` (not
  `&&`/`&>`/`&>>`/`>&`/`2>&1`/`N>&M`, not inside quotes), the bare words
  `nohup`/`disown`/`setsid`, `screen` in a command position as a session
  launcher, and `tmux` in a command position starting/attaching a session.

  Advisory only: never raises, never blocks and never rewrites the command.
  """
  @spec detect_manual_background(String.t()) :: String.t() | nil
  def detect_manual_background(command) when is_binary(command) do
    command
    |> strip_quoted_segments()
    |> manual_background_construct()
    |> case do
      nil -> nil
      construct -> manual_background_hint(construct)
    end
  end

  def detect_manual_background(_command), do: nil

  defp strip_quoted_segments(text), do: Regex.replace(@quoted_segment_regex, text, "")

  # The detected construct, rendered for the hint. Keyword constructs win over a
  # bare `&` (a `nohup cmd &` names the more specific cause).
  defp manual_background_construct(text) do
    cond do
      word = manual_background_word(text) ->
        "`#{word}`"

      launcher = session_launcher(text) ->
        "`#{launcher}`"

      String.match?(text, @standalone_ampersand_regex) ->
        "`&`"

      true ->
        nil
    end
  end

  defp manual_background_word(text) do
    Enum.find_value(@manual_background_regexes, fn {word, regex} ->
      if Regex.match?(regex, text), do: word
    end)
  end

  defp session_launcher(text) do
    text
    |> String.split(@command_separator_regex, trim: true)
    |> Enum.find_value(fn segment ->
      case String.split(segment, ~r/\s+/, trim: true) do
        ["screen" | rest] -> if screen_launch?(rest), do: "screen"
        ["tmux" | rest] -> if tmux_launch?(rest), do: "tmux"
        _ -> nil
      end
    end)
  end

  # `screen` launches a session BARE, with a COMMAND argument, or with a
  # session-launching flag bundle (`-dmS name cmd`, `-S name`, `-dm`). Listing /
  # query forms (`-ls`, `-list`, `-v`, `-X …`) are not launchers.
  defp screen_launch?([]), do: true

  defp screen_launch?([token | _rest]) do
    case token do
      "-" <> flags -> String.match?(flags, ~r/[dDmS]/)
      _command -> true
    end
  end

  # `tmux` launches a session BARE, or through `new` / `new-session` /
  # `new-window` / `neww` (optionally behind flags), or by attaching.
  defp tmux_launch?(rest) do
    rest
    |> Enum.drop_while(&String.starts_with?(&1, "-"))
    |> case do
      [] -> true
      [command | _rest] -> command in ["new", "new-session", "new-window", "neww", "attach", "at"]
    end
  end

  defp manual_background_hint(construct) do
    "Hint: #{construct} does not keep a command alive here — the sandbox kills the process group when this call returns, so the work dies and its output is lost. Use bash's `run_in_background: true` and collect the result with `job_output` (ids from `job_list`, stop with `job_kill`)."
  end

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
