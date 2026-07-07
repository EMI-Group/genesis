defmodule EvoGit.Agent.Tools.Git do
  @moduledoc """
  Tool for executing git commands.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    co_author_tip =
      if EvoGit.Config.resolve([:git, :co_authored_by_enabled]) != false do
        "- When committing, append `Genesis <noreply@evogit.ai>` as a co-author on git commits using a second `-m` flag (e.g., `git commit -m \"message\" -m \"Co-authored-by: Genesis <noreply@evogit.ai>\"`)."
      else
        ""
      end

    ReqLLM.tool(
      name: "run_git",
      description: """
      Executes a git command inside your worktree. The cwd is already set to the repository path.
      Provide arguments as a list of strings, for example: ["status"], ["diff", "--stat"], ["log", "-1"].

      - NEVER update the git config
      - NEVER run destructive git commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly
      requests these actions. Taking unauthorized destructive actions is unhelpful and can result in lost work, so it's best to ONLY run these
      commands when given direct instructions.
      - Never use git commands with the -i flag (like git rebase -i or git add -i) since they require interactive input which is not supported.
      - Never use --no-edit with git rebase commands, as the --no-edit flag is not a valid option for git rebase.

      ## Tips
      - Run git status to check the current state of the repo
      - Run git diff to see the specific changes to tracked files
      - Run git log to see the commit history and understand recent changes
      #{co_author_tip}
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of arguments to pass to git, e.g. ['status'], ['diff', 'HEAD']"
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum output size in bytes before truncation. " <>
                "Default: 16384 (16KB). Increase up to 131072 (128KB) if you need more output.",
            "default" => 16_384
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
