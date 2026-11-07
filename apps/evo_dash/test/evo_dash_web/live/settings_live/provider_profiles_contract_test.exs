defmodule EvoDashWeb.SettingsLive.ProviderProfilesContractTest do
  use ExUnit.Case, async: true

  # One pure editor-boundary suite keeps parse → draft → CRUD round trips
  # together; detached sockets below never start a LiveView or shared services.
  alias EvoDashWeb.SettingsLive.{AuthStatus, ConfigIO, ModelProfileEvents, ProviderProfiles}

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
    assert {:ok, ^profile} = ProviderProfiles.parse(%{}, "test", profile)
    refute Map.has_key?(profile, "model")
    refute Map.has_key?(profile, "reasoning_effort")

    assert {:error, "reasoning_default_invalid"} =
             ProviderProfiles.parse(Map.put(input, "default_reasoning_effort", "other"), "test")
  end

  test "nested generation overrides are typed, sparse and survive untouched editing" do
    input = %{
      "provider" => "openai",
      "default_model" => "inherited",
      "temperature" => "0.9",
      "max_tokens" => "4096",
      "top_p" => "0.8",
      "provider_options" => ~s({"parallel_tool_calls":true}),
      "models" => [
        %{"model" => "inherited"},
        %{
          "model" => "overridden",
          "temperature" => "0",
          "max_tokens" => "2048",
          "top_p" => "0.5",
          "top_k" => "4",
          "frequency_penalty" => "-0.2",
          "presence_penalty" => "0.1",
          "extra" => ~s({"flag":false}),
          "provider_options" => ~s({"parallel_tool_calls":false})
        }
      ]
    }

    assert {:ok, profile} = ProviderProfiles.parse(input, "test")
    assert profile["temperature"] == 0.9
    assert profile["max_tokens"] == 4096
    assert profile["top_p"] == 0.8
    assert profile["provider_options"] == %{"parallel_tool_calls" => true}
    assert [inherited, overridden] = profile["models"]
    assert inherited == %{"model" => "inherited"}

    assert overridden == %{
             "model" => "overridden",
             "temperature" => 0.0,
             "max_tokens" => 2048,
             "top_p" => 0.5,
             "top_k" => 4,
             "frequency_penalty" => -0.2,
             "presence_penalty" => 0.1,
             "extra" => %{"flag" => false},
             "provider_options" => %{"parallel_tool_calls" => false}
           }

    assert {:ok, ^profile} =
             ProviderProfiles.parse(ProviderProfiles.draft(profile), "test", profile)

    # Blank model overrides restore inheritance, never copy provider defaults
    # into the nested row or erase the provider's own generation settings.
    cleared = Map.new(overridden, fn {key, _} -> {key, ""} end) |> Map.put("model", "overridden")

    assert {:ok, updated} =
             ProviderProfiles.parse(%{"models" => [inherited, cleared]}, "test", profile)

    assert updated["models"] == [inherited, %{"model" => "overridden"}]
    assert Map.drop(updated, ["models"]) == Map.drop(profile, ["models"])
  end

  test "nested invalid values fail instead of dropping a malformed override" do
    for {key, value, reason} <- [
          {"max_tokens", "3.5", "numeric_invalid"},
          {"temperature", "hot", "numeric_invalid"},
          {"extra", "[]", "extra_must_be_object"},
          {"provider_options", "{", "invalid_provider_options_json"}
        ] do
      row = %{"model" => "example", key => value}

      assert {:error, ^reason} =
               ProviderProfiles.parse(Map.put(params(), "models", [row]), "test")
    end

    assert {:error, "model_id_empty"} =
             ProviderProfiles.parse(
               Map.put(params(), "models", [%{"temperature" => "0.5"}]),
               "test"
             )
  end

  test "credential env inputs emit only the canonical key, with canonical presence winning" do
    for input <- [
          %{"api_key_env" => " LEGACY_KEY "},
          %{"api_key_env_var" => " LEGACY_KEY "},
          %{"api_key_env_var" => " LEGACY_KEY ", "api_key_env" => "IGNORED"}
        ] do
      assert {:ok, profile} = ProviderProfiles.parse(Map.merge(params(), input), "test")
      assert profile["api_key_env_var"] == "LEGACY_KEY"
      refute Map.has_key?(profile, "api_key_env")
      assert {:ok, ^profile} = ProviderProfiles.parse(%{}, "test", profile)
    end

    original = Map.put(params(), "api_key_env", "OLD_KEY")

    for canonical <- ["", " ", nil] do
      input = %{"api_key_env_var" => canonical, "api_key_env" => "IGNORED"}
      assert {:ok, profile} = ProviderProfiles.parse(input, "test", original)
      refute Map.has_key?(profile, "api_key_env_var")
      refute Map.has_key?(profile, "api_key_env")
    end

    for key <- ["api_key_env", "api_key_env_var"], empty <- ["", " ", nil] do
      saved = Map.put(params(), "api_key_env_var", "SAVED_KEY")
      assert {:ok, profile} = ProviderProfiles.parse(%{key => empty}, "test", saved)
      refute Map.has_key?(profile, "api_key_env_var")
      refute Map.has_key?(profile, "api_key_env")
    end

    assert {:ok, profile} =
             ProviderProfiles.parse(%{"api_key_env" => "NEW_KEY"}, "test", original)

    assert profile["api_key_env_var"] == "NEW_KEY"
    refute Map.has_key?(profile, "api_key_env")
  end

  test "drafts normalize legacy credential env keys without losing blank canonical input" do
    for normalize <- [&ProviderProfiles.draft/1, &ProviderProfiles.normalize_draft/1] do
      draft = normalize.(%{api_key_env: "LEGACY_KEY"})
      assert draft["api_key_env_var"] == "LEGACY_KEY"
      refute Map.has_key?(draft, "api_key_env")

      for canonical <- ["CANONICAL_KEY", "", nil] do
        draft = normalize.(%{"api_key_env_var" => canonical, "api_key_env" => "IGNORED"})
        assert Map.fetch!(draft, "api_key_env_var") == canonical
        refute Map.has_key?(draft, "api_key_env")
      end
    end
  end

  test "OAuth strips API secrets and both env key spellings from submitted and saved fields" do
    for provider <- ["openai_codex", "anthropic"],
        env_fields <- [
          %{"api_key_env" => "LEGACY_KEY"},
          %{"api_key_env_var" => "CANONICAL_KEY"},
          %{"api_key_env" => "LEGACY_KEY", "api_key_env_var" => "CANONICAL_KEY"}
        ] do
      original = params() |> Map.merge(env_fields) |> Map.put("api_key", "saved-secret")
      input = %{"provider" => provider, "auth_mode" => "oauth"}

      for submitted <- [input, Map.merge(original, input)] do
        assert {:ok, profile} = ProviderProfiles.parse(submitted, "test", original)
        assert profile["auth_mode"] == "oauth"
        refute Map.has_key?(profile, "api_key")
        refute Map.has_key?(profile, "api_key_env")
        refute Map.has_key?(profile, "api_key_env_var")
      end
    end
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
    assert updated.llm.providers == [%{"id" => "a"}, %{"id" => "b"}]
    assert updated.llm.default_provider_profile == "a"
    assert updated.llm.tool_result_pruning == false
    assert updated.scheduler == config.scheduler

    empty = ProviderProfiles.put_profiles(updated, [])
    assert empty.llm.providers == []
    refute Map.has_key?(empty.llm, :default_provider_profile)
  end

  test "canonical writes remove both shadow spellings and retain an existing default" do
    profiles = [%{"id" => "a"}, %{"id" => "b"}]

    llm = %{
      :models => [%{id: "old"}],
      "models" => [%{"id" => "other-old"}],
      "providers" => [%{"id" => "stale"}],
      "default_provider_profile" => "b",
      "tool_result_pruning" => false
    }

    config = %{"llm" => llm, "scheduler" => %{"max_turns" => 12}}
    updated = ProviderProfiles.put_profiles(config, profiles)

    refute Map.has_key?(updated, "llm")

    assert updated.llm == %{
             :providers => profiles,
             :default_provider_profile => "b",
             "tool_result_pruning" => false
           }

    assert updated["scheduler"] == config["scheduler"]
    assert ProviderProfiles.put_profiles(updated, profiles) == updated
  end

  test "canonical CRUD preserves order and default identity across rename, move and deletion" do
    profile = fn id ->
      %{
        "id" => id,
        "name" => id,
        "provider" => "openai",
        "auth_mode" => "api_key",
        "concurrency" => 3,
        "default_model" => "example",
        "reasoning_efforts" => [],
        "models" => [%{"model" => "example"}]
      }
    end

    a = profile.("a")
    b = profile.("b")
    c = profile.("c")

    config = %{
      scheduler: %{max_turns: 12},
      llm: %{providers: [a, b], default_provider_profile: "b", tool_result_pruning: false}
    }

    renamed = Map.put(b, "id", "renamed")
    updated = ProviderProfiles.update(config, "b", renamed)
    assert updated.llm.providers == [a, renamed]
    assert updated.llm.default_provider_profile == "renamed"
    assert updated.scheduler == config.scheduler
    assert updated.llm.tool_result_pruning == false
    refute Map.has_key?(updated.llm, :models)
    refute Map.has_key?(updated.llm, "models")

    added = ProviderProfiles.update(updated, nil, c)
    assert added.llm.providers == [a, renamed, c]
    assert added.llm.default_provider_profile == "renamed"
    moved = ProviderProfiles.move(added, "c", "up")
    assert moved.llm.providers == [a, c, renamed]
    assert moved.llm.default_provider_profile == "renamed"
    assert ProviderProfiles.set_default(moved, "a").llm.default_provider_profile == "a"

    for {id, direction} <- [{"a", "up"}, {"renamed", "down"}, {"missing", "up"}] do
      assert ProviderProfiles.move(moved, id, direction) == moved
    end

    assert ProviderProfiles.set_default(moved, "missing") == moved
    assert ProviderProfiles.delete(moved, "missing") == moved
    deleted = ProviderProfiles.delete(moved, "renamed")
    assert deleted.llm.providers == [a, c]
    assert deleted.llm.default_provider_profile == "a"
    assert ProviderProfiles.delete(deleted, "c").llm.providers == [a]
    empty = deleted |> ProviderProfiles.delete("c") |> ProviderProfiles.delete("a")
    assert empty.llm.providers == []
    refute Map.has_key?(empty.llm, :default_provider_profile)
    assert config.llm.providers == [a, b]
  end

  test "legacy read and edit migrate accounts one-for-one without rewriting the input" do
    old = %{
      id: "legacy",
      model: %{provider: :openai, id: "example", base_url: "https://example.test/v1"},
      concurrency: 6,
      temperature: 0.2,
      reasoning_effort: "high"
    }

    config = %{llm: %{models: [old]}, scheduler: %{max_turns: 12}}
    assert [profile] = ProviderProfiles.profiles(config)
    assert profile["id"] == "legacy"
    assert profile["provider"] == "openai"
    assert profile["default_model"] == "example"
    assert profile["base_url"] == "https://example.test/v1"
    assert profile["models"] == [%{"model" => "example"}]
    assert profile["default_reasoning_effort"] == "high"
    assert profile["reasoning_efforts"] == ["high"]
    assert config.llm.models == [old]

    assert {:ok, edited} =
             ProviderProfiles.parse(%{"name" => "Edited"}, "renamed", profile)

    assert edited["concurrency"] == 6
    assert edited["temperature"] == 0.2
    assert edited["models"] == profile["models"]
    assert edited["base_url"] == profile["base_url"]
    refute Map.has_key?(edited, "model")
    refute Map.has_key?(edited, "reasoning_effort")
    saved = ProviderProfiles.update(config, "legacy", edited)
    assert saved.llm.providers == [edited]
    assert saved.llm.default_provider_profile == "renamed"
    refute Map.has_key?(saved.llm, :models)
    assert saved.scheduler == config.scheduler
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
  end

  test "default-only profiles round-trip without manufacturing model overrides" do
    for models <- [%{}, %{"models" => []}] do
      input = Map.merge(models, %{"provider" => "openai", "default_model" => " default "})
      assert {:ok, profile} = ProviderProfiles.parse(input, "test")
      assert profile["default_model"] == "default"
      refute Map.has_key?(profile, "models")
      assert ProviderProfiles.draft(profile)["models"] == []
      assert {:ok, ^profile} = ProviderProfiles.parse(%{}, "test", profile)
    end
  end

  test "models are overrides and do not restrict the default model" do
    input = Map.put(params(), "default_model", "unlisted")
    assert {:ok, profile} = ProviderProfiles.parse(input, "test")
    assert profile["default_model"] == "unlisted"
    assert profile["models"] == [%{"model" => "example"}]

    assert {:error, "default_model_invalid"} =
             ProviderProfiles.parse(%{"provider" => "openai"}, "empty")

    assert {:error, "default_model_invalid"} =
             ProviderProfiles.parse(
               %{"provider" => "openai", "default_model" => " ", "models" => []},
               "empty"
             )
  end

  test "reasoning defaults respect effective inventories, including unrestricted overrides" do
    input = %{
      "provider" => "openai",
      "default_model" => "default",
      "reasoning_efforts" => ["low", "high"],
      "default_reasoning_effort" => "high",
      "models" => [%{"model" => "other", "reasoning_efforts" => ["low"]}]
    }

    assert {:error, "reasoning_default_invalid"} = ProviderProfiles.parse(input, "test")

    restricted = %{"model" => "other", "default_reasoning_effort" => "other"}

    assert {:error, "reasoning_default_invalid"} =
             ProviderProfiles.parse(Map.put(input, "models", [restricted]), "test")

    for unrestricted <- [[], ""] do
      row = Map.put(restricted, "reasoning_efforts", unrestricted)
      assert {:ok, profile} = ProviderProfiles.parse(Map.put(input, "models", [row]), "test")
      assert hd(profile["models"])["reasoning_efforts"] == []
      assert hd(profile["models"])["default_reasoning_effort"] == "other"
    end

    assert {:ok, profile} =
             ProviderProfiles.parse(
               %{
                 "provider" => "openai",
                 "default_model" => "default",
                 "default_reasoning_effort" => "custom"
               },
               "test"
             )

    refute Map.has_key?(profile, "reasoning_efforts")
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
    assert {:error, "default_model_invalid"} = ProviderProfiles.parse(emptied, "test", params())

    default_only = Map.put(draft, "default_model", "keep")

    submitted =
      ProviderProfiles.submission(
        %{"provider" => "openai", "default_model" => "keep"},
        default_only
      )

    assert {:ok, profile} = ProviderProfiles.parse(submitted, "test", params())
    refute Map.has_key?(profile, "models")

    legacy = ProviderProfiles.submission(%{"provider" => "openai", "model_id" => "new"}, draft)
    assert {:ok, %{"models" => [%{"model" => "new"}]}} = ProviderProfiles.parse(legacy, "test")
  end

  test "form changes and row buttons only mutate detached drafts and cancel discards them" do
    config = %{llm: %{providers: [%{"id" => "saved", "default_model" => "example"}]}}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        file_config: config,
        editing_profile_id: "saved",
        profile_form_draft: %{},
        profile_advanced_open: nil
      }
    }

    assert {:noreply, socket} =
             ModelProfileEvents.model_profile_form_change(
               socket,
               %{"default_model" => "typed", "models" => [], "temperature" => "0.7"}
             )

    assert {:noreply, socket} = ModelProfileEvents.add_profile_model(socket, %{})
    assert socket.assigns.profile_form_draft["models"] == [%{"model" => ""}]
    assert socket.assigns.profile_form_draft["default_model"] == "typed"
    assert socket.assigns.file_config == config

    assert {:noreply, ^socket} =
             ModelProfileEvents.remove_profile_model(socket, %{"index" => "-1"})

    assert {:noreply, socket} = ModelProfileEvents.remove_profile_model(socket, %{"index" => "0"})
    assert socket.assigns.profile_form_draft["models"] == []
    assert {:noreply, socket} = ModelProfileEvents.toggle_profile_advanced(socket, %{})
    assert socket.assigns.profile_advanced_open == false
    assert {:noreply, socket} = ModelProfileEvents.cancel_edit_model_profile(socket, %{})
    assert socket.assigns.file_config == config
    assert socket.assigns.profile_form_draft == nil
    assert socket.assigns.profile_advanced_open == nil
    assert socket.assigns.editing_profile_id == nil
  end

  test "advanced auto-open considers nested model overrides" do
    refute ModelProfileEvents.advanced_open?(%{"models" => []})
    assert ModelProfileEvents.advanced_open?(%{"models" => [%{"extra" => "{}"}]})
    refute ModelProfileEvents.advanced_open?(nil)
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
