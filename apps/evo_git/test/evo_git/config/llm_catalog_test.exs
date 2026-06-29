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
      assert provider.env_var == "OPENROUTER_API_KEY"
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
      assert provider.env_var == "OPENAI_API_KEY"
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

    test "includes all expected provider env vars" do
      vars = LLMCatalog.known_env_vars()

      expected = [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "GOOGLE_API_KEY",
        "DEEPSEEK_API_KEY",
        "DASHSCOPE_API_KEY",
        "ZAI_API_KEY",
        "MINIMAX_API_KEY",
        "OPENROUTER_API_KEY"
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
end
