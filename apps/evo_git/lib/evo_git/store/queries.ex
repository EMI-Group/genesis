defmodule EvoGit.Store.Queries do
  @moduledoc """
  SQL builder helpers for the EvoGit SQLite store.

  Pure functions — no GenServer, no I/O. Builds SELECT strings, WHERE clauses,
  UPDATE SET clauses, and encodes individual column values for SQL parameters.
  """

  alias EvoGit.Store.Codec

  @doc """
  Returns a SELECT SQL string for all task columns.
  """
  def task_select_sql do
    "SELECT #{Enum.join(Codec.task_columns(), ", ")} FROM tasks"
  end

  @doc """
  Returns a SELECT SQL string for all project columns.
  """
  def project_select_sql do
    "SELECT #{Enum.join(Codec.project_columns(), ", ")} FROM projects"
  end

  @doc """
  Builds the SET clause and value list for a targeted UPDATE from a keyword
  list of column names to values. Each value is encoded through the
  appropriate Codec.encode_* function based on column semantics:
  atoms, datetimes, lists/maps get encoded; scalars pass through as-is.
  """
  def build_update_set(columns, start_idx) do
    {clauses, values, _idx} =
      Enum.reduce(columns, {[], [], start_idx}, fn {col, value}, {clauses, values, idx} ->
        encoded = encode_column_value(col, value)
        clause = "#{col} = ?#{idx}"
        {[clause | clauses], [encoded | values], idx + 1}
      end)

    {Enum.join(Enum.reverse(clauses), ", "), Enum.reverse(values)}
  end

  @doc """
  Encodes a column value for an UPDATE SET clause. Uses the same Codec
  functions as encode_task for consistency.
  """
  def encode_column_value(_col, nil), do: nil

  def encode_column_value(:status, value), do: Codec.encode_atom(value)
  def encode_column_value(:type, value), do: Codec.encode_atom(value)
  def encode_column_value(:review_status, value), do: Codec.encode_atom(value)
  def encode_column_value(:started_at, value), do: Codec.encode_datetime(value)
  def encode_column_value(:finished_at, value), do: Codec.encode_datetime(value)
  def encode_column_value(:logs, value), do: Codec.encode_logs(value)
  def encode_column_value(:result, value), do: Codec.encode_result(value)
  def encode_column_value(:usage, value), do: Codec.encode_usage(value)
  def encode_column_value(:opts, value), do: Codec.encode_opts(value)
  def encode_column_value(:archive_metadata, value), do: Codec.encode_archive(value)
  def encode_column_value(:project_path, value), do: value
  def encode_column_value(:branch_name, value), do: value
  def encode_column_value(:agent_count, value), do: value
  def encode_column_value(:lease_expires_at, value), do: value
  def encode_column_value(:model_id, value), do: value
  def encode_column_value(:base_sha, value), do: value
  def encode_column_value(:commit_sha, value), do: value
  def encode_column_value(_col, value), do: value

  # ── Pagination clamping ──────────────────────────────────────────────

  @doc """
  Ensures limit is a positive integer (default 50). Non-integer or
  non-positive values fall back to the default.
  """
  def clamp_limit(nil), do: 50
  def clamp_limit(n) when is_integer(n) and n > 0, do: n
  def clamp_limit(_), do: 50

  @doc """
  Ensures offset is a non-negative integer (default 0). Non-integer or
  negative values fall back to 0.
  """
  def clamp_offset(nil), do: 0
  def clamp_offset(n) when is_integer(n) and n >= 0, do: n
  def clamp_offset(_), do: 0

  # ── WHERE clause builder ─────────────────────────────────────────────

  @doc """
  Builds a SQL WHERE clause (with leading space) and an ordered param list
  from the filters keyword list. Returns `{"", []}` when no filters apply.

  ## Filters

    * `:status` — atom/string status or `"all"` (default `"all"`)
    * `:project_path` — path string or `"all"` (default `"all"`)
    * `:review_status` — `"all"`, `"pending"`, `"merged"`, `"rejected"`, `"continued"`
    * `:search` — non-empty search string; matches id or opts JSON text

  Placeholders use incremental `?N` indexing so LIMIT/OFFSET can append their
  own placeholders after the WHERE params.
  """
  def build_where(filters) do
    # status filter
    {clauses, params, idx} =
      case Keyword.get(filters, :status, "all") do
        "all" ->
          {[], [], 1}

        status ->
          {["status = ?1"], [status], 2}
      end

    # project_path filter — matches the denormalized project_path column
    {clauses, params, idx} =
      case Keyword.get(filters, :project_path, "all") do
        "all" ->
          {clauses, params, idx}

        path ->
          {clauses ++ ["project_path = ?" <> Integer.to_string(idx)],
           params ++ [path], idx + 1}
      end

    # review_status filter ("pending" is a composite of completed + null review + branch)
    {clauses, params, idx} =
      case Keyword.get(filters, :review_status, "all") do
        "all" ->
          {clauses, params, idx}

        "pending" ->
          # Completed tasks with no review status whose result contains a
          # branch_name (meaning they're awaiting review).
          c1 = "status = ?" <> Integer.to_string(idx)
          c2 = "review_status IS NULL"
          c3 = "branch_name IS NOT NULL"

          {clauses ++ [c1, c2, c3],
           params ++ ["completed"], idx + 1}

        rs ->
          {clauses ++ ["review_status = ?" <> Integer.to_string(idx)], params ++ [rs], idx + 1}
      end

    # search filter — matches id, raw opts JSON text, or project_path
    {clauses, params, _idx} =
      case Keyword.get(filters, :search) do
        nil ->
          {clauses, params, idx}

        "" ->
          {clauses, params, idx}

        search ->
          pat = "%#{escape_like(search)}%"
          c1 = "id LIKE ?" <> Integer.to_string(idx) <> " ESCAPE '\\'"
          c2 = "opts LIKE ?" <> Integer.to_string(idx + 1) <> " ESCAPE '\\'"
          c3 = "project_path LIKE ?" <> Integer.to_string(idx + 2) <> " ESCAPE '\\'"
          {clauses ++ ["(#{c1} OR #{c2} OR #{c3})"], params ++ [pat, pat, pat], idx + 3}
      end

    case clauses do
      [] -> {"", []}
      _ -> {" WHERE " <> Enum.join(clauses, " AND "), params}
    end
  end

  @doc """
  Escapes the SQL LIKE-special characters (`%`, `_`, `\\`) by prefixing them
  with a backslash. Used together with `ESCAPE '\\'` on LIKE clauses so that
  user-supplied values (e.g. project paths containing underscores) are matched
  literally instead of being interpreted as wildcards.
  """
  def escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
