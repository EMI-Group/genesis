defmodule EvoGit.SystemSampler do
  @moduledoc """
  Supervised GenServer that samples scheduler status every 3 seconds and
  broadcasts it on the `EvoGit.PubSub` topic `"system"`.

  Runs on EVERY node running the `:evo_git` application — including the
  headless `genesis_server` daemon — so the dashboard can render remote
  scheduler charts from these pushes (Phoenix.PubSub is already an `:evo_git`
  dependency and its PG2 adapter propagates broadcasts across nodes).

  ## Event contract

  One broadcast per tick:

      {:system_sample, node, seq, sample}

  * `node` — the sampling node (`node()`; sampling is LOCAL-only, no RPC).
  * `seq` — monotonically increasing integer per sampler instance.
  * `sample` — a map with EXACTLY these 14 keys (no extras):

        llm_slots, llm_pools, llm_used, llm_waiting, tool_used, tool_waiting,
        llm_capacity, tool_capacity,
        agents_total, agents_running, agents_blocked, agents_waiting,
        agents_pending, scheduler_alive

    `llm_slots` is the real per-model LLM slot occupancy, read live from the
    scheduler GenServer state every tick (see "Sampling semantics" below):

        llm_slots: %{model_id => %{used: non_neg_integer, waiting: non_neg_integer, capacity: non_neg_integer}}

    `llm_pools` is the CACHED provider-account view of those pools, one entry
    per canonical `[[llm.providers]]` account — an account owns several models,
    so a multi-model account is ONE pool entry:

        llm_pools: %{profile_id => %{label: String.t() | nil, models: [String.t()]}}

    `profile_id` is the STRING account id, `label` the account `name` (falling
    back to the id) and `models` the account's configured BARE model ids in
    configured order. It is `%{}` for a legacy/empty config with no provider
    profiles, on the dead-scheduler sample, and whenever no cached profile
    metadata exists yet.

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

  Capacity totals (`llm_capacity`, `tool_capacity`) AND the provider-account
  profile metadata (`llm_pools`) come from the RESOLVED scheduler config,
  cached TOGETHER in state and refreshed every 10th tick on the dashboard's
  `rem(tick, 10) != 1` rule (tick 1 always loads; an unloaded cache refetches
  on any tick until the first FAILED attempt records a failed-refresh marker
  that defers further retries to the refresh cadence; zero capacities from the
  dead-scheduler branch are NEVER cached). Canonical configs derive
  `llm_capacity` from the summed per-ACCOUNT concurrency of
  `[[llm.providers]]` (the selection inventory in `model_profiles` carries no
  concurrency), legacy configs keep the Σ-per-model-profile computation.

  The per-model `llm_slots` map is NOT part of that cache: it is fetched LIVE
  every tick via `EvoGit.AgentScheduler.get_llm_slot_status/0` so holder and
  queue changes (slot grants, releases, peak-pause flips) show up on the very
  next 3s sample. The per-model `capacity` values therefore come from the
  scheduler-returned effective capacity (`State.concurrency_for/2` — peak-pause
  correctness), not from the static profile `concurrency` in the config cache;
  the aggregate `llm_capacity` key keeps its cached summed-concurrency value —
  Σ per canonical provider ACCOUNT (`[[llm.providers]]`, which owns the
  concurrency of all its models) when provider profiles exist, else the
  legacy Σ per-model-profile `:concurrency`.

  **Config source — a direct, bounded scheduler `GenServer.call` for
  `:get_config`** (what `RemoteAPI.get_config/0` wraps, minus its implicit
  5000 ms timeout — see "Graceful degradation"). Chosen because the chart must
  reflect the LIVE runtime config (including runtime overrides such as a
  `-c` and dashboard saves), and the scheduler's resolved config lives only in
  the GenServer state — it is not mirrored to ETS. `Config.resolve/0` would
  re-read disk and miss runtime overrides, and there is no cheaper in-process
  read; a cached call every 10 ticks is the same cost profile the dashboard's
  `chart_totals/3` had.

  ## Graceful degradation

  When the scheduler/ETS is absent (`scheduler_alive?/0` false) the sample has
  zero agent counts, zero capacities, and `llm_slots: %{}` with
  `scheduler_alive: false` — mirrors the dashboard's dead branch. Broadcasts
  continue (the dashboard rendered zero samples in the dead branch too).

  The sampler must also survive an ALIVE-but-busy scheduler, not just a dead
  one. Both scheduler reads are cross-process `GenServer.call`s, so the
  `Process.whereis(EvoGit.AgentScheduler) != nil` fast-path guard alone cannot
  prevent exits: a scheduler blocked in a long handler (e.g. a config update)
  makes the call time out and would kill the sampler — crash-looping it via
  the supervisor for as long as the scheduler stays wedged. The calls
  therefore use an explicit bounded timeout (`@scheduler_call_timeout_ms`,
  2 s — shorter than the 3 s tick cadence, so a wedged scheduler costs at most
  one degraded sample) and catch the `:exit` (timeout, the `:noproc` race
  between the whereis check and the call, or any other call exit) — a
  justified `try/catch :exit` at a cross-GenServer boundary, mirroring
  `EvoGit.PeakHourEngine.safe_get_config/2`. A failure degrades the sample
  only:

  * Config refresh failure → the last cached capacity totals are retained
    (10-tick staleness is already by design). When there is NO cache yet
    (e.g. tick 1 after a restart), a failed-refresh marker defers the next
    retry to the regular refresh cadence — the wedged scheduler is never
    re-attempted on every tick — and the capacity keys take the zero
    fallback. Sampling continues.
  * `llm_slots` fetch failure → `llm_slots: %{}` for that tick (the
    documented scheduler-dead shape). Sampling continues.

  Recovery is automatic: the next successful call restores live data on the
  following tick. Failures log a rate-limited `Logger.warning` — at most once
  per ~10 ticks (~30 s) per failure kind, never once per tick — naming the
  scheduler and the failing call.

  ## API

  * `get_recent_samples/0` — the last 60 samples (ring buffer).
  * `tick/0` — synchronous sampling tick (test seam).
  * `scheduler_alive?/0`, `status_counts/1`, `config_totals/1`, `llm_pools/1`,
    `build_sample/3,4,5`, `push/3` — pure helpers (public for tests; the
    dashboard's old `Charts` equivalents are deleted).
  """

  use GenServer

  require Logger

  @topic "system"
  @sample_capacity 60
  @config_refresh_divisor 10
  # Scheduler RPC bound and warning rate limit — see the moduledoc's "Graceful
  # degradation" section for the rationale. 2 s is deliberately shorter than
  # the 3 s tick cadence: a wedged scheduler costs at most one degraded sample
  # instead of a 5 s default-timeout crash (the production failure this guards).
  @scheduler_call_timeout_ms 2_000
  # At most one warning per failure kind per this many ticks (~30 s at 3 s).
  @warn_min_interval_ticks 10
  # Project default for an account that declares no `concurrency` — the same
  # value the config schema injects during provider-profile normalization.
  @default_account_concurrency 3

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
  returned error value (the failure is surfaced to the caller, not swallowed).
  This fast, well-behaved boundary needs no catch; the one justified
  `try/catch :exit` in this module is reserved for the sampler's OWN bounded
  scheduler calls (see the moduledoc's "Graceful degradation").
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
  Extracts slot capacities from a resolved scheduler config map.

  LLM capacity is the sum of per-ACCOUNT `concurrency` values. Canonical
  provider profiles (`config[:provider_profiles]`, one entry per
  `[[llm.providers]]` account, which owns the concurrency of every model it
  holds) win whenever that list is non-empty: an absent/nil concurrency
  contributes the project default `3` and an explicit `0` is preserved as a
  hard pause. Configs without provider profiles keep the legacy computation,
  Σ per-model-profile `:concurrency` (`nil` counting as 0).

  `tool_capacity` is `max_tool_concurrency`. Missing/unknown keys or a non-map
  yield zero capacities.
  """
  @spec config_totals(term()) :: %{llm_capacity: integer(), tool_capacity: integer()}
  def config_totals(config) when is_map(config) do
    %{
      llm_capacity: llm_capacity(config),
      tool_capacity: Map.get(config, :max_tool_concurrency) || 0
    }
  end

  def config_totals(_), do: %{llm_capacity: 0, tool_capacity: 0}

  @doc """
  Builds the `llm_pools` sample key: the CACHED provider-account view of the
  LLM slot pools, one entry per canonical `[[llm.providers]]` account (an
  account holds several models, so a multi-model account is ONE pool entry):

      %{profile_id => %{label: String.t() | nil, models: [String.t()]}}

  * `profile_id` — the account id as a STRING (`"id"`/`:id`; an atom id is
    converted, an entry without one is skipped).
  * `label` — the account `name` (`"name"`/`:name`), else the id.
  * `models` — the account's configured BARE model ids in configured order,
    read from its nested `models` list (each entry's `"model"`/`:model`, or a
    bare binary; a leading `"<provider>:"` qualifier is stripped defensively).
    `[]` when the account declares no models.

  `%{}` when the config carries no provider profiles (legacy/empty config), for
  a non-map, and — through the sampler — whenever no cached profile metadata
  exists yet.
  """
  @spec llm_pools(term()) ::
          %{optional(String.t()) => %{label: String.t() | nil, models: [String.t()]}}
  def llm_pools(config) when is_map(config) do
    case field(config, :provider_profiles) do
      [_ | _] = accounts ->
        accounts
        |> Enum.map(&pool_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  def llm_pools(_), do: %{}

  # ── Config-derived helpers ───────────────────────────────────────
  #
  # Atom-or-string key read for the scheduler config map: the resolved
  # scheduler config is atom-keyed at the top level, while canonical provider
  # profiles and their nested model entries are STRING-keyed (the config
  # schema's normalization boundary). Never creates atoms.
  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp llm_capacity(config) do
    case field(config, :provider_profiles) do
      [_ | _] = accounts ->
        Enum.reduce(accounts, 0, fn account, acc ->
          acc + account_concurrency(account)
        end)

      _ ->
        legacy_llm_capacity(config)
    end
  end

  # Legacy configs (no canonical provider profiles): unchanged Σ per-model-
  # profile `:concurrency`, absent counting as 0.
  defp legacy_llm_capacity(config) do
    Enum.reduce(Map.get(config, :model_profiles, []), 0, fn profile, acc ->
      acc + (Map.get(profile, :concurrency) || 0)
    end)
  end

  # A canonical account owns the concurrency of every model it holds, so an
  # absent value falls back to the project default (the value the schema
  # injects during normalization) while an explicit 0 stays a hard pause.
  defp account_concurrency(account) when is_map(account) do
    case field(account, :concurrency) do
      value when is_integer(value) -> value
      _ -> @default_account_concurrency
    end
  end

  # A list entry that is not a map is not an account — it contributes nothing.
  defp account_concurrency(_), do: 0

  defp pool_entry(account) when is_map(account) do
    case profile_id(account) do
      nil -> nil
      id -> {id, %{label: profile_label(account, id), models: profile_models(account)}}
    end
  end

  defp pool_entry(_), do: nil

  defp profile_id(account) do
    case field(account, :id) do
      id when is_binary(id) and id != "" -> id
      id when is_atom(id) and not is_nil(id) -> Atom.to_string(id)
      _ -> nil
    end
  end

  defp profile_label(account, id) do
    case field(account, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> id
    end
  end

  defp profile_models(account) do
    provider = field(account, :provider)

    case field(account, :models) do
      models when is_list(models) ->
        models
        |> Enum.map(&model_id(&1, provider))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  # A configured model entry is a bare binary, or a map whose id lives under
  # `"model"` (canonical) or `"id"` (input spelling) — mirroring the schema's
  # normalization.
  defp model_id(entry, provider) when is_binary(entry), do: unqualify(entry, provider)

  defp model_id(entry, provider) when is_map(entry) do
    case field(entry, :model) || field(entry, :id) do
      model when is_binary(model) and model != "" -> unqualify(model, provider)
      _ -> nil
    end
  end

  defp model_id(_entry, _provider), do: nil

  # Canonical inventories are BARE model ids; strip a `"<provider>:"` qualifier
  # defensively (same rule as the schema's normalization boundary).
  defp unqualify(model, provider) when is_binary(provider) and provider != "" do
    String.replace_prefix(model, provider <> ":", "")
  end

  defp unqualify(model, _provider), do: model

  @doc """
  Builds one sample map (the 14-key contract map — no extra keys) from status
  counts, capacity totals, the live per-model LLM slot map, the scheduler
  liveness flag and the cached provider-account pools.

  * `llm_slots` — real per-model LLM slot occupancy read live from the
    scheduler GenServer state (`EvoGit.AgentScheduler.get_llm_slot_status/0`);
    the scheduler-dead shape is `%{}`.
  * `llm_pools` — the CACHED provider-account view (`llm_pools/1`, refreshed
    together with the capacity totals every 10th tick); it defaults to `%{}`,
    so `build_sample/4` and `build_sample/3` compose exactly the maps they
    always did.
  * The aggregated `llm_used`/`llm_waiting` and both tool keys are the
    `:running`/`:blocked` status proxies (see moduledoc), kept for backward
    compatibility.
  """
  @spec build_sample(map(), map(), map(), boolean(), map()) :: map()
  def build_sample(counts, totals, llm_slots, scheduler_alive, llm_pools \\ %{})

  def build_sample(counts, totals, llm_slots, scheduler_alive, llm_pools)
      when is_map(counts) and is_map(totals) and is_map(llm_slots) and
             is_boolean(scheduler_alive) and is_map(llm_pools) do
    %{
      llm_slots: llm_slots,
      llm_pools: llm_pools,
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
  per-model slot data (`llm_slots: %{}` — the scheduler-dead shape) and without
  provider-account pools (`llm_pools: %{}`). The sampler's live tick path uses
  `build_sample/5` with the per-tick-fetched `llm_slots` map and the cached
  `llm_pools`.
  """
  @spec build_sample(map(), map(), boolean()) :: map()
  def build_sample(counts, totals, scheduler_alive)
      when is_map(counts) and is_map(totals) and is_boolean(scheduler_alive) do
    build_sample(counts, totals, %{}, scheduler_alive, %{})
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
      interval_ms: interval,
      # Last tick a rate-limited scheduler-failure warning was logged, per
      # failure kind (nil = never; reset on restart is fine).
      last_config_warn_tick: nil,
      last_llm_slots_warn_tick: nil
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
      {state, llm_slots} = fetch_llm_slots(state)
      state = maybe_refresh_config(state)

      sample =
        build_sample(
          status_counts(read_sched_metas()),
          cached_totals(state),
          llm_slots,
          true,
          cached_llm_pools(state)
        )

      broadcast_and_store(state, sample)
    else
      # Dead scheduler: zero agents, zero capacities, an empty llm_slots map and
      # empty provider-account pools — mirrors the dashboard's dead branch
      # (`{[], nil}`). Zero capacities are NOT cached (see maybe_refresh_config).
      sample = build_sample(status_counts([]), zero_totals(), %{}, false, %{})
      broadcast_and_store(state, sample)
    end
  end

  # Per-tick live read of the per-model LLM slot status from the scheduler
  # GenServer state (`get_llm_slot_status/0` — cheap pure in-state reads).
  # The whereis guard is the DEAD-scheduler fast path (never call a process
  # that is not registered); it cannot protect against an alive-but-busy
  # scheduler, so the call itself is bounded and exit-contained — a justified
  # cross-GenServer catch, see the moduledoc's "Graceful degradation" and
  # safe_scheduler_call/1. `scheduler_alive?/0` can be true while the
  # scheduler process is down (ETS table still exists, crash-restart window)
  # — in that window (whereis miss) and on any call failure the dead shape
  # (%{}) is reported for the tick and sampling continues.
  defp fetch_llm_slots(state) do
    if Process.whereis(EvoGit.AgentScheduler) != nil do
      case safe_scheduler_call(llm_slots_fun()) do
        {:ok, slots} ->
          {state, slots}

        {:failed, reason} ->
          state =
            warn_rate_limited(state, :last_llm_slots_warn_tick, "get_llm_slot_status", reason)

          {state, %{}}
      end
    else
      {state, %{}}
    end
  end

  # 10-tick config-cache rule (dashboard's `rem(tick, 10) != 1`): use the
  # cache (valid totals+pools OR a failed-refresh marker — both tuples) except
  # on ticks 1, 11, 21…; a cache that has never loaded (nil) refetches on any
  # tick until the first attempt succeeds or fails (the marker then defers
  # further retries to the refresh cadence).
  defp maybe_refresh_config(%{tick: tick, config_cache: {_totals, _pools, _loaded_tick}} = state)
       when rem(tick, @config_refresh_divisor) != 1 do
    state
  end

  # The failed-refresh marker counts as a cache entry for the SAME cadence
  # rule — it is what defers a wedged scheduler's next attempt to the refresh
  # tick instead of retrying on every tick.
  defp maybe_refresh_config(%{tick: tick, config_cache: {:failed_at, _}} = state)
       when rem(tick, @config_refresh_divisor) != 1 do
    state
  end

  defp maybe_refresh_config(state) do
    if Process.whereis(EvoGit.AgentScheduler) != nil do
      case safe_scheduler_call(config_fun()) do
        {:ok, config} ->
          # Config source: the resolved scheduler config (incl. runtime
          # overrides) — the same the dashboard's chart capacities used; see
          # the moduledoc for the choice rationale. The provider-account
          # profile metadata is cached WITH the totals so both stay on the
          # same refresh tick (no extra scheduler call, no per-tick work).
          %{state | config_cache: {config_totals(config), llm_pools(config), state.tick}}

        {:failed, reason} ->
          state = warn_rate_limited(state, :last_config_warn_tick, "get_config", reason)

          case state.config_cache do
            # Valid stale totals+pools exist — keep them (never nil the cache;
            # 10-tick staleness is already by design). The next refresh
            # attempt falls on the next refresh tick.
            {totals, _pools, _loaded} when is_map(totals) ->
              state

            # No cache yet (e.g. tick 1 after a restart): record a
            # failed-refresh marker so the next retry falls on the regular
            # refresh cadence instead of re-attempting a wedged scheduler on
            # every tick. cached_totals/1 and cached_llm_pools/1 map the marker
            # to the documented zero/empty fallbacks.
            _ ->
              %{state | config_cache: {:failed_at, state.tick}}
          end
      end
    else
      # Scheduler process down (ETS may still exist): keep the last-known
      # totals without re-caching. Never cache zero/stale totals — the
      # dead-scheduler branch must not suppress the next refresh.
      state
    end
  end

  defp cached_totals(%{config_cache: {totals, _pools, _loaded_tick}}) when is_map(totals),
    do: totals

  defp cached_totals(_state), do: zero_totals()

  defp cached_llm_pools(%{config_cache: {_totals, pools, _loaded_tick}}) when is_map(pools),
    do: pools

  defp cached_llm_pools(_state), do: %{}

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

  # ── Scheduler-call seams & exit containment ──────────────────────

  # Test seams, named after the `:peak_hours_now_fun` convention: 0-arity funs
  # returning the full resolved config map / the per-model slot map, read from
  # app env PER CALL (tests flip them mid-run; recovery on restore is
  # instant). Defaults are the real scheduler reads performed with the
  # sampler's own bounded timeout — the AgentScheduler module wrappers
  # (`RemoteAPI.get_config/0`, `get_llm_slot_status/0`) use GenServer.call's
  # implicit 5000 ms, which is exactly the unbounded-ish crash this module
  # must not inherit.
  defp config_fun do
    Application.get_env(:evo_git, :system_sampler_config_fun, &config_fetch/0)
  end

  defp config_fetch do
    GenServer.call(EvoGit.AgentScheduler, :get_config, @scheduler_call_timeout_ms)
  end

  defp llm_slots_fun do
    Application.get_env(:evo_git, :system_sampler_llm_slots_fun, &llm_slots_fetch/0)
  end

  defp llm_slots_fetch do
    GenServer.call(EvoGit.AgentScheduler, :get_llm_slot_status, @scheduler_call_timeout_ms)
  end

  # Justified try/catch :exit at a cross-GenServer boundary. The whereis
  # guards elsewhere detect a DEAD scheduler before any call is made; an
  # alive-but-busy scheduler (e.g. blocked in a long config-update handler)
  # cannot be detected that way and makes the bounded GenServer.call time
  # out — an uncaught exit would crash this sampler and crash-loop it via the
  # supervisor for as long as the scheduler stays wedged. Precedent:
  # `EvoGit.PeakHourEngine.safe_get_config/2` ("a transient scheduler restart
  # must never kill the engine"). Any `:exit` (timeout, the `:noproc` race
  # between whereis and the call, or a server crash mid-call) is contained;
  # genuine raises (a broken test seam or a scheduler bug) still surface.
  defp safe_scheduler_call(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    catch
      :exit, reason -> {:failed, reason}
    end
  end

  # Rate-limited clear warning: at most once per @warn_min_interval_ticks
  # (~30 s at the 3 s cadence) per failure kind. The sampler is a health
  # source — a silent data gap is worse than a clearly-worded warning, but one
  # warning per tick would spam the log during a scheduler stall. Last-warn
  # ticks live in state; a restart resets them (fine — a fresh sampler warns
  # once more before rate-limiting).
  defp warn_rate_limited(state, warn_field, call_name, reason) do
    last = Map.get(state, warn_field)

    if last == nil or state.tick - last >= @warn_min_interval_ticks do
      Logger.warning(
        "SystemSampler: AgentScheduler #{call_name} call failed: #{inspect(reason)} — " <>
          "the scheduler GenServer is busy or down; sampling continues with stale/empty " <>
          "data and recovers automatically once the scheduler responds"
      )

      Map.put(state, warn_field, state.tick)
    else
      state
    end
  end

  defp broadcast_and_store(state, sample) do
    seq = state.seq + 1
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic, {:system_sample, node(), seq, sample})
    %{state | seq: seq, samples: push(state.samples, sample)}
  end
end
