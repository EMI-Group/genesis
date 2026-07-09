defmodule EvoGit.ConfigTest do
  use ExUnit.Case, async: false

  alias EvoGit.Config

  describe "defaults/0" do
    test "returns a map with scheduler defaults" do
      defaults = Config.defaults()
      assert is_map(defaults)
      assert %{scheduler: %{max_concurrency: 3}} = defaults
    end

    test "has no default llm model" do
      defaults = Config.defaults()
      assert Map.has_key?(defaults.llm, :model)
      assert defaults.llm.model == nil
    end

    test "has no default github username" do
      defaults = Config.defaults()
      assert Map.has_key?(defaults.user, :github_username)
      assert defaults.user.github_username == nil
    end

    test "sandbox defaults to :auto" do
      defaults = Config.defaults()
      assert defaults.sandbox.mode == :auto
    end
  end

  describe "resolve/0" do
    test "returns a map with at least the default keys" do
      config = Config.resolve()
      assert is_map(config)
      assert Map.has_key?(config, :scheduler)
      assert Map.has_key?(config, :llm)
      assert Map.has_key?(config, :user)
      assert Map.has_key?(config, :sandbox)
    end

    test "scheduler config has expected keys" do
      config = Config.resolve()
      scheduler = config.scheduler
      assert Map.has_key?(scheduler, :max_concurrency)
      assert Map.has_key?(scheduler, :max_tool_concurrency)
      assert Map.has_key?(scheduler, :agent_max_retries)
      assert Map.has_key?(scheduler, :max_agent_depth)
      assert Map.has_key?(scheduler, :max_retries)
    end
  end

  describe "resolve/1" do
    test "returns value for single key" do
      scheduler = Config.resolve(:scheduler)
      assert is_map(scheduler)
      assert Map.has_key?(scheduler, :max_concurrency)
    end

    test "returns value for nested key path" do
      concurrency = Config.resolve([:scheduler, :max_concurrency])
      assert is_integer(concurrency)
    end

    test "returns nil for unknown key" do
      assert Config.resolve(:nonexistent_key) == nil
    end

    test "returns nil for unknown nested path" do
      assert Config.resolve([:scheduler, :nonexistent]) == nil
    end
  end

  describe "user_config/0" do
    test "returns empty map when no config file exists" do
      # Config.config_path() may or may not exist
      # Just verify it returns a map
      config = Config.user_config()
      assert is_map(config)
    end
  end

  describe "credentials/0" do
    test "returns empty map when no credentials file exists" do
      creds = Config.credentials()
      assert is_map(creds)
    end

    test "does not accidentally set environment variables when no credentials file exists" do
      # Ensure a known test env var is not set after calling credentials/0
      System.delete_env("TEST_CRED_KEY")
      Config.credentials()
      assert System.get_env("TEST_CRED_KEY") == nil
    end

    test "does not crash when GOOGLE_API_KEY environment variable is already set" do
      # If GOOGLE_API_KEY is set in the environment, credentials/0 should
      # still work without crashing or raising.
      System.put_env("GOOGLE_API_KEY", "test-key-value")
      try do
        creds = Config.credentials()
        assert is_map(creds)
      after
        System.delete_env("GOOGLE_API_KEY")
      end
    end
  end

  describe "config_dir/0" do
    test "returns a string path" do
      dir = Config.config_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "genesis")
    end
  end

  describe "config_path/0" do
    test "returns path ending with config.toml" do
      path = Config.config_path()
      assert String.ends_with?(path, "config.toml")
    end
  end

  describe "credentials_path/0" do
    test "returns path ending with credentials.toml" do
      path = Config.credentials_path()
      assert String.ends_with?(path, "credentials.toml")
    end
  end

  describe "save_user_config/1 validation" do
    test "returns error for invalid config" do
      invalid = put_in(Config.defaults(), [:scheduler, :max_concurrency], -1)
      assert {:error, errors} = Config.save_user_config(invalid)
      assert is_list(errors)
      assert length(errors) > 0
    end

    test "rejects string for integer field" do
      invalid = put_in(Config.defaults(), [:scheduler, :max_concurrency], "not_a_number")
      assert {:error, _} = Config.save_user_config(invalid)
    end
  end

  describe "config_status/0 validation_errors" do
    test "returns validation_errors key" do
      status = Config.config_status()
      assert Map.has_key?(status, :validation_errors)
      assert is_list(status.validation_errors)
    end
  end

  describe "config_status/0 uses dynamic env vars" do
    test "returns a map with :missing key" do
      status = Config.config_status()
      assert is_map(status)
      assert Map.has_key?(status, :missing)
    end

    test "LLMCatalog.known_credential_keys/0 includes the new provider credential keys" do
      # If config_status still used a hardcoded list, minimax_api_key and
      # openrouter_api_key would be absent. The catalog now drives the list.
      vars = EvoGit.Config.LLMCatalog.known_credential_keys()
      assert "minimax_api_key" in vars
      assert "openrouter_api_key" in vars
    end
  end

  describe "api_key_present?/1" do
    # The set of ReqLLM atoms consulted; we clean up after each test so the
    # shared BEAM environment stays clean.

    defp reqllm_key_cleanup do
      for var <- EvoGit.Config.LLMCatalog.known_credential_keys(),
          key_atom = EvoGit.Config.credential_key_to_reqllm_key(var),
          not is_nil(key_atom) do
        Application.delete_env(:req_llm, key_atom)
      end
    end

    setup do
      on_exit(&reqllm_key_cleanup/0)

      :ok
    end

    test "returns false when no key is in ReqLLM store or creds" do
      reqllm_key_cleanup()

      assert Config.api_key_present?(%{}) == false
    end

    test "returns true when a key is present in the creds map (deepseek)" do
      reqllm_key_cleanup()

      creds = %{"deepseek_api_key" => "sk-test"}
      assert Config.api_key_present?(creds) == true
    end

    test "returns true when a key is stored via ReqLLM.put_key (anthropic)" do
      reqllm_key_cleanup()
      ReqLLM.put_key(:anthropic_api_key, "sk-test")

      assert Config.api_key_present?(%{}) == true
    end

    test "returns true when a key is stored via ReqLLM.put_key (deepseek)" do
      reqllm_key_cleanup()
      ReqLLM.put_key(:deepseek_api_key, "sk-test")

      assert Config.api_key_present?(%{}) == true
    end

    test "treats empty-string creds value as absent" do
      reqllm_key_cleanup()

      assert Config.api_key_present?(%{"deepseek_api_key" => ""}) == false
    end

    test "config_status/0 does not flag :api_key as missing when key is in ReqLLM store" do
      reqllm_key_cleanup()
      ReqLLM.put_key(:deepseek_api_key, "sk-test")

      status = Config.config_status()
      assert :api_key not in status.missing
    end
  end

  describe "LLMCatalog.known_credential_keys integration" do
    test "returns a list that is a superset of expected credential keys" do
      vars = EvoGit.Config.LLMCatalog.known_credential_keys()

      # GROQ_API_KEY appears in the credentials.toml example format but has no
      # dedicated entry in the LLMCatalog, so it is intentionally NOT asserted here.
      expected = [
        "google_api_key",
        "zai_api_key",
        "deepseek_api_key",
        "anthropic_api_key",
        "openai_api_key",
        "minimax_api_key",
        "alibaba_api_key",
        "alibaba_cn_api_key",
        "zai_coding_plan_api_key",
        "openrouter_api_key"
      ]

      for e <- expected do
        assert e in vars, "expected #{e} to be a member of known_credential_keys/0"
      end
    end
  end

  describe "model profiles resolution" do
    test "defaults produce empty models list" do
      # Use defaults directly (no user config merge) to verify no models by default
      config = Config.__migrate_llm_models__(Config.defaults())
      models = EvoGit.Config.Schema.model_profiles(config)
      assert models == []
    end

    test "flat config migrates into single default profile" do
      # Simulate what resolve does with a flat config
      flat_config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)

      # Use the private migration via a direct call to resolve's pipeline
      # We test the end-to-end behavior by checking that resolve produces models
      config =
        flat_config
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      models = EvoGit.Config.Schema.model_profiles(config)
      assert length(models) == 1
      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == %{provider: :anthropic, id: "claude-sonnet-4"}
      assert profile.concurrency == 3
      assert profile.temperature == 0.5
    end

    test "flat config migration picks up scheduler max_concurrency" do
      flat_config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:scheduler, :max_concurrency], 8)

      config =
        flat_config
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      profile = hd(EvoGit.Config.Schema.model_profiles(config))
      assert profile.concurrency == 8
    end

    test "flat config migration includes generation params" do
      flat_config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :max_tokens], 8192)
        |> put_in([:llm, :reasoning_effort], "high")
        |> put_in([:llm, :top_p], 0.9)
        |> put_in([:llm, :frequency_penalty], 0.5)
        |> put_in([:llm, :presence_penalty], 0.3)

      config =
        flat_config
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      profile = hd(EvoGit.Config.Schema.model_profiles(config))
      assert profile.max_tokens == 8192
      assert profile.reasoning_effort == "high"
      assert profile.top_p == 0.9
      assert profile.frequency_penalty == 0.5
      assert profile.presence_penalty == 0.3
    end

    test "flat config migration omits nil generation params" do
      flat_config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")

      config =
        flat_config
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      profile = hd(EvoGit.Config.Schema.model_profiles(config))
      # Only id, model, concurrency should be present — no nil gen params
      refute Map.has_key?(profile, :temperature)
      refute Map.has_key?(profile, :max_tokens)
    end

    test "no model configured produces empty models list" do
      flat_config = Config.defaults()

      config =
        flat_config
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      assert EvoGit.Config.Schema.model_profiles(config) == []
    end

    test "existing models list is used directly (not migrated)" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{id: "fast", model: "google:gemini-flash", temperature: 0.3},
          %{id: "reasoning", model: "anthropic:claude-sonnet-4", reasoning_effort: "high"}
        ])
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      models = EvoGit.Config.Schema.model_profiles(config)
      assert length(models) == 2
      assert Enum.at(models, 0).id == "fast"
      assert Enum.at(models, 1).id == "reasoning"
    end

    test "config_status reports missing model when no profiles" do
      # Test the Schema.model_profiles + has_model logic directly since
      # Config.resolve() reads the real config file in this environment.
      resolved = Config.__migrate_llm_models__(Config.defaults())
      profiles = EvoGit.Config.Schema.model_profiles(resolved)

      has_model =
        Enum.any?(profiles, fn profile ->
          case Map.get(profile, :model) do
            nil -> false
            "" -> false
            _ -> true
          end
        end)

      assert has_model == false
    end
  end

  describe "backward compat: Config.resolve([:llm, :model])" do
    test "returns the default profile's model after migration" do
      flat_config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")

      config =
        flat_config
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      # The flat [llm].model should mirror the default profile's model
      assert get_in(config, [:llm, :model]) == %{provider: :anthropic, id: "claude-sonnet-4"}
    end

    test "returns first profile's model when using new format" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{id: "default", model: "google:gemini-flash"},
          %{id: "reasoning", model: "anthropic:claude-sonnet-4"}
        ])
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      # [llm].model mirrors the first/default profile's model
      assert get_in(config, [:llm, :model]) == %{provider: :google, id: "gemini-flash"}
    end
  end

  describe "save_user_config/1 LLM format (multi-model)" do
    test "strip_flat_llm_fields removes flat gen params when models is non-empty" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :max_tokens], 8192)
        |> put_in([:llm, :reasoning_effort], "high")
        |> put_in([:llm, :top_p], 0.9)
        |> put_in([:llm, :top_k], 40)
        |> put_in([:llm, :frequency_penalty], 0.5)
        |> put_in([:llm, :presence_penalty], 0.3)
        |> put_in([:llm, :models], [
          %{id: "default", model: "anthropic:claude-sonnet-4", temperature: 0.5}
        ])

      stripped = Config.__strip_flat_llm_fields__(config)

      llm = stripped.llm
      # Flat gen params removed
      refute Map.has_key?(llm, :model)
      refute Map.has_key?(llm, :temperature)
      refute Map.has_key?(llm, :max_tokens)
      refute Map.has_key?(llm, :reasoning_effort)
      refute Map.has_key?(llm, :top_p)
      refute Map.has_key?(llm, :top_k)
      refute Map.has_key?(llm, :frequency_penalty)
      refute Map.has_key?(llm, :presence_penalty)
      # models preserved
      assert length(llm.models) == 1
      # compression_threshold_tokens preserved
      assert Map.has_key?(llm, :compression_threshold_tokens)
    end

    test "strip_flat_llm_fields does NOT mutate the original config" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :models], [
          %{id: "default", model: "anthropic:claude-sonnet-4", temperature: 0.5}
        ])

      _stripped = Config.__strip_flat_llm_fields__(config)

      # Original config still has the flat fields
      assert config.llm.model == "anthropic:claude-sonnet-4"
      assert config.llm.temperature == 0.5
    end

    test "strip_flat_llm_fields leaves flat fields when models is empty" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :models], [])

      stripped = Config.__strip_flat_llm_fields__(config)

      # Flat fields preserved since models is empty
      assert stripped.llm.model == "anthropic:claude-sonnet-4"
      assert stripped.llm.temperature == 0.5
    end

    test "strip_flat_llm_fields leaves flat fields when models is absent" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :models], nil)

      stripped = Config.__strip_flat_llm_fields__(config)

      assert stripped.llm.model == "anthropic:claude-sonnet-4"
      assert stripped.llm.temperature == 0.5
    end

    test "strip_flat_llm_fields does not crash when llm is absent" do
      config = %{scheduler: %{max_concurrency: 3}}

      stripped = Config.__strip_flat_llm_fields__(config)

      assert stripped == config
    end

    test "strip_flat_llm_fields handles string keys defensively" do
      config =
        %{
          llm: %{
            "model" => "anthropic:claude-sonnet-4",
            "temperature" => 0.5,
            "models" => [%{id: "default", model: "anthropic:claude-sonnet-4"}],
            "compression_threshold_tokens" => 100_000
          }
        }

      stripped = Config.__strip_flat_llm_fields__(config)

      llm = stripped.llm
      refute Map.has_key?(llm, "model")
      refute Map.has_key?(llm, "temperature")
      assert length(Map.get(llm, "models")) == 1
      assert Map.has_key?(llm, "compression_threshold_tokens")
    end

    test "stringify_keys recurses into list elements (model profiles)" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{id: "default", model: "anthropic:claude-sonnet-4", temperature: 0.5},
          %{id: "fast", model: "google:gemini-flash", top_p: 0.9}
        ])

      stringified = Config.__stringify_keys__(config)

      models = get_in(stringified, ["llm", "models"])
      assert is_list(models)
      [p1, p2] = models
      # Keys inside profile maps are now strings
      assert p1["id"] == "default"
      assert p1["model"] == "anthropic:claude-sonnet-4"
      assert p1["temperature"] == 0.5
      assert p2["id"] == "fast"
      assert p2["top_p"] == 0.9
    end

    test "full round-trip: multi-model config encodes/decodes as [[llm.models]]" do
      config =
        Config.defaults()
        |> put_in([:llm, :compression_threshold_tokens], 100_000)
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :max_tokens], 8192)
        |> put_in([:llm, :models], [
          %{
            id: "default",
            model: "anthropic:claude-sonnet-4",
            temperature: 0.5,
            max_tokens: 8192
          },
          %{
            id: "fast",
            model: "google:gemini-flash",
            temperature: 0.3,
            top_p: 0.9
          }
        ])

      # Simulate the save_user_config pipeline (minus the filesystem write)
      pipeline =
        config
        |> Map.delete(:evolution)
        |> Config.__strip_flat_llm_fields__()
        |> Config.__stringify_keys__()

      assert {:ok, toml} = TomlElixir.encode(pipeline)
      assert {:ok, decoded} = TomlElixir.decode(toml)

      llm = decoded["llm"]

      # Contains [[llm.models]] with both profiles
      models = llm["models"]
      assert is_list(models)
      assert length(models) == 2

      [p1, p2] = models
      assert p1["id"] == "default"
      assert p1["model"] == "anthropic:claude-sonnet-4"
      assert p2["id"] == "fast"
      assert p2["model"] == "google:gemini-flash"

      # Does NOT contain flat model / gen params under [llm]
      refute Map.has_key?(llm, "model")
      refute Map.has_key?(llm, "temperature")
      refute Map.has_key?(llm, "max_tokens")
      refute Map.has_key?(llm, "reasoning_effort")
      refute Map.has_key?(llm, "top_p")
      refute Map.has_key?(llm, "top_k")
      refute Map.has_key?(llm, "frequency_penalty")
      refute Map.has_key?(llm, "presence_penalty")

      # compression_threshold_tokens IS preserved
      assert llm["compression_threshold_tokens"] == 100_000
    end

    test "full round-trip: empty models preserves flat fields (no stripping)" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :models], [])

      pipeline =
        config
        |> Map.delete(:evolution)
        |> Config.__strip_flat_llm_fields__()
        |> Config.__stringify_keys__()

      assert {:ok, toml} = TomlElixir.encode(pipeline)
      assert {:ok, decoded} = TomlElixir.decode(toml)

      llm = decoded["llm"]
      # Flat fields preserved since models is empty
      assert llm["model"] == "anthropic:claude-sonnet-4"
      assert llm["temperature"] == 0.5
    end

    test "full round-trip: config with no llm.models does not crash" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :models], nil)

      pipeline =
        config
        |> Map.delete(:evolution)
        |> Config.__strip_flat_llm_fields__()
        |> Config.__stringify_keys__()

      assert {:ok, toml} = TomlElixir.encode(pipeline)
      assert {:ok, decoded} = TomlElixir.decode(toml)

      llm = decoded["llm"]
      # No models key after nil is rejected by stringify_keys
      refute Map.has_key?(llm, "models")
      # Flat fields preserved
      assert llm["model"] == "anthropic:claude-sonnet-4"
    end
  end

  describe "model map normalization in profiles" do
    test "provider string is atomized in each profile's model map" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{"id" => "default", "model" => %{"provider" => "openai", "id" => "my-model"}}
        ])
        |> Config.__atomize_enum_values__()

      models = EvoGit.Config.Schema.model_profiles(config)
      profile = hd(models)
      assert profile.id == "default"
      assert is_map(profile.model)
      assert profile.model.provider == :openai
      assert profile.model.id == "my-model"
    end

    test "multiple profiles each get normalized model maps" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{"id" => "a", "model" => %{"provider" => "openai", "id" => "m1"}},
          %{"id" => "b", "model" => "anthropic:claude-sonnet-4"}
        ])
        |> Config.__atomize_enum_values__()

      models = EvoGit.Config.Schema.model_profiles(config)
      [p1, p2] = models
      assert p1.id == "a"
      assert p1.model.provider == :openai
      assert p2.id == "b"
      assert p2.model == %{provider: :anthropic, id: "claude-sonnet-4"}
    end
  end

  describe "github_username is not required (config_status/0)" do
    # Bug fix: config_status/0 no longer includes :github_username in its
    # checks list. The github username is purely informational and must not
    # surface as a missing-config warning. These tests only assert that
    # :github_username is absent — :llm_model may legitimately be in :missing
    # in the test env (no model configured), which is fine.
    test ":github_username is not in the :missing list" do
      status = Config.config_status()
      assert :github_username not in status.missing
    end

    test ":github_username is not in the :warnings list" do
      status = Config.config_status()
      assert :github_username not in status.warnings
    end

    test "the string 'github' does not appear in any warning message" do
      status = Config.config_status()

      for warning <- status.warnings do
        refute String.contains?(String.downcase(warning), "github"),
               "unexpected github reference in warning: #{inspect(warning)}"
      end
    end
  end

  describe "resolve pipeline robustness against malformed config types" do
    # Bug fix: the defaults() |> deep_merge(user) |> atomize_enum_values()
    # |> migrate_llm_models() pipeline was hardened so it never raises on
    # type-mismatched user config (e.g. user wrote `llm = "claude"` — a
    # scalar — instead of a `[llm]` table). These tests exercise each
    # defensive guard via the Config.__*__ test helpers.

    test "deep_merge keeps base map when override is a non-map type mismatch" do
      base = %{llm: %{model: "default", concurrency: 3}}
      # A string where a [llm] table is expected — a type error.
      override = %{llm: "claude"}
      result = Config.__deep_merge__(base, override)

      assert is_map(result.llm)
      # The string override must NOT have replaced the map default.
      assert result.llm.model == "default"
      assert result.llm.concurrency == 3
    end

    test "migrate_llm_models does not crash and returns a map when :llm is a string" do
      config = %{llm: "claude", scheduler: "oops"}
      result = Config.__migrate_llm_models__(config)
      assert is_map(result)
    end

    test "atomize_enum_values replaces non-map model profiles with %{}" do
      config = %{llm: %{models: ["not-a-map", %{id: "ok"}]}}
      result = Config.__atomize_enum_values__(config)

      assert is_map(result)
      models = result.llm.models
      assert is_list(models)
      assert length(models) == 2
      assert Enum.at(models, 0) == %{}
      assert Enum.at(models, 1).id == "ok"
    end

    test "Schema.model_profiles returns [] for non-map :llm" do
      assert EvoGit.Config.Schema.model_profiles(%{llm: "string"}) == []
      assert EvoGit.Config.Schema.model_profiles(%{llm: nil}) == []
    end

    test "Schema.model_profiles returns [] when models is not a list" do
      assert EvoGit.Config.Schema.model_profiles(%{llm: %{models: "not-a-list"}}) == []
    end

    test "Schema.validate does not raise on string sections" do
      result1 = EvoGit.Config.Schema.validate(%{llm: "string"})
      assert match?({_, _}, result1)

      result2 = EvoGit.Config.Schema.validate(%{scheduler: "string"})
      assert match?({_, _}, result2)

      result3 = EvoGit.Config.Schema.validate(%{tools: "string"})
      assert match?({_, _}, result3)
    end

    test "end-to-end pipeline (defaults + malformed override) never crashes" do
      malformed_override = %{llm: "claude", scheduler: "oops", tools: "string"}

      # Simulate resolve/0 minus the disk read: defaults |> deep_merge
      # |> atomize_enum_values |> migrate_llm_models
      config =
        Config.defaults()
        |> Config.__deep_merge__(malformed_override)
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      assert is_map(config)
      # The type-mismatched overrides must not have replaced the map defaults.
      assert is_map(config.llm)
      assert is_map(config.scheduler)
    end
  end

  describe "config_status/0 structural integrity" do
    test "returns the full result map without raising in the test env" do
      status = Config.config_status()

      assert Map.has_key?(status, :ok?)
      assert Map.has_key?(status, :missing)
      assert Map.has_key?(status, :warnings)
      assert Map.has_key?(status, :validation_errors)
      assert is_boolean(status.ok?)
      assert is_list(status.missing)
      assert is_list(status.warnings)
      assert is_list(status.validation_errors)
    end
  end

  describe "string to model map normalization" do
    # Exercises the @doc false test wrappers that expose the private config
    # pipeline steps: string_to_model_map/1, atomize_enum_values/1, and
    # migrate_llm_models/1. These cover the map model-spec generalization
    # where "provider:model" strings are normalized to %{provider: atom, id: string}.

    test "string_to_model_map splits a provider:model string on the first colon" do
      assert Config.__string_to_model_map__("anthropic:claude-sonnet-4") ==
               %{provider: :anthropic, id: "claude-sonnet-4"}
    end

    test "string_to_model_map only splits on the first colon (rest is the id)" do
      assert Config.__string_to_model_map__("a:b:c") == %{provider: :a, id: "b:c"}
    end

    test "string_to_model_map on a no-colon string returns %{id: string} with no provider key" do
      # Confirmed by reading string_to_model_map/1: a single-element split
      # returns %{id: string} (no :provider key — provider is nil downstream).
      assert Config.__string_to_model_map__("just-a-model") == %{id: "just-a-model"}
    end

    test "end-to-end flat config: model string becomes a map in both profile and mirror" do
      config =
        %{llm: %{model: "anthropic:claude-x"}}
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      models = EvoGit.Config.Schema.model_profiles(config)
      assert length(models) == 1
      profile = hd(models)
      assert profile.model == %{provider: :anthropic, id: "claude-x"}

      # The flat [llm].model mirror is also the map form (not the string).
      assert get_in(config, [:llm, :model]) == %{provider: :anthropic, id: "claude-x"}
    end

    test "[[llm.models]] profile model string becomes a map through atomize_enum_values" do
      config =
        %{llm: %{models: [%{id: "default", model: "google:gflash"}]}}
        |> Config.__atomize_enum_values__()

      models = EvoGit.Config.Schema.model_profiles(config)
      assert length(models) == 1
      profile = hd(models)
      assert profile.model == %{provider: :google, id: "gflash"}
    end

    test "atomize_enum_values passes an atom-keyed map model through unchanged" do
      model_map = %{provider: :openai, id: "x", base_url: "https://u/v1"}

      config =
        %{llm: %{models: [%{id: "default", model: model_map}]}}
        |> Config.__atomize_enum_values__()

      profile = hd(EvoGit.Config.Schema.model_profiles(config))
      assert profile.model == %{provider: :openai, id: "x", base_url: "https://u/v1"}
      assert profile.model.provider == :openai
    end

    test "atomize_enum_values normalizes a string-keyed model map to atom keys with atom provider" do
      config =
        %{
          llm: %{
            models: [
              %{
                "id" => "default",
                "model" => %{
                  "provider" => "openai",
                  "id" => "x",
                  "base_url" => "https://u/v1"
                }
              }
            ]
          }
        }
        |> Config.__atomize_enum_values__()

      profile = hd(EvoGit.Config.Schema.model_profiles(config))
      assert profile.id == "default"
      assert profile.model.provider == :openai
      assert profile.model.id == "x"
      assert profile.model.base_url == "https://u/v1"
    end
  end
end
