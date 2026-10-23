defmodule EvoGit.Agent.Tools.Git do
  @moduledoc """
  Tool for executing git commands.
  """

  alias EvoGit.Agent.Tools.Failure
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
      description:
        "Use the run_git tool to run a read-only git command. " <>
          "Arguments are a list of strings without the `git` prefix (e.g. [\"status\"], [\"diff\", \"--stat\"], [\"log\", \"-1\"]); the working directory is already the repository. " <>
          "Mutating subcommands are classified as write operations, so they are rejected for read-only agents and for read-only foreign repositories. " <>
          "Never update the git config and never run destructive commands (push --force, reset --hard, checkout ., restore ., clean -f, branch -D) unless the user explicitly asks for them. " <>
          "Never use interactive commands (-i, or --no-edit with rebase). " <>
          "Tips: git status shows the working tree, git diff shows the unstaged changes, git log shows the commit history.\n" <>
          co_author_tip,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The git arguments, e.g. [\"status\"], [\"diff\", \"HEAD\"] — the `git` executable itself is not included."
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
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
          Failure.error("git failed with exit code #{exit_code}.", "Output:\n#{output}")
        end

      {:error, message} ->
        Failure.error(message)
    end
  end
end
