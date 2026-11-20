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

  ## Workspace mounts

  A WORKSPACE mount is a third, orthogonal kind: a point below
  `vct:///workspaces/<slug>` whose row carries `kind: "workspace"`, `path: nil`
  and an ordered `members` list (see `EvoGit.VCT.Mount`). A workspace is a pure
  grouping point, so it is neither a PROJECT mount nor a RESERVED one: the cap
  never evicts it, it never counts against the cap, and `find_by_os_path/2` /
  `mount_for_path/2` never return it (it owns no OS path). Workspaces never
  nest: a workspace point is refused as a workspace member.

  The ONE namespace definition is `project_mount?/1` / `workspace_point?/1` /
  `reserved?/1` — all POINT-based; `kind` is a storage-class label and never
  expresses that split.
  """

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath

  @typedoc """
  A mutation-rule failure of this module.

  Exactly the reasons the pure rules return: `:invalid_point` (an unparseable
  point, or a workspace point where a file mount is required — both via
  `VctPath.canonical/1` / `reject_workspace_point/1` / `require_workspace_point/1`),
  `:invalid_path` (a blank or non-binary OS path), `:invalid_mounts` (a non-list
  mount table) and `:not_found` (a removal that matched no mount).
  """
  @type mount_error :: :invalid_point | :invalid_path | :invalid_mounts | :not_found

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
  Returns the display name for an OS path: its basename, or `"root"` for the
  degenerate root (`path_basename/1` normalizes a blank path to `"/"`, whose
  basename is `""`).
  """
  @spec display_name(String.t()) :: String.t()
  def display_name(path) when is_binary(path) do
    case path_basename(path) do
      "" -> "root"
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

  @doc """
  Normalizes a workspace description: blank (or non-binary) becomes `nil`.
  """
  @spec normalize_description(term()) :: String.t() | nil
  def normalize_description(description) when is_binary(description) do
    if String.trim(description) == "", do: nil, else: String.trim(description)
  end

  def normalize_description(_description), do: nil

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
  Returns `true` when `point` is a WORKSPACE mount point
  (`vct:///workspaces/<name>` and anything nested below it).

  A workspace point is a pure grouping point: it has no OS path, it is not a
  project mount and it is not a reserved (system) mount. TOTAL — `nil`, garbage,
  `vct:///workspaces` (no name) and `vct:///projects/foo` are all `false`,
  never a raise.
  """
  @spec workspace_point?(VctPath.t() | String.t() | term()) :: boolean()
  def workspace_point?(point) do
    case point_segments(point) do
      {:ok, ["workspaces", _name | _rest]} -> true
      _other -> false
    end
  end

  @doc """
  Returns `true` when `point` names a workspace mount — the POINT-based
  spelling of `workspace_point?/1` (mirroring `project_mount?/1`, which is also
  point-based).

  This is the LEGACY spelling of `workspace_point?/1` — the same rule, with no
  production caller, kept only while the value-object tests pin it; prefer
  `workspace_point?/1`.

  TOTAL: an unparseable or non-path input is `false`.
  """
  @spec workspace_mount?(VctPath.t() | String.t() | term()) :: boolean()
  def workspace_mount?(point), do: workspace_point?(point)

  @doc """
  Returns `true` when `point` is RESERVED — a system mount outside both
  `vct:///projects/<name>` and `vct:///workspaces/<name>` (`vct:///`,
  `vct:///projects`, `vct:///<namespace>`).

  Reserved mounts are never listed as projects, never forgotten and never
  evicted by the cap. A WORKSPACE point is NOT reserved (it has its own rules).
  TOTAL: an unparseable or non-path input is NOT reserved (`false`), so a caller
  can distinguish "reserved" from "not a point at all".
  """
  @spec reserved?(VctPath.t() | String.t() | term()) :: boolean()
  def reserved?(point) do
    case point_segments(point) do
      {:ok, segments} ->
        not project_segments?(segments) and not workspace_segments?(segments)

      :error ->
        false
    end
  end

  @doc """
  Keeps only the PROJECT mounts of a mount list, preserving order.
  """
  @spec project_mounts([Mount.t()]) :: [Mount.t()]
  def project_mounts(mounts) when is_list(mounts), do: Enum.filter(mounts, &project_entry?/1)
  def project_mounts(_mounts), do: []

  @doc """
  Keeps only the WORKSPACE mounts of a mount list, preserving order.

  TOTAL: a non-list is `[]`.
  """
  @spec workspace_mounts([Mount.t()]) :: [Mount.t()]
  def workspace_mounts(mounts) when is_list(mounts), do: Enum.filter(mounts, &workspace_entry?/1)
  def workspace_mounts(_mounts), do: []

  defp project_entry?(%Mount{point: point}), do: project_mount?(point)
  defp project_entry?(_mount), do: false

  defp workspace_entry?(%Mount{point: point}), do: workspace_point?(point)
  defp workspace_entry?(_mount), do: false

  defp project_segments?(["projects", _name | _rest]), do: true
  defp project_segments?(_segments), do: false

  defp workspace_segments?(["workspaces", _name | _rest]), do: true
  defp workspace_segments?(_segments), do: false

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

  Mounts without an OS path (a workspace) are SKIPPED, so a workspace is never
  returned and never raises here.
  """
  @spec find_by_os_path([Mount.t()], String.t()) :: Mount.t() | nil
  def find_by_os_path(mounts, os_path) when is_list(mounts) and is_binary(os_path) do
    target = comparison_form(normalize_os_path(os_path))
    Enum.find(mounts, &(&1 |> mount_path() |> path_equal?(target)))
  end

  def find_by_os_path(_mounts, _os_path), do: nil

  @doc """
  Returns the mount containing `os_path` — the LONGEST matching OS-path prefix.

  Matching respects a path boundary (`/a/b` matches `/a/b/c` but not `/a/bc`)
  and compares separator-insensitively, so Windows paths work. Mounts without
  an OS path (a workspace) are SKIPPED, so a workspace never owns a path and
  never raises here. `nil` when no mount contains the path.
  """
  @spec mount_for_path([Mount.t()], String.t() | nil) :: Mount.t() | nil
  def mount_for_path(mounts, os_path) when is_list(mounts) and is_binary(os_path) do
    target = comparison_form(normalize_os_path(os_path))

    mounts
    |> Enum.filter(fn mount -> prefix?(prefix_form(mount_path(mount)), target) end)
    |> Enum.max_by(fn mount -> byte_size(prefix_form(mount_path(mount))) end, fn -> nil end)
  end

  def mount_for_path(_mounts, _os_path), do: nil

  defp mount_path(%Mount{path: path}) when is_binary(path), do: path
  defp mount_path(_mount), do: nil

  defp path_equal?(nil, _target), do: false
  defp path_equal?(path, target) when is_binary(path), do: comparison_form(path) == target

  # A mount with no OS path can never be a prefix: give it an EMPTY comparison
  # form (and a zero byte size) so the filter drops it instead of raising.
  defp prefix_form(nil), do: ""
  defp prefix_form(path) when is_binary(path), do: comparison_form(path)

  defp prefix?("", _target), do: false

  defp prefix?(prefix, target) do
    cond do
      prefix == "/" -> String.starts_with?(target, "/")
      target == prefix -> true
      true -> String.starts_with?(target, prefix <> "/")
    end
  end

  ## Workspace membership

  @doc """
  Resolves ONE workspace member ref to the mount it names.

  POINT-first: the member's `point` is looked up with `find_by_point/2` and only
  when it does not resolve is its exact normalized OS `path` looked up with
  `find_by_os_path/2`. Returns:

    * `{:ok, mount}` — a resolved non-workspace (git) mount;
    * `:nested` — the member resolved to a WORKSPACE (never expanded; workspaces
      do not nest);
    * `:missing` — nothing resolves (including an unusable member ref) — a
      member's target need not exist.

  Resolution is deliberately LENIENT (a ref is read as a raw `point`/`path`
  pair, not validated as a new member): a hand-written or legacy row that names
  a workspace still answers `:nested` instead of being flattened.
  """
  @spec member_mount([Mount.t()], term()) :: {:ok, Mount.t()} | :missing | :nested
  def member_mount(mounts, ref) when is_list(mounts) do
    case lookup_member_mount(mounts, ref) do
      %Mount{} = mount -> if workspace_entry?(mount), do: :nested, else: {:ok, mount}
      nil -> :missing
    end
  end

  def member_mount(_mounts, _ref), do: :missing

  defp lookup_member_mount(mounts, ref) do
    case point_find(mounts, member_ref_point(ref)) do
      %Mount{} = mount -> mount
      nil -> os_path_find(mounts, member_ref_path(ref))
    end
  end

  # Resolution reads the raw ref (either key spelling) and is lenient: a value
  # that cannot be used simply never resolves.
  defp member_ref_point(ref) do
    case fetch_ref(ref, "point") do
      %VctPath{} = point ->
        VctPath.format(point)

      point when is_binary(point) ->
        case VctPath.parse(point) do
          {:ok, parsed} -> VctPath.format(parsed)
          {:error, _reason} -> nil
        end

      _other ->
        nil
    end
  end

  defp member_ref_path(ref) do
    case fetch_ref(ref, "path") do
      path when is_binary(path) ->
        if String.trim(path) == "", do: nil, else: normalize_os_path(path)

      _other ->
        nil
    end
  end

  defp fetch_ref(ref, "point") when is_map(ref), do: Map.get(ref, "point") || Map.get(ref, :point)
  defp fetch_ref(ref, "path") when is_map(ref), do: Map.get(ref, "path") || Map.get(ref, :path)
  defp fetch_ref(_ref, _key), do: nil

  defp point_find(_mounts, nil), do: nil
  defp point_find(mounts, point) when is_binary(point), do: find_by_point(mounts, point)

  defp os_path_find(_mounts, nil), do: nil
  defp os_path_find(mounts, path) when is_binary(path), do: find_by_os_path(mounts, path)

  @doc """
  Splits a member list into the refs that are USABLE and the ones that are not
  — the ONE documented member policy: **keep every resolvable member and report
  the unusable ones**.

  Each element is normalized INDIVIDUALLY with `EvoGit.VCT.Mount.member/1`
  (which canonicalizes a point, normalizes an OS path and refuses a workspace
  point). Returns `{valid, invalid}`:

    * `valid` — the normalized `t:EvoGit.VCT.Mount.member_ref/0` maps, in
      stored order;
    * `invalid` — the refs that did not normalize, in stored order and in their
      STORED form (unmodified, so a caller can report exactly what was stored).

  A single unusable ref never hides its siblings. `{[], []}` for a non-list.
  A member's target need not exist — that is resolution's concern, not this
  split.
  """
  @spec member_refs(term()) :: {[Mount.member_ref()], [term()]}
  def member_refs(members) when is_list(members) do
    {valid, invalid} =
      Enum.reduce(members, {[], []}, fn ref, {valid, invalid} ->
        case Mount.member(ref) do
          {:ok, normalized} -> {[normalized | valid], invalid}
          {:error, _reason} -> {valid, [ref | invalid]}
        end
      end)

    {Enum.reverse(valid), Enum.reverse(invalid)}
  end

  def member_refs(_members), do: {[], []}

  @doc """
  Returns the WORKSPACE mounts whose membership covers `point` and/or `os_path`,
  in input order (the caller sorts).

  A workspace matches when ANY of its members:

    * carries `point` (`point` is `nil` → this clause never matches);
    * carries a path that equals `os_path` once both are in
      `comparison_form/1` form (`os_path` is `nil`, or the member has no path →
      this clause never matches);
    * resolves through `member_mount/2` to a mount whose point is `point`.

  Membership follows `member_refs/1`'s policy: every resolvable member counts,
  so ONE unusable ref never hides the rest, and a member's target need not
  exist. TOTAL: a non-list is `[]`.
  """
  @spec workspaces_containing([Mount.t()], term(), term()) :: [Mount.t()]
  def workspaces_containing(mounts, point, os_path) when is_list(mounts) do
    target_point = comparison_point(point)
    target_path = comparison_path(os_path)

    mounts
    |> workspace_mounts()
    |> Enum.filter(&workspace_covers?(&1, mounts, target_point, target_path))
  end

  def workspaces_containing(_mounts, _point, _os_path), do: []

  defp workspace_covers?(%Mount{members: members}, mounts, target_point, target_path) do
    members
    |> normal_members()
    |> Enum.any?(fn member ->
      member_point_match?(member, target_point) or
        member_path_match?(member, target_path) or
        member_resolves_to?(mounts, member, target_point)
    end)
  end

  defp normal_members(members) do
    {valid, _invalid} = member_refs(members)
    valid
  end

  defp member_point_match?(_member, nil), do: false
  defp member_point_match?(member, target_point), do: member["point"] == target_point

  defp member_path_match?(_member, nil), do: false

  defp member_path_match?(%{"path" => path}, target_path) when is_binary(path),
    do: comparison_form(path) == target_path

  defp member_path_match?(_member, _target_path), do: false

  defp member_resolves_to?(_mounts, _member, nil), do: false

  defp member_resolves_to?(mounts, member, target_point) do
    case member_mount(mounts, member) do
      {:ok, %Mount{point: point}} -> point == target_point
      _missing_or_nested -> false
    end
  end

  defp comparison_point(nil), do: nil
  defp comparison_point(%VctPath{} = point), do: VctPath.format(point)

  defp comparison_point(point) when is_binary(point) do
    case VctPath.parse(point) do
      {:ok, parsed} -> VctPath.format(parsed)
      {:error, _reason} -> nil
    end
  end

  defp comparison_point(_point), do: nil

  defp comparison_path(nil), do: nil

  defp comparison_path(os_path) when is_binary(os_path),
    do: comparison_form(normalize_os_path(os_path))

  defp comparison_path(_os_path), do: nil

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

  RESERVED (system) mounts AND WORKSPACE mounts are always retained, and they do
  not count against the cap (a workspace is filtered exactly like a reserved
  mount: it is simply not a project mount). A `nil` `last_opened_at` counts as
  the oldest, and the sort is stable over the incoming list — which is the
  store's order (newest first, ties by point ascending) — so the outcome is
  deterministic. Surviving mounts keep their original list positions, so
  membership (not just count) is preserved.
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
        VctPath.last_segment(mount.point) == base and
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

  A WORKSPACE point is refused with `{:error, :invalid_point}` — a workspace is
  created through `upsert_workspace/6`, never as a file mount.
  """
  @spec ensure_mount([Mount.t()], VctPath.t() | String.t(), String.t(), String.t() | nil) ::
          {:ok, [Mount.t()], Mount.t(), boolean()} | {:error, mount_error()}
  def ensure_mount(mounts, point, os_path, name) when is_list(mounts) do
    with {:ok, canonical} <- VctPath.canonical(point),
         :ok <- reject_workspace_point(canonical),
         {:ok, normalized} <- ensure_os_path(os_path) do
      name = normalize_name(name)
      do_ensure_mount(mounts, canonical, normalized, name)
    end
  end

  def ensure_mount(_mounts, _point, _os_path, _name), do: {:error, :invalid_mounts}

  defp reject_workspace_point(point) do
    if workspace_point?(point), do: {:error, :invalid_point}, else: :ok
  end

  @doc """
  Creates or REPLACES the WORKSPACE mount at `point` — the pure upsert rule
  behind `EvoGit.VCT.create_workspace/…`.

  Returns `{:ok, mounts, mount}` (the updated list and the written workspace) or
  `{:error, :invalid_point}` for an unparseable/non-workspace point and the
  error of `EvoGit.VCT.Mount.normalize_members/1` for invalid members.

  A row already at `point` is replaced IN PLACE (same list position), otherwise
  the workspace is appended. The written mount is `kind: "workspace"`,
  `path: nil`, the supplied (normalized) name, the normalized members, the
  supplied description and `last_opened_at: now` (a `nil` `now` defaults to
  `DateTime.utc_now/0`, like `register/4`). The cap is NEVER applied here.
  """
  @spec upsert_workspace(
          [Mount.t()],
          VctPath.t() | String.t(),
          String.t() | nil,
          [Mount.member_ref()],
          String.t() | nil,
          DateTime.t() | nil
        ) :: {:ok, [Mount.t()], Mount.t()} | {:error, mount_error() | Mount.member_error()}
  def upsert_workspace(mounts, point, name, members, description, now \\ nil)

  def upsert_workspace(mounts, point, name, members, description, now)
      when is_list(mounts) do
    with {:ok, canonical} <- VctPath.canonical(point),
         :ok <- require_workspace_point(canonical),
         {:ok, normalized_members} <- Mount.normalize_members(members) do
      mount = %Mount{
        point: canonical,
        path: nil,
        name: normalize_name(name),
        kind: "workspace",
        last_opened_at: now || DateTime.utc_now(),
        members: normalized_members,
        description: normalize_description(description)
      }

      case find_by_point(mounts, canonical) do
        %Mount{} = existing -> {:ok, replace(mounts, existing, mount), mount}
        nil -> {:ok, mounts ++ [mount], mount}
      end
    end
  end

  def upsert_workspace(_mounts, _point, _name, _members, _description, _now),
    do: {:error, :invalid_mounts}

  defp require_workspace_point(point) do
    if workspace_point?(point), do: :ok, else: {:error, :invalid_point}
  end

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
  Returns the canonical VCT URL for `relative_path` inside the mount's point.

  `"./"`, `""` and `"."`-free relative paths map onto the mount point itself;
  `"./src/auth"` and `"src/auth"` map onto `<point>/src/auth`. Returns `nil` for
  an absolute path, a `".."`/`"."` segment, a control-character segment or a
  non-binary input.

  Takes an already-resolved `%Mount{}` plus a relative path — unlike
  `EvoGit.VCT.vct_path_for/2` and its batched companion
  `EvoGit.VCT.vct_paths_for/2`, which take a repo ROOT plus relative path(s) and
  resolve the containing mount themselves (`EvoGit.VCT.Mounts.vct_paths/3` maps
  every path through this function after ONE mount lookup).
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
  Turns arbitrary text into a VALID VCT path segment: folds `/` and `\\` to
  `-`, strips control characters, trims the result, and maps `""`, `"."` and
  `".."` to `"project"`.

  It is a SANITIZER, not a slugifier: no downcasing, no transliteration, no
  space collapsing.
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
