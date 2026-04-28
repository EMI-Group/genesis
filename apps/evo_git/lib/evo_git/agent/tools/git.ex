defmodule EvoGit.Agent.Tools.Git do
  @moduledoc """
  Tool for executing git commands.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "run_git",
      description: """
      Executes a git command inside your worktree. The cwd is already set to the repository path.
      Provide arguments as a list of strings.

      - NEVER update the git config
      - NEVER run destructive git commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly
      requests these actions. Taking unauthorized destructive actions is unhelpful and can result in lost work, so it's best to ONLY run these
      commands when given direct instructions
      - CRITICAL: Commit the changes before calling any tools or subagents. Changes will be LOST if not committed.
      - CRITICAL: Always create NEW commits rather than amending
      - IMPORTANT: Never use git commands with the -i flag (like git rebase -i or git add -i) since they require interactive input which is not supported.
      - IMPORTANT: Do not use --no-edit with git rebase commands, as the --no-edit flag is not a valid option for git rebase.

      ## Tips
      - Run git status to check the current state of the repo
      - Run git add / git commit to save changes before they get lost
      - Run git status to see all untracked files and changes to tracked files
      - Run git diff to see the specific changes to tracked files
      - Run git log to see the commit history and understand recent changes
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of arguments to pass to git, e.g. ['status'], ['diff', 'HEAD']"
          }
        },
        "required" => ["args"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the git tool.
  """
  def execute(args, repo_path, repo_root) do
    case Shared.fetch_array_arg(args, "args") do
      {:ok, sanitized_args} ->
        {output, exit_code} =
          EvoGit.sandbox_run(repo_path, "git", sanitized_args, repo_root)

        if exit_code == 0 do
          "Command executed successfully.\nOutput:\n#{output}"
        else
          "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
        end

      {:error, message} ->
        message
    end
  end
end
