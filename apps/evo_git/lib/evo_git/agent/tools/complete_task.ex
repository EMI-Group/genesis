defmodule EvoGit.Agent.Tools.CompleteTask do
  @moduledoc """
  The completion tool that agents use to submit their final results.

  This tool has special handling:
  - It performs a git status check before allowing completion (can be disabled)
  - It creates a tag at the completion commit
  - It returns commit information along with the result

  The tool is handled specially in the agent loop and doesn't go through
  the standard tool execution pipeline.
  """

  alias EvoGit.Adapters.Git

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "complete_task",
      description:
        "Call this tool to submit your final findings. This is the ONLY way to finish.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "result" => %{
            "type" => "string",
            "description" => "The final result or findings"
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
  Performs the actual completion: syncs commit, creates tag, wraps result.

  Returns {:ok, completion_map} with :result, :commit_sha, and :tag.
  """
  def complete(agent_id, result, commit_sha) do
    tag_name = "subagent_#{agent_id}"
    repo_path = Process.get(:repo_path)
    Git.tag(repo_path, tag_name, commit_sha)

    %{
      result: result,
      commit_sha: commit_sha,
      tag: tag_name
    }
  end
end
