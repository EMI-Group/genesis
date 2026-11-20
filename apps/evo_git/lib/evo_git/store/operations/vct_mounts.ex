defmodule EvoGit.Store.Operations.VctMounts do
  @moduledoc """
  Ecto operations for the Virtual Context Tree (VCT) mount table
  (`vct_mounts`).

  The VCT namespace itself (point derivation, re-pointing, the cap) belongs to
  `EvoGit.VCT` / `EvoGit.VCT.Table`; this module only moves the mount LIST in
  and out of SQLite, so the store layer never depends on the VCT modules.

  ## Conventions (shared with the sibling Operations modules)

  Every public function takes the repo pid FIRST and runs its whole body
  inside `EvoGit.Store.RepoScope.with_repo/2`; every statement goes through
  `EvoGit.Repo.*` + `Ecto.Query` against
  `EvoGit.Store.Schemas.VctMountRow`. There is NO try/rescue: a failing read
  raises out of `EvoGit.Repo.*` and the facade turns it into the read's
  documented degraded value (`offload/5`), while a failing write is converted
  by the facade's disk-full choke point (`write_call/2`) or crashes it.

  ## Entry maps are STRING-KEYED

  `list/1` returns entries shaped `%{"point" =>, "path" =>, "name" =>,
  "kind" =>, "last_opened_at" => %DateTime{} | nil, "members" => [map()],
  "description" => String.t() | nil}` — the shape the VCT layer consumes.
  `save/2` accepts BOTH key spellings (atom-keyed mount maps and the
  string-keyed maps `EvoGit.VCT.Mount.to_map/1` produces), so a read-modify-write
  round trip needs no reshaping. `last_opened_at` may be a `%DateTime{}`, an
  ISO-8601 binary or `nil`; it is normalized through
  `EvoGit.Store.Types.TaskTimestamp.cast/1` before the insert. `path` may be
  `nil` (a workspace mount owns no OS path), and so may `description`.

  ## `members`: the decoded/encoded boundary

  The column stores JSON **TEXT** (an ORDERED array of STRING-KEYED member
  maps, `%{"point" => "vct:///…" | nil, "path" => "/abs/path" | nil}`); this
  module is the ONE place that crosses that boundary, in both directions:

    * on the way IN (`entry_from_row/1`) the column is DECODED into a list of
      maps. A `NULL` column — every mount written before workspace mounts
      existed — is `[]`, and an undecodable or non-list value also degrades to
      `[]` with ONE `Logger.warning` per row (a corrupt column must not take the
      whole mount list down);
    * on the way OUT (`row_from_entry/1`) the list is encoded with `Jason`. An
      absent or `nil` key is `"[]"`, so a git mount always round-trips to an
      empty list, and a value that is not a list of maps raises a descriptive
      `ArgumentError` — that is a caller bug (the VCT always writes a member
      list), never a value to silently store.

  `description` needs no boundary: it is plain TEXT and passes through as
  `nil | String.t()`.

  ## Ordering

  `list/1` is newest-first with a `nil` `last_opened_at` LAST and a
  deterministic `point` ASC tie-break, so the caller's order never depends on
  SQLite's scan order.

  ## Transactional diff writes

  `save/2` RECONCILES the table with the supplied list instead of rebuilding
  it: one `EvoGit.Repo.transaction/2` with `mode: :immediate` reads the stored
  points, DELETES only the rows whose point disappeared, and INSERT-OR-REPLACES
  the supplied rows in place (`ON CONFLICT (point) DO UPDATE`), so a surviving
  row is never dropped and recreated. Because the whole diff is one
  transaction, a reader sees either the old table or the new one — never a
  half-written mix — and an empty list still empties the table. The VCT keeps
  the authoritative list in memory, so the supplied list is always the DESIRED
  state, not a patch.
  """

  import Ecto.Query

  require Logger

  alias EvoGit.Repo
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.VctMountRow
  alias EvoGit.Store.Types.TaskTimestamp

  @doc """
  Returns every mount as a STRING-KEYED entry, newest first.

  Ordering: `last_opened_at` DESC with `nil` LAST, then `point` ASC. A failed
  read raises; the facade degrades it to `[]`.
  """
  @spec list(pid()) :: [map()]
  def list(repo) do
    RepoScope.with_repo(repo, fn ->
      VctMountRow
      |> order_by(
        [m],
        asc: fragment("? IS NULL", m.last_opened_at),
        desc: m.last_opened_at,
        asc: m.point
      )
      |> Repo.all()
      |> Enum.map(&entry_from_row/1)
    end)
  end

  @doc """
  Reconciles the mount table to the DESIRED state `mounts` — `:ok` on success.

  One immediate transaction performs a DIFF against the stored rows: rows whose
  point is no longer supplied are deleted, and every supplied row is inserted
  or replaced (`ON CONFLICT (point) DO UPDATE`). An unchanged mount is
  therefore one upsert, not a whole-table rewrite, and an empty list simply
  leaves the table empty. Disk-full is converted by the store facade's write
  choke point; every other error re-raises.
  """
  @spec save(pid(), [map()]) :: :ok
  def save(repo, mounts) when is_list(mounts) do
    RepoScope.with_repo(repo, fn ->
      {:ok, :ok} =
        Repo.transaction(
          fn ->
            # Rows are normalized/validated FIRST, so a bad entry (an unusable
            # `last_opened_at`, a non-list-of-maps `members`) raises before
            # anything is written and the transaction rolls back untouched.
            rows = desired_rows(mounts)
            removed = stored_points() -- Enum.map(rows, & &1.point)

            # Deletes run before the upserts, so a re-pointed mount can claim
            # the OS path the previous owner's row held under the UNIQUE index.
            if removed != [] do
              Repo.delete_all(from(m in VctMountRow, where: m.point in ^removed))
            end

            if rows != [] do
              Repo.insert_all(VctMountRow, rows,
                on_conflict: :replace_all,
                conflict_target: :point
              )
            end

            :ok
          end,
          mode: :immediate
        )

      :ok
    end)
  end

  ## Private — the desired-state diff

  # One row per POINT: a duplicate point in the input cannot make the upsert
  # ambiguous, and the LAST occurrence wins (the supplied list is ordered, so
  # the newest spelling of a mount is the one that is kept).
  defp desired_rows(mounts) do
    mounts
    |> Enum.map(&row_from_entry/1)
    |> Enum.reduce(%{}, fn row, acc -> Map.put(acc, row.point, row) end)
    |> Map.values()
  end

  defp stored_points do
    Repo.all(from(m in VctMountRow, select: m.point))
  end

  ## Private — row ↔ entry

  # THE row → entry translation. `last_opened_at` already loaded through
  # `Types.TaskTimestamp` (a DateTime or nil); `members` is the JSON TEXT
  # column and is DECODED here, so no caller ever sees the wire format.
  defp entry_from_row(%VctMountRow{} = row) do
    %{
      "point" => row.point,
      "path" => row.path,
      "name" => row.name,
      "kind" => row.kind,
      "last_opened_at" => row.last_opened_at,
      "members" => decode_members(row.point, row.members),
      "description" => row.description
    }
  end

  defp row_from_entry(entry) do
    %{
      point: fetch(entry, :point),
      path: fetch(entry, :path),
      name: fetch(entry, :name),
      kind: fetch(entry, :kind) || "git",
      last_opened_at: cast_timestamp(fetch(entry, :last_opened_at)),
      members: encode_members(fetch(entry, :members)),
      description: fetch(entry, :description)
    }
  end

  ## Private — the `members` JSON boundary

  # A NULL column is the EMPTY member list: every mount written before
  # workspace mounts existed has one, and a git mount never has members. A
  # corrupt value degrades to `[]` with ONE warning — one bad row must not take
  # the whole mount list down (the read is total, like every other store read).
  defp decode_members(_point, nil), do: []

  defp decode_members(point, encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, members} when is_list(members) ->
        if Enum.all?(members, &is_map/1) do
          members
        else
          warn_members(point, encoded, :not_a_list_of_maps)
          []
        end

      {:ok, _other} ->
        warn_members(point, encoded, :not_a_list)
        []

      {:error, _reason} ->
        warn_members(point, encoded, :undecodable)
        []
    end
  end

  defp decode_members(point, value) do
    warn_members(point, value, :not_text)
    []
  end

  # An absent/nil key is `"[]"`, so a git mount round-trips to an empty list. A
  # value that is not a list of maps is a CALLER bug (the VCT always writes
  # `Mount.to_map/1`'s shape) and raises instead of silently storing NULL.
  defp encode_members(nil), do: "[]"

  defp encode_members(members) when is_list(members) do
    if Enum.all?(members, &is_map/1) do
      Jason.encode!(members)
    else
      raise ArgumentError,
            "invalid vct_mounts.members: #{inspect(members)} " <>
              "(expected a list of member maps)"
    end
  end

  defp encode_members(value) do
    raise ArgumentError,
          "invalid vct_mounts.members: #{inspect(value)} " <>
            "(expected a list of member maps or nil)"
  end

  defp warn_members(point, value, reason) do
    Logger.warning(
      "vct_mounts: unusable members value for #{inspect(point)} (#{inspect(reason)}); " <>
        "reading it as an empty member list: #{inspect(value)}"
    )
  end

  # `TaskTimestamp.cast/1` accepts a DateTime, an ISO-8601 binary or nil; a
  # value it rejects is a caller bug (the VCT always writes `Mount.to_map/1`'s
  # shape), so it raises instead of silently writing NULL.
  defp cast_timestamp(nil), do: nil

  defp cast_timestamp(value) do
    case Ecto.Type.cast(TaskTimestamp, value) do
      {:ok, datetime} ->
        datetime

      :error ->
        raise ArgumentError,
              "invalid vct_mounts.last_opened_at: #{inspect(value)} " <>
                "(expected a DateTime, an ISO-8601 string or nil)"
    end
  end

  # Accepts BOTH key spellings: an atom key wins when the map has it (even with
  # a `nil` value), else the string spelling is used.
  defp fetch(entry, field) do
    case Map.fetch(entry, field) do
      {:ok, value} -> value
      :error -> Map.get(entry, Atom.to_string(field))
    end
  end
end
