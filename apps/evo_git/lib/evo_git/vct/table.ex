defmodule EvoGit.VCT.Table do
  @moduledoc """
  Table operations for the Virtual Context Tree (VCT) mount list.

  The GenServer in `EvoGit.VCT` owns I/O (persistence, broadcasting, the global
  context file and its git history); the rules that operate on a mount LIST live
  here so they can be reasoned about — and tested — without a process, a data
  directory or a JSON file. A mount is pure metadata: none of these functions
  ever creates, moves or requires a directory (see `EvoGit.VCT.Mount`).

  Mount identity rules:

    * an OS path is normalized (trimmed, trailing separators removed) and
      compared separator-insensitively, so Windows `\\` paths and POSIX `/` paths
      both work;
    * registering an already-mounted OS path is idempotent and keeps the existing
      VCT point (a point never churns under a stable path);
    * registering a NEW OS path whose display name and basename match a mount
      whose recorded OS path no longer EXISTS re-points that mount instead of
      accumulating a second point (portability across machines) — this is the
      only place a filesystem probe happens;
    * every other registration gets a deduplicated
      `vct:///projects/<basename>[-N]` point.

  Points are unique within a table; `unique_point/2` enforces that.

  ## Project mounts vs reserved (system) mounts

  A point is a PROJECT mount exactly when it carries at least two segments and
  the first one is `"projects"` (`vct:///projects/<name>` and anything nested
  below it). Everything else — `vct:///`, `vct:///projects` (no name), and any
  other top-level namespace such as `vct:///genesis-source` — is a RESERVED
  (system) mount: it is not part of the user's project list, it is never
  forgotten through `EvoGit.VCT.forget/1`, and `enforce_cap/2` never evicts it.
  """

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath

  @projects_prefix VctPath.projects()

  ## Path normalization

  @doc """
  Normalizes an absolute OS path for mount identity.

  Trims surrounding whitespace and trailing separators. A root path stays a
  root (`"/"`, `"C:\\"`), so two spellings of the same directory compare equal.
  The path itself is otherwise kept as given (no symlink resolution, no
  `Path.expand/1`) — a mount's OS path need not exist.
  """
  @spec normalize_os_path(String.t()) :: String.t()
  def normalize_os_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> trim_trailing_separators()
    |> restore_root()
  end

  defp trim_trailing_separators(path) do
    trimmed = path |> String.trim_trailing("/") |> String.trim_trailing("\\")
    if trimmed == path, do: path, else: trim_trailing_separators(trimmed)
  end

  defp restore_root(""), do: "/"

  defp restore_root(<<letter, ?:>>) when letter in ?a..?z or letter in ?A..?Z,
    do: <<letter, ?:>> <> "\\"

  defp restore_root(path), do: path

  @doc """
  Returns the separator-normalized comparison form of a path.

  Backslashes become `/`, repeated separators collapse and a trailing separator
  is dropped, so `/a/b/` and `/a/b` (and `C:\\a\\b` vs `C:/a/b`) compare equal.
  Used for identity and prefix matching only — never for display or I/O.
  """
  @spec comparison_form(String.t()) :: String.t()
  def comparison_form(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.replace(~r{/+}, "/")
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      form -> form
    end
  end

  @doc """
  Returns the display basename of an OS path (both separator styles).
  """
  @spec path_basename(String.t()) :: String.t()
  def path_basename(path) when is_binary(path),
    do: path |> comparison_form() |> Path.basename()

  @doc """
  Returns the display name for an OS path: its basename, or `"root"`/`"project"`
  for the degenerate roots.
  """
  @spec display_name(String.t()) :: String.t()
  def display_name(path) when is_binary(path) do
    case path_basename(path) do
      "" -> "project"
      "/" -> "root"
      name -> name
    end
  end

  @doc """
  Normalizes a user-supplied display name: blank (or non-binary) becomes `nil`.
  """
  @spec normalize_name(term()) :: String.t() | nil
  def normalize_name(name) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: String.trim(name)
  end

  def normalize_name(_name), do: nil

  ## Reserved (system) vs project mounts

  @doc """
  Returns `true` when `point` is a PROJECT mount point.

  A project mount sits in the `projects` namespace with a name:
  `vct:///projects/<name>` (and anything nested below it). Accepts a canonical
  point string or an `EvoGit.VCT.Path`; TOTAL — an unparseable or non-path
  input is not a project mount (`false`).
  """
  @spec project_mount?(VctPath.t() | String.t() | term()) :: boolean()
  def project_mount?(point) do
    case point_segments(point) do
      {:ok, ["projects", _name | _rest]} -> true
      _other -> false
    end
  end

  @doc """
  Returns `true` when `point` is RESERVED — a system mount outside
  `vct:///projects/<name>` (`vct:///`, `vct:///projects`, `vct:///<namespace>`).

  Reserved mounts are never listed as projects, never forgotten and never
  evicted by the cap. TOTAL: an unparseable or non-path input is NOT reserved
  (`false`), so a caller can distinguish "reserved" from "not a point at all".
  """
  @spec reserved?(VctPath.t() | String.t() | term()) :: boolean()
  def reserved?(point) do
    case point_segments(point) do
      {:ok, segments} -> not project_segments?(segments)
      :error -> false
    end
  end

  @doc """
  Keeps only the PROJECT mounts of a mount list, preserving order.
  """
  @spec project_mounts([Mount.t()]) :: [Mount.t()]
  def project_mounts(mounts) when is_list(mounts), do: Enum.filter(mounts, &project_entry?/1)
  def project_mounts(_mounts), do: []

  defp project_entry?(%Mount{point: point}), do: project_mount?(point)
  defp project_entry?(_mount), do: false

  defp project_segments?(["projects", _name | _rest]), do: true
  defp project_segments?(_segments), do: false

  defp point_segments(%VctPath{segments: segments}) when is_list(segments), do: {:ok, segments}

  defp point_segments(point) when is_binary(point) do
    case VctPath.parse(point) do
      {:ok, parsed} -> {:ok, parsed.segments}
      {:error, _reason} -> :error
    end
  end

  defp point_segments(_point), do: :error

  ## Queries

  @doc """
  Finds a mount by its canonical VCT point.
  """
  @spec find_by_point([Mount.t()], String.t()) :: Mount.t() | nil
  def find_by_point(mounts, point) when is_list(mounts) and is_binary(point),
    do: Enum.find(mounts, &(&1.point == point))

  def find_by_point(_mounts, _point), do: nil

  @doc """
  Finds a mount by OS path (normalized, separator-insensitive).
  """
  @spec find_by_os_path([Mount.t()], String.t()) :: Mount.t() | nil
  def find_by_os_path(mounts, os_path) when is_list(mounts) and is_binary(os_path) do
    target = comparison_form(normalize_os_path(os_path))
    Enum.find(mounts, &(comparison_form(&1.path) == target))
  end

  def find_by_os_path(_mounts, _os_path), do: nil

  @doc """
  Returns the mount containing `os_path` — the LONGEST matching OS-path prefix.

  Matching respects a path boundary (`/a/b` matches `/a/b/c` but not `/a/bc`)
  and compares separator-insensitively, so Windows paths work. `nil` when no
  mount contains the path.
  """
  @spec mount_for_path([Mount.t()], String.t() | nil) :: Mount.t() | nil
  def mount_for_path(mounts, os_path) when is_list(mounts) and is_binary(os_path) do
    target = comparison_form(normalize_os_path(os_path))

    mounts
    |> Enum.filter(&prefix?(comparison_form(&1.path), target))
    |> Enum.max_by(&byte_size(comparison_form(&1.path)), fn -> nil end)
  end

  def mount_for_path(_mounts, _os_path), do: nil

  defp prefix?(prefix, target) do
    cond do
      prefix == "/" -> String.starts_with?(target, "/")
      target == prefix -> true
      true -> String.starts_with?(target, prefix <> "/")
    end
  end

  @doc """
  Sorts mounts by `last_opened_at` DESC, with `nil` timestamps LAST.
  """
  @spec sort_by_recency([Mount.t()]) :: [Mount.t()]
  def sort_by_recency(mounts) when is_list(mounts) do
    Enum.sort(mounts, fn
      %Mount{last_opened_at: nil}, %Mount{last_opened_at: nil} -> true
      %Mount{last_opened_at: nil}, _other -> false
      _other, %Mount{last_opened_at: nil} -> true
      a, b -> DateTime.compare(a.last_opened_at, b.last_opened_at) in [:gt, :eq]
    end)
  end

  @doc """
  Caps the PROJECT mounts at `cap` entries by EVICTING the oldest ones.

  RESERVED (system) mounts are always retained, and they do not count against
  the cap. A `nil` `last_opened_at` counts as the oldest, and the sort is stable
  over the incoming list — which is the store's order (newest first, ties by
  point ascending) — so the outcome is deterministic. Surviving mounts keep
  their original list positions, so membership (not just count) is preserved.
  A non-positive or non-integer `cap` leaves the list untouched.
  """
  @spec enforce_cap([Mount.t()], term()) :: [Mount.t()]
  def enforce_cap(mounts, cap) when is_list(mounts) and is_integer(cap) and cap > 0 do
    project_count = mounts |> project_mounts() |> length()

    if project_count <= cap do
      mounts
    else
      kept_points =
        mounts
        |> project_mounts()
        |> sort_by_recency()
        |> Enum.take(cap)
        |> MapSet.new(& &1.point)

      Enum.filter(mounts, fn mount ->
        not project_entry?(mount) or MapSet.member?(kept_points, mount.point)
      end)
    end
  end

  def enforce_cap(mounts, _cap), do: mounts

  ## Mutations

  @doc """
  Registers an OS path in the mount table.

  Returns `{:ok, mounts, mount}` — the updated list and the created/updated
  mount. The rules, in order:

    1. the same normalized OS path already mounted → refresh `last_opened_at`,
       update `name` only when a non-blank name is supplied, KEEP the point;
    2. a mount with the same display name and point basename whose recorded OS
       path no longer exists → RE-POINT it (replace path/timestamp, keep the
       point stable);
    3. otherwise create a new mount at a deduplicated
       `vct:///projects/<basename>[-N]` point.
  """
  @spec register([Mount.t()], String.t(), String.t() | nil, DateTime.t() | nil) ::
          {:ok, [Mount.t()], Mount.t()}
  def register(mounts, os_path, name, now \\ nil)
      when is_list(mounts) and is_binary(os_path) do
    now = now || DateTime.utc_now()
    normalized = normalize_os_path(os_path)
    name = normalize_name(name)

    case find_by_os_path(mounts, normalized) do
      %Mount{} = existing ->
        updated = %{
          existing
          | path: normalized,
            name: name || existing.name,
            last_opened_at: now
        }

        {:ok, replace(mounts, existing, updated), updated}

      nil ->
        derived = name || display_name(normalized)
        base = path_basename(normalized)

        case repoint_candidate(mounts, derived, base) do
          %Mount{} = target ->
            updated = %{target | path: normalized, name: derived, last_opened_at: now}
            {:ok, replace(mounts, target, updated), updated}

          nil ->
            point = unique_point(mounts, point_for_basename(base))
            mount = Mount.new(point, normalized, name: derived, last_opened_at: now)
            {:ok, mounts ++ [mount], mount}
        end
    end
  end

  # A mount is re-pointable when it describes the same logical project (same
  # display name AND same point basename) but its recorded OS path is gone —
  # e.g. a mount table written on another machine. Never requires the NEW path
  # to exist.
  defp repoint_candidate(mounts, derived, base) do
    Enum.find(mounts, fn mount ->
      mount.name == derived and
        VctPath.name(mount.point) == base and
        not File.exists?(mount.path)
    end)
  end

  @doc """
  Ensures `os_path` is mounted at exactly `point` — the POINT-first rule used by
  reserved (system) mounts.

  PURE: no clock, no filesystem probe, no I/O. `last_opened_at` is never
  refreshed here (only `register/4` does that for a user "open"), so a repeated
  ensure never churns a timestamp. Returns
  `{:ok, mounts, mount, changed?}` — or `{:error, reason}` for an unparseable
  point (`:invalid_point`) or a blank/non-binary OS path (`:invalid_path`).

  The rules, in order:

    1. `point` already holds the SAME normalized OS path → the existing mount,
       unchanged (`changed? = false`): no rename, no timestamp churn;
    2. `point` already holds a DIFFERENT path → RE-POINT it (new path, the
       supplied name only when non-blank, point and `last_opened_at` kept); a
       row mounting that same path at another point is removed, so an OS path
       never has two rows;
    3. no row at `point`, but the OS path is mounted at another point → MOVE
       that row to `point` (path, name and `last_opened_at` preserved, the
       supplied name winning when non-blank);
    4. otherwise INSERT a new mount at `point` with `last_opened_at: nil`
       (a system mount is not "opened", so it sorts last among projects).

  Points stay unique: a row at `point` is never duplicated.
  """
  @spec ensure_mount([Mount.t()], VctPath.t() | String.t(), String.t(), String.t() | nil) ::
          {:ok, [Mount.t()], Mount.t(), boolean()} | {:error, term()}
  def ensure_mount(mounts, point, os_path, name) when is_list(mounts) do
    with {:ok, canonical} <- canonical_point(point),
         {:ok, normalized} <- ensure_os_path(os_path) do
      name = normalize_name(name)
      do_ensure_mount(mounts, canonical, normalized, name)
    end
  end

  def ensure_mount(_mounts, _point, _os_path, _name), do: {:error, :invalid_mounts}

  defp do_ensure_mount(mounts, point, normalized, name) do
    case find_by_point(mounts, point) do
      %Mount{} = existing ->
        if comparison_form(existing.path) == comparison_form(normalized) do
          {:ok, mounts, existing, false}
        else
          updated = %{existing | path: normalized, name: name || existing.name}

          mounts =
            mounts
            |> drop_other_path_row(normalized, point)
            |> replace(existing, updated)

          {:ok, mounts, updated, true}
        end

      nil ->
        case find_by_os_path(mounts, normalized) do
          %Mount{} = existing ->
            moved = %{existing | point: point, path: normalized, name: name || existing.name}
            {:ok, replace(mounts, existing, moved), moved, true}

          nil ->
            mount =
              Mount.new(point, normalized,
                name: name || display_name(normalized),
                last_opened_at: nil
              )

            {:ok, mounts ++ [mount], mount, true}
        end
    end
  end

  # One OS path, one row: a re-point must not leave the previous owner behind.
  defp drop_other_path_row(mounts, normalized, point) do
    case find_by_os_path(mounts, normalized) do
      %Mount{point: ^point} -> mounts
      %Mount{} = other -> List.delete(mounts, other)
      nil -> mounts
    end
  end

  defp canonical_point(%VctPath{segments: segments}) do
    if Enum.all?(segments, &is_binary/1),
      do: {:ok, VctPath.format(segments)},
      else: {:error, :invalid_point}
  end

  defp canonical_point(point) when is_binary(point) do
    case VctPath.parse(point) do
      {:ok, parsed} -> {:ok, VctPath.format(parsed)}
      {:error, _reason} -> {:error, :invalid_point}
    end
  end

  defp canonical_point(_point), do: {:error, :invalid_point}

  defp ensure_os_path(path) when is_binary(path) do
    if String.trim(path) == "", do: {:error, :invalid_path}, else: {:ok, normalize_os_path(path)}
  end

  defp ensure_os_path(_path), do: {:error, :invalid_path}

  defp replace(mounts, old, new) do
    Enum.map(mounts, fn mount -> if mount.point == old.point, do: new, else: mount end)
  end

  @doc """
  Removes the mount at `point`. Returns `{:ok, mounts, removed_mount}` or
  `{:error, :not_found}`.
  """
  @spec remove_by_point([Mount.t()], String.t()) ::
          {:ok, [Mount.t()], Mount.t()} | {:error, :not_found}
  def remove_by_point(mounts, point) when is_list(mounts) and is_binary(point) do
    case find_by_point(mounts, point) do
      nil -> {:error, :not_found}
      mount -> {:ok, List.delete(mounts, mount), mount}
    end
  end

  def remove_by_point(_mounts, _point), do: {:error, :not_found}

  @doc """
  Removes the mount whose OS path is `os_path`. Returns `{:ok, mounts, mount}`
  or `{:error, :not_found}`.
  """
  @spec remove_by_path([Mount.t()], String.t()) ::
          {:ok, [Mount.t()], Mount.t()} | {:error, :not_found}
  def remove_by_path(mounts, os_path) when is_list(mounts) and is_binary(os_path) do
    case find_by_os_path(mounts, os_path) do
      nil -> {:error, :not_found}
      mount -> {:ok, List.delete(mounts, mount), mount}
    end
  end

  def remove_by_path(_mounts, _os_path), do: {:error, :not_found}

  ## VCT path derivation

  @doc """
  Returns the canonical VCT URL for `relative_path` inside the mount's OS path.

  `"./"`, `""` and `"."`-free relative paths map onto the mount point itself;
  `"./src/auth"` and `"src/auth"` map onto `<point>/src/auth`. Returns `nil` for
  an absolute path, a `".."`/`"."` segment, a control-character segment or a
  non-binary input.
  """
  @spec vct_path_for(Mount.t(), term()) :: String.t() | nil
  def vct_path_for(%Mount{point: point}, relative) when is_binary(relative) do
    with {:ok, parsed} <- VctPath.parse(point),
         {:ok, segments} <- relative_segments(relative) do
      safe_format(VctPath.join(parsed, segments))
    else
      _reason -> nil
    end
  end

  def vct_path_for(_mount, _relative), do: nil

  defp relative_segments(relative) do
    relative
    |> String.trim()
    |> strip_leading_dot_slashes()
    |> build_segments()
  end

  defp build_segments(""), do: {:ok, []}

  defp build_segments(path) do
    cond do
      EvoGit.Platform.absolute_path?(path) ->
        {:error, :absolute}

      true ->
        segments = path |> String.replace("\\", "/") |> String.split("/", trim: true)

        if Enum.any?(segments, &(&1 in [".", ".."])) do
          {:error, :invalid_segment}
        else
          {:ok, segments}
        end
    end
  end

  defp strip_leading_dot_slashes("./" <> rest), do: strip_leading_dot_slashes(rest)
  defp strip_leading_dot_slashes(".\\" <> rest), do: strip_leading_dot_slashes(rest)
  defp strip_leading_dot_slashes(path), do: path

  defp safe_format(path) do
    VctPath.format(path)
  rescue
    ArgumentError -> nil
  end

  ## Points

  @doc """
  Turns arbitrary text into a VALID VCT path segment (never `""`, `"."` or
  `".."`, no separators or control characters).
  """
  @spec point_segment(term()) :: String.t()
  def point_segment(raw) do
    segment =
      raw
      |> to_string()
      |> String.replace(~r{[/\\]}, "-")
      |> String.replace(~r/[\x00-\x1F\x7F]/, "")
      |> String.trim()

    if segment in ["", ".", ".."], do: "project", else: segment
  end

  @doc """
  Returns the first unused `vct:///projects/<segment>[-N]` point.
  """
  @spec unique_point([Mount.t()], String.t()) :: String.t()
  def unique_point(mounts, base) when is_list(mounts) and is_binary(base),
    do: unique_point(mounts, base, 1)

  defp unique_point(mounts, base, counter) do
    candidate = if counter == 1, do: base, else: base <> "-" <> Integer.to_string(counter)

    if find_by_point(mounts, candidate) do
      unique_point(mounts, base, counter + 1)
    else
      candidate
    end
  end

  defp point_for_basename(basename) do
    VctPath.format(VctPath.join(@projects_prefix, point_segment(basename)))
  end
end
