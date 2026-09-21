defmodule EvoGit.Store.Schemas.TaskRowRaw do
  @moduledoc """
  RAW wire-value Ecto schema for the `tasks` table — the read-projection twin
  of `EvoGit.Store.Schemas.TaskRow`.

  Every field is a PLAIN `:string`/`:integer` type: no `EvoGit.Store.Types.*`
  casting, no atom recovery, no DateTime parsing, no JSON decode. A row loaded
  through this schema holds EXACTLY the bytes SQLite stored. The field list,
  order, and primary key mirror `TaskRow` 1:1 — only the types differ.

  ## Why a raw twin exists

    * **Per-row safe decode** — `EvoGit.Store.Codec` decode is strictly
      canonical and RAISES on bad data. The safe-select helpers must load rows
      as raw column values, decode each row through `Codec` individually, and
      skip (log a warning) the ones that raise — so one corrupt row never
      poisons a whole `list_tasks` read. Loading through `TaskRow` would raise
      inside Ecto's loader, before any per-row rescue could run.
    * **Byte-identical `updated_at`** — the summary projections return
      `updated_at` as the RAW fixed-precision ISO string (SQL string
      comparison, `updated_at > ?` changed-since queries). Loading it through
      `TaskTimestamp` would round-trip a `%DateTime{}` and lose the stored
      spelling; the raw select keeps the exact stored bytes.

  ## Read-projection only

  Because the fields are plain types, an INSERT/UPDATE through this schema
  would write UNENCODED values (raw keyword lists where the wire format
  expects JSON text, ISO strings where atoms are expected, ...). Writes must
  go through `TaskRow` (typed dump) or `Codec.encode_task/1` directly. There
  is NO `timestamps()` macro — `updated_at` is a plain field the Store manages.

  ## Column → raw type mapping

  | column             | raw type     | typed counterpart in `TaskRow`  |
  |--------------------|--------------|---------------------------------|
  | `id`               | `:string` PK | `:string` (PK, no autogenerate) |
  | `type`             | `:string`    | `TaskType` (atom ↔ TEXT)        |
  | `status`           | `:string`    | `Status` (atom ↔ TEXT)          |
  | `opts`             | `:string`    | `OptsJson` (JSON TEXT)          |
  | `started_at`       | `:string`    | `TaskTimestamp` (ISO TEXT)      |
  | `finished_at`      | `:string`    | `TaskTimestamp` (ISO TEXT)      |
  | `logs`             | `:string`    | `LogsJson` (JSON TEXT)          |
  | `result`           | `:string`    | `ResultJson` (JSON TEXT)        |
  | `review_status`    | `:string`    | `ReviewStatus` (atom ↔ TEXT)    |
  | `usage`            | `:string`    | `UsageJson` (JSON TEXT)         |
  | `agent_count`      | `:integer`   | `:integer`                      |
  | `base_sha`         | `:string`    | `:string`                       |
  | `commit_sha`       | `:string`    | `:string`                       |
  | `archive_metadata` | `:string`    | `ArchiveJson` (JSON TEXT)       |
  | `lease_expires_at` | `:integer`   | `UnixMs` (unix-ms INTEGER)      |
  | `model_id`         | `:string`    | `:string`                       |
  | `project_path`     | `:string`    | `:string`                       |
  | `branch_name`      | `:string`    | `:string`                       |
  | `error`            | `:string`    | `ErrorJson` (JSON TEXT)         |
  | `updated_at`       | `:string`    | `TaskTimestampRaw` (ISO TEXT)   |
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "tasks" do
    # Field ORDER mirrors TaskRow 1:1 (== the physical table column order);
    # the string PK `id` comes from @primary_key above. The type GROUPS
    # (atom-TEXT / JSON-TEXT / ISO-TEXT / plain scalar) interleave in the
    # physical order, so each field carries its wire-family as a trailing
    # comment instead of a per-group block.
    field(:type, :string)
    field(:status, :string)
    field(:opts, :string)
    field(:started_at, :string)
    field(:finished_at, :string)
    field(:logs, :string)
    field(:result, :string)
    field(:review_status, :string)
    field(:usage, :string)
    field(:agent_count, :integer)
    field(:base_sha, :string)
    field(:commit_sha, :string)
    field(:archive_metadata, :string)
    field(:lease_expires_at, :integer)
    field(:model_id, :string)
    field(:project_path, :string)
    field(:branch_name, :string)
    field(:error, :string)
    field(:updated_at, :string)
  end

  @doc """
  The 20 task-table column names (strings) in schema-declaration order —
  identical to `EvoGit.Store.Schemas.TaskRow.columns/0` (the physical table
  column order). Returns strings to mirror `Codec.task_columns/0` exactly.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end

defmodule EvoGit.Store.Schemas.ProjectRowRaw do
  @moduledoc """
  RAW wire-value Ecto schema for the `projects` table — the read-projection
  twin of `EvoGit.Store.Schemas.ProjectRow`.

  Same rationale as `EvoGit.Store.Schemas.TaskRowRaw`: plain `:string` fields
  (no `Types.TaskTimestamp` casting) so a row loads as the exact bytes SQLite
  stored, enabling per-row safe decode through `Codec.decode_project/1` (one
  bad row is skipped, not fatal) and byte-identical timestamp strings.
  READ-PROJECTION ONLY — writes go through `ProjectRow` or
  `Codec.encode_project/1`. No `timestamps()` macro.
  """

  use Ecto.Schema

  @primary_key {:path, :string, autogenerate: false}
  schema "projects" do
    # Plain TEXT columns; the string PK `path` comes from @primary_key above
    # (mirrors ProjectRow).
    field(:name, :string)

    # ISO-8601 TEXT timestamp — raw fixed-precision string, never parsed.
    field(:last_opened_at, :string)
  end

  @doc """
  The 3 project-table column names (strings) in schema-declaration order —
  identical to `EvoGit.Store.Schemas.ProjectRow.columns/0`. Returns strings to
  mirror `Codec.project_columns/0` exactly.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end
