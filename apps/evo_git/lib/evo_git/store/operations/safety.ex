defmodule EvoGit.Store.Operations.Safety do
  @moduledoc """
  Safe-select + size store operations on Ecto — the port of the raw-SQL
  `EvoGit.Store` GenServer's Size & Safety handlers (`:size`,
  `:safe_select_all_tasks`).

  Pure operation module: every function takes the repo PID FIRST (an UNNAMED
  dynamic `EvoGit.Repo` instance started by `EvoGit.Store.Boot.start_dynamic/1`),
  scopes it through `EvoGit.Store.RepoScope.with_repo/2`, and addresses the
  database exclusively via `EvoGit.Repo.*` + the RAW wire-value schemas — no
  `?N` SQL strings, no GenServer.

  ## Return shapes (EXACTLY the old public-API shapes — zero consumer changes)

  | function                  | returns |
  |---------------------------|---------|
  | `safe_select_all_tasks/1` | `[TaskInfo.t()]` — undecodable rows SKIPPED + logged |
  | `size/1`                  | integer — the SUM of the ROW COUNTS of the `tasks` and `vct_mounts` tables (`SELECT COUNT(*)` per table; NO PRAGMA byte math) |

  Like the old bare `SELECT ... FROM tasks`, the safe select carries NO
  `ORDER BY` (rows come back in rowid/insertion order) and returns a plain
  LIST — the `{tasks, total_count}` split belongs to the paginated variant,
  not this handler. The old offload-to-a-Task heap isolation was a GenServer
  concern and stays at the wave-2 store layer.

  ## Wrong-typed cells (load-failure fallback)

  Ecto's struct loader RAISES inside `Repo.all/1` when a cell's physical type
  does not match the raw twin's declared field type — BEFORE the per-row
  boundary below can see the row. The old raw-SQL store read plain bytes and
  skipped such rows inside its `decode_skipping_bad/3` (the Codec decode raised
  `FunctionClauseError` on the non-binary value), so a corrupt/legacy row NEVER
  crashed the read. The safe select reproduces that exactly: on a loader raise
  it falls back to reading rows ONE AT A TIME by primary key, so a row that
  fails to LOAD or DECODE is skipped + logged while every other row still comes
  back. The fallback only ever triggers on a wrong-typed cell — over well-typed
  rows the single-set `Repo.all/1` path runs, unchanged.

  ## Why rows load through the RAW twin

  `EvoGit.Store.Codec` decode raises on corrupt/legacy wire values BY DESIGN.
  Loading through the typed schema (`TaskRow`) would raise inside Ecto's
  loader — before any per-row rescue could run — so the safe select loads every
  row through `EvoGit.Store.Schemas.TaskRowRaw` (plain `:string`/`:integer`
  fields = the exact bytes SQLite stored) and decodes each row through the
  Codec individually. The Codec stays the single decode oracle: task rows are
  handed to `Codec.decode_task/1` as the same 18-element positional list
  (`Codec.task_columns/0` order — deliberately WITHOUT `updated_at`, which the
  old `SELECT` over those columns never fetched either).

  ## Lenient per-row decode (skip + log)

  Ported verbatim from the raw store's `decode_skipping_bad/3`: a row whose
  Codec decode RAISES (by design — e.g. non-object `opts` JSON) is SKIPPED
  with a `Logger.warning` ("Store: skipping undecodable row in ...") instead
  of crashing the whole read; no data-movement INSERT/DELETE is performed on
  bad rows.

  Query errors under Ecto raise (the old `_ -> []` NIF error-tuple arms have
  no equivalent under the adapter); this module's ONLY try/rescue is the
  per-row decode boundary above.
  """

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.Store.Schemas.VctMountRow
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
      all_tasks_skipping_bad()
    end)
  end

  @doc """
  Returns the total number of rows across both tables (`tasks` and
  `vct_mounts`).

  Plain ROW COUNTS summed, undecodable rows INCLUDED (COUNT(*) counts rows,
  never decodes them).
  """
  @spec size(pid()) :: non_neg_integer()
  def size(repo) do
    RepoScope.with_repo(repo, fn ->
      Repo.aggregate(TaskRow, :count) + Repo.aggregate(VctMountRow, :count)
    end)
  end

  ## Private — decode

  # %TaskRowRaw{} → the 18-element positional list `Codec.decode_task/1`
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
      row.lease_expires_at,
      row.model_id,
      row.project_path,
      row.branch_name,
      row.error
    ])
  end

  ## Private — safe-select set loading

  # Loads ALL task rows and decodes them through the task decoder, skipping +
  # logging rows that fail. Two failure depths, mirroring the old raw-SQL
  # skip-and-log boundary exactly:
  #
  #   * DECODE failures (per row, below) — the usual case: the Codec raises
  #     on corrupt/legacy JSON text.
  #   * LOAD failures (the fallback) — Ecto's struct loader raises inside
  #     `Repo.all/1` when a cell's physical type mismatches the raw twin's
  #     declared field type. The old store never saw this class separately (it
  #     read plain bytes and the Codec's FunctionClauseError landed in the same
  #     per-row skip), so the fallback re-reads rows ONE AT A TIME by primary
  #     key and lets the SAME per-row boundary skip+log the offending row while
  #     every other row survives. This rescue catches ONLY loader raises —
  #     `Repo.get/2` re-raises any genuine database error, which then surfaces
  #     to the caller unchanged (crash philosophy preserved).
  defp all_tasks_skipping_bad do
    TaskRowRaw
    |> Repo.all()
    |> decode_skipping_bad("tasks", :id, &decode_raw_task/1)
  rescue
    e ->
      # Justified try/rescue — safe-select boundary (mirrors the raw store):
      # a wrong-typed cell poisons the WHOLE set load, so fall back to
      # per-key loads and skip only the offending rows (see moduledoc).
      Logger.warning(
        "Store: batch row load failed for tasks (#{Exception.message(e)}); " <>
          "falling back to per-row loads, skipping undecodable rows"
      )

      from(s in TaskRowRaw, select: s.id)
      |> Repo.all()
      |> Enum.flat_map(fn id ->
        try do
          case Repo.get(TaskRowRaw, id) do
            nil -> []
            row -> [decode_raw_task(row)]
          end
        rescue
          e ->
            Logger.warning(
              "Store: skipping undecodable row in tasks (id: #{inspect(id)}): " <>
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
