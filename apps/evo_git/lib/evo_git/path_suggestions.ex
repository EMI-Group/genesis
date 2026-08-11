defmodule EvoGit.PathSuggestions do
  @moduledoc """
  Pure, platform-aware filesystem path suggestion helper.

  Given the user's typed path, returns matching absolute path suggestions
  (directories first, then files, case-insensitive prefix match). Used both
  locally and on remote nodes via `:erpc` — so it must stay side-effect free
  except `File.ls/1` and `File.dir?/1`, and must resolve paths on the node
  where it runs (`Path.expand/1` on the node running the code — correct for
  remote daemons).

  Relative input (bare names like `Test`, volume-relative `D:Test`,
  root-relative `\\Test`) is deliberately rejected with `[]` — it is never
  expanded against `File.cwd!()`, which would anchor suggestions to the
  BEAM's launch directory (e.g. the desktop app's install dir) instead of
  the project the user actually means. Only tilde (`~`) and platform-absolute
  input produce suggestions; callers must resolve relative input against the
  intended project root themselves.

  Ported from `EvoDashWeb.ProjectsLive.Project.filesystem_suggestions/1` so
  the dashboard's path autocomplete can run on a remote `genesis_remote`
  daemon (which runs `:evo_git` only).
  """

  @max_suggestions 15

  @doc """
  Returns up to `#{@max_suggestions}` absolute path suggestions for `value`.

  Semantics:

    * `nil`, `""`, or whitespace-only input → `[]`.
    * Input starting with `~` (i.e. `~`, `~/...`, `~\\...`) → expanded via
      `Path.expand/1` (tilde expansion is cwd-independent); `~` alone lists
      the home directory itself.
    * Platform-absolute input (Unix `/foo`, Windows `C:\\foo`, `C:/foo`,
      `D:/bar`, UNC `\\\\server\\share`) → suggestions computed from that
      base.
    * Any other input (bare names like `Test`, relative paths like
      `foo/bar`, volume-relative `D:Test`, root-relative `\\Test`,
      tilde-username forms like `~bob`) → `[]`. Relative input is NEVER
      expanded against `File.cwd!()` — callers must resolve it against the
      intended project root.
    * Value ending with `/` or `\\` → list the directory itself (prefix `""`).
    * Value containing `/` or `\\` → list `Path.dirname/1` of the expanded
      path, filtering by `Path.basename/1` (case-insensitive prefix).
    * Entries are sorted directories-first, then case-insensitively by name.
    * `File.ls/1` failure (e.g. non-existent directory) → `[]`.
  """
  @spec suggest(String.t() | nil) :: [String.t()]
  def suggest(value) when is_nil(value) or value == "", do: []

  def suggest(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        []

      String.starts_with?(trimmed, "~") and tilde_path?(trimmed) ->
        {expanded, raw} = expand_tilde(trimmed)
        list_suggestions(expanded, raw)

      EvoGit.Platform.absolute_path?(trimmed) ->
        list_suggestions(expand_absolute(trimmed), trimmed)

      true ->
        []
    end
  end

  defp list_suggestions(expanded, raw) do
    {dir, prefix} = split_dir_prefix(expanded, raw)

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

  # Only `~`, `~/...`, and `~\\...` are tilde paths. Bare `~name` (e.g.
  # `~bob`) is NOT cwd-independent — `Path.expand/1` treats it as a
  # cwd-relative name on non-Windows hosts — so it is rejected like any
  # other relative input.
  defp tilde_path?("~" <> rest) do
    rest == "" or String.starts_with?(rest, "/") or String.starts_with?(rest, "\\")
  end

  defp tilde_path?(_other), do: false

  # Expands a well-formed tilde path. `~` alone (or followed only by a
  # separator, i.e. `~/` or `~\\`) lists the home directory itself; the raw
  # value passed on is forced to end with a separator so
  # `split_dir_prefix/2` takes its "list the directory itself" branch.
  defp expand_tilde(trimmed) do
    if trimmed == "~" or trimmed == "~/" or trimmed == "~\\" do
      {Path.expand("~"), "~/"}
    else
      {Path.expand(trimmed), trimmed}
    end
  end

  # Cwd-independent expansion for platform-absolute input. `Path.expand/1`
  # is only applied to native absolute paths (`Path.type/1 == :absolute`) —
  # it normalizes `..` and strips trailing separators. Windows-style paths
  # on non-Windows hosts (where `Path.type/1` returns `:relative`, e.g.
  # `D:\\Pro` on Linux) are used as-is, only stripped of trailing separators
  # so the `File.ls/1` base is clean.
  defp expand_absolute(trimmed) do
    if Path.type(trimmed) == :absolute do
      Path.expand(trimmed)
    else
      # Windows-style path on a non-Windows host: use as-is, only stripping
      # trailing separators so the `File.ls/1` base is clean.
      case String.replace(trimmed, ~r/[\/\\]+$/, "") do
        "" -> trimmed
        stripped -> stripped
      end
    end
  end

  # Splits the expanded path into `{dir, prefix}` for the File.ls listing:
  # value ending with a separator → list the directory itself; otherwise →
  # list the parent dir filtered by the basename. The trailing-separator
  # check runs on the RAW value because `Path.expand/1` strips trailing
  # separators (`Path.expand("/tmp/foo/") == "/tmp/foo"`). Callers guarantee
  # `expanded` is home-anchored or absolute, so there is no cwd fallback —
  # relative input never reaches this point.
  defp split_dir_prefix(expanded, value) do
    if String.ends_with?(value, "/") or String.ends_with?(value, "\\") do
      {expanded, ""}
    else
      {Path.dirname(expanded), Path.basename(expanded)}
    end
  end

  defp prefix_match?(_entry, prefix) when prefix == "", do: true

  defp prefix_match?(entry, prefix) do
    String.starts_with?(String.downcase(entry), String.downcase(prefix))
  end
end
