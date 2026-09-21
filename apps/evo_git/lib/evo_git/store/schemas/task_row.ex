defmodule EvoGit.Store.Schemas.TaskRow do
  @moduledoc """
  Ecto schema for the `tasks` table — a PERSISTENCE-ROW struct, not a domain
  struct.

  `EvoGit.Store` translates `TaskRow ↔ %EvoGit.TaskInfo{}` in wave 2; nothing
  outside the store layer should ever see a `TaskRow`. The field set mirrors
  `Codec.task_columns/0` plus the store-internal `updated_at` (the table's
  20th column, deliberately NOT in `Codec.task_columns/0` / `%TaskInfo{}`).

  ## Column → type mapping

  | column             | type                          | notes |
  |--------------------|-------------------------------|-------|
  | `id`               | `:string` (PK)                | task id, no autogenerate |
  | `type`             | `TaskType`                    | atom ↔ TEXT |
  | `status`           | `Status`                      | atom ↔ TEXT |
  | `opts`             | `OptsJson`                    | keyword ↔ JSON object |
  | `started_at`       | `TaskTimestamp`               | DateTime ↔ fixed-ms ISO TEXT |
  | `finished_at`      | `TaskTimestamp`               | DateTime ↔ fixed-ms ISO TEXT |
  | `logs`             | `LogsJson`                    | list ↔ JSON array (nil dumps `"[]"`) |
  | `result`           | `ResultJson`                  | 4-form `__result_tag__` envelope |
  | `review_status`    | `ReviewStatus`                | atom ↔ TEXT |
  | `usage`            | `UsageJson`                   | `%EvoGit.Agent.Usage{}` ↔ JSON |
  | `agent_count`      | `:integer`                    | plain |
  | `base_sha`         | `:string`                     | plain |
  | `commit_sha`       | `:string`                     | plain |
  | `archive_metadata` | `ArchiveJson`                 | list of maps ↔ JSON array |
  | `lease_expires_at` | `UnixMs`                      | unix-ms INTEGER |
  | `model_id`         | `:string`                     | plain |
  | `project_path`     | `:string`                     | plain |
  | `branch_name`      | `:string`                     | plain |
  | `error`            | `ErrorJson`                   | map ↔ JSON object (lenient decode) |
  | `updated_at`       | `TaskTimestampRaw`            | store-internal, RAW-string load |

  There is NO `timestamps()` — `updated_at` is a plain field the Store manages
  on every targeted column update (see `EvoGit.Store.update_task_columns/3`),
  and it loads as the raw ISO string because the changed-since queries
  string-compare it in SQL.

  Loading a row with corrupt `opts`/`result` text raises `ArgumentError` (the
  Codec's strictly-canonical decode contract); wave-2 Store code is expected
  to rescue/skip like the current safe-select helpers do.
  """

  use Ecto.Schema

  alias EvoGit.Store.Types

  @primary_key {:id, :string, autogenerate: false}
  schema "tasks" do
    field(:type, Types.TaskType)
    field(:status, Types.Status)
    field(:opts, Types.OptsJson)
    field(:started_at, Types.TaskTimestamp)
    field(:finished_at, Types.TaskTimestamp)
    field(:logs, Types.LogsJson)
    field(:result, Types.ResultJson)
    field(:review_status, Types.ReviewStatus)
    field(:usage, Types.UsageJson)
    field(:agent_count, :integer)
    field(:base_sha, :string)
    field(:commit_sha, :string)
    field(:archive_metadata, Types.ArchiveJson)
    field(:lease_expires_at, Types.UnixMs)
    field(:model_id, :string)
    field(:project_path, :string)
    field(:branch_name, :string)
    field(:error, Types.ErrorJson)
    field(:updated_at, Types.TaskTimestampRaw)
  end

  @doc """
  The 20 task-table column names (strings) in schema-declaration order —
  equals `Codec.task_columns/0 ++ ["updated_at"]`, the physical table column
  order. Returns strings to mirror `Codec.task_columns/0` exactly.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end

defmodule EvoGit.Store.Schemas.ProjectRow do
  @moduledoc """
  Ecto schema for the `projects` table — a PERSISTENCE-ROW struct, not a
  domain struct.

  `EvoGit.Store` translates `ProjectRow ↔ %EvoGit.RecentProject{}` in wave 2;
  nothing outside the store layer should ever see a `ProjectRow`. The field
  set mirrors `Codec.project_columns/0`.

  `path` is the TEXT primary key (no autogenerate); `name` is plain TEXT;
  `last_opened_at` is a `TaskTimestamp` (DateTime ↔ fixed-millisecond ISO-8601
  TEXT — same wire format as every other timestamp column). No `timestamps()`.
  """

  use Ecto.Schema

  alias EvoGit.Store.Types

  @primary_key {:path, :string, autogenerate: false}
  schema "projects" do
    field(:name, :string)
    field(:last_opened_at, Types.TaskTimestamp)
  end

  @doc """
  The 3 project-table column names (strings) in schema-declaration order —
  equals `Codec.project_columns/0`. Returns strings to mirror
  `Codec.project_columns/0` exactly.
  """
  def columns, do: Enum.map(__schema__(:fields), &Atom.to_string/1)
end
