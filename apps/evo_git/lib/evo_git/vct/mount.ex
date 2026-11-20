defmodule EvoGit.VCT.Mount do
  @moduledoc """
  A mount entry of the Virtual Context Tree (VCT).

  A mount binds a canonical VCT point (`vct:///projects/foo`) to an absolute OS
  path on the local host. Mounts are pure metadata: creating one never touches
  the filesystem, never creates a symlink/junction/bind mount, and never changes
  the on-disk layout.

  `kind` is a plain string so later iterations can add mount kinds. Two kinds
  exist today:

    * `"git"` — a PROJECT (or reserved/system) mount: it owns ONE absolute OS
      path and that path is required.
    * `"workspace"` — a pure GROUPING point below `vct:///workspaces/<slug>`. A
      workspace has **no OS path at all** (`path: nil`: no directory, no
      worktree, no file view) and instead carries an ORDERED `members` list plus
      an optional `description`.

  A member ref is a STRING-KEYED map
  `%{"point" => "vct:///projects/foo" | nil, "path" => "/abs/path" | nil}` with
  at least one of the two non-nil; order is significant and a member's target
  need not exist. A member point is never itself a workspace point — nesting is
  refused when the workspace is created, so a workspace tree is exactly ONE
  level deep and cycles are structurally impossible.
  """

  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Table

  defstruct [
    :point,
    :path,
    :name,
    kind: "git",
    last_opened_at: nil,
    members: [],
    description: nil
  ]

  @type member :: %{optional(String.t()) => String.t() | nil}

  @type t :: %__MODULE__{
          point: String.t(),
          path: String.t() | nil,
          name: String.t(),
          kind: String.t(),
          last_opened_at: DateTime.t() | nil,
          members: [member()],
          description: String.t() | nil
        }

  @type new_opt ::
          {:name, String.t()}
          | {:kind, String.t()}
          | {:last_opened_at, DateTime.t() | nil}
          | {:members, [member()]}
          | {:description, String.t() | nil}

  @git_kind "git"
  @workspace_kind "workspace"

  @atom_keys %{
    "point" => :point,
    "path" => :path,
    "name" => :name,
    "kind" => :kind,
    "last_opened_at" => :last_opened_at,
    "members" => :members,
    "description" => :description
  }

  @doc """
  Builds a mount, validating its VCT point and canonicalizing it.

  ## Options

    * `:name` — display name (default: `Path.basename/1` of `path`, or the
      workspace point's slug for a workspace)
    * `:kind` — mount kind (default: `"git"`)
    * `:last_opened_at` — a `DateTime` or `nil` (default: `DateTime.utc_now/0`)
    * `:members` — workspace members (default: `[]`), normalized through
      `normalize_members/1`
    * `:description` — workspace description (default: `nil`)

  Raises `ArgumentError` when the point is invalid, when a `"git"` mount's
  `path` is not a non-empty binary, when a `"workspace"` mount carries a path,
  and when a workspace point is used for a non-workspace mount.
  """
  @spec new(VctPath.t() | String.t(), String.t() | nil, [new_opt()]) :: t()
  def new(point, path, opts \\ []) do
    point = canonical_point(point)

    case normalize_kind(Keyword.get(opts, :kind, @git_kind)) do
      @workspace_kind -> new_workspace(point, path, opts)
      kind -> new_file_mount(point, path, kind, opts)
    end
  end

  defp new_workspace(point, path, opts) do
    unless is_nil(path) do
      raise ArgumentError,
            "invalid VCT workspace path: #{inspect(path)} " <>
              "(a workspace mount has no OS path — pass nil)"
    end

    unless Table.workspace_point?(point) do
      raise ArgumentError,
            "invalid VCT workspace point: #{inspect(point)} " <>
              "(a workspace mount point must be vct:///workspaces/<name>)"
    end

    %__MODULE__{
      point: point,
      path: nil,
      name: Keyword.get(opts, :name) || VctPath.name(point),
      kind: @workspace_kind,
      last_opened_at: Keyword.get(opts, :last_opened_at, DateTime.utc_now()),
      members: validate_members!(Keyword.get(opts, :members, [])),
      description: Table.normalize_description(Keyword.get(opts, :description))
    }
  end

  defp new_file_mount(point, path, kind, opts) do
    if Table.workspace_point?(point) do
      raise ArgumentError,
            "invalid VCT mount point: #{inspect(point)} " <>
              "(a workspace point is never a file mount — use kind: \"workspace\" with a nil path)"
    end

    path = validate_path!(path)

    %__MODULE__{
      point: point,
      path: path,
      name: Keyword.get(opts, :name) || Path.basename(path),
      kind: kind,
      last_opened_at: Keyword.get(opts, :last_opened_at, DateTime.utc_now())
    }
  end

  @doc """
  Normalizes ONE workspace member ref (an atom- OR string-keyed map).

  Returns `{:ok, member}` — a STRING-keyed map carrying BOTH keys, so it is
  always re-encodable (`%{"point" => nil | canonical_point, "path" => nil |
  normalized_os_path}`) — or one of:

    * `{:error, {:invalid_member, ref}}` — not a map, neither key present, a
      non-binary point, an unparseable point, or a blank/relative/non-binary
      path;
    * `{:error, {:member_is_workspace, point}}` — the point is a workspace
      point (workspaces never nest).

  Nothing is required to exist: a member may name an unmounted path or a mount
  whose OS path is missing.
  """
  @spec member(term()) :: {:ok, member()} | {:error, term()}
  def member(ref) when is_map(ref) do
    with {:ok, point} <- member_point(ref),
         {:ok, path} <- member_path(ref) do
      if is_nil(point) and is_nil(path) do
        {:error, {:invalid_member, ref}}
      else
        {:ok, %{"point" => point, "path" => path}}
      end
    end
  end

  def member(ref), do: {:error, {:invalid_member, ref}}

  @doc """
  Normalizes an ORDERED list of workspace member refs — the STRICT creation
  validator.

  Returns `{:ok, members}` (order preserved, duplicates NOT collapsed) with
  every entry in the canonical form produced by `member/1`, or
  `{:error, :invalid_members}` for a non-list, or the error of the first
  invalid member (see `member/1`).

  Use this on the CREATION path (`new/3`), where a bad ref is a caller mistake
  worth refusing (an unparseable point, a workspace point, a relative path).
  LOADING a persisted row must never use it: see `from_map/1`.
  """
  @spec normalize_members(term()) :: {:ok, [member()]} | {:error, term()}
  def normalize_members(members) when is_list(members) do
    members
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case member(ref) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_members(_members), do: {:error, :invalid_members}

  @doc """
  Returns `true` when `mount` is a WORKSPACE mount (`kind: "workspace"`).

  TOTAL: a non-mount input is `false`, never a raise.
  """
  @spec workspace?(term()) :: boolean()
  def workspace?(%__MODULE__{kind: @workspace_kind}), do: true
  def workspace?(_mount), do: false

  @doc """
  Returns `true` when `mount` is a `"git"` mount (the default kind).

  TOTAL: a non-mount input is `false`, never a raise.
  """
  @spec git?(term()) :: boolean()
  def git?(%__MODULE__{kind: @git_kind}), do: true
  def git?(_mount), do: false

  @doc """
  Decodes a mount from a persisted (JSON) map. LENIENT by contract: loading
  never loses a stored row.

  Accepts string-keyed maps (JSON) as well as atom-keyed ones. Returns
  `{:ok, mount}`, or `{:error, reason}` when the map is not a map, the point is
  missing/invalid (the reason of `EvoGit.VCT.Path.parse/1` is propagated), the
  path is present but not a non-empty binary, or `members` is present but is not
  a list (`{:error, :invalid_members}`).

  A workspace row decodes with `path: nil` (an absent or `nil` `path` is
  accepted; `members` absent/`nil` decodes to `[]`; `description` is a string or
  `nil`). `members` must already be decoded — a JSON BINARY is not accepted at
  this boundary (the store layer decodes it).

  Members are preserved AS STORED: each map element (string- OR atom-keyed)
  decodes to `%{"point" => value-or-nil, "path" => value-or-nil}` WITHOUT being
  parsed, canonicalized or validated, and a non-map element is dropped. That is
  deliberately NOT `normalize_members/1` (the strict creation validator): a
  hand-written, legacy or corrupted row may carry a workspace-point member or an
  unusable ref, and it must still load so RESOLUTION can diagnose it — an
  unusable ref is reported `missing` and a workspace ref `nested` by
  `EvoGit.VCT.workspace_members/1`. Refusing it here would drop the whole
  workspace row instead.

  An absent, `nil` or unparseable ISO-8601 `last_opened_at` decodes to `nil`
  without raising.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, point} <- decode_point(map),
         {:ok, path} <- decode_path(map),
         {:ok, members} <- decode_members(map) do
      {:ok,
       %__MODULE__{
         point: point,
         path: path,
         name: decode_string(map, "name") || default_name(point, path),
         kind: decode_string(map, "kind") || @git_kind,
         last_opened_at: decode_datetime(map),
         members: members,
         description: decode_string(map, "description")
       }}
    end
  end

  def from_map(_other), do: {:error, :invalid_mount}

  @doc """
  Encodes a mount as a STRING-keyed map suitable for JSON.

  Always carries `"point"`, `"path"`, `"name"`, `"kind"`, `"last_opened_at"`
  (ISO-8601 or `nil`), `"members"` (a list of member maps) and `"description"`
  — `"path"` is `nil` for a workspace.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = mount) do
    %{
      "point" => mount.point,
      "path" => mount.path,
      "name" => mount.name,
      "kind" => mount.kind,
      "last_opened_at" => encode_datetime(mount.last_opened_at),
      "members" => encode_members(mount.members),
      "description" => mount.description
    }
  end

  ## Member normalization helpers

  defp member_point(ref) do
    case fetch(ref, "point") do
      nil -> {:ok, nil}
      %VctPath{} = point -> decode_member_point(VctPath.format(point), ref)
      point when is_binary(point) -> decode_member_point(point, ref)
      _other -> {:error, {:invalid_member, ref}}
    end
  end

  defp decode_member_point(point, ref) do
    case VctPath.parse(point) do
      {:ok, parsed} ->
        canonical = VctPath.format(parsed)

        if Table.workspace_point?(canonical) do
          {:error, {:member_is_workspace, canonical}}
        else
          {:ok, canonical}
        end

      {:error, _reason} ->
        {:error, {:invalid_member, ref}}
    end
  end

  defp member_path(ref) do
    case fetch(ref, "path") do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        trimmed = String.trim(path)

        if trimmed != "" and EvoGit.Platform.absolute_path?(trimmed) do
          {:ok, Table.normalize_os_path(trimmed)}
        else
          {:error, {:invalid_member, ref}}
        end

      _other ->
        {:error, {:invalid_member, ref}}
    end
  end

  defp validate_members!(members) do
    case normalize_members(members) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, members_error(reason)
    end
  end

  defp members_error(:invalid_members) do
    "invalid VCT workspace members: expected a list of member maps " <>
      "(%{point: …, path: …} or %{\"point\" => …, \"path\" => …})"
  end

  defp members_error({:member_is_workspace, point}) do
    "invalid VCT workspace member: #{inspect(point)} is a workspace " <>
      "(workspaces never nest)"
  end

  defp members_error({:invalid_member, ref}) do
    "invalid VCT workspace member: #{inspect(ref)} " <>
      "(each member needs at least one of a valid vct:/// point or an absolute OS path)"
  end

  defp members_error(reason), do: "invalid VCT workspace members: #{inspect(reason)}"

  ## Decoding helpers

  defp decode_point(map) do
    case fetch(map, "point") do
      point when is_binary(point) ->
        case VctPath.parse(point) do
          {:ok, parsed} -> {:ok, VctPath.format(parsed)}
          {:error, reason} -> {:error, reason}
        end

      _missing ->
        {:error, :invalid_point}
    end
  end

  # A workspace has no OS path, so an absent/`nil` path is `nil`; a present
  # value must still be a non-empty binary (unchanged for file mounts).
  defp decode_path(map) do
    case fetch(map, "path") do
      nil -> {:ok, nil}
      path when is_binary(path) and path != "" -> {:ok, path}
      _missing -> {:error, :invalid_path}
    end
  end

  # LENIENT, by contrast with `normalize_members/1`: a persisted row is data we
  # must LOAD, not a creation request we may refuse. Routing this through the
  # strict validator would reject a hand-written/legacy/corrupted row (a
  # workspace-point member, an unusable ref) and make
  # `EvoGit.VCT.load_mounts/1` drop the whole workspace, so
  # `EvoGit.VCT.workspace_members/1` could never report `:nested` / `:missing`
  # for real stored data. Resolution owns that diagnosis; decoding only
  # normalizes the map SHAPE (STRING keys, both keys present, string-or-nil) and
  # keeps every value verbatim.
  defp decode_members(map) do
    case fetch(map, "members") do
      nil -> {:ok, []}
      members when is_list(members) -> {:ok, stored_members(members)}
      _other -> {:error, :invalid_members}
    end
  end

  # Keeps the stored refs ORDER and their values verbatim (no point parsing, no
  # path absolutizing), dropping only an element that is not a map at all.
  defp stored_members(members) do
    members
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn ref ->
      %{
        "point" => string_or_nil(fetch_member(ref, "point")),
        "path" => string_or_nil(fetch_member(ref, "path"))
      }
    end)
  end

  defp default_name(_point, path) when is_binary(path) and path != "", do: Path.basename(path)

  defp default_name(point, _path), do: VctPath.name(point) || ""

  defp decode_string(map, key) do
    case fetch(map, key) do
      value when is_binary(value) -> value
      _missing -> nil
    end
  end

  defp decode_datetime(map) do
    case fetch(map, "last_opened_at") do
      %DateTime{} = datetime ->
        datetime

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          {:error, _reason} -> nil
        end

      _missing ->
        nil
    end
  end

  defp fetch(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@atom_keys, key))
    end
  end

  ## Encoding helpers

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp encode_members(members) when is_list(members), do: Enum.map(members, &encode_member/1)
  defp encode_members(_members), do: []

  defp encode_member(ref) do
    case member(ref) do
      {:ok, normalized} ->
        normalized

      {:error, _reason} ->
        # A hand-built struct may carry an un-normalized member; keep the encode
        # TOTAL and JSON-safe instead of raising (the mount layer never writes
        # such a value — `new/3` and `from_map/1` normalize).
        %{
          "point" => string_or_nil(fetch_member(ref, "point")),
          "path" => string_or_nil(fetch_member(ref, "path"))
        }
    end
  end

  defp fetch_member(ref, key) when is_map(ref) do
    case Map.fetch(ref, key) do
      {:ok, value} -> value
      :error -> Map.get(ref, Map.fetch!(@atom_keys, key))
    end
  end

  defp fetch_member(_ref, _key), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  ## Validation

  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind), do: kind

  defp canonical_point(%VctPath{} = point), do: VctPath.format(point)
  defp canonical_point(point) when is_binary(point), do: VctPath.format(VctPath.parse!(point))

  defp canonical_point(other) do
    raise ArgumentError, "invalid VCT mount point: #{inspect(other)}"
  end

  defp validate_path!(path) when is_binary(path) and path != "", do: path

  defp validate_path!(path) do
    raise ArgumentError,
          "invalid VCT mount path: #{inspect(path)} (must be a non-empty absolute path string)"
  end
end
