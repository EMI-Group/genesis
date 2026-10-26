defmodule EvoGit.Store.Operations.Pages do
  @moduledoc """
  The LIGHTWEIGHT task read API — the store half of the dashboard's task-list /
  detail reads, built so a page or a detail view never pays for the heavy JSON
  blobs (`result`, `logs`, `usage`).

  Two reads, all additive (the existing `Operations.Tasks` /
  `Operations.Summaries` handlers keep their names, arities and return shapes):

  | function | returns |
  |----------|---------|
  | `select_tasks_page/2` | `%{rows: [summary_map], total: non_neg_integer}` |
  | `get_task_lite/2` | `%EvoGit.TaskInfo{} \\| nil` — the full row decode, nothing dropped |

  ## `select_tasks_page/2` — the summary page

  Rows are the CANONICAL 16-key summary projection from
  `EvoGit.Store.Operations.Summaries.summary_query/0` (id, status,
  review_status, started_at, finished_at, type, project_path, opts,
  branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at,
  updated_at, error) — `result`/`logs`/`usage` are NEVER selected, so a page
  costs the same whether a row holds 1 kB or 108 MB of `result`. Rows are
  sorted `ORDER BY started_at DESC` and the page is index-served
  (`idx_tasks_started_at`, or the matching composite when a filter pins a
  leading equality column) with no temp B-tree; `total` is a `COUNT(*)` over
  the SAME WHERE, independent of pagination — and restricted to RENDERABLE
  rows (see below), so it can never exceed the rows the pages actually yield.

  `opts` accepts the `EvoGit.Store.Operations.Tasks.safe_select_paginated_tasks/2`
  shape — `:limit`, `:offset`, and the filter set — so a caller can switch
  reads without reshaping anything. The filter keys (`:status`,
  `:project_path`, `:review_status`, `:search`) may be passed either nested
  under `:filters` (the legacy shape) or at the top level; a top-level key wins
  over the nested one. Both go through the ONE shared WHERE builder
  (`EvoGit.Store.Operations.Filters.where_filters/2`), so this read and the
  legacy FULL-row page can never match different rows.

  Limit/offset are clamped for a dashboard-sized page: `:limit` defaults to 25
  and caps at 50 (`EvoGit.Store.Operations.Filters.clamp_page_limit/1`),
  `:offset` is never negative. If the requested offset
  lies PAST the end of the filtered set, the LAST page is returned instead of
  an empty one (the same "clamp to the last page" behaviour the dashboard
  applies today, moved into the read so every caller gets it for free) — with
  the row total unchanged.

  ## `total` and the skip boundary agree

  `Summaries.decode_skipping_bad/1` drops a row whose `opts` column cannot be
  decoded, so a plain `COUNT(*)` would count rows the page refuses to render —
  `total` would exceed the renderable rows and the LAST page could come back
  empty. Both the count and the page selection therefore carry
  `Summaries.where_renderable/1` (SQLite `json_valid`/`json_type`), the SQL
  twin of that decode rule: a corrupt row is excluded from the total AND from
  the rendering, so `total`, the page offsets and the rendered rows always
  agree. The per-row skip stays as the defence for anything SQLite considers
  renderable but the Codec still rejects.

  ## `get_task_lite/2` — the detail view

  Decodes exactly like `Operations.Tasks.get_task/2` (the same Codec
  `decode_task/1`, i.e. every column decoded identically). The per-agent
  archive is NOT part of the task row any more (it lives in the relational
  `task_agent_archives` table), so no column has to be skipped here.

  ## Crash philosophy

  No try/rescue here: a failing statement raises out of `EvoGit.Repo.*` and the
  facade's failure-isolated read offload (`EvoGit.Store.offload/5`) turns it
  into each read's documented degraded value (`%{rows: [], total: 0}` / `nil`)
  without disturbing any other caller.
  """

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Filters
  alias EvoGit.Store.Operations.Summaries
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo

  @doc """
  Returns one page of the 16-key summary projection plus the filtered row
  total: `%{rows: [summary_map], total: non_neg_integer}`.

  See the moduledoc for the projection, the filter/limit/offset contract and
  the last-page refetch on an out-of-range offset.
  """
  @spec select_tasks_page(pid(), keyword()) :: %{
          rows: [Summaries.summary()],
          total: non_neg_integer()
        }
  def select_tasks_page(repo, opts) when is_list(opts) do
    RepoScope.with_repo(repo, fn ->
      filters = filters_from_opts(opts)
      limit = Filters.clamp_page_limit(Keyword.get(opts, :limit))
      requested_offset = Filters.clamp_offset(Keyword.get(opts, :offset))

      # `total` counts only rows the page can actually RENDER: both the count
      # and the selection carry `Summaries.where_renderable/1` (the SQL twin of
      # the Codec's opts decode), so a corrupt `opts` row can neither inflate
      # the total nor push a renderable row onto a later page. Counting rows
      # the page drops would let the last page come back EMPTY.
      total =
        TaskRowRaw
        |> Filters.where_filters(filters)
        |> Summaries.where_renderable()
        |> Repo.aggregate(:count)

      rows =
        Summaries.summary_query()
        |> Filters.where_filters(filters)
        |> Summaries.where_renderable()
        |> order_by([t], desc: t.started_at)
        |> limit(^limit)
        |> offset(^last_page_offset(requested_offset, limit, total))
        |> Repo.all()
        |> Summaries.decode_skipping_bad()

      %{rows: rows, total: total}
    end)
  end

  @doc """
  Reads a single task by id, decoded EXACTLY like `Operations.Tasks.get_task/2`.
  Returns `nil` when no row matches.
  """
  @spec get_task_lite(pid(), String.t()) :: TaskInfo.t() | nil
  def get_task_lite(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      case Repo.one(lite_query(task_id)) do
        nil -> nil
        row -> row |> lite_columns() |> Codec.decode_task()
      end
    end)
  end

  ## Private — page helpers

  # Filter keys may arrive nested under `:filters` (the legacy
  # `safe_select_paginated_tasks/2` shape) and/or at the top level; a top-level
  # key wins. Both feed the ONE shared WHERE builder.
  defp filters_from_opts(opts) do
    nested =
      case Keyword.get(opts, :filters, []) do
        list when is_list(list) -> list
        _ -> []
      end

    Keyword.merge(nested, Keyword.take(opts, [:status, :project_path, :review_status, :search]))
  end

  # Page-clamp refetch: an offset at/past the end of the filtered set lands on
  # the LAST page (its first offset) instead of yielding an empty page. `limit`
  # is always ≥ 1 (the clamp guarantees it) and `total` is ≥ 0, so the division
  # is safe; an empty set keeps offset 0.
  defp last_page_offset(_requested, _limit, 0), do: 0

  defp last_page_offset(requested, _limit, total) when requested < total, do: requested

  defp last_page_offset(_requested, limit, total), do: div(total - 1, limit) * limit

  ## Private — lite detail read

  # The 18 decode-relevant columns — everything `Operations.Tasks.get_task/2`
  # decodes. Field list/order mirrors `Codec.task_columns/0` (which is the
  # positional contract `Codec.decode_task/1` expects, minus `updated_at`).
  defp lite_query(task_id) do
    from(t in TaskRowRaw,
      select: %{
        id: t.id,
        type: t.type,
        status: t.status,
        opts: t.opts,
        started_at: t.started_at,
        finished_at: t.finished_at,
        logs: t.logs,
        result: t.result,
        review_status: t.review_status,
        usage: t.usage,
        agent_count: t.agent_count,
        base_sha: t.base_sha,
        commit_sha: t.commit_sha,
        lease_expires_at: t.lease_expires_at,
        model_id: t.model_id,
        project_path: t.project_path,
        branch_name: t.branch_name,
        error: t.error
      },
      where: t.id == ^task_id
    )
  end

  # Rebuilds the positional row `Codec.decode_task/1` expects from the map
  # projection above: the EXACT `Codec.task_columns/0` order (minus
  # `updated_at`, which the decoder never reads). Reusing the Codec — rather
  # than re-implementing the per-column decode — is what keeps this read
  # field-identical to `get_task/2`.
  defp lite_columns(row) do
    [
      row.id,
      row.type,
      row.status,
      row.opts,
      row.started_at,
      row.finished_at,
      row.logs,
      row.result,
      row.review_status,
      row.usage,
      row.agent_count,
      row.base_sha,
      row.commit_sha,
      row.lease_expires_at,
      row.model_id,
      row.project_path,
      row.branch_name,
      row.error
    ]
  end
end
