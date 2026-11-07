defmodule EvoGit.AgentScheduler.ModelSelectionRegressionTest do
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.{AgentState, Dispatch, ModelSelection, State, Store}
  alias EvoGit.{AgentSpec, CustomAgents}
  alias EvoGit.Config.Schema
  alias EvoGit.TestSupport.ConfigDir

  # Recovered from d14b4ee5e's source-local test and extended at the permanent
  # test entry point. ConfigDir/script caches and all ETS ids are test-owned.
  setup do
    ConfigDir.isolate!("scheduler-selection-regression")
    :ok
  end

  defmodule BindingObserver do
    def run(objective, ctx) do
      {:ok, binding} = Store.get_agent_state(ctx[:agent_id])
      send(ctx[:spec].opts[:observer], {:dispatched_binding, objective, binding, ctx[:spec]})
      {:ok, :observed}
    end
  end

  defp config do
    %{
      llm: %{
        default_provider_profile: "account",
        providers: [
          %{
            id: "account",
            provider: "openai",
            default_model: "gpt-4o",
            concurrency: 5,
            models: [
              %{model: "gpt-4o", context_window: 120_000},
              %{
                model: "gpt-4o-mini",
                context_window: 64_000,
                reasoning_efforts: ["low", "high"]
              }
            ]
          }
        ]
      }
    }
  end

  defp two_accounts do
    first = hd(config().llm.providers)

    second = %{
      first
      | id: "other-account",
        default_model: "gpt-4o-mini",
        concurrency: 2
    }

    second =
      Map.merge(second, %{
        auth_mode: "api_key",
        temperature: 0.4,
        max_tokens: 1000,
        default_reasoning_effort: "low",
        reasoning_efforts: ["low", "high"],
        models: [
          %{model: "gpt-4o", context_window: 110_000},
          %{
            model: "gpt-4o-mini",
            context_window: 48_000,
            temperature: 0.2,
            default_reasoning_effort: "high"
          }
        ]
      })

    %{llm: %{default_provider_profile: "other-account", providers: [first, second]}}
  end

  defp spec(opts \\ []) do
    %AgentSpec{
      context_node: nil,
      phylo_node: EvoGit.Core.PhyloGraphNode.new(File.cwd!()),
      agent_module: EvoGit.Agents.Executor,
      objective: "selection regression",
      opts: opts
    }
  end

  defp script(code), do: assert(:ok = CustomAgents.save_model_selection_script(code))

  defp resolve(state, spec \\ spec()) do
    Dispatch.resolve_selection(state, spec, nil, 0, "selection-regression")
  end

  defp fresh_state(config) do
    %{
      State.from_config(config)
      | next_agent_id: 1_000_000_000 + System.unique_integer([:positive, :monotonic]) * 100
    }
  end

  defp register(state, spec, parent_id \\ nil, depth \\ 0) do
    id = state.next_agent_id

    on_exit(fn ->
      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
    end)

    assert {^id, next} =
             Dispatch.register_agent(
               state,
               spec,
               nil,
               parent_id,
               depth,
               "selection-regression",
               1
             )

    assert {:ok, binding} = Store.get_agent_state(id)
    {id, next, binding}
  end

  # The schema's model_spec is a ReqLLM identifier, not the task selection map.
  # Generation params deliberately retain the schema's full credential contract.
  defp assert_binding(binding, config, requested) do
    assert {:ok, resolved} = Schema.resolve_model_spec(config, requested)

    expected = %{
      "provider_profile_id" => resolved.provider_profile_id,
      "model" => resolved.model
    }

    expected =
      if resolved.reasoning_effort,
        do: Map.put(expected, "reasoning_effort", resolved.reasoning_effort),
        else: expected

    assert binding.provider_profile_id == resolved.provider_profile_id
    assert binding.model_spec == expected
    assert binding.llm_model == resolved.model_spec
    assert binding.llm_generation_params == resolved.generation_params
    assert binding.llm_context_window == Schema.LLM.context_window(resolved.runtime_profile)
  end

  test "legacy populated, flat and empty configurations retain effective runtime profiles" do
    for config <- [
          %{},
          %{scheduler: %{default_llm_max_concurrency: 2}},
          %{llm: %{model: "openai:gpt-4o"}},
          %{llm: %{providers: [], models: []}},
          %{llm: %{models: [%{id: "fast", model: "openai:gpt-4o-mini", concurrency: 7}]}},
          %{"llm" => %{"model" => "openai:gpt-4o"}}
        ] do
      assert ModelSelection.config_opts(config)[:model_profiles] ==
               Schema.effective_model_profiles(config)
    end

    for config <- [%{}, %{llm: %{models: []}}] do
      state = State.from_config(config)
      assert state.llm_model == nil
      assert [%{id: "default", model: nil}] = state.model_profiles
      assert state.model_selection_config == nil
    end
  end

  test "empty legacy reload clears the previous account snapshot after nil filtering" do
    state = State.from_config(config())
    opts = EvoGit.AgentScheduler.RemoteAPI.build_reload_opts(%{})
    opts = ModelSelection.update_opts(state, opts)
    reloaded = State.from_model_profiles(opts[:model_profiles], opts)
    assert reloaded.model_selection_config == nil
    assert reloaded.provider_profiles == []
    assert reloaded.llm_model == nil
    assert reloaded.model_profiles == Schema.effective_model_profiles(%{})
  end

  test "canonical inventories retain multiple selections but one shared account pool" do
    opts = ModelSelection.config_opts(config())
    assert opts[:model_profiles] == Schema.model_selections(config())
    assert length(opts[:model_profiles]) == 2
    assert opts[:provider_profiles] == Schema.provider_profiles(config())
    assert opts[:model_selection_config] == config()
    state = State.from_config(config())
    assert state.model_concurrency == %{"account" => 5}
    assert Map.keys(state.llm_holders) == ["account"]
  end

  test "atom-keyed script selections resolve model, reasoning and context through the schema" do
    script("%{provider_profile_id: \"account\", model: \"gpt-4o-mini\", reasoning_effort: :high}")
    assert {:ok, selection} = resolve(State.from_config(config()))
    assert selection.model_id == nil
    assert selection.provider_profile_id == "account"
    assert selection.llm_model == "openai:gpt-4o-mini"
    assert selection.llm_context_window == 64_000

    assert selection.model_spec == %{
             "provider_profile_id" => "account",
             "model" => "gpt-4o-mini",
             "reasoning_effort" => "high"
           }

    assert_binding(selection, config(), selection.model_spec)
  end

  test "script maps also resolve against migrated legacy accounts" do
    script("%{provider_profile_id: \"fast\", model: \"gpt-4o-mini\"}")
    legacy = %{llm: %{models: [%{id: "fast", model: "openai:gpt-4o-mini"}]}}
    assert {:ok, selection} = resolve(State.from_config(legacy))
    assert selection.llm_model == "openai:gpt-4o-mini"
    assert selection.provider_profile_id == "fast"
  end

  test "map selections never enter legacy id fallback without a schema snapshot" do
    script("%{provider_profile_id: \"account\", model: \"gpt-4o-mini\"}")
    state = State.from_model_profiles([%{id: "fallback", model: "openai:gpt-4o"}])
    assert resolve(state) == {:error, :model_spec_schema_unavailable}
  end

  test "invalid script maps return schema errors rather than silently using default" do
    state = State.from_config(config())

    for {code, error} <- [
          {"%{provider_profile_id: \"missing\", model: \"gpt-4o\"}",
           {:provider_profile_not_found, "missing"}},
          {"%{provider_profile_id: \"account\", model: \"missing\"}",
           {:model_not_found, "account", "missing"}},
          {"%{provider_profile_id: \"account\", model: \"gpt-4o-mini\", reasoning_effort: :medium}",
           {:unsupported_reasoning_effort, "medium", ["low", "high"]}}
        ] do
      script(code)
      assert resolve(state) == {:error, error}
    end
  end

  test "explicit selection and user lock bypass script maps" do
    script("%{provider_profile_id: \"missing\", model: \"missing\"}")
    state = State.from_config(config())
    explicit = %{"provider_profile_id" => "account", "model" => "gpt-4o-mini"}
    assert {:ok, selection} = resolve(state, spec(model_spec: explicit))
    assert selection.model_spec == explicit
    locked = %{spec(model_id_locked: true) | model_id: "account"}
    assert {:ok, selection} = resolve(state, locked)
    assert selection.llm_model == "openai:gpt-4o"
  end

  test "locked parent selection overrides a child's explicit selection before script dispatch" do
    script("%{provider_profile_id: \"missing\", model: \"missing\"}")
    inherited = %{"provider_profile_id" => "account", "model" => "gpt-4o"}
    state = fresh_state(config())
    {parent_id, state, _} = register(state, spec(model_spec: inherited, model_id_locked: true))
    child = spec(model_spec: %{"provider_profile_id" => "missing", "model" => "missing"})
    child = Dispatch.inherit_model_selection(child, parent_id)
    assert child.opts[:model_id_locked]
    assert {:ok, selection} = resolve(state, child)
    assert selection.model_spec == inherited
  end

  test "configured provider, model and effort defaults win over inventory order" do
    config = two_accounts()
    state = State.from_config(config)
    assert State.default_pool_id(state) == "other-account"
    assert State.default_model_id(state) == "other-account"
    assert state.llm_model == "openai:gpt-4o-mini"
    assert {:ok, selection} = resolve(state)
    assert selection.model_id == "other-account"
    assert selection.model_spec["reasoning_effort"] == "high"
    assert selection.llm_context_window == 48_000
    assert selection.llm_generation_params[:temperature] == 0.2
    assert selection.llm_generation_params[:max_tokens] == 1000
    assert_binding(selection, config, nil)
  end

  test "explicit struct field wins over compatibility opts and legacy id" do
    config = two_accounts()

    explicit = %{
      "provider_profile_id" => "account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "low"
    }

    request = %{
      spec(model_spec: %{"provider_profile_id" => "missing", "model" => "missing"})
      | model_spec: explicit,
        model_id: "other-account"
    }

    assert {:ok, selection} = resolve(State.from_config(config), request)
    assert selection.model_id == nil
    assert_binding(selection, config, explicit)
  end

  test "definition selection is a fallback below script and above legacy id" do
    config = two_accounts()

    fallback = %{
      "provider_profile_id" => "account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "low"
    }

    request = %{spec(default_model_spec: fallback) | model_id: "other-account"}
    state = State.from_config(config)
    assert {:ok, selection} = resolve(state, request)
    assert_binding(selection, config, fallback)

    script(
      "%{provider_profile_id: \"other-account\", model: \"gpt-4o\", reasoning_effort: :high}"
    )

    assert {:ok, scripted} = resolve(state, request)

    assert_binding(scripted, config, %{
      "provider_profile_id" => "other-account",
      "model" => "gpt-4o",
      "reasoning_effort" => "high"
    })
  end

  test "invalid explicit selections never fall back or register ETS state" do
    state = fresh_state(config())
    id = state.next_agent_id

    on_exit(fn ->
      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
    end)

    for invalid <- [
          nil,
          %{},
          %{"provider_profile_id" => "account"},
          %{"provider_profile_id" => "", "model" => "gpt-4o"},
          %{provider_profile_id: "account", model: "gpt-4o"}
        ] do
      assert Dispatch.register_agent(state, spec(model_spec: invalid), nil, nil, 0, "invalid", 1) ==
               {:error, :invalid_model_spec}

      assert Store.get_agent_state(id) == :error
      assert Store.get_sched_meta(id) == :error
    end
  end

  test "schema errors at registration reject account, model and effort without writing ETS" do
    state = fresh_state(config())
    id = state.next_agent_id

    on_exit(fn ->
      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
    end)

    for {selection, reason} <- [
          {%{"provider_profile_id" => "missing", "model" => "gpt-4o"},
           {:provider_profile_not_found, "missing"}},
          {%{"provider_profile_id" => "account", "model" => "missing"},
           {:model_not_found, "account", "missing"}},
          {%{
             "provider_profile_id" => "account",
             "model" => "gpt-4o-mini",
             "reasoning_effort" => "medium"
           }, {:unsupported_reasoning_effort, "medium", ["low", "high"]}}
        ] do
      assert Dispatch.register_agent(
               state,
               spec(model_spec: selection),
               nil,
               nil,
               0,
               "invalid",
               1
             ) == {:error, reason}

      assert Store.get_agent_state(id) == :error
      assert Store.get_sched_meta(id) == :error
    end
  end

  test "invalid definition selections also fail closed" do
    state = State.from_config(config())

    for invalid <- [nil, %{}, "account"] do
      assert resolve(state, spec(default_model_spec: invalid)) == {:error, :invalid_model_spec}
    end
  end

  test "full locked selection survives two generations and every conflicting child input" do
    config = two_accounts()

    inherited = %{
      "provider_profile_id" => "other-account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "low"
    }

    script("%{provider_profile_id: \"missing\", model: \"missing\"}")
    state = fresh_state(config)

    {root, state, root_binding} =
      register(state, spec(model_spec: inherited, model_id_locked: true))

    assert root_binding.model_id == nil
    assert root_binding.model_id_locked

    conflict = %{"provider_profile_id" => "account", "model" => "gpt-4o"}

    child = %{
      spec(model_spec: conflict, default_model_spec: conflict, model_id_locked: false)
      | model_spec: conflict,
        model_id: "account"
    }

    {child_id, state, child_binding} = register(state, child, root, 1)
    {grandchild_id, _state, grandchild_binding} = register(state, child, child_id, 2)

    for {id, binding} <- [{child_id, child_binding}, {grandchild_id, grandchild_binding}] do
      assert binding.model_id == nil
      assert binding.model_id_locked
      assert_binding(binding, config, inherited)
      assert {:ok, meta} = Store.get_sched_meta(id)
      assert meta.spec.model_id == nil
      assert meta.spec.model_spec == inherited
      assert meta.spec.opts[:model_spec] == inherited
      assert meta.spec.opts[:model_id_locked]
    end
  end

  test "unlocked parent does not capture child's script or explicit selection" do
    config = two_accounts()
    state = fresh_state(config)
    parent_choice = %{"provider_profile_id" => "account", "model" => "gpt-4o"}
    {parent, state, binding} = register(state, spec(model_spec: parent_choice))
    refute binding.model_id_locked

    script(
      "%{provider_profile_id: \"other-account\", model: \"gpt-4o-mini\", reasoning_effort: :low}"
    )

    {_, state, scripted} = register(state, spec(), parent, 1)
    assert scripted.provider_profile_id == "other-account"
    assert scripted.model_spec["reasoning_effort"] == "low"
    {_, _, explicit} = register(state, %{spec() | model_spec: parent_choice}, parent, 1)
    assert_binding(explicit, config, parent_choice)
    refute explicit.model_id_locked
  end

  test "missing parent leaves requested selection and lock unchanged" do
    child = spec(model_spec: %{"provider_profile_id" => "account", "model" => "gpt-4o-mini"})
    missing = 1_000_000_000 + System.unique_integer([:positive, :monotonic]) * 100
    assert Dispatch.inherit_model_selection(child, missing) == child
  end

  test "legacy locked parent still overrides a child's conflicting legacy id and script" do
    script("%{provider_profile_id: \"missing\", model: \"missing\"}")
    parent_id = 1_000_000_000 + System.unique_integer([:positive, :monotonic]) * 100

    Store.put_agent_state(parent_id, %AgentState{
      context_node: nil,
      llm_model: "openai:gpt-4o",
      max_retries: 1,
      max_depth: 2,
      model_id: "account",
      model_id_locked: true
    })

    on_exit(fn -> Store.delete_agent_state(parent_id) end)
    child = %{spec() | model_id: "other-account"}
    inherited = Dispatch.inherit_model_selection(child, parent_id)
    assert inherited.model_id == "account"
    assert inherited.opts[:model_id_locked]
    assert {:ok, selection} = resolve(State.from_config(two_accounts()), inherited)
    assert_binding(selection, two_accounts(), "account")
  end

  test "legacy lock overrides a child's canonical selection as well as its legacy id" do
    parent_id = 1_000_000_000 + System.unique_integer([:positive, :monotonic]) * 100

    Store.put_agent_state(parent_id, %AgentState{
      context_node: nil,
      llm_model: "openai:gpt-4o",
      max_retries: 1,
      max_depth: 2,
      model_id: "account",
      model_id_locked: true
    })

    on_exit(fn -> Store.delete_agent_state(parent_id) end)

    other = %{
      "provider_profile_id" => "other-account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "high"
    }

    child = %{spec(model_spec: other) | model_spec: other, model_id: "other-account"}
    inherited = Dispatch.inherit_model_selection(child, parent_id)
    assert {:ok, selection} = resolve(State.from_config(two_accounts()), inherited)
    assert_binding(selection, two_accounts(), "account")
  end

  test "endpoint ReqLLM identifier stays separate from the canonical task selection" do
    config = config()
    provider = config.llm.providers |> hd() |> Map.put(:base_url, "https://example.invalid/v1")
    config = put_in(config, [:llm, :providers], [provider])

    choice = %{
      "provider_profile_id" => "account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "high"
    }

    {_, _, binding} = register(fresh_state(config), spec(model_spec: choice))
    assert binding.model_spec == choice

    assert binding.llm_model == %{
             provider: :openai,
             id: "gpt-4o-mini",
             base_url: "https://example.invalid/v1"
           }

    assert_binding(binding, config, choice)
  end

  test "script and definition fallbacks are resolved before writing effective dispatch state" do
    config = two_accounts()
    state = fresh_state(config)

    fallback = %{
      "provider_profile_id" => "account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "low"
    }

    request = %{spec(default_model_spec: fallback) | model_id: "other-account"}
    {_, state, default_binding} = register(state, request)
    assert_binding(default_binding, config, fallback)

    script(
      "%{provider_profile_id: \"other-account\", model: \"gpt-4o\", reasoning_effort: :high}"
    )

    {_, _, scripted} = register(state, request)

    assert_binding(scripted, config, %{
      "provider_profile_id" => "other-account",
      "model" => "gpt-4o",
      "reasoning_effort" => "high"
    })
  end

  test "an unknown legacy id falls back to the configured account default, not first inventory" do
    script("\"unknown-legacy-id\"")
    assert {:ok, selected} = resolve(State.from_config(two_accounts()))
    assert_binding(selected, two_accounts(), nil)
    assert selected.provider_profile_id == "other-account"
    assert selected.model_spec["model"] == "gpt-4o-mini"
  end

  test "dispatch task observes the effective binding, not the unresolved child request" do
    config = two_accounts()
    state = fresh_state(config)

    chosen = %{
      "provider_profile_id" => "other-account",
      "model" => "gpt-4o-mini",
      "reasoning_effort" => "low"
    }

    {root, state, _} = register(state, spec(model_spec: chosen, model_id_locked: true))
    request = %{spec(observer: self()) | agent_module: BindingObserver, model_id: "account"}
    {child, state, binding} = register(state, request, root, 1)
    dispatched = Dispatch.try_dispatch(state, child)
    assert {:ok, meta} = Store.get_sched_meta(child)
    task = meta.task_ref
    assert Map.fetch!(dispatched.ref_to_agent, task.ref) == child
    assert meta.status == :running
    assert_receive {:dispatched_binding, "selection regression", observed, effective_spec}, 5000
    assert observed == binding
    assert_binding(observed, config, chosen)
    assert effective_spec.model_spec == chosen
    assert effective_spec.opts[:model_id_locked]
    assert Task.await(task, 5000) == {:ok, :observed}
  end
end
