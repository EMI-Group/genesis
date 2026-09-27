defmodule EvoGit.Agent.CostTest do
  @moduledoc """
  `async: false` — `EvoGit.Agent.Cost` is only reachable through BEAM-global
  state:

    * `recompute_for_agent/2` / `apply_to_usage/3` read the GLOBAL
      `EvoGit.AgentScheduler` (`get_agent_state/1` → the app-owned
      `:evogit_agent_state` ETS table), and the positive-path tests here
      insert/delete rows in that table;
    * `period_for_model_id/1` reads the scheduler's LIVE `:model_profiles`
      config, so its tests temporarily REPLACE that list (restored on exit)
      with `EvoGit.PeakHourEngine` suspended — the same idiom as
      `agent_scheduler/agent_scheduler_test.exs` (the app-supervised engine
      re-applies a floored `model_concurrency` map on every
      `"scheduler_config"` broadcast and would otherwise race the assertions);
    * the pricing-period tests mutate the shared app-env clock seams
      `:peak_hours_now_fun` / `:peak_hours_utc_now_fun` (read at call time by
      `EvoGit.Agent.Cost` AND by `EvoGit.PeakHourEngine`), restored via
      `on_exit` for every test.

  The FIRST `ReqLLM.model/1` call in a fresh BEAM decodes llm_db's packaged
  pricing catalog (~2.5-3.5 s, once) — expected, not a failure.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Cost
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store, as: SchedulerStore
  alias EvoGit.Core.ContextNode

  # A model whose catalog pricing has an explicit peak/off-peak split:
  #   off-peak — token.input 0.15/M, token.output 0.6/M, token.cache_read 0.003/M
  #   peak     — token.input 0.3/M,  token.output 1.2/M, token.cache_read 0.006/M
  # and `pricing.excluded_cost_components == ["token.reasoning"]`.
  @model "deepseek:deepseek-v4-flash"

  # Shared usage fixture. `input_includes_cached` is DERIVED true here
  # (cached_tokens > 0 and cached_tokens <= input_tokens), so the cache-MISS
  # input billed at the input rate is 14_434_811 - 14_164_224 = 270_587.
  @usage %{
    input_tokens: 14_434_811,
    output_tokens: 263_800,
    cached_tokens: 14_164_224
  }

  # round6 components of @usage under the off-peak tariff:
  #   cache-miss  270_587    x 0.15  / 1e6 = 0.04058805  → 0.040588
  #   cache-read  14_164_224 x 0.003 / 1e6 = 0.042492672 → 0.042493
  #   input = 0.083081 ; output 263_800 x 0.6 / 1e6 = 0.15828
  #   total = 0.241361
  @off_peak_input 0.083081
  @off_peak_output 0.15828
  @off_peak_total 0.241361

  # The same under the peak tariff (every rate doubled):
  #   input 0.081176 + 0.084985 = 0.166161 ; output = 0.31656 ; total 0.482721
  @peak_input 0.166161
  @peak_output 0.31656
  @peak_total 0.482721

  # Billing the FULL 14_434_811 input tokens at the off-peak input rate (the
  # no-cache-discount result) = 2.16522165 → 0.165222… rounded to 2.165222.
  @full_input_at_input_rate 2.165222

  # The cache-miss term alone, with no cache-read component.
  @cache_miss_only_input 0.040588

  @delta 1.0e-6

  # Two profiles with a shared 09:00-17:00 peak window — one atom-keyed and one
  # STRING-keyed (the scheduler's profile list may carry either shape) — used to
  # prove the id lookup + peak-window resolution of `period_for_model_id/1`.
  @peak_profiles [
    %{
      id: "cost-test-peak",
      model: @model,
      concurrency: 3,
      peak_hours: [%{start: "09:00", end: "17:00"}],
      peak_concurrency: 5
    },
    %{
      "id" => "cost-test-string-keyed",
      "model" => @model,
      "concurrency" => 3,
      "peak_hours" => [%{"start" => "09:00", "end" => "17:00"}],
      "peak_concurrency" => 5
    }
  ]

  # Every test may set the clock seams; restore them unconditionally so no
  # seam value (or absence) leaks into a later test or module.
  setup do
    local = Application.get_env(:evo_git, :peak_hours_now_fun)
    utc = Application.get_env(:evo_git, :peak_hours_utc_now_fun)

    on_exit(fn ->
      restore_app_env(:peak_hours_now_fun, local)
      restore_app_env(:peak_hours_utc_now_fun, utc)
    end)

    :ok
  end

  # ==========================================================================
  # recompute/3 — the formula
  # ==========================================================================

  describe "recompute/3 — off-peak tariff" do
    test "bills cache-miss input + cache-read + output with the off-peak rates" do
      costs = Cost.recompute(@usage, @model, "off_peak")

      assert %{input_cost: input, output_cost: output, total_cost: total} = costs
      assert_in_delta input, @off_peak_input, @delta
      assert_in_delta output, @off_peak_output, @delta
      assert_in_delta total, @off_peak_total, @delta
      assert total == Float.round(input + output, 6)
    end

    test "an explicit input_includes_cached: true yields the same numbers" do
      explicit = Map.put(@usage, :input_includes_cached, true)

      assert Cost.recompute(explicit, @model, "off_peak") ==
               Cost.recompute(@usage, @model, "off_peak")
    end

    test "only the exact \"peak\" string selects peak — every other period is off-peak" do
      expected = Cost.recompute(@usage, @model, "off_peak")

      for odd_period <- ["PEAK", "offpeak", "", nil, :peak, 0] do
        assert Cost.recompute(@usage, @model, odd_period) == expected
      end
    end
  end

  describe "recompute/3 — peak tariff" do
    test "doubles both buckets and the total versus off-peak" do
      off_peak = Cost.recompute(@usage, @model, "off_peak")
      peak = Cost.recompute(@usage, @model, "peak")

      assert_in_delta peak.input_cost, @peak_input, @delta
      assert_in_delta peak.output_cost, @peak_output, @delta
      assert_in_delta peak.total_cost, @peak_total, @delta

      # Components are rounded individually, so allow one ulp of the 6-decimal
      # rounding on the doubling comparison.
      assert_in_delta peak.input_cost, off_peak.input_cost * 2, 2.0 * @delta
      assert_in_delta peak.output_cost, off_peak.output_cost * 2, 2.0 * @delta
      assert_in_delta peak.total_cost, off_peak.total_cost * 2, 2.0 * @delta
    end
  end

  describe "recompute/3 — cache discount" do
    test "cached tokens are billed at the cache-read rate, not the full input rate" do
      costs = Cost.recompute(@usage, @model, "off_peak")

      # More than the cache-miss term alone — the cache-read component IS
      # charged (input 0.040588 + cache-read 0.042493 = 0.083081) ...
      assert costs.input_cost > @cache_miss_only_input
      assert_in_delta costs.input_cost, @cache_miss_only_input + 0.042493, @delta
      # ... and far below billing every input token at the input rate.
      assert costs.input_cost < 1.0
      assert @full_input_at_input_rate > costs.input_cost * 20
    end

    test "no cached tokens means the full input is billed at the input rate" do
      costs = Cost.recompute(Map.put(@usage, :cached_tokens, 0), @model, "off_peak")

      # Derived input_includes_cached = false → the FULL input is billed at the
      # input rate; the cache-read component's count is 0, so its contribution
      # is exactly 0 and input_cost equals the pure full-input term.
      assert_in_delta costs.input_cost, @full_input_at_input_rate, @delta
      assert costs.input_cost > 1.0

      discounted = Cost.recompute(@usage, @model, "off_peak")
      assert costs.input_cost > discounted.input_cost * 20
    end
  end

  describe "recompute/3 — reasoning is never charged twice" do
    test "reasoning tokens add no separate charge (deepseek excludes token.reasoning)" do
      base = Cost.recompute(@usage, @model, "off_peak")

      with_reasoning =
        Cost.recompute(Map.put(@usage, :reasoning_tokens, 999_999), @model, "off_peak")

      assert with_reasoning == base
      assert with_reasoning.output_cost == base.output_cost
      assert with_reasoning.total_cost == base.total_cost
    end
  end

  describe "recompute/3 — nil / zero fallbacks (never raises)" do
    test "returns nil when the model spec cannot be resolved" do
      assert Cost.recompute(@usage, "no-such-provider:no-such-model", "off_peak") == nil
    end

    test "returns nil for a non-map usage map" do
      for bad <- [nil, "garbage", 42, :atom, [], {:ok, %{}}] do
        assert Cost.recompute(bad, @model, "off_peak") == nil
      end
    end

    test "returns a ZERO-cost map (not nil) for an empty usage map" do
      assert Cost.recompute(%{}, @model, "off_peak") ==
               %{input_cost: 0.0, output_cost: 0.0, total_cost: 0.0}
    end

    test "never raises for arbitrary model specs (nil or a cost map)" do
      for spec <- [nil, 42, "no-such-provider:no-such-model", %{}, [], self()] do
        result = Cost.recompute(@usage, spec, "peak")
        assert is_nil(result) or is_map(result)
      end
    end
  end

  # ==========================================================================
  # recompute_for_agent/2
  # ==========================================================================

  describe "recompute_for_agent/2" do
    test "returns nil when the agent state is gone" do
      assert Cost.recompute_for_agent(@usage, 999_999_999) == nil
    end

    test "returns nil for a nil agent id" do
      assert Cost.recompute_for_agent(@usage, nil) == nil
    end

    test "recomputes from the agent's llm_model with the model profile's period" do
      agent_id =
        register_agent!(987_654, %{
          llm_model: @model,
          # Not a configured profile id → the normal off-peak tariff.
          model_id: "cost-test-model"
        })

      assert Cost.recompute_for_agent(@usage, agent_id) ==
               Cost.recompute(@usage, @model, "off_peak")
    end

    test "returns nil when the agent's model spec is unresolvable" do
      agent_id = register_agent!(987_655, %{llm_model: "no-such-provider:no-such-model"})

      assert Cost.recompute_for_agent(@usage, agent_id) == nil
    end
  end

  # ==========================================================================
  # apply_to_usage/3
  # ==========================================================================

  describe "apply_to_usage/3" do
    test "leaves the struct byte-identical for a nonexistent agent id" do
      usage = reported_usage()

      assert Cost.apply_to_usage(usage, @usage, 999_999_999) == usage
    end

    test "leaves the struct byte-identical for a nil agent id" do
      usage = reported_usage()

      assert Cost.apply_to_usage(usage, @usage, nil) == usage
    end

    test "leaves the struct byte-identical when no recomputation is possible" do
      usage = reported_usage()

      assert Cost.apply_to_usage(usage, nil, 999_999_999) == usage

      agent_id = register_agent!(987_656, %{llm_model: @model})
      assert Cost.apply_to_usage(usage, nil, agent_id) == usage
    end

    test "overrides ONLY the three cost fields of a scheduled agent's usage" do
      agent_id = register_agent!(987_657, %{llm_model: @model})

      applied = Cost.apply_to_usage(reported_usage(), @usage, agent_id)

      assert_in_delta applied.input_cost, @off_peak_input, @delta
      assert_in_delta applied.output_cost, @off_peak_output, @delta
      assert_in_delta applied.total_cost, @off_peak_total, @delta

      # Token counts / cache fields keep exactly what the caller read.
      assert %Usage{
               input_tokens: 14_434_811,
               output_tokens: 263_800,
               total_tokens: 14_698_611,
               cached_tokens: 14_164_224,
               cache_creation_tokens: 0
             } = applied
    end
  end

  # ==========================================================================
  # period_for_model_id/1
  # ==========================================================================

  describe "period_for_model_id/1" do
    test "a configured peak profile is peak inside its window, off-peak outside" do
      with_peak_profiles!(@peak_profiles)

      set_peak_clock(~N[2024-01-01 12:00:00])
      assert Cost.period_for_model_id("cost-test-peak") == "peak"
      # The lookup tolerates an atom id (normalized via Atom.to_string/1) ...
      assert Cost.period_for_model_id(:"cost-test-peak") == "peak"
      # ... and a STRING-keyed profile map.
      assert Cost.period_for_model_id("cost-test-string-keyed") == "peak"

      set_peak_clock(~N[2024-01-01 08:00:00])
      assert Cost.period_for_model_id("cost-test-peak") == "off_peak"
    end

    test "an unknown / nil / non-matching id is off-peak" do
      with_peak_profiles!(@peak_profiles)
      set_peak_clock(~N[2024-01-01 12:00:00])

      for unknown <- ["no-such-profile", nil, 42, :cost_test_peak, %{}, []] do
        assert Cost.period_for_model_id(unknown) == "off_peak"
      end
    end

    test "a configured profile without peak windows is off-peak" do
      with_peak_profiles!([%{id: "cost-test-flat", model: @model, concurrency: 3}])
      set_peak_clock(~N[2024-01-01 12:00:00])

      assert Cost.period_for_model_id("cost-test-flat") == "off_peak"
    end

    test "never raises for an odd id shape" do
      with_peak_profiles!(@peak_profiles)

      assert Cost.period_for_model_id(%{id: "cost-test-peak"}) == "off_peak"
      assert Cost.period_for_model_id({:ok, "cost-test-peak"}) == "off_peak"
    end
  end

  # ==========================================================================
  # period_for_profile/1
  # ==========================================================================

  describe "period_for_profile/1" do
    test "a profile with no peak configuration is always off-peak" do
      assert Cost.period_for_profile(%{}) == "off_peak"
      assert Cost.period_for_profile(%{id: "x", peak_concurrency: 5}) == "off_peak"
      assert Cost.period_for_profile(%{peak_hours: []}) == "off_peak"
      assert Cost.period_for_profile(%{peak_hours: "09:00-17:00"}) == "off_peak"

      assert Cost.period_for_profile(%{peak_hours: [%{start: "nope", end: "17:00"}]}) ==
               "off_peak"
    end

    test "a non-map profile is off-peak" do
      assert Cost.period_for_profile(nil) == "off_peak"
      assert Cost.period_for_profile("peak") == "off_peak"
      assert Cost.period_for_profile(42) == "off_peak"
    end

    test "the clock seam drives in-window vs out-of-window resolution" do
      profile = %{id: "x", peak_hours: [%{start: "09:00", end: "17:00"}], peak_concurrency: 5}

      set_peak_clock(~N[2024-01-01 12:00:00])
      assert Cost.period_for_profile(profile) == "peak"

      set_peak_clock(~N[2024-01-01 08:00:00])
      assert Cost.period_for_profile(profile) == "off_peak"

      # Half-open window [start, end) — the end instant is already off-peak.
      set_peak_clock(~N[2024-01-01 17:00:00])
      assert Cost.period_for_profile(profile) == "off_peak"
    end

    test "off_peak_days wins over an in-window instant" do
      profile = %{
        id: "x",
        peak_hours: [%{start: "09:00", end: "17:00"}],
        peak_concurrency: 5,
        off_peak_days: ["mon"]
      }

      # 2024-01-01 is a Monday — off_peak_days suppresses the window entirely.
      set_peak_clock(~N[2024-01-01 12:00:00])
      assert Cost.period_for_profile(profile) == "off_peak"

      # ... the very same window on a Tuesday is peak again.
      set_peak_clock(~N[2024-01-02 12:00:00])
      assert Cost.period_for_profile(profile) == "peak"
    end

    test "a timezone profile resolves the UTC seam into the zone's wall clock" do
      profile = %{
        id: "x",
        peak_hours: [%{start: "09:00", end: "17:00"}],
        peak_concurrency: 5,
        timezone: "America/New_York"
      }

      # 17:00 UTC == 12:00 in New York (EST) → inside the window.
      set_peak_utc_clock(~U[2024-01-01 17:00:00Z])
      assert Cost.period_for_profile(profile) == "peak"

      # 21:00 UTC == 16:00 in New York → still inside.
      set_peak_utc_clock(~U[2024-01-01 21:00:00Z])
      assert Cost.period_for_profile(profile) == "peak"

      # 23:00 UTC == 18:00 in New York → outside.
      set_peak_utc_clock(~U[2024-01-01 23:00:00Z])
      assert Cost.period_for_profile(profile) == "off_peak"
    end

    test "an invalid timezone falls back to the LOCAL wall clock" do
      profile = %{
        id: "x",
        peak_hours: [%{start: "09:00", end: "17:00"}],
        peak_concurrency: 5,
        timezone: "Not/AZone"
      }

      set_peak_utc_clock(~U[2024-01-01 17:00:00Z])
      set_peak_clock(~N[2024-01-01 08:00:00])
      assert Cost.period_for_profile(profile) == "off_peak"

      set_peak_clock(~N[2024-01-01 12:00:00])
      assert Cost.period_for_profile(profile) == "peak"
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # An already-built (ReqLLM-reported) usage struct: the three cost fields are
  # deliberately wrong so an override is observable, while every token count
  # mirrors the raw usage map.
  defp reported_usage do
    %Usage{
      input_tokens: 14_434_811,
      output_tokens: 263_800,
      total_tokens: 14_698_611,
      cached_tokens: 14_164_224,
      cache_creation_tokens: 0,
      input_cost: 1.1,
      output_cost: 2.2,
      total_cost: 3.3
    }
  end

  # Temporarily replaces the GLOBAL scheduler's `:model_profiles` list and
  # suspends the app-supervised `EvoGit.PeakHourEngine` for the test's duration,
  # so its async `model_concurrency` re-application cannot race the assertions.
  # The original profile list is restored BEFORE the engine is resumed, so the
  # queued `"scheduler_config"` broadcasts are re-derived from the real config.
  defp with_peak_profiles!(profiles) do
    original = AgentScheduler.get_config(:model_profiles)
    engine = Process.whereis(EvoGit.PeakHourEngine)
    if engine, do: :sys.suspend(engine)

    on_exit(fn ->
      AgentScheduler.update_config(model_profiles: original)
      if engine, do: :sys.resume(engine)
    end)

    :ok = AgentScheduler.update_config(model_profiles: profiles)
  end

  # Registers an agent in the app-global `:evogit_agent_state` ETS table (the
  # `EvoGit.AgentScheduler.get_agent_state/1` source) and removes it on exit.
  defp register_agent!(agent_id, attrs) do
    state =
      struct!(
        AgentState,
        Map.merge(
          %{
            context_node: %ContextNode{path: "./", repo: "/tmp/cost-test-repo"},
            llm_model: @model,
            max_retries: 2,
            max_depth: 1
          },
          attrs
        )
      )

    SchedulerStore.put_agent_state(agent_id, state)
    on_exit(fn -> SchedulerStore.delete_agent_state(agent_id) end)

    agent_id
  end

  defp set_peak_clock(%NaiveDateTime{} = naive) do
    Application.put_env(:evo_git, :peak_hours_now_fun, fn -> naive end)
  end

  defp set_peak_utc_clock(%DateTime{} = utc) do
    Application.put_env(:evo_git, :peak_hours_utc_now_fun, fn -> utc end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)
end
