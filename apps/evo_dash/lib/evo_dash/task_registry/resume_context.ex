defmodule EvoDash.TaskRegistry.ResumeContext do
  @moduledoc """
  Resume context builder for `EvoDash.TaskRegistry`.

  When an evolve task resumes from a previous task, this module builds the
  context block (commits, objective, result) that gets prepended to the new
  task's objective.
  """

  alias EvoDash.TaskInfo
  alias EvoDash.TaskRegistry.RuntimeOpts

  @doc """
  Builds the objective and `runtime_opts` for an evolve task that resumes from
  a previous task. Injects the previous task's context (commits, objective,
  result) into the new objective and sets `:starting_commit` to the previous
  task's end commit. Falls back gracefully if the previous task can't be
  found or has no useful data.
  """
  def apply_resume_context(opts, task_id, resume_from_id) do
    # Strip :resume_from so it never leaks into the runtime opts.
    opts_without_resume = Keyword.delete(opts, :resume_from)

    prev_task = EvoDash.TaskRegistry.get_task(resume_from_id)

    {objective, runtime_opts} =
      if is_nil(prev_task) do
        # Previous task not found — run with the original objective.
        objective = Keyword.get(opts_without_resume, :objective, "")

        {_input_arg, runtime_opts} =
          RuntimeOpts.build_common_runtime_opts(opts_without_resume, task_id, :evolve)

        {objective, runtime_opts}
      else
        context_block = build_resume_context_block(prev_task)

        objective = Keyword.get(opts_without_resume, :objective, "")

        objective =
          if context_block != "", do: context_block <> "\n\n" <> objective, else: objective

        # The previous task's commit_sha takes priority as :starting_commit.
        prev_commit_sha = prev_task.commit_sha

        opts_with_commit =
          if is_binary(prev_commit_sha) and prev_commit_sha != "" do
            Keyword.put(opts_without_resume, :starting_commit, prev_commit_sha)
          else
            opts_without_resume
          end

        {_input_arg, runtime_opts} =
          RuntimeOpts.build_common_runtime_opts(opts_with_commit, task_id, :evolve)

        {objective, runtime_opts}
      end

    {objective, runtime_opts}
  end

  @doc """
  Builds a "Previous Task Context" block string from a completed task's
  `%TaskInfo{}` struct. Includes commits, objective, and result summary.
  Returns an empty string if no useful context is available.
  """
  def build_resume_context_block(%TaskInfo{} = prev_task) do
    base_sha = prev_task.base_sha
    commit_sha = prev_task.commit_sha

    commits_line =
      cond do
        is_binary(base_sha) and base_sha != "" and is_binary(commit_sha) and commit_sha != "" ->
          "#{base_sha}..#{commit_sha}"

        is_binary(commit_sha) and commit_sha != "" ->
          commit_sha

        true ->
          nil
      end

    old_objective =
      case prev_task.opts do
        opts when is_list(opts) -> Keyword.get(opts, :objective) || Keyword.get(opts, :prompt)
        _ -> nil
      end

    agent_response = extract_result_summary(prev_task.result)

    parts = []

    parts =
      if commits_line do
        parts ++ ["Previous task commits: #{commits_line}"]
      else
        parts
      end

    parts =
      if is_binary(old_objective) and old_objective != "" do
        parts ++ ["Previous task objective: #{old_objective}"]
      else
        parts
      end

    parts =
      if is_binary(agent_response) and agent_response != "" do
        parts ++ ["Previous task result:", agent_response]
      else
        parts
      end

    if parts == [] do
      ""
    else
      "--- Previous Task Context ---\n" <>
        Enum.join(parts, "\n") <> "\n--- End Previous Task Context ---"
    end
  end

  def build_resume_context_block(_), do: ""

  @doc """
  Extracts a human-readable summary string from a task result tuple
  (`{:ok, %{result: ...}}`, `{:error, reason}`, `{:exit, reason}`).
  """
  def extract_result_summary({:ok, %{result: summary}}) when is_binary(summary), do: summary

  def extract_result_summary({:ok, %{result: summary}}) when is_atom(summary),
    do: to_string(summary)

  def extract_result_summary({:error, reason}), do: "Error: #{inspect(reason)}"
  def extract_result_summary({:exit, reason}), do: "Exited: #{inspect(reason)}"
  def extract_result_summary(_), do: nil
end
