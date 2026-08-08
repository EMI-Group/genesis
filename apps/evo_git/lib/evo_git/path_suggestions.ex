defmodule EvoGit.PathSuggestions do
  @moduledoc """
  Pure, platform-aware filesystem path suggestion helper.

  Given the user's typed path, returns matching absolute path suggestions
  (directories first, then files, case-insensitive prefix match). Used both
  locally and on remote nodes via `:erpc` — so it must stay side-effect free
  except `File.ls/1` and `File.dir?/1`, and must resolve paths on the node
  where it runs (`Path.expand/1` on the node running the code — correct for
  remote daemons).

  Ported from `EvoDashWeb.DashboardLive.Project.filesystem_suggestions/1` so
  the dashboard's path autocomplete can run on a remote `genesis_remote`
  daemon (which runs `:evo_git` only).
  """

  @max_suggestions 15

  @doc """
  Returns up to `#{@max_suggestions}` absolute path suggestions for `value`.

  Semantics:

    * `nil` or `""` → `[]`.
    * Value ending with `/` or `\\` → list the directory itself (prefix `""`).
    * Value containing `/` or `\\` → list `Path.dirname/1` of the expanded
      path, filtering by `Path.basename/1` (case-insensitive prefix).
    * Otherwise → list `File.cwd!()`, filtering by the expanded value.
    * Entries are sorted directories-first, then case-insensitively by name.
    * `File.ls/1` failure (e.g. non-existent directory) → `[]`.
  """
  @spec suggest(String.t() | nil) :: [String.t()]
  def suggest(value) when is_nil(value) or value == "", do: []

  def suggest(value) when is_binary(value) do
    expanded = Path.expand(value)
    {dir, prefix} = split_dir_prefix(expanded, value)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&prefix_match?(&1, prefix))
        |> Enum.sort_by(fn entry ->
          {not File.dir?(Path.join(dir, entry)), String.downcase(entry)}
        end)
        |> Enum.take(@max_suggestions)
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  # Splits the expanded path into `{dir, prefix}` for the File.ls listing:
  # value ending with a separator → list the directory itself; embedded
  # separator → list the parent dir filtered by the basename; no separator →
  # list cwd filtered by the whole expanded value. The trailing-separator
  # check runs on the RAW value because `Path.expand/1` strips trailing
  # separators (`Path.expand("/tmp/foo/") == "/tmp/foo"`).
  defp split_dir_prefix(expanded, value) do
    cond do
      String.ends_with?(value, "/") or String.ends_with?(value, "\\") ->
        {expanded, ""}

      String.contains?(expanded, "/") or String.contains?(expanded, "\\") ->
        {Path.dirname(expanded), Path.basename(expanded)}

      true ->
        {File.cwd!(), expanded}
    end
  end

  defp prefix_match?(_entry, prefix) when prefix == "", do: true

  defp prefix_match?(entry, prefix) do
    String.starts_with?(String.downcase(entry), String.downcase(prefix))
  end
end
