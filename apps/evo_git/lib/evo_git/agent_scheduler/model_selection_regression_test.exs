defmodule EvoGit.AgentScheduler.ModelSelectionRegressionTest do
  # Leaf-local regression coverage: run explicitly alongside the scheduler suite.
  # ConfigDir and path-keyed script caches isolate all configuration per process.
  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.{AgentState, Dispatch, ModelSelection, State, Store}
  alias EvoGit.{AgentSpec, CustomAgents}
  alias EvoGit.Config.Schema
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("scheduler-selection-regression")
    :ok
  end

  defp config do
    %{
      llm: %{
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

  defp spec(opts \\ []) do
    %AgentSpec{
      context_node: nil,
      phylo_node: nil,
      agent_module: EvoGit.Agents.Executor,
      objective: "selection regression",
      opts: opts
    }
  end

  defp script(code) do
    assert :ok = CustomAgents.save_model_selection_script(code)
  end

  defp resolve(state, spec \\ spec()) do
    Dispatch.resolve_selection(state, spec, nil, 0, "selection-regression")
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
    parent_id = :erlang.unique_integer([:positive])
    inherited = %{"provider_profile_id" => "account", "model" => "gpt-4o"}

    Store.put_agent_state(parent_id, %AgentState{
      context_node: nil,
      llm_model: "openai:gpt-4o",
      max_retries: 1,
      max_depth: 1,
      model_id: nil,
      model_id_locked: true,
      model_spec: inherited
    })

    on_exit(fn -> Store.delete_agent_state(parent_id) end)
    child = spec(model_spec: %{"provider_profile_id" => "missing", "model" => "missing"})
    child = Dispatch.inherit_model_selection(child, parent_id)
    assert child.opts[:model_id_locked]
    assert {:ok, selection} = resolve(State.from_config(config()), child)
    assert selection.model_spec == inherited
  end
end
