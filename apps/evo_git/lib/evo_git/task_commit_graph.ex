defmodule EvoGit.TaskCommitGraph do
  @moduledoc """
  App-layer bridge between a persisted task row (`%EvoGit.TaskInfo{}`) and the
  pure `EvoGit.CommitGraph` data API: resolves a task's DURABLE commit refs
  (the ones that outlive a recycled agent) and derives the repo-aware base
  commit, so the dashboard can draw the WHOLE task — from its base through
  every branch, including agents that have already completed and been recycled.

  Why this exists: the dashboard's live-agent ranges (`{base_commit,
  current_commit}` per agent) disappear once `EvoGit.AgentScheduler.Lifecycle`
  recycles an agent — recycling deletes both its ETS rows AND its
  `evogit-agent-*` branch. The commits survive on DURABLE refs recorded on the
  task row: `commit_sha` + `branch_name` (the `genesis/agent_<hex>` result
  branch created in `EvoGit.Runtime.Helpers.merge_and_report/4`) and the
  per-repo entries in the result's `"repos"` map.

  Every function is TOTAL — bad/absent data normalizes to empty rather than
  raising (a corrupt task row or a missing registry process degrades to an
  empty ref set).
  """

  require Logger

  alias EvoGit.Adapters.Git
  alias EvoGit.CommitGraph
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry.PrevTaskRepos

  @spec resolve_refs(TaskInfo.t() | nil) :: %{
          base_sha: String.t() | nil,
          tips: [String.t()],
          project_path: String.t() | nil
        }
  @doc """
  Resolves the DURABLE commit refs recorded on a task row (pure, no I/O).

  Gathers the task's `commit_sha` and `branch_name` (when non-blank) plus every
  `commit_sha` / `branch_name` under the result's STRING-keyed
  `"repos" => %{repo_id => %{"commit_sha" => ..., "branch_name" => ...}}` map.
  The persisted `result` is the DECODED result — an `{:ok, data}` tuple for a
  successful task — so both that tuple shape and a bare data map are accepted;
  `result` may also be `nil` or a legacy shape with no `"repos"` (never
  crashes). Tips are deduplicated with blanks dropped. `base_sha` is the task's
  `base_sha` when a non-blank string, else `nil`; `project_path` is
  `task.project_path`.

  A `nil` (or non-`%TaskInfo{}`) input yields
  `%{base_sha: nil, tips: [], project_path: nil}`.
  """
  def resolve_refs(%TaskInfo{} = task) do
    tips =
      [task.commit_sha, task.branch_name]
      |> Kernel.++(repo_refs(task.result))
      |> normalize_tips()

    %{
      base_sha: blank_to_nil(task.base_sha),
      tips: tips,
      project_path: task.project_path
    }
  end

  def resolve_refs(_task), do: empty_refs()

  @spec resolve(String.t()) :: %{
          base_sha: String.t() | nil,
          tips: [String.t()],
          project_path: String.t() | nil
        }
  @doc """
  Loads the task row via `EvoGit.TaskRegistry.get_task/1` and delegates to
  `resolve_refs/1`.

  Defensive by contract: a corrupt row (the Store raises on corrupt rows) or a
  missing/unreachable registry process degrades to the empty ref map rather
  than propagating the failure to the dashboard.
  """
  def resolve(task_id) when is_binary(task_id) do
    task_id
    |> EvoGit.TaskRegistry.get_task()
    |> resolve_refs()
  rescue
    e ->
      Logger.debug("TaskCommitGraph.resolve/1 failed for #{task_id}: #{Exception.message(e)}")
      empty_refs()
  catch
    kind, reason ->
      Logger.debug("TaskCommitGraph.resolve/1 failed for #{task_id}: #{inspect({kind, reason})}")
      empty_refs()
  end

  def resolve(_task_id), do: empty_refs()

  @spec for_task(String.t(), String.t(), [String.t() | nil], keyword()) :: {:ok, map()}
  @doc """
  Builds the task-scoped commit graph for `repo_path` (the orchestrator used by
  the RPC pass-through).

  Steps:

    1. `refs = resolve(task_id)` — the durable refs (never raises).
    2. Resolve the SINGLE base for `repo_path`, first non-blank wins:
       a. `opts[:base_sha]` — an optional explicit caller override;
       b. the repo-aware task base — `refs.base_sha` when `repo_path ==
          `refs.project_path`, else the `:base_sha` of a matching entry in
          `opts[:foreign_repos]` (each entry normalized via
          `EvoGit.Core.ForeignRepo.normalize/1`, nils dropped) whose `:root ==
          repo_path`;
       c. a merge-base fallback — for the first resolvable ref among
          `refs.tips ++ live_tips`, `Git.merge_base(repo_path, "HEAD", ref)`.
          During a live run HEAD sits at the task base, so the merge-base of
          HEAD and a live agent's tip IS the task base; after completion the
          merge-base of HEAD and the durable result commit is the task base.
       d. otherwise `nil` (⇒ empty graph).
    3. `tips = refs.tips ++ live_tips` (deduped, blanks dropped).
    4. `EvoGit.CommitGraph.for_task(repo_path, base, tips, opts)`.

  `opts` is passed through to `CommitGraph.for_task/4` (`:limit`);
  `:base_sha`/`:foreign_repos` are consumed here only. Always returns
  `{:ok, %{commits: [commit], refs: %{sha => [ref_name]}, truncated: boolean}}`
  (`truncated: true` when any tip range was cut at `opts[:limit]` — the flag
  from `CommitGraph.for_task/4`, carried verbatim).
  """
  def for_task(task_id, repo_path, live_tips, opts \\ []) do
    refs = resolve(task_id)
    foreign_repos = normalize_foreign_repos(Keyword.get(opts, :foreign_repos, []))
    base = resolve_base(repo_path, refs, foreign_repos, live_tips, opts)
    tips = normalize_tips(refs.tips ++ List.wrap(live_tips))

    CommitGraph.for_task(repo_path, base, tips, opts)
  end

  ## Base resolution

  # First non-blank wins: explicit override → repo-aware task base → merge-base
  # fallback → nil.
  defp resolve_base(repo_path, refs, foreign_repos, live_tips, opts) do
    with nil <- blank_to_nil(keyword_get(opts, :base_sha)),
         nil <- task_base_for_repo(repo_path, refs, foreign_repos),
         nil <- merge_base_fallback(repo_path, refs.tips ++ List.wrap(live_tips)) do
      nil
    end
  end

  # The repo-aware task base: the primary repo's task base when `repo_path`
  # matches the task's project path, else a writable/read-only foreign repo
  # entry's own `:base_sha` when its root matches.
  defp task_base_for_repo(
         repo_path,
         %{base_sha: base_sha, project_path: project_path},
         foreign_repos
       ) do
    if is_binary(project_path) and project_path == repo_path and is_binary(base_sha) do
      base_sha
    else
      foreign_base_for(repo_path, foreign_repos)
    end
  end

  defp foreign_base_for(repo_path, foreign_repos) do
    Enum.find_value(foreign_repos, fn %ForeignRepo{root: root, base_sha: base_sha} ->
      if root == repo_path, do: base_sha
    end)
  end

  # Merge-base of HEAD and the first resolvable candidate ref. `merge_base`
  # returns `{:error, ...}` for an unresolvable ref (e.g. unrelated history), so
  # the search moves on to the next candidate.
  defp merge_base_fallback(repo_path, candidate_refs) do
    candidate_refs
    |> normalize_tips()
    |> Enum.find_value(fn ref ->
      case Git.merge_base(repo_path, "HEAD", ref) do
        {:ok, sha} -> blank_to_nil(sha)
        {:error, {_, _}} -> nil
      end
    end)
  end

  ## Ref extraction

  # Walks the STRING-keyed result `"repos"` map defensively. A persisted
  # `%TaskInfo{}.result` holds the DECODED result — an `{:ok, data}` tuple for a
  # successful task (see `EvoGit.Store.Codec.decode_result/1`) whose `data` may
  # (or may not) carry a `"repos"` map. A bare map is also accepted so a
  # caller-supplied plain data map works too; result may be nil or a legacy
  # shape without `"repos"`.
  defp repo_refs({:ok, data}), do: repo_refs(data)

  defp repo_refs(result) when is_map(result) do
    case fetch_repos(result) do
      repos when is_map(repos) ->
        Enum.flat_map(repos, fn {_repo_id, entry} -> entry_refs(entry) end)

      _ ->
        []
    end
  end

  defp repo_refs(_result), do: []

  defp fetch_repos(result) do
    Map.get(result, "repos") || Map.get(result, :repos)
  end

  defp entry_refs(entry) when is_map(entry) do
    [
      Map.get(entry, "commit_sha") || Map.get(entry, :commit_sha),
      Map.get(entry, "branch_name") || Map.get(entry, :branch_name)
    ]
  end

  defp entry_refs(_entry), do: []

  # Normalizes persisted/CLI foreign-repo entries (%ForeignRepo{} structs or
  # STRING-keyed Codec round-trip maps) into structs, dropping unparseable ones.
  # Reuses the shared helper in `EvoGit.TaskRegistry.PrevTaskRepos`.
  defp normalize_foreign_repos(list) do
    PrevTaskRepos.normalize_foreign_repos(list)
  end

  ## Shared helpers

  defp normalize_tips(tips) when is_list(tips) do
    tips
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp normalize_tips(_tips), do: []

  # Coerces a value to a non-blank string or nil (blank/whitespace-only strings
  # and non-strings become nil).
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp keyword_get(opts, key) do
    if is_list(opts) and Keyword.keyword?(opts), do: Keyword.get(opts, key), else: nil
  end

  defp empty_refs, do: %{base_sha: nil, tips: [], project_path: nil}
end
