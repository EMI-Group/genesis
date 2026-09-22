defmodule EvoGit.Store.Operations.Safety do
  @moduledoc """
  Safe-select + size store operations on Ecto — the port of the raw-SQL
  `EvoGit.Store` GenServer's Size & Safety handlers (store.ex lines 925-953:
  `:size`, `:safe_select_all_tasks`, `:safe_select_all_projects`).

  Pure operation module: every function takes the repo PID FIRST (an UNNAMED
  dynamic `EvoGit.Repo` instance started by `EvoGit.Store.Boot.start_dynamic/1`),
  scopes it through `EvoGit.Store.RepoScope.with_repo/2`, and addresses the
  database exclusively via `EvoGit.Repo.*` + the RAW wire-value schemas — no
  `?N` SQL strings, no GenServer.

  ## Return shapes (EXACTLY the old public-API shapes — zero consumer changes)

  | function                     | old handler  | returns |
  |------------------------------|--------------|---------|
  | `safe_select_all_tasks/1`    | store.ex:934 | `[TaskInfo.t()]` — undecodable rows SKIPPED + logged |
  | `safe_select_all_projects/1` | store.ex:943 | `[RecentProject.t()]` — undecodable rows SKIPPED + logged |
  | `size/1`                     | store.ex:928 | integer — the SUM of the ROW COUNTS of both tables (`SELECT COUNT(*)` per table; NO PRAGMA byte math) |

  Like the old bare `SELECT ... FROM tasks/projects`, the safe selects carry
  NO `ORDER BY` (rows come back in rowid/insertion order) and return a plain
  LIST — the `{tasks, total_count}` split belongs to the paginated variant,
  not these handlers. The old offload-to-a-Task heap isolation was a GenServer
  concern and stays at the wave-2 store layer.

  ## Wrong-typed cells (load-failure fallback)

  Ecto's struct loader RAISES inside `Repo.all/1` when a cell's physical type
  does not match the raw twin's declared field type (e.g. a legacy INTEGER
  `last_opened_at`) — BEFORE the per-row boundary below can see the row. The
  old raw-SQL store read plain bytes and skipped such rows inside its
  `decode_skipping_bad/3` (the Codec decode raised `FunctionClauseError` on
  the non-binary value), so a corrupt/legacy row NEVER crashed the read. Both
  safe selects reproduce that exactly: on a loader raise they fall back to
  reading rows ONE AT A TIME by primary key, so a row that fails to LOAD or
  DECODE is skipped + logged while every other row still comes back. The
  fallback only ever triggers on a wrong-typed cell — over well-typed rows
  the single-set `Repo.all/1` path runs, unchanged.

  ## Why rows load through the RAW twins

  `EvoGit.Store.Codec` decode raises on corrupt/legacy wire values BY DESIGN.
  Loading through the typed schemas (`TaskRow`/`ProjectRow`) would raise inside
  Ecto's loader — before any per-row rescue could run — so the safe selects
  load every row through `EvoGit.Store.Schemas.TaskRowRaw` /
  `EvoGit.Store.Schemas.ProjectRowRaw` (plain `:string`/`:integer` fields = the
  exact bytes SQLite stored) and decode each row through the Codec individually.
  The Codec stays the single decode oracle: task rows are handed to
  `Codec.decode_task/1` as the same 19-element positional list
  (`Codec.task_columns/0` order — deliberately WITHOUT `updated_at`, which the
  old `SELECT` over those columns never fetched either), project rows to
  `Codec.decode_project/1` as the 3-element list.

  ## Lenient per-row decode (skip + log)

  Ported verbatim from the raw store's `decode_skipping_bad/3`: a row whose
  Codec decode RAISES (by design — e.g. non-object `opts` JSON) is SKIPPED
  with a `Logger.warning` ("Store: skipping undecodable row in ...") instead
  of crashing the whole read; no data-movement INSERT/DELETE is performed on
  bad rows. Only genuinely raising columns trip the skip — the lenient Codec
  decoders (`decode_datetime/1`, `decode_atom/1`, `decode_error/1`) return
  fallbacks, so e.g. a project row with an unparseable `last_opened_at` SURVES
  with `last_opened_at: nil` (exactly the old behavior — the project skip arm
  is effectively unreachable over TEXT wire values).

  Query errors under Ecto raise (the old `_ -> []` NIF error-tuple arms have
  no equivalent under the adapter); this module's ONLY try/rescue is the
  per-row decode boundary above.
  """

  alias EvoGit.RecentProject
  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.ProjectRow
  alias EvoGit.Store.Schemas.ProjectRowRaw
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo

  import Ecto.Query, only: [from: 2]

  require Logger

  @doc """
  Enumerates all tasks, skipping (not raising on) rows that fail to decode.

  Bad rows are logged with a warning and excluded from the returned list.
  """
  @spec safe_select_all_tasks(pid()) :: [TaskInfo.t()]
  def safe_select_all_tasks(repo) do
    RepoScope.with_repo(repo, fn ->
      all_skipping_bad(TaskRowRaw, "tasks", :id, &decode_raw_task/1)
    end)
  end

  @doc """
  Enumerates all projects, skipping (not raising on) rows that fail to decode.

  Bad rows are logged with a warning and excluded from the returned list.
  """
  @spec safe_select_all_projects(pid()) :: [RecentProject.t()]
  def safe_select_all_projects(repo) do
    RepoScope.with_repo(repo, fn ->
      all_skipping_bad(ProjectRowRaw, "projects", :path, &decode_raw_project/1)
    end)
  end

  @doc """
  Returns the total number of rows across both tables.

  Port of the old `count_table(tasks) + count_table(projects)` — plain ROW
  COUNTS summed, undecodable rows INCLUDED (COUNT(*) counts rows, never
  decodes them).
  """
  @spec size(pid()) :: non_neg_integer()
  def size(repo) do
    RepoScope.with_repo(repo, fn ->
      Repo.aggregate(TaskRow, :count) + Repo.aggregate(ProjectRow, :count)
    end)
  end

  ## Private — decode

  # %TaskRowRaw{} → the 19-element positional list `Codec.decode_task/1`
  # expects (`Codec.task_columns/0` order — without `updated_at`, mirroring the
  # old `SELECT #{Enum.join(Codec.task_columns(), ", ")} FROM tasks`). The raw
  # twin guarantees the values are the exact stored wire bytes.
  defp decode_raw_task(%TaskRowRaw{} = row) do
    Codec.decode_task([
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
      row.archive_metadata,
      row.lease_expires_at,
      row.model_id,
      row.project_path,
      row.branch_name,
      row.error
    ])
  end

  # %ProjectRowRaw{} → the 3-element positional list `Codec.decode_project/1`
  # expects (`Codec.project_columns/0` order).
  defp decode_raw_project(%ProjectRowRaw{} = row) do
    Codec.decode_project([row.path, row.name, row.last_opened_at])
  end

  ## Private — safe-select set loading

  # Loads ALL rows of `schema` and decodes them through `decoder`, skipping
  # + logging rows that fail. Two failure depths, mirroring the old raw-SQL
  # skip-and-log boundary exactly:
  #
  #   * DECODE failures (per row, below) — the usual case: the Codec raises
  #     on corrupt/legacy JSON text.
  #   * LOAD failures (the fallback) — Ecto's struct loader raises inside
  #     `Repo.all/1` when a cell's physical type mismatches the raw twin's
  #     declared field type (e.g. a legacy INTEGER `last_opened_at` in a
  #     table some old DB version created). The old store never saw this
  #     class separately (it read plain bytes and the Codec's
  #     FunctionClauseError landed in the same per-row skip), so the fallback
  #     re-reads rows ONE AT A TIME by primary key and lets the SAME per-row
  #     boundary skip+log the offending row while every other row survives.
  #     This rescue catches ONLY loader raises — `Repo.get/2` re-raises any
  #     genuine database error, which then surfaces to the caller unchanged
  #     (crash philosophy preserved).
  defp all_skipping_bad(schema, table, id_key, decoder) do
    schema
    |> Repo.all()
    |> decode_skipping_bad(table, id_key, decoder)
  rescue
    e ->
      # Justified try/rescue — safe-select boundary (mirrors the raw store):
      # a wrong-typed cell poisons the WHOLE set load, so fall back to
      # per-key loads and skip only the offending rows (see moduledoc).
      # (`from s in schema` needs a compile-time queryable, hence the case.)
      Logger.warning(
        "Store: batch row load failed for #{table} (#{Exception.message(e)}); " <>
          "falling back to per-row loads, skipping undecodable rows"
      )

      id_query =
        case id_key do
          :id -> from(s in TaskRowRaw, select: s.id)
          :path -> from(p in ProjectRowRaw, select: p.path)
        end

      id_query
      |> Repo.all()
      |> Enum.flat_map(fn id ->
        try do
          case Repo.get(schema, id) do
            nil -> []
            row -> [decoder.(row)]
          end
        rescue
          e ->
            Logger.warning(
              "Store: skipping undecodable row in #{table} (id: #{inspect(id)}): " <>
                Exception.message(e)
            )

            []
        end
      end)
  end

  # Safe-select decode boundary — ported verbatim from the raw store's
  # decode_skipping_bad/3 (store.ex:1123): decodes every row, SKIPPING (and
  # logging) rows that raise instead of crashing the whole select. The decoder
  # raises by design; skipping is the deliberate recovery boundary — no
  # data-movement INSERT/DELETE is performed on bad rows. `id_key` is the
  # struct field the old `hd(row)` first-column id came from.
  defp decode_skipping_bad(rows, table, id_key, decoder) do
    Enum.flat_map(rows, fn row ->
      # Justified try/rescue — safe-select boundary (mirrors the raw store):
      # (1) Do we expect this? Yes — DB rows may contain corrupt or legacy
      # data that fails to decode. (2) Cleanest approach? The Codec decoders
      # raise by design; skipping is the deliberate recovery boundary.
      try do
        [decoder.(row)]
      rescue
        e ->
          Logger.warning(
            "Store: skipping undecodable row in #{table} (id: #{inspect(Map.get(row, id_key))}): " <>
              Exception.message(e)
          )

          []
      end
    end)
  end
end
