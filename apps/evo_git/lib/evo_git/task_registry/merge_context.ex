defmodule EvoGit.TaskRegistry.MergeContext do
  @moduledoc """
  Merge-conflict-resolution context builder for `EvoGit.TaskRegistry`.

  When an evolve task is created to resolve a merge conflict for a completed
  task (`:merge_from`), this module loads the previous task and builds the
  context block (task id, shas, branch name, merge target, goal, hints) that
  gets prepended to the new task's objective. It also threads the previous
  task's end commit (`:starting_commit`) and foreign repos into the new
  task's opts.
  """

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo

  @doc """
  Builds the opts for an evolve task that resolves a merge conflict for the
  task identified by `merge_from`.

  Strips the `:merge_from`/`:merge_target` keys (they must never leak into the
  runtime opts), then — when the previous task is found — sets
  `:starting_commit` to the previous task's end commit, carries over the
  previous task's `:foreign_repos`, and prepends the merge context block to the
  `:objective`. Returns the original opts (minus the merge keys) when the
  previous task can't be found.
  """
  def apply_merge_context(opts, _task_id, merge_from, merge_target) do
    # Strip :merge_from/:merge_target first so they never leak into runtime opts.
    opts = Keyword.drop(opts, [:merge_from, :merge_target])

    prev_task = EvoGit.TaskRegistry.get_task(merge_from)

    if is_nil(prev_task) do
      # Previous task not found — run the task with the original opts.
      opts
    else
      opts =
        if is_binary(prev_task.commit_sha) and prev_task.commit_sha != "" do
          # The previous task's end commit takes priority as :starting_commit.
          Keyword.put(opts, :starting_commit, prev_task.commit_sha)
        else
          opts
        end

      opts =
        case prev_task.opts do
          prev_opts when is_list(prev_opts) ->
            # Give the merge agent the same foreign repo access. The previous
            # task's opts came back from the SQLite store, where the Codec JSON
            # round-trip turned %ForeignRepo{} structs into string-keyed maps —
            # normalize them back into structs (dropping unparseable entries) so
            # downstream dot-access (Runtime.Helpers.merge_foreign_repos/2) never
            # crashes with a KeyError.
            case Keyword.get(prev_opts, :foreign_repos) do
              nil ->
                opts

              foreign_repos when is_list(foreign_repos) ->
                repos =
                  foreign_repos
                  |> Enum.map(&ForeignRepo.normalize/1)
                  |> Enum.reject(&is_nil/1)

                Keyword.put(opts, :foreign_repos, repos)

              _ ->
                opts
            end

          _ ->
            opts
        end

      block = build_merge_context_block(prev_task, merge_target)
      objective = Keyword.get(opts, :objective, "")
      Keyword.put(opts, :objective, block <> "\n\n" <> objective)
    end
  end

  @doc """
  Builds a "Merge Conflict Resolution Context" block string from a completed
  task's `%TaskInfo{}` struct and the merge target branch.
  """
  def build_merge_context_block(%TaskInfo{} = prev_task, merge_target) do
    base_sha = prev_task.base_sha
    commit_sha = prev_task.commit_sha
    branch_name = prev_task.branch_name || "unknown"
    target = merge_target || "unknown"

    base_line =
      if is_binary(base_sha) and base_sha != "" do
        ["Base sha: #{base_sha}"]
      else
        []
      end

    commit_line =
      if is_binary(commit_sha) and commit_sha != "" do
        ["End (commit) sha: #{commit_sha}"]
      else
        []
      end

    goal =
      "Goal: You are resolving a merge conflict for a completed task: merge the target " <>
        "branch into your worktree (`git merge #{target}`), resolve ALL conflicts by " <>
        "thoughtfully combining changes from both sides, commit the merged result, then " <>
        "continue developing on top of it until the integrated result is coherent " <>
        "(compiles/tests pass)."

    own_range =
      cond do
        is_binary(base_sha) and base_sha != "" and is_binary(commit_sha) and commit_sha != "" ->
          "#{base_sha}..#{commit_sha}"

        is_binary(commit_sha) and commit_sha != "" ->
          commit_sha

        true ->
          "<base>..<end sha>"
      end

    target_range =
      if is_binary(base_sha) and base_sha != "" do
        "#{base_sha}..#{target}"
      else
        "<base>..<target>"
      end

    hints = [
      "Hints:",
      "- Commit conflict resolutions before delegating follow-up work: agents and " <>
        "subagents always spawn at a clean checkout of a specific commit, so uncommitted " <>
        "changes in a worktree are invisible to subagents.",
      "- To understand the change, inspect `git log/diff #{own_range}` for the task's own " <>
        "changes and `git log/diff #{target_range}` for the changes made on the target " <>
        "side since the base.",
      "- If conflicts are hard to resolve in one pass, either do incremental milestone " <>
        "merges (merge earlier commits one at a time, resolving and committing each step), " <>
        "or resolve conflicts in a rough way first, commit, and then continue developing " <>
        "on top of that commit to integrate the missing pieces (subagent-friendly because " <>
        "the rough state is committed)."
    ]

    lines =
      [
        "--- Merge Conflict Resolution Context ---",
        "Previous task id: #{prev_task.id}"
      ] ++
        base_line ++
        commit_line ++
        ["Task branch name: #{branch_name}", "Merge target branch: #{target}", goal] ++
        hints ++
        ["--- End Merge Conflict Resolution Context ---"]

    Enum.join(lines, "\n")
  end

  def build_merge_context_block(_, _), do: ""
end
