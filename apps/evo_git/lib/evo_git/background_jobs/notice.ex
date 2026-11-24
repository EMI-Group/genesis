defmodule EvoGit.BackgroundJobs.Notice do
  @moduledoc """
  The notice/announce rules for background-job records.

  `announced` means "the owner already knows this job's outcome — no completion notice needed": it starts `false`, and is set by the per-turn claim (`EvoGit.BackgroundJobs.NoticeMirror`), by `read/2` / `list/1` for the terminal jobs they return, and by a successful `kill/3`.
  This module owns the record-level marking (`mark_announced/1`, `suppress_notice/1`), the status predicates every marking decision branches on (`terminal?/1`, `live?/1` — the ONE source of those two vocabularies), the newest-first ordering of the state-only reads (`sort_newest_first/1`) and the two ordering/bookkeeping helpers retention shares with it (`prune_unknown_since/1`, `finished_key/1`).
  RETENTION itself — the caps, the observation rule and the tombstones — belongs to `EvoGit.BackgroundJobs.Retention`.
  Every function here is pure with respect to the process — no registry call and no file I/O.

  `prune_unknown_since/1` takes the registry's state map (reading `:jobs` and `:unknown_since`).
  """

  alias EvoGit.BackgroundJobs.NoticeMirror

  @doc """
  Terminal = the job can never change status again, so it is eligible for a (single) completion notice.
  """
  @spec terminal?(term()) :: boolean()
  def terminal?(%{status: status}), do: status in [:completed, :killed, :failed]
  def terminal?(_job), do: false

  @doc "Live = the job may still change status (a `:stopping` record is live: its observer still settles it)."
  @spec live?(term()) :: boolean()
  def live?(%{status: status}), do: status in [:running, :stopping]
  def live?(_job), do: false

  @doc """
  Marks a terminal job as announced ONCE; never resets back to `false` and never touches a live job.
  """
  @spec mark_announced(map()) :: map()
  def mark_announced(job) do
    if terminal?(job) and not job.announced do
      %{job | announced: true}
    else
      job
    end
  end

  @doc """
  The kill path's own marking: the caller REQUESTED the stop, so it knows the outcome.
  Unlike `mark_announced/1` this also applies to a non-terminal record (a `:stopping` unit handle settles later), so the later finish cannot resurrect a notice.
  """
  @spec suppress_notice(map()) :: map()
  def suppress_notice(job), do: %{job | announced: true}

  @doc """
  Newest-first ordering for the reconciled reads: `started_at` microsecond DESC, with a record that has no `started_at` last.
  """
  @spec sort_newest_first([map()]) :: [map()]
  def sort_newest_first(jobs),
    do: Enum.sort_by(jobs, &NoticeMirror.started_microseconds/1, :desc)

  @doc """
  Drops the unknown-grace markers of jobs that are no longer live.

  The floor only ever tracks LIVE jobs: a job that reached a terminal status by another route (a kill, or its observer port's exit message) drops its marker here, so the bookkeeping cannot grow without bound.
  """
  @spec prune_unknown_since(map()) :: %{optional(String.t()) => integer()}
  def prune_unknown_since(state) do
    state.unknown_since
    |> Enum.filter(fn {id, _since} -> live?(Map.get(state.jobs, id)) end)
    |> Map.new()
  end

  @doc "Sort key for retention: `finished_at` in microseconds, with 0 for a record that has none (total)."
  @spec finished_key(map()) :: integer()
  def finished_key(job) do
    case job.finished_at do
      %DateTime{} = finished_at -> DateTime.to_unix(finished_at, :microsecond)
      _ -> 0
    end
  end
end
