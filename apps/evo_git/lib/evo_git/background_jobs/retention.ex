defmodule EvoGit.BackgroundJobs.Retention do
  @moduledoc """
  Retention policy and TOMBSTONES for FINISHED background-job records.

  The policy answers ONE question: which finished records may leave the registry's authoritative map, and what does a caller see afterwards.
  Live (`:running` / `:stopping`) records are never touched here — retention only ever considers finished ones.

  Observation rule — a finished record whose owner has NOT observed its outcome (`announced == false`) AND whose owner pid is still alive is NEVER evicted by an ordinary cap, no matter how much OTHER agents churn.
  Such a record (and its notice-mirror row) is what an agent's next `job_output` / `job_list` and its pending completion notice depend on; deleting it is exactly how a live agent was once told "no background job with id … is known to this agent" about a job it had started.

  Caps, applied in this order (every trim is oldest-first by `{Notice.finished_key(job), job.id}`):
  1. `:max_dead_per_owner` (10) — per DEAD owner (a `nil` or dead `owner_pid` counts as dead): the oldest finished records beyond the cap are DELETED; a dead owner can never read them and its notice can never be claimed.
  2. `:max_observed_per_owner` (20) — per LIVE owner, over its announced records only: the oldest beyond the cap are DELETED.
  3. `:max_finished_total` (500) — ONE global safety valve over every remaining finished record: observed/dead-owner records are DELETED oldest-first, and only once those are exhausted is a live owner's UNOBSERVED record converted into a TOMBSTONE (never a silent delete), oldest-first.
  4. `:max_tombstones` (200) — tombstones themselves are capped, evicting the oldest first by `evicted_at` then `id`.

  A TOMBSTONE is a job-shaped map (see `EvoGit.BackgroundJobs.Retention.tombstone?/1`) that keeps an evicted-but-unobserved record's identity, status, exit code and log path so `job/2`, `read/2` and `list/1` can still answer HONESTLY instead of claiming the id was never issued.
  Converting a record to a tombstone deliberately LEAVES its notice-mirror row intact: the owner still learns the outcome through the normal per-turn notice, which is the path the record was protected for in the first place.

  `prune/1` takes and returns the registry's state map and reads/writes exactly `:jobs`, `:probes`, `:unknown_since`, `:notice_table`, `:tombstones` and `:retention`; the owner-monitor bookkeeping is NOT its business.
  The ONE side effect (as in the notice layer) is the notice-mirror row delete performed for a record that is genuinely GONE.
  Every function here is pure with respect to the process: no registry call, no file I/O, no timers, no app-env seams.
  """

  alias EvoGit.BackgroundJobs.Notice
  alias EvoGit.BackgroundJobs.NoticeMirror

  # The recognised retention caps, in the order the policy applies them. A
  # literal list — never a computed atom — and the ONLY keys an option may set.
  @cap_keys [:max_observed_per_owner, :max_dead_per_owner, :max_finished_total, :max_tombstones]

  @type policy :: %{
          max_observed_per_owner: pos_integer(),
          max_dead_per_owner: pos_integer(),
          max_finished_total: pos_integer(),
          max_tombstones: pos_integer()
        }

  @doc """
  The production retention policy: 20 announced records per live owner, 10 per dead owner, 500 finished records in total and 200 tombstones.
  """
  @spec defaults() :: policy()
  def defaults do
    %{
      max_observed_per_owner: 20,
      max_dead_per_owner: 10,
      max_finished_total: 500,
      max_tombstones: 200
    }
  end

  @doc """
  Normalizes the `:retention` START OPTION of the registry.

  Accepts a keyword list or a map: each recognised cap overlays `defaults/0` PER KEY, so a caller may set one cap and keep the rest.
  An absent key, a non-integer value and a non-positive value each fall back to that key's default, and unknown keys are ignored — a malformed option can never disable the policy.
  This is an opt-in overlay for ISOLATED registries (the suite's `:name` seam), never an app-env or TOML key.
  """
  @spec from_opts(term()) :: policy()
  def from_opts(opts) do
    Enum.reduce(@cap_keys, defaults(), fn key, acc ->
      case option(opts, key) do
        value when is_integer(value) and value > 0 -> Map.put(acc, key, value)
        _other -> acc
      end
    end)
  end

  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)

  defp option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key), else: nil
  end

  defp option(_opts, _key), do: nil

  @doc """
  Applies the whole retention policy to the registry state and returns the new state.

  Runs `Notice.prune_unknown_since/1` first (the unknown-grace markers of no-longer-live jobs are bookkeeping, not records), then the four caps in the documented order.
  Every evicted record also loses its `:probes` entry and its notice-mirror row; a TOMBSTONED record loses its probe entry but KEEPS its mirror row so the owner's pending notice still arrives.
  Total over a partial state map (missing keys are treated as empty / default), so an isolated test registry needs no setup.
  """
  @spec prune(map()) :: map()
  def prune(state) do
    state =
      state
      |> Map.put_new(:jobs, %{})
      |> Map.put_new(:probes, %{})
      |> Map.put_new(:unknown_since, %{})
      |> Map.put_new(:notice_table, nil)
      |> Map.put_new(:tombstones, %{})
      |> Map.update(:retention, defaults(), &from_opts/1)

    state = %{state | unknown_since: Notice.prune_unknown_since(state)}

    state
    |> prune_dead_owners()
    |> prune_observed_owners()
    |> enforce_finished_total()
    |> prune_tombstones()
  end

  @doc """
  True iff the map is a TOMBSTONE — an evicted finished record that is kept as an honest answer rather than deleted.

  The predicate is the presence of `:evicted_reason`, which no live or ordinary record carries; callers that render or serve such a map branch on exactly this.
  """
  @spec tombstone?(term()) :: boolean()
  def tombstone?(job) when is_map(job), do: Map.has_key?(job, :evicted_reason)
  def tombstone?(_job), do: false

  @doc "Fetches one tombstone from the registry state by id (total)."
  @spec fetch_tombstone(map(), String.t()) :: {:ok, map()} | :error
  def fetch_tombstone(state, id) when is_binary(id) do
    state
    |> Map.get(:tombstones, %{})
    |> Map.fetch(id)
  end

  @doc """
  Stores an updated tombstone back into the registry state — used when a `read/2` advances a tombstone's saved `cursor` / `lines_read`.
  """
  @spec update_tombstone(map(), map()) :: map()
  def update_tombstone(state, %{id: id} = tombstone) do
    Map.put(state, :tombstones, Map.put(Map.get(state, :tombstones, %{}), id, tombstone))
  end

  ## Cap 1 + 2 — per-owner caps

  defp prune_dead_owners(state) do
    cap = state.retention.max_dead_per_owner

    state
    |> finished_records()
    |> Enum.reject(&live_owner?/1)
    |> Enum.group_by(&Map.get(&1, :owner_pid))
    |> Enum.reduce(state, fn {_owner_pid, jobs}, acc -> evict_oldest(acc, jobs, cap) end)
  end

  defp prune_observed_owners(state) do
    cap = state.retention.max_observed_per_owner

    state
    |> finished_records()
    |> Enum.filter(&(live_owner?(&1) and observed?(&1)))
    |> Enum.group_by(&Map.get(&1, :owner_pid))
    |> Enum.reduce(state, fn {_owner_pid, jobs}, acc -> evict_oldest(acc, jobs, cap) end)
  end

  ## Cap 3 — the global safety valve

  defp enforce_finished_total(state) do
    finished = finished_records(state)
    excess = length(finished) - state.retention.max_finished_total

    if excess > 0 do
      {protected, evictable} = Enum.split_with(finished, &protected?/1)
      {evicted, _kept} = evictable |> sort_oldest_first() |> Enum.split(excess)

      # The deletion pass always spends the whole excess when enough evictable
      # records exist; whatever remains OVER the cap can only be a live owner's
      # unobserved record, which leaves as a tombstone.
      remaining = excess - length(evicted)

      state = Enum.reduce(evicted, state, &evict_job(&2, &1))

      protected
      |> sort_oldest_first()
      |> Enum.take(max(remaining, 0))
      |> Enum.reduce(state, &tombstone_job(&2, &1))
    else
      state
    end
  end

  ## Cap 4 — tombstones

  defp prune_tombstones(state) do
    excess = map_size(state.tombstones) - state.retention.max_tombstones

    if excess > 0 do
      dropped =
        state.tombstones
        |> Map.values()
        |> Enum.sort_by(&{evicted_key(&1), Map.get(&1, :id)})
        |> Enum.take(excess)
        |> MapSet.new(& &1.id)

      %{
        state
        | tombstones: Map.reject(state.tombstones, fn {id, _t} -> MapSet.member?(dropped, id) end)
      }
    else
      state
    end
  end

  defp evicted_key(tombstone) do
    case Map.get(tombstone, :evicted_at) do
      %DateTime{} = evicted_at -> DateTime.to_unix(evicted_at, :microsecond)
      _other -> 0
    end
  end

  ## Record classification

  defp finished_records(state), do: state.jobs |> Map.values() |> Enum.reject(&Notice.live?/1)

  defp live_owner?(job) do
    case Map.get(job, :owner_pid) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  end

  defp observed?(job), do: Map.get(job, :announced, false) == true

  # A live owner that has NOT observed the outcome: the only shape an ordinary
  # cap may not touch, and the only shape that may become a tombstone.
  defp protected?(job), do: live_owner?(job) and not observed?(job)

  defp sort_oldest_first(jobs),
    do: Enum.sort_by(jobs, &{Notice.finished_key(&1), Map.get(&1, :id)})

  ## Record transitions

  defp evict_oldest(state, jobs, cap) do
    excess = length(jobs) - cap

    jobs
    |> sort_oldest_first()
    |> Enum.take(max(excess, 0))
    |> Enum.reduce(state, &evict_job(&2, &1))
  end

  # A record that is GONE: the map entry, its cached probe and its notice-mirror
  # row all go, so nothing outlives the record it describes.
  defp evict_job(state, job) do
    NoticeMirror.delete(state.notice_table, job)

    %{
      state
      | jobs: Map.delete(state.jobs, job.id),
        probes: Map.delete(state.probes, job.id)
    }
  end

  # A record kept as an ANSWER: it leaves the authoritative map (it can never
  # change status again) but its mirror row STAYS, so the owner's pending notice
  # is still claimable.
  defp tombstone_job(state, job) do
    tombstone = tombstone_for(job, :retention)

    %{
      state
      | jobs: Map.delete(state.jobs, job.id),
        probes: Map.delete(state.probes, job.id),
        tombstones: Map.put(state.tombstones, tombstone.id, tombstone)
    }
  end

  defp tombstone_for(job, reason) do
    %{
      id: Map.get(job, :id),
      kind: Map.get(job, :kind),
      label: Map.get(job, :label),
      owner_pid: Map.get(job, :owner_pid),
      status: Map.get(job, :status),
      exit_code: Map.get(job, :exit_code),
      terminal_reason: Map.get(job, :terminal_reason),
      detail: Map.get(job, :detail),
      started_at: Map.get(job, :started_at),
      finished_at: Map.get(job, :finished_at),
      output_path: Map.get(job, :output_path),
      cursor: Map.get(job, :cursor),
      lines_read: Map.get(job, :lines_read),
      announced: true,
      evicted_reason: reason,
      evicted_at: DateTime.utc_now()
    }
  end
end
