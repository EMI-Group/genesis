defmodule EvoGit.PeakHourEngine do
  @moduledoc """
  Dynamic peak/off-peak LLM concurrency engine.

  LLM providers charge more during peak hours. Model profiles may declare
  optional `peak_concurrency` + `peak_hours` windows; this GenServer watches
  the local wall clock and pushes the peak-adjusted per-model concurrency map
  into `EvoGit.AgentScheduler` via `update_config(model_concurrency: map)`
  whenever the clock enters or leaves a peak window.

  ## Runtime update path

  For every model profile the engine computes the per-model concurrency map —
  `effective_map/3,4` — and OWNS the floor logic itself. An explicit in-peak
  `peak_concurrency` — including the hard-pause `0` — is an intentional
  per-model user configuration and is sent as-is, exempt from the
  `default_llm_max_concurrency` floor; every other value floors to
  `max(effective_concurrency(profile, now), default_llm_max_concurrency)`
  (`nil` becomes the floor). It then calls
  `AgentScheduler.update_config(model_concurrency: map,
  model_concurrency_skip_floor: true)` only when the computed map differs from
  the scheduler's current one — the skip-floor flag makes the scheduler store
  the map verbatim, so the floored computation guarantees a **fixed point**:
  the stored map equals the computed map, and the
  `{:scheduler_config_updated, node}` broadcast that every update emits
  re-checks into a no-op instead of looping. The scheduler's
  `Slots.grant_pending_on_resume/1` sweep grants queued LLM waiters on any
  capacity increase, and `reconcile_pool_after_update/1` re-sizes the
  ReqLLM Finch pool — both automatic.

  ## Timezones

  Profiles may declare an optional `timezone` (IANA name, e.g.
  `"Asia/Shanghai"`). For such profiles the engine resolves the wall clock
  from the UTC clock seam via `EvoGit.PeakHours.wall_clock_in/2` instead of
  the local wall clock, and computes the next wakeup in the profile's own
  wall clock (converting the wall transition to UTC). Profiles without a
  `timezone` keep using the local wall clock exactly as before.

  ## Day-of-week scoping

  Profiles may declare `off_peak_days` (a list of day identifiers/keywords —
  vocabulary in `EvoGit.PeakHours`): on those days the profile is off-peak
  the ENTIRE day (every `peak_hours` window is suppressed, and
  `peak_concurrency` — including the hard-pause `0` — never applies; the
  value floors to normal concurrency). Windows may also declare their own
  `days` key. The engine passes the profile's canonical off-peak day list
  into `EvoGit.PeakHours.in_peak?/3` / `next_transition/3`, so day-of-week
  is evaluated in each profile's own wall clock (see Timezones above).

  ## Wakeups

  After every check the engine schedules the next wakeup at the earliest
  in-peak state flip across all profiles' windows, computed in each profile's
  own wall clock (`EvoGit.PeakHours.next_transition/3` — day-aware: window
  start/end minutes on applicable days, midnight day-boundary flips, and
  off-peak-day suppression all count as transitions), plus a small epsilon
  so `now` is guaranteed to be past the boundary when the timer fires
  (windows are half-open). Profiles with NO windows never change effective —
  they contribute no transitions, and a profile whose only state change
  would be a suppressed window on an off-peak day is naturally skipped by
  the day-aware transition math (no pointless mid-day wakeups). When no
  transition is computable it falls back to a 6-hour safety-net cap so
  config reloads are still picked up. A pending timer is always cancelled
  before a new one is scheduled, so wakeups never stack.

  ## Config reloads

  The engine subscribes to PubSub topic `"scheduler_config"` and re-runs the
  check on `{:scheduler_config_updated, node}` from the local node, so a
  profile edit / config reload re-applies immediately even mid-peak. Foreign
  node broadcasts are ignored.

  ## Clock seams

  `now` (local wall clock) is read from
  `Application.get_env(:evo_git, :peak_hours_now_fun, &NaiveDateTime.local_now/0)`
  on EVERY wakeup, and `utc_now` (for timezone profiles) from
  `Application.get_env(:evo_git, :peak_hours_utc_now_fun, &DateTime.utc_now/0)`
  — so tests can swap either clock at runtime with `Application.put_env` and
  the engine picks them up without a restart.

  ## Robustness

  The engine never crashes the GenServer: if the scheduler is down or has no
  profiles it no-ops and reschedules the safety-net wakeup; scheduler RPC
  exits (`:noproc` from a down scheduler, etc.) are caught and logged as
  warnings. The map computation (`effective_map/3`) and wakeup math
  (`next_wakeup_ms/2`) are pure `@doc false` helpers so unit tests can drive
  them without a live scheduler.
  """

  use GenServer

  require Logger

  alias EvoGit.AgentScheduler
  alias EvoGit.PeakHours

  @topic "scheduler_config"

  # Safety-net cap: when no transition can be computed (no windows), wake up
  # at most every 6h so a config reload still gets picked up.
  @max_sleep_ms 6 * 60 * 60 * 1000

  # Small epsilon added to a computed transition delay so that when the timer
  # fires `now` is guaranteed to be >= the transition instant (half-open
  # windows flip exactly at the boundary).
  @wakeup_epsilon_ms 100

  # Scheduler RPC timeout (each scheduler call inside the check pipeline uses
  # the GenServer default 5s; check/0 gets generous headroom).
  @check_call_timeout 30_000

  @type state :: %{timer_ref: reference() | nil}

  @doc "Starts the engine (supervised in `EvoGit.Application`)."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs the peak-hour check pipeline synchronously and returns `:ok`.

  Test/diagnostic API — the engine normally self-wakes on its timer and on
  `"scheduler_config"` broadcasts. Returns `:ok` even when the scheduler is
  down or profiles are empty (no-op, never raises).
  """
  @spec check :: :ok
  def check do
    GenServer.call(__MODULE__, :check, @check_call_timeout)
  end

  @doc """
  Computes the floored per-model concurrency map for `profiles`.

  `default` is the scheduler's `default_llm_max_concurrency` floor (`nil` is
  treated as no floor / 0). Arity 3 uses the local wall clock `now` for every
  profile (profiles without a `timezone` behave exactly as before; a
  timezone profile with no `utc_now` falls back to `now`). Arity 4 resolves
  each timezone profile's wall clock from `utc_now` via
  `EvoGit.PeakHours.wall_clock_in/2` (falling back to `now` on resolution
  errors) and uses `now` for non-timezone profiles.

  **Floor rule**: an explicit in-peak `peak_concurrency` — including the
  hard-pause `0` — is an intentional per-model user configuration and is sent
  as-is, exempt from the `default_llm_max_concurrency` floor (the engine owns
  the floor logic; the scheduler stores the map verbatim for the
  `model_concurrency_skip_floor` flag). `nil` (no concurrency) becomes the
  floor; every other value floors to `max(effective, default)`. The engine
  must NEVER send an unfloored map for NON-exempt values, or the scheduler
  would floor it and the engine would re-apply forever (fixed point). On a
  profile's `off_peak_days` (canonical day-atom list) the profile is never in
  peak — `peak_exempt?/3` returns false there, so the value is the normal
  (floored) concurrency and the explicit peak value never applies.
  """
  @spec effective_map([map()], non_neg_integer() | nil, NaiveDateTime.t(), DateTime.t() | nil) ::
          %{String.t() => non_neg_integer()}
  def effective_map(profiles, default, %NaiveDateTime{} = now, utc_now \\ nil)
      when is_list(profiles) do
    d = default || 0

    Map.new(profiles, fn p ->
      id = Map.get(p, :id, "default")
      eff = effective_for_profile(p, now, utc_now)

      # An explicit in-peak `peak_concurrency` (incl. the hard-pause 0) is an
      # intentional user configuration and is sent as-is, exempt from the
      # default floor; everything else floors.
      {id, if(peak_exempt?(p, now, utc_now), do: eff, else: floor_effective(eff, d))}
    end)
  end

  @doc """
  Milliseconds until the next in-peak state flip across `windows_lists`, or
  the 6h safety-net cap when no transition is computable.

  `windows_lists` is a list of validated window lists (one per profile; empty
  lists contribute nothing). The result is `max(transition - now, 0)` plus
  `@wakeup_epsilon_ms`, capped at `@max_sleep_ms`.
  """
  @spec next_wakeup_ms([[PeakHours.windows()]], NaiveDateTime.t()) :: pos_integer()
  def next_wakeup_ms(windows_lists, %NaiveDateTime{} = now) when is_list(windows_lists) do
    transitions =
      Enum.flat_map(windows_lists, fn
        [] ->
          []

        ws ->
          case PeakHours.next_transition(ws, now) do
            nil -> []
            transition -> [transition]
          end
      end)

    case Enum.min(transitions, fn -> nil end) do
      nil ->
        @max_sleep_ms

      transition ->
        ms = max(NaiveDateTime.diff(transition, now, :millisecond), 0)
        min(ms + @wakeup_epsilon_ms, @max_sleep_ms)
    end
  end

  @doc false
  # Timezone-aware variant of `next_wakeup_ms/2`: takes `[{windows, tz}]`
  # pairs or `[{windows, off_peak_days, tz}]` triples (`tz` = nil for
  # local-clock profiles, `off_peak_days` = canonical day-atom list) plus
  # both clocks, computes each profile's next transition in its OWN wall
  # clock via the day-aware `PeakHours.next_transition/3`, and returns the
  # earliest wakeup delay — epsilon and the 6h cap applied, mirroring
  # `next_wakeup_ms/2`. Empty-window pairs/triples contribute nothing (a
  # profile with no windows never changes effective).
  #
  # Non-tz pairs use the local `now` directly. Tz pairs resolve their wall
  # clock from `utc_now` via `EvoGit.PeakHours.wall_clock_in/2` (falling back
  # to `now` on resolution errors) and convert the wall transition to a UTC
  # instant via `DateTime.from_naive/3` + `DateTime.shift_zone/3`; on ANY
  # conversion error (DST gap/ambiguity, unknown zone, unconfigured db) that
  # profile's transition is skipped. No transitions at all → `@max_sleep_ms`.
  @spec next_wakeup_ms_for(
          [
            {PeakHours.windows(), [PeakHours.day()], String.t() | nil}
            | {PeakHours.windows(), String.t() | nil}
          ],
          NaiveDateTime.t(),
          DateTime.t()
        ) ::
          pos_integer()
  def next_wakeup_ms_for(windows_tz_pairs, %NaiveDateTime{} = now, %DateTime{} = utc_now)
      when is_list(windows_tz_pairs) do
    transitions =
      Enum.flat_map(windows_tz_pairs, fn pair ->
        case normalize_wakeup_pair(pair) do
          nil ->
            []

          {ws, off_days, tz} ->
            transition_for(ws, off_days, tz, now, utc_now)
        end
      end)

    case Enum.min(transitions, fn -> nil end) do
      nil -> @max_sleep_ms
      ms -> min(ms + @wakeup_epsilon_ms, @max_sleep_ms)
    end
  end

  @impl true
  def init(_opts) do
    # Subscribe to scheduler-config broadcasts so a profile edit / config
    # reload re-applies immediately, even mid-peak. Same subscribe idiom as
    # the rest of the app (e.g. Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")).
    Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)

    state = %{timer_ref: nil}

    # Diagnostic boot summary — makes a misconfigured profile (bad timezone,
    # missing/odd peak_hours, unexpected peak_concurrency) visible in the very
    # first log lines instead of surfacing only through confusing runtime
    # behavior (e.g. a task that stays blocked after peak exit).
    log_boot_profiles()

    # Kick off an immediate check. The engine is supervised AFTER the
    # scheduler (application.ex), so the scheduler is up at boot.
    Process.send(self(), :check, [])

    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    {:reply, :ok, run_check(state, :manual)}
  end

  @impl true
  def handle_info(:check, state) do
    {:noreply, run_check(state, :timer)}
  end

  def handle_info({:scheduler_config_updated, node}, state) when node == node() do
    {:noreply, run_check(state, :broadcast)}
  end

  def handle_info({:scheduler_config_updated, _foreign_node}, state) do
    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # The full wakeup pipeline: read the clock, compute the floored effective
  # map, apply it when it differs, and schedule the next wakeup. Never raises
  # and never crashes the GenServer — scheduler failures degrade to a
  # safety-net wakeup.
  #
  # `wake_reason` is the wakeup source (one of :boot, :timer, :broadcast,
  # :manual) and is used for diagnostic logging ONLY — it never influences
  # timing, the floor logic, or the applied map.
  defp run_check(state, wake_reason) do
    # Cancel any pending timer before scheduling a fresh one — repeated
    # wakeups (e.g. broadcasts while a timer is pending) must not stack timers.
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    state = %{state | timer_ref: nil}

    now = now_fun()
    utc_now = utc_now_fun()
    scheduler_up = scheduler_up?()

    # Every wakeup logs WHY we woke and the clocks the engine saw — the
    # first thing to check when a task stays blocked after a peak should have
    # ended (distinguishes "engine never woke" from "woke but didn't apply").
    Logger.info(
      "PeakHourEngine: wakeup reason=#{wake_reason} now=#{inspect(now)} " <>
        "utc_now=#{inspect(utc_now)} scheduler_up=#{scheduler_up}"
    )

    if scheduler_up do
      profiles = safe_get_config(:model_profiles, [])

      if is_list(profiles) and profiles != [] do
        default = safe_get_config(:default_llm_max_concurrency, nil)
        effective = effective_map(profiles, default, now, utc_now)
        current = safe_get_config(:model_concurrency, %{})

        if effective != current do
          Logger.info(
            "PeakHourEngine: decision=applying effective=#{inspect(effective)} " <>
              "current=#{inspect(current)}"
          )

          case safe_update_config(
                 model_concurrency: effective,
                 model_concurrency_skip_floor: true
               ) do
            :ok ->
              Logger.info("PeakHourEngine: applied model concurrency #{inspect(effective)}")

            {:error, reason} ->
              Logger.warning(
                "PeakHourEngine: failed to apply model concurrency: #{inspect(reason)}"
              )

            :scheduler_down ->
              Logger.warning("PeakHourEngine: scheduler unavailable, skipping concurrency apply")
          end
        else
          # The no-op branch previously logged NOTHING — this is what makes a
          # "woke but decided not to apply" distinguishable from "never woke".
          Logger.info(
            "PeakHourEngine: decision=unchanged effective=#{inspect(effective)} " <>
              "current=#{inspect(current)} (no apply)"
          )
        end

        windows_tz_pairs =
          Enum.flat_map(profiles, fn p ->
            case PeakHours.validate_windows(Map.get(p, :peak_hours)) do
              {:ok, ws} when ws != [] ->
                [{ws, profile_off_peak_days(p), profile_timezone(p)}]

              _ ->
                []
            end
          end)

        ms = next_wakeup_ms_for(windows_tz_pairs, now, utc_now)
        log_next_wakeup(profiles, ms, now, utc_now)
        %{state | timer_ref: Process.send_after(self(), :check, ms)}
      else
        schedule_safety_net(state)
      end
    else
      schedule_safety_net(state)
    end
  end

  # Logs the computed next-wakeup delay and — for each profile with validated
  # peak windows — its next in-peak transition wall-clock time (nil when the
  # pure module computed none). A "next_transition returned 09:00 tomorrow
  # instead of 18:00 today" bug is visible here at a glance, and the 6h
  # safety-net fallback is explicitly flagged.
  defp log_next_wakeup(profiles, ms, now, utc_now) do
    transitions =
      Enum.flat_map(profiles, fn p ->
        case PeakHours.validate_windows(Map.get(p, :peak_hours)) do
          {:ok, ws} when ws != [] ->
            id = Map.get(p, :id, "default")
            tz = profile_timezone(p)
            off_days = profile_off_peak_days(p)

            [
              {id, tz, off_days, ws,
               PeakHours.next_transition(ws, peak_wall_clock(p, now, utc_now), off_days)}
            ]

          _ ->
            []
        end
      end)

    Logger.info(
      "PeakHourEngine: next wakeup in #{ms}ms" <>
        if(ms >= @max_sleep_ms,
          do: " (6h safety-net fallback — no transition computed)",
          else: ""
        ) <>
        " transitions=#{inspect(transitions)}"
    )
  end

  defp schedule_safety_net(state) do
    Logger.info(
      "PeakHourEngine: scheduling 6h safety-net wakeup (#{@max_sleep_ms}ms) — no profiles / scheduler down"
    )

    %{state | timer_ref: Process.send_after(self(), :check, @max_sleep_ms)}
  end

  defp now_fun do
    fun = Application.get_env(:evo_git, :peak_hours_now_fun, &NaiveDateTime.local_now/0)
    fun.()
  end

  defp utc_now_fun do
    fun = Application.get_env(:evo_git, :peak_hours_utc_now_fun, &DateTime.utc_now/0)
    fun.()
  end

  # One-shot boot diagnostic: summarizes every watched model profile (id,
  # concurrency, peak_concurrency, peak_hours windows, timezone) so a
  # misconfigured profile is visible immediately. Runs in init via the safe
  # config read (scheduler is up at boot; a missing scheduler degrades to []).
  defp log_boot_profiles do
    profiles = safe_get_config(:model_profiles, [])

    summary =
      Enum.map(profiles, fn p ->
        %{
          id: Map.get(p, :id, "default"),
          concurrency: Map.get(p, :concurrency) || Map.get(p, "concurrency"),
          peak_concurrency: Map.get(p, :peak_concurrency) || Map.get(p, "peak_concurrency"),
          peak_hours: Map.get(p, :peak_hours) || Map.get(p, "peak_hours"),
          off_peak_days: Map.get(p, :off_peak_days) || Map.get(p, "off_peak_days"),
          timezone: profile_timezone(p)
        }
      end)

    Logger.info("PeakHourEngine: starting — watched profiles: #{inspect(summary)}")
  end

  # Resolves a profile's effective concurrency at its own wall clock: tz
  # profiles resolve the utc seam into the zone's wall clock (falling back to
  # the local `now` on any resolution error); non-tz profiles use `now`
  # directly.
  defp effective_for_profile(p, now, utc_now) do
    case profile_timezone(p) do
      nil ->
        PeakHours.effective_concurrency(p, now)

      tz ->
        case PeakHours.wall_clock_in(tz, utc_now) do
          {:ok, wall} -> PeakHours.effective_concurrency(p, wall)
          {:error, _reason} -> PeakHours.effective_concurrency(p, now)
        end
    end
  end

  # Floor rule for NON-exempt values (the engine owns the floor logic now —
  # the scheduler stores the map verbatim for the `model_concurrency_skip_floor`
  # flag): an explicit in-peak `peak_concurrency` (incl. the hard-pause 0) is
  # sent as-is via `peak_exempt?/3` and never reaches this helper; nil (no
  # concurrency) becomes the floor; all other values floor to max(eff, floor).
  # An unfloored NON-exempt value would be raised by the scheduler-side floor
  # and break the fixed point.
  defp floor_effective(eff, floor) do
    cond do
      eff == 0 -> 0
      is_nil(eff) -> floor
      true -> max(eff, floor)
    end
  end

  # True iff the profile declares an explicit `peak_concurrency` (a
  # non-negative integer; atom- or string-keyed like `profile_timezone/1`)
  # AND is CURRENTLY inside one of its validated `peak_hours` windows (day-
  # aware via the profile's `off_peak_days` — on an off-peak day the profile
  # is NEVER in peak, so the explicit peak value never applies and the value
  # floors to normal concurrency). An explicit in-peak peak value — including
  # the hard-pause 0 — is an intentional per-model user configuration and
  # wins over the global default floor; everything else (off-peak profiles,
  # absent/invalid/empty windows, no explicit peak_concurrency) is floored.
  # Invalid/empty/absent `peak_hours` → false (never exempt).
  defp peak_exempt?(p, now, utc_now) do
    with {:ok, _peak} <- explicit_peak_concurrency(p),
         {:ok, ws} <- PeakHours.validate_windows(Map.get(p, :peak_hours)),
         ws when ws != [] <- ws do
      PeakHours.in_peak?(ws, peak_wall_clock(p, now, utc_now), profile_off_peak_days(p))
    else
      _ -> false
    end
  end

  # Returns {:ok, peak} when the profile declares an explicit non-negative
  # integer `peak_concurrency` (atom- or string-keyed), else :error.
  defp explicit_peak_concurrency(p) do
    case {Map.get(p, :peak_concurrency), Map.get(p, "peak_concurrency")} do
      {v, _} when is_integer(v) and v >= 0 -> {:ok, v}
      {_, v} when is_integer(v) and v >= 0 -> {:ok, v}
      _ -> :error
    end
  end

  # Resolves the wall clock for the in-peak check, mirroring
  # `effective_for_profile/3`: tz profiles resolve the utc seam (falling back
  # to `now` on resolution errors); non-tz profiles use `now` directly.
  defp peak_wall_clock(p, now, utc_now) do
    case profile_timezone(p) do
      nil ->
        now

      tz ->
        {:ok, wall} = wall_clock_for(tz, now, utc_now)
        wall
    end
  end

  # Returns the profile's timezone as a non-empty binary, or nil when
  # absent / empty (atom- and string-keyed tolerance — TOML decoding may
  # produce string keys).
  defp profile_timezone(p) do
    case Map.get(p, :timezone) do
      tz when tz in [nil, ""] ->
        case Map.get(p, "timezone") do
          tz2 when tz2 in [nil, ""] -> nil
          tz2 -> tz2
        end

      tz ->
        tz
    end
  end

  # Returns the profile's canonical off-peak day-atom list (atom- or
  # string-keyed tolerance, mirroring `profile_timezone/1`). Absent / empty
  # / invalid values degrade to `[]` (disabled) and never crash — the pure
  # `PeakHours.validate_days/1` is the single parse/validation path.
  defp profile_off_peak_days(p) do
    case PeakHours.validate_days(Map.get(p, :off_peak_days) || Map.get(p, "off_peak_days")) do
      {:ok, days} -> days
      {:error, _reason} -> []
    end
  end

  # Resolves the wall clock for a tz profile from the utc seam, falling back
  # to the local `now` on any resolution error.
  defp wall_clock_for(tz, now, utc_now) do
    case PeakHours.wall_clock_in(tz, utc_now) do
      {:ok, wall} -> {:ok, wall}
      {:error, _reason} -> {:ok, now}
    end
  end

  # Converts a wall-clock transition (expressed in `tz`) into milliseconds
  # until the corresponding UTC instant. nil when the conversion fails (DST
  # gap/ambiguity, unknown zone, unconfigured tz db).
  defp tz_transition_delay_ms(wall_transition, tz, utc_now) do
    db = Calendar.get_time_zone_database()

    with {:ok, dt_tz} <- DateTime.from_naive(wall_transition, tz, db),
         {:ok, dt_utc} <- DateTime.shift_zone(dt_tz, "Etc/UTC", db) do
      max(DateTime.diff(dt_utc, utc_now, :millisecond), 0)
    else
      _ -> nil
    end
  end

  # Normalizes one wakeup-math input pair into `{windows, off_peak_days, tz}`
  # for `transition_for/5`: 3-tuples pass through, 2-tuples (backward-compat
  # `{windows, tz}` shape) get an empty off-peak-day list. Empty window lists
  # contribute nothing — a profile with no windows never changes effective —
  # and normalize to nil (skipped by `next_wakeup_ms_for/3`).
  defp normalize_wakeup_pair({[], _off_days, _tz}), do: nil
  defp normalize_wakeup_pair({[], _tz}), do: nil
  defp normalize_wakeup_pair({ws, off_days, tz}) when is_list(ws) and is_list(off_days),
    do: {ws, off_days, tz}

  defp normalize_wakeup_pair({ws, tz}) when is_list(ws), do: {ws, [], tz}

  # Computes the millisecond delay until a profile's next in-peak transition
  # (or `[]` when none is computable — the caller's min is skipped). Non-tz
  # profiles compute the day-aware transition directly on the local wall clock
  # `now`; tz profiles resolve their wall clock from `utc_now` (falling back
  # to `now` on resolution errors via `wall_clock_for/3`) and convert the
  # wall transition to a UTC delay via `tz_transition_delay_ms/3` (nil →
  # skipped). Off-peak-day suppression and day-scoped window skipping are
  # handled inside `PeakHours.next_transition/3`, so a suppressed window's
  # start on an off-peak day never schedules a pointless mid-day wakeup.
  defp transition_for(ws, off_days, nil, now, _utc_now) do
    case PeakHours.next_transition(ws, now, off_days) do
      nil -> []
      transition -> [max(NaiveDateTime.diff(transition, now, :millisecond), 0)]
    end
  end

  defp transition_for(ws, off_days, tz, now, utc_now) do
    {:ok, wall} = wall_clock_for(tz, now, utc_now)

    case PeakHours.next_transition(ws, wall, off_days) do
      nil ->
        []

      wall_transition ->
        case tz_transition_delay_ms(wall_transition, tz, utc_now) do
          nil -> []
          ms -> [ms]
        end
    end
  end

  defp scheduler_up? do
    Process.whereis(EvoGit.AgentScheduler) != nil
  end

  # Scheduler RPCs are GenServer.calls — guard against a scheduler that goes
  # down between the whereis check and the call (or crashes mid-call). A
  # transient scheduler restart must never kill the engine.
  defp safe_get_config(key, fallback) do
    try do
      AgentScheduler.get_config(key)
    catch
      :exit, reason ->
        Logger.warning("PeakHourEngine: get_config(#{inspect(key)}) failed: #{inspect(reason)}")
        fallback
    end
  end

  defp safe_update_config(opts) do
    try do
      AgentScheduler.update_config(opts)
    catch
      :exit, reason ->
        Logger.warning("PeakHourEngine: update_config failed: #{inspect(reason)}")
        :scheduler_down
    end
  end
end
