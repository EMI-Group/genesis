defmodule EvoGit.Store.Schemas.VctMountRow do
  @moduledoc """
  Ecto schema for the `vct_mounts` table — ONE row per Virtual Context Tree
  mount. A PERSISTENCE-ROW struct, not a domain struct.

  Nothing outside the store layer should ever see a `VctMountRow`:
  `EvoGit.Store.Operations.VctMounts` translates it to the STRING-KEYED entry
  maps the facade (`list_vct_mounts/1`) returns and accepts, and
  `EvoGit.VCT` translates those into `EvoGit.VCT.Mount` structs.

  `point` is the canonical VCT URL (`vct:///projects/foo`) and the TEXT primary
  key (no autogenerate), so a mount point can never be duplicated. `path` is
  the absolute OS path a GIT mount binds to and is UNIQUE — two points never
  claim one directory — but it is NULLABLE: a WORKSPACE mount groups other
  mounts and has no OS path of its own (SQLite allows many NULLs under a
  UNIQUE index). `kind` is a plain string (`"git"` today, `"workspace"` for a
  workspace) and `last_opened_at` a `TaskTimestamp` (DateTime ↔
  fixed-millisecond ISO-8601 TEXT, the wire format shared by every timestamp
  column in this store).

  `members` is the workspace's ORDERED member list as JSON TEXT (a JSON array
  of STRING-KEYED maps; `NULL` for a mount with no members — the operations
  module decodes it to `[]` and encodes `[]` back), and `description` an
  optional free-text note (`NULL` when absent). Both are NULLABLE, and both
  carry NO Ecto type of their own: the JSON boundary lives in
  `EvoGit.Store.Operations.VctMounts`, so this schema stays plain TEXT.

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
    field(:members, :string)
    field(:description, :string)
  end

  @doc """
  The 7 `vct_mounts` column names (strings) in schema-declaration order —
  the physical table column order declared by the migration.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end
