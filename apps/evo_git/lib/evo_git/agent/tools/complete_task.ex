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
  alias EvoGit.Agent.Result

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "complete_task",
      description:
        "Call this tool to report your findings and results. This is the ONLY way to finish. " <>
          "Your result MUST summarize the status of the ORIGINAL objective as a whole, not just the most recent sub-task you worked on.",
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

  Returns a `%EvoGit.Agent.Result{}` struct with :result, :commit_sha, :branch, and :repo_id.

  The `repo_id` field is automatically populated from the process dictionary
  key `:evogit_repo_id` (set at dispatch time).

  ## Options
    - `:base_commit` - The commit SHA the agent started on (required for metadata)
    - `:parent_id` - The parent agent ID (if this is a subagent)
    - `:depth` - The depth of this agent in the hierarchy
    - `:objective` - The objective/task this agent was working on
    - `:usage` - The cumulative `EvoGit.Agent.Usage.t()` for this agent run
  """
  @spec complete(pos_integer(), String.t(), String.t(), keyword()) :: Result.t()
  def complete(agent_id, result, commit_sha, opts \\ []) do
    base_commit = Keyword.get(opts, :base_commit)
    parent_id = Keyword.get(opts, :parent_id)
    depth = Keyword.get(opts, :depth, 0)
    objective = Keyword.get(opts, :objective)
    archive = Keyword.get(opts, :archive, false)
    repo_path = Process.get(:repo_path)

    # Derive branch name using task-scoped naming: evogit-agent-T<task_number>-A<task_local_id>
    # Look up task_id/task_number from SchedMeta and task_local_id from AgentState via ETS
    {task_id, task_number, task_local_id} = lookup_task_info(agent_id)
    branch_name = "evogit-agent-T#{task_number}-A#{task_local_id}"

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
        usage: format_usage_for_note(Keyword.get(opts, :usage)),
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end

    if archive and base_commit do
      write_archive_refs(repo_path, task_id, task_local_id, agent_id, base_commit, commit_sha, %{
        objective: objective,
        result: result,
        parent_id: parent_id,
        depth: depth,
        branch_name: branch_name,
        usage: Keyword.get(opts, :usage),
        completed_at: DateTime.utc_now()
      })
    end

    %Result{
      result: result,
      commit_sha: commit_sha,
      branch: branch_name,
      repo_id: Process.get(:evogit_repo_id),
      usage: Keyword.get(opts, :usage)
    }
  end

  defp lookup_task_info(agent_id) do
    {task_id, task_number} =
      case :ets.lookup(:evogit_sched_meta, agent_id) do
        [{^agent_id, %{task_id: tid, task_number: tn}}] ->
          {tid, tn}

        [{^agent_id, %{task_id: tid}}] ->
          # Backward compat: task_number may be nil in older entries
          {tid, nil}

        _ ->
          {0, nil}
      end

    task_local_id =
      case :ets.lookup(:evogit_agent_state, agent_id) do
        [{^agent_id, %{task_local_id: tlid}}] when is_integer(tlid) -> tlid
        _ -> 0
      end

    {task_id, task_number, task_local_id}
  end

  defp add_metadata_note(repo_path, commit_sha, metadata) do
    note_content = Jason.encode!(metadata, pretty: true)

    # Use a notes ref specific to evogit to avoid conflicts with user's notes
    case Git.add_note(repo_path, commit_sha, note_content, ["--ref=evogit"]) do
      {:ok, _} ->
        Logger.info("Wrote git note for commit #{commit_sha} (ref: evogit)")
        :ok

      {:error, _, _msg} ->
        # If custom ref fails (might not exist yet), try with force to create it
        handle_fallback(repo_path, commit_sha, note_content)

      {:conflict, _msg} ->
        # git notes add returns exit code 1 when note already exists — overwrite with force
        handle_fallback(repo_path, commit_sha, note_content)
    end
  end

  defp handle_fallback(repo_path, commit_sha, note_content) do
    case Git.add_note(repo_path, commit_sha, note_content, ["--ref=evogit"], true) do
      {:ok, _} ->
        Logger.info("Wrote git note for commit #{commit_sha} (ref: evogit, forced)")
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

  defp format_usage_for_note(nil), do: nil

  defp format_usage_for_note(%EvoGit.Agent.Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      cost: usage.total_cost
    }
  end

  defp write_archive_refs(
         repo_path,
         task_id,
         task_local_id,
         agent_id,
         base_commit,
         final_commit,
         data
       ) do
    ref_start = "refs/genesis/archive/T#{task_id}-A#{task_local_id}-start"
    ref_final = "refs/genesis/archive/T#{task_id}-A#{task_local_id}-final"

    # Write refs to protect commits from gc
    Git.update_ref(repo_path, ref_start, base_commit)
    Git.update_ref(repo_path, ref_final, final_commit)

    record = %{
      agent_id: agent_id,
      parent_id: data[:parent_id],
      depth: data[:depth] || 0,
      objective: data[:objective],
      result: data[:result],
      base_commit: base_commit,
      final_commit: final_commit,
      archive_ref_start: ref_start,
      archive_ref_final: ref_final,
      branch_name: data[:branch_name],
      usage: format_usage_for_note(data[:usage]),
      started_at: parse_started_at(Process.get(:evogit_started_at)),
      completed_at: data[:completed_at]
    }

    # Write to the archive records ETS table (if it exists)
    case :ets.whereis(:evogit_archive_records) do
      :undefined -> :ok
      _tid -> :ets.insert(:evogit_archive_records, {task_id, record})
    end

    Logger.info("Archive: Wrote refs #{ref_start} and #{ref_final} for agent #{agent_id}")
  end

  defp parse_started_at(nil), do: nil

  defp parse_started_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
