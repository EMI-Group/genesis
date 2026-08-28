defmodule EvoGit.TaskRegistry.PrevTaskRepos do
  @moduledoc """
  Defensive reading of the per-repo `repos` map embedded in a previous task's
  result, plus per-repo starting-commit application for continued tasks.

  The runtime streams a `repos` map into the task report covering `"primary"`
  and every writable foreign repo that produced commits, each entry shaped
  `%{"commit_sha" => sha, "branch_name" => branch}`. After the SQLite Codec
  JSON round trip (`EvoGit.Store.Codec`) the top-level `repos` key stays a
  STRING key (`@result_data_fields` does not include `repos`) and its entries
  are string-keyed maps — so every read here is defensive (`case`/`Map.get`
  with atom fallbacks, no try/rescue).

  Used by `EvoGit.TaskRegistry.MergeContext` and
  `EvoGit.TaskRegistry.ResumeContext` to override each carried foreign repo's
  `base_sha` with the commit the previous task produced in that repo. All
  functions are pure — no I/O, no GenServer.
  """

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo

  @doc """
  Returns the (string-keyed) `repos` map from a previous task's result, or
  `%{}` when there is none (result nil, `{:ok, non-map-data}`, missing/blank
  `repos`, or a non-map `repos` value).
  """
  @spec prev_repos_map(%TaskInfo{} | nil) :: map()
  def prev_repos_map(%TaskInfo{result: {:ok, data}}) when is_map(data) do
    case Map.get(data, "repos") || Map.get(data, :repos, %{}) do
      repos when is_map(repos) -> repos
      _ -> %{}
    end
  end

  def prev_repos_map(_), do: %{}

  @doc """
  Returns the commit sha recorded for `repo_id` in a previous task's `repos`
  map, or nil when the repo has no entry / no usable commit sha. Reads the
  entry's `"commit_sha"` (string key first, atom fallback) and only returns
  non-empty binaries.
  """
  @spec repo_commit_sha(map(), String.t()) :: String.t() | nil
  def repo_commit_sha(repos, repo_id) when is_map(repos) and is_binary(repo_id) do
    case Map.get(repos, repo_id) do
      repo_map when is_map(repo_map) ->
        case Map.get(repo_map, "commit_sha") || Map.get(repo_map, :commit_sha) do
          sha when is_binary(sha) and sha != "" -> sha
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def repo_commit_sha(_repos, _repo_id), do: nil

  @doc """
  Applies per-repo starting commits to a list of PRE-NORMALIZED `%ForeignRepo{}`
  structs: each repo's `base_sha` is overridden with the previous task's result
  `repos[repo.id]["commit_sha"]` when present, otherwise the repo is unchanged.
  A nil `prev_task` (or one without a usable `repos` map) leaves the list
  unchanged.
  """
  @spec apply_starting_commits([ForeignRepo.t()], %TaskInfo{} | nil) :: [ForeignRepo.t()]
  def apply_starting_commits(foreign_repos, %TaskInfo{} = prev_task)
      when is_list(foreign_repos) do
    repos = prev_repos_map(prev_task)

    Enum.map(foreign_repos, fn %ForeignRepo{} = repo ->
      case repo_commit_sha(repos, repo.id) do
        nil -> repo
        sha -> %{repo | base_sha: sha}
      end
    end)
  end

  def apply_starting_commits(foreign_repos, _prev_task), do: foreign_repos

  @doc """
  Formats a "Writable foreign repos: <id>@<base_sha|HEAD>, ..." line from a
  list of PRE-NORMALIZED `%ForeignRepo{}` structs, or nil when none are
  writable. Used by the merge/resume context block builders.
  """
  @spec writable_repos_line([ForeignRepo.t()]) :: String.t() | nil
  def writable_repos_line(foreign_repos) when is_list(foreign_repos) do
    case Enum.filter(foreign_repos, & &1.writable) do
      [] -> nil
      writable -> "Writable foreign repos: " <> Enum.map_join(writable, ", ", &repo_entry/1)
    end
  end

  def writable_repos_line(_), do: nil

  defp repo_entry(%ForeignRepo{id: id, base_sha: base_sha}), do: "#{id}@#{base_sha || "HEAD"}"
end
