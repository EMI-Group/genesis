defmodule EvoGit.Agent.Tools.Bash do
  @moduledoc """
  Tool for executing bash commands.
  """

  alias EvoGit.Agent.Tools.Shared

  # 3 minutes timeout for running complex commands, such as running tests or building the project.
  @default_timeout 180_000

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "run_bash",
      description: """
      Executes a shell command via bash -c.
      Useful for running scripts, building, testing, git or executing common command-line tools.
      The current working directory is automatically set to the repo path (the current git worktree path).

      ## General Guidelines
      STRICT CONSTRAINTS:
      - Do NOT use bash for file operations unless dedicated tools fail.
      - File search: Use glob (not find)
      - Directory creation: Use make_dir (not mkdir)
      - Read files: Use file_read (not cat/head/tail)
      - Edit files: Use edit_file (not sed/awk)
      - Write files: Use write_file (not echo/cat EOF)
      - Communication: Output directly (not echo/printf)
      Aside from these exceptions, you can use bash to run tools for file operations:
      - Use ls with args for listing files with specific needs (e.g., `ls -la` for detailed listing).
      - Use find for complex file searching with regex
      - Use mkdir for creating directories
      - Use project level package managers (e.g., uv, npm, mix, cargo) for managing dependencies.

      EXECUTION RULES:
      - Prefer relative paths for in-repo operations and absolute paths for external operations.
      - Double-quote all paths containing spaces.
      - Verify parent directories exist before creating files/folders.
      - Always use $TMPDIR for temporary files, never /tmp.
      - In `find -regex` alternations, place the longest alternative first (e.g., `'.*\.\(tsx\|ts\)'`).

      ## Git Specific Guidelines
      Use bash for all git operations
      - NEVER update the git config
      - NEVER run destructive git commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly
      requests these actions. Taking unauthorized destructive actions is unhelpful and can result in lost work, so it's best to ONLY run these
      commands when given direct instructions
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
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The bash command to execute"},
          "timeout" => %{"type" => "integer", "description" => "Timeout in milliseconds for this tool execution. Default: #{@default_timeout}", "default" => @default_timeout}
        },
        "required" => ["command"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the bash tool.
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
    {output, exit_code} =
      EvoGit.sandbox_run(repo_path, "bash", ["-c", command], repo_root)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end
end
