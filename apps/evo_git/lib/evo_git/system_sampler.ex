defmodule EvoGit.SystemSampler do
  @moduledoc """
  Supervised GenServer that samples scheduler status every 3 seconds and
  broadcasts it on the `EvoGit.PubSub` topic `"system"`.

  Runs on EVERY node running the `:evo_git` application — including the
  headless `genesis_remote` daemon — so the dashboard can render remote
  scheduler charts from these pushes (Phoenix.PubSub is already an `:evo_git`
  dependency and its PG2 adapter propagates broadcasts across nodes).

  ## Event contract

  One broadcast per tick:

      {:system_sample, node, seq, sample}

  * `node` — the sampling node (`node()`; sampling is LOCAL-only, no RPC).
  * `seq` — monotonically increasing integer per sampler instance.
  * `sample` — a map with EXACTLY these keys (no extras):

        llm_slots, llm_used, llm_waiting, tool_used, tool_waiting,
        llm_capacity, tool_capacity,
        agents_total, agents_running, agents_blocked, agents_waiting,
        agents_pending, scheduler_alive

    `llm_slots` is the real per-model LLM slot occupancy, read live from the
    scheduler GenServer state every tick (see "Sampling semantics" below):

        llm_slots: %{model_id => %{used: non_neg_integer, waiting: non_neg_integer, capacity: non_neg_integer}}

  ## Sampling semantics (proxy, must stay truthful)

  `llm_slots` reports REAL per-model LLM slot occupancy, fetched per tick from
  the `EvoGit.AgentScheduler` GenServer state via the scheduler's
  `get_llm_slot_status/0` read API: `used` is the true holder count
  (`MapSet.size` of the model's holder pool), `waiting` the true queued count
  (`:queue.len`), and `capacity` the model's effective capacity exactly as the
  scheduler grants it — a peak-paused model reports `0` and the value tracks
  peak/off-peak transitions. This observation point is the scheduler GenServer
  read API itself, NOT `RemoteAPI` (that surface is intentionally ETS-pure).

  The aggregated `llm_used`/`llm_waiting` keys and both tool keys remain
  clearly-labeled status proxies, kept for backward compatibility: `:running`
  (the agents that acquire/hold slots) feeds the "used" lines, `:blocked`
  (agents waiting for a slot, the saturation signal) feeds the "waiting"
  lines. The same `:running`/`:blocked` counts feed both the LLM and tool
  charts; only the capacity lines differ. This reproduces the dashboard's old
  chart semantics exactly (`EvoDashWeb.SystemLive.Charts`, deleted from
  evo_dash by the parallel workstream).

  ## Tick & configuration cache

  The tick is a `Process.send_after(self(), :sample_tick, interval)` self
  message, rescheduled BEFORE sampling so a slow step never breaks cadence.
  The interval is read ONCE at init from
  `Application.get_env(:evo_git, :system_sample_interval_ms, 3000)` (tests set
  it high, e.g. 86_400_000, and drive ticks via `tick/0` or by sending
  `:sample_tick` directly to the sampler process).

  Capacity totals (`llm_capacity`, `tool_capacity`) come from the RESOLVED
  scheduler config, cached in state and refreshed every 10th tick on the
  dashboard's `rem(tick, 10) != 1` rule (tick 1 always loads; a cache miss
  refetches on any tick; zero capacities from the dead-scheduler branch are
  NEVER cached).

  The per-model `llm_slots` map is NOT part of that cache: it is fetched LIVE
  every tick via `EvoGit.AgentScheduler.get_llm_slot_status/0` so holder and
  queue changes (slot grants, releases, peak-pause flips) show up on the very
  next 3s sample. The per-model `capacity` values therefore come from the
  scheduler-returned effective capacity (`State.concurrency_for/2` — peak-pause
  correctness), not from the static profile `concurrency` in the config cache;
  the aggregate `llm_capacity` key keeps its cached Σ-profiled-concurrency
  value.

  **Config source — `RemoteAPI.get_config/0` (a scheduler `GenServer.call`).**
  Chosen because the chart must reflect the LIVE runtime config (including
  runtime overrides such as CLI `-c` and dashboard saves), and the scheduler's
  resolved config lives only in the GenServer state — it is not mirrored to
  ETS. `Config.resolve/0` would re-read disk and miss runtime overrides, and
  there is no cheaper in-process read; a cached call every 10 ticks is the
  same cost profile the dashboard's `chart_totals/3` had.

  ## Graceful degradation

  When the scheduler/ETS is absent (`scheduler_alive?/0` false) the sample has
  zero agent counts, zero capacities, and `llm_slots: %{}` with
  `scheduler_alive: false` — mirrors the dashboard's dead branch. Broadcasts
  continue (the dashboard rendered zero samples in the dead branch too). The
  sampler never calls into a dead scheduler: the config refetch and the live
  `llm_slots` fetch are additionally gated on
  `Process.whereis(EvoGit.AgentScheduler) != nil`, so no `GenServer.call`
  exits (and no try/rescue — project policy).

  ## API

  * `get_recent_samples/0` — the last 60 samples (ring buffer).
  * `tick/0` — synchronous sampling tick (test seam).
  * `scheduler_alive?/0`, `status_counts/1`, `config_totals/1`,
    `build_sample/3,4`, `push/3` — pure helpers (public for tests; the
    dashboard's old `Charts` equivalents are deleted).
  """

  use GenServer

  alias EvoGit.AgentScheduler.RemoteAPI

  @topic "system"
  @sample_capacity 60
  @config_refresh_divisor 10

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Starts the sampler. `:name` defaults to `__MODULE__` (pass `name: nil` for
  an unregistered instance — tests). `:interval_ms` overrides the
  `:system_sample_interval_ms` application env.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Returns the ring buffer of recent samples (oldest first, at most 60).

  `{:error, :not_found}` when the sampler process is not running. A
  `GenServer.call` to a dead process would exit the caller with `:noproc`, so
  the process is looked up first — the guard converts that exit into a
  returned error value (the failure is surfaced to the caller, not swallowed;
  this is the project's no-try/rescue policy at a process boundary).
  """
  @spec get_recent_samples() :: {:ok, [map()]} | {:error, :not_found}
  def get_recent_samples do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_recent_samples)
    end
  end

  @doc """
  Runs one sampling tick synchronously (broadcast + ring-buffer push happen
  before the reply). Test seam: tests set a long `:system_sample_interval_ms`
  and drive sampling with this call — or by sending `:sample_tick` to the
  sampler process (same handler, no reply).
  """
  @spec tick() :: :ok | {:error, :not_found}
  def tick do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :tick)
    end
  end

  @doc """
  Scheduler liveness gate — same definition as the dashboard's
  `scheduler_alive?/1`: the scheduler process is registered, OR its ETS table
  still exists (crash-restart window).
  """
  @spec scheduler_alive?() :: boolean()
  def scheduler_alive? do
    Process.whereis(EvoGit.AgentScheduler) != nil or :ets.info(:evogit_sched_meta) != :undefined
  end

  @doc """
  Per-status agent counts. Reproduces the dashboard's `Charts.status_counts/1`
  grouping exactly: `total/running/blocked/waiting/pending/ready`, with
  missing/unknown statuses counting as `:unknown` (i.e. excluded from every
  named bucket).
  """
  @spec status_counts([map()]) :: map()
  def status_counts(agents) when is_list(agents) do
    counts = Enum.frequencies_by(agents, fn agent -> Map.get(agent, :status, :unknown) end)

    %{
      total: length(agents),
      running: Map.get(counts, :running, 0),
      blocked: Map.get(counts, :blocked, 0),
      waiting: Map.get(counts, :waiting, 0),
      pending: Map.get(counts, :pending, 0),
      ready: Map.get(counts, :ready, 0)
    }
  end

  @doc """
  Extracts slot capacities from a resolved config map (same computation as the
  dashboard's `Charts.config_totals/1`): LLM = Σ per-profile `concurrency`,
  tool = `max_tool_concurrency`. Missing/unknown keys or a non-map yield zero
  capacities.
  """
  @spec config_totals(term()) :: %{llm_capacity: integer(), tool_capacity: integer()}
  def config_totals(config) when is_map(config) do
    llm =
      Enum.reduce(Map.get(config, :model_profiles, []), 0, fn profile, acc ->
        acc + (Map.get(profile, :concurrency) || 0)
      end)

    %{llm_capacity: llm, tool_capacity: Map.get(config, :max_tool_concurrency) || 0}
  end

  def config_totals(_), do: %{llm_capacity: 0, tool_capacity: 0}

  @doc """
  Builds one sample map (the 13-key contract map — no extra keys) from status
  counts, capacity totals, the live per-model LLM slot map and the
  scheduler-liveness flag.

  * `llm_slots` — real per-model LLM slot occupancy read live from the
    scheduler GenServer state (`EvoGit.AgentScheduler.get_llm_slot_status/0`);
    the scheduler-dead shape is `%{}`.
  * The aggregated `llm_used`/`llm_waiting` and both tool keys are the
    `:running`/`:blocked` status proxies (see moduledoc), kept for backward
    compatibility.
  """
  @spec build_sample(map(), map(), map(), boolean()) :: map()
  def build_sample(counts, totals, llm_slots, scheduler_alive)
      when is_map(counts) and is_map(totals) and is_map(llm_slots) and
             is_boolean(scheduler_alive) do
    %{
      llm_slots: llm_slots,
      llm_used: counts.running,
      llm_waiting: counts.blocked,
      llm_capacity: totals.llm_capacity,
      tool_used: counts.running,
      tool_waiting: counts.blocked,
      tool_capacity: totals.tool_capacity,
      agents_total: counts.total,
      agents_running: counts.running,
      agents_blocked: counts.blocked,
      agents_waiting: counts.waiting,
      agents_pending: counts.pending,
      scheduler_alive: scheduler_alive
    }
  end

  @doc """
  Backward-compat 3-arity of `build_sample/4`: composes a sample without live
  per-model slot data (`llm_slots: %{}` — the scheduler-dead shape). The
  sampler's live tick path uses `build_sample/4` with the per-tick-fetched
  `llm_slots` map.
  """
  @spec build_sample(map(), map(), boolean()) :: map()
  def build_sample(counts, totals, scheduler_alive)
      when is_map(counts) and is_map(totals) and is_boolean(scheduler_alive) do
    build_sample(counts, totals, %{}, scheduler_alive)
  end

  @doc """
  Appends a sample to the ring buffer, keeping at most `capacity` samples
  (oldest dropped). Default capacity is 60 samples ≈ 3 minutes at 3s ticks —
  same as the dashboard's `Charts.push/3`.
  """
  @spec push(list(), map(), pos_integer()) :: list()
  def push(buffer, sample, capacity \\ @sample_capacity) when is_list(buffer) do
    (buffer ++ [sample]) |> Enum.take(-capacity)
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :interval_ms) ||
        Application.get_env(:evo_git, :system_sample_interval_ms, 3000)

    state = %{
      samples: [],
      seq: 0,
      tick: 0,
      config_cache: nil,
      interval_ms: interval
    }

    schedule_next_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample_tick, state) do
    # Reschedule FIRST so the cadence stays steady even if a sampling step is
    # slow (mirrors the dashboard's tick handling).
    schedule_next_tick(state)
    {:noreply, do_sample(state)}
  end

  @impl true
  def handle_call(:get_recent_samples, _from, state) do
    {:reply, {:ok, state.samples}, state}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {:reply, :ok, do_sample(state)}
  end

  # ── Private ──────────────────────────────────────────────────────

  defp schedule_next_tick(%{interval_ms: interval}) do
    Process.send_after(self(), :sample_tick, interval)
  end

  defp do_sample(state) do
    state = %{state | tick: state.tick + 1}

    if scheduler_alive?() do
      state = maybe_refresh_config(state)

      sample =
        build_sample(
          status_counts(read_sched_metas()),
          cached_totals(state),
          fetch_llm_slots(),
          true
        )

      broadcast_and_store(state, sample)
    else
      # Dead scheduler: zero agents, zero capacities and an empty llm_slots
      # map — mirrors the dashboard's dead branch (`{[], nil}`). Zero
      # capacities are NOT cached (see maybe_refresh_config).
      sample = build_sample(status_counts([]), zero_totals(), %{}, false)
      broadcast_and_store(state, sample)
    end
  end

  # Per-tick live read of the per-model LLM slot status from the scheduler
  # GenServer state (`get_llm_slot_status/0` — cheap pure in-state reads).
  # The whereis guard mirrors maybe_refresh_config: NEVER GenServer.call a dead
  # scheduler (a call would exit the sampler with :noproc; no try/rescue —
  # project policy). scheduler_alive?/0 can be true while the scheduler
  # process is down (ETS table still exists, crash-restart window) — in that
  # window the live data is unavailable and the dead shape (%{}) is reported.
  defp fetch_llm_slots do
    if Process.whereis(EvoGit.AgentScheduler) != nil do
      EvoGit.AgentScheduler.get_llm_slot_status()
    else
      %{}
    end
  end

  # 10-tick config-cache rule (dashboard's `rem(tick, 10) != 1`): use the
  # cache except on ticks 1, 11, 21…; a missing cache refetches on any tick.
  defp maybe_refresh_config(%{tick: tick, config_cache: {_totals, _loaded_tick}} = state)
       when rem(tick, @config_refresh_divisor) != 1 do
    state
  end

  defp maybe_refresh_config(state) do
    if Process.whereis(EvoGit.AgentScheduler) != nil do
      # Config source: RemoteAPI.get_config/0 (scheduler GenServer call) — the
      # same resolved config (incl. runtime overrides) the dashboard's chart
      # capacities used; see moduledoc for the choice rationale.
      %{state | config_cache: {config_totals(RemoteAPI.get_config()), state.tick}}
    else
      # Scheduler process down (ETS may still exist): keep the last-known
      # totals without re-caching. Never cache zero/stale totals — the
      # dead-scheduler branch must not suppress the next refresh.
      state
    end
  end

  defp cached_totals(%{config_cache: {totals, _loaded_tick}}), do: totals
  defp cached_totals(_state), do: zero_totals()

  defp zero_totals, do: %{llm_capacity: 0, tool_capacity: 0}

  # Reads all sched-meta entries (guarded — returns [] when the table doesn't
  # exist yet, mirroring RemoteAPI's private read_table/1). Status comes from
  # `meta.status` — the exact source `RemoteAPI.build_agent_summary/3` uses
  # for the summary `:status` field, so status_counts/1 here yields the same
  # grouping as the dashboard's old chart over RemoteAPI.list_agents/0.
  defp read_sched_metas do
    case :ets.whereis(:evogit_sched_meta) do
      :undefined -> []
      _ -> for {_agent_id, meta} <- :ets.tab2list(:evogit_sched_meta), do: meta
    end
  end

  defp broadcast_and_store(state, sample) do
    seq = state.seq + 1
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic, {:system_sample, node(), seq, sample})
    %{state | seq: seq, samples: push(state.samples, sample)}
  end
end
