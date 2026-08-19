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
  `effective_map/3,4` — applying the **same floor**
  `EvoGit.AgentScheduler.State` re-applies when storing a
  `:model_concurrency` replacement (`maybe_update_model_concurrency/2` +
  `apply_default_llm_concurrency_override/2`): an explicit effective `0`
  stays `0`, and every other value floors to
  `max(effective_concurrency(profile, now), default_llm_max_concurrency)`.
  It then calls `AgentScheduler.update_config(model_concurrency: map)` only
  when the computed map differs from the scheduler's current one. The floored
  computation guarantees a **fixed point**: the stored map equals the computed
  map, so the `{:scheduler_config_updated, node}` broadcast that every update
  emits re-checks into a no-op instead of looping. The scheduler's
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

  ## Wakeups

  After every check the engine schedules the next wakeup at the earliest
  in-peak state flip across all profiles' windows, computed in each profile's
  own wall clock (`EvoGit.PeakHours.next_transition/2`), plus a small epsilon
  so `now` is guaranteed to be past the boundary when the timer fires (windows
  are half-open). When no transition is computable (no windows) it falls back
  to a 6-hour safety-net cap so config reloads are still picked up. A pending
  timer is always cancelled before a new one is scheduled, so wakeups never
  stack.

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

  **Floor rule** (must mirror
  `EvoGit.AgentScheduler.State.apply_default_llm_concurrency_override/2`):
  an explicit effective `0` stays `0`; `nil` (no concurrency) becomes the
  floor; every other value floors to `max(effective, default)`. The engine
  must NEVER compute an unfloored map, or the State would floor it and the
  engine would re-apply forever.
  """
  @spec effective_map([map()], non_neg_integer() | nil, NaiveDateTime.t(), DateTime.t() | nil) ::
          %{String.t() => non_neg_integer()}
  def effective_map(profiles, default, %NaiveDateTime{} = now, utc_now \\ nil)
      when is_list(profiles) do
    d = default || 0

    Map.new(profiles, fn p ->
      id = Map.get(p, :id, "default")
      eff = effective_for_profile(p, now, utc_now)
      {id, floor_effective(eff, d)}
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
  # pairs (`tz` = nil for local-clock profiles) plus both clocks, computes
  # each profile's next transition in its OWN wall clock, and returns the
  # earliest wakeup delay — epsilon and the 6h cap applied, mirroring
  # `next_wakeup_ms/2`.
  #
  # Non-tz pairs use the local `now` directly. Tz pairs resolve their wall
  # clock from `utc_now` via `EvoGit.PeakHours.wall_clock_in/2` (falling back
  # to `now` on resolution errors) and convert the wall transition to a UTC
  # instant via `DateTime.from_naive/3` + `DateTime.shift_zone/3`; on ANY
  # conversion error (DST gap/ambiguity, unknown zone, unconfigured db) that
  # profile's transition is skipped. No transitions at all → `@max_sleep_ms`.
  @spec next_wakeup_ms_for(
          [{PeakHours.windows(), String.t() | nil}],
          NaiveDateTime.t(),
          DateTime.t()
        ) ::
          pos_integer()
  def next_wakeup_ms_for(windows_tz_pairs, %NaiveDateTime{} = now, %DateTime{} = utc_now)
      when is_list(windows_tz_pairs) do
    transitions =
      Enum.flat_map(windows_tz_pairs, fn
        {[], _tz} ->
          []

        {ws, nil} ->
          case PeakHours.next_transition(ws, now) do
            nil -> []
            transition -> [max(NaiveDateTime.diff(transition, now, :millisecond), 0)]
          end

        {ws, tz} ->
          # wall_clock_for/3 always resolves (falling back to `now`), so the
          # match below cannot fail.
          {:ok, wall} = wall_clock_for(tz, now, utc_now)

          case PeakHours.next_transition(ws, wall) do
            nil ->
              []

            wall_transition ->
              case tz_transition_delay_ms(wall_transition, tz, utc_now) do
                nil -> []
                ms -> [ms]
              end
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

    # Kick off an immediate check. The engine is supervised AFTER the
    # scheduler (application.ex), so the scheduler is up at boot.
    Process.send(self(), :check, [])

    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    {:reply, :ok, run_check(state)}
  end

  @impl true
  def handle_info(:check, state) do
    {:noreply, run_check(state)}
  end

  def handle_info({:scheduler_config_updated, node}, state) when node == node() do
    {:noreply, run_check(state)}
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
  defp run_check(state) do
    # Cancel any pending timer before scheduling a fresh one — repeated
    # wakeups (e.g. broadcasts while a timer is pending) must not stack timers.
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    state = %{state | timer_ref: nil}

    now = now_fun()
    utc_now = utc_now_fun()

    if scheduler_up?() do
      profiles = safe_get_config(:model_profiles, [])

      if is_list(profiles) and profiles != [] do
        default = safe_get_config(:default_llm_max_concurrency, nil)
        effective = effective_map(profiles, default, now, utc_now)
        current = safe_get_config(:model_concurrency, %{})

        if effective != current do
          case safe_update_config(model_concurrency: effective) do
            :ok ->
              Logger.info("PeakHourEngine: applied model concurrency #{inspect(effective)}")

            {:error, reason} ->
              Logger.warning(
                "PeakHourEngine: failed to apply model concurrency: #{inspect(reason)}"
              )

            :scheduler_down ->
              Logger.warning("PeakHourEngine: scheduler unavailable, skipping concurrency apply")
          end
        end

        windows_tz_pairs =
          Enum.flat_map(profiles, fn p ->
            case PeakHours.validate_windows(Map.get(p, :peak_hours)) do
              {:ok, ws} when ws != [] -> [{ws, profile_timezone(p)}]
              _ -> []
            end
          end)

        ms = next_wakeup_ms_for(windows_tz_pairs, now, utc_now)
        %{state | timer_ref: Process.send_after(self(), :check, ms)}
      else
        schedule_safety_net(state)
      end
    else
      schedule_safety_net(state)
    end
  end

  defp schedule_safety_net(state) do
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

  # Task B floor rule (must mirror
  # State.apply_default_llm_concurrency_override/2): an explicit effective 0
  # stays 0; nil (no concurrency) becomes the floor; all other values floor
  # to max(eff, floor).
  defp floor_effective(eff, floor) do
    cond do
      eff == 0 -> 0
      is_nil(eff) -> floor
      true -> max(eff, floor)
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
