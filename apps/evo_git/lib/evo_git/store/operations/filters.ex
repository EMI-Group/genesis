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
    * `:session_mode` (default `"all"`) — the root agent's driver mode:
      `"oneshot"` matches a stored NULL cell (the canonical `"oneshot"`, see
      `EvoGit.Store.Codec.decode_session_mode/1`, which also normalizes a
      blank cell to it), the stored `"oneshot"` TEXT and a blank TEXT cell;
      `"interactive"` is exact TEXT equality on that one value; `"all"` and
      any other/unknown value mean no clause at all.
    * `:search` (`nil`/`""` = no clause) — ONE runtime `fragment/1`: a
      case-insensitive OR-LIKE over **`id`, `opts`, `project_path`,
      `branch_name`** with the escaped pattern `%<escaped search>%` and
      the escape char pinned as a bound parameter (`ESCAPE ?`).

  ## Search behaviour change (deliberate)

  `result` is NO LONGER searched. It is a full-blob column stored as plain
  JSON text, so a LIKE over it is a scan of the heaviest column in the table
  — one live row held 108 MB of `result` — and its text is the agent's own
  prose, not something users search for. The denormalized `branch_name`
  column replaces it: it is the branch a task produced (already
  exposed on the summary projection and used by the review flow), it is small,
  and it is what users actually search for ("which task produced
  `genesis/agent_ab12`?"). A phrase that exists ONLY inside a task's `result`
  text therefore no longer matches; phrases in the objective (`opts`), the id,
  the project path and the branch name still do.

  The escape char must be pinned as a PARAMETER, never written as the SQL
  literal `'\\'`: the adapter doubles backslashes inside SQL string literals,
  which SQLite then rejects ("ESCAPE expression must be a single character").

  ## Pagination clamps

  The three clamps below are the SAME rule with different arguments — `nil`,
  a non-integer or (by default) a NON-POSITIVE value falls back to the
  caller's default, while a positive integer is bounded by the caller's
  maximum — and that rule lives in ONE place (`clamp/2`). Every paged read in
  the store (legacy task page, lightweight summary page, per-agent archive
  roster) clamps its `:limit`/`:offset` through one of these functions.
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
  def clamp_limit(value), do: clamp_limit(value, default: @default_limit)

  @doc """
  Lightweight-page limit clamp: `nil`/invalid/non-positive → #{@page_default_limit},
  a positive integer is capped at #{@page_max_limit}.
  """
  @spec clamp_page_limit(term()) :: pos_integer()
  def clamp_page_limit(value),
    do: clamp_limit(value, default: @page_default_limit, max: @page_max_limit)

  @doc "Offset clamp: `nil`, negative or non-integer → 0."
  @spec clamp_offset(term()) :: non_neg_integer()
  def clamp_offset(value), do: clamp_limit(value, default: 0)

  # The ONE pagination-clamp rule behind the three clamps above (see the
  # moduledoc). `:max` is the positive cap, `:infinity` (the default) leaves a
  # positive value uncapped. `:non_positive` decides what a zero/negative
  # INTEGER becomes: `:default` (a non-positive value means "not specified",
  # so the caller's `:default` applies — the legacy and lightweight reads) or
  # `:minimum` (the hard minimum of 1 — the archive roster, which floors a
  # too-small page to one row rather than falling back to 100).
  @doc false
  @spec clamp_limit(term(), keyword()) :: non_neg_integer()
  def clamp_limit(value, opts) when is_list(opts) do
    default = Keyword.fetch!(opts, :default)
    max = Keyword.get(opts, :max, :infinity)
    non_positive = Keyword.get(opts, :non_positive, :default)

    cond do
      not is_integer(value) -> default
      value <= 0 and non_positive == :default -> default
      true -> value |> max(1) |> bounded(max)
    end
  end

  defp bounded(value, :infinity), do: value
  defp bounded(value, max), do: min(value, max)

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
    |> where_session_mode_filter(Keyword.get(filters, :session_mode, "all"))
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

  defp where_session_mode_filter(query, "all"), do: query

  defp where_session_mode_filter(query, "oneshot") do
    # A stored NULL cell IS the canonical "oneshot" (Codec.decode_session_mode/1),
    # and that decoder normalizes a blank cell to it as well — both spellings a
    # row can actually carry are admitted, so a legacy row is never stranded
    # outside BOTH session-mode filters.
    where(
      query,
      [t],
      is_nil(t.session_mode) or t.session_mode == "oneshot" or t.session_mode == ""
    )
  end

  defp where_session_mode_filter(query, "interactive") do
    where(query, [t], t.session_mode == "interactive")
  end

  defp where_session_mode_filter(query, _unknown), do: query

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
