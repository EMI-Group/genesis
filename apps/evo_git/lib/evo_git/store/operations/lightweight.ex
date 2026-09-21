defmodule EvoGit.Store.Operations.Lightweight do
  @moduledoc """
  Ecto ports of the raw-SQL lightweight task queries of `EvoGit.Store`.

  Unit R3a of the Store→Ecto migration: the id/lease/cleanup query handlers
  whose SQL-pushdown filtering (literal status sets, `finished_at`
  cutoff/count trim) is preserved verbatim, expressed as `Ecto.Query`
  queries against `EvoGit.Repo`. Return shapes are EXACTLY the old handler
  shapes — the consumers (`EvoGit.TaskRegistry` for paths/ids/lease,
  `EvoGit.TaskRegistry.Cleanup` for cleanup ids) change nothing.

  Every entry point takes the repo pid FIRST and runs its queries inside
  `EvoGit.Store.RepoScope.with_repo/2`, so calls target that specific dynamic
  instance and never leak the caller's binding.

  ## Read path — the RAW schema, deliberately

  All reads go through the raw wire twin `EvoGit.Store.Schemas.TaskRowRaw`
  (plain `:string`/`:integer` fields), because these handlers' contracts are
  raw-value projections, not decoded rows:

    * `updated_at` is returned as the stored fixed-precision ISO string
      (store-internal bookkeeping, string-compared by callers, never decoded).
    * `lease_expires_at` is the raw unix-ms INTEGER.
    * `status` is decoded PER ROW via `Codec.decode_atom/1` — the exact call
      the old handlers made (known atom, or warning log + `nil` on unknown),
      not the typed schema's silent `nil`.
    * `finished_at` (`select_cleanup_info/1` only) is decoded per row via
      `Codec.decode_datetime/1` (nil on corrupt data, never a raise).

  No JSON blob column (`opts`, `result`, `logs`, `usage`,
  `archive_metadata`) is ever selected — these remain the cheap projections
  the old handlers were.

  ## SQL equivalence notes

    * No `ORDER BY`/`LIMIT` anywhere except `select_cleanup_info/3`'s count
      trim, which keeps the old
      `ORDER BY finished_at DESC LIMIT -1 OFFSET n` shape (a limit-less
      offset makes the adapter emit `LIMIT -1`).
    * The literal status sets are compile-time literals in the queries — the
      same SQL literal pushdown the old handlers used. `select_task_ids/2`'s
      filter is parameterized, exactly like the old `build_status_where/1`.
    * No `fragment/1` anywhere: the old SQL contains no strftime/date math.
      The cleanup cutoff is a plain TEXT comparison over the fixed-precision
      24-char ISO format, carried out by pinning the ISO string (which sorts
      chronologically).
  """

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw

  # "Finished" = every status EXCEPT running/pending/cancelling. `:cancelling`
  # is deliberately excluded (an in-flight graceful cancel must never be
  # deleted by clear_finished_tasks); `:finalizing` IS finished (terminal-ish
  # cleanup target). Mirrors the old literal `NOT IN` pushdown.
  @live_statuses ["running", "pending", "cancelling"]

  # Lease/reconciliation set: `:cancelling` is included so startup
  # reconciliation can mark orphaned cancelling tasks `:cancelled`, mirroring
  # the `:finalizing` → `:failed` reconciliation. Mirrors the old literal
  # `IN` pushdown.
  @lease_statuses ["running", "finalizing", "cancelling"]

  @doc """
  Returns the distinct non-nil `project_path` values from all task rows.

  Port of the `:select_task_paths` handler
  (`SELECT DISTINCT project_path FROM tasks WHERE project_path IS NOT NULL`).
  Only the `project_path` column is read — no JSON blobs are touched.
  """
  @spec select_task_paths(pid()) :: [String.t()]
  def select_task_paths(repo) when is_pid(repo) do
    RepoScope.with_repo(repo, fn ->
      from(t in TaskRowRaw,
        where: not is_nil(t.project_path),
        distinct: true,
        select: t.project_path
      )
      |> Repo.all()
    end)
  end

  @doc """
  Returns the ids of all tasks whose status is NOT running, pending, or
  cancelling.

  Port of the `:select_finished_task_ids` handler. Raw id strings, no decode;
  the status filter is pushed into SQL as the literal
  `status NOT IN ('running', 'pending', 'cancelling')`.
  """
  @spec select_finished_task_ids(pid()) :: [String.t()]
  def select_finished_task_ids(repo) when is_pid(repo) do
    RepoScope.with_repo(repo, fn ->
      from(t in TaskRowRaw, where: t.status not in @live_statuses, select: t.id)
      |> Repo.all()
    end)
  end

  @doc """
  Returns a minimal id/status/updated_at projection for all tasks matching
  the given `statuses` (atoms; `[]` = no filter, all rows).

  Port of the `:select_task_ids` handler. `updated_at` is the RAW stored
  fixed-precision ISO string (never decoded); `status` is decoded per row via
  `Codec.decode_atom/1`. Non-empty `statuses` are mapped to their stored TEXT
  spelling and pushed into SQL (`WHERE status IN (...)`), exactly like the
  old `build_status_where/1`.
  """
  @spec select_task_ids(pid(), [atom()]) :: [
          %{id: String.t(), status: atom() | nil, updated_at: String.t() | nil}
        ]
  def select_task_ids(repo, statuses) when is_pid(repo) and is_list(statuses) do
    RepoScope.with_repo(repo, fn ->
      query =
        from(t in TaskRowRaw,
          select: %{id: t.id, status: t.status, updated_at: t.updated_at}
        )

      query =
        case statuses do
          [] ->
            query

          [_ | _] ->
            status_strings = Enum.map(statuses, &Atom.to_string/1)
            where(query, [t], t.status in ^status_strings)
        end

      query
      |> Repo.all()
      |> Enum.map(&decode_status_field/1)
    end)
  end

  @doc """
  Returns lightweight lease info for running/finalizing/cancelling tasks:
  `%{id, status, lease_expires_at}`.

  Port of the `:select_running_lease_info` handler. Only the `status` field is
  decoded (a lightweight atom via `Codec.decode_atom/1`); `lease_expires_at`
  is the raw unix-ms INTEGER. The status filter is pushed into SQL as the
  literal `status IN ('running', 'finalizing', 'cancelling')` — `:cancelling`
  is included so startup reconciliation can resolve orphaned cancelling tasks.
  """
  @spec select_running_lease_info(pid()) :: [
          %{id: String.t(), status: atom() | nil, lease_expires_at: integer() | nil}
        ]
  def select_running_lease_info(repo) when is_pid(repo) do
    RepoScope.with_repo(repo, fn ->
      from(t in TaskRowRaw,
        where: t.status in @lease_statuses,
        select: %{id: t.id, status: t.status, lease_expires_at: t.lease_expires_at}
      )
      |> Repo.all()
      |> Enum.map(&decode_status_field/1)
    end)
  end

  @doc """
  Returns lightweight cleanup info for finished tasks: `%{id, finished_at}`.

  Port of the default-args `:select_cleanup_info` handler
  (`SELECT id, finished_at FROM tasks WHERE finished_at IS NOT NULL`). `id` is
  the raw string; `finished_at` is decoded per row via
  `Codec.decode_datetime/1` (nil on corrupt data). No JSON blobs are decoded.

  NOTE: `select_cleanup_info/3` is the SQL-pushdown variant the runtime
  cleanup actually uses — it returns plain id strings.
  """
  @spec select_cleanup_info(pid()) :: [%{id: String.t(), finished_at: DateTime.t() | nil}]
  def select_cleanup_info(repo) when is_pid(repo) do
    RepoScope.with_repo(repo, fn ->
      from(t in TaskRowRaw,
        where: not is_nil(t.finished_at),
        select: %{id: t.id, finished_at: t.finished_at}
      )
      |> Repo.all()
      |> Enum.map(fn %{finished_at: finished_at} = row ->
        %{row | finished_at: Codec.decode_datetime(finished_at)}
      end)
    end)
  end

  @doc """
  SQL-pushdown cleanup variant — returns the concatenated id lists
  (`q1_ids ++ q2_ids`, plain id strings) to delete:

    * Q1 (age-expired — ALL deleted, no count trim):
      `finished_at IS NOT NULL AND finished_at < cutoff_iso` (strictly less
      than — a row exactly AT the cutoff is NOT age-expired).
    * Q2 (over-limit — beyond the newest `max_tasks` among the NON-age-expired
      finished rows, ordered newest-first):
      `finished_at IS NOT NULL AND finished_at >= cutoff_iso
       ORDER BY finished_at DESC LIMIT -1 OFFSET max_tasks`.

  `cutoff_iso` is a fixed-precision ISO string; the comparison is a TEXT
  comparison (the 24-char format sorts chronologically). Both queries read
  only the `id` column — nothing is decoded.
  """
  @spec select_cleanup_info(pid(), String.t(), non_neg_integer()) :: [String.t()]
  def select_cleanup_info(repo, cutoff_iso, max_tasks)
      when is_pid(repo) and is_binary(cutoff_iso) and is_integer(max_tasks) and max_tasks >= 0 do
    RepoScope.with_repo(repo, fn ->
      q1_ids =
        from(t in TaskRowRaw,
          where: not is_nil(t.finished_at) and t.finished_at < ^cutoff_iso,
          select: t.id
        )
        |> Repo.all()

      q2_ids =
        from(t in TaskRowRaw,
          where: not is_nil(t.finished_at) and t.finished_at >= ^cutoff_iso,
          order_by: [desc: t.finished_at],
          offset: ^max_tasks,
          select: t.id
        )
        |> Repo.all()

      q1_ids ++ q2_ids
    end)
  end

  # Decodes the raw `status` TEXT of a projected row into its atom via
  # `Codec.decode_atom/1` — the same per-row call the old handlers made
  # (warning log + nil on an unknown value, never a raise).
  defp decode_status_field(%{status: status} = row),
    do: %{row | status: Codec.decode_atom(status)}
end
