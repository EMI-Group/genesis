defmodule EvoGit.Config.LLMCatalogTest do
  use ExUnit.Case, async: true

  alias EvoGit.Config.LLMCatalog

  describe "providers/0" do
    test "returns a list of provider entries" do
      providers = LLMCatalog.providers()
      assert is_list(providers)
      assert length(providers) > 0
    end

    test "every entry has required keys" do
      required_keys = [:id, :display_name, :provider_atoms, :env_var, :models, :variants]

      for provider <- LLMCatalog.providers() do
        for key <- required_keys do
          assert Map.has_key?(provider, key),
                 "provider #{inspect(provider.id)} is missing required key #{inspect(key)}"
        end
      end
    end

    test ":openrouter entry exists" do
      assert Enum.find(LLMCatalog.providers(), &(&1.id == :openrouter))
    end

    test ":openai_compatible entry exists" do
      assert Enum.find(LLMCatalog.providers(), &(&1.id == :openai_compatible))
    end
  end

  describe "minimax cleanup" do
    test "find_provider(:minimax) returns cleaned-up provider" do
      provider = LLMCatalog.find_provider(:minimax)
      assert provider != nil
      assert provider.provider_atoms == [:minimax]
      assert provider.variants == nil
      assert is_list(provider.models)
      assert length(provider.models) > 0
    end

    test "removed variant atoms are no longer found" do
      assert LLMCatalog.find_provider(:minimax_cn) == nil
      assert LLMCatalog.find_provider(:minimax_coding_plan) == nil
      assert LLMCatalog.find_provider(:minimax_cn_coding_plan) == nil
    end
  end

  describe "openrouter" do
    test "find_provider(:openrouter) returns expected provider entry" do
      provider = LLMCatalog.find_provider(:openrouter)
      assert provider != nil
      assert provider.display_name == "OpenRouter"
      assert provider.provider_atoms == [:openrouter]
      assert provider.env_var == "openrouter_api_key"
      assert provider.variants == nil
      assert provider.models == []
      assert provider.custom_model == true
      # requires_base_url is absent (nil)
      assert Map.get(provider, :requires_base_url) == nil
    end
  end

  describe "openai_compatible" do
    test "entry has expected attributes (found by id)" do
      provider =
        Enum.find(LLMCatalog.providers(), &(&1.id == :openai_compatible))

      assert provider != nil
      assert provider.display_name == "OpenAI-Compatible API"
      assert provider.env_var == "openai_api_key"
      assert provider.provider_atoms == [:openai]
      assert provider.variants == nil
      assert provider.models == []
      assert provider.custom_model == true
      assert provider.requires_base_url == true
    end
  end

  describe "resolve_model/2 for minimax" do
    test "returns a string starting with the canonical provider atom" do
      result = LLMCatalog.resolve_model(:minimax, "MiniMax-M3")
      assert is_binary(result)
      assert String.starts_with?(result, "minimax:")
    end

    test "resolves exact model id" do
      assert LLMCatalog.resolve_model(:minimax, "MiniMax-M3") == "minimax:MiniMax-M3"
    end

    test "resolves display name to canonical model id" do
      result = LLMCatalog.resolve_model(:minimax, "MiniMax-M2.7 Highspeed")
      assert result == "minimax:MiniMax-M2.7-highspeed"
    end
  end

  describe "known_env_vars/0" do
    test "returns a list of strings" do
      vars = LLMCatalog.known_env_vars()
      assert is_list(vars)

      for v <- vars do
        assert is_binary(v)
      end
    end

    test "includes all expected provider and variant env vars" do
      vars = LLMCatalog.known_env_vars()

      expected = [
        "anthropic_api_key",
        "openai_api_key",
        "google_api_key",
        "deepseek_api_key",
        "alibaba_api_key",
        "alibaba_cn_api_key",
        "zai_api_key",
        "zai_coding_plan_api_key",
        "minimax_api_key",
        "openrouter_api_key"
      ]

      for e <- expected do
        assert e in vars, "expected #{e} to be in known_env_vars/0"
      end
    end

    test "returns unique values" do
      assert LLMCatalog.known_env_vars() == Enum.uniq(LLMCatalog.known_env_vars())
    end
  end

  describe "provider_models/2" do
    test "returns a non-empty list for minimax" do
      models = LLMCatalog.provider_models(:minimax)
      assert is_list(models)
      assert length(models) > 0
    end

    test "returns empty list for openrouter" do
      assert LLMCatalog.provider_models(:openrouter) == []
    end

    test "returns empty list for nonexistent provider" do
      assert LLMCatalog.provider_models(:nonexistent) == []
    end
  end

  describe "resolve_model_spec/2,3" do
    # The map-producing analog of resolve_model/2. Returns
    # %{provider: atom, id: string} (plus optional base_url/extra).

    test "resolves provider + model id to a map with no base_url when not provided" do
      assert LLMCatalog.resolve_model_spec(:anthropic, "claude-sonnet-4") ==
               %{provider: :anthropic, id: "claude-sonnet-4"}
    end

    test "resolves a display name to the canonical catalog id" do
      # "Claude Sonnet 4.6" -> id "claude-sonnet-4-6" (from the catalog)
      assert LLMCatalog.resolve_model_spec(:anthropic, "Claude Sonnet 4.6") ==
               %{provider: :anthropic, id: "claude-sonnet-4-6"}
    end

    test "includes base_url when a non-empty value is provided" do
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-5.5",
               base_url: "https://my.proxy/v1"
             ) ==
               %{provider: :openai, id: "gpt-5.5", base_url: "https://my.proxy/v1"}
    end

    test "omits base_url when it is an empty string" do
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-5.5", base_url: "") ==
               %{provider: :openai, id: "gpt-5.5"}
    end

    test "omits base_url when it is nil" do
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-5.5", base_url: nil) ==
               %{provider: :openai, id: "gpt-5.5"}
    end

    test "includes extra when a non-nil value is provided" do
      assert LLMCatalog.resolve_model_spec(:google, "gemini-3.1-pro",
               extra: %{family: "glm"}
             ) ==
               %{provider: :google, id: "gemini-3.1-pro", extra: %{family: "glm"}}
    end

    test "omits extra when it is nil" do
      refute Map.has_key?(
               LLMCatalog.resolve_model_spec(:google, "gemini-3.1-pro", extra: nil),
               :extra
             )
    end

    test "variant resolves to the variant's provider atom (alibaba cn)" do
      # The :cn variant maps to provider_atom :alibaba_cn (from the catalog)
      assert LLMCatalog.resolve_model_spec(:alibaba, "qwen-3.7-max", variant: :cn) ==
               %{provider: :alibaba_cn, id: "qwen-3.7-max"}
    end

    test "custom/unknown model passes through unchanged" do
      assert LLMCatalog.resolve_model_spec(:openrouter, "custom-model-x") ==
               %{provider: :openrouter, id: "custom-model-x"}
    end
  end

  describe "requires_base_url?/1" do
    test "returns true for openai_compatible" do
      assert LLMCatalog.requires_base_url?(:openai_compatible) == true
    end

    test "returns false for anthropic" do
      assert LLMCatalog.requires_base_url?(:anthropic) == false
    end

    test "returns false for openai" do
      assert LLMCatalog.requires_base_url?(:openai) == false
    end

    test "returns false for google" do
      assert LLMCatalog.requires_base_url?(:google) == false
    end

    test "returns false for openrouter" do
      assert LLMCatalog.requires_base_url?(:openrouter) == false
    end

    test "returns false for an unknown provider" do
      assert LLMCatalog.requires_base_url?(:unknown_provider) == false
    end
  end

  describe "env_var_for_atom/1" do
    test "lowercases the atom name and appends _api_key" do
      assert LLMCatalog.env_var_for_atom(:anthropic) == "anthropic_api_key"
    end

    test "works with multi-word atoms" do
      assert LLMCatalog.env_var_for_atom(:zai_coding_plan) == "zai_coding_plan_api_key"
    end

    test "works with aliased atoms like :alibaba_cn" do
      assert LLMCatalog.env_var_for_atom(:alibaba_cn) == "alibaba_cn_api_key"
    end

    test "works with single-word atoms" do
      assert LLMCatalog.env_var_for_atom(:openai) == "openai_api_key"
    end
  end
end
