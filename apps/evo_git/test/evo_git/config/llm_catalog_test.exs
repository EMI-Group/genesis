defmodule EvoGit.Config.LLMCatalogTest do
  @moduledoc """
  Pins the static provider/model catalog surface (`EvoGit.Config.LLMCatalog`):
  provider entries, model id display-name resolution, credential keys, and
  `base_url` / variant rules.

  `async: true` is safe: the catalog is compile-time static data and every
  function under test is a pure lookup — no app env, `:persistent_term`, ETS,
  process, or other shared state is read or written.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Config.LLMCatalog

  describe "providers/0" do
    test "returns a list of provider entries" do
      providers = LLMCatalog.providers()
      assert is_list(providers)
      assert length(providers) > 0
    end

    test "every entry has required keys" do
      required_keys = [:id, :display_name, :provider_atoms, :credential_key, :models, :variants]

      for provider <- LLMCatalog.providers() do
        for key <- required_keys do
          assert Map.has_key?(provider, key),
                 "provider #{inspect(provider.id)} is missing required key #{inspect(key)}"
        end
      end
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
      assert provider.credential_key == "openrouter_api_key"
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
      assert provider.credential_key == "openai_api_key"
      assert provider.provider_atoms == [:openai]
      assert provider.variants == nil
      assert provider.models == []
      assert provider.custom_model == true
      assert provider.requires_base_url == true
    end
  end

  describe "resolve_model/2 for minimax" do
    test "resolves exact model id" do
      assert LLMCatalog.resolve_model(:minimax, "MiniMax-M3") == "minimax:MiniMax-M3"
    end

    test "resolves display name to canonical model id" do
      result = LLMCatalog.resolve_model(:minimax, "MiniMax-M2.7 Highspeed")
      assert result == "minimax:MiniMax-M2.7-highspeed"
    end
  end

  describe "known_credential_keys/0" do
    test "returns a list of strings" do
      vars = LLMCatalog.known_credential_keys()
      assert is_list(vars)

      for v <- vars do
        assert is_binary(v)
      end
    end

    test "includes all expected provider and variant env vars" do
      vars = LLMCatalog.known_credential_keys()

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
        "xai_api_key",
        "openrouter_api_key"
      ]

      for e <- expected do
        assert e in vars, "expected #{e} to be in known_credential_keys/0"
      end
    end

    test "returns unique values" do
      assert LLMCatalog.known_credential_keys() == Enum.uniq(LLMCatalog.known_credential_keys())
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

    # Data-driven instead of one hand-maintained list per catalogue batch: every
    # entry the catalogue ships must resolve to its own provider/id, and every
    # display name to its canonical id.
    test "every catalog model id resolves to its canonical provider/id" do
      for provider <- LLMCatalog.providers(),
          model <- provider.models do
        canonical = hd(provider.provider_atoms)

        assert LLMCatalog.resolve_model_spec(provider.id, model.id) ==
                 %{provider: canonical, id: model.id},
               "#{provider.id} model id #{inspect(model.id)} did not resolve"
      end
    end

    test "every catalog display name resolves to its canonical model id" do
      for provider <- LLMCatalog.providers(),
          model <- provider.models do
        canonical = hd(provider.provider_atoms)

        assert LLMCatalog.resolve_model_spec(provider.id, model.display_name) ==
                 %{provider: canonical, id: model.id},
               "#{provider.id} display name #{inspect(model.display_name)} did not resolve to #{inspect(model.id)}"
      end
    end

    test "includes base_url when a non-empty value is provided" do
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-5.5", base_url: "https://my.proxy/v1") ==
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
      assert LLMCatalog.resolve_model_spec(:google, "gemini-3.1-pro-preview",
               extra: %{family: "glm"}
             ) ==
               %{provider: :google, id: "gemini-3.1-pro-preview", extra: %{family: "glm"}}
    end

    test "omits extra when it is nil" do
      refute Map.has_key?(
               LLMCatalog.resolve_model_spec(:google, "gemini-3.1-pro-preview", extra: nil),
               :extra
             )
    end

    test "variant resolves to the variant's provider atom (alibaba cn)" do
      # The :cn variant maps to provider_atom :alibaba_cn (from the catalog)
      assert LLMCatalog.resolve_model_spec(:alibaba, "qwen3.7-max", variant: :cn) ==
               %{provider: :alibaba_cn, id: "qwen3.7-max"}
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

    test "returns false for providers without the flag and for unknown providers" do
      for provider <- [:anthropic, :openai, :google, :openrouter, :unknown_provider] do
        assert LLMCatalog.requires_base_url?(provider) == false,
               "expected #{inspect(provider)} not to require a base_url"
      end
    end
  end

  describe "credential_key_for_atom/1" do
    test "lowercases the atom name and appends _api_key" do
      for {atom, key} <- [
            {:anthropic, "anthropic_api_key"},
            {:zai_coding_plan, "zai_coding_plan_api_key"},
            {:alibaba_cn, "alibaba_cn_api_key"},
            {:openai, "openai_api_key"}
          ] do
        assert LLMCatalog.credential_key_for_atom(atom) == key
      end
    end
  end

  describe "llm_db resolvability (correctness bar)" do
    # Every model id in the catalog MUST resolve through the authoritative
    # llm_db resolver for the provider's canonical atom — otherwise the CLI
    # setup wizard and dashboard pickers would offer models that fail at
    # request time. `LLMDB.model/2` validates; `ReqLLM.model/1` does not.
    test "every catalog model id resolves via LLMDB.model/2" do
      for provider <- LLMCatalog.providers(),
          provider.models != [],
          model <- provider.models do
        canonical = hd(provider.provider_atoms)

        assert {:ok, _} = LLMDB.model(canonical, model.id),
               "catalog model #{inspect(model.id)} does not resolve for provider #{inspect(canonical)}"
      end
    end
  end
end
