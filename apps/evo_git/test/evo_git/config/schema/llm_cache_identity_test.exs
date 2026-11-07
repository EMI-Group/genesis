defmodule EvoGit.Config.Schema.LLMCacheIdentityTest do
  @moduledoc """
  `EvoGit.Config.Schema.LLM.with_cache_identity/3` — the provider-gated
  prompt-cache/routing identity.

  `async: true`: this module only touches pure functions and a fixed provider
  literal, so it shares no BEAM-global state with other modules.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config.Schema.LLM

  defp provider_options(params) when is_list(params) do
    case Keyword.fetch(params, :provider_options) do
      {:ok, options} -> options
      :error -> flunk("expected :provider_options in #{inspect(params)}")
    end
  end

  defp cache_key(params), do: Keyword.fetch!(provider_options(params), :prompt_cache_key)

  describe "provider gating" do
    test ":openai_codex gets prompt_cache_key AND session_id, both the derived key" do
      params = [provider_options: [auth_mode: :oauth, oauth_file: "/tmp/auth.json"]]

      result =
        LLM.with_cache_identity(params, "task-codex-1", "openai_codex:gpt-6-luna")

      options = provider_options(result)
      key = Keyword.fetch!(options, :prompt_cache_key)

      assert key == Keyword.fetch!(options, :session_id)
      assert key == "genesis-task-codex-1"
      # The existing options are EXTENDED, never replaced.
      assert Keyword.fetch!(options, :auth_mode) == :oauth
      assert Keyword.fetch!(options, :oauth_file) == "/tmp/auth.json"
    end

    test ":openai gets prompt_cache_key only (no session_id)" do
      params = [provider_options: [store: false]]

      result = LLM.with_cache_identity(params, "task-openai-1", "openai:gpt-4o")

      options = provider_options(result)
      assert Keyword.fetch!(options, :prompt_cache_key) == "genesis-task-openai-1"
      refute Keyword.has_key?(options, :session_id)
      # store: false survives.
      assert Keyword.fetch!(options, :store) == false
    end

    test "a model MAP form resolves the provider too" do
      result =
        LLM.with_cache_identity([], "map-conversation", %{provider: :openai, id: "gpt-4o"})

      assert cache_key(result) == "genesis-map-conversation"
      refute Keyword.has_key?(provider_options(result), :session_id)
    end

    test "a codex model MAP form gets both keys" do
      result =
        LLM.with_cache_identity([], "map-conversation", %{
          provider: :openai_codex,
          id: "gpt-6-luna"
        })

      options = provider_options(result)

      assert Keyword.fetch!(options, :prompt_cache_key) ==
               Keyword.fetch!(options, :session_id)
    end

    test "non-OpenAI providers are returned byte-identical" do
      for model <- [
            "deepseek:deepseek-v4-flash",
            "zai_coding_plan:glm-5.3",
            "anthropic:claude-sonnet-4"
          ] do
        params = [temperature: 0.7, provider_options: [thinking: %{type: "enabled"}]]
        assert LLM.with_cache_identity(params, "any-conversation", model) == params
      end
    end

    test "an unrecognized/absent provider is returned byte-identical" do
      params = [temperature: 0.7]
      assert LLM.with_cache_identity(params, "any-conversation", nil) == params
      assert LLM.with_cache_identity(params, "any-conversation", "no-provider-colon") == params
    end
  end

  describe "conversation id" do
    test "nil and empty conversation ids leave params untouched" do
      params = [provider_options: [store: false]]
      assert LLM.with_cache_identity(params, nil, "openai:gpt-4o") == params
      assert LLM.with_cache_identity(params, "", "openai:gpt-4o") == params
      assert LLM.with_cache_identity(params, "", "openai_codex:gpt-6-luna") == params
    end

    test "non-keyword params are left untouched" do
      assert LLM.with_cache_identity(%{provider_options: []}, "conversation", "openai:gpt-4o") ==
               %{provider_options: []}
    end
  end

  describe "explicit user configuration wins" do
    test "an explicit prompt_cache_key is preserved for :openai" do
      params = [provider_options: [store: false, prompt_cache_key: "user-key"]]

      assert LLM.with_cache_identity(params, "conversation", "openai:gpt-4o") == params
    end

    test "an explicit prompt_cache_key is preserved for :openai_codex" do
      params = [provider_options: [prompt_cache_key: "user-key"]]

      assert LLM.with_cache_identity(params, "conversation", "openai_codex:gpt-6-luna") == params
    end

    test "an explicit codex session_id wins (it already implies the cache key)" do
      params = [provider_options: [session_id: "user-session"]]

      assert LLM.with_cache_identity(params, "conversation", "openai_codex:gpt-6-luna") == params
    end
  end

  describe "derived key shape" do
    test "deterministic for the same input, distinct for a different one" do
      a = LLM.with_cache_identity([], "conversation-a", "openai:gpt-4o") |> cache_key()
      b = LLM.with_cache_identity([], "conversation-a", "openai:gpt-4o") |> cache_key()
      c = LLM.with_cache_identity([], "conversation-b", "openai:gpt-4o") |> cache_key()

      assert a == b
      refute a == c
      assert a =~ "genesis-"
    end

    test "ASCII and <= 64 characters, even for an over-long conversation id" do
      long_id = String.duplicate("a", 200)
      key = LLM.with_cache_identity([], long_id, "openai:gpt-4o") |> cache_key()

      assert key =~ ~r/\A[\x20-\x7e]+\z/
      assert byte_size(key) <= 64
      assert String.starts_with?(key, "genesis-")
      # Still deterministic, and still distinct from another over-long id.
      assert key == LLM.with_cache_identity([], long_id, "openai:gpt-4o") |> cache_key()
      refute key == LLM.with_cache_identity([], long_id <> "b", "openai:gpt-4o") |> cache_key()
    end

    test "ASCII and <= 64 characters for a non-ASCII conversation id" do
      key = LLM.with_cache_identity([], "对话-1", "openai:gpt-4o") |> cache_key()

      assert key =~ ~r/\A[\x20-\x7e]+\z/
      assert byte_size(key) <= 64
    end
  end
end
