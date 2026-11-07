defmodule EvoGit.Config.ProviderProfilesTest do
  @moduledoc """
  Pure account normalization and selection enumeration, without resolving credentials
  or mutating global config. Canonical maps are deliberately string-keyed.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config.Schema

  describe "provider_profiles/1" do
    test "canonical accounts take precedence over both legacy inventories" do
      config = %{
        llm: %{
          providers: [%{id: "account", provider: :openai, models: ["first", "second"]}],
          models: [%{id: "stale", model: "anthropic:old"}],
          model: "google:older"
        }
      }

      assert Schema.provider_profiles(config) == [
               %{
                 "id" => "account",
                 "provider" => "openai",
                 "models" => [%{"model" => "first"}, %{"model" => "second"}],
                 "default_model" => "first",
                 "auth_mode" => "api_key",
                 "concurrency" => 3,
                 "reasoning_efforts" => []
               }
             ]
    end

    test "atom, string and mixed-key configs normalize identically, recursively" do
      atom_config = %{
        llm: %{
          providers: [
            %{
              id: "work",
              provider: :openai,
              auth_mode: :api_key,
              reasoning_efforts: [:high, :low],
              default_reasoning_effort: :low,
              provider_options: %{custom: %{enabled: true}},
              models: [%{id: "openai:alpha", context_window: 64_000, temperature: 0.2}]
            }
          ]
        }
      }

      string_config = %{
        "llm" => %{
          "providers" => [
            %{
              "id" => "work",
              "provider" => "openai",
              "auth_mode" => "api_key",
              "reasoning_efforts" => ["high", "low"],
              "default_reasoning_effort" => "low",
              "provider_options" => %{"custom" => %{"enabled" => true}},
              "models" => [
                %{"id" => "openai:alpha", "context_window" => 64_000, "temperature" => 0.2}
              ]
            }
          ]
        }
      }

      assert Schema.provider_profiles(atom_config) == Schema.provider_profiles(string_config)

      assert Schema.provider_profiles(%{"llm" => atom_config.llm}) ==
               Schema.provider_profiles(string_config)

      [profile] = Schema.provider_profiles(atom_config)
      assert profile["provider_options"] == %{"custom" => %{"enabled" => true}}

      assert profile["models"] == [
               %{"model" => "alpha", "context_window" => 64_000, "temperature" => 0.2}
             ]
    end

    test "does not merge accounts sharing provider, endpoint or model" do
      profiles =
        for id <- ["personal", "work"] do
          %{
            id: id,
            provider: "openai",
            api_key_env_var: String.upcase(id) <> "_KEY",
            base_url: "https://accounts.invalid/v1",
            concurrency: if(id == "work", do: 7, else: 2),
            models: ["shared"]
          }
        end

      [personal, work] = Schema.provider_profiles(%{llm: %{providers: profiles}})
      assert personal["id"] == "personal"
      assert work["id"] == "work"
      assert personal["api_key_env_var"] == "PERSONAL_KEY"
      assert work["api_key_env_var"] == "WORK_KEY"
      assert personal["concurrency"] == 2
      assert work["concurrency"] == 7
      assert personal["models"] == work["models"]
    end

    test "strips only the matching provider prefix and preserves explicit model order/default" do
      config = %{
        llm: %{
          providers: [
            %{
              id: "a",
              provider: "openai",
              default_model: "openai:second",
              models: ["openai:first", %{id: "openai:second"}, "other:third"]
            }
          ]
        }
      }

      [profile] = Schema.provider_profiles(config)
      assert profile["default_model"] == "second"

      assert profile["models"] == [
               %{"model" => "first"},
               %{"model" => "second"},
               %{"model" => "other:third"}
             ]
    end

    test "efforts keep first-occurrence order rather than sorting or inventing a default" do
      config = %{
        llm: %{
          providers: [
            %{
              id: "a",
              provider: "openai",
              reasoning_efforts: [:high, "low", :high, nil, "", "medium"],
              models: [%{model: "alpha", reasoning_efforts: [:medium, :low, :medium]}]
            }
          ]
        }
      }

      [profile] = Schema.provider_profiles(config)
      assert profile["reasoning_efforts"] == ["high", "low", "medium"]
      refute Map.has_key?(profile, "default_reasoning_effort")
      assert hd(profile["models"])["reasoning_efforts"] == ["medium", "low"]
      [selection] = Schema.model_selections(config)
      assert selection.default_reasoning_effort == nil
    end

    test "normalizes explicit and OAuth-only auth without importing a credential file" do
      config = %{
        llm: %{
          providers: [
            %{id: "api", provider: "anthropic", models: ["alpha"]},
            %{id: "sub", provider: :anthropic, auth_mode: :oauth, models: ["alpha"]},
            %{id: "codex", provider: :openai_codex, models: ["alpha"]}
          ]
        }
      }

      assert Enum.map(Schema.provider_profiles(config), & &1["auth_mode"]) ==
               ["api_key", "oauth", "oauth"]

      assert Enum.map(Schema.model_profiles(config), & &1.auth_mode) ==
               ["api_key", "oauth", "oauth"]
    end

    test "runtime default projections inherit each OAuth account's own file and concurrency" do
      config = %{
        llm: %{
          default_provider_profile: "second",
          providers: [
            %{
              id: "first",
              provider: "openai_codex",
              oauth_file: "first.json",
              concurrency: 2,
              default_model: "beta",
              models: ["alpha", "beta"]
            },
            %{
              id: "second",
              provider: "openai_codex",
              oauth_file: "second.json",
              concurrency: 7,
              models: [%{model: "alpha", context_window: 48_000}]
            }
          ]
        }
      }

      [first, second] = Schema.model_profiles(config)

      assert {first.id, first.model, first.auth_mode, first.oauth_file, first.concurrency} ==
               {"first", "openai_codex:beta", "oauth", "first.json", 2}

      assert {second.id, second.model, second.auth_mode, second.oauth_file, second.concurrency} ==
               {"second", "openai_codex:alpha", "oauth", "second.json", 7}

      assert second.context_window == 48_000
      assert Schema.default_model_profile(config) == {:ok, second}
      assert Schema.get_model_profile(config, "first") == {:ok, first}
      assert Schema.effective_model_profiles(config) == [first, second]
    end

    test "legacy models migrate one-for-one before flat keys, retaining account settings" do
      config = %{
        llm: %{
          providers: [],
          model: "google:stale",
          models: [
            %{
              id: "first",
              model: "openai:alpha",
              concurrency: 5,
              context_window: 32_000,
              reasoning_effort: :high,
              temperature: 0.4,
              api_key_env_var: "FIRST_KEY"
            },
            %{id: "second", model: "openai:alpha", auth_mode: "oauth", oauth_file: "own.json"}
          ]
        }
      }

      [first, second] = Schema.provider_profiles(config)
      assert first["id"] == "first"
      assert first["provider"] == "openai"
      assert first["default_model"] == "alpha"
      assert first["models"] == [%{"model" => "alpha"}]
      assert first["reasoning_efforts"] == ["high"]
      assert first["default_reasoning_effort"] == "high"
      assert first["concurrency"] == 5
      assert first["context_window"] == 32_000
      assert first["temperature"] == 0.4
      assert first["api_key_env_var"] == "FIRST_KEY"
      assert second["id"] == "second"
      assert second["oauth_file"] == "own.json"
      assert second["auth_mode"] == "oauth"
    end

    test "legacy map and tuple specs retain endpoint/extra/account overrides" do
      for model <- [
            %{provider: :openai, id: "alpha", base_url: "https://api.invalid", extra: %{x: 1}},
            {:openai, [id: "alpha", base_url: "https://api.invalid", extra: %{x: 1}]}
          ] do
        config = %{llm: %{models: [%{id: "legacy", model: model}]}}
        [profile] = Schema.provider_profiles(config)
        assert profile["provider"] == "openai"
        assert profile["models"] == [%{"model" => "alpha"}]
        assert profile["base_url"] == "https://api.invalid"
        assert profile["extra"] == %{"x" => 1}
      end
    end

    test "flat model becomes default account using scheduler concurrency unless overridden" do
      for {llm, expected} <- [
            {%{model: "openai:alpha"}, 9},
            {%{model: "openai:alpha", concurrency: 4}, 4}
          ] do
        [profile] =
          Schema.provider_profiles(%{llm: llm, scheduler: %{default_llm_max_concurrency: 9}})

        assert profile["id"] == "default"
        assert profile["concurrency"] == expected
        assert profile["default_model"] == "alpha"
      end
    end

    test "absent and malformed config has no phantom accounts or selections" do
      for config <- [nil, [], "bad", %{}, %{llm: nil}, %{llm: "bad"}, %{llm: %{}}] do
        assert Schema.provider_profiles(config) == []
        assert Schema.model_selections(config) == []
      end
    end

    test "nonempty invalid canonical inventory never falls back to stale legacy data" do
      for providers <- [[nil], [%{id: "broken"}], [%{provider: "openai"}]] do
        config = %{
          llm: %{
            providers: providers,
            models: [%{id: "legacy", model: "openai:alpha"}],
            model: "openai:flat"
          }
        }

        assert Schema.provider_profiles(config) == []
        assert Schema.model_selections(config) == []

        assert Schema.resolve_model_spec(config, nil) ==
                 {:error, {:provider_profile_not_found, nil}}
      end
    end
  end

  describe "model_selections/1" do
    test "one row per model, not effort, preserves account/model/effort order and display name" do
      config = %{
        llm: %{
          providers: [
            %{
              id: "z",
              name: "Work account",
              provider: "openai",
              context_window: 80_000,
              reasoning_efforts: ["high", "low"],
              default_reasoning_effort: "low",
              models: [
                "beta",
                %{
                  model: "alpha",
                  context_window: 40_000,
                  reasoning_efforts: ["medium", "high"],
                  default_reasoning_effort: "medium"
                }
              ]
            },
            %{id: "a", provider: "openai", models: ["beta"]}
          ]
        }
      }

      assert Schema.model_selections(config) == [
               %{
                 provider_profile_id: "z",
                 profile_name: "Work account",
                 provider: "openai",
                 model: "beta",
                 reasoning_efforts: ["high", "low"],
                 default_reasoning_effort: "low",
                 context_window: 80_000
               },
               %{
                 provider_profile_id: "z",
                 profile_name: "Work account",
                 provider: "openai",
                 model: "alpha",
                 reasoning_efforts: ["medium", "high"],
                 default_reasoning_effort: "medium",
                 context_window: 40_000
               },
               %{
                 provider_profile_id: "a",
                 profile_name: "a",
                 provider: "openai",
                 model: "beta",
                 reasoning_efforts: [],
                 default_reasoning_effort: nil,
                 context_window: 200_000
               }
             ]
    end

    test "empty model inventory gives no selection and no invented default model" do
      config = %{llm: %{providers: [%{id: "a", provider: "openai", models: []}]}}
      assert Schema.model_selections(config) == []
      assert [%{"default_model" => nil, "models" => []}] = Schema.provider_profiles(config)
      assert Schema.resolve_model_spec(config, nil) == {:error, {:model_not_found, "a", nil}}
    end
  end
end
