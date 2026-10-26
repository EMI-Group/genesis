defmodule EvoGit.Store.Schemas.TaskAgentArchiveRow do
  @moduledoc """
  Ecto schema for the `task_agent_archives` table — ONE row per (task, agent)
  archived agent. A PERSISTENCE-ROW struct, not a domain struct.

  Nothing outside the store layer should ever see a `TaskAgentArchiveRow`:
  `EvoGit.Store.Operations.Archives` translates it to the STRING-KEYED entry
  maps the facade (`put_task_archive/2`, `list_task_archives/3`,
  `get_agent_archive/3`, `delete_task_archives/2`) returns and accepts.

  ## Composite primary key

  `@primary_key false` plus two `primary_key: true` fields gives the
  `(task_id, agent_id)` composite key the table declares — the reason a
  re-put of an existing pair REPLACES it (`INSERT … ON CONFLICT DO UPDATE`)
  instead of adding a duplicate row.

  ## Column → type mapping

  | column               | type                     | notes |
  |----------------------|--------------------------|-------|
  | `task_id`            | `:string` (PK)           | no autogenerate |
  | `agent_id`           | `:integer` (PK)          | no autogenerate |
  | `parent_id`          | `:integer`               | spawn-tree parent agent id |
  | `depth`              | `:integer`               | NOT NULL DEFAULT 0, root = 0 |
  | `agent_type`         | `:string`                | plain |
  | `context_node_path`  | `:string`                | plain |
  | `objective`          | `:string`                | plain |
  | `result`             | `:string`                | the heavy column — paged out on roster reads |
  | `base_commit`        | `:string`                | plain |
  | `final_commit`       | `:string`                | plain |
  | `branch_name`        | `:string`                | plain |
  | `archive_ref_start`  | `:string`                | plain |
  | `archive_ref_final`  | `:string`                | plain |
  | `repo_id`            | `:integer`               | plain |
  | `repo_root`          | `:string`                | plain |
  | `repo_path`          | `:string`                | plain |
  | `usage`              | `ArchiveUsageJson`       | plain JSON object (no `%Usage{}` struct) |
  | `llm_settings`       | `ArchiveLlmSettingsJson` | plain JSON object |
  | `agent_settings`     | `ArchiveAgentSettingsJson` | plain JSON object |
  | `foreign_repos`      | `ArchiveForeignReposJson` | plain JSON array of objects |
  | `compression_count`  | `:integer`               | NOT NULL DEFAULT 0 |
  | `started_at`         | `:string`                | ISO-8601 TEXT, stored/read as-is |
  | `completed_at`       | `:string`                | ISO-8601 TEXT, stored/read as-is |

  There is NO `timestamps()`: `started_at`/`completed_at` are the archive's
  own ISO-8601 strings, kept as TEXT so a read returns exactly the bytes that
  were written (no re-formatting round trip). The JSON columns use the plain
  `EvoGit.Store.Types.ArchiveColumns.*` types — no Codec, no `"z1:"`
  compression (see that module's moduledoc for why).
  """

  use Ecto.Schema

  alias EvoGit.Store.Types

  @primary_key false
  schema "task_agent_archives" do
    field(:task_id, :string, primary_key: true)
    field(:agent_id, :integer, primary_key: true)
    field(:parent_id, :integer)
    field(:depth, :integer)
    field(:agent_type, :string)
    field(:context_node_path, :string)
    field(:objective, :string)
    field(:result, :string)
    field(:base_commit, :string)
    field(:final_commit, :string)
    field(:branch_name, :string)
    field(:archive_ref_start, :string)
    field(:archive_ref_final, :string)
    field(:repo_id, :integer)
    field(:repo_root, :string)
    field(:repo_path, :string)
    field(:usage, Types.ArchiveUsageJson)
    field(:llm_settings, Types.ArchiveLlmSettingsJson)
    field(:agent_settings, Types.ArchiveAgentSettingsJson)
    field(:foreign_repos, Types.ArchiveForeignReposJson)
    field(:compression_count, :integer)
    field(:started_at, :string)
    field(:completed_at, :string)
  end

  @doc """
  The 23 archive-table column names (strings) in schema-declaration order —
  the physical table column order declared by the migration.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end
