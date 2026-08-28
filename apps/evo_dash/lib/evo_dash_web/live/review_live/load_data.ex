defmodule EvoDashWeb.ReviewLive.LoadData do
  @moduledoc """
  Async review-data load for `EvoDashWeb.ReviewLive`.

  Runs the whole review-page load sequence (task, merge targets, review
  metadata, commits, and — on the `:commit` route — the commit-inspection
  data) OUTSIDE the LiveView process, in a supervised task. The LiveView
  spawns the task via its private `start_async_load/2` and applies the result
  from `{:review_data_loaded, ...}` messages; `@loading` renders the spinner
  until the result arrives. Kept as a support module (same pattern as
  `EvoDashWeb.ReviewLive.MergeCheck`) so the single-page LiveView stays lean.

  `load/3` returns a plain assigns map (no socket) so it can run in any
  process. All review operations run on the node being viewed: local →
  direct call, remote → RPC to the remote daemon (its own TaskRegistry + its
  own filesystem). RemoteNode returns the verbatim underlying value in both
  paths, so the pattern matches are identical for local and remote.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  @doc """
  Loads all review-page data for `task_id` on `node`.

  Options:
    * `:live_action` — `:show` or `:commit`. The `:commit` route additionally
      loads the commit-inspection data (header + file list).
    * `:inspect_commit_sha` — the commit being inspected (commit route only).

  Returns `{:ok, assigns_map} | {:error, reason_string}` — the error string
  is already gettext-wrapped for display.
  """
  def load(node, task_id, opts \\ []) do
    live_action = Keyword.get(opts, :live_action)
    inspect_commit_sha = Keyword.get(opts, :inspect_commit_sha)

    case EvoDash.NodeContext.get_task(node, task_id) do
      nil ->
        {:error, gettext("Task not found. It may have been deleted.")}

      task ->
        assigns = build_assigns(node, task_id, task)

        assigns =
          if live_action == :commit do
            Map.merge(assigns, commit_inspection(node, assigns, inspect_commit_sha))
          else
            assigns
          end

        {:ok, assigns}
    end
  end

  @doc """
  Whether the reviewed repo at `repo_path` is accessible on `node`.

  Mirrors `MergeCheck.repo_available?/2`'s gate: on the local node the path
  must be an existing directory; on remote nodes availability is derived from
  RPC results (a bare path is enough to attempt the check). The spawned load
  task runs in the same VM as the LiveView, so the `node == node()`
  comparison is still correct.
  """
  def repo_available?(node, repo_path) do
    if node == node() do
      repo_path != nil && File.dir?(repo_path)
    else
      repo_path != nil
    end
  end

  # Builds the full review-page assigns map (the ~30 keys the template reads)
  # from a fetched task. The per-repo data (branch existence, review metadata,
  # commits, merge targets) lives in the `@review_repos` list — one entry per
  # reviewable repo, PRIMARY FIRST — and the flat assigns are projected from
  # the primary entry (multi-repo support: foreign repos get their own entries).
  defp build_assigns(node, task_id, task) do
    result = task.result
    repo_path = task.opts[:path]

    {commit_sha, branch_name, agent_summary, pr_url, pr_title, repos} =
      case result do
        {:ok,
         %{
           commit_sha: sha,
           branch_name: branch,
           result: summary,
           pr_url: url,
           pr_title: title
         } = res} ->
          # `repos` is the STRING-keyed multi-repo result map
          # (%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}});
          # present only on multi-repo tasks. After a Store/Codec round trip the
          # top-level key may be "repos" (it is not in @result_data_fields), so
          # accept both key shapes.
          {sha, branch, summary, url, title, Map.get(res, :repos) || Map.get(res, "repos")}

        _ ->
          {nil, nil, nil, nil, nil, nil}
      end

    objective = (task.opts[:prompt] || task.opts[:objective]) |> to_string() |> String.trim()

    commit_sha = commit_sha || task.commit_sha

    review_repos =
      build_review_repos(node, task, repos, repo_path, commit_sha, branch_name)

    # The primary entry is always first and always present (LEGACY tasks have
    # exactly one entry) — the flat assigns below are projected from it.
    primary = Enum.find(review_repos, &(&1.repo_id == "primary"))

    title = pr_title || objective || primary.branch_name || gettext("Review Changes")

    can_resume =
      repo_available?(node, primary.repo_path) &&
        (primary.commit_sha != nil || primary.branch_name == nil)

    rs = task.review_status

    review_status =
      cond do
        primary.branch_name == nil -> :no_changes
        rs != nil -> rs
        not primary.branch_exists -> :open
        true -> :open
      end

    is_no_changes = primary.branch_name == nil && task.status in [:completed, :cancelled]

    # Persist SHAs when loading from branch (for future post-merge access).
    # PRIMARY-scoped by design: task.base_sha/commit_sha are the primary's;
    # foreign SHAs already live in the persisted `repos` result map.
    if (primary.branch_exists && primary.review_data && is_nil(task.base_sha)) and
         primary.base_sha do
      EvoDash.NodeContext.set_review_metadata(node, task_id, primary.base_sha, primary.commit_sha)
    end

    %{
      loading: false,
      error: nil,
      title: title,
      task_type: task.type,
      branch_name: primary.branch_name,
      commit_sha: primary.commit_sha,
      base_sha: primary.base_sha,
      agent_summary: agent_summary,
      review_status: review_status,
      branch_exists: primary.branch_exists || false,
      can_resume: can_resume || false,
      is_no_changes: is_no_changes,
      has_pr: pr_url != nil,
      pr_url: pr_url,
      review_data: primary.review_data,
      expanded_files: %{},
      file_context_levels: %{},
      selected_file: nil,
      repo_path: primary.repo_path,
      objective: objective,
      commits: primary.commits,
      archive_metadata: task.archive_metadata,
      task_usage: task.usage,
      agent_count: task.agent_count,
      task_status: task.status,
      model_id: task.model_id,
      started_at: task.started_at,
      finished_at: task.finished_at,
      merge_targets: primary.merge_targets,
      default_merge_target: primary.default_merge_target,
      merge_status: primary.merge_status,
      review_repos: review_repos,
      active_repo_id: "primary"
    }
  end

  # Builds the `@review_repos` list — one entry per reviewable repo, PRIMARY
  # FIRST. The primary entry always exists (LEGACY tasks without a `repos`
  # result key yield exactly one entry, so the page renders identical to
  # today). Foreign entries come from `task.opts[:foreign_repos]` normalized
  # via `ForeignRepo.normalize/1` (unparseable entries dropped) and are
  # included only when the repo's id appears in `repos` with a non-nil
  # branch_name — i.e. a writable foreign repo that produced commits; read-only
  # repos and writable-with-no-commits repos are absent from `repos`.
  defp build_review_repos(node, task, repos, repo_path, primary_commit_sha, primary_branch_name) do
    primary_ctx = %{
      repo_id: "primary",
      repo_path: repo_path,
      branch_name:
        if is_map(repos) do
          case Map.get(repos, "primary") do
            %{"branch_name" => branch} -> branch
            _ -> primary_branch_name
          end
        else
          primary_branch_name
        end,
      commit_sha:
        if is_map(repos) do
          case Map.get(repos, "primary") do
            %{"commit_sha" => sha} when is_binary(sha) -> sha
            _ -> primary_commit_sha
          end
        else
          primary_commit_sha
        end,
      base_sha: task.base_sha
    }

    foreign_ctxs =
      if is_map(repos) do
        task.opts[:foreign_repos]
        |> List.wrap()
        |> Enum.map(&EvoGit.Core.ForeignRepo.normalize/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn repo ->
          case Map.get(repos, repo.id) do
            %{"branch_name" => branch} when is_binary(branch) -> String.trim(branch) != ""
            _ -> false
          end
        end)
        |> Enum.map(fn repo ->
          entry = Map.get(repos, repo.id)

          %{
            repo_id: repo.id,
            repo_path: repo.root,
            branch_name: entry["branch_name"],
            commit_sha: entry["commit_sha"],
            base_sha: repo.base_sha
          }
        end)
      else
        []
      end

    [primary_ctx | foreign_ctxs]
    |> Enum.map(&build_repo_entry(node, &1))
  end

  # Loads the per-repo review data for one review-repo entry: branch existence,
  # review metadata, base SHA, commits, and merge targets. Mirrors the original
  # single-repo logic exactly, parameterized by the entry's repo path, branch,
  # and SHAs. `ctx.base_sha` is the per-repo fallback base: `task.base_sha` for
  # the primary (existing behavior), the ForeignRepo's `.base_sha` for foreign
  # repos (per-repo starting commit; may be nil — then the from_shas fallback
  # is skipped and review_data/commits degrade to nil/[]).
  defp build_repo_entry(node, ctx) do
    repo_id = ctx.repo_id
    repo_path = ctx.repo_path
    branch_name = ctx.branch_name
    commit_sha = ctx.commit_sha
    fallback_base_sha = ctx.base_sha

    repo_available = repo_available?(node, repo_path)

    # Merge-target branch selector: list local branches and resolve the
    # default merge target. Degrades gracefully to [] / nil when branches
    # cannot be listed (e.g. missing repo or unreachable remote node) —
    # plain case on the tuple returns, no try/rescue.
    {merge_targets, default_merge_target} =
      if repo_available do
        targets =
          case EvoDash.NodeContext.list_branches(node, repo_path) do
            {:ok, names} -> Enum.filter(names, &(is_binary(&1) and String.trim(&1) != ""))
            _ -> []
          end

        default =
          case EvoDash.NodeContext.default_merge_target(node, repo_path) do
            {:ok, name} -> name
            _ -> nil
          end

        {targets, default}
      else
        {[], nil}
      end

    branch_exists =
      !!(branch_name && repo_available && branch_exists_on_node?(node, repo_path, branch_name))

    review_data =
      cond do
        # Normal case: branch still exists
        branch_exists && repo_path ->
          case EvoDash.NodeContext.load_review_metadata(node, repo_path, branch_name) do
            {:ok, data} -> data
            _ -> nil
          end

        # Post-merge/reject case: branch gone but SHAs persisted. Primary uses
        # task.base_sha (existing behavior); foreign repos use their per-repo
        # base_sha (skipped when nil — no starting commit was persisted).
        not branch_exists && repo_path && fallback_base_sha && commit_sha ->
          case EvoDash.NodeContext.load_review_metadata_from_shas(
                 node,
                 repo_path,
                 fallback_base_sha,
                 commit_sha
               ) do
            {:ok, data} -> data
            _ -> nil
          end

        true ->
          nil
      end

    base_sha = if review_data, do: review_data.base_sha, else: fallback_base_sha

    commits =
      cond do
        branch_exists && repo_path ->
          case EvoDash.NodeContext.list_commits(node, repo_path, branch_name) do
            {:ok, commits} -> commits
            # Graceful degradation (missing repo, unreachable remote
            # node): render an empty commit list instead of crashing.
            _ -> []
          end

        not branch_exists && repo_path && fallback_base_sha && commit_sha ->
          case EvoDash.NodeContext.list_commits_from_shas(
                 node,
                 repo_path,
                 fallback_base_sha,
                 commit_sha
               ) do
            {:ok, commits} -> commits
            _ -> []
          end

        true ->
          []
      end

    %{
      repo_id: repo_id,
      repo_path: repo_path,
      branch_name: branch_name,
      commit_sha: commit_sha,
      base_sha: base_sha,
      branch_exists: branch_exists,
      review_data: review_data,
      commits: commits,
      merge_targets: merge_targets,
      default_merge_target: default_merge_target,
      merge_status: nil
    }
  end

  # Branch existence on the current node. For the local node this is
  # `EvoGit.Review.branch_exists?/2` (a raw boolean). For remote nodes it is
  # the RPC result, which may be `{:error, {kind, reason}}` on transport
  # failure — treated as branch-not-determinable (false) so the page degrades
  # to the existing post-merge/reject state instead of crashing.
  defp branch_exists_on_node?(node, repo_path, branch_name) do
    EvoDash.NodeContext.branch_exists?(node, repo_path, branch_name) == true
  end

  # Loads commit inspection data (header + file list) for the `:commit` route.
  # PRIMARY-scoped: reads the primary entry's repo_path/commits via the flat
  # assigns (foreign repos have no commit-inspection route).
  defp commit_inspection(node, assigns, inspect_commit_sha) do
    commit_sha = inspect_commit_sha || assigns.commit_sha

    commit_header =
      Enum.find(assigns.commits, &(&1.sha == commit_sha)) ||
        %EvoGit.Review.CommitInfo{
          sha: commit_sha,
          short_sha: String.slice(commit_sha, 0..7),
          message: gettext("Commit details"),
          author_name: "",
          date: DateTime.utc_now()
        }

    commit_data =
      case EvoDash.NodeContext.load_commit_files(node, assigns.repo_path, commit_sha) do
        {:ok, data} -> data
        _ -> nil
      end

    %{
      inspect_commit_sha: commit_sha,
      commit_header: commit_header,
      commit_data: commit_data,
      expanded_files: %{},
      file_context_levels: %{},
      selected_file: nil
    }
  end
end
