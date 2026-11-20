defmodule EvoGit.Store.Operations.Summaries do
  @moduledoc """
  Ecto port of the raw-SQL store's three summary-projection handlers —
  `EvoGit.Store.select_tasks_summary/3`, `select_tasks_summary_by_path/4`, and
  `select_tasks_changed_since/2` (unit R3b of the Store→Ecto migration).

  ## The 18-key projection contract

  Consumers are `EvoGit.TaskRegistry` (`list_tasks_summary/2`,
  `list_tasks_summary_by_path/3`, `list_tasks_changed_since/1`) and, through
  them, the `evo_dash` RPC surface. Every row is returned as a plain map with
  EXACTLY these keys:

      id, status, review_status, started_at, finished_at, type, project_path,
      opts, branch_name, model_id, agent_count, base_sha, commit_sha,
      lease_expires_at, updated_at, error, session_mode, pause_kind

  * `result` is DELIBERATELY NEVER selected — no summary consumer reads it (the
    dashboard's review button uses the denormalized `branch_name` column) and
    its JSON blob (usage included) is the heaviest per-row decode. A row with a
    huge or corrupt `result` column is returned by the summary path completely
    unaffected.
  * No other heavy JSON field (`logs`, `usage`) is read.
  * `updated_at` is returned as the RAW fixed-precision ISO string stored in
    the DB — byte-identical, NOT decoded to a `%DateTime{}`. Rows are selected
    through `EvoGit.Store.Schemas.TaskRowRaw` (the RAW wire-value twin) so a
    typed timestamp load can never round-trip the stored spelling.
  * `error` (16th key) is a cheap LENIENT decode (`Codec.decode_error/1`):
    `nil` for non-`:failed` rows, an atom-keyed map for `:failed` rows, and
    `nil` (never a crash) for undecodable text.
  * `session_mode` (17th key) is the task's driver mode — `"oneshot"` or
    `"interactive"`, normalized through `Codec.decode_session_mode/1` so a
    pre-migration NULL reads as `"oneshot"`. It is one short string, which is
    what lets the task list filter sessions without reading the full row.
  * `pause_kind` (18th key) is `:clean | :dirty | nil` — the paused task's
    pause kind, `nil` whenever the task is NOT paused, decoded through
    `Codec.decode_pause_kind/1` (total: an unknown spelling reads as `nil`).
    Like `session_mode` it is one short value, so a paused task reports its
    kind without any consumer paying for the full row decode.

  ## Filters (exact raw-SQL semantics)

    * `statuses` — a list of status ATOMS; `[]` means all statuses (no WHERE
      clause). Non-empty lists push the atoms down to SQL as their TEXT
      strings: `WHERE status IN ('running', ...)`.
    * `since` — an optional fixed-precision ISO string; when non-nil, only
      rows whose raw `updated_at` string is STRICTLY greater are returned
      (`WHERE updated_at > ?` lexicographic string comparison — the 24-char
      fixed-ms format sorts chronologically). `nil` means no filter.
    * `project_path` — exact TEXT equality (`WHERE project_path = ?`).

  No `ORDER BY` and no `LIMIT` by DEFAULT (the raw-SQL handlers never ordered
  or truncated; consumers sort/filter client-side). `select_tasks_summary/4`
  and `select_tasks_summary_by_path/5` accept ONE add-only option, `:limit`:
  a POSITIVE integer applies `ORDER BY updated_at DESC` and truncates to
  `min(n, 1_000)` rows (the implicit order exists only to make that
  truncation deterministic — it always accompanies a limit and is never added
  without one; `idx_tasks_updated_at` serves it). Any other `:limit` value
  (absent, `nil`, a non-integer, zero or negative) leaves the read EXACTLY as
  before: no order, no limit.

  ## Lenient per-row decode (skip + log)

  Rows are loaded as RAW wire values and decoded per-row through the Codec
  (`Codec` is the decode oracle). The Codec decoders RAISE by design on
  corrupt/legacy wire values (notably `decode_opts/1` on non-object JSON), so
  — through the SHARED `EvoGit.Store.Operations.Decoding` boundary — a row that
  raises is SKIPPED with a `Logger.warning` instead of poisoning the whole
  read. The lenient decoders (`decode_atom/1`, `decode_datetime/1`,
  `decode_error/1`) never raise, so only genuinely undecodable `opts` text
  trips the skip.

  Query errors under Ecto raise (the xqlite NIF error-tuple contract the old
  `_ -> []` arms handled does not exist under the adapter); this module adds
  no blanket rescue — a real database error surfaces to the caller.
  """

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Decoding
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw

  # Hard ceiling for the add-only `:limit` option: a bounded sidebar read, not
  # an unbounded history dump.
  @max_summary_limit 1_000

  @typedoc "One task row in the 18-key summary projection."
  @type summary :: %{
          required(:id) => String.t(),
          required(:status) => atom() | nil,
          required(:review_status) => atom() | nil,
          required(:started_at) => DateTime.t() | nil,
          required(:finished_at) => DateTime.t() | nil,
          required(:type) => atom() | nil,
          required(:project_path) => String.t() | nil,
          required(:opts) => keyword() | nil,
          required(:branch_name) => String.t() | nil,
          required(:model_id) => String.t() | nil,
          required(:agent_count) => integer() | nil,
          required(:base_sha) => String.t() | nil,
          required(:commit_sha) => String.t() | nil,
          required(:lease_expires_at) => integer() | nil,
          required(:updated_at) => String.t() | nil,
          required(:error) => map() | nil,
          required(:session_mode) => String.t(),
          required(:pause_kind) => :clean | :dirty | nil
        }

  @doc """
  Returns the 18-key summary projection for task rows, optionally filtered by
  `statuses` (atoms; `[]` = all) and `since` (strict raw-string
  `updated_at >` compare; `nil` = no filter).

  `opts` carries the ONE add-only option `:limit`: a positive integer applies
  `ORDER BY updated_at DESC` and truncates to `min(n, #{@max_summary_limit})`
  rows; any other value keeps the unbounded, unordered read.

  Undecodable rows are skipped and logged (see moduledoc).
  """
  @spec select_tasks_summary(pid(), [atom()], String.t() | nil, keyword()) :: [summary()]
  def select_tasks_summary(repo_pid, statuses, since, opts \\ []) when is_pid(repo_pid) do
    RepoScope.with_repo(repo_pid, fn ->
      summary_query()
      |> where_statuses(statuses)
      |> where_since(since)
      |> maybe_limit(opts)
      |> Repo.all()
      |> decode_skipping_bad()
    end)
  end

  @doc """
  Same as `select_tasks_summary/4` but restricted to rows whose
  `project_path` equals `project_path` (exact TEXT equality), then optionally
  filtered by `statuses` and `since` as in `select_tasks_summary/4`.
  """
  @spec select_tasks_summary_by_path(pid(), String.t(), [atom()], String.t() | nil, keyword()) ::
          [summary()]
  def select_tasks_summary_by_path(repo_pid, project_path, statuses, since, opts \\ [])
      when is_pid(repo_pid) do
    RepoScope.with_repo(repo_pid, fn ->
      summary_query()
      |> where([t], t.project_path == ^project_path)
      |> where_statuses(statuses)
      |> where_since(since)
      |> maybe_limit(opts)
      |> Repo.all()
      |> decode_skipping_bad()
    end)
  end

  @doc """
  Returns the 18-key summary projection for all tasks whose raw `updated_at`
  string is strictly newer than `since_iso` (lexicographic string comparison;
  the fixed-precision 24-char ISO format sorts chronologically).
  """
  @spec select_tasks_changed_since(pid(), String.t()) :: [summary()]
  def select_tasks_changed_since(repo_pid, since_iso) when is_pid(repo_pid) do
    RepoScope.with_repo(repo_pid, fn ->
      summary_query()
      |> where_since(since_iso)
      |> Repo.all()
      |> decode_skipping_bad()
    end)
  end

  ## Query building

  # The 18-column summary projection, selected through the RAW wire-value twin
  # so every value comes back as the exact bytes SQLite stored (the raw store's
  # @summary_columns SELECT). `result`, `logs` and `usage` are deliberately not
  # selected.
  #
  # Public (but `@doc false`) so the LIGHTWEIGHT paged read
  # (`EvoGit.Store.Operations.Pages.select_tasks_page/2`) reuses THIS canonical
  # projection + its per-row decode instead of inventing a second one.
  @doc false
  @spec summary_query() :: Ecto.Query.t()
  def summary_query do
    from(t in TaskRowRaw,
      select: %{
        id: t.id,
        status: t.status,
        review_status: t.review_status,
        started_at: t.started_at,
        finished_at: t.finished_at,
        type: t.type,
        project_path: t.project_path,
        opts: t.opts,
        branch_name: t.branch_name,
        model_id: t.model_id,
        agent_count: t.agent_count,
        base_sha: t.base_sha,
        commit_sha: t.commit_sha,
        lease_expires_at: t.lease_expires_at,
        updated_at: t.updated_at,
        error: t.error,
        session_mode: t.session_mode,
        pause_kind: t.pause_kind
      }
    )
  end

  # `statuses = []` emits NO clause (all statuses) — mirrors the raw store's
  # build_status_where([]) arm. Non-empty lists push the status ATOMS down to
  # SQL as their TEXT strings (`WHERE status IN (...)`).
  defp where_statuses(query, []), do: query

  defp where_statuses(query, statuses) do
    where(query, [t], t.status in ^Enum.map(statuses, &Atom.to_string/1))
  end

  # `since = nil` emits NO clause; otherwise a STRICT `>` comparison on the raw
  # fixed-precision ISO text (string comparison — chronological because of the
  # constant 24-char format).
  defp where_since(query, nil), do: query
  defp where_since(query, since), do: where(query, [t], t.updated_at > ^since)

  # The add-only `:limit` option (see the moduledoc): a POSITIVE integer bounds
  # the read and — because truncation needs a well-defined "which rows" answer —
  # brings an implicit `updated_at DESC` order (`idx_tasks_updated_at` serves
  # it). Every other value (absent, `nil`, non-integer, `<= 0`) leaves the
  # query byte-identical to the unbounded read: no order, no limit.
  defp maybe_limit(query, opts) when is_list(opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 ->
        query
        |> order_by([t], desc: t.updated_at)
        |> limit(^min(limit, @max_summary_limit))

      _ ->
        query
    end
  end

  defp maybe_limit(query, _other), do: query

  @doc """
  Restricts a query to rows whose `opts` column can be DECODED — i.e. the rows
  `decode_skipping_bad/1` will not drop.

  `Codec.decode_opts/1` raises only for a non-NULL `opts` that is not a JSON
  OBJECT (invalid JSON, a legacy pair-array, a scalar), so this predicate is
  exactly "renderable": `opts IS NULL OR json_valid(opts) AND
  json_type(opts) = 'object'`. Paging reads apply it to the COUNT and to the
  page selection alike, so `total` and the renderable rows can never disagree
  (a corrupt row is excluded from both instead of inflating the total).
  SQLite's JSON1 functions (`json_valid`, `json_type`) are available in the
  bundled SQLite (>= 3.38 ships JSON1 unconditionally).
  """
  @spec where_renderable(Ecto.Query.t()) :: Ecto.Query.t()
  def where_renderable(query) do
    where(
      query,
      [t],
      is_nil(t.opts) or
        fragment("json_valid(?) AND json_type(?) = 'object'", t.opts, t.opts)
    )
  end

  ## Decode

  # Decodes one row of the 18-column RAW projection — a field-for-field port
  # of the raw store's decode_summary_row/1: atoms/datetimes/opts/error through
  # the Codec (the decode oracle), scalars and the RAW `updated_at` string
  # passed through untouched.
  defp decode_summary_row(row) do
    %{
      id: row.id,
      status: Codec.decode_atom(row.status),
      review_status: Codec.decode_atom(row.review_status),
      started_at: Codec.decode_datetime(row.started_at),
      finished_at: Codec.decode_datetime(row.finished_at),
      type: Codec.decode_atom(row.type),
      project_path: row.project_path,
      opts: Codec.decode_opts(row.opts),
      branch_name: row.branch_name,
      model_id: row.model_id,
      agent_count: row.agent_count,
      base_sha: row.base_sha,
      commit_sha: row.commit_sha,
      lease_expires_at: row.lease_expires_at,
      updated_at: row.updated_at,
      error: Codec.decode_error(row.error),
      session_mode: Codec.decode_session_mode(row.session_mode),
      pause_kind: Codec.decode_pause_kind(row.pause_kind)
    }
  end

  # Lenient per-row decode boundary — the SHARED skip-and-log rule
  # (`EvoGit.Store.Operations.Decoding`, which owns the justified per-row
  # try/rescue): rows whose Codec decode RAISES (by design, e.g. non-object
  # `opts` JSON) are skipped with a warning instead of crashing the whole read.
  #
  # Public (but `@doc false`) so the lightweight paged read shares the EXACT
  # same skip-and-log boundary as the summary reads.
  @doc false
  @spec decode_skipping_bad([map()]) :: [summary()]
  def decode_skipping_bad(rows) do
    Decoding.decode_skipping_bad(rows, "tasks", & &1.id, &decode_summary_row/1)
  end
end
