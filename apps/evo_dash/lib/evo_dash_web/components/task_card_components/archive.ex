defmodule EvoDashWeb.TaskCardComponents.Archive do
  @moduledoc """
  Total readers for the lazily-fetched, PAGED archive envelope
  (`detail.archive`).

  The envelope is owned by `EvoDashWeb.TasksLive.TaskDetail`; every reader here
  is TOTAL, so a nil/odd shape falls back to the empty/on-demand state instead of
  crashing the card.
  The `opts[:archive]` opt-in check lives in `EvoDashWeb.ArchiveHelpers` (the
  single definition, delegated here under its historical name) — this module
  only reads the envelope.
  """

  # ---------------------------------------------------------------------------
  # Helpers — lazy archive envelope (`detail.archive`)
  # ---------------------------------------------------------------------------
  #
  # Archive records are NOT on the summary map: the FIRST page is fetched on
  # demand via the `load_task_archive` event, further pages append via
  # `load_more_task_archive`, and one agent's heavy `"result"` is fetched on
  # demand via `load_task_archive_agent_result`. The envelope is
  # `%{state: :loading | :ok | :error, entries: [map()], total: non_neg_integer(),
  # next_offset: non_neg_integer(), loading_more?: boolean(),
  # more_error: term() | nil, error: term() | nil, seq: pos_integer(),
  # agent_results: %{agent_id => %{state:, entry:, error:}},
  # dropped: non_neg_integer(), exhausted?: boolean(),
  # server_total: non_neg_integer() | nil}`.
  #
  # `total`/`server_total` are OPTIONAL: the store's page reads may stop
  # returning `COUNT(*)`, so every reader below stays TOTAL when they are
  # absent (`total` falls back to the loaded count, `server_total` to nil).

  @doc """
  The archive envelope's first-page state: `:loading`, `:ok`, `:error`, or nil
  when no archive has been requested yet (`detail.archive == nil`).
  """
  def archive_state(archive) do
    case archive do
      %{state: state} -> state
      %{"state" => state} -> state
      _ -> nil
    end
  end

  @doc """
  The archive entries loaded so far (every appended page, in read order).

  Kept under the historical name `archive_records/1` so the card markup and its
  tests stay stable; the list is the page accumulation, never the full archive.
  """
  def archive_records(archive) do
    case archive do
      %{entries: entries} when is_list(entries) -> entries
      %{"entries" => entries} when is_list(entries) -> entries
      _ -> []
    end
  end

  @doc """
  The TRUE number of archive entries on the task (not just the loaded page).

  Falls back to the number of loaded entries when the envelope carries no usable
  `total` (a nil/garbage envelope → `0`).
  """
  def archive_total(archive) do
    case archive do
      %{total: total} when is_integer(total) and total >= 0 -> total
      %{"total" => total} when is_integer(total) and total >= 0 -> total
      _ -> length(archive_records(archive))
    end
  end

  @doc """
  The number of leading archive rows EVICTED by the retention window (their
  records are no longer loaded). Non-negative integer; `0` when absent/garbage.
  """
  def archive_dropped(archive) do
    case archive do
      %{dropped: dropped} when is_integer(dropped) and dropped >= 0 -> dropped
      %{"dropped" => dropped} when is_integer(dropped) and dropped >= 0 -> dropped
      _ -> 0
    end
  end

  @doc """
  True iff the archive is EXHAUSTED (a short/empty page arrived), so the pager is
  replaced by the exhaustion note. Absent/garbage → `false`.
  """
  def archive_exhausted?(archive) do
    case archive do
      %{exhausted?: true} -> true
      %{"exhausted?" => true} -> true
      _ -> false
    end
  end

  @doc """
  The archive's TRUE size as reported by the server, for the label only.

  `nil` when the envelope carries no usable count (the page reads may stop
  returning `COUNT(*)`), so the render site falls back to the effective total.
  """
  def archive_server_total(archive) do
    case archive do
      %{server_total: total} when is_integer(total) and total >= 0 -> total
      %{"server_total" => total} when is_integer(total) and total >= 0 -> total
      _ -> nil
    end
  end

  @doc """
  The per-agent lazily-fetched result cache: `%{agent_id => %{state:, entry:,
  error:}}`. `%{}` when the envelope carries none (nil/garbage → `%{}`).
  """
  def archive_agent_results(archive) do
    case archive do
      %{agent_results: %{} = results} -> results
      %{"agent_results" => %{} = results} -> results
      _ -> %{}
    end
  end

  @doc "True while an append page is in flight (defaults to `false`)."
  def archive_loading_more?(archive) do
    case archive do
      %{loading_more?: true} -> true
      %{"loading_more?" => true} -> true
      _ -> false
    end
  end

  @doc "The last append page's failure reason, or nil (defaults to nil)."
  def archive_more_error(archive) do
    case archive do
      %{more_error: reason} -> reason
      %{"more_error" => reason} -> reason
      _ -> nil
    end
  end

  @doc """
  True iff the task's `opts` opted into archiving (`[archive: true]` from the
  dashboard, `[archive: "true"]` from the CLI / task data plane).

  Delegates to the shared `EvoDashWeb.ArchiveHelpers.archive_opt?/1`, which owns
  that definition; the name is kept here for the task card's import site.
  """
  defdelegate archive_opt?(opts), to: EvoDashWeb.ArchiveHelpers
end
