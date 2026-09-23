defmodule EvoGit.CommitGraph do
  @moduledoc """
  Read-only commit-graph data API for the dashboard's temporal (git commit
  history) visualization.

  `for_ranges/3` collects the commits belonging to a set of git ranges in one
  `git log` call per range, deduplicates them by full SHA, and pairs them with
  the branch/tag ref labels pointing at those commits.

  `for_task/4` is the TASK-SCOPED variant: given one task-wide `base_sha` and a
  list of tip refs (durable task refs + live agent tips), it draws the whole
  task from its base commit through every tip — INCLUDING the base commit
  itself (which `git log base..tip` deliberately excludes).

  Every git operation goes through `EvoGit.Adapters.Git`. Both functions are
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
    commits = collect_commits(repo_path, ranges, limit)

    {:ok, %{commits: commits, refs: refs_for(repo_path, commits)}}
  end

  @doc """
  Returns the task-scoped commit graph for `repo_path`.

  `base_sha` is the task's base commit/ref (a SHA or branch name) or `nil`/blank
  when the base is unknown; `tips` is a list of tip SHA/ref strings (a task's
  durable refs plus its live agents' tips). Non-binary and blank tips are
  dropped and duplicates are collapsed, so callers may pass lists that contain
  `nil`s.

  One `git log <base>..<tip>` runs per tip (each capped at `opts[:limit]`
  commits, default #{@default_limit}), the unions are deduplicated by full SHA,
  and the BASE COMMIT is then appended as its own node via a single
  `git log -n 1 <base_sha>` — so the base is present in `commits` even though
  `git log base..tip` excludes it. The base keeps its REAL `:parents`; its own
  ANCESTORS are NOT fetched, so a parent SHA absent from `commits` marks the
  graph boundary (the same convention as `for_ranges/3`, which can return merge
  parents lying outside a range).

  `opts` is a keyword list; it supports `:limit` (max commits kept per range).

  Returns the SAME shape as `for_ranges/3`:
  `{:ok, %{commits: [commit], refs: %{sha => [ref_name]}}}` (commits newest-first
  with the base appended last). `refs` is computed over the full union, so the
  base node also carries its branch/tag labels. A `nil`/blank `base_sha` — the
  base is genuinely unknown — yields `{:ok, %{commits: [], refs: %{}}}`.
  """
  @spec for_task(String.t(), String.t() | nil, [String.t() | nil], keyword()) :: {:ok, map()}
  def for_task(repo_path, base_sha, tips, opts \\ []) do
    base = normalize_ref(base_sha)

    if is_nil(base) do
      {:ok, %{commits: [], refs: %{}}}
    else
      limit = resolve_limit(opts)
      ranges = Enum.map(normalize_tips(tips), fn tip -> {base, tip} end)

      commits =
        collect_commits(repo_path, ranges, limit)
        |> Kernel.++(base_commit_for(repo_path, base))
        |> Enum.uniq_by(& &1.sha)

      {:ok, %{commits: commits, refs: refs_for(repo_path, commits)}}
    end
  end

  # Shared per-range collection + dedupe used by BOTH `for_ranges/3` and
  # `for_task/4`: normalize the ranges, run one `git log <base>..<tip>` each,
  # and keep the first occurrence of every full SHA (git log order).
  defp collect_commits(repo_path, ranges, limit) do
    ranges
    |> normalize_ranges()
    |> Enum.flat_map(&commits_for_range(repo_path, &1, limit))
    |> Enum.uniq_by(& &1.sha)
  end

  # Fetches the base commit itself as a single-node log (the same pretty format
  # + parser), so it appears in the graph even though `git log base..tip`
  # excludes it. A bad ref yields no node (never raises).
  defp base_commit_for(repo_path, base) do
    args = ["--format=#{@commit_format}", "-n", "1", base]

    case Git.log(repo_path, args) do
      {:ok, output} -> output |> parse_log_output() |> Enum.take(1)
      {:error, {_, _}} -> []
    end
  end

  # Normalizes a single ref to a non-blank string or nil.
  defp normalize_ref(ref) when is_binary(ref) do
    case String.trim(ref) do
      "" -> nil
      _ -> ref
    end
  end

  defp normalize_ref(_), do: nil

  # Drops non-binary/blank tips and collapses duplicates, preserving order.
  defp normalize_tips(tips) when is_list(tips) do
    tips
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp normalize_tips(_), do: []
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
