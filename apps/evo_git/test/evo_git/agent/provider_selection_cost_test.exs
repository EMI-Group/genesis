defmodule EvoGit.Agent.ProviderSelectionCostTest do
  @moduledoc """
  Permanent regressions for canonical account/model selection through the scheduler
  adapter into cost recomputation, using real catalog prices (no HTTP/LLM calls).

  `async: false` because every test installs canonical configuration on the global
  EvoGit.AgentScheduler, suspends the global PeakHourEngine and sets the shared
  :peak_hours_now_fun clock seam. All three configuration fields and the clock
  are restored before the engine resumes. Agent ETS rows have unique IDs and
  production structs; cleanup deletes only those rows. Credential files use the
  per-process ConfigDir seam, never the developer's files or process-wide env.

  Generation params can contain credentials: assertions inspect individual fields,
  never dump a resolved profile or the complete parameter list. Prices are pinned
  independently of Cost.recompute/3 so choosing the wrong default/model/account
  cannot make an equality against the same implementation pass vacuously.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.{Cost, Usage}
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{AgentState, ModelSelection, State}
  alias EvoGit.AgentScheduler.Store, as: SchedulerStore
  alias EvoGit.AgentSpec
  alias EvoGit.Config.Schema
  alias EvoGit.Core.ContextNode

  @flash "deepseek-v4-flash"
  @pro "deepseek-v4-pro"
  @endpoint "https://cost-account.invalid/v1"
  @cost_fields [:input_cost, :output_cost, :total_cost]

  # One million prompt tokens including 200k cache hits, and one million output
  # tokens including reasoning. Catalog USD/M-token rates:
  # flash off-peak: input .15, cache .003, output .6; peak: .3/.006/1.2.
  # pro off-peak: input .66, cache .022, output 1.98; peak: 1.32/.044/3.96.
  @raw %{
    input_tokens: 1_000_000,
    output_tokens: 1_000_000,
    total_tokens: 2_000_000,
    cached_tokens: 200_000,
    input_includes_cached: true,
    reasoning_tokens: 700_000
  }
  @flash_off %{input_cost: 0.1206, output_cost: 0.6, total_cost: 0.7206}
  @flash_peak %{input_cost: 0.2412, output_cost: 1.2, total_cost: 1.4412}
  @pro_off %{input_cost: 0.5324, output_cost: 1.98, total_cost: 2.5124}
  @pro_peak %{input_cost: 1.0648, output_cost: 3.96, total_cost: 5.0248}

  setup do
    EvoGit.TestSupport.ConfigDir.isolate!("provider-selection-cost")
    engine = Process.whereis(EvoGit.PeakHourEngine)
    if engine, do: :sys.suspend(engine)

    original = :sys.get_state(AgentScheduler)
    clock = Application.fetch_env(:evo_git, :peak_hours_now_fun)

    on_exit(fn ->
      :ok =
        AgentScheduler.update_config(
          model_profiles: original.model_profiles,
          provider_profiles: original.provider_profiles,
          model_selection_config: original.model_selection_config
        )

      case clock do
        {:ok, value} -> Application.put_env(:evo_git, :peak_hours_now_fun, value)
        :error -> Application.delete_env(:evo_git, :peak_hours_now_fun)
      end

      if engine, do: :sys.resume(engine)
    end)

    set_clock(~N[2024-01-01 08:00:00])
    config = config()
    install!(config)
    %{config: config}
  end

  describe "selected model, account defaults and nested overrides" do
    test "configured account and model defaults beat inventory order and stale legacy config",
         %{config: config} do
      for requested <- [nil, "work", %{"provider_profile_id" => "work"}] do
        selection = select!(config, requested)
        assert selection.provider_profile_id == "work"
        assert selection.model_spec["model"] == @flash
        assert selection.llm_model == endpoint_model(@flash)
        assert selection.model_spec["reasoning_effort"] == "high"
        assert Keyword.fetch!(selection.llm_generation_params, :reasoning_effort) == :high
        assert_cost(selection, @flash_off)
      end
    end

    test "a nested model changes effective price, generation defaults and reasoning, not account",
         %{config: config} do
      selection = select!(config, wire("work", @pro))
      assert selection.provider_profile_id == "work"
      assert selection.model_id == nil
      assert selection.llm_model == endpoint_model(@pro)
      assert selection.model_spec == wire("work", @pro, "low")
      assert Keyword.fetch!(selection.llm_generation_params, :temperature) == 0.6
      assert Keyword.fetch!(selection.llm_generation_params, :max_tokens) == 4_096
      assert Keyword.fetch!(selection.llm_generation_params, :top_p) == 0.9
      assert Keyword.fetch!(selection.llm_generation_params, :reasoning_effort) == :low
      assert selection.llm_context_window == 256_000
      assert_cost(selection, @pro_off)
    end

    test "nil nested generation overrides inherit account defaults without switching price",
         %{config: config} do
      config =
        update_work(config, fn account ->
          Map.put(account, :models, [
            %{model: @pro, temperature: nil, max_tokens: nil, context_window: nil},
            @flash
          ])
        end)

      install!(config)
      selection = select!(config, wire("work", @pro))
      assert Keyword.fetch!(selection.llm_generation_params, :temperature) == 0.2
      assert Keyword.fetch!(selection.llm_generation_params, :max_tokens) == 2_048
      assert Keyword.fetch!(selection.llm_generation_params, :reasoning_effort) == :high
      assert selection.llm_context_window == 160_000
      assert_cost(selection, @pro_off)
    end

    test "models share an account's scheduling defaults but never its default model price",
         %{config: config} do
      flash = resolve!(config, wire("work", @flash))
      pro = resolve!(config, wire("work", @pro))

      for resolved <- [flash, pro] do
        assert resolved.provider_profile_id == "work"
        assert resolved.concurrency == 7
        assert resolved.peak_concurrency == 0
        assert resolved.peak_hours == [%{"start" => "09:00", "end" => "17:00"}]
      end

      assert_cost(select!(config, wire("work", @flash)), @flash_off)
      assert_cost(select!(config, wire("work", @pro)), @pro_off)
      assert_cost(select!(config, "work"), @flash_off)
    end

    test "explicit reasoning changes the request, not the selected model's token tariff",
         %{config: config} do
      for effort <- ["low", "high"] do
        selection = select!(config, wire("work", @pro, effort))
        assert selection.model_spec == wire("work", @pro, effort)
        assert selection.llm_model == endpoint_model(@pro)

        assert Keyword.fetch!(selection.llm_generation_params, :reasoning_effort) ==
                 Schema.LLM.convert_reasoning_effort(effort)

        assert_cost(selection, @pro_off)
      end
    end

    test "an absent reasoning default stays absent rather than borrowing another account's effort",
         %{config: config} do
      selection = select!(config, wire("backup", @flash))
      assert selection.model_spec == wire("backup", @flash)
      refute Keyword.has_key?(selection.llm_generation_params, :reasoning_effort)
      assert_cost(selection, @flash_off)
    end

    test "unsupported reasoning and unknown models are errors, never billable default selections",
         %{config: config} do
      assert Schema.resolve_model_spec(config, wire("work", @pro, "xhigh")) ==
               {:error, {:unsupported_reasoning_effort, "xhigh", ["low", "high"]}}

      assert ModelSelection.resolve(snapshot(config), wire("work", "not-configured")) ==
               {:error, {:model_not_found, "work", "not-configured"}}

      assert ModelSelection.resolve(snapshot(config), wire("missing", @flash)) ==
               {:error, {:provider_profile_not_found, "missing"}}
    end

    test "JSON-round-tripped config and full task selections preserve effective price and effort",
         %{config: config} do
      config = config |> Jason.encode!() |> Jason.decode!()
      install!(config)
      requested = wire("work", @pro, "high") |> Jason.encode!() |> Jason.decode!()
      selection = select!(config, requested)
      assert selection.model_spec == requested
      assert selection.llm_model == endpoint_model(@pro)
      assert Keyword.fetch!(selection.llm_generation_params, :reasoning_effort) == :high
      assert_cost(selection, @pro_off)
    end
  end

  describe "ReqLLM identifiers and account isolation" do
    test "the schema model_spec is a ReqLLM identifier, never the task-selection map",
         %{config: config} do
      resolved = resolve!(config, wire("work", @pro, "high"))
      assert resolved.model_spec == endpoint_model(@pro)
      assert resolved.runtime_profile.model == resolved.model_spec
      refute Map.has_key?(resolved.model_spec, "provider_profile_id")
      assert Cost.recompute(@raw, resolved.model_spec, "off_peak") == @pro_off

      selection = select!(config, wire("work", @pro, "high"))
      assert selection.model_spec == wire("work", @pro, "high")
      assert selection.llm_model == resolved.model_spec
      assert_cost(selection, @pro_off)
    end

    test "custom endpoint identifiers recover the selected catalog model's price, not zero",
         %{config: config} do
      for {model, expected} <- [{@flash, @flash_off}, {@pro, @pro_off}] do
        native = select!(config, wire("backup", model))
        custom = select!(config, wire("work", model))
        assert native.llm_model == "deepseek:" <> model
        assert custom.llm_model == endpoint_model(model)
        assert_cost(native, expected)
        assert_cost(custom, expected)
      end
    end

    test "two accounts keep credentials, endpoint and generation defaults isolated while pricing the same model",
         %{config: config} do
      suffix = Integer.to_string(System.unique_integer([:positive]))
      work_key = "COST_REGRESSION_WORK_" <> suffix
      backup_key = "COST_REGRESSION_BACKUP_" <> suffix
      dir = EvoGit.Config.config_dir()
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "credentials.toml"),
        "#{work_key} = \"synthetic-work-secret\"\n#{backup_key} = \"synthetic-backup-secret\"\n"
      )

      config =
        update_in(config, [:llm, :providers], fn accounts ->
          Enum.map(accounts, fn account ->
            key = if account.id == "work", do: work_key, else: backup_key
            Map.put(account, :api_key_env_var, key)
          end)
        end)

      install!(config)
      work = select!(config, wire("work", @pro))
      backup = select!(config, wire("backup", @pro))
      assert Keyword.fetch!(work.llm_generation_params, :api_key) == "synthetic-work-secret"
      assert Keyword.fetch!(backup.llm_generation_params, :api_key) == "synthetic-backup-secret"
      assert Keyword.fetch!(work.llm_generation_params, :temperature) == 0.6
      assert Keyword.fetch!(backup.llm_generation_params, :temperature) == 0.8
      assert work.llm_model == endpoint_model(@pro)
      assert backup.llm_model == "deepseek:" <> @pro
      refute Map.has_key?(work.model_spec, "api_key")
      refute Map.has_key?(backup.model_spec, "api_key")
      assert_cost(work, @pro_off)
      assert_cost(backup, @pro_off)
    end

    test "pricing follows effective llm_model even when account and selection labels suggest another model",
         %{config: config} do
      selection = select!(config, "work")
      assert selection.model_spec["model"] == @flash
      selection = %{selection | llm_model: endpoint_model(@pro)}
      assert_cost(selection, @pro_off)
    end

    test "an unpriced selected model never borrows the configured default's catalog price",
         %{config: config} do
      config =
        update_work(config, fn account ->
          Map.update!(account, :models, &(&1 ++ ["private-unpriced-model"]))
        end)

      install!(config)
      selection = select!(config, wire("work", "private-unpriced-model"))
      assert selection.llm_model == endpoint_model("private-unpriced-model")
      id = register!(selection)
      assert Cost.recompute_for_agent(@raw, id) == nil
      reported = reported_usage()
      assert Cost.apply_to_usage(reported, @raw, id) == reported
    end
  end

  describe "full selection inheritance" do
    test "locked children inherit account, alternate model and explicit reasoning together",
         %{config: config} do
      parent = select!(config, wire("work", @pro, "high"))
      child = child_spec(wire("backup", @flash))

      inherited = ModelSelection.inherit(child, Map.put(parent, :model_id_locked, true))
      assert inherited.model_spec == wire("work", @pro, "high")
      assert inherited.opts[:model_spec] == inherited.model_spec
      assert inherited.opts[:model_id_locked] == true
      assert {:ok, requested} = ModelSelection.explicit_spec(inherited)
      selection = select!(config, requested)
      assert selection.provider_profile_id == "work"
      assert Keyword.fetch!(selection.llm_generation_params, :reasoning_effort) == :high
      assert_cost(selection, @pro_off)
    end

    test "unlocked children retain their own model rather than inherit a parent's more expensive tariff",
         %{config: config} do
      parent = select!(config, wire("work", @pro, "high"))
      child = child_spec(wire("backup", @flash))
      inherited = ModelSelection.inherit(child, Map.put(parent, :model_id_locked, false))
      assert inherited == child
      assert {:ok, requested} = ModelSelection.explicit_spec(inherited)
      assert_cost(select!(config, requested), @flash_off)
    end

    test "a locked inherited selection keeps its own account's peak tariff",
         %{config: config} do
      set_clock(~N[2024-01-01 12:00:00])
      parent = select!(config, wire("work", @pro, "high"))
      inherited = ModelSelection.inherit(child_spec(nil), Map.put(parent, :model_id_locked, true))
      assert {:ok, requested} = ModelSelection.explicit_spec(inherited)
      assert_cost(select!(config, requested), @pro_peak)
    end
  end

  describe "account pricing period, independent of selected model and legacy id" do
    test "canonical provider profiles supply peak scheduling, not the model inventory",
         %{config: config} do
      set_clock(~N[2024-01-01 12:00:00])
      assert length(AgentScheduler.get_config(:provider_profiles)) == 2
      assert Cost.period_for_provider_profile_id("work") == "peak"
      assert Cost.period_for_provider_profile_id("backup") == "off_peak"
      assert_cost(select!(config, wire("work", @flash)), @flash_peak)
      assert_cost(select!(config, wire("work", @pro)), @pro_peak)
    end

    test "the same concrete model on a different account can have a different pricing period",
         %{config: config} do
      set_clock(~N[2024-01-01 12:00:00])
      assert_cost(select!(config, wire("backup", @pro)), @pro_off)
      assert_cost(select!(config, wire("work", @pro)), @pro_peak)
    end

    test "the full selection's account takes precedence over a stale legacy model_id",
         %{config: config} do
      set_clock(~N[2024-01-01 12:00:00])
      selection = select!(config, wire("work", @pro))
      selection = %{selection | model_id: "backup"}
      assert_cost(selection, @pro_peak)
    end

    test "off_peak_days on the account suppress peak rates for every selected model",
         %{config: config} do
      set_clock(~N[2024-01-01 12:00:00])
      config = update_work(config, &Map.put(&1, :off_peak_days, ["mon"]))
      install!(config)
      assert_cost(select!(config, wire("work", @flash)), @flash_off)
      assert_cost(select!(config, wire("work", @pro)), @pro_off)
      assert Cost.period_for_provider_profile_id("work") == "off_peak"
    end

    for {label, time, expected} <- [
          {"before start", ~N[2024-01-01 08:59:59], @pro_off},
          {"inclusive start", ~N[2024-01-01 09:00:00], @pro_peak},
          {"exclusive end", ~N[2024-01-01 17:00:00], @pro_off}
        ] do
      test "selected-model cost respects the account's half-open window: #{label}",
           %{config: config} do
        set_clock(unquote(Macro.escape(time)))
        assert_cost(select!(config, wire("work", @pro)), unquote(Macro.escape(expected)))
      end
    end
  end

  describe "usage override and degradation retain token accounting" do
    test "only cost fields change; token counts come from the real response usage",
         %{config: config} do
      id = register!(select!(config, wire("work", @pro)))
      reported = reported_usage()
      adjusted = Cost.apply_to_usage(reported, @raw, id)
      assert Map.take(adjusted, @cost_fields) == @pro_off
      assert Map.drop(adjusted, @cost_fields) == Map.drop(reported, @cost_fields)
      assert Usage.add(Usage.zero(), adjusted) == adjusted
    end

    test "mixed models on one account accumulate their effective prices rather than the default price",
         %{config: config} do
      flash_id = register!(select!(config, wire("work", @flash)))
      pro_id = register!(select!(config, wire("work", @pro, "high")))
      reported = reported_usage()

      flash = Cost.apply_to_usage(reported, @raw, flash_id)
      pro = Cost.apply_to_usage(reported, @raw, pro_id)
      total = Usage.add(flash, pro)

      assert Map.take(flash, @cost_fields) == @flash_off
      assert Map.take(pro, @cost_fields) == @pro_off

      assert Map.take(total, @cost_fields) ==
               %{input_cost: 0.653, output_cost: 2.58, total_cost: 3.233}

      assert total.input_tokens == 2_000_000
      assert total.output_tokens == 2_000_000
      assert total.cached_tokens == 400_000
      assert total.total_tokens == 4_000_000
    end

    test "reasoning tokens are already in output, irrespective of selected effort",
         %{config: config} do
      id = register!(select!(config, wire("work", @pro, "high")))
      assert Cost.recompute_for_agent(Map.put(@raw, :reasoning_tokens, 0), id) == @pro_off
      assert Cost.recompute_for_agent(Map.put(@raw, :reasoning_tokens, 999_999), id) == @pro_off
    end

    test "cache-hit usage is billed at the selected model's cache rate", %{config: config} do
      id = register!(select!(config, wire("work", @pro)))
      assert Cost.recompute_for_agent(@raw, id) == @pro_off

      assert Cost.recompute_for_agent(Map.put(@raw, :cached_tokens, 0), id) ==
               %{input_cost: 0.66, output_cost: 1.98, total_cost: 2.64}
    end

    test "empty and string-keyed usage still use the selected model", %{config: config} do
      id = register!(select!(config, wire("work", @pro)))

      assert Cost.recompute_for_agent(%{}, id) ==
               %{input_cost: 0.0, output_cost: 0.0, total_cost: 0.0}

      string_usage = Map.new(@raw, fn {key, value} -> {Atom.to_string(key), value} end)
      assert Cost.recompute_for_agent(string_usage, id) == @pro_off
    end

    test "missing usage and a recycled agent keep reported costs byte-identical",
         %{config: config} do
      id = register!(select!(config, wire("work", @pro)))
      reported = reported_usage()
      assert Cost.recompute_for_agent(nil, id) == nil
      assert Cost.apply_to_usage(reported, nil, id) == reported
      SchedulerStore.delete_agent_state(id)
      assert Cost.recompute_for_agent(@raw, id) == nil
      assert Cost.apply_to_usage(reported, @raw, id) == reported
    end
  end

  defp config do
    %{
      llm: %{
        default_provider_profile: "work",
        # Canonical providers must win over stale pre-redesign configuration.
        models: [%{id: "work", model: "deepseek:" <> @pro}],
        providers: [
          %{
            id: "backup",
            provider: "deepseek",
            models: [@pro, @flash],
            default_model: @pro,
            concurrency: 2,
            temperature: 0.8,
            max_tokens: 1_024,
            peak_hours: [%{start: "18:00", end: "20:00"}],
            peak_concurrency: 1
          },
          %{
            id: "work",
            provider: "deepseek",
            base_url: @endpoint,
            default_model: @flash,
            concurrency: 7,
            peak_concurrency: 0,
            peak_hours: [%{start: "09:00", end: "17:00"}],
            temperature: 0.2,
            max_tokens: 2_048,
            top_p: 0.9,
            context_window: 160_000,
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "high",
            models: [
              %{
                model: @pro,
                temperature: 0.6,
                max_tokens: 4_096,
                context_window: 256_000,
                reasoning_efforts: ["low", "high"],
                default_reasoning_effort: "low"
              },
              @flash
            ]
          }
        ]
      }
    }
  end

  defp snapshot(config), do: struct!(State, ModelSelection.config_opts(config))

  defp install!(config) do
    assert :ok = AgentScheduler.update_config(ModelSelection.config_opts(config))
  end

  defp resolve!(config, requested) do
    assert {:ok, resolved} = Schema.resolve_model_spec(config, requested)
    resolved
  end

  defp select!(config, requested) do
    assert {:ok, selection} = ModelSelection.resolve(snapshot(config), requested)
    selection
  end

  defp wire(account, model), do: %{"provider_profile_id" => account, "model" => model}

  defp wire(account, model, effort),
    do: Map.put(wire(account, model), "reasoning_effort", effort)

  defp endpoint_model(model), do: %{provider: :deepseek, id: model, base_url: @endpoint}

  defp update_work(config, fun) do
    update_in(config, [:llm, :providers], fn accounts ->
      Enum.map(accounts, fn
        %{id: "work"} = account -> fun.(account)
        account -> account
      end)
    end)
  end

  defp register!(selection) do
    id = 90_000_000 + System.unique_integer([:positive])

    state =
      struct!(
        AgentState,
        Map.merge(selection, %{
          context_node: %ContextNode{path: "./", repo: "provider-cost-test"},
          max_retries: 1,
          max_depth: 2
        })
      )

    SchedulerStore.put_agent_state(id, state)
    on_exit(fn -> SchedulerStore.delete_agent_state(id) end)
    id
  end

  defp assert_cost(selection, expected) do
    actual = Cost.recompute_for_agent(@raw, register!(selection))
    assert actual == expected
    assert actual.total_cost == Float.round(actual.input_cost + actual.output_cost, 6)
  end

  defp child_spec(selection) do
    AgentSpec.new(
      %ContextNode{path: "./", repo: "provider-cost-test"},
      nil,
      EvoGit.Agents.Executor,
      "Retain selected model pricing",
      model_id: "backup",
      model_spec: selection
    )
  end

  defp reported_usage do
    @raw
    |> Map.merge(%{input_cost: 91.0, output_cost: 92.0, total_cost: 183.0})
    |> Usage.from_response_usage()
  end

  defp set_clock(time),
    do: Application.put_env(:evo_git, :peak_hours_now_fun, fn -> time end)
end
