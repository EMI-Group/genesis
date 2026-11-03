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

  describe "refreshed model lists" do
    # Per-provider model ids, newest generation first. Derived from the vendored
    # LLMDB catalog snapshot (retired/non-chat entries and superseded
    # generations excluded). `provider_models/1` resolves by provider atom, so
    # every key below matches a `provider_atoms` entry.
    @expected_models %{
      anthropic: [
        "claude-haiku-5-5",
        "claude-sonnet-5-5",
        "claude-opus-5-5",
        "claude-fable-5-1",
        "claude-opus-5",
        "claude-sonnet-5"
      ],
      openai: [
        "gpt-6.1-sol",
        "gpt-6-sol",
        "gpt-6-luna",
        "gpt-6-astra",
        "gpt-5.6-sol",
        "gpt-5.6-terra"
      ],
      google: [
        "gemini-4-argon",
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite"
      ],
      deepseek: [
        "deepseek-v4-flash-vision-exp",
        "deepseek-v4-flash",
        "deepseek-flash",
        "deepseek-v4-pro"
      ],
      alibaba: [
        "qwen3.8-omni-flash",
        "qwen3.8-flash",
        "qwen3.8-max",
        "qwen3.7-flash",
        "qwen3.7-plus",
        "qwen3.7-max"
      ],
      zai: ["glm-5.3-flashx", "glm-5.3-flash", "glm-5.3", "glm-5.2", "glm-5.1"],
      minimax: [
        "MiniMax-M3.1-Flash",
        "MiniMax-M3",
        "MiniMax-M2.7",
        "MiniMax-M2.7-highspeed"
      ],
      moonshotai: [
        "kimi-k3.1-pro",
        "kimi-k3.1-pro-highspeed",
        "kimi-k3",
        "kimi-k2.7-code-highspeed",
        "kimi-k2.7-code"
      ],
      xai: ["grok-4.7", "grok-4.6", "grok-4.5", "grok-4.3", "grok-build-0.1"]
    }

    # Models the refresh deliberately retired. They must never come back by
    # appending to the existing list instead of regenerating it.
    @retired_models %{
      anthropic: [
        "claude-fable-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-sonnet-4-6"
      ],
      openai: ["gpt-5.6-luna", "gpt-5.5", "gpt-5.4"],
      google: ["gemini-3.1-pro-preview", "gemini-flash-latest"],
      alibaba: ["qwen3.6-plus"],
      zai: ["glm-5-turbo", "glm-5"],
      minimax: ["MiniMax-M2.5", "MiniMax-M2.5-highspeed"],
      moonshotai: ["kimi-k2.6"],
      xai: ["grok-imagine-image", "grok-imagine-image-2.0"]
    }

    test "each provider ships exactly its refreshed model list" do
      for {provider_atom, expected_ids} <- @expected_models do
        assert Enum.map(LLMCatalog.provider_models(provider_atom), & &1.id) == expected_ids
      end
    end

    test "retired model ids are gone from provider_models/1" do
      for {provider_atom, retired_ids} <- @retired_models,
          retired_id <- retired_ids do
        refute retired_id in Enum.map(LLMCatalog.provider_models(provider_atom), & &1.id),
               "retired model #{inspect(retired_id)} is still offered for #{inspect(provider_atom)}"
      end
    end

    test "newly added models resolve and carry a readable display name" do
      new_models = [
        {:anthropic, "claude-haiku-5-5"},
        {:openai, "gpt-6.1-sol"},
        {:google, "gemini-4-argon"},
        {:alibaba, "qwen3.8-omni-flash"},
        {:zai, "glm-5.3-flashx"},
        {:minimax, "MiniMax-M3.1-Flash"},
        {:moonshotai, "kimi-k3.1-pro"},
        {:moonshotai, "kimi-k3.1-pro-highspeed"}
      ]

      for {provider_atom, model_id} <- new_models do
        model = Enum.find(LLMCatalog.provider_models(provider_atom), &(&1.id == model_id))
        assert model, "#{model_id} missing from #{inspect(provider_atom)}"
        assert is_binary(model.display_name)
        assert model.display_name != ""

        assert LLMCatalog.resolve_model(provider_atom, model_id) ==
                 "#{hd(LLMCatalog.find_provider(provider_atom).provider_atoms)}:#{model_id}"
      end
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
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-6-sol", base_url: "https://my.proxy/v1") ==
               %{provider: :openai, id: "gpt-6-sol", base_url: "https://my.proxy/v1"}
    end

    test "omits base_url when it is an empty string" do
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-6-sol", base_url: "") ==
               %{provider: :openai, id: "gpt-6-sol"}
    end

    test "omits base_url when it is nil" do
      assert LLMCatalog.resolve_model_spec(:openai, "gpt-6-sol", base_url: nil) ==
               %{provider: :openai, id: "gpt-6-sol"}
    end

    test "includes extra when a non-nil value is provided" do
      assert LLMCatalog.resolve_model_spec(:google, "gemini-3.7-flash", extra: %{family: "glm"}) ==
               %{provider: :google, id: "gemini-3.7-flash", extra: %{family: "glm"}}
    end

    test "omits extra when it is nil" do
      refute Map.has_key?(
               LLMCatalog.resolve_model_spec(:google, "gemini-3.7-flash", extra: nil),
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
