defmodule EvoGit.VCT.Mount do
  @moduledoc """
  A mount entry of the Virtual Context Tree (VCT).

  A mount binds a canonical VCT point (`vct:///projects/foo`) to an absolute OS
  path on the local host. Mounts are pure metadata: creating one never touches
  the filesystem, never creates a symlink/junction/bind mount, and never changes
  the on-disk layout.

  `kind` is a plain string so later iterations can add mount kinds; `"git"` is
  the only kind supported today.
  """

  alias EvoGit.VCT.Path, as: VctPath

  defstruct [:point, :path, :name, kind: "git", last_opened_at: nil]

  @type t :: %__MODULE__{
          point: String.t(),
          path: String.t(),
          name: String.t(),
          kind: String.t(),
          last_opened_at: DateTime.t() | nil
        }

  @type new_opt ::
          {:name, String.t()} | {:kind, String.t()} | {:last_opened_at, DateTime.t() | nil}

  @atom_keys %{
    "point" => :point,
    "path" => :path,
    "name" => :name,
    "kind" => :kind,
    "last_opened_at" => :last_opened_at
  }

  @doc """
  Builds a mount, validating its VCT point and canonicalizing it.

  ## Options

    * `:name` — display name (default: `Path.basename/1` of `path`)
    * `:kind` — mount kind (default: `"git"`)
    * `:last_opened_at` — a `DateTime` or `nil` (default: `DateTime.utc_now/0`)

  Raises `ArgumentError` when the point is invalid or `path` is not a binary.
  """
  @spec new(VctPath.t() | String.t(), String.t(), [new_opt()]) :: t()
  def new(point, path, opts \\ []) do
    path = validate_path!(path)

    %__MODULE__{
      point: canonical_point(point),
      path: path,
      name: Keyword.get(opts, :name) || Path.basename(path),
      kind: Keyword.get(opts, :kind, "git"),
      last_opened_at: Keyword.get(opts, :last_opened_at, DateTime.utc_now())
    }
  end

  @doc """
  Decodes a mount from a (JSON) map.

  Accepts string-keyed maps (JSON) as well as atom-keyed ones. Returns
  `{:ok, mount}`, or `{:error, reason}` when the map is not a map, the point is
  missing/invalid (the reason of `EvoGit.VCT.Path.parse/1` is propagated), or
  the path is missing/not a binary.

  An absent, `nil` or unparseable ISO-8601 `last_opened_at` decodes to `nil`
  without raising.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with {:ok, point} <- decode_point(map),
         {:ok, path} <- decode_path(map) do
      {:ok,
       %__MODULE__{
         point: point,
         path: path,
         name: decode_string(map, "name") || Path.basename(path),
         kind: decode_string(map, "kind") || "git",
         last_opened_at: decode_datetime(map)
       }}
    end
  end

  def from_map(_other), do: {:error, :invalid_mount}

  @doc """
  Encodes a mount as a STRING-keyed map suitable for JSON.

  `last_opened_at` is rendered as an ISO-8601 string (or `nil`).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = mount) do
    %{
      "point" => mount.point,
      "path" => mount.path,
      "name" => mount.name,
      "kind" => mount.kind,
      "last_opened_at" => encode_datetime(mount.last_opened_at)
    }
  end

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

  defp decode_path(map) do
    case fetch(map, "path") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _missing -> {:error, :invalid_path}
    end
  end

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

  ## Validation

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
