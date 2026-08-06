defmodule EvoDashWeb.TasksLive.DirtyTracker do
  @moduledoc """
  Dirty-check state for the Tasks page's remote-node polling.

  When viewing a remote `genesis_remote` daemon, the Tasks LiveView polls every
  3s (`:remote_poll`) because cross-node PubSub may be unreliable. Instead of
  transferring the full paginated page of `EvoGit.TaskInfo` structs (plus the
  COUNT and DISTINCT-project-paths queries) over `:erpc` on every tick, each
  tick first fetches only the lightweight changed-since summaries (usually
  `[]`) and reloads the full page only when something actually changed.

  This module tracks the baseline `updated_at` timestamp (fixed-precision ISO
  strings — lexicographic comparison is chronological) and the ticks elapsed
  since the last full re-sync.

  ## Deletion reconcile

  A changed-since query cannot detect *deleted* tasks (they no longer have an
  `updated_at` to compare). To bound deletion staleness, the tracker forces a
  full re-sync every `full_resync_every` ticks (default 10 ticks = ~30s at the
  3s cadence): the `:resync` action triggers the same full page reload as
  `:reload`, refreshing the task set, count, and project paths. This is chosen
  over per-tick count comparisons (an extra RPC per tick) and id-set
  reconciliation (requires holding the full remote task list in memory —
  exactly what the dirty check avoids).
  """

  defstruct node: nil,
            last_seen_updated_at: nil,
            ticks_since_full_resync: 0,
            full_resync_every: 10

  @type t :: %__MODULE__{
          node: node() | nil,
          last_seen_updated_at: String.t() | nil,
          ticks_since_full_resync: non_neg_integer(),
          full_resync_every: pos_integer()
        }

  @doc """
  Builds a new tracker. `:full_resync_every` (no-change ticks before a forced
  full re-sync) is overridable via opts; tests use small values.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{full_resync_every: Keyword.get(opts, :full_resync_every, 10)}
  end

  @doc """
  Seeds the tracker for a node from task summaries: binds the node, advances
  the baseline to the max `:updated_at` (the `""` sentinel when the list is
  empty), and resets the resync tick counter.
  """
  @spec seed(t(), node(), [map()]) :: t()
  def seed(tracker, node, summaries) do
    %{
      tracker
      | node: node,
        last_seen_updated_at: max_updated_at(summaries),
        ticks_since_full_resync: 0
    }
  end

  @doc """
  Returns the max `:updated_at` string across task summary maps, or `""` for
  an empty list. Fixed-precision ISO strings sort lexicographically in
  chronological order, so plain string comparison is correct. `""` is the
  "nothing seen yet" sentinel — all real `updated_at` strings are non-empty
  and sort greater.
  """
  @spec max_updated_at([map()]) :: String.t()
  def max_updated_at(tasks) do
    tasks
    |> Enum.map(&Map.get(&1, :updated_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> "" end)
  end

  @doc """
  Evaluates one poll tick against the changed-since summaries.

  Returns `{action, tracker}`:

  - changed non-empty → `{:reload, tracker}` with the baseline advanced to
    `max_updated_at(changed)` and the resync counter reset. Changed is *all*
    tasks with `updated_at` greater than the old baseline, so its max IS the
    new global max — no extra summary fetch is needed after a reload.
  - changed empty and `ticks_since_full_resync + 1 >= full_resync_every` →
    `{:resync, tracker}` with the counter reset (deletion safeguard).
  - changed empty otherwise → `{:noop, tracker}` with the counter incremented.
  - unseeded baseline (`last_seen_updated_at == nil`): seeds from changed
    (`max_updated_at`), `{:reload, ...}` when changed is non-empty, else
    `{:noop, tracker}` — belt-and-braces; the LiveView normally seeds first.
  """
  @spec evaluate(t(), [map()]) :: {:reload | :resync | :noop, t()}
  def evaluate(%__MODULE__{last_seen_updated_at: nil} = tracker, changed) do
    case changed do
      [] -> {:noop, tracker}
      _ -> {:reload, advance(tracker, changed)}
    end
  end

  def evaluate(%__MODULE__{} = tracker, []) do
    if tracker.ticks_since_full_resync + 1 >= tracker.full_resync_every do
      {:resync, %{tracker | ticks_since_full_resync: 0}}
    else
      {:noop, %{tracker | ticks_since_full_resync: tracker.ticks_since_full_resync + 1}}
    end
  end

  def evaluate(%__MODULE__{} = tracker, changed) do
    {:reload, advance(tracker, changed)}
  end

  defp advance(tracker, changed) do
    %{
      tracker
      | last_seen_updated_at: max_updated_at(changed),
        ticks_since_full_resync: 0
    }
  end
end
