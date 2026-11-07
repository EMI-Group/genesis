defmodule EvoGit.CLI.SetupTest do
  # Account helper/save/load tests use per-process config isolation, never the
  # global scheduler or environment. Vendor probes use explicit temporary homes;
  # OAuth resolution/import and network requests are deliberately not exercised.
  use ExUnit.Case, async: true

  alias EvoGit.CLI.Setup
  alias EvoGit.Config
  alias EvoGit.Config.{LLMCatalog, Schema}
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("evogit_setup_test")
    :ok
  end

  @codex_spec %{provider: :openai_codex, id: "gpt-6.1-sol"}
  @anthropic_spec %{provider: :anthropic, id: "claude-sonnet-5-5"}

  describe "resolve_auth_choice/2 (dual-mode provider)" do
    test "defaults to api_key on empty input — never defaults INTO oauth" do
      assert Setup.resolve_auth_choice(:anthropic, "") == :api_key
    end

    test "keeps api_key for option 1 and for invalid input" do
      assert Setup.resolve_auth_choice(:anthropic, "1") == :api_key
      assert Setup.resolve_auth_choice(:anthropic, "3") == :api_key
      assert Setup.resolve_auth_choice(:anthropic, "bogus") == :api_key
      assert Setup.resolve_auth_choice(:anthropic, nil) == :api_key
    end

    test "picks oauth for option 2, case-insensitively and trimmed" do
      for answer <- ["2", "oauth", "OAuth", " subscription "] do
        assert Setup.resolve_auth_choice(:anthropic, answer) == :oauth
      end
    end
  end

  describe "resolve_auth_choice/2 (oauth-only provider)" do
    test "openai_codex is oauth-only and skips the question" do
      assert LLMCatalog.oauth_only?(:openai_codex)
      assert LLMCatalog.auth_modes(:openai_codex) == [:oauth]

      # No answer (the question is never asked) still lands on oauth.
      assert Setup.resolve_auth_choice(:openai_codex, "") == :oauth
      assert Setup.resolve_auth_choice(:openai_codex, nil) == :oauth
      assert Setup.resolve_auth_choice(:openai_codex, "1") == :oauth
    end

    test "anthropic is dual-mode, not oauth-only" do
      assert LLMCatalog.supports_oauth?(:anthropic)
      refute LLMCatalog.oauth_only?(:anthropic)
    end
  end

  describe "resolve_auth_choice/2 (api-key-only provider)" do
    test "never resolves to oauth even for an explicit option 2" do
      refute LLMCatalog.supports_oauth?(:openai)
      assert Setup.resolve_auth_choice(:openai, "2") == :api_key
      assert Setup.resolve_auth_choice(:deepseek, "oauth") == :api_key
    end

    test "non-atom provider falls back to api_key" do
      assert Setup.resolve_auth_choice("anthropic", "2") == :api_key
    end
  end

  describe "apply_auth_mode/2" do
    test "sets auth_mode for the oauth branch" do
      assert Setup.apply_auth_mode(%{id: "default"}, "oauth") == %{
               id: "default",
               auth_mode: "oauth"
             }
    end

    test "removes a stale auth_mode (atom and string spellings) for the api_key branch" do
      assert Setup.apply_auth_mode(%{id: "default", auth_mode: "oauth"}, nil) == %{id: "default"}

      assert Setup.apply_auth_mode(%{"id" => "default", "auth_mode" => "oauth"}, nil) == %{
               "id" => "default"
             }
    end

    test "is idempotent for a profile that never carried an auth mode" do
      assert Setup.apply_auth_mode(%{id: "default", concurrency: 3}, nil) == %{
               id: "default",
               concurrency: 3
             }
    end
  end

  describe "canonical provider account creation" do
    test "creates one default OAuth account with an unqualified nested model" do
      for config <- [%{}, %{llm: %{models: []}}, %{llm: %{providers: []}}] do
        result = Setup.do_add_model_profile(config, @codex_spec, "oauth")

        assert result == %{
                 llm: %{
                   default_provider_profile: "default",
                   providers: [
                     %{
                       id: "default",
                       provider: "openai_codex",
                       concurrency: 3,
                       auth_mode: "oauth",
                       reasoning_efforts: [],
                       default_model: @codex_spec.id,
                       models: [%{model: @codex_spec.id}]
                     }
                   ]
                 }
               }

        assert {:ok, _} = Schema.validate(result)
      end
    end

    test "the two-arity helper defaults to API-key auth without persisting a nil auth mode" do
      result = Setup.do_add_model_profile(%{}, "anthropic:test-model")

      assert result == %{
               llm: %{
                 default_provider_profile: "default",
                 providers: [
                   %{
                     id: "default",
                     provider: "anthropic",
                     concurrency: 3,
                     reasoning_efforts: [],
                     default_model: "test-model",
                     models: [%{model: "test-model"}]
                   }
                 ]
               }
             }

      assert {:ok, _} = Schema.validate(result)
      assert [profile] = Schema.provider_profiles(result)
      assert profile["auth_mode"] == "api_key"
    end

    test "a map spec stores endpoint overrides at account scope, not on its model" do
      spec = Map.merge(@anthropic_spec, %{base_url: "https://proxy.example/v1"})
      result = Setup.do_prepare_config(%{}, spec, nil)
      assert [profile] = result.llm.providers
      assert profile.base_url == spec.base_url
      assert profile.provider == "anthropic"
      assert profile.default_model == spec.id
      assert profile.models == [%{model: spec.id}]
      refute Map.has_key?(profile, :model)
      assert {:ok, _} = Schema.validate(result)
    end
  end

  describe "updating the selected account" do
    test "preserves shared settings and existing model overrides when appending a model" do
      profile = account()
      config = %{llm: %{default_provider_profile: profile.id, providers: [profile]}}
      result = Setup.do_add_model_profile(config, @anthropic_spec, "oauth")

      assert result.llm.default_provider_profile == profile.id

      assert result.llm.providers == [
               %{profile | default_model: @anthropic_spec.id, auth_mode: "oauth"}
               |> Map.put(:models, profile.models ++ [%{model: @anthropic_spec.id}])
             ]

      assert {:ok, _} = Schema.validate(result)
    end

    test "selecting an existing model keeps its position and overrides without duplication" do
      profile = account()
      config = %{llm: %{default_provider_profile: profile.id, providers: [profile]}}
      spec = %{provider: :anthropic, id: "review-model"}
      result = Setup.do_prepare_config(config, spec, "oauth")

      assert result.llm.providers == [%{profile | default_model: spec.id, auth_mode: "oauth"}]
      assert Setup.do_prepare_config(result, spec, "oauth") == result
    end

    test "switching a dual-mode account to API key clears OAuth mode but preserves its settings" do
      profile = %{account() | auth_mode: "oauth"}
      config = %{llm: %{default_provider_profile: profile.id, providers: [profile]}}
      result = Setup.do_add_model_profile(config, "anthropic:review-model", nil)

      assert result.llm.providers == [
               profile |> Map.delete(:auth_mode) |> Map.put(:default_model, "review-model")
             ]

      assert [normalized] = Schema.provider_profiles(result)
      assert normalized["auth_mode"] == "api_key"
      assert normalized["oauth_file"] == profile.oauth_file
      assert normalized["api_key_env_var"] == profile.api_key_env_var
    end

    test "updates the explicitly selected account even when another account has the same provider" do
      first = %{account() | id: "first", concurrency: 2}
      selected = %{account() | id: "selected", concurrency: 7}

      config = %{
        llm: %{default_provider_profile: "selected", providers: [first, selected]},
        scheduler: %{max_turns: 23}
      }

      result = Setup.do_prepare_config(config, @anthropic_spec, "oauth")
      assert [untouched, updated] = result.llm.providers
      assert untouched == first
      assert updated.id == "selected"
      assert updated.concurrency == 7
      assert updated.models == selected.models ++ [%{model: @anthropic_spec.id}]
      assert result.llm.default_provider_profile == "selected"
      assert result.scheduler == config.scheduler
    end

    test "without an explicit selector the first account wins, not an account named default" do
      first = %{account() | id: "first"}
      named_default = %{account() | id: "default"}
      config = %{llm: %{providers: [first, named_default]}}
      result = Setup.do_prepare_config(config, @anthropic_spec, "oauth")

      assert result.llm.default_provider_profile == "first"
      assert [updated, ^named_default] = result.llm.providers
      assert updated.id == "first"
      assert updated.default_model == @anthropic_spec.id
    end
  end

  describe "choosing a different provider" do
    test "appends a new account without overwriting the selected account's auth or limits" do
      original = %{account() | auth_mode: "oauth"}
      config = %{llm: %{default_provider_profile: original.id, providers: [original]}}
      result = Setup.do_prepare_config(config, @codex_spec, "oauth")

      assert [^original, added] = result.llm.providers
      assert result.llm.default_provider_profile == "openai_codex"

      assert added == %{
               id: "openai_codex",
               provider: "openai_codex",
               concurrency: 3,
               auth_mode: "oauth",
               reasoning_efforts: [],
               default_model: @codex_spec.id,
               models: [%{model: @codex_spec.id}]
             }

      assert {:ok, _} = Schema.validate(result)
    end

    test "a new API-key account cannot clear the previous provider's OAuth mode" do
      config = Setup.do_prepare_config(%{}, @codex_spec, "oauth")
      assert [original] = config.llm.providers
      result = Setup.do_prepare_config(config, @anthropic_spec, nil)

      assert [^original, added] = result.llm.providers
      assert result.llm.default_provider_profile == "anthropic"
      assert added.provider == "anthropic"
      refute Map.has_key?(added, :auth_mode)
      assert added.models == [%{model: @anthropic_spec.id}]
    end

    test "allocates an unused account id without merging into a non-selected account" do
      selected = account()
      codex = Setup.do_prepare_config(%{}, @codex_spec, "oauth").llm.providers |> hd()
      occupied = [%{codex | id: "openai_codex"}, %{codex | id: "openai_codex-2"}]

      config = %{
        llm: %{default_provider_profile: selected.id, providers: [selected | occupied]}
      }

      result = Setup.do_prepare_config(config, @codex_spec, "oauth")
      assert Enum.take(result.llm.providers, 3) == config.llm.providers
      assert List.last(result.llm.providers).id == "openai_codex-3"
      assert result.llm.default_provider_profile == "openai_codex-3"
      assert {:ok, _} = Schema.validate(result)
    end
  end

  describe "vendor login probing" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "evogit_setup_test_#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, dir: dir}
    end

    test "reports a missing and then a present Codex CLI login", %{dir: dir} do
      refute Setup.oauth_available?(:openai_codex, codex_home: dir)
      assert Setup.find_vendor_login(:openai_codex, codex_home: dir) == nil

      auth_file = Path.join(dir, "auth.json")
      File.write!(auth_file, ~s({"auth_mode":"chatgpt"}))

      assert Setup.find_vendor_login(:openai_codex, codex_home: dir) == auth_file
      assert Setup.oauth_available?(:openai_codex, codex_home: dir)
    end

    test "reports a missing and then a present Claude Code login", %{dir: dir} do
      refute Setup.oauth_available?(:anthropic, home: dir)

      claude_dir = Path.join(dir, ".claude")
      File.mkdir_p!(claude_dir)
      creds = Path.join(claude_dir, ".credentials.json")
      File.write!(creds, "{}")

      assert Setup.find_vendor_login(:anthropic, home: dir) == creds
    end

    test "providers with no OAuth source never report a login", %{dir: dir} do
      assert Setup.find_vendor_login(:deepseek, home: dir) == nil
      refute Setup.oauth_available?(:openai, home: dir, codex_home: dir)
    end
  end

  describe "do_prepare_config/3 with decoded TOML and legacy input" do
    test "recurses through string-keyed accounts and model maps, clearing stale OAuth mode" do
      profile = %{account() | auth_mode: "oauth"}
      config = %{llm: %{default_provider_profile: profile.id, providers: [profile]}}
      assert {:ok, toml} = TomlElixir.encode(stringify(config))
      assert {:ok, decoded} = TomlElixir.decode(toml)

      result = Setup.do_prepare_config(decoded, %{provider: :anthropic, id: "review-model"}, nil)

      assert result == %{
               llm: %{
                 default_provider_profile: profile.id,
                 providers: [
                   profile |> Map.delete(:auth_mode) |> Map.put(:default_model, "review-model")
                 ]
               }
             }

      assert {:ok, _} = Schema.validate(result)
    end

    test "migrates a string-keyed legacy profile once and keeps its account id and limits" do
      config = %{
        "llm" => %{
          "models" => [
            %{
              "id" => "team",
              "model" => %{"provider" => "anthropic", "id" => "old-model"},
              "concurrency" => 5,
              "auth_mode" => "oauth",
              "reasoning_effort" => "high",
              "temperature" => 0.4
            }
          ],
          "tool_result_pruning" => false
        }
      }

      result = Setup.do_prepare_config(config, @anthropic_spec, nil)
      assert result.llm.default_provider_profile == "team"
      assert result.llm.tool_result_pruning == false
      refute Map.has_key?(result.llm, :models)
      refute Map.has_key?(result.llm, :model)
      assert [profile] = result.llm.providers
      assert profile.id == "team"
      assert profile.provider == "anthropic"
      assert profile.concurrency == 5
      assert profile.reasoning_efforts == ["high"]
      assert profile.default_reasoning_effort == "high"
      assert profile.temperature == 0.4
      assert profile.default_model == @anthropic_spec.id
      assert profile.models == [%{model: "old-model"}, %{model: @anthropic_spec.id}]
      refute Map.has_key?(profile, :auth_mode)
      assert {:ok, _} = Schema.validate(result)
    end

    test "flat legacy defaults become shared account defaults, not duplicate llm fields" do
      config = %{
        llm: %{model: "anthropic:old-model", temperature: 0.6, max_tokens: 4096},
        scheduler: %{default_llm_max_concurrency: 6}
      }

      result = Setup.do_prepare_config(config, @anthropic_spec, "oauth")
      assert Map.keys(result.llm) |> Enum.sort() == [:default_provider_profile, :providers]
      assert result.scheduler == config.scheduler
      assert result.llm.default_provider_profile == "default"
      assert [profile] = result.llm.providers
      assert profile.concurrency == 6
      assert profile.temperature == 0.6
      assert profile.max_tokens == 4096
      assert profile.auth_mode == "oauth"
      assert profile.models == [%{model: "old-model"}, %{model: @anthropic_spec.id}]
      assert {:ok, _} = Schema.validate(result)
    end
  end

  describe "canonical persistence and resolution" do
    test "OAuth setup round-trips auth, account selection and nested overrides through real config IO" do
      profile = account()

      result =
        Setup.do_prepare_config(
          %{llm: %{default_provider_profile: profile.id, providers: [profile]}},
          %{provider: :anthropic, id: "review-model"},
          "oauth"
        )

      assert :ok = Config.save_user_config(result)
      assert {:ok, decoded} = TomlElixir.decode(File.read!(Config.config_path()))
      assert decoded == stringify(result)
      assert decoded["llm"]["default_provider_profile"] == profile.id
      refute Map.has_key?(decoded["llm"], "model")
      refute Map.has_key?(decoded["llm"], "models")
      assert [saved] = decoded["llm"]["providers"]
      assert saved["auth_mode"] == "oauth"
      assert saved["oauth_file"] == profile.oauth_file
      assert saved["models"] == stringify(profile.models)
      assert Schema.provider_profiles(Config.user_config()) == Schema.provider_profiles(result)
      refute File.exists?(Config.credentials_path())
    end

    test "resolution keeps the account/model/effort selection separate from ReqLLM identity and credentials" do
      key_name = "GENESIS_SETUP_TEST_#{System.unique_integer([:positive])}_API_KEY"
      profile = %{account() | api_key_env_var: key_name}
      config = %{llm: %{default_provider_profile: profile.id, providers: [profile]}}
      result = Setup.do_prepare_config(config, %{provider: :anthropic, id: "review-model"}, nil)
      assert :ok = Config.save_user_config(result)
      assert :ok = Config.save_credentials(%{key_name => "account-secret"})

      assert {:ok, resolved} = Schema.resolve_model_spec(Config.user_config(), nil)
      assert resolved.provider_profile_id == profile.id
      assert resolved.model == "review-model"
      assert resolved.reasoning_effort == "high"
      assert resolved.context_window == 64_000
      assert resolved.concurrency == profile.concurrency
      assert resolved.model_spec == "anthropic:review-model"
      assert resolved.generation_params[:api_key] == "account-secret"
      assert resolved.generation_params[:temperature] == 0.2
      assert resolved.generation_params[:max_tokens] == 4096
      assert resolved.generation_params[:reasoning_effort] == :high

      # Task selections are NOT resolved.model_spec or the credential-bearing
      # generation params. They retain the account identity explicitly.
      selection = Map.take(resolved, [:provider_profile_id, :model, :reasoning_effort])

      assert selection == %{
               provider_profile_id: profile.id,
               model: "review-model",
               reasoning_effort: "high"
             }

      assert {:ok, again} = Schema.resolve_model_spec(Config.user_config(), selection)
      assert again.model_spec == resolved.model_spec
      assert again.generation_params == resolved.generation_params
      refute File.read!(Config.config_path()) =~ "account-secret"
      refute inspect(selection) =~ "account-secret"
    end

    test "custom endpoint resolution produces a ReqLLM map without losing account selection" do
      spec = %{
        provider: :anthropic,
        id: "custom-model",
        base_url: "https://proxy.example/v1"
      }

      result = Setup.do_prepare_config(%{}, spec, nil)
      assert :ok = Config.save_user_config(result)
      assert {:ok, resolved} = Schema.resolve_model_spec(Config.user_config(), nil)
      assert resolved.model_spec == spec

      assert Map.take(resolved, [:provider_profile_id, :model, :reasoning_effort]) == %{
               provider_profile_id: "default",
               model: "custom-model",
               reasoning_effort: nil
             }
    end
  end

  ## Helpers

  defp account do
    %{
      id: "team",
      provider: "anthropic",
      name: "Team subscription",
      auth_mode: "api_key",
      api_key_env_var: "GENESIS_SETUP_TEAM_API_KEY",
      oauth_file: Path.join(Config.config_dir(), "team-oauth.json"),
      concurrency: 5,
      peak_concurrency: 0,
      peak_hours: [%{start: "09:00", end: "17:00"}],
      off_peak_days: ["weekends"],
      timezone: "Etc/UTC",
      temperature: 0.7,
      max_tokens: 8192,
      reasoning_efforts: ["low", "high"],
      default_reasoning_effort: "low",
      default_model: "fast-model",
      models: [
        %{model: "fast-model", context_window: 32_000},
        %{
          model: "review-model",
          context_window: 64_000,
          reasoning_efforts: ["high"],
          default_reasoning_effort: "high",
          temperature: 0.2,
          max_tokens: 4096
        }
      ]
    }
  end

  # Mirrors `Config.stringify_keys/1` (recurses into maps and lists, drops nil)
  # so the profile can be encoded as TOML exactly like `save_user_config/1`.
  defp stringify(map) when is_map(map) do
    map
    |> Map.new(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify(value)}
      {key, value} -> {key, stringify(value)}
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(nil), do: nil
  defp stringify(value), do: value
end
