defmodule EvoGit.CustomAgents.ModelSelectorSelectionTest do
  use ExUnit.Case, async: true

  alias EvoGit.CustomAgents
  alias EvoGit.CustomAgents.ModelSelector
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("model-selector-selection")
    :ok
  end

  test "canonical maps normalize atom, string and mixed keys and effort values" do
    for selection <- [
          %{provider_profile_id: "account", model: "reasoner", reasoning_effort: :high},
          %{
            "provider_profile_id" => "account",
            "model" => "reasoner",
            "reasoning_effort" => "high"
          },
          %{"model" => "reasoner", provider_profile_id: "account", reasoning_effort: :high}
        ] do
      assert evaluate(selection) ==
               {:ok,
                %{provider_profile_id: "account", model: "reasoner", reasoning_effort: "high"}}
    end
  end

  test "absent and nil effort use schema defaults, and unrelated fields are dropped" do
    expected = {:ok, %{provider_profile_id: "account", model: "fast"}}

    assert evaluate(%{provider_profile_id: "account", model: "fast"}) == expected

    assert evaluate(%{
             "provider_profile_id" => "account",
             "model" => "fast",
             "reasoning_effort" => nil,
             "extra" => "ignored"
           }) == expected
  end

  test "atom keys take precedence over duplicate string keys" do
    assert evaluate(%{
             "provider_profile_id" => "ignored",
             "model" => "ignored",
             "reasoning_effort" => "low",
             provider_profile_id: "account",
             model: "reasoner",
             reasoning_effort: :high
           }) ==
             {:ok, %{provider_profile_id: "account", model: "reasoner", reasoning_effort: "high"}}
  end

  test "normalized selections feed the schema and leave effort support validation to it" do
    config = %{
      llm: %{
        providers: [
          %{
            id: "account",
            provider: "openai",
            context_window: 4096,
            models: ["reasoner"],
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "low"
          }
        ]
      }
    }

    assert {:ok, selection} =
             evaluate(%{provider_profile_id: "account", model: "reasoner"})

    assert {:ok, %{model: "openai:reasoner", reasoning_effort: "low"}} =
             EvoGit.Config.Schema.ProviderProfiles.resolve_runtime_profile(config, selection)

    assert {:ok, selection} = evaluate(Map.put(selection, :reasoning_effort, :unsupported))

    assert {:error, {:unsupported_reasoning_effort, "unsupported", ["low", "high"]}} =
             EvoGit.Config.Schema.ProviderProfiles.resolve_runtime_profile(config, selection)
  end

  test "malformed selections and other result types retain invalid_result errors" do
    for selection <- [
          %{},
          %{model: "fast"},
          %{provider_profile_id: "account"},
          %{provider_profile_id: "", model: "fast"},
          %{provider_profile_id: "account", model: ""},
          %{provider_profile_id: :account, model: "fast"},
          %{provider_profile_id: "account", model: 42},
          %{provider_profile_id: "account", model: "fast", reasoning_effort: ""},
          %{provider_profile_id: "account", model: "fast", reasoning_effort: 42},
          %{provider_profile_id: "account", model: "fast", reasoning_effort: %{}},
          %URI{scheme: "https"},
          [],
          42
        ] do
      assert evaluate(selection) == {:error, {:invalid_result, inspect(selection)}}
    end
  end

  test "legacy ids and default results remain unchanged" do
    assert evaluate("legacy-id") == {:ok, "legacy-id"}
    for value <- [nil, "", false], do: assert(evaluate(value) == {:ok, nil})
    assert :ok = CustomAgents.save_model_selection_script("")
    assert ModelSelector.select_model(%{}) == {:ok, nil}
  end

  test "ordinary compile and runtime exceptions retain their error contracts" do
    assert :ok = CustomAgents.save_model_selection_script("raise \"script failed\"")
    assert {:error, {:script_raised, message}} = ModelSelector.select_model(%{})
    assert message =~ "script failed"

    assert :ok = CustomAgents.save_model_selection_script("if (")
    assert {:error, {:compile_error, _}} = ModelSelector.select_model(%{})
  end

  defp evaluate(value) do
    assert :ok = CustomAgents.save_model_selection_script(inspect(value))
    # Multiple scripts in one test can have identical size and stat timestamps.
    ModelSelector.invalidate()
    ModelSelector.select_model(%{})
  end
end
