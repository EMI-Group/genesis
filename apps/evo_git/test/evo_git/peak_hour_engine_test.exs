defmodule EvoGit.PeakHourEngineTest do
  @moduledoc """
  Integration tests for `EvoGit.PeakHourEngine` — the dynamic peak/off-peak
  LLM concurrency engine.

  The engine is a singleton supervised at app boot, so these tests drive it
  through its public `check/0` API (and the `{:scheduler_config_updated,
  node}` PubSub broadcast path) against the LIVE `EvoGit.AgentScheduler`,
  with the wall clock injected via the `:peak_hours_now_fun` app-env seam.

  `async: false` because the tests push configuration to the global
  `EvoGit.AgentScheduler` GenServer, drive the singleton `PeakHourEngine`, and
  mutate app env `:peak_hours_now_fun` / `:peak_hours_utc_now_fun`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.ModelSelection
  alias EvoGit.Config.Schema
  alias EvoGit.PeakHourEngine

  # Daily window 09:00–12:00 local (raw "HH:MM" form, as in config TOML).
  @window [%{start: "09:00", end: "12:00"}]

  # Canonical form (minutes of day) of the same window, for pure-helper tests.
  @canonical_window %{start: 9 * 60, end: 12 * 60}

  @six_hours_ms 6 * 60 * 60 * 1000

  defp fake_now(hour, minute \\ 0) do
    NaiveDateTime.new!(~D[2026-01-15], Time.new!(hour, minute, 0))
  end

  defp with_clock(fun) do
    Application.put_env(:evo_git, :peak_hours_now_fun, fun)
  end

  defp with_utc_clock(fun) do
    Application.put_env(:evo_git, :peak_hours_utc_now_fun, fun)
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, original_timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        Process.sleep(15)
        do_wait_until(fun, deadline, original_timeout)
    end
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"
    assert Process.whereis(EvoGit.PeakHourEngine), "PeakHourEngine must be supervised"

    # Snapshot and restore canonical accounts AND the selection snapshot, not
    # only the legacy model inventory. Suspend the engine around both operations
    # so its read-then-apply broadcast handler cannot race the restoration.
    :sys.suspend(PeakHourEngine)

    state = :sys.get_state(AgentScheduler)

    config =
      for key <- [
            :model_profiles,
            :provider_profiles,
            :model_selection_config,
            :default_llm_max_concurrency,
            :model_concurrency,
            :llm_model,
            :llm_generation_params
          ] do
        {key, Map.fetch!(state, key)}
      end

    clocks =
      for key <- [:peak_hours_now_fun, :peak_hours_utc_now_fun] do
        {key, Application.fetch_env(:evo_git, key)}
      end

    on_exit(fn ->
      :sys.suspend(PeakHourEngine)

      try do
        Enum.each(clocks, fn
          {key, {:ok, value}} -> Application.put_env(:evo_git, key, value)
          {key, :error} -> Application.delete_env(:evo_git, key)
        end)

        # The public updater rejects an explicit nil llm_model; rebuilding an
        # unconfigured profile set derives that nil itself.
        restore_opts = Enum.reject(config, &(&1 == {:llm_model, nil}))

        assert :ok =
                 AgentScheduler.update_config(
                   restore_opts ++ [model_concurrency_skip_floor: true]
                 )
      after
        :sys.resume(PeakHourEngine)
      end
    end)

    :sys.resume(PeakHourEngine)
    :ok
  end

  describe "canonical provider accounts and nested model selections" do
    test "peak pause and explicit low capacity beat floors for every model in an account" do
      config = provider_config()
      providers = Schema.provider_profiles(config)
      selections = Schema.model_selections(config)
      assert length(selections) == 4

      assert Enum.frequencies_by(selections, & &1.provider_profile_id) == %{
               "paused" => 2,
               "limited" => 2
             }

      # The canonical boundary is string-keyed, including nested model maps.
      assert Enum.all?(providers, &is_list(&1["models"]))

      assert PeakHourEngine.effective_map(providers, 5, fake_now(10)) == %{
               "paused" => 0,
               "limited" => 1
             }

      assert PeakHourEngine.effective_map(providers, 5, fake_now(12)) == %{
               "paused" => 5,
               "limited" => 5
             }

      with_clock(fn -> fake_now(10) end)
      install_provider_config(config)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 0, "limited" => 1}

      assert Map.keys(AgentScheduler.get_llm_slot_status()) |> Enum.sort() == [
               "limited",
               "paused"
             ]

      # Repeated checks must retain zero rather than re-flooring it to five.
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 0, "limited" => 1}

      with_clock(fn -> fake_now(12) end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 5, "limited" => 5}

      with_clock(fn -> fake_now(10) end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 0, "limited" => 1}
    end

    test "account schedules survive nested model/default changes and suppress pauses on off-peak days" do
      with_clock(fn -> fake_now(10) end)
      config = provider_config()
      install_provider_config(config)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 0, "limited" => 1}

      changed =
        update_in(config, [:llm, :providers], fn providers ->
          Enum.map(providers, fn account ->
            account
            |> Map.put(:default_model, "gpt-4.1")
            |> Map.update!(:models, &(&1 ++ [%{model: "gpt-4.1-nano", context_window: 16_000}]))
          end)
        end)

      # Exercise the actual reload broadcast path, not only the pure helper.
      assert :ok = AgentScheduler.update_config(ModelSelection.config_opts(changed))

      wait_until(
        fn ->
          AgentScheduler.get_config(:model_concurrency) == %{"paused" => 0, "limited" => 1}
        end,
        5000
      )

      assert length(AgentScheduler.get_config(:model_profiles)) == 6
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 0, "limited" => 1}

      with_clock(fn -> ~N[2026-01-17 10:00:00] end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"paused" => 5, "limited" => 5}
    end
  end

  defp install_provider_config(config) do
    # Install one coherent account/selection/default snapshot before the engine
    # can observe a broadcast; resume even if a setup assertion fails.
    :sys.suspend(PeakHourEngine)

    try do
      assert :ok =
               AgentScheduler.update_config(
                 ModelSelection.config_opts(config) ++ [default_llm_max_concurrency: 5]
               )
    after
      :sys.resume(PeakHourEngine)
    end
  end

  defp provider_config do
    %{
      llm: %{
        default_provider_profile: "limited",
        providers:
          for {id, peak} <- [{"paused", 0}, {"limited", 1}] do
            %{
              id: id,
              provider: "openai",
              auth_mode: "api_key",
              api_key_env_var: "PEAK_ENGINE_TEST_UNUSED_KEY",
              concurrency: 2,
              peak_concurrency: peak,
              peak_hours: @window,
              off_peak_days: ["sat", "sun"],
              default_model: "gpt-4.1-mini",
              temperature: 0.4,
              reasoning_efforts: ["low", "high"],
              default_reasoning_effort: "low",
              models: [
                %{model: "gpt-4.1", context_window: 64_000, temperature: 0.2},
                %{model: "gpt-4.1-mini", context_window: 32_000, default_reasoning_effort: "high"}
              ]
            }
          end
      }
    }
  end

  describe "engine integration (live scheduler + injected clock)" do
    test "applies peak_concurrency below the default floor inside a peak window" do
      # 10:00 inside 09:00–12:00
      with_clock(fn -> fake_now(10) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{id: "glm", model: "zai:glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}
        ]
      )

      # An explicit in-peak peak_concurrency (2) is an intentional per-model
      # setting and wins over the global default floor (3) — sent as-is.
      AgentScheduler.update_config(default_llm_max_concurrency: 3)

      assert :ok = PeakHourEngine.check()

      # Peak applied (2 < 4) AND exempt from the floor (2 < 3).
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}
    end

    test "applies normal concurrency outside a peak window" do
      # 14:00 outside 09:00–12:00
      with_clock(fn -> fake_now(14) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{id: "glm", model: "zai:glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}
        ]
      )

      assert :ok = PeakHourEngine.check()

      # Off-peak → normal concurrency 4 (first profile's concurrency doubles
      # as the default floor, so max(4, 4) = 4).
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 4}
    end

    test "config reload re-applies via the scheduler_config broadcast" do
      with_clock(fn -> fake_now(10) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{id: "glm", model: "zai:glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}

      # Edit the profile mid-peak: every update_config broadcasts
      # {:scheduler_config_updated, node()} and the engine must re-apply
      # WITHOUT a manual check — wait for the async broadcast to land.
      AgentScheduler.update_config(
        model_profiles: [
          %{id: "glm", model: "zai:glm", concurrency: 4, peak_concurrency: 5, peak_hours: @window}
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      wait_until(
        fn -> AgentScheduler.get_config(:model_concurrency) == %{"glm" => 5} end,
        2000
      )

      # The engine must ignore foreign-node broadcasts (the topic contract
      # carries the emitting node).
      assert Process.whereis(EvoGit.PeakHourEngine) != nil
    end

    test "check is a fixed point — repeated checks never re-apply" do
      with_clock(fn -> fake_now(10) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{id: "glm", model: "zai:glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      # First apply happens here (outside the capture).
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}

      # Let the engine's own apply-broadcast settle, then re-check twice. The
      # floored computation must be a fixed point: no further "applied" log,
      # no map change (an unfloored computation would loop forever here).
      Process.sleep(50)

      logs =
        capture_log([level: :info], fn ->
          assert :ok = PeakHourEngine.check()
          Process.sleep(50)
          assert :ok = PeakHourEngine.check()
        end)

      refute logs =~ "PeakHourEngine: applied model concurrency"
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}
    end

    test "update_config flows through the ReqLLMPool reconciliation path" do
      with_clock(fn -> fake_now(10) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{id: "glm", model: "zai:glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      # The engine's apply is an update_config(model_concurrency:) call — the
      # SAME call that runs reconcile_pool_after_update/1 → ReqLLMPool.reconcile
      # (agent_scheduler.ex). Assert :ok + state change (the pool itself is
      # grow-only and no-ops on unmaterialized origins in tests, so asserting
      # Finch internals here would be flaky — see req_llm_pool_test.exs).
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}

      # Direct update_config also returns :ok (the engine's path is identical,
      # incl. reconcile_pool_after_update/1 → ReqLLMPool.reconcile) — but the
      # engine owns the map, so it re-applies the peak-adjusted value via the
      # broadcast right after.
      assert :ok = AgentScheduler.update_config(model_concurrency: %{"glm" => 3})

      wait_until(
        fn -> AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2} end,
        2000
      )
    end

    test "peak_concurrency below the boot-derived floor applies (user scenario)" do
      # Single profile with concurrency 5 → the boot-time default floor derives
      # from the FIRST profile's concurrency (5). An explicit peak_concurrency
      # 1 inside the window must apply as-is — not be floored back up to 5 —
      # exactly what makes new tasks queue instead of launching with 5 slots.
      with_clock(fn -> fake_now(14, 1) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "deepseek",
            model: "deepseek:deepseek-v4-flash",
            concurrency: 5,
            peak_concurrency: 1,
            peak_hours: [%{start: "14:00", end: "18:00"}]
          }
        ]
      )

      # Simulate the boot-derived floor (first profile's concurrency).
      AgentScheduler.update_config(default_llm_max_concurrency: 5)

      # 14:01 → inside the 14:00–18:00 window: the explicit peak 1 is exempt
      # from the floor and applies as-is.
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"deepseek" => 1}

      # Fixed point: a re-check while still in peak keeps the map at 1 (no
      # flapping back to the floored 5).
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"deepseek" => 1}

      # 13:59 → off-peak (before the window): normal concurrency 5.
      with_clock(fn -> fake_now(13, 59) end)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"deepseek" => 5}

      # Back in peak → 1 again (the engine flips both ways).
      with_clock(fn -> fake_now(14, 1) end)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"deepseek" => 1}
    end

    test "does not crash when the scheduler is down" do
      with_clock(fn -> fake_now(10) end)

      # Stop the scheduler — the AgentGroupSupervisor (one_for_all) will
      # restart it and EvoGit.TaskSupervisor together. No async test touches
      # the live scheduler (verified), so this is safe.
      GenServer.stop(EvoGit.AgentScheduler, :normal, 5_000)

      # The engine must no-op (whereis guard) instead of raising :noproc.
      assert :ok = PeakHourEngine.check()
      assert Process.whereis(EvoGit.PeakHourEngine) != nil

      # The supervisor restarts the scheduler shortly after.
      wait_until(fn -> Process.whereis(EvoGit.AgentScheduler) != nil end, 5000)

      # The engine keeps working once the scheduler is back.
      assert :ok = PeakHourEngine.check()
      assert Process.whereis(EvoGit.PeakHourEngine) != nil
    end

    test "tz profile resolves its wall clock from the utc seam, not the local clock" do
      # Local clock says 08:00 (off-peak for 09:00–12:00), but at 01:00 UTC
      # Shanghai is 09:00 → in peak → peak_concurrency 2 applies. peak is
      # NON-zero so the (old) scheduler-side floor can't interfere.
      with_clock(fn -> fake_now(8) end)
      with_utc_clock(fn -> ~U[2025-01-15 01:00:00Z] end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 2,
            peak_hours: @window,
            timezone: "Asia/Shanghai"
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      assert :ok = PeakHourEngine.check()

      # If the engine had (wrongly) used the local 08:00 clock, off-peak → 4.
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}
    end

    test "tz profile off-peak in its own wall clock applies normal concurrency" do
      # 00:00 UTC = 08:00 Shanghai → off-peak → 4 (local clock 14:00 would be
      # off-peak anyway; the utc seam is what drives the decision).
      with_clock(fn -> fake_now(14) end)
      with_utc_clock(fn -> ~U[2025-01-15 00:00:00Z] end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 2,
            peak_hours: @window,
            timezone: "Asia/Shanghai"
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 4}
    end

    test "off-peak days suppress peak windows entirely (weekend scenario)" do
      # Sat 23:00 inside the 22:00–08:00 window — but Sat is off-peak → 4.
      with_clock(fn -> NaiveDateTime.new!(~D[2026-01-17], Time.new!(23, 0, 0)) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 2,
            peak_hours: [%{start: "22:00", end: "08:00"}],
            off_peak_days: ["sat", "sun"]
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 1)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 4}

      # Fri 23:00 — same window on a weekday → the explicit peak 2 applies.
      with_clock(fn -> NaiveDateTime.new!(~D[2026-01-16], Time.new!(23, 0, 0)) end)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}
    end
  end

  describe "effective_map/3 (pure)" do
    test "peak inside the window below the default floor is preserved" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}]
      # Explicit in-peak peak_concurrency (2) is exempt from the floor (3).
      assert PeakHourEngine.effective_map(profiles, 3, fake_now(10)) == %{"glm" => 2}
    end

    test "peak inside the window without a floor (default nil → 0)" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}]
      assert PeakHourEngine.effective_map(profiles, nil, fake_now(10)) == %{"glm" => 2}
    end

    test "outside the window → normal concurrency" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}]
      assert PeakHourEngine.effective_map(profiles, nil, fake_now(14)) == %{"glm" => 4}
    end

    test "missing id falls back to \"default\"; missing concurrency floors to default" do
      assert PeakHourEngine.effective_map([%{concurrency: 3}], nil, fake_now(10)) ==
               %{"default" => 3}

      assert PeakHourEngine.effective_map([%{id: "x"}], 5, fake_now(10)) == %{"x" => 5}
    end

    test "empty profiles → empty map" do
      assert PeakHourEngine.effective_map([], 3, fake_now(10)) == %{}
    end
  end

  describe "effective_map/3 with off_peak_days (day-aware)" do
    # 22:00–08:00 overnight window, every day (absent :days).
    @overnight_all_days [%{start: 1320, end: 480}]
    @weekend_off [
      %{
        id: "glm",
        concurrency: 4,
        peak_concurrency: 2,
        peak_hours: @overnight_all_days,
        off_peak_days: ["sat", "sun"]
      }
    ]

    test "off-peak day wins: normal concurrency inside what would be a peak window" do
      # Sat 23:00 is inside 22:00–08:00, but Sat is off-peak → 4 (not peak 2).
      sat = NaiveDateTime.new!(~D[2026-01-17], Time.new!(23, 0, 0))
      assert PeakHourEngine.effective_map(@weekend_off, nil, sat) == %{"glm" => 4}
    end

    test "weekday in the same window is peak and exempt from the floor" do
      # Fri 23:00 → in peak → the explicit peak 2 is sent as-is (floor 3 ignored).
      fri = NaiveDateTime.new!(~D[2026-01-16], Time.new!(23, 0, 0))
      assert PeakHourEngine.effective_map(@weekend_off, 3, fri) == %{"glm" => 2}
    end

    test "string-keyed off_peak_days is tolerated on an atom-keyed profile" do
      profiles = [
        %{
          "off_peak_days" => ["sat"],
          id: "glm",
          concurrency: 4,
          peak_concurrency: 2,
          peak_hours: @overnight_all_days
        }
      ]

      sat = NaiveDateTime.new!(~D[2026-01-17], Time.new!(23, 0, 0))
      assert PeakHourEngine.effective_map(profiles, nil, sat) == %{"glm" => 4}
    end
  end

  describe "next_wakeup_ms/2 (pure)" do
    test "inside a window → the window end plus epsilon" do
      assert PeakHourEngine.next_wakeup_ms([[@canonical_window]], fake_now(10)) ==
               7_200_000 + 100
    end

    test "before a window → the window start plus epsilon" do
      assert PeakHourEngine.next_wakeup_ms([[@canonical_window]], fake_now(8)) ==
               3_600_000 + 100
    end

    test "after a window → capped at the 6h safety net" do
      # Next start is tomorrow 09:00 (19h away) — exceeds the 6h cap.
      assert PeakHourEngine.next_wakeup_ms([[@canonical_window]], fake_now(14)) ==
               @six_hours_ms
    end

    test "no windows → 6h safety-net cap" do
      assert PeakHourEngine.next_wakeup_ms([], fake_now(10)) == @six_hours_ms
      assert PeakHourEngine.next_wakeup_ms([[], []], fake_now(10)) == @six_hours_ms
    end

    test "earliest boundary wins across multiple windows" do
      w2 = %{start: 14 * 60, end: 18 * 60}

      # 10:00 → next end of the morning window (12:00, 2h).
      assert PeakHourEngine.next_wakeup_ms([[w2, @canonical_window]], fake_now(10)) ==
               7_200_000 + 100

      # 13:00 → next start of the afternoon window (14:00, 1h).
      assert PeakHourEngine.next_wakeup_ms([[@canonical_window, w2]], fake_now(13)) ==
               3_600_000 + 100
    end
  end

  describe "effective_map/4 (pure, tz-aware)" do
    @tz_profiles [
      %{
        id: "glm",
        concurrency: 4,
        peak_concurrency: 2,
        peak_hours: @window,
        timezone: "Asia/Shanghai"
      }
    ]

    test "tz profile resolves its wall clock from the utc arg" do
      # 00:30 UTC = 08:30 Shanghai → off peak → 4 (local fake_now(8) is the
      # fallback clock, same value here by construction).
      assert PeakHourEngine.effective_map(
               @tz_profiles,
               nil,
               fake_now(8),
               ~U[2025-01-15 00:30:00Z]
             ) ==
               %{"glm" => 4}

      # 01:30 UTC = 09:30 Shanghai → in peak → 2.
      assert PeakHourEngine.effective_map(
               @tz_profiles,
               nil,
               fake_now(8),
               ~U[2025-01-15 01:30:00Z]
             ) ==
               %{"glm" => 2}
    end

    test "tz profile with no utc arg falls back to the local clock" do
      # Arity 3: fake_now(10) is 10:00 local → in peak → 2.
      assert PeakHourEngine.effective_map(@tz_profiles, nil, fake_now(10)) == %{"glm" => 2}
    end

    test "non-tz profile ignores the utc arg (behaves exactly like arity 3)" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 2, peak_hours: @window}]

      assert PeakHourEngine.effective_map(profiles, nil, fake_now(10), ~U[2025-01-15 01:00:00Z]) ==
               %{"glm" => 2}

      assert PeakHourEngine.effective_map(profiles, nil, fake_now(14), ~U[2025-01-15 01:00:00Z]) ==
               %{"glm" => 4}
    end
  end

  describe "effective_map/3 floor rule (peak_concurrency 0)" do
    test "explicit 0 in peak stays 0 even with a default floor" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 0, peak_hours: @window}]
      assert PeakHourEngine.effective_map(profiles, nil, fake_now(10)) == %{"glm" => 0}
      assert PeakHourEngine.effective_map(profiles, 3, fake_now(10)) == %{"glm" => 0}
    end

    test "explicit 0 off peak → normal concurrency" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 0, peak_hours: @window}]
      assert PeakHourEngine.effective_map(profiles, nil, fake_now(14)) == %{"glm" => 4}
      assert PeakHourEngine.effective_map(profiles, 3, fake_now(14)) == %{"glm" => 4}
    end

    test "computation is deterministic (fixed-point re-check is a no-op)" do
      profiles = [%{id: "glm", concurrency: 4, peak_concurrency: 0, peak_hours: @window}]

      assert PeakHourEngine.effective_map(profiles, 3, fake_now(10)) ==
               PeakHourEngine.effective_map(profiles, 3, fake_now(10))

      tz_profiles = [
        %{
          id: "glm",
          concurrency: 4,
          peak_concurrency: 2,
          peak_hours: @window,
          timezone: "Asia/Shanghai"
        }
      ]

      assert PeakHourEngine.effective_map(tz_profiles, nil, fake_now(8), ~U[2025-01-15 01:30:00Z]) ==
               PeakHourEngine.effective_map(
                 tz_profiles,
                 nil,
                 fake_now(8),
                 ~U[2025-01-15 01:30:00Z]
               )
    end
  end

  describe "next_wakeup_ms_for/3 (pure, tz-aware)" do
    test "non-tz pair uses the local clock (same result as next_wakeup_ms/2)" do
      assert PeakHourEngine.next_wakeup_ms_for(
               [{[@canonical_window], nil}],
               fake_now(10),
               ~U[2026-01-15 02:00:00Z]
             ) == 7_200_000 + 100

      assert PeakHourEngine.next_wakeup_ms_for(
               [{[@canonical_window], nil}],
               fake_now(14),
               ~U[2026-01-15 02:00:00Z]
             ) == @six_hours_ms
    end

    test "tz pair converts the wall transition to UTC" do
      # Shanghai window 09:00–12:00; utc_now = 00:30 UTC (08:30 Shanghai) →
      # next transition 09:00 Shanghai = 01:00 UTC → 30min = 1_800_000ms.
      assert PeakHourEngine.next_wakeup_ms_for(
               [{[@canonical_window], "Asia/Shanghai"}],
               fake_now(8),
               ~U[2025-01-15 00:30:00Z]
             ) == 1_800_000 + 100
    end

    test "no transitions → 6h safety-net cap" do
      assert PeakHourEngine.next_wakeup_ms_for([], fake_now(10), ~U[2025-01-15 02:00:00Z]) ==
               @six_hours_ms

      assert PeakHourEngine.next_wakeup_ms_for(
               [{[], "Asia/Shanghai"}],
               fake_now(10),
               ~U[2025-01-15 02:00:00Z]
             ) == @six_hours_ms
    end
  end

  describe "next_wakeup_ms_for/3 with off_peak_days (3-tuples)" do
    test "profiles with only off_peak_days and no windows contribute no transitions" do
      assert PeakHourEngine.next_wakeup_ms_for(
               [{[], [:sat, :sun], nil}],
               fake_now(10),
               ~U[2026-01-15 02:00:00Z]
             ) == @six_hours_ms
    end

    test "midnight entering an off-peak day is the next wakeup" do
      # Fri 23:00 inside 22:00–08:00 → the next flip is Sat 00:00 (1h away);
      # the engine must NOT schedule a pointless Sat mid-day wakeup.
      overnight = [%{start: 1320, end: 480}]
      fri = NaiveDateTime.new!(~D[2026-01-16], Time.new!(23, 0, 0))

      assert PeakHourEngine.next_wakeup_ms_for(
               [{overnight, [:sat, :sun], nil}],
               fri,
               ~U[2026-01-16 15:00:00Z]
             ) == 3_600_000 + 100
    end

    test "a far-away day-scoped transition exceeds the 6h safety-net cap" do
      # Mon-only window at Mon 13:00 → next boundary is NEXT Mon 09:00 (≫ 6h).
      mon_only = [%{start: 540, end: 720, days: [:mon]}]
      mon = NaiveDateTime.new!(~D[2026-01-19], Time.new!(13, 0, 0))

      assert PeakHourEngine.next_wakeup_ms_for(
               [{mon_only, [], nil}],
               mon,
               ~U[2026-01-19 05:00:00Z]
             ) == @six_hours_ms
    end
  end

  describe "canonical integer-minute windows (regression)" do
    test "in-peak applies peak_concurrency, off-peak applies concurrency" do
      with_clock(fn -> fake_now(10) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 2,
            peak_hours: [%{start: 540, end: 720}]
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 3)

      # 10:00 inside 09:00–12:00 → explicit in-peak 2 wins over the floor 3.
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}

      # 22:00 off-peak → normal concurrency 4.
      with_clock(fn -> fake_now(22) end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 4}
    end

    test "string-keyed integer windows (TOML-decoded shape)" do
      with_clock(fn -> fake_now(10) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 2,
            peak_hours: [%{"start" => 540, "end" => 720}]
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 3)

      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}
    end

    test "boundary times: start inclusive, end exclusive" do
      with_clock(fn -> fake_now(9, 0) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 2,
            peak_hours: [%{start: 540, end: 720}]
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 3)

      # 09:00 = window start → in peak → 2.
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 2}

      # 12:00 = window end → off peak (half-open) → 4.
      with_clock(fn -> fake_now(12, 0) end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 4}
    end

    test "overnight integer windows wrap midnight" do
      # 22:00–06:00 overnight window.
      with_clock(fn -> fake_now(23) end)

      AgentScheduler.update_config(
        model_profiles: [
          %{
            id: "glm",
            model: "zai:glm",
            concurrency: 4,
            peak_concurrency: 1,
            peak_hours: [%{start: 1320, end: 360}]
          }
        ]
      )

      AgentScheduler.update_config(default_llm_max_concurrency: 3)

      # 23:00 and 05:00 inside [22:00, 24:00) ∪ [00:00, 06:00) → peak 1.
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 1}

      with_clock(fn -> fake_now(5) end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 1}

      # 07:00 after the window → normal concurrency 4.
      with_clock(fn -> fake_now(7) end)
      assert :ok = PeakHourEngine.check()
      assert AgentScheduler.get_config(:model_concurrency) == %{"glm" => 4}
    end
  end
end
