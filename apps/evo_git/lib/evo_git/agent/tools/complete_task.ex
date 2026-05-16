defmodule EvoGit.Agent.Tools.CompleteTask do
  @moduledoc """
  The completion tool that agents use to submit their final results.

  This tool has special handling:
  - It performs a git status check before allowing completion (can be disabled)
  - It records the branch name for the completion commit
  - It returns commit information along with the result

  The tool is handled specially in the agent loop and doesn't go through
  the standard tool execution pipeline.
  """

  require Logger

  alias EvoGit.Adapters.Git

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "complete_task",
      description:
        "Call this tool to report your findings and results. This is the ONLY way to finish.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "result" => %{
            "type" => "string",
            "description" => "The final findings, results, or report that you want to submit."
          },
          "check_git_status" => %{
            "type" => "boolean",
            description:
              "If true (default), checks if the workspace has uncommitted changes before completing. " <>
                "If set to false, the check is skipped.",
            default: true
          }
        },
        "required" => ["result"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Checks if the workspace is dirty and returns a warning message if so.

  Returns {:dirty, warning_message} if dirty, {:clean, nil} if clean.
  """
  def check_workspace_dirty(repo_path) do
    case Git.status(repo_path) do
      {:ok, status_output} when is_binary(status_output) and status_output != "" ->
        formatted_status = format_git_status_porcelain(status_output)

        warning_msg = """
        [NOTICE] The workspace has uncommitted changes.
        Please commit the necessary files before calling complete_task.

        Git status:
        #{formatted_status}

        After committing the files you want to keep, call complete_task again with check_git_status: false to skip the git status check.
        """

        {:dirty, warning_msg}

      _ ->
        {:clean, nil}
    end
  end

  @doc """
  Formats git status --porcelain output for display.
  Format: "XY filename" where X = staged, Y = unstaged
  """
  def format_git_status_porcelain(porcelain_output) do
    porcelain_output
    |> String.split("\n", trim: true)
    |> Enum.map(&format_porcelain_line/1)
    |> Enum.join("\n")
  end

  defp format_porcelain_line(line) do
    case String.graphemes(line) do
      [x, y | rest] ->
        filename = Enum.join(rest)
        status = porcelain_status_code_to_name(x, y)
        "#{status} #{filename}"

      _ ->
        line
    end
  end

  defp porcelain_status_code_to_name(" ", "M"), do: "modified"
  defp porcelain_status_code_to_name("M", " "), do: "staged"
  defp porcelain_status_code_to_name("M", "M"), do: "staged, modified"
  defp porcelain_status_code_to_name("A", " "), do: "staged (new)"
  defp porcelain_status_code_to_name(" ", "D"), do: "deleted"
  defp porcelain_status_code_to_name("D", " "), do: "staged (deleted)"
  defp porcelain_status_code_to_name("D", "D"), do: "staged, deleted"
  defp porcelain_status_code_to_name("R", " "), do: "staged (renamed)"
  defp porcelain_status_code_to_name(" ", "?"), do: "untracked"
  defp porcelain_status_code_to_name("?", "?"), do: "untracked"
  defp porcelain_status_code_to_name(x, y), do: "#{x}#{y}"

  @doc """
  Performs the actual completion: records branch name, adds metadata note.

  Returns {:ok, completion_map} with :result, :commit_sha, and :branch.

  ## Options
    - `:base_commit` - The commit SHA the agent started on (required for metadata)
    - `:parent_id` - The parent agent ID (if this is a subagent)
    - `:depth` - The depth of this agent in the hierarchy
    - `:objective` - The objective/task this agent was working on
  """
  def complete(agent_id, result, commit_sha, opts \\ []) do
    base_commit = Keyword.get(opts, :base_commit)
    parent_id = Keyword.get(opts, :parent_id)
    depth = Keyword.get(opts, :depth, 0)
    objective = Keyword.get(opts, :objective)
    repo_path = Process.get(:repo_path)

    # Branch name (created by scheduler at worktree creation, just record it here)
    branch_name = "agent/#{agent_id}"

    # Add metadata as git note (if we have the base commit)
    if base_commit do
      add_metadata_note(repo_path, commit_sha, %{
        agent_id: agent_id,
        base_commit: base_commit,
        final_commit: commit_sha,
        parent_id: parent_id,
        depth: depth,
        objective: objective,
        result: result,
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    %{
      result: result,
      commit_sha: commit_sha,
      branch: branch_name
    }
  end

  defp add_metadata_note(repo_path, commit_sha, metadata) do
    note_content = Jason.encode!(metadata, pretty: true)

    # Use a notes ref specific to evogit to avoid conflicts with user's notes
    case Git.add_note(repo_path, commit_sha, note_content, ["--ref=evogit"]) do
      {:ok, _} ->
        :ok

      {:error, _, _msg} ->
        # If custom ref fails (might not exist yet), try with force to create it
        handle_fallback(repo_path, commit_sha, note_content)

      {:conflict, _msg} ->
        # git notes add returns exit code 1 when the ref doesn't exist yet
        handle_fallback(repo_path, commit_sha, note_content)
    end
  end

  defp handle_fallback(repo_path, commit_sha, note_content) do
    case Git.add_note(repo_path, commit_sha, note_content, ["--ref=evogit"], force: true) do
      {:ok, _} ->
        :ok

      {:error, _code, msg} ->
        Logger.warning("Failed to write git note for commit #{commit_sha}: #{msg}")
        {:error, msg}

      {:conflict, msg} ->
        Logger.warning("Failed to write git note for commit #{commit_sha}: #{msg}")
        {:error, msg}
    end
  end

  @doc """
  Retrieves the metadata for an agent from their final commit's git note.

  Returns {:ok, metadata_map} or :error if not found.

  ## Metadata includes
    - `agent_id` - The agent's ID
    - `base_commit` - The commit the agent started on
    - `final_commit` - The agent's final commit
    - `parent_id` - The parent agent ID (if subagent)
    - `depth` - Depth in the agent hierarchy
    - `objective` - The objective/task the agent was given
    - `result` - The agent's final result message
    - `completed_at` - ISO8601 timestamp of completion
  """
  def get_agent_metadata(repo_path, commit_sha) do
    Git.get_note(repo_path, commit_sha, ["--ref=evogit"])
  end
end
