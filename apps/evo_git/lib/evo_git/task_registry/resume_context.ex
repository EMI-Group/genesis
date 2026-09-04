defmodule EvoGit.TaskRegistry.ResumeContext do
  @moduledoc """
  Resume context builder for `EvoGit.TaskRegistry`.

  When an evolve task resumes from a previous task, this module builds the
  context block (commits, objective, result, writable foreign repos) that gets
  prepended to the new task's objective. Caller-supplied `:foreign_repos` are
  normalized back into `%ForeignRepo{}` structs (persisted/CLI entries may be
  string-keyed maps from a Codec JSON round trip) and each repo's `base_sha`
  is overridden with the previous task's result `repos` commit when present —
  per-repo starting commits, same as the merge-conflict flow.
  """

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry.PrevTaskRepos
  alias EvoGit.TaskRegistry.RuntimeOpts

  @doc """
  Builds the objective and `runtime_opts` for an evolve task that resumes from
  a previous task. Injects the previous task's context (commits, objective,
  result) into the new objective and sets `:starting_commit` to the previous
  task's end commit. Caller-supplied `:foreign_repos` flow through normalized
  to `%ForeignRepo{}` structs, with per-repo `base_sha` overridden from the
  previous task's result `repos` when present. Falls back gracefully if the
  previous task can't be found or has no useful data.
  """
  def apply_resume_context(opts, task_id, resume_from_id) do
    # Strip :resume_from so it never leaks into the runtime opts.
    opts_without_resume = Keyword.delete(opts, :resume_from)

    prev_task = EvoGit.TaskRegistry.get_task(resume_from_id)

    # Normalize the caller-supplied :foreign_repos (entries may be string-keyed
    # maps from a Codec JSON round trip) and override each repo's base_sha with
    # the previous task's result repos commit when present. The key is only
    # (re)added when the normalized list is non-empty — a caller with no repos
    # keeps no :foreign_repos key.
    opts_with_repos =
      case Keyword.get(opts_without_resume, :foreign_repos) do
        foreign_repos when is_list(foreign_repos) ->
          repos =
            foreign_repos
            |> PrevTaskRepos.normalize_foreign_repos()
            |> PrevTaskRepos.apply_starting_commits(prev_task)

          case repos do
            [] -> opts_without_resume
            repos -> Keyword.put(opts_without_resume, :foreign_repos, repos)
          end

        _ ->
          opts_without_resume
      end

    {objective, runtime_opts} =
      if is_nil(prev_task) do
        # Previous task not found — run with the original objective.
        objective = Keyword.get(opts_with_repos, :objective, "")

        {_input_arg, runtime_opts} =
          RuntimeOpts.build_common_runtime_opts(opts_with_repos, task_id, :evolve)

        {objective, runtime_opts}
      else
        context_block = build_resume_context_block(prev_task)

        objective = Keyword.get(opts_with_repos, :objective, "")

        objective =
          if context_block != "", do: context_block <> "\n\n" <> objective, else: objective

        # The previous task's commit_sha takes priority as :starting_commit.
        prev_commit_sha = prev_task.commit_sha

        opts_with_commit =
          if is_binary(prev_commit_sha) and prev_commit_sha != "" do
            Keyword.put(opts_with_repos, :starting_commit, prev_commit_sha)
          else
            opts_with_repos
          end

        {_input_arg, runtime_opts} =
          RuntimeOpts.build_common_runtime_opts(opts_with_commit, task_id, :evolve)

        {objective, runtime_opts}
      end

    {objective, runtime_opts}
  end

  @doc """
  Builds a "Previous Task Context" block string from a completed task's
  `%TaskInfo{}` struct. Includes commits, writable foreign repos, objective,
  and result summary.

  The block is fenced by `--- Previous Task Context ---` /
  `--- End Previous Task Context ---`. Sections are separated by blank
  lines; the objective and result sections wrap their (potentially
  multi-line) content in explicit `<<<BEGIN ...>>>` / `<<<END ...>>>`
  delimiters so the agent can never confuse a section label with its
  content, or the content with the outer fence. Returns an empty string
  if no useful context is available.
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

    commits_part = commits_line && "Previous task commits: #{commits_line}"

    writable_repos_part =
      case prev_task.opts do
        opts when is_list(opts) ->
          case Keyword.get(opts, :foreign_repos) do
            repos when is_list(repos) ->
              repos
              |> Enum.map(&ForeignRepo.normalize/1)
              |> Enum.reject(&is_nil/1)
              |> PrevTaskRepos.writable_repos_line()

            _ ->
              nil
          end

        _ ->
          nil
      end

    objective_part =
      if is_binary(old_objective) and old_objective != "" do
        delimited_section("Previous task objective:", old_objective, "OBJECTIVE")
      end

    result_part =
      if is_binary(agent_response) and agent_response != "" do
        delimited_section("Previous task result:", agent_response, "RESULT")
      end

    parts =
      Enum.reject([commits_part, writable_repos_part, objective_part, result_part], &is_nil/1)

    if parts == [] do
      ""
    else
      "--- Previous Task Context ---\n" <>
        Enum.join(parts, "\n\n") <> "\n--- End Previous Task Context ---"
    end
  end

  def build_resume_context_block(_), do: ""

  # Wraps potentially multi-line section content in explicit BEGIN/END
  # delimiters: a label line, then the content between `<<<BEGIN MARKER>>>` /
  # `<<<END MARKER>>>`. The triple-angle-bracket, all-caps markers are chosen
  # so no plausible agent-generated text collides with them.
  defp delimited_section(label, content, marker) do
    "#{label}\n<<<BEGIN #{marker}>>>\n#{content}\n<<<END #{marker}>>>"
  end

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
