defmodule EvoGit.Config.LLMGenerationParamsTest do
  @moduledoc """
  Provider/model-aware LLM generation parameters.

  `async: false` is REQUIRED: the metadata-lookup seam is a BEAM-global
  application env key (`:llm_model_metadata_fun`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Config.Schema.LLM
  alias EvoGit.Config.Schema.LLMConstraints

  @seam :llm_model_metadata_fun

  setup do
    on_exit(fn -> Application.delete_env(:evo_git, @seam) end)
    :ok
  end

  defp stub_metadata(metadata) do
    Application.put_env(:evo_git, @seam, fn _model -> metadata end)
  end

  describe "provider_options_for_model/1 — native OpenAI only" do
    test "string spec for a native OpenAI endpoint keeps store: false" do
      assert LLM.provider_options_for_model("openai:gpt-5") == [store: false]
    end

    test "map spec for a native OpenAI endpoint keeps store: false" do
      assert LLM.provider_options_for_model(%{provider: :openai, id: "gpt-5"}) == [store: false]
    end

    test "tuple spec for a native OpenAI endpoint keeps store: false" do
      assert LLM.provider_options_for_model({:openai, [id: "gpt-5"]}) == [store: false]
    end

    test "an OpenAI-compatible endpoint with a custom base_url does NOT get store: false" do
      assert LLM.provider_options_for_model(%{
               provider: :openai,
               id: "z-ai/glm-5.3-flash",
               base_url: "https://openrouter.ai/api/v1"
             }) == []
    end

    test "an endpoint with extra does NOT get store: false (presence check)" do
      assert LLM.provider_options_for_model(%{provider: :openai, id: "gpt-5", extra: %{}}) == []
    end

    test "non-OpenAI providers get no default provider options" do
      assert LLM.provider_options_for_model("anthropic:claude-sonnet-4") == []
      assert LLM.provider_options_for_model("zai:glm-5.3-flash") == []
      assert LLM.provider_options_for_model({:anthropic, [id: "claude"]}) == []
      assert LLM.provider_options_for_model(nil) == []
      assert LLM.provider_options_for_model(%{}) == []
    end

    test "default_provider_options/0 is the OpenAI default itself" do
      assert LLM.default_provider_options() == [store: false]
    end
  end

  describe "profile_generation_params/1 — store fix and provider_options precedence" do
    test "a native OpenAI profile gets store: false" do
      assert LLM.profile_generation_params(%{model: "openai:gpt-5"}) ==
               [provider_options: [store: false]]
    end

    test "an OpenAI-compatible profile gets no provider_options key" do
      profile = %{
        model: %{
          provider: :openai,
          id: "z-ai/glm-5.3-flash",
          base_url: "https://openrouter.ai/api/v1"
        }
      }

      refute Keyword.has_key?(LLM.profile_generation_params(profile), :provider_options)
    end

    test "an explicit provider_options override wins over the default" do
      params =
        LLM.profile_generation_params(%{model: "openai:gpt-5", provider_options: %{store: true}})

      assert params[:provider_options] == [store: true]
    end

    test "an empty explicit override yields NO provider_options key" do
      refute Keyword.has_key?(
               LLM.profile_generation_params(%{model: "openai:gpt-5", provider_options: %{}}),
               :provider_options
             )
    end

    test "a non-OpenAI profile without an override gets no provider_options key" do
      refute Keyword.has_key?(
               LLM.profile_generation_params(%{model: "anthropic:claude"}),
               :provider_options
             )
    end
  end

  describe "LLMConstraints.filter/3 — Z.AI/GLM table rules without metadata" do
    test "drops top_k / frequency_penalty / presence_penalty for a :zai provider atom" do
      params = [
        temperature: 0.7,
        top_p: 0.9,
        top_k: 50,
        frequency_penalty: 0.5,
        presence_penalty: 0.5
      ]

      assert LLMConstraints.filter(params, "zai:glm-5.3-flash", nil) ==
               [temperature: 0.7, top_p: 0.9]
    end

    test "matches on the provider atom alone even when the id does not contain glm" do
      assert LLMConstraints.filter([top_k: 50], {:zai, [id: "mystery-model"]}, nil) == []
      assert LLMConstraints.filter([top_k: 50], {:zai_coder, [id: "mystery"]}, nil) == []
      assert LLMConstraints.filter([top_k: 50], {:zai_coding_plan, [id: "mystery"]}, nil) == []
    end

    test "matches OpenRouter-style z-ai/glm-* ids through the model-id heuristic" do
      model = %{
        provider: :openrouter,
        id: "z-ai/glm-5.3-flash",
        base_url: "https://openrouter.ai/api/v1"
      }

      assert LLMConstraints.filter([top_k: 50, temperature: 0.4], model, nil) ==
               [temperature: 0.4]
    end

    test "keyword order of the surviving params is preserved" do
      params = [
        temperature: 0.7,
        top_k: 50,
        max_tokens: 100,
        frequency_penalty: 0.1
      ]

      assert LLMConstraints.filter(params, "zai:glm-4.6", nil) ==
               [temperature: 0.7, max_tokens: 100]
    end

    test "non-GLM models are left byte-identical" do
      params = [
        temperature: 2.0,
        top_k: 50,
        frequency_penalty: 0.5,
        presence_penalty: 0.5,
        reasoning_effort: :medium
      ]

      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", nil) == params
      assert LLMConstraints.filter(params, %{provider: :openai, id: "gpt-5"}, nil) == params
      assert LLMConstraints.filter(params, "deepseek:deepseek-chat", nil) == params
    end

    test "a nil / unknown model spec is left byte-identical" do
      params = [top_k: 50, temperature: 1.9]

      assert LLMConstraints.filter(params, nil, nil) == params
      assert LLMConstraints.filter(params, "", nil) == params
      assert LLMConstraints.filter(params, 42, nil) == params
      assert LLMConstraints.filter(params, %{}, nil) == params
      assert LLMConstraints.filter(params, "no-colon", nil) == params
    end

    test "nil / non-keyword params are returned unchanged" do
      assert LLMConstraints.filter(nil, "zai:glm-5.3-flash", nil) == nil
      assert LLMConstraints.filter("nope", "zai:glm-5.3-flash", nil) == "nope"
      assert LLMConstraints.filter([1, 2, 3], "zai:glm-5.3-flash", nil) == [1, 2, 3]
      assert LLMConstraints.filter([], "zai:glm-5.3-flash", nil) == []
    end

    test "a warning names the dropped parameter and the model" do
      log =
        capture_log(fn -> LLMConstraints.filter([top_k: 50], "zai:glm-5.3-flash", nil) end)

      assert log =~ ":top_k"
      assert log =~ "zai:glm-5.3-flash"
    end
  end

  describe "LLMConstraints.filter/3 — reasoning_effort value sets" do
    test "GLM-5.3 / GLM-5.3-FLASH accept low | high | max only" do
      models = [
        "zai:glm-5.3",
        "zai:glm-5.3-flash",
        %{provider: :openrouter, id: "z-ai/glm-5.3-flash"}
      ]

      for model <- models do
        assert LLMConstraints.filter([reasoning_effort: :low], model, nil) ==
                 [reasoning_effort: :low]

        assert LLMConstraints.filter([reasoning_effort: :high], model, nil) ==
                 [reasoning_effort: :high]

        assert LLMConstraints.filter([reasoning_effort: :max], model, nil) ==
                 [reasoning_effort: :max]

        assert LLMConstraints.filter([reasoning_effort: :medium], model, nil) == []
        assert LLMConstraints.filter([reasoning_effort: :none], model, nil) == []
      end
    end

    test "a TOML string 'max' is accepted for GLM-5.3 (compared on the normalized form)" do
      assert LLMConstraints.filter([reasoning_effort: "max"], "zai:glm-5.3-flash", nil) ==
               [reasoning_effort: "max"]
    end

    test "other GLM models accept the full OpenAI set" do
      for model <- ["zai:glm-5.2", "zai:glm-4.6"] do
        for effort <- [:none, :minimal, :low, :medium, :high, :xhigh, :default] do
          assert LLMConstraints.filter([reasoning_effort: effort], model, nil) ==
                   [reasoning_effort: effort]
        end
      end
    end

    test "non-GLM models are unaffected" do
      assert LLMConstraints.filter([reasoning_effort: :medium], "anthropic:claude-sonnet-4", nil) ==
               [reasoning_effort: :medium]
    end
  end

  describe "LLMConstraints.filter/3 — temperature ceiling" do
    test "above the documented Z.AI maximum (1.0) is omitted, not clamped" do
      assert LLMConstraints.filter([temperature: 1.5], "zai:glm-4.6", nil) == []
      assert LLMConstraints.filter([temperature: 2.0], "zai:glm-4.6", nil) == []
    end

    test "at or below the maximum is kept" do
      assert LLMConstraints.filter([temperature: 1.0], "zai:glm-4.6", nil) == [temperature: 1.0]
      assert LLMConstraints.filter([temperature: 0.3], "zai:glm-4.6", nil) == [temperature: 0.3]
    end

    test "non-GLM providers keep values up to Genesis' own maximum" do
      assert LLMConstraints.filter([temperature: 2.0], "anthropic:claude-sonnet-4", nil) ==
               [temperature: 2.0]
    end
  end

  describe "LLMConstraints.filter/3 — metadata-driven rules" do
    test "max_tokens above limits.output is omitted" do
      meta = %{limits: %{output: 131_072}, capabilities: %{}}

      assert LLMConstraints.filter([max_tokens: 200_000], "zai:glm-5.3-flash", meta) == []
    end

    test "max_tokens within limits.output is kept" do
      meta = %{limits: %{output: 131_072}, capabilities: %{}}

      assert LLMConstraints.filter([max_tokens: 131_072], "zai:glm-5.3-flash", meta) ==
               [max_tokens: 131_072]

      assert LLMConstraints.filter([max_tokens: 4096], "zai:glm-5.3-flash", meta) ==
               [max_tokens: 4096]
    end

    test "max_tokens is kept when the metadata is missing or carries no limit" do
      params = [max_tokens: 999_999]

      assert LLMConstraints.filter(params, "zai:glm-5.3-flash", nil) == params

      assert LLMConstraints.filter(params, "zai:glm-5.3-flash", %{limits: %{}, capabilities: %{}}) ==
               params

      assert LLMConstraints.filter(params, "zai:glm-5.3-flash", %{limits: %{output: nil}}) ==
               params
    end

    test "string-keyed metadata is tolerated" do
      meta = %{"limits" => %{"output" => 10}, "capabilities" => %{}}

      assert LLMConstraints.filter([max_tokens: 100], "zai:glm-4.6", meta) == []
    end

    test "reasoning_effort is dropped when the model does not declare reasoning" do
      meta = %{
        limits: %{},
        capabilities: %{reasoning: %{enabled: false}, tools: %{enabled: true}}
      }

      assert LLMConstraints.filter([reasoning_effort: :high], "anthropic:claude-sonnet-4", meta) ==
               []
    end

    test "reasoning_effort is kept when reasoning is enabled or undeclared" do
      enabled = %{limits: %{}, capabilities: %{reasoning: %{enabled: true}}}

      assert LLMConstraints.filter(
               [reasoning_effort: :high],
               "anthropic:claude-sonnet-4",
               enabled
             ) ==
               [reasoning_effort: :high]

      assert LLMConstraints.filter(
               [reasoning_effort: :high],
               "anthropic:claude-sonnet-4",
               %{limits: %{output: 10}}
             ) == [reasoning_effort: :high]
    end

    test "tool params are dropped when tools.enabled is false" do
      meta = %{limits: %{}, capabilities: %{tools: %{enabled: false}}}
      params = [temperature: 0.5, tools: [%{name: "x"}], tool_choice: "auto"]

      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", meta) ==
               [temperature: 0.5]
    end

    test "tool params are kept when tools are enabled or undeclared" do
      params = [tools: [%{name: "x"}], tool_choice: "auto"]

      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", %{
               capabilities: %{tools: %{enabled: true}}
             }) == params

      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", nil) == params
    end

    test "garbage metadata never causes a drop" do
      params = [temperature: 0.5, top_p: 0.9]

      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", :garbage) == params
      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", %{other: 1}) == params
      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", []) == params
    end
  end

  describe "LLM.model_metadata/1 — injection seam" do
    test "reads the app-env seam at call time" do
      stub_metadata(%{limits: %{output: 100}, capabilities: %{reasoning: %{enabled: true}}})

      assert LLM.model_metadata("anthropic:claude") == %{
               limits: %{output: 100},
               capabilities: %{reasoning: %{enabled: true}}
             }
    end

    test "normalizes a raw catalog-like map carrying :limits / :capabilities" do
      stub_metadata(%{id: "x", limits: %{output: 5}, capabilities: %{tools: %{enabled: true}}})

      assert LLM.model_metadata("anthropic:claude") == %{
               limits: %{output: 5},
               capabilities: %{tools: %{enabled: true}}
             }
    end

    test "collapses empty / garbage seam results to nil" do
      stub_metadata(%{})
      assert LLM.model_metadata("anthropic:claude") == nil

      stub_metadata(:nope)
      assert LLM.model_metadata("anthropic:claude") == nil

      stub_metadata(nil)
      assert LLM.model_metadata("anthropic:claude") == nil
    end

    test "a raising seam never propagates (warns and degrades to nil)" do
      Application.put_env(:evo_git, @seam, fn _model -> raise "boom" end)

      log =
        capture_log(fn ->
          assert LLM.model_metadata("anthropic:claude") == nil
        end)

      assert log =~ "metadata lookup failed"
    end

    test "a throwing seam never propagates" do
      Application.put_env(:evo_git, @seam, fn _model -> throw(:boom) end)

      capture_log(fn ->
        assert LLM.model_metadata("anthropic:claude") == nil
      end)
    end

    test "the seam flows through profile_generation_params/1" do
      stub_metadata(%{limits: %{output: 10}, capabilities: %{reasoning: %{enabled: false}}})

      assert LLM.profile_generation_params(%{
               model: "anthropic:claude",
               max_tokens: 100,
               reasoning_effort: :high
             }) == []
    end

    test "without the seam the real catalog path is used and never raises" do
      Application.delete_env(:evo_git, @seam)

      for spec <- [
            nil,
            "",
            42,
            %{},
            "no-colon",
            "not-a-real-provider:id",
            "zai:glm-5.3-flash",
            {:zai, [id: "glm-5.3-flash"]},
            %{provider: :openai, id: "z-ai/glm-5.3-flash"}
          ] do
        metadata = LLM.model_metadata(spec)
        assert is_nil(metadata) or is_map(metadata), "unexpected metadata for #{inspect(spec)}"
      end
    end

    test "table rules still fire through profile_generation_params/1 without the seam" do
      Application.delete_env(:evo_git, @seam)

      params =
        LLM.profile_generation_params(%{
          model: "zai:glm-5.3-flash",
          top_k: 50,
          max_tokens: 4096
        })

      refute Keyword.has_key?(params, :top_k)
      assert params[:max_tokens] == 4096
    end
  end

  describe "LLMConstraints.constraints_for/1" do
    test "returns the Z.AI/GLM table for a :zai provider atom and for a GLM id" do
      assert [%{id: :zai_glm}] = LLMConstraints.constraints_for("zai:glm-5.3-flash")
      assert [%{id: :zai_glm}] = LLMConstraints.constraints_for({:zai, [id: "mystery"]})

      assert [%{id: :zai_glm}] =
               LLMConstraints.constraints_for(%{provider: :openrouter, id: "z-ai/glm-4.6"})
    end

    test "every matching entry documents its provenance" do
      tables = LLMConstraints.constraints_for("zai:glm-5.3-flash")
      assert tables != []

      for table <- tables do
        assert is_binary(table.provenance)
        assert table.provenance =~ "Z.AI"
        assert is_list(table.unsupported_params)
        assert is_number(table.max_temperature)
      end
    end

    test "returns [] for unrelated and unknown models" do
      assert LLMConstraints.constraints_for("anthropic:claude-sonnet-4") == []
      assert LLMConstraints.constraints_for(nil) == []
      assert LLMConstraints.constraints_for(%{}) == []
      assert LLMConstraints.constraints_for(42) == []
    end
  end
end
