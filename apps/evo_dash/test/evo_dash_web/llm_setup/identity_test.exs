defmodule EvoDashWeb.LLMSetup.IdentityTest do
  @moduledoc """
  Pins provider-DERIVED account identity: the name always comes from the
  provider (never a model), ids/names are uniquified case-insensitively, and
  every extraction helper is total over the shapes config can hand us.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.LLMSetup.Identity

  describe "provider_display_name/1" do
    test "uses the catalog display name for a known provider" do
      assert Identity.provider_display_name(:zai) == "Z.ai (Zhipu AI)"
      assert Identity.provider_display_name("zai") == "Z.ai (Zhipu AI)"
      assert Identity.provider_display_name(:deepseek) == "DeepSeek"
      assert Identity.provider_display_name("deepseek") == "DeepSeek"
      assert Identity.provider_display_name(:openrouter) == "OpenRouter"
    end

    test "an OpenAI-compatible endpoint is never presented as plain OpenAI" do
      name = Identity.provider_display_name(:openai_compatible)

      assert name == "OpenAI-Compatible API"
      refute name == "OpenAI"
    end

    test "titleizes an unknown provider spelling" do
      assert Identity.provider_display_name("my_proxy") == "My Proxy"
      assert Identity.provider_display_name("acme-gateway") == "Acme Gateway"
    end

    test "falls back to the custom-endpoint label for nil and blank input" do
      assert Identity.provider_display_name(nil) == "Custom endpoint"
      assert Identity.provider_display_name("") == "Custom endpoint"
      assert Identity.provider_display_name("   ") == "Custom endpoint"
      assert Identity.provider_display_name(42) == "Custom endpoint"
    end
  end

  describe "provider_slug/1" do
    test "slugs the catalog id" do
      assert Identity.provider_slug(:zai) == "zai"
      assert Identity.provider_slug(:deepseek) == "deepseek"
      assert Identity.provider_slug(:openai_compatible) == "openai-compatible"
    end

    test "slugs an unknown provider's titleized spelling" do
      assert Identity.provider_slug("My Proxy") == "my-proxy"
      assert Identity.provider_slug("acme_gateway") == "acme-gateway"
    end

    test "a nil provider resolves to the custom-endpoint slug" do
      # NOTE: the @doc claims "" for nil/blank, but the implementation routes
      # through provider_display_name/1 (→ "Custom endpoint") instead. Pinned
      # as implemented; reported rather than fixed.
      assert Identity.provider_slug(nil) == "custom-endpoint"
    end
  end

  describe "unique_id/2" do
    test "keeps the bare base while it is free" do
      assert Identity.unique_id("zai", []) == "zai"
      assert Identity.unique_id(:zai, []) == "zai"
    end

    test "appends -2, -3, … on collision" do
      assert Identity.unique_id("zai", ["zai"]) == "zai-2"
      assert Identity.unique_id("zai", ["zai", "zai-2"]) == "zai-3"
    end

    test "skips taken suffixes instead of counting blindly" do
      assert Identity.unique_id("zai", ["zai", "zai-3"]) == "zai-2"
      assert Identity.unique_id("zai", ["zai", "zai-2", "zai-4"]) == "zai-3"
    end

    test "compares case-insensitively" do
      assert Identity.unique_id("zai", ["ZAI"]) == "zai-2"
    end

    test "understands account maps, bare ids and id-keyed maps" do
      assert Identity.unique_id("deepseek", [%{"id" => "deepseek"}]) == "deepseek-2"
      assert Identity.unique_id("deepseek", [%{id: "deepseek"}]) == "deepseek-2"
      assert Identity.unique_id(:deepseek, [:deepseek]) == "deepseek-2"

      assert Identity.unique_id("deepseek", %{"deepseek" => %{"id" => "deepseek"}}) ==
               "deepseek-2"
    end

    test "a blank base uses the profile-N scheme" do
      assert Identity.unique_id("", []) == "profile-1"
      assert Identity.unique_id(nil, []) == "profile-1"
      assert Identity.unique_id("   ", ["profile-1"]) == "profile-2"
      assert Identity.unique_id("", ["profile-1", "profile-2"]) == "profile-3"
    end
  end

  describe "unique_name/2" do
    test "keeps the bare base while it is free and suffixes on collision" do
      assert Identity.unique_name("DeepSeek", []) == "DeepSeek"
      assert Identity.unique_name("DeepSeek", ["DeepSeek"]) == "DeepSeek-2"
      assert Identity.unique_name("DeepSeek", ["DeepSeek", "DeepSeek-2"]) == "DeepSeek-3"
    end

    test "compares case-insensitively" do
      assert Identity.unique_name("DeepSeek", ["deepseek"]) == "DeepSeek-2"

      assert Identity.unique_name("Z.ai (Zhipu AI)", [%{"name" => "z.ai (zhipu ai)"}]) ==
               "Z.ai (Zhipu AI)-2"
    end

    test "a blank base falls back to Account" do
      assert Identity.unique_name("", []) == "Account"
      assert Identity.unique_name(nil, []) == "Account"
      assert Identity.unique_name("  ", ["Account"]) == "Account-2"
    end
  end

  describe "default_identity/2" do
    test "returns a string-keyed id/name pair derived from the provider" do
      assert Identity.default_identity(:deepseek, []) == %{
               "id" => "deepseek",
               "name" => "DeepSeek"
             }

      assert Identity.default_identity(:openai_compatible, []) == %{
               "id" => "openai-compatible",
               "name" => "OpenAI-Compatible API"
             }
    end

    test "uniquifies a second account of the same provider on both id and name" do
      assert Identity.default_identity(:deepseek, [
               %{"id" => "deepseek", "name" => "DeepSeek"}
             ]) == %{"id" => "deepseek-2", "name" => "DeepSeek-2"}
    end

    test "never derives identity from a model" do
      identity = Identity.default_identity(:deepseek, [])

      refute identity["id"] =~ "flash"
      refute identity["id"] =~ "deepseek-v4"
      refute identity["name"] =~ "Flash"
      assert identity["name"] == "DeepSeek"
    end
  end

  describe "account_ids/1 and account_names/1" do
    test "extract from a list of account maps, bare ids/atoms and nil" do
      accounts = [%{"id" => "a"}, %{id: "b"}, "c", :d, nil]

      assert Identity.account_ids(accounts) == ["a", "b", "c", "d"]
      assert Identity.account_ids(nil) == []
      assert Identity.account_ids([]) == []
      assert Identity.account_ids("zai") == ["zai"]
      assert Identity.account_ids(:zai) == ["zai"]
    end

    test "an account id falls back to its name" do
      assert Identity.account_ids([%{"name" => "Only Name"}]) == ["Only Name"]
    end

    test "account_names/1 prefers the name and falls back to the id" do
      accounts = [%{"id" => "a", "name" => "Alpha"}, %{"display_name" => "Beta"}, %{"id" => "c"}]

      assert Identity.account_names(accounts) == ["Alpha", "Beta", "c"]
      assert Identity.account_names(nil) == []
      assert Identity.account_names(:zai) == ["zai"]
    end

    test "understand a map keyed by id" do
      keyed = %{"a" => %{"id" => "a", "name" => "Alpha"}}

      assert Identity.account_ids(keyed) == ["a"]
      assert Identity.account_names(keyed) == ["Alpha"]
    end

    test "are total over unrecognized input" do
      assert Identity.account_ids(42) == []
      assert Identity.account_names(42) == []
      assert Identity.account_ids(%{}) == []
      assert Identity.account_names(%{}) == []
    end
  end
end
