defmodule EvoGit.Store.Operations.Filters do
  @moduledoc """
  The ONE task-list WHERE builder + pagination clamps, shared by every paged
  task read:

    * `EvoGit.Store.Operations.Tasks.safe_select_paginated_tasks/2` (the FULL
      `%TaskInfo{}` page — the legacy dashboard read), and
    * `EvoGit.Store.Operations.Pages.select_tasks_page/2` (the LIGHTWEIGHT
      16-key summary page).

  Extracted so the two reads can never diverge on which rows they match: both
  apply `where_filters/2` to a `TaskRowRaw`-rooted query (a `COUNT(*)` base or
  a projection), so a filter fix lands in exactly one place.

  ## Filters (raw-SQL semantics, unchanged)

    * `:status` (default `"all"`) — exact TEXT equality on the stored status
      string (dashboard filters pass the string spelling; `"all"` = no clause).
    * `:project_path` (default `"all"`) — exact TEXT equality.
    * `:review_status` (default `"all"`) — `"pending"` is the COMPOSITE
      `status = 'completed' AND review_status IS NULL AND branch_name IS NOT
      NULL` (completed tasks with no review whose row carries a branch →
      awaiting review); any other value is exact TEXT equality.
    * `:search` (`nil`/`""` = no clause) — ONE runtime `fragment/1`: a
      case-insensitive OR-LIKE over **`id`, `opts`, `project_path`,
      `branch_name`** with the escaped pattern `%<escaped search>%` and
      the escape char pinned as a bound parameter (`ESCAPE ?`).

  ## Search behaviour change (deliberate)

  `result` is NO LONGER searched. It is a full-blob column that the Codec
  transparently zlib-compresses above 4 kB (`"z1:" <> base64`), so a LIKE over
  it is both (a) a scan of the heaviest column in the table — one live row held
  108 MB of `result` — and (b) semantically wrong for compressed rows, whose
  stored text is base64 with no user-visible substring in it. The denormalized
  `branch_name` column replaces it: it is the branch a task produced (already
  exposed on the summary projection and used by the review flow), it is small,
  and it is what users actually search for ("which task produced
  `genesis/agent_ab12`?"). A phrase that exists ONLY inside a task's `result`
  text therefore no longer matches; phrases in the objective (`opts`), the id,
  the project path and the branch name still do.

  The escape char must be pinned as a PARAMETER, never written as the SQL
  literal `'\\'`: the adapter doubles backslashes inside SQL string literals,
  which SQLite then rejects ("ESCAPE expression must be a single character").
  """

  import Ecto.Query

  # Legacy (`safe_select_paginated_tasks/2`) limit default — unchanged.
  @default_limit 50

  # Lightweight page defaults: a dashboard-sized page of at most 50 summary
  # rows (25 when the caller gives no/invalid limit). Deliberately separate
  # from @default_limit so extracting this module could not change the legacy
  # read's behaviour.
  @page_default_limit 25
  @page_max_limit 50

  @doc "Legacy pagination clamp: non-integer or non-positive → 50."
  @spec clamp_limit(term()) :: pos_integer()
  def clamp_limit(nil), do: @default_limit
  def clamp_limit(n) when is_integer(n) and n > 0, do: n
  def clamp_limit(_), do: @default_limit

  @doc """
  Lightweight-page limit clamp: `nil`/invalid/non-positive → #{@page_default_limit},
  a positive integer is capped at #{@page_max_limit}.
  """
  @spec clamp_page_limit(term()) :: pos_integer()
  def clamp_page_limit(nil), do: @page_default_limit

  def clamp_page_limit(n) when is_integer(n) and n > 0, do: min(n, @page_max_limit)

  def clamp_page_limit(_), do: @page_default_limit

  @doc "Offset clamp: `nil`, negative or non-integer → 0."
  @spec clamp_offset(term()) :: non_neg_integer()
  def clamp_offset(nil), do: 0
  def clamp_offset(n) when is_integer(n) and n >= 0, do: n
  def clamp_offset(_), do: 0

  @doc """
  Applies the task-list filter set (see the moduledoc) to a `TaskRowRaw`-rooted
  query. `filters` is a keyword list; absent keys mean "no clause".
  """
  @spec where_filters(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  def where_filters(query, filters) when is_list(filters) do
    query
    |> where_status_filter(Keyword.get(filters, :status, "all"))
    |> where_path_filter(Keyword.get(filters, :project_path, "all"))
    |> where_review_status_filter(Keyword.get(filters, :review_status, "all"))
    |> where_search_filter(Keyword.get(filters, :search))
  end

  defp where_status_filter(query, "all"), do: query
  defp where_status_filter(query, status), do: where(query, [t], t.status == ^status)

  defp where_path_filter(query, "all"), do: query
  defp where_path_filter(query, path), do: where(query, [t], t.project_path == ^path)

  defp where_review_status_filter(query, "all"), do: query

  defp where_review_status_filter(query, "pending") do
    # The composite "pending review" predicate — literal 'completed' pushdown,
    # exactly as written.
    where(
      query,
      [t],
      t.status == "completed" and is_nil(t.review_status) and
        not is_nil(t.branch_name)
    )
  end

  defp where_review_status_filter(query, review_status) do
    where(query, [t], t.review_status == ^review_status)
  end

  defp where_search_filter(query, search) when search in [nil, ""], do: query

  defp where_search_filter(query, search) do
    pat = "%#{escape_like(search)}%"

    # A single literal fragment — the 4-column OR-LIKE (id, opts, project_path,
    # branch_name) with the escape char pinned as a bound parameter. `result` is
    # deliberately absent (see the moduledoc's behaviour-change note).
    where(
      query,
      [t],
      fragment(
        "(? LIKE ? ESCAPE ? OR ? LIKE ? ESCAPE ? OR ? LIKE ? ESCAPE ? OR ? LIKE ? ESCAPE ?)",
        t.id,
        ^pat,
        ^"\\",
        t.opts,
        ^pat,
        ^"\\",
        t.project_path,
        ^pat,
        ^"\\",
        t.branch_name,
        ^pat,
        ^"\\"
      )
    )
  end

  # Escapes the SQL LIKE-special characters (`%`, `_`, `\`) by prefixing them
  # with a backslash — used together with `ESCAPE '\'` on the LIKE fragment so
  # user-supplied values (e.g. project paths containing underscores) match
  # literally instead of acting as wildcards.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
