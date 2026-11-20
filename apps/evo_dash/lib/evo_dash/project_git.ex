defmodule EvoDash.ProjectGit do
  @moduledoc "Git status and branch actions for the project on its owning node."

  alias EvoDash.NodeContext
  alias EvoGit.Adapters.Git

  @diff_flags ~w(--no-ext-diff --no-textconv --no-color)
  @max_diff_bytes 256 * 1024
  @commit_page_size 30

  def head(node, project),
    do: git(node, project, ~w(symbolic-ref --quiet --short HEAD))

  def snapshot(node, project) do
    with {:ok, root} <- repository_root(node, project),
         {:ok, status} <-
           git(node, root, ~w(--no-optional-locks status --porcelain=v2 --branch -z -uall)),
         {:ok, refs} <-
           git(node, root, [
             "for-each-ref",
             "--format=%(refname)%09%(symref)",
             "refs/heads",
             "refs/remotes"
           ]) do
      snapshot = status |> :binary.split(<<0>>, [:global]) |> parse_status(%{}, [])

      {:ok,
       Map.merge(snapshot, %{
         root: root,
         branches: parse_branches(refs),
         subject: head_subject(node, root, snapshot[:commit])
       })}
    end
  end

  def switch_branch(node, root, %{kind: :local, name: name}) do
    git(node, root, ["switch", "--no-guess", "--", name])
  end

  def switch_branch(node, root, %{kind: :remote, name: name}) do
    git(node, root, ["switch", "--track", "--", name])
  end

  def starting_commit(node, root, %{ref: ref}) do
    git(node, root, ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"])
  end

  def commits(_node, _root, nil, _offset), do: {:ok, %{rows: [], more?: false}}

  def commits(node, root, tip, offset) do
    args = [
      "log",
      "-z",
      "--format=%H%x00%h%x00%s%x00%an%x00%aI",
      "--max-count=#{@commit_page_size + 1}",
      "--skip=#{offset}",
      tip,
      "--"
    ]

    with {:ok, output} <- git(node, root, args) do
      rows =
        output
        |> :binary.split(<<0>>, [:global])
        |> Enum.chunk_every(5, 5, :discard)
        |> Enum.map(fn [sha, short, subject, author, date] ->
          %{
            sha: sha,
            short: short,
            subject: String.replace_invalid(subject),
            author: String.replace_invalid(author),
            date: date
          }
        end)

      {:ok, %{rows: Enum.take(rows, @commit_page_size), more?: length(rows) > @commit_page_size}}
    end
  end

  def commit_diff(node, root, sha) do
    with {:ok, patch} <-
           git(
             node,
             root,
             ["show", "--format=", "--diff-merges=first-parent" | @diff_flags] ++ [sha, "--"]
           ) do
      clipped_diff(patch)
    end
  end

  def diff(node, root, %{kind: kind, path: path, from: from}) do
    result =
      case kind do
        :untracked ->
          git(node, root, ["diff", "--no-index" | @diff_flags] ++ ["--", "/dev/null", path])

        _ ->
          flags = if kind == :staged, do: ["--cached" | @diff_flags], else: @diff_flags
          paths = if is_binary(from), do: [from, path], else: [path]
          git(node, root, ["--literal-pathspecs", "diff" | flags] ++ ["--" | paths])
      end

    case result do
      {:error, {:conflict, "diff --git " <> _ = patch}} when kind == :untracked ->
        clipped_diff(patch)

      {:ok, patch} ->
        clipped_diff(patch)

      error ->
        error
    end
  end

  defp clipped_diff(patch) when byte_size(patch) > @max_diff_bytes do
    {:ok, %{text: String.replace_invalid(binary_part(patch, 0, @max_diff_bytes)), clipped?: true}}
  end

  defp clipped_diff(patch), do: {:ok, %{text: String.replace_invalid(patch), clipped?: false}}

  defp head_subject(_node, _root, nil), do: nil

  defp head_subject(node, root, commit) do
    case git(node, root, ["show", "-s", "--format=%s", commit]) do
      {:ok, subject} -> String.replace_invalid(subject)
      _ -> nil
    end
  end

  defp repository_root(node, project) do
    case git(node, project, ~w(rev-parse --show-toplevel)) do
      {:error, {_, "fatal: not a git repository" <> _}} -> {:error, :not_a_repository}
      result -> result
    end
  end

  defp git(node, path, args) do
    case NodeContext.call_remote(node, Git, :run, [args, path]) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, :node_unavailable}
    end
  end

  defp parse_status([], head, files), do: Map.put(head, :changes, Enum.reverse(files))

  defp parse_status(["# branch.head " <> branch | rest], head, files) do
    branch = if branch == "(detached)", do: nil, else: branch
    parse_status(rest, Map.put(head, :branch, branch), files)
  end

  defp parse_status(["# branch.oid " <> oid | rest], head, files) do
    commit = if oid == "(initial)", do: nil, else: oid
    parse_status(rest, Map.put(head, :commit, commit), files)
  end

  defp parse_status(["# branch.upstream " <> upstream | rest], head, files),
    do: parse_status(rest, Map.put(head, :upstream, upstream), files)

  defp parse_status(["# branch.ab +" <> counts | rest], head, files) do
    [ahead, behind] = String.split(counts, " -", parts: 2)
    parse_status(rest, Map.merge(head, %{ahead: ahead, behind: behind}), files)
  end

  defp parse_status(["1 " <> _ = entry | rest], head, files) do
    [_, xy, _, _, _, _, _, _, path] = String.split(entry, " ", parts: 9)
    parse_status(rest, head, changes(xy, path, nil, files))
  end

  defp parse_status(["2 " <> _ = entry, from | rest], head, files) do
    [_, xy, _, _, _, _, _, _, _, path] = String.split(entry, " ", parts: 10)
    parse_status(rest, head, changes(xy, path, from, files))
  end

  defp parse_status(["u " <> _ = entry | rest], head, files) do
    [_, _, _, _, _, _, _, _, _, _, path] = String.split(entry, " ", parts: 11)
    parse_status(rest, head, [file(:conflicted, path, nil, "U") | files])
  end

  defp parse_status(["? " <> path | rest], head, files),
    do: parse_status(rest, head, [file(:untracked, path, nil, "?") | files])

  defp parse_status([_ | rest], head, files), do: parse_status(rest, head, files)

  defp changes(<<index, worktree>>, path, from, files) do
    files = if index == ?., do: files, else: [file(:staged, path, from, <<index>>) | files]

    if worktree == ?.,
      do: files,
      else: [file(:unstaged, path, from, <<worktree>>) | files]
  end

  defp file(kind, path, from, code), do: %{kind: kind, path: path, from: from, code: code}

  defp parse_branches(refs) do
    refs
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn ref ->
      # The adapter trims the final tab when the last ref is not symbolic.
      case String.split(ref, "\t", parts: 2) do
        ["refs/heads/" <> name | tail] when tail in [[], [""]] ->
          [%{ref: "refs/heads/" <> name, name: name, kind: :local}]

        ["refs/remotes/" <> name | tail] when tail in [[], [""]] ->
          [%{ref: "refs/remotes/" <> name, name: name, kind: :remote}]

        _ ->
          []
      end
    end)
  end
end
