defmodule EvoGit.PeakHourEngine do
  @moduledoc """
  Dynamic peak/off-peak LLM concurrency engine.

  LLM providers charge more during peak hours. Model profiles may declare
  optional `peak_concurrency` + `peak_hours` windows; this GenServer watches
  the local wall clock and pushes the peak-adjusted per-model concurrency map
  into `EvoGit.AgentScheduler` via `update_config(model_concurrency: map)`
  whenever the clock enters or leaves a peak window.

  ## Runtime update path

  For every model profile the engine computes
  `max(effective_concurrency(profile, now), default_llm_max_concurrency)` —
  the **same floor** `EvoGit.AgentScheduler.State` re-applies when storing a
  `:model_concurrency` replacement (`maybe_update_model_concurrency/2` +
  `apply_default_llm_concurrency_override/2`). It then calls
  `AgentScheduler.update_config(model_concurrency: map)` only when the
  computed map differs from the scheduler's current one. The floored
  computation guarantees a **fixed point**: the stored map equals the computed
  map, so the `{:scheduler_config_updated, node}` broadcast that every update
  emits re-checks into a no-op instead of looping. The scheduler's
  `Slots.grant_pending_on_resume/1` sweep grants queued LLM waiters on any
  capacity increase, and `reconcile_pool_after_update/1` re-sizes the
  ReqLLM Finch pool — both automatic.

  ## Wakeups

  After every check the engine schedules the next wakeup at the earliest
  in-peak state flip across all profiles' windows
  (`EvoGit.PeakHours.next_transition/2`), plus a small epsilon so `now` is
  guaranteed to be past the boundary when the timer fires (windows are
  half-open). When no transition is computable (no windows) it falls back to a
  6-hour safety-net cap so config reloads are still picked up. A pending timer
  is always cancelled before a new one is scheduled, so wakeups never stack.

  ## Config reloads

  The engine subscribes to PubSub topic `"scheduler_config"` and re-runs the
  check on `{:scheduler_config_updated, node}` from the local node, so a
  profile edit / config reload re-applies immediately even mid-peak. Foreign
  node broadcasts are ignored.

  ## Clock seam

  `now` is read from `Application.get_env(:evo_git, :peak_hours_now_fun,
  &NaiveDateTime.local_now/0)` on EVERY wakeup, so tests can swap the clock at
  runtime with `Application.put_env` and the engine picks it up without a
  restart.

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
  Computes the floored per-model concurrency map for `profiles` at `now`.

  `default` is the scheduler's `default_llm_max_concurrency` floor (`nil` is
  treated as no floor / 0). Each entry is
  `max(effective_concurrency(profile, now), default)` — the exact floor
  `EvoGit.AgentScheduler.State` applies when storing a `:model_concurrency`
  replacement, so the applied map is a fixed point (the engine must NEVER
  compute an unfloored map, or the State would floor it and the engine would
  re-apply forever).
  """
  @spec effective_map([map()], non_neg_integer() | nil, NaiveDateTime.t()) ::
          %{String.t() => non_neg_integer()}
  def effective_map(profiles, default, %NaiveDateTime{} = now) when is_list(profiles) do
    d = default || 0

    Map.new(profiles, fn p ->
      id = Map.get(p, :id, "default")
      eff = PeakHours.effective_concurrency(p, now)
      {id, max(eff || d, d)}
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

    if scheduler_up?() do
      profiles = safe_get_config(:model_profiles, [])

      if is_list(profiles) and profiles != [] do
        default = safe_get_config(:default_llm_max_concurrency, nil)
        effective = effective_map(profiles, default, now)
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

        windows_list =
          Enum.flat_map(profiles, fn p ->
            case PeakHours.validate_windows(Map.get(p, :peak_hours)) do
              {:ok, ws} when ws != [] -> [ws]
              _ -> []
            end
          end)

        ms = next_wakeup_ms(windows_list, now)
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
