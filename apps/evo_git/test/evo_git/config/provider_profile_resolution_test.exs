defmodule EvoGit.Config.ProviderProfileResolutionTest do
  @moduledoc """
  Public Schema resolver contracts, using catalog-absent test model ids so metadata
  cannot change the asserted generation defaults. Config/credential files are
  per-process isolated; no app-env or OS-env writes, scheduler or LLM requests.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config.Schema
  alias EvoGit.TestSupport.ConfigDir

  @alpha "genesis-schema-test-alpha"
  @beta "genesis-schema-test-beta"

  setup do
    ConfigDir.isolate!("provider_resolution")
    dir = EvoGit.Config.config_dir()
    File.mkdir_p!(dir)
    {:ok, config_dir: dir}
  end

  defp account(id, overrides \\ %{}) do
    Map.merge(%{id: id, provider: "openai", models: [@alpha, @beta]}, overrides)
  end

  defp config(profiles, llm \\ %{}), do: %{llm: Map.put(llm, :providers, profiles)}

  defp resolve!(config, spec) do
    assert {:ok, resolved} = Schema.resolve_model_spec(config, spec)
    resolved
  end

  describe "account and model precedence" do
    test "nil and empty-map selections use first account and first model when defaults absent" do
      config = config([account("first"), account("second")])

      for spec <- [nil, %{}] do
        resolved = resolve!(config, spec)
        assert resolved.provider_profile_id == "first"
        assert resolved.model == @alpha
        assert resolved.model_spec == "openai:" <> @alpha
        assert resolved.reasoning_effort == nil
        assert resolved.default_reasoning_effort == nil
        assert resolved.reasoning_efforts == []
        assert resolved.context_window == 200_000
        assert resolved.concurrency == 3
        assert resolved.generation_params == [provider_options: [store: false]]
      end
    end

    test "explicit default account and default model win, and request overrides both" do
      config =
        config([account("first"), account("second", %{default_model: @beta})], %{
          default_provider_profile: "second"
        })

      default = resolve!(config, nil)
      assert {default.provider_profile_id, default.model} == {"second", @beta}
      assert resolve!(config, "first").model == @alpha

      for spec <- [
            %{provider_profile_id: "first", model: @beta},
            %{"provider_profile_id" => "first", "model" => "openai:" <> @beta}
          ] do
        resolved = resolve!(config, spec)
        assert {resolved.provider_profile_id, resolved.model} == {"first", @beta}
        assert resolved.model_spec == "openai:" <> @beta
      end
    end

    test "map without account uses configured account while overriding its model" do
      config = config([account("a"), account("b")], %{default_provider_profile: "b"})
      resolved = resolve!(config, %{model: @beta})
      assert {resolved.provider_profile_id, resolved.model} == {"b", @beta}
    end

    test "invalid explicit defaults and requests never silently use first account/model" do
      config = config([account("first")], %{default_provider_profile: "missing"})

      assert Schema.resolve_model_spec(config, nil) ==
               {:error, {:provider_profile_not_found, "missing"}}

      assert resolve!(config, "first").provider_profile_id == "first"
      config = config([account("first", %{default_model: "missing"})])

      assert Schema.resolve_model_spec(config, nil) ==
               {:error, {:model_not_found, "first", "missing"}}

      assert resolve!(config, %{model: @alpha}).model == @alpha
    end

    test "string-keyed config and selection resolve identically to atom-keyed inputs" do
      config =
        config([
          account("a", %{
            context_window: 90_000,
            max_tokens: 512,
            reasoning_efforts: ["high", "low"],
            default_reasoning_effort: "low"
          })
        ])

      spec = %{provider_profile_id: "a", model: @beta, reasoning_effort: "high"}
      string_config = config |> Jason.encode!() |> Jason.decode!()
      string_spec = spec |> Jason.encode!() |> Jason.decode!()

      assert Schema.resolve_model_spec(config, spec) ==
               Schema.resolve_model_spec(string_config, string_spec)
    end

    test "legacy id and flat default account are still resolvable" do
      legacy = %{
        llm: %{
          models: [
            %{id: "old", model: "openai:" <> @alpha, reasoning_effort: "high"},
            %{id: "other", model: "openai:" <> @beta}
          ],
          default_provider_profile: "other"
        }
      }

      assert resolve!(legacy, nil).model == @beta
      old = resolve!(legacy, "old")
      assert old.provider_profile_id == "old"
      assert old.model_spec == "openai:" <> @alpha
      assert old.reasoning_effort == "high"
      assert old.generation_params[:reasoning_effort] == :high

      flat = %{llm: %{model: "openai:" <> @alpha}, scheduler: %{default_llm_max_concurrency: 8}}
      assert resolve!(flat, nil).concurrency == 8
      assert resolve!(flat, "default").model_spec == "openai:" <> @alpha
    end

    test "canonical selection ignores stale legacy model and generation settings" do
      config = config([account("a")], %{model: "anthropic:stale", temperature: 1.7})
      resolved = resolve!(config, nil)
      assert resolved.model_spec == "openai:" <> @alpha
      refute Keyword.has_key?(resolved.generation_params, :temperature)

      assert Schema.resolve_model_spec(config, "default") ==
               {:error, {:provider_profile_not_found, "default"}}
    end
  end

  describe "effort selection" do
    test "ordered inventory alone never invents a default effort" do
      config = config([account("a", %{reasoning_efforts: ["high", "low"]})])
      resolved = resolve!(config, nil)
      assert resolved.reasoning_efforts == ["high", "low"]
      assert resolved.reasoning_effort == nil
      refute Keyword.has_key?(resolved.generation_params, :reasoning_effort)
    end

    test "request beats model default/legacy effort, which beat provider defaults" do
      for {model_fields, provider_fields, expected} <- [
            {%{}, %{default_reasoning_effort: "low", reasoning_effort: "high"}, "low"},
            {%{}, %{reasoning_effort: "high"}, "high"},
            {%{reasoning_effort: "medium"}, %{default_reasoning_effort: "low"}, "medium"},
            {%{default_reasoning_effort: "high", reasoning_effort: "medium"},
             %{default_reasoning_effort: "low"}, "high"}
          ] do
        profile =
          account(
            "a",
            Map.merge(provider_fields, %{models: [Map.put(model_fields, :model, @alpha)]})
          )

        config = config([profile])
        resolved = resolve!(config, nil)
        assert resolved.default_reasoning_effort == expected
        assert resolved.reasoning_effort == expected
        assert resolved.generation_params[:reasoning_effort] == String.to_existing_atom(expected)

        requested = resolve!(config, %{reasoning_effort: :minimal})
        assert requested.default_reasoning_effort == expected
        assert requested.reasoning_effort == "minimal"
        assert requested.generation_params[:reasoning_effort] == :minimal
      end
    end

    test "model effort inventory replaces provider inventory, including an explicit empty list" do
      for {efforts, requested, expected} <- [
            {["medium", "low"], "medium", {:ok, "medium"}},
            {["medium", "low"], "high",
             {:error, {:unsupported_reasoning_effort, "high", ["medium", "low"]}}},
            {[], "xhigh", {:ok, "xhigh"}}
          ] do
        config =
          config([
            account("a", %{
              reasoning_efforts: ["high", "low"],
              models: [%{model: @alpha, reasoning_efforts: efforts}]
            })
          ])

        spec = %{reasoning_effort: requested}

        case expected do
          {:ok, effort} ->
            resolved = resolve!(config, spec)
            assert resolved.reasoning_effort == effort
            assert resolved.reasoning_efforts == efforts

          {:error, _} = error ->
            assert Schema.resolve_model_spec(config, spec) == error
        end
      end
    end

    test "unsupported inherited default is an error, not a replacement with first allowed effort" do
      config =
        config([
          account("a", %{
            default_reasoning_effort: "high",
            models: [%{model: @alpha, reasoning_efforts: ["low", "medium"]}]
          })
        ])

      assert Schema.resolve_model_spec(config, nil) ==
               {:error, {:unsupported_reasoning_effort, "high", ["low", "medium"]}}

      assert resolve!(config, %{reasoning_effort: "low"}).reasoning_effort == "low"
    end

    test "nil request effort uses default; invalid effort values fail explicitly" do
      config = config([account("a", %{default_reasoning_effort: "low"})])
      assert resolve!(config, %{reasoning_effort: nil}).reasoning_effort == "low"

      for invalid <- ["", 7, [], %{}] do
        assert Schema.resolve_model_spec(config, %{reasoning_effort: invalid}) ==
                 {:error, {:invalid_reasoning_effort, invalid}}
      end
    end
  end

  describe "runtime and generation inheritance" do
    test "model overrides generation and context but inherits all shared scheduling fields" do
      schedule = %{
        concurrency: 6,
        peak_concurrency: 0,
        peak_hours: [%{start: "09:00", end: "17:00", days: ["weekdays"]}],
        off_peak_days: ["sun"],
        timezone: "Asia/Hong_Kong"
      }

      profile =
        account(
          "a",
          Map.merge(schedule, %{
            context_window: 80_000,
            temperature: 0.8,
            max_tokens: 4096,
            top_p: 0.9,
            top_k: 40,
            frequency_penalty: 0.3,
            presence_penalty: 0.4,
            provider_options: %{shared: true},
            models: [
              @alpha,
              %{
                model: @beta,
                context_window: 32_000,
                temperature: 0.0,
                max_tokens: 1024,
                top_p: 0.5,
                top_k: 10,
                frequency_penalty: 0.0,
                presence_penalty: 0.0,
                provider_options: %{model_only: true}
              }
            ]
          })
        )

      config = config([profile])
      first = resolve!(config, nil)
      second = resolve!(config, %{model: @beta})
      assert first.context_window == 80_000
      assert second.context_window == 32_000

      assert first.generation_params |> Map.new() == %{
               temperature: 0.8,
               max_tokens: 4096,
               top_p: 0.9,
               top_k: 40,
               frequency_penalty: 0.3,
               presence_penalty: 0.4,
               provider_options: [shared: true]
             }

      assert second.generation_params |> Map.new() == %{
               temperature: 0.0,
               max_tokens: 1024,
               top_p: 0.5,
               top_k: 10,
               frequency_penalty: 0.0,
               presence_penalty: 0.0,
               provider_options: [model_only: true]
             }

      for resolved <- [first, second] do
        assert Map.take(resolved, Map.keys(schedule)) == %{
                 concurrency: 6,
                 peak_concurrency: 0,
                 peak_hours: [%{"start" => "09:00", "end" => "17:00", "days" => ["weekdays"]}],
                 off_peak_days: ["sun"],
                 timezone: "Asia/Hong_Kong"
               }

        assert resolved.runtime_profile.id == "a"
        assert resolved.runtime_profile.context_window == resolved.context_window
        assert resolved.runtime_profile.model == resolved.model_spec
      end
    end

    test "nil model overrides inherit provider values; zero generation values remain explicit" do
      config =
        config([
          account("a", %{
            context_window: 70_000,
            temperature: 0.8,
            max_tokens: 2048,
            models: [%{model: @alpha, context_window: nil, temperature: nil, max_tokens: nil}]
          })
        ])

      resolved = resolve!(config, nil)
      assert resolved.context_window == 70_000
      assert resolved.generation_params[:temperature] == 0.8
      assert resolved.generation_params[:max_tokens] == 2048
    end

    test "endpoint/extra overrides produce a ReqLLM map, never a persisted task selection map" do
      config =
        config([
          account("a", %{
            base_url: "https://api.invalid/v1",
            extra: %{headers: %{"x-test" => "yes"}}
          })
        ])

      resolved = resolve!(config, %{provider_profile_id: "a", model: @beta})

      assert resolved.model_spec == %{
               provider: :openai,
               id: @beta,
               base_url: "https://api.invalid/v1",
               extra: %{headers: %{"x-test" => "yes"}}
             }

      refute Map.has_key?(resolved.model_spec, :provider_profile_id)
      refute Keyword.has_key?(resolved.generation_params, :provider_options)
    end

    test "per-account API credentials and concurrency do not bleed between same-provider accounts",
         %{config_dir: dir} do
      suffix = System.unique_integer([:positive])
      key_a = "GENESIS_SCHEMA_ACCOUNT_A_#{suffix}"
      key_b = "GENESIS_SCHEMA_ACCOUNT_B_#{suffix}"
      # Unknown credential names do not update ReqLLM's global provider key store.
      File.write!(
        Path.join(dir, "credentials.toml"),
        "#{key_a} = \"a-secret\"\n#{key_b} = \"b-secret\"\n"
      )

      config =
        config([
          account("a", %{api_key_env_var: key_a, concurrency: 2}),
          account("b", %{api_key_env_var: key_b, concurrency: 7})
        ])

      for {id, key, secret, concurrency} <- [
            {"a", key_a, "a-secret", 2},
            {"b", key_b, "b-secret", 7}
          ],
          model <- [@alpha, @beta] do
        resolved = resolve!(config, %{provider_profile_id: id, model: model})
        assert resolved.runtime_profile.api_key_env_var == key
        assert resolved.generation_params[:api_key] == secret
        assert resolved.concurrency == concurrency
        assert resolved.provider_profile["id"] == id
      end
    end

    test "nested models cannot replace shared API account auth or scheduling", %{config_dir: dir} do
      key = "GENESIS_SCHEMA_SHARED_#{System.unique_integer([:positive])}"
      File.write!(Path.join(dir, "credentials.toml"), "#{key} = \"shared-secret\"\n")

      config =
        config([
          account("a", %{
            api_key_env_var: key,
            auth_mode: "api_key",
            concurrency: 5,
            base_url: "https://shared.invalid",
            models: [
              %{
                model: @alpha,
                api_key_env_var: "NESTED_KEY",
                auth_mode: "oauth",
                oauth_file: "nested.json",
                concurrency: 99,
                base_url: "https://nested.invalid"
              }
            ]
          })
        ])

      resolved = resolve!(config, nil)
      assert resolved.runtime_profile.auth_mode == "api_key"
      assert resolved.runtime_profile.api_key_env_var == key
      assert resolved.generation_params[:api_key] == "shared-secret"
      assert resolved.concurrency == 5
      assert resolved.model_spec.base_url == "https://shared.invalid"
      refute Map.has_key?(resolved.runtime_profile, :oauth_file)
      refute Keyword.has_key?(resolved.generation_params, :provider_options)
    end

    test "nonempty environment credential wins over persisted credential without global env writes",
         %{config_dir: dir} do
      # PATH is already present on every host running Mix. Read it only; never
      # mutate a process-wide environment variable from an async test.
      path = System.fetch_env!("PATH")
      assert path != ""
      File.write!(Path.join(dir, "credentials.toml"), "PATH = \"persisted-fallback\"\n")
      resolved = resolve!(config([account("a", %{api_key_env_var: "PATH"})]), nil)
      assert resolved.generation_params[:api_key] == path
    end

    test "missing custom account credential fails closed rather than selecting provider-wide key" do
      key = "GENESIS_SCHEMA_MISSING_#{System.unique_integer([:positive])}"
      resolved = resolve!(config([account("a", %{api_key_env_var: key})]), nil)
      assert resolved.generation_params[:api_key] == ""
    end

    test "OAuth mode and file are shared by every model and survive model generation overrides",
         %{config_dir: dir} do
      oauth_file = Path.join(dir, "account-auth.json")
      # An uncatalogued provider exercises OAuth option assembly without reading a
      # developer's vendor CLI login or writing imported credentials to disk.
      config =
        config([
          account("sub", %{
            provider: "schema_test_oauth",
            auth_mode: "oauth",
            oauth_file: oauth_file,
            api_key_env_var: "UNUSED_FOR_OAUTH",
            models: [@alpha, %{model: @beta, temperature: 0.2, provider_options: %{custom: true}}]
          })
        ])

      for model <- [@alpha, @beta] do
        resolved = resolve!(config, %{model: model})
        assert resolved.runtime_profile.auth_mode == "oauth"
        assert resolved.runtime_profile.oauth_file == oauth_file
        opts = resolved.generation_params[:provider_options]
        assert opts[:auth_mode] == :oauth
        assert opts[:oauth_file] == oauth_file
        refute Keyword.has_key?(resolved.generation_params, :api_key)
        if model == @beta, do: assert(opts[:custom] == true)
      end

      refute File.exists?(oauth_file)
    end
  end

  describe "errors" do
    test "malformed config/spec, unknown ids and duplicate identities have precise errors" do
      config = config([account("a")])

      for invalid <- [nil, [], "bad", 42] do
        assert Schema.resolve_model_spec(invalid, nil) == {:error, :invalid_config}
      end

      for invalid <- ["", 42, [], {:openai, []}] do
        assert Schema.resolve_model_spec(config, invalid) == {:error, :invalid_model_spec}
      end

      assert Schema.resolve_model_spec(%{}, nil) == {:error, {:provider_profile_not_found, nil}}

      assert Schema.resolve_model_spec(config, "missing") ==
               {:error, {:provider_profile_not_found, "missing"}}

      assert Schema.resolve_model_spec(config, %{model: "missing"}) ==
               {:error, {:model_not_found, "a", "missing"}}

      assert Schema.resolve_model_spec(config([account("a"), account("a")]), nil) ==
               {:error, {:duplicate_provider_profile_id, "a"}}

      duplicate = config([account("a", %{models: [@alpha, "openai:" <> @alpha]})])

      assert Schema.resolve_model_spec(duplicate, nil) ==
               {:error, {:duplicate_model, "a", @alpha}}
    end
  end
end
