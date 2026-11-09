defmodule EvoGit.Store.Schemas.VctMountRow do
  @moduledoc """
  Ecto schema for the `vct_mounts` table — ONE row per Virtual Context Tree
  project mount. A PERSISTENCE-ROW struct, not a domain struct.

  Nothing outside the store layer should ever see a `VctMountRow`:
  `EvoGit.Store.Operations.VctMounts` translates it to the STRING-KEYED entry
  maps the facade (`list_vct_mounts/1`) returns and accepts, and
  `EvoGit.VCT` translates those into `EvoGit.VCT.Mount` structs.

  `point` is the canonical VCT URL (`vct:///projects/foo`) and the TEXT primary
  key (no autogenerate), so a mount point can never be duplicated. `path` is
  the absolute OS path the point is bound to and is UNIQUE — two points never
  claim one directory. `kind` is a plain string (`"git"` today) and
  `last_opened_at` a `TaskTimestamp` (DateTime ↔ fixed-millisecond ISO-8601
  TEXT, the wire format shared by every timestamp column in this store).

  There is NO `timestamps()`: a mount carries only its own `last_opened_at`.
  """

  use Ecto.Schema

  alias EvoGit.Store.Types

  @primary_key {:point, :string, autogenerate: false}
  schema "vct_mounts" do
    field(:path, :string)
    field(:name, :string)
    field(:kind, :string, default: "git")
    field(:last_opened_at, Types.TaskTimestamp)
  end

  @doc """
  The 5 `vct_mounts` column names (strings) in schema-declaration order —
  the physical table column order declared by the migration.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end
