defmodule EvoGit.Agent.Tools.ShellTool do
  @moduledoc """
  Tool for executing shell commands.

  Adapts automatically to the current platform at compile time:
  - Linux/macOS: uses bash
  - Windows: uses PowerShell
  """

  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Platform

  # Compile-time platform detection
  @os Platform.os()
  @on_windows @os == :windows

  # Compile-time tool name and shell identity
  @tool_name if(@on_windows, do: "run_powershell", else: "run_bash")
  @shell_name if(@on_windows, do: "PowerShell", else: "bash")
  @shell_flag if(@on_windows, do: "-Command", else: "-c")
  @tmp_var if(@on_windows, do: "$env:TEMP", else: "$TMPDIR")

  # Compile-time descriptions that differ by platform
  @command_description "The #{@shell_name} command to execute"

  # Compile-time prompt sections that differ by platform
  @shell_intro "Executes a command via #{@shell_name} #{@shell_flag}."

  @file_search_alt if(@on_windows, do: "Get-ChildItem", else: "find")
  @read_file_alt if(@on_windows, do: "Get-Content", else: "cat/head/tail")
  @edit_file_alt if(@on_windows, do: "string replacement", else: "sed/awk")
  @write_file_alt if(@on_windows, do: "Set-Content/Out-File", else: "echo/cat EOF")
  @output_alt if(@on_windows, do: "Write-Host/Write-Output", else: "echo/printf")
  @ls_command if(@on_windows, do: "Get-ChildItem -Force", else: "ls -la")

  @no_shell_for_reads if(
                        @on_windows,
                        do:
                          "Do NOT use PowerShell for file operations unless dedicated tools fail.",
                        else: "Do NOT use bash for file operations unless dedicated tools fail."
                      )

  # 3 minutes timeout for running complex commands
  @default_timeout 180_000

  @cd_regex ~r/\bcd\s+["']?(\/[^\s"'&;|]+)/

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
          "command" => %{"type" => "string", "description" => @command_description},
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Timeout in milliseconds for this tool execution. Default: #{@default_timeout}",
            "default" => @default_timeout
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum output size in bytes before truncation. " <>
                "Default: 16384 (16KB). Increase up to 131072 (128KB) if you need more output.",
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
      if @on_windows do
        ""
      else
        "- Use find for complex file searching with regex\n      "
      end

    tmp_suffix =
      if @on_windows do
        "."
      else
        ", never /tmp."
      end

    find_regex_line =
      if @on_windows do
        ""
      else
        "\n      - In `find -regex` alternations, place the longest alternative first (e.g., `'.*\\.(tsx|ts)'`)."
      end

    ls_with_args =
      if @on_windows do
        "Get-ChildItem with args"
      else
        "ls with args"
      end

    """
    #{@shell_intro}
    Useful for running scripts, building, testing, git or executing common command-line tools.
    The current working directory is automatically set to the repo path (the current git worktree path). Avoid using `cd` — the cwd is already correct.

    ## General Guidelines
    STRICT CONSTRAINTS:
    - #{@no_shell_for_reads}
    - File search: Use glob (not #{@file_search_alt})
    - Directory creation: Use make_dir (not mkdir)
    - Read files: Use file_read (not #{@read_file_alt})
    - Edit files: Use edit_file (not #{@edit_file_alt})
    - Write files: Use write_file (not #{@write_file_alt})
    - Communication: Output directly (not #{@output_alt})
    Aside from these exceptions, you can use #{@shell_name} to run tools for file operations:
    - Use #{ls_with_args} for listing files with specific needs (e.g., `#{@ls_command}` for detailed listing).
    #{find_line}- Use project level package managers (e.g., uv, npm, mix, cargo) for managing dependencies.

    EXECUTION RULES:
    - Prefer relative paths for in-repo operations and absolute paths for external operations.
    - Double-quote all paths containing spaces.
    - Verify parent directories exist before creating files/folders.
    - Always use #{@tmp_var} for temporary files#{tmp_suffix}#{find_regex_line}

    ## Git Specific Guidelines
    Use #{@shell_name} for all git operations
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
              "[Took: #{timing}]\n\nCommand executed successfully.\nOutput:\n#{output}"

            desc = describe_exit_code(exit_code) ->
              "[Took: #{timing}]\n\n#{desc.header}\n#{desc.description}\nOutput:\n#{output}"

            true ->
              "[Took: #{timing}]\n\nCommand failed with exit code #{exit_code}.\nOutput:\n#{output}"
          end

        case detect_cd_warnings(command, repo_path, repo_root) do
          nil -> base
          warning -> base <> "\n\n" <> warning
        end

      {:timeout, partial_output} ->
        elapsed = System.monotonic_time(:millisecond) - start
        timing = format_duration(elapsed)
        base = "Command timed out after #{timeout}ms (actual: #{timing}). Partial output:\n#{partial_output}"

        case detect_cd_warnings(command, repo_path, repo_root) do
          nil -> base
          warning -> base <> "\n\n" <> warning
        end
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

    command
    |> cd_targets()
    |> Enum.reduce([], fn target, acc ->
      cond do
        target != repo_path and EvoGit.Platform.path_under?(target, worktree_base) ->
          [
            "⚠️ You are trying to `cd` into another agent's worktree. Your worktree is at `#{repo_path}`. Double-check if this is the right path. If this is intentional, you can ignore this warning."
            | acc
          ]

        target == repo_root ->
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
    cd_targets(command)
    |> Enum.any?(&(&1 == repo_path))
  end

  @doc """
  Returns the redundant-cd warning message for the given worktree path.
  """
  def redundant_cd_warning(repo_path) do
    "⚠️ You don't need to `cd` into your worktree — your working directory is already set to it (`#{repo_path}`). Just run commands directly without changing directory."
  end

  defp cd_targets(command) do
    @cd_regex
    |> Regex.scan(command, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
