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
    - When committing, append `EvoGit <noreply@evogit.ai>` as a co-author on git commits using a second `-m` flag (e.g., `git commit -m "message" -m "Co-authored-by: EvoGit <noreply@evogit.ai>"`).
    """
  end

  @doc """
  Executes the shell tool.
  """
  def execute(args, repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "command") do
      {:ok, command} ->
        do_execute(command, repo_path, repo_root)

      {:error, message} ->
        message
    end
  end

  defp do_execute(command, repo_path, repo_root) do
    shell = Platform.shell()
    shell_args = Platform.shell_args(command)
    {output, exit_code} = EvoGit.sandbox_run(repo_path, shell, shell_args, repo_root)

    base =
      if exit_code == 0 do
        "Command executed successfully.\nOutput:\n#{output}"
      else
        "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
      end

    case detect_cd_warnings(command, repo_path, repo_root) do
      nil -> base
      warning -> base <> "\n\n" <> warning
    end
  end

  @doc false
  def detect_cd_warnings(command, repo_path, repo_root) do
    worktree_base = Path.join([repo_root, ".evogit", "workers"])

    ~r/\bcd\s+["']?(\/[^\s"'&|;]+)/
    |> Regex.scan(command, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reduce([], fn target, acc ->
      cond do
        target == repo_path ->
          [
            "⚠️ You don't need to `cd` into your worktree — your working directory is already set to it (`#{repo_path}`). Just run commands directly without changing directory."
            | acc
          ]

        String.starts_with?(target, worktree_base <> "/") ->
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
end
