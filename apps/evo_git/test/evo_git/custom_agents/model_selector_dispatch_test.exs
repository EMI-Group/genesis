defmodule EvoGit.CustomAgents.ModelSelectorDispatchTest do
  # Pure dispatch resolution over a local State plus per-process agents.toml:
  # never start/register agents or mutate the app-global scheduler or OS env.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.AgentScheduler.{Dispatch, State}
  alias EvoGit.AgentSpec
  alias EvoGit.Config.Schema.ProviderProfiles
  alias EvoGit.CustomAgents
  alias EvoGit.CustomAgents.ModelSelector
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("model-selector-dispatch")

    assert {:ok, %{id: "reviewer"}} =
             CustomAgents.save(%{name: "Reviewer", prompt: "Review carefully"})

    config = config()
    {:ok, config: config, state: %State{model_selection_config: config}}
  end

  test "no script honors configured account and model defaults, not enumeration order", ctx do
    assert {:ok, resolved} = ProviderProfiles.resolve_model_spec(ctx.config, nil)
    assert resolved.provider_profile_id == "account"
    assert resolved.model == "reasoner"
    assert resolved.model_spec == "openai:reasoner"
    assert resolved.reasoning_effort == "medium"

    assert {:ok, selected} = resolve(ctx.state)
    assert_selected(selected, "account", "reasoner", "medium")
    assert selected.model_id == "account"
    assert selected.llm_context_window == 16_384
  end

  test "script gets custom-agent spawn attributes and overrides definition and legacy defaults",
       ctx do
    write_script("""
    if agent.agent_type == :custom and agent.custom_agent_id == "reviewer" and
         agent.depth == 2 and agent.parent_id == 17 and agent.task_id == "selection-task" and
         agent.objective == "Review this change" do
      %{provider_profile_id: "account", model: "reasoner", reasoning_effort: :high}
    else
      raise "wrong spawn attributes"
    end
    """)

    spec = spec(model_id: "first-account", default_model_spec: wire("account", "fast"))
    assert {:ok, selected} = Dispatch.resolve_selection(ctx.state, spec, 17, 2, "selection-task")
    assert_selected(selected, "account", "reasoner", "high")
    assert selected.model_id == nil
  end

  test "nil, empty and false script results use definition selection before legacy ids", ctx do
    for result <- [nil, "", false] do
      write_script(inspect(result))

      assert {:ok, selected} =
               resolve(ctx.state,
                 model_id: "first-account",
                 default_model_spec: wire("account", "fast")
               )

      assert_selected(selected, "account", "fast", "low")
    end
  end

  test "custom definition legacy id is used only without a canonical definition fallback", ctx do
    assert {:ok, _} =
             CustomAgents.save(%{
               id: "reviewer",
               name: "Reviewer",
               prompt: "Review carefully",
               model_id: "first-account"
             })

    assert %{model_id: "first-account"} = CustomAgents.get("reviewer")
    assert {:ok, selected} = resolve(ctx.state)
    assert_selected(selected, "first-account", "fast", "low")

    assert {:ok, selected} =
             resolve(ctx.state, default_model_spec: wire("account", "reasoner", "high"))

    assert_selected(selected, "account", "reasoner", "high")
  end

  test "locked legacy id skips script execution and definition selection", ctx do
    write_script("""
    send(self(), :locked_selection_script_executed)
    %{provider_profile_id: "account", model: "reasoner", reasoning_effort: :high}
    """)

    assert {:ok, selected} =
             resolve(ctx.state,
               model_id: "first-account",
               model_id_locked: true,
               default_model_spec: wire("account", "reasoner", "high")
             )

    assert_selected(selected, "first-account", "fast", "low")
    refute_received :locked_selection_script_executed
  end

  test "explicit task selection wins over script, legacy id and definition defaults", ctx do
    write_script("""
    send(self(), :explicit_selection_script_executed)
    %{provider_profile_id: "first-account", model: "fast"}
    """)

    assert {:ok, selected} =
             resolve(ctx.state,
               model_spec: wire("account", "fast"),
               model_id: "first-account",
               default_model_spec: wire("account", "reasoner", "high")
             )

    assert_selected(selected, "account", "fast", "low")
    refute_received :explicit_selection_script_executed
  end

  test "script-selected models share account auth and schedule but have generation overrides",
       ctx do
    selected =
      for model <- ["fast", "reasoner"] do
        write_script(inspect(%{provider_profile_id: "account", model: model}))
        assert {:ok, selected} = resolve(ctx.state)

        assert {:ok, resolved} =
                 ProviderProfiles.resolve_model_spec(ctx.config, selected.model_spec)

        assert resolved.concurrency == 7
        assert resolved.peak_concurrency == 0
        assert resolved.runtime_profile.auth_mode == "api_key"
        assert resolved.runtime_profile.api_key_env_var == "PATH"
        assert selected.provider_profile_id == "account"
        assert selected.llm_model == resolved.model_spec
        # Credentials are allowed in generation_params. PATH is a harmless
        # existing value used as fixture credential, with no global env mutation.
        assert selected.llm_generation_params[:api_key] == System.fetch_env!("PATH")
        selected
      end

    [fast, reasoner] = selected
    assert fast.llm_context_window == 8192
    assert reasoner.llm_context_window == 16_384
    assert fast.llm_generation_params[:temperature] == 0.6
    assert reasoner.llm_generation_params[:temperature] == 0.3
    assert fast.llm_generation_params[:max_tokens] == 2048
    assert reasoner.llm_generation_params[:max_tokens] == 1024
    assert fast.llm_generation_params[:reasoning_effort] == :low
    assert reasoner.llm_generation_params[:reasoning_effort] == :medium
  end

  test "endpoint ReqLLM identifier stays separate from the persisted selection map", ctx do
    [first, account] = ctx.config.llm.providers
    account = Map.put(account, :base_url, "https://models.example.invalid/v1")
    config = put_in(ctx.config, [:llm, :providers], [first, account])
    state = %{ctx.state | model_selection_config: config}
    write_script(inspect(wire("account", "reasoner", "high")))

    assert {:ok, selected} = resolve(state)
    assert {:ok, resolved} = ProviderProfiles.resolve_model_spec(config, selected.model_spec)

    assert resolved.model_spec == %{
             provider: :openai,
             id: "reasoner",
             base_url: "https://models.example.invalid/v1"
           }

    # Build selection from resolved fields, never reuse resolved.model_spec:
    # that field belongs to ReqLLM and may be a string OR an endpoint map.
    assert selected.model_spec == %{
             "provider_profile_id" => resolved.provider_profile_id,
             "model" => resolved.model,
             "reasoning_effort" => resolved.reasoning_effort
           }

    assert selected.llm_model == resolved.model_spec
    refute Map.has_key?(selected.model_spec, "base_url")
    refute Map.has_key?(selected.model_spec, "api_key")
  end

  test "schema-invalid script maps return precise errors instead of silently using defaults",
       ctx do
    for {selection, expected} <- [
          {wire("missing", "fast"), {:provider_profile_not_found, "missing"}},
          {wire("account", "missing"), {:model_not_found, "account", "missing"}},
          {wire("account", "reasoner", "low"),
           {:unsupported_reasoning_effort, "low", ["medium", "high"]}}
        ] do
      write_script(inspect(selection))
      assert resolve(ctx.state, default_model_spec: wire("account", "fast")) == {:error, expected}
    end
  end

  test "invalid script results and ordinary script failures fall back to definition selection",
       ctx do
    for script <- ["%{}", "42", ~s(raise "bad script"), "if ("] do
      write_script(script)

      assert capture_log(fn ->
               assert {:ok, selected} =
                        resolve(ctx.state, default_model_spec: wire("account", "fast"))

               assert_selected(selected, "account", "fast", "low")
             end) =~ "model selection script failed"
    end
  end

  test "unknown legacy script id keeps warn-and-default behavior, unlike invalid map", ctx do
    write_script(~s("missing-legacy-id"))

    assert capture_log(fn ->
             assert {:ok, selected} =
                      resolve(ctx.state, default_model_spec: wire("first-account", "fast"))

             assert_selected(selected, "account", "reasoner", "medium")
           end) =~ "legacy selection"
  end

  test "invalid definition or explicit selection never falls back to configured default", ctx do
    for selection <- [nil, %{}, wire("", "fast"), wire("account", ""), 42] do
      assert resolve(ctx.state, default_model_spec: selection) == {:error, :invalid_model_spec}
      # opts retains an explicit nil even though AgentSpec.model_spec is nil.
      assert resolve(ctx.state, model_spec: selection) == {:error, :invalid_model_spec}
    end

    missing = wire("missing", "fast")

    assert resolve(ctx.state, default_model_spec: missing) ==
             {:error, {:provider_profile_not_found, "missing"}}

    write_script(inspect(wire("account", "fast")))

    assert resolve(ctx.state, model_spec: missing) ==
             {:error, {:provider_profile_not_found, "missing"}}
  end

  defp config do
    %{
      llm: %{
        default_provider_profile: "account",
        providers: [
          %{
            id: "first-account",
            provider: "openai",
            auth_mode: "api_key",
            concurrency: 2,
            context_window: 4096,
            models: ["fast"],
            reasoning_efforts: ["low"],
            default_reasoning_effort: "low"
          },
          %{
            id: "account",
            provider: "openai",
            auth_mode: "api_key",
            api_key_env_var: "PATH",
            concurrency: 7,
            peak_concurrency: 0,
            default_model: "reasoner",
            context_window: 8192,
            temperature: 0.6,
            max_tokens: 2048,
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "low",
            models: [
              "fast",
              %{
                model: "reasoner",
                context_window: 16_384,
                temperature: 0.3,
                max_tokens: 1024,
                reasoning_efforts: ["medium", "high"],
                default_reasoning_effort: "medium"
              }
            ]
          }
        ]
      }
    }
  end

  defp spec(opts) do
    opts = Keyword.put_new(opts, :custom_agent_id, "reviewer")
    AgentSpec.new(nil, nil, EvoGit.Agents.Custom, "Review this change", opts)
  end

  defp resolve(state, opts \\ []) do
    Dispatch.resolve_selection(state, spec(opts), nil, 0, "selection-task")
  end

  defp wire(account, model, effort \\ nil) do
    selection = %{"provider_profile_id" => account, "model" => model}
    if effort, do: Map.put(selection, "reasoning_effort", effort), else: selection
  end

  defp assert_selected(selected, account, model, effort) do
    assert selected.provider_profile_id == account
    assert selected.model_spec == wire(account, model, effort)
    assert selected.llm_model == "openai:" <> model
    # ReqLLM parameters use atoms for known efforts; the persisted map uses strings.
    assert selected.llm_generation_params[:reasoning_effort] ==
             Map.fetch!(%{"low" => :low, "medium" => :medium, "high" => :high}, effort)
  end

  defp write_script(script) do
    assert :ok = CustomAgents.save_model_selection_script(script)
    ModelSelector.invalidate()
  end
end
