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
  does not match the raw twin's declared field type — BEFORE any per-row
  boundary can see the row. The old raw-SQL store read plain bytes and skipped
  such rows inside its decode boundary (the Codec decode raised
  `FunctionClauseError` on the non-binary value), so a corrupt/legacy row NEVER
  crashed the read. The safe select reproduces that in two steps, so ONE
  poisoned cell never costs a round trip per row:

  1. The whole set is read in ONE `Repo.all/1`; when it loads, every row goes
     through `EvoGit.Store.Operations.Decoding.decode_skipping_bad/4`.
  2. Only when that set load raises does it fall back to CHUNKED re-reads: the
     ids are read once, then re-read in batches of 100 ids
     (`WHERE id IN ^chunk`) — so a database with one bad row pays
     `ceil(rows / 100)` + 1 queries, not one query per row.
     A chunk that loads cleanly goes through the same shared decode boundary;
     a chunk that STILL fails to load is narrowed to per-row `Repo.get/2`
     loads for THAT chunk only, each guarded so the offending row is skipped +
     logged while the rest of the chunk survives.

  ## Rescue scope — decode/loader classes ONLY

  Every rescue in this module lists exactly `ArgumentError`,
  `FunctionClauseError` and `Ecto.Query.CastError` (`@load_errors`): the
  classes a wrong-typed cell produces (`Ecto.Repo.Schema.load_each/4` raises
  `ArgumentError` "cannot load … as type …"), plus the Codec's own raising
  decode. A GENUINE database error (adapter failure, missing table, bad
  connection) matches none of them and therefore propagates to the caller
  unchanged — the Operations crash philosophy — instead of being turned into an
  empty result. Note that the load and the decode are SEPARATE guarded steps:
  the decode call is never inside a load rescue, so a skipped row is logged
  exactly once.

  ## Why rows load through the RAW twin

  `EvoGit.Store.Codec` decode raises on corrupt/legacy wire values BY DESIGN.
  Loading through the typed schema (`TaskRow`) would raise inside Ecto's
  loader — before any per-row boundary could run — so the safe select loads
  every row through `EvoGit.Store.Schemas.TaskRowRaw` (plain
  `:string`/`:integer` fields = the exact bytes SQLite stored) and decodes each
  row through `Codec.decode_raw_row/1`. The Codec stays the single decode
  oracle: no positional column list is duplicated here.

  ## Lenient per-row decode (skip + log)

  Delegated to `EvoGit.Store.Operations.Decoding.decode_skipping_bad/4`: a row
  whose Codec decode RAISES (by design — e.g. non-object `opts` JSON) is
  SKIPPED with a `Logger.warning` ("Store: skipping undecodable row in ...")
  instead of crashing the whole read; no data-movement INSERT/DELETE is
  performed on bad rows.
  """

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Decoding
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.Store.Schemas.VctMountRow
  alias EvoGit.TaskInfo

  import Ecto.Query, only: [from: 2]

  require Logger

  # ids per re-read batch in the load-failure fallback.
  @id_chunk_size 100

  # The ONLY exception classes this module rescues: a wrong-typed cell raises
  # `ArgumentError` out of Ecto's struct loader (`Ecto.Repo.Schema.load_each/4`)
  # and the Codec decoders raise `ArgumentError`/`FunctionClauseError` by
  # design; `Ecto.Query.CastError` covers a chunk parameter that will not cast.
  # Anything else is a genuine database/query error and MUST propagate.
  @load_errors [ArgumentError, FunctionClauseError, Ecto.Query.CastError]

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

  ## Private — safe-select set loading

  # Whole-set load first; only a LOAD failure falls back to chunked re-reads.
  # Two failure depths, mirroring the old raw-SQL skip-and-log boundary:
  #
  #   * DECODE failures — the usual case: the Codec raises on corrupt/legacy
  #     JSON text. Handled per row by the shared decode boundary.
  #   * LOAD failures — Ecto's struct loader raises inside `Repo.all/1` when a
  #     cell's physical type mismatches the raw twin's declared field type. The
  #     old store never saw this class separately (it read plain bytes and the
  #     Codec's FunctionClauseError landed in the same per-row skip), so the
  #     fallback re-reads the rows in id chunks and narrows only a still-failing
  #     chunk to per-row loads.
  defp all_tasks_skipping_bad do
    case guarded_load(fn -> Repo.all(TaskRowRaw) end) do
      {:ok, rows} ->
        decode_rows(rows)

      {:error, e} ->
        # Justified try/rescue — safe-select boundary (mirrors the raw store),
        # restricted to the decode/loader classes by `guarded_load/1`.
        Logger.warning(
          "Store: batch row load failed for tasks (#{Exception.message(e)}); " <>
            "falling back to chunked re-reads, skipping undecodable rows"
        )

        chunked_reload()
    end
  end

  # Reads every id ONCE, then re-reads the rows in batches so one poisoned cell
  # costs `ceil(rows / @id_chunk_size)` queries instead of one per row.
  defp chunked_reload do
    from(s in TaskRowRaw, select: s.id)
    |> Repo.all()
    |> Enum.chunk_every(@id_chunk_size)
    |> Enum.flat_map(&reload_chunk/1)
  end

  # A chunk that loads cleanly is decoded through the shared per-row boundary;
  # a chunk that still fails is narrowed to per-row loads for THAT chunk only.
  defp reload_chunk(ids) do
    chunk_query = from(s in TaskRowRaw, where: s.id in ^ids)

    case guarded_load(fn -> Repo.all(chunk_query) end) do
      {:ok, rows} -> rows |> order_by_ids(ids) |> decode_rows()
      {:error, _e} -> Enum.flat_map(ids, &reload_row/1)
    end
  end

  defp reload_row(id) do
    case guarded_load(fn -> Repo.get(TaskRowRaw, id) end) do
      {:ok, nil} ->
        []

      {:ok, row} ->
        decode_rows([row])

      {:error, e} ->
        # Justified try/rescue — this ONE row cannot be loaded (wrong-typed
        # cell), so it is skipped + logged while the rest of the chunk survives.
        Logger.warning(
          "Store: skipping undecodable row in tasks (id: #{inspect(id)}): " <>
            Exception.message(e)
        )

        []
    end
  end

  # Runs ONE load call, answering `{:ok, result}` or `{:error, exception}` for
  # the decode/loader classes ONLY — a genuine database error is NOT matched
  # and propagates to the caller unchanged.
  defp guarded_load(load_fun) when is_function(load_fun, 0) do
    {:ok, load_fun.()}
  rescue
    e in @load_errors -> {:error, e}
  end

  # Restores the id-list order the PLANNED order (`no ORDER BY`) delivered: an
  # `IN` query may answer in primary-key order instead.
  defp order_by_ids(rows, ids) do
    positions = ids |> Enum.with_index() |> Map.new()
    Enum.sort_by(rows, &Map.fetch!(positions, &1.id))
  end

  # The ONE shared skip-and-log decode boundary (`Decoding.decode_skipping_bad/4`).
  defp decode_rows(rows) do
    Decoding.decode_skipping_bad(rows, "tasks", & &1.id, &Codec.decode_raw_row/1)
  end
end
