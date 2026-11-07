# Kept in the assigned leaf so this contract can run before the core/UI merge.
# Move into test/evo_dash_web/live/settings_live/ when integrating sibling tests.
ExUnit.start()

defmodule EvoDashWeb.SettingsLive.ProviderProfilesContractTest do
  use ExUnit.Case, async: true
  alias EvoDashWeb.SettingsLive.{AuthStatus, ConfigIO, ProviderProfiles}

  defp params, do: %{"provider" => "openai", "models" => [%{"model" => "example"}]}

  test "minimal canonical profile keeps generation overrides absent" do
    assert {:ok, profile} = ProviderProfiles.parse(params(), "test")
    assert profile["id"] == "test"
    assert profile["auth_mode"] == "api_key"
    assert profile["models"] == [%{"model" => "example"}]
    assert profile["concurrency"] == 3
    refute Map.has_key?(profile, "temperature")
    refute Map.has_key?(profile, "reasoning_effort")
  end

  test "nested model overrides and reasoning are typed and ordered" do
    input =
      Map.merge(params(), %{
        "reasoning_efforts" => "low, high",
        "default_reasoning_effort" => "high",
        "models" => %{
          "10" => %{"model" => "ten", "temperature" => "0.5"},
          "2" => %{"model" => "two", "context_window" => "64000"}
        }
      })

    assert {:ok, profile} = ProviderProfiles.parse(input, "test")
    assert Enum.map(profile["models"], & &1["model"]) == ["two", "ten"]
    assert hd(profile["models"])["context_window"] == 64000
    assert List.last(profile["models"])["temperature"] == 0.5
    assert profile["reasoning_efforts"] == ["low", "high"]

    assert {:error, "reasoning_default_invalid"} =
             ProviderProfiles.parse(Map.put(input, "default_reasoning_effort", "other"), "test")
  end

  test "OAuth-only auth is forced and status adapter carries no API secret" do
    input =
      Map.merge(params(), %{
        "provider" => "openai_codex",
        "auth_mode" => "api_key",
        "api_key" => "secret",
        "oauth_file" => " /managed "
      })

    assert {:ok, profile} = ProviderProfiles.parse(input, "codex")
    assert profile["auth_mode"] == "oauth"
    refute Map.has_key?(profile, "api_key")
    assert profile["oauth_file"] == "/managed"
    assert AuthStatus.credential_profile(profile).model.provider == :openai_codex
    refute Map.has_key?(AuthStatus.credential_profile(profile), :api_key)
    assert AuthStatus.unknown_statuses([profile])["codex"].state == :unknown
  end

  test "writes omit legacy shadows while preserving unrelated config" do
    config = %{
      scheduler: %{max_turns: 12},
      llm: %{models: [%{id: "old"}], tool_result_pruning: false}
    }

    updated = ProviderProfiles.put_profiles(config, [%{"id" => "a"}, %{"id" => "b"}])
    refute Map.has_key?(updated.llm, :models)
    refute Map.has_key?(updated.llm, "models")
    assert updated.llm.default_provider_profile == "a"
    assert updated.llm.tool_result_pruning == false
    assert updated.scheduler == config.scheduler

    empty = ProviderProfiles.put_profiles(updated, [])
    assert empty.llm.providers == []
    refute Map.has_key?(empty.llm, :default_provider_profile)
  end

  test "editing preserves shared fields and numeric values from the core" do
    original = %{
      "id" => "old",
      "provider" => "openai",
      "name" => "Original",
      "concurrency" => 4,
      "peak_concurrency" => 0,
      "extra" => %{"flag" => true},
      "models" => [%{"model" => "example", "context_window" => 40000}]
    }

    assert {:ok, profile} = ProviderProfiles.parse(%{}, "renamed", original)
    assert profile["concurrency"] == 4
    assert profile["peak_concurrency"] == 0
    assert profile["extra"] == %{"flag" => true}
    assert hd(profile["models"])["context_window"] == 40000
  end

  test "legacy single-model edit fields save without a model shadow" do
    assert {:ok, profile} =
             ProviderProfiles.parse(
               %{
                 "provider" => "openai",
                 "model_id" => "legacy",
                 "context_window" => "90000",
                 "reasoning_effort" => "high"
               },
               "old"
             )

    assert profile["default_model"] == "legacy"
    assert hd(profile["models"])["context_window"] == 90000
    refute Map.has_key?(profile, "model")
    refute Map.has_key?(profile, "reasoning_effort")
  end

  test "validation rejects malformed rows, duplicates, bad numbers and defaults" do
    assert {:error, "models_invalid"} =
             ProviderProfiles.parse(
               Map.put(params(), "models", [123, %{"model" => "ok"}]),
               "test"
             )

    assert {:error, "duplicate_model"} =
             ProviderProfiles.parse(
               Map.put(params(), "models", [%{"model" => "x"}, %{"model" => "x"}]),
               "test"
             )

    assert {:error, "numeric_invalid"} =
             ProviderProfiles.parse(Map.put(params(), "concurrency", "invalid"), "test")

    assert {:error, "invalid_extra_json"} =
             ProviderProfiles.parse(Map.put(params(), "extra", "{"), "test")

    assert {:error, "default_model_invalid"} =
             ProviderProfiles.parse(Map.put(params(), "default_model", "missing"), "test")
  end

  test "dedicated fields never enter generic flat-category deletion" do
    schemas = [
      %{type: :provider_profiles, key_path: [:llm, :providers]},
      %{type: :string, key_path: [:llm, :default_provider_profile]}
    ]

    assert ConfigIO.params_to_category_config(%{}, :llm, schemas) == {%{}, []}
  end

  test "submission preserves explicitly emptied rows without overriding legacy model input" do
    draft = %{"models" => [], "peak_hours" => [], "off_peak_days" => []}
    submitted = ProviderProfiles.submission(params(), draft)
    assert submitted["peak_hours"] == []
    assert submitted["models"] == params()["models"]

    emptied = ProviderProfiles.submission(%{"provider" => "openai"}, draft)
    assert {:error, "model_id_empty"} = ProviderProfiles.parse(emptied, "test", params())

    legacy = ProviderProfiles.submission(%{"provider" => "openai", "model_id" => "new"}, draft)
    assert {:ok, %{"models" => [%{"model" => "new"}]}} = ProviderProfiles.parse(legacy, "test")
  end

  test "draft rows are ordered, detached, and preserve blank input" do
    profile = %{"models" => [%{"model" => "example", "extra" => %{"a" => 1}}]}
    draft = ProviderProfiles.draft(profile)
    assert hd(draft["models"])["extra"] == ~s({"a":1})

    updated =
      ProviderProfiles.normalize_draft(%{
        "models" => %{"1" => %{"model" => ""}, "0" => %{"model" => "first"}},
        "off_peak_days" => "weekends"
      })

    assert updated["models"] == [%{"model" => "first"}, %{"model" => ""}]
    assert updated["off_peak_days"] == ["weekends"]
    assert hd(profile["models"])["extra"] == %{"a" => 1}
  end
end
