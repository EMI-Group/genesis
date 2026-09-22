defmodule EvoGit.CommitGraph do
  @moduledoc """
  Read-only commit-graph data API for the dashboard's temporal (git commit
  history) visualization.

  `for_ranges/3` collects the commits belonging to a set of git ranges in one
  `git log` call per range, deduplicates them by full SHA, and pairs them with
  the branch/tag ref labels pointing at those commits.

  Every git operation goes through `EvoGit.Adapters.Git`. The function is
  TOTAL: unresolvable ranges, invalid refs, and non-git directories contribute
  nothing and never raise (git/parse failures degrade to empty results, the
  same normalize-to-empty convention as `EvoGit.Review.list_commits/2`).
  """

  alias EvoGit.Adapters.Git

  # Record separator and pretty format shared by every `git log` invocation.
  # `%P` (parent SHAs, space-separated; empty for a root commit) is captured so
  # the caller can draw the commit graph; `%s` is the subject line only.
  @commit_separator "|||COMMIT_GRAPH_SEP|||"
  @commit_format "%H%n%h%n%s%n%an%n%ae%n%aI%n%P%n#{@commit_separator}"

  @default_limit 100

  @doc """
  Returns the commits belonging to `ranges` plus the refs pointing at them.

  `ranges` is a list of `{base_ref, tip_ref}` 2-tuples of SHA or branch-name
  strings; one `git log <base>..<tip>` runs in `repo_path` per range, capped at
  `opts[:limit]` commits (default #{@default_limit}). Commits are deduplicated
  by full SHA across ranges and kept in git log order (newest-first).

  `opts` is a keyword list; it supports `:limit` (max commits kept per range).

  Returns `{:ok, %{commits: [commit], refs: %{sha => [ref_name]}}}`, where each
  `commit` is an atom-keyed map with EXACTLY `:sha`, `:short_sha`, `:message`,
  `:author_name`, `:author_email`, `:date` (a `%DateTime{}` parsed from the
  ISO-8601 value, or `nil` when unparsable) and `:parents` (a list of full SHA
  strings, `[]` for a root commit). `refs` maps each returned commit SHA to the
  short names of the local branches/tags pointing at it (an empty map if the
  ref listing fails).
  """
  @spec for_ranges(String.t(), [{String.t(), String.t()}], keyword()) :: {:ok, map()}
  def for_ranges(repo_path, ranges, opts) do
    limit = resolve_limit(opts)

    commits =
      ranges
      |> normalize_ranges()
      |> Enum.flat_map(&commits_for_range(repo_path, &1, limit))
      |> Enum.uniq_by(& &1.sha)

    {:ok, %{commits: commits, refs: refs_for(repo_path, commits)}}
  end

  # Accepts only well-formed 2-tuples of non-blank strings; anything else is
  # dropped so a malformed range contributes no commits instead of raising.
  defp normalize_ranges(ranges) when is_list(ranges) do
    Enum.flat_map(ranges, fn
      {base, tip} when is_binary(base) and is_binary(tip) ->
        if String.trim(base) == "" or String.trim(tip) == "" do
          []
        else
          [{base, tip}]
        end

      _ ->
        []
    end)
  end

  defp normalize_ranges(_), do: []

  defp resolve_limit(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      case Keyword.get(opts, :limit, @default_limit) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_limit
      end
    else
      @default_limit
    end
  end

  # One `git log <base>..<tip>` per range. A bad ref (exit != 0) or a
  # non-existent path normalizes to an empty commit list.
  defp commits_for_range(repo_path, {base, tip}, limit) do
    args = ["--format=#{@commit_format}", "-n", Integer.to_string(limit), "#{base}..#{tip}"]

    case Git.log(repo_path, args) do
      {:ok, output} -> parse_log_output(output)
      {:error, {_, _}} -> []
    end
  end

  defp parse_log_output(output) when is_binary(output) do
    output
    |> String.split(@commit_separator)
    |> Enum.map(&parse_commit_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_log_output(_), do: []

  defp parse_commit_entry(entry) when is_binary(entry) do
    case String.split(String.trim(entry), "\n") do
      [sha, short_sha, message, author_name, author_email, date | rest] ->
        %{
          sha: sha,
          short_sha: short_sha,
          message: message,
          author_name: author_name,
          author_email: author_email,
          date: parse_iso_date(date),
          parents: parse_parents(rest)
        }

      _ ->
        nil
    end
  end

  defp parse_commit_entry(_), do: nil

  # `%P` is a space-separated line of full parent SHAs, absent for a root
  # commit (and trimmed away by the entry trim), hence the join over `rest`.
  defp parse_parents(rest) do
    rest
    |> Enum.join(" ")
    |> String.split(" ", trim: true)
  end

  defp parse_iso_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_iso_date(_), do: nil

  # Maps each returned commit SHA to the short names of the branches/tags
  # pointing at it. Restricted to SHAs actually present in the returned commits;
  # a failed ref listing yields an empty map.
  defp refs_for(repo_path, commits) do
    shas = MapSet.new(commits, & &1.sha)

    case Git.list_refs(repo_path) do
      {:ok, refs} ->
        refs
        |> Enum.reduce(%{}, fn {name, sha}, acc ->
          if MapSet.member?(shas, sha) do
            Map.update(acc, sha, [name], &[name | &1])
          else
            acc
          end
        end)
        |> Map.new(fn {sha, names} -> {sha, Enum.reverse(names)} end)

      {:error, _} ->
        %{}
    end
  end
end
