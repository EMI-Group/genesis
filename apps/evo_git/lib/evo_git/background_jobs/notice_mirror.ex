defmodule EvoGit.BackgroundJobs.NoticeMirror do
  @moduledoc """
  Public ETS mirror of the registry's terminal-but-unannounced background jobs.

  The mirror exists so the per-turn notice claim is ONE `:ets` operation instead of a `GenServer.call`: a busy, blocked or slow registry can no longer stall an agent's turn start, and the claim can never time out because there is no reply to wait for.
  The registry's own `%{jobs: ...}` map stays AUTHORITATIVE — the mirror is only a read path for that claim.
  It is written and deleted exclusively by `EvoGit.BackgroundJobs.put_job/2` (the ONE state writer) plus the explicit drops in `EvoGit.BackgroundJobs.Retention.prune/1` and `EvoGit.BackgroundJobs.terminate/2`, so every transition of every job keeps it correct.
  A record retention keeps as a TOMBSTONE (a live owner's still-unobserved finished record hitting the global valve) deliberately keeps its mirror row: the owner's pending notice must still be claimable.
  A row is `{{owner_pid, job_id}, job}` and carries the FULL job record, so a claim needs no registry state lookup.
  Rows exist EXACTLY for terminal, unannounced jobs: any other state deletes the row, which is what makes a second immediate claim empty.
  `:ets.take/2` is atomic per key, so two concurrent claimants can never both win one job — the loser's take answers `[]` and skips that job, which is the whole exactly-once guarantee (no lock, no registry round trip).
  The table is named after the registry's OWN registered name (an Erlang named ETS table and a registered process name are separate namespaces, so this creates no atom), is owned by the registry process, and dies with it.
  """

  require Logger

  alias EvoGit.BackgroundJobs.Notice

  @type table :: :ets.tab() | nil

  @doc """
  Creates the PUBLIC named mirror table for `name` and returns it, or `nil` when the table cannot be created.

  A pre-existing table of that name is deleted first: `:ets.new/2` raises `:badarg` on a duplicate name, and a stale table from a previous incarnation of the same name must not wedge a boot.
  Total by construction — creation is the ONE place a `:badarg` is possible, and a `nil` table only degrades the claim to `{:ok, []}`, never the registry.
  """
  @spec new(atom() | nil) :: table()
  def new(nil), do: nil

  def new(name) when is_atom(name) do
    case :ets.whereis(name) do
      :undefined -> :ok
      _existing -> :ets.delete(name)
    end

    :ets.new(name, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  rescue
    # Justified boundary: table setup must never take the shared registry down, and this is the only failure mode it has.
    exception ->
      Logger.warning(
        "BackgroundJobs: could not create the notice mirror table #{inspect(name)} (#{Exception.message(exception)}); finished-job notices will be empty"
      )

      nil
  end

  def new(_other), do: nil

  @doc """
  Resolves the mirror table for a registry handle AT CALL time: the name itself for an atom, the registered name of a pid, and `nil` for anything else or for a registry that is not registered.

  Total: never raises, and `:ets.whereis/1` only ever sees a real atom name (never `nil`).
  """
  @spec table_for(GenServer.server() | nil) :: table()
  def table_for(nil), do: nil

  def table_for(name) when is_atom(name), do: existing(name)

  def table_for(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> existing(name)
      _other -> nil
    end
  end

  def table_for(_server), do: nil

  defp existing(name) do
    case :ets.whereis(name) do
      :undefined -> nil
      _tid -> name
    end
  end

  @doc """
  Mirrors ONE job record: inserts it when it is terminal and not yet announced, otherwise deletes its row.

  Called from `EvoGit.BackgroundJobs.put_job/2`, so every transition is covered automatically — the terminal transition inserts, announcing (`read/2`, `list/1`, `kill/3`, and the `{:notices_claimed, ...}` cast) deletes, a non-terminal re-put deletes, and the owner-death kill path inserts its terminal record.
  TOTAL: a missing or concurrently deleted table is swallowed at this single boundary, because a mirror write must never crash the registry.
  """
  @spec put(table(), map()) :: :ok
  def put(nil, _job), do: :ok

  def put(table, job) when is_map(job) do
    if Notice.terminal?(job) and not Map.get(job, :announced, false) do
      :ets.insert(table, {key(job), job})
    else
      :ets.delete(table, key(job))
    end

    :ok
  catch
    # Justified boundary: `:badarg` covers the one real race (the table dying with its registry between resolution and this write); a lost mirror row only means a notice already answered `{:ok, []}`.
    :error, :badarg -> :ok
  end

  def put(_table, _job), do: :ok

  @doc """
  Drops ONE job's row — used by the explicit deletes OUTSIDE `put_job/2` (retention pruning).

  TOTAL for the same reason as `put/2`.
  """
  @spec delete(table(), map()) :: :ok
  def delete(nil, _job), do: :ok

  def delete(table, job) when is_map(job) do
    :ets.delete(table, key(job))
    :ok
  catch
    :error, :badarg -> :ok
  end

  def delete(_table, _job), do: :ok

  @doc """
  Removes every mirrored row — the registry's own `terminate/2` tidiness step (the table itself dies with the process).

  TOTAL.
  """
  @spec clear(table()) :: :ok
  def clear(nil), do: :ok

  def clear(table) do
    :ets.delete_all_objects(table)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  Claims (takes) every mirrored row belonging to `owner_pid`, returning `{:ok, jobs}` newest first with `announced: true` on each.

  `:ets.take/2` is ATOMIC per key, so two concurrent claimants can never both win the same job — a loser's take answers `[]` and that job is skipped.
  A missing table, an unknown owner or a table that dies mid-claim all answer `{:ok, []}`: the claim is total and never raises on an agent's turn path.
  """
  @spec claim(table(), pid() | nil) :: {:ok, [EvoGit.BackgroundJobs.job()]}
  def claim(nil, _owner_pid), do: {:ok, []}

  def claim(table, owner_pid) when is_pid(owner_pid) do
    claimed =
      table
      |> :ets.match_object({{owner_pid, :_}, :_})
      |> Enum.flat_map(fn {{owner, id}, _row} -> take(table, owner, id) end)

    {:ok, sort_newest_first_with_id(claimed)}
  catch
    # Justified boundary: the table dies with the registry, so a shutdown racing this read is a genuine `:badarg`; losing a notice is the documented degraded outcome, crashing a turn is not.
    :error, :badarg -> {:ok, []}
  end

  def claim(_table, _owner_pid), do: {:ok, []}

  defp take(table, owner_pid, id) do
    case :ets.take(table, {owner_pid, id}) do
      [{_key, job}] -> [Map.put(job, :announced, true)]
      [] -> []
    end
  end

  @doc false
  # The ONE newest-first ordering, shared by the claim and the registry's state-only reads: `started_at` microsecond DESC, then `id` ASC, so two jobs started in the same microsecond never come back in arbitrary map-iteration order.
  @spec sort_newest_first_with_id([map()]) :: [map()]
  def sort_newest_first_with_id(jobs), do: Enum.sort_by(jobs, &{-started_microseconds(&1), &1.id})

  @doc false
  # `started_at` in microseconds, with 0 for a record that has none (total).
  @spec started_microseconds(map()) :: integer()
  def started_microseconds(job) do
    case Map.get(job, :started_at) do
      %DateTime{} = started_at -> DateTime.to_unix(started_at, :microsecond)
      _other -> 0
    end
  end

  defp key(job), do: {Map.get(job, :owner_pid), Map.get(job, :id)}
end
