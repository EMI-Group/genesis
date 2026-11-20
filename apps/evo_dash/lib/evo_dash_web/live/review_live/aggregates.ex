defmodule EvoDashWeb.ReviewLive.Aggregates do
  @moduledoc """
  Pure, total derivations over `EvoDashWeb.ReviewLive`'s `@review_repos` list.

  The review page used to recompute three of these on EVERY render — the
  aggregate diff statistics, the PRIMARY repo lookup, and the aggregate
  completion status — so a tab switch, a keystroke in the file filter or a
  debounced task broadcast paid for them again. They are derived ONCE per data
  mutation instead (`ReviewLive.LoadData` at load time, the page's own
  `put_derived/1` on every later event) and the render reads the cached
  assigns.

  Nothing here does I/O, formats text or raises: entries are plain maps
  (built by `LoadData`, or a test fixture), and a malformed entry degrades to
  contributing nothing instead of crashing a render.
  """

  # `RepoCards.repo_has_changes?/1` is the SINGLE source of the "does this repo
  # have changes?" test (also used by RepoCards' own merge-all gate).
  alias EvoDashWeb.ReviewComponents.RepoCards

  @empty_stats %{files_count: 0, additions: 0, deletions: 0, commits_count: 0}

  @doc """
  The zero value of `stats/1` (the page's pre-load default).
  """
  def empty_stats, do: @empty_stats

  @doc """
  Aggregate diff statistics across ALL review repos (primary + foreign) — the
  page header's stat row, the tab count badges, and the conversation tab's
  diff-stats bar read these SUMS (never the active repo alone, so the numbers
  stay stable while the user switches repos).

  A repo with nil `review_data` contributes only its commit count; all four
  counters default to 0 for an empty/legacy-empty repo list.
  """
  def stats(review_repos) when is_list(review_repos) do
    Enum.reduce(review_repos, @empty_stats, fn repo, acc ->
      {files_count, additions, deletions} =
        case field(repo, :review_data) do
          data when is_map(data) ->
            {count(field(data, :changed_files_count)), count(field(data, :total_additions)),
             count(field(data, :total_deletions))}

          _other ->
            {0, 0, 0}
        end

      %{
        files_count: acc.files_count + files_count,
        additions: acc.additions + additions,
        deletions: acc.deletions + deletions,
        commits_count: acc.commits_count + commits_length(field(repo, :commits))
      }
    end)
  end

  def stats(_review_repos), do: @empty_stats

  @doc """
  The `"primary"` entry of `@review_repos` (always first and present after a
  load), or nil when the list is empty/malformed.
  """
  def primary(review_repos) when is_list(review_repos) do
    Enum.find(review_repos, fn repo -> is_map(repo) and field(repo, :repo_id) == "primary" end)
  end

  def primary(_review_repos), do: nil

  @doc """
  Aggregate completion of a multi-repo review: `nil` until EVERY CHANGE-BEARING
  repo's resolution is TERMINAL, otherwise the effective review status.

  A no-change repo (nil/blank branch) needs no action, so it never blocks
  completion nor counts toward the aggregate — merging/rejecting all the
  change-bearing repos still completes the review. A task with NO changes in
  ANY repo is NEVER reported as `:rejected` (dismissed via "Mark as read"
  instead) → `nil`. Prefers the already-persisted `review_status` when it is
  `:merged`/`:rejected` (reload coherence), else `:merged` if ANY repo merged,
  else `:rejected`. An empty repo list never completes.
  """
  def completion_status([], _review_status), do: nil

  def completion_status(review_repos, review_status) when is_list(review_repos) do
    actionable = Enum.filter(review_repos, &RepoCards.repo_has_changes?/1)

    cond do
      actionable == [] ->
        nil

      Enum.all?(actionable, &terminal_resolution?(field(&1, :resolution))) ->
        cond do
          review_status in [:merged, :rejected] ->
            review_status

          Enum.any?(actionable, &match?(%{state: :merged}, field(&1, :resolution))) ->
            :merged

          true ->
            :rejected
        end

      true ->
        nil
    end
  end

  def completion_status(_review_repos, _review_status), do: nil

  @doc """
  A repo entry's `:resolution` is TERMINAL once its branch has been merged,
  rejected, or is already gone (`:handled`, seeded at load when a branch that
  once existed no longer does).

  Terminal repos offer no further actions and count toward review completion.
  NON-terminal values (`nil`, `:error`, `:conflict`) stay actionable/retryable.
  """
  def terminal_resolution?(%{state: state}) when state in [:merged, :rejected, :handled],
    do: true

  def terminal_resolution?(_), do: false

  # Key-tolerant field read: a map/struct entry answers its value, anything
  # else (a bare atom, a nil, garbage) answers nil — never raising.
  defp field(entry, key) when is_map(entry), do: Map.get(entry, key)
  defp field(_entry, _key), do: nil

  defp count(value) when is_number(value), do: value
  defp count(_value), do: 0

  defp commits_length(commits) when is_list(commits), do: length(commits)
  defp commits_length(_commits), do: 0
end
