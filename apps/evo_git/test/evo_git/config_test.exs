defmodule EvoGit.ConfigTest do
  # async: false — several tests mutate BEAM-global state observable by every
  # concurrently running module: System.put_env ("XDG_CONFIG_HOME",
  # "GOOGLE_API_KEY"/"TEST_CRED_KEY") and Application.put_env/delete_env on the
  # shared :req_llm credential keys. Serializing avoids cross-test interference.
  use ExUnit.Case, async: false

  alias EvoGit.Config

  # Isolates `XDG_CONFIG_HOME` for one test so every config/credentials write in
  # that test lands in a throwaway temp dir — never the developer's real
  # `~/.config/genesis/`. Shared by every describe that writes config.toml.
  defp isolate_xdg!(prefix) do
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    tmp_xdg = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    :ok
  end

  describe "defaults/0" do
    test "returns a map with scheduler defaults" do
      defaults = Config.defaults()
      assert is_map(defaults)
      assert %{scheduler: %{default_llm_max_concurrency: 3}} = defaults
    end
  end

  describe "sandbox backend config" do
    test "atomizes string backend values" do
      config =
        Config.defaults()
        |> put_in([:sandbox, :backend], "systemd")
        |> Config.__atomize_enum_values__()

      assert config.sandbox.backend == :systemd

      config =
        Config.defaults()
        |> put_in([:sandbox, :backend], "bwrap")
        |> Config.__atomize_enum_values__()

      assert config.sandbox.backend == :bwrap
    end

    test "rejects an unknown backend value without crashing" do
      config = put_in(EvoGit.Config.Schema.defaults(), [:sandbox, :backend], :bogus)
      assert {:error, errors} = EvoGit.Config.Schema.validate(config)
      assert is_list(errors)
      assert length(errors) > 0

      error = List.first(errors)
      assert error.key_path == [:sandbox, :backend]
      assert error.rule == {:in, [:auto, :systemd, :bwrap]}
    end
  end

  describe "resolve/0" do
    test "returns a map with the documented sections and scheduler keys" do
      config = Config.resolve()
      assert is_map(config)
      assert Map.has_key?(config, :scheduler)
      assert Map.has_key?(config, :llm)
      assert Map.has_key?(config, :user)
      assert Map.has_key?(config, :sandbox)

      scheduler = config.scheduler
      assert Map.has_key?(scheduler, :default_llm_max_concurrency)
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
      assert Map.has_key?(scheduler, :default_llm_max_concurrency)
    end

    test "returns value for nested key path" do
      concurrency = Config.resolve([:scheduler, :default_llm_max_concurrency])
      assert is_integer(concurrency)
    end

    test "returns nil for unknown key" do
      assert Config.resolve(:nonexistent_key) == nil
    end

    test "returns nil for unknown nested path" do
      assert Config.resolve([:scheduler, :nonexistent]) == nil
    end
  end

  describe "user_config/0 and credentials/0" do
    test "both answer a map (never nil) when their files may be absent" do
      assert is_map(Config.user_config())
      assert is_map(Config.credentials())
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

  describe "config_dir/0, config_path/0 and credentials_path/0" do
    test "the config dir is a genesis directory and both file paths extend it" do
      dir = Config.config_dir()
      assert is_binary(dir)
      assert String.contains?(dir, "genesis")

      assert String.ends_with?(Config.config_path(), "config.toml")
      assert String.ends_with?(Config.credentials_path(), "credentials.toml")
    end
  end

  describe "save_user_config/1 validation" do
    test "returns error for invalid config" do
      invalid = put_in(Config.defaults(), [:scheduler, :default_llm_max_concurrency], -1)
      assert {:error, errors} = Config.save_user_config(invalid)
      assert is_list(errors)
      assert length(errors) > 0
    end
  end

  describe "appearance accent color save/load round-trip" do
    # Isolates XDG_CONFIG_HOME so save_user_config/1 writes to a temp dir,
    # never the developer's real ~/.config/genesis/config.toml.
    setup do
      isolate_xdg!("evogit-config-appearance")

      :ok
    end

    test "saving a valid accent color writes it to config.toml and resolves back" do
      config =
        Config.defaults()
        |> put_in([:appearance, :accent_color], "teal")

      assert :ok = Config.save_user_config(config)

      contents = File.read!(Config.config_path())
      assert contents =~ "accent_color = \"teal\""

      # resolve/0 merges defaults + user config and round-trips the string enum
      assert get_in(Config.resolve(), [:appearance, :accent_color]) == "teal"
    end
  end

  describe "[data] dir save/load round-trip" do
    # Isolates XDG_CONFIG_HOME so save_user_config/1 writes to a temp dir,
    # never the developer's real ~/.config/genesis/config.toml.
    setup do
      isolate_xdg!("evogit-config-data-dir")

      :ok
    end

    test "defaults to nil when no [data] dir key is set" do
      # Isolated XDG_CONFIG_HOME points at an empty tmp dir — no config.toml,
      # so resolve([:data, :dir]) must return the schema default (nil).
      assert Config.resolve([:data, :dir]) == nil
    end

    test "saving an absolute [data] dir writes it to config.toml and resolves back" do
      data_dir =
        Path.join(System.tmp_dir!(), "evogit-relocated-#{System.unique_integer([:positive])}")

      config =
        Config.defaults()
        |> put_in([:data, :dir], data_dir)

      assert :ok = Config.save_user_config(config)

      contents = File.read!(Config.config_path())
      assert contents =~ ~s(dir = "#{data_dir}")

      # resolve/0 merges defaults + user config and round-trips the string
      assert Config.resolve([:data, :dir]) == data_dir
    end
  end

  describe "[llm] context-window / stage-1 pruning save/load round-trip" do
    # Isolates XDG_CONFIG_HOME so save_user_config/1 writes to a temp dir,
    # never the developer's real ~/.config/genesis/config.toml.
    setup do
      isolate_xdg!("evogit-config-llm-window")

      :ok
    end

    test "explicit values are written to config.toml and resolve back" do
      config =
        Config.defaults()
        |> put_in([:llm, :compression_threshold_tokens], 120_000)
        |> put_in([:llm, :tool_result_pruning], false)
        |> put_in([:llm, :tool_result_pruning_target_fraction], 0.75)

      assert :ok = Config.save_user_config(config)

      contents = File.read!(Config.config_path())
      assert contents =~ "compression_threshold_tokens"
      assert contents =~ "tool_result_pruning"
      assert contents =~ "tool_result_pruning_target_fraction"

      assert Config.resolve([:llm, :compression_threshold_tokens]) == 120_000
      assert Config.resolve([:llm, :tool_result_pruning]) == false
      assert Config.resolve([:llm, :tool_result_pruning_target_fraction]) == 0.75
    end

    test "an absent compression_threshold_tokens stays out of config.toml and resolves to nil" do
      config =
        Config.defaults()
        |> put_in([:llm, :tool_result_pruning], false)

      assert :ok = Config.save_user_config(config)

      contents = File.read!(Config.config_path())
      refute contents =~ "compression_threshold_tokens"

      # nil = "derive from the model profile's context_window".
      assert Config.resolve([:llm, :compression_threshold_tokens]) == nil

      # The pruning keys still survive resolution.
      assert Config.resolve([:llm, :tool_result_pruning]) == false
      assert Config.resolve([:llm, :tool_result_pruning_target_fraction]) == 0.5
    end

    test "strip_flat_llm_fields preserves the pruning keys when models is non-empty" do
      config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:llm, :temperature], 0.5)
        |> put_in([:llm, :tool_result_pruning], false)
        |> put_in([:llm, :tool_result_pruning_target_fraction], 0.25)
        |> put_in([:llm, :models], [%{id: "default", model: "anthropic:claude-sonnet-4"}])

      llm = Config.__strip_flat_llm_fields__(config).llm

      # Flat generation params are stripped...
      refute Map.has_key?(llm, :model)
      refute Map.has_key?(llm, :temperature)
      # ...but the compression/pruning knobs are NOT generation params.
      assert llm.tool_result_pruning == false
      assert llm.tool_result_pruning_target_fraction == 0.25
      assert Map.has_key?(llm, :compression_threshold_tokens)
    end

    test "strip_flat_llm_fields preserves the pruning keys for string-keyed configs" do
      config = %{
        llm: %{
          "model" => "anthropic:claude-sonnet-4",
          "temperature" => 0.5,
          "models" => [%{id: "default", model: "anthropic:claude-sonnet-4"}],
          "compression_threshold_tokens" => 100_000,
          "tool_result_pruning" => false,
          "tool_result_pruning_target_fraction" => 0.25
        }
      }

      llm = Config.__strip_flat_llm_fields__(config).llm

      refute Map.has_key?(llm, "model")
      refute Map.has_key?(llm, "temperature")
      assert llm["compression_threshold_tokens"] == 100_000
      assert llm["tool_result_pruning"] == false
      assert llm["tool_result_pruning_target_fraction"] == 0.25
    end

    test "the three [llm] keys survive the stringify + TOML encode/decode round trip" do
      config =
        Config.defaults()
        |> put_in([:llm, :compression_threshold_tokens], 100_000)
        |> put_in([:llm, :tool_result_pruning], false)
        |> put_in([:llm, :tool_result_pruning_target_fraction], 0.75)

      pipeline =
        config
        |> Map.delete(:evolution)
        |> Config.__strip_flat_llm_fields__()
        |> Config.__stringify_keys__()

      assert {:ok, toml} = TomlElixir.encode(pipeline)
      assert {:ok, decoded} = TomlElixir.decode(toml)

      llm = decoded["llm"]
      assert llm["compression_threshold_tokens"] == 100_000
      assert llm["tool_result_pruning"] == false
      assert llm["tool_result_pruning_target_fraction"] == 0.75
    end
  end

  describe "api_key_present?/1" do
    # The ReqLLM credential keys live in the BEAM-global `:req_llm` app env, so
    # these tests work on a SNAPSHOT: `setup` records every key's current value
    # (with `@absent` marking a key that had none) BEFORE the test body clears
    # them, and `on_exit` puts the environment back exactly as it found it — so
    # no later module can observe a credential this module wiped.
    @absent :__evogit_absent__

    # Clears every credential key so a test can observe "no key anywhere"; the
    # `setup` snapshot above is what lets `on_exit` undo it faithfully.
    defp reqllm_key_cleanup do
      for var <- EvoGit.Config.LLMCatalog.known_credential_keys(),
          key_atom = EvoGit.Config.credential_key_to_reqllm_key(var),
          not is_nil(key_atom) do
        Application.delete_env(:req_llm, key_atom)
      end
    end

    # {key_atom, value | @absent} for every credential key ReqLLM consults.
    defp reqllm_key_snapshot do
      for var <- EvoGit.Config.LLMCatalog.known_credential_keys(),
          key_atom = EvoGit.Config.credential_key_to_reqllm_key(var),
          not is_nil(key_atom) do
        {key_atom, Application.get_env(:req_llm, key_atom, @absent)}
      end
    end

    defp reqllm_key_restore(snapshot) do
      for {key_atom, value} <- snapshot do
        case value do
          @absent -> Application.delete_env(:req_llm, key_atom)
          value -> Application.put_env(:req_llm, key_atom, value)
        end
      end

      :ok
    end

    setup do
      snapshot = reqllm_key_snapshot()
      on_exit(fn -> reqllm_key_restore(snapshot) end)

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

    test "returns true when a key is stored via ReqLLM.put_key (any provider)" do
      for key <- [:anthropic_api_key, :deepseek_api_key] do
        reqllm_key_cleanup()
        ReqLLM.put_key(key, "sk-test")

        assert Config.api_key_present?(%{}) == true
      end
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

  describe "legacy model profiles resolution" do
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
      assert profile.model == "anthropic:claude-sonnet-4"
      assert profile.concurrency == 3
      assert profile.temperature == 0.5
    end

    test "flat config migration picks up scheduler default_llm_max_concurrency" do
      flat_config =
        Config.defaults()
        |> put_in([:llm, :model], "anthropic:claude-sonnet-4")
        |> put_in([:scheduler, :default_llm_max_concurrency], 8)

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
      assert get_in(config, [:llm, :model]) == "anthropic:claude-sonnet-4"
    end

    test "returns first legacy profile's model when using the explicit list format" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{id: "default", model: "google:gemini-flash"},
          %{id: "reasoning", model: "anthropic:claude-sonnet-4"}
        ])
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      # [llm].model mirrors the first/default profile's model
      assert get_in(config, [:llm, :model]) == "google:gemini-flash"
    end
  end

  describe "save_user_config/1 legacy LLM format (multi-model)" do
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
      config = %{scheduler: %{default_llm_max_concurrency: 3}}

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
    test "simple model map (only provider+id) is normalized to a provider:id string" do
      config =
        Config.defaults()
        |> put_in([:llm, :models], [
          %{"id" => "default", "model" => %{"provider" => "openai", "id" => "my-model"}}
        ])
        |> Config.__atomize_enum_values__()

      models = EvoGit.Config.Schema.model_profiles(config)
      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == "openai:my-model"
    end

    test "multiple profiles each get normalized model specs (map→string, string passes through)" do
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
      assert p1.model == "openai:m1"
      assert p2.id == "b"
      assert p2.model == "anthropic:claude-sonnet-4"
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

  describe "config_status/0 legacy llm_model gate (map-form model health)" do
    # Regression tests for the config-health fix: config_status/0's has_model
    # predicate now counts a profile whose :model is a valid map spec
    # (%{provider: ..., id: ..., base_url: ...} — kept as a map by
    # normalize_model_map/1 whenever override keys like :base_url are present)
    # as configured. Previously such custom-endpoint map models were wrongly
    # reported as missing (false positive: "LLM model is not configured").
    # Each test writes a real config.toml into an isolated XDG_CONFIG_HOME so
    # the REAL Config.config_status/0 gate (which resolves from disk) is
    # exercised — no inline re-implementation of the has_model logic.
    setup do
      # These tests satisfy the :api_key gate by storing a ReqLLM credential, so
      # snapshot the `:req_llm` credential keys up front and restore them on exit
      # (the app env is BEAM-global — leaving the store empty would hide a
      # credential from every later module that builds a provider request).
      reqllm_snapshot = reqllm_key_snapshot()
      on_exit(fn -> reqllm_key_restore(reqllm_snapshot) end)

      isolate_xdg!("evogit-config-status")

      # config.toml lives at <xdg>/genesis/config.toml — create the parent dir
      # since these tests write raw TOML (no save_user_config mkdir).
      File.mkdir_p!(Config.config_dir())

      :ok
    end

    test "map-form model with provider/id/base_url passes the gate (ok?: true)" do
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "neo"
      model = { provider = "openai_compatible", id = "neo-coder-max", base_url = "http://127.0.0.1:11434/v1" }
      """)

      # The map model survives the resolve pipeline as a map (provider atomized,
      # base_url override kept) — what normalize_model_map/1 produces for
      # custom-endpoint models. This is the shape that previously failed the
      # health predicate.
      [profile] = EvoGit.Config.Schema.model_profiles(Config.resolve())
      assert profile.id == "neo"

      assert profile.model == %{
               provider: :openai_compatible,
               id: "neo-coder-max",
               base_url: "http://127.0.0.1:11434/v1"
             }

      # Satisfy the :api_key check so the whole config_status gate is green.
      ReqLLM.put_key(:openai_api_key, "sk-test")

      status = Config.config_status()
      assert status.ok? == true
      assert :llm_model not in status.missing
      assert status.warnings == []
    end

    test "binary-string model still passes the gate (unchanged behavior)" do
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "default"
      model = "openai:gpt-4.1"
      """)

      ReqLLM.put_key(:openai_api_key, "sk-test")

      status = Config.config_status()
      assert status.ok? == true
      assert :llm_model not in status.missing
      assert status.warnings == []
    end

    @tag capture_log: true
    test "profile with no model still reports :llm_model missing" do
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "no-model"
      """)

      status = Config.config_status()
      assert :llm_model in status.missing
    end

    test "profile with empty-string model still reports :llm_model missing" do
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "empty-model"
      model = ""
      """)

      status = Config.config_status()
      assert :llm_model in status.missing
    end

    @tag capture_log: true
    test "profile with empty-map model still reports :llm_model missing" do
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "empty-map-model"
      model = {}
      """)

      status = Config.config_status()
      assert :llm_model in status.missing
    end
  end

  describe "config_status/0 OAuth awareness" do
    # Health checks must never flag a subscription (OAuth) model profile as
    # "missing an API key". These tests write real config.toml/auth.json files
    # into the isolated XDG dir and exercise the REAL Config.config_status/0.
    #
    # The `:req_llm` credential keys, the `:auth_home_fun` seam and the two
    # Claude env tokens are BEAM-global — this module is async: false and
    # snapshots/restores every one of them (a leaked key would hide a credential
    # from later modules; a leaked vendor home would import real tokens).
    @generic_api_key_warning "No API key found. Add keys to credentials.toml or configure via the settings page."

    setup do
      reqllm_snapshot = reqllm_key_snapshot()
      on_exit(fn -> reqllm_key_restore(reqllm_snapshot) end)

      # `:auth_home_fun` is the sole home-directory source for the vendor-CLI
      # credential import — an empty temp home makes it a deterministic skip
      # instead of importing a real ~/.codex or ~/.claude login.
      empty_home =
        Path.join(System.tmp_dir!(), "evogit-oauth-home-#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty_home)
      previous_home_fun = Application.get_env(:evo_git, :auth_home_fun)
      Application.put_env(:evo_git, :auth_home_fun, fn -> empty_home end)

      env_names = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "CODEX_HOME"]
      env_snapshot = Enum.map(env_names, fn name -> {name, System.get_env(name)} end)
      Enum.each(env_names, &System.delete_env/1)

      on_exit(fn ->
        if previous_home_fun do
          Application.put_env(:evo_git, :auth_home_fun, previous_home_fun)
        else
          Application.delete_env(:evo_git, :auth_home_fun)
        end

        File.rm_rf!(empty_home)

        for {name, value} <- env_snapshot do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      isolate_xdg!("evogit-config-status-oauth")
      File.mkdir_p!(Config.config_dir())

      %{oauth_home: empty_home}
    end

    # The warning that belongs to a given missing key (checks keep their order).
    defp warning_for(status, key) do
      status.missing
      |> Enum.find_index(&(&1 == key))
      |> case do
        nil -> nil
        index -> Enum.at(status.warnings, index)
      end
    end

    # Writes a config whose Codex profile points its managed OAuth file at an
    # UNWRITABLE path: a regular FILE sits where the managed file's directory
    # would be, so every access fails with :enotdir — the hermetic stand-in for
    # a read-only home / Nix sandbox (which reports :erofs). The vendor login
    # itself exists in the isolated `:auth_home_fun` home. Returns the path.
    defp write_unwritable_oauth_config!(home) do
      codex_home = Path.join(home, ".codex")
      File.mkdir_p!(codex_home)

      File.write!(
        Path.join(codex_home, "auth.json"),
        Jason.encode!(%{
          "auth_mode" => "chatgpt",
          "tokens" => %{"access_token" => "tok", "refresh_token" => "refresh"}
        })
      )

      blocker = Path.join(Config.config_dir(), "blocked")
      File.write!(blocker, "not a directory")
      managed = Path.join(blocker, "auth.json")

      # The managed file is a PER-PROFILE setting (there is no global
      # `[llm] oauth_file` key).
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "codex"
      model = "openai_codex:gpt-5.6-terra"
      auth_mode = "oauth"
      oauth_file = "#{managed}"
      """)

      managed
    end

    test "a resolvable OAuth credential satisfies the :api_key check" do
      reqllm_key_cleanup()

      auth_file = Path.join(Config.config_dir(), "auth.json")

      File.write!(
        auth_file,
        Jason.encode!(%{
          "openai-codex" => %{"type" => "oauth", "access" => "tok", "refresh" => "refresh"}
        })
      )

      # No auth_mode: the OAuth-only provider is auto-detected. The managed
      # file is a PER-PROFILE setting.
      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "codex"
      model = "openai_codex:gpt-5.6-terra"
      oauth_file = "#{auth_file}"
      """)

      status = Config.config_status()

      refute :api_key in status.missing
      refute :llm_model in status.missing
      assert status.ok? == true
    end

    test "an unresolvable Codex credential flags :api_key and names `codex login`" do
      reqllm_key_cleanup()
      auth_file = Path.join(Config.config_dir(), "absent-auth.json")

      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "codex"
      model = "openai_codex:gpt-5.6-terra"
      auth_mode = "oauth"
      oauth_file = "#{auth_file}"
      """)

      status = Config.config_status()

      assert :api_key in status.missing
      warning = warning_for(status, :api_key)
      assert warning =~ "codex login"
      assert warning =~ auth_file
      # ONE distinct managed path renders in the singular form.
      assert warning =~ "Managed OAuth file: #{auth_file}"
      refute warning == @generic_api_key_warning
    end

    test "an unresolvable Claude credential names the Claude login / CLAUDE_CODE_OAUTH_TOKEN" do
      reqllm_key_cleanup()
      auth_file = Path.join(Config.config_dir(), "absent-claude-auth.json")

      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "claude"
      model = "anthropic:claude-opus-5-5"
      auth_mode = "oauth"
      oauth_file = "#{auth_file}"
      """)

      status = Config.config_status()

      assert :api_key in status.missing
      warning = warning_for(status, :api_key)
      assert warning =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert warning =~ auth_file
    end

    test "distinct per-profile managed files are all named (plural form)" do
      reqllm_key_cleanup()

      codex_file = Path.join(Config.config_dir(), "absent-codex-auth.json")
      claude_file = Path.join(Config.config_dir(), "absent-claude-auth.json")

      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "codex"
      model = "openai_codex:gpt-5.6-terra"
      auth_mode = "oauth"
      oauth_file = "#{codex_file}"

      [[llm.models]]
      id = "claude"
      model = "anthropic:claude-opus-5-5"
      auth_mode = "oauth"
      oauth_file = "#{claude_file}"
      """)

      status = Config.config_status()

      assert :api_key in status.missing
      warning = warning_for(status, :api_key)
      # Each profile's OWN file is resolved — never one global path.
      assert warning =~ "Managed OAuth files: #{codex_file}, #{claude_file}"
    end

    test "an API key still satisfies the check for an OAuth profile" do
      reqllm_key_cleanup()
      ReqLLM.put_key(:openai_api_key, "sk-test")

      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "codex"
      model = "openai_codex:gpt-5.6-terra"
      auth_mode = "oauth"
      oauth_file = "#{Path.join(Config.config_dir(), "absent-auth.json")}"
      """)

      refute :api_key in Config.config_status().missing
    end

    test "a managed file that cannot be written names the path, the cause and the remedy", %{
      oauth_home: home
    } do
      reqllm_key_cleanup()
      managed = write_unwritable_oauth_config!(home)

      status = Config.config_status()

      assert :api_key in status.missing
      warning = warning_for(status, :api_key)

      assert warning =~ managed
      assert warning =~ ":enotdir"
      assert warning =~ "oauth_file"
      assert warning =~ "writable location"
      # The vendor login EXISTS, so repeating the login step is wrong advice.
      refute warning =~ "codex login"
    end

    test "SystemCheck.llm_test reports the remedy instead of calling the provider", %{
      oauth_home: home
    } do
      reqllm_key_cleanup()
      write_unwritable_oauth_config!(home)

      # No network: the managed-file failure short-circuits the connection test.
      assert {:error, message} = EvoGit.SystemCheck.llm_test("openai_codex:gpt-5.6-terra")

      assert message =~ ":enotdir"
      assert message =~ "oauth_file"
      assert message =~ "not run"
    end

    test "canonical OAuth selection never substitutes another account's usable managed file", %{
      oauth_home: home
    } do
      reqllm_key_cleanup()
      blocked_file = write_unwritable_oauth_config!(home)
      usable_file = Path.join(Config.config_dir(), "usable-auth.json")

      File.write!(
        usable_file,
        Jason.encode!(%{
          "openai-codex" => %{"type" => "oauth", "access" => "tok", "refresh" => "refresh"}
        })
      )

      File.write!(Config.config_path(), """
      [llm]
      default_provider_profile = "blocked-account"

      [[llm.providers]]
      id = "usable-account"
      provider = "openai_codex"
      base_url = "http://127.0.0.1:1/v1"
      auth_mode = "oauth"
      oauth_file = "#{usable_file}"
      models = [{model = "gpt-5.6-terra", context_window = 96000}]

      [[llm.providers]]
      id = "blocked-account"
      provider = "openai_codex"
      base_url = "http://127.0.0.1:1/v1"
      auth_mode = "oauth"
      oauth_file = "#{blocked_file}"
      models = [{model = "gpt-5.6-terra", context_window = 96000}]
      """)

      config = Config.resolve()

      for {id, path} <- [{"usable-account", usable_file}, {"blocked-account", blocked_file}] do
        assert {:ok, resolved} = EvoGit.Config.Schema.resolve_model_spec(config, id)
        assert resolved.provider_profile_id == id
        assert resolved.generation_params[:provider_options][:auth_mode] == :oauth
        assert resolved.generation_params[:provider_options][:oauth_file] == path
        refute Keyword.has_key?(resolved.generation_params, :api_key)
      end

      # Every supported selection shape must stop before the request. The dead
      # loopback endpoint also keeps an accidental fallback off the real provider.
      for selection <- ["blocked-account", %{provider_profile_id: "blocked-account"}] do
        assert {:error, message} = EvoGit.SystemCheck.llm_test(selection)
        assert message =~ blocked_file
        assert message =~ ":enotdir"
        assert message =~ "not run"
      end

      assert {:error, message} = EvoGit.SystemCheck.llm_test()
      assert message =~ blocked_file
      assert message =~ "not run"
    end

    test "no OAuth profile keeps the generic API-key warning byte-identical" do
      reqllm_key_cleanup()

      File.write!(Config.config_path(), """
      [llm]

      [[llm.models]]
      id = "claude"
      model = "anthropic:claude-opus-5-5"
      """)

      status = Config.config_status()

      assert :api_key in status.missing
      assert warning_for(status, :api_key) == @generic_api_key_warning
    end

    test "no configured model profile keeps the generic API-key warning" do
      reqllm_key_cleanup()

      File.write!(Config.config_path(), """
      [llm]
      """)

      status = Config.config_status()

      assert :api_key in status.missing
      assert :llm_model in status.missing
      assert warning_for(status, :api_key) == @generic_api_key_warning
    end
  end

  describe "model spec normalization (LLMDB-compatible output)" do
    # Model specs are now normalized to LLMDB-compatible formats instead of
    # plain maps. String model specs pass through as-is (ReqLLM resolves them
    # through LLMDB natively). Map model specs are normalized: simple models
    # (only :provider + :id) become "provider:id" strings; models with override
    # keys become {:provider, opts} tuples.

    test "end-to-end flat config: model string passes through as-is (both profile and mirror)" do
      config =
        %{llm: %{model: "anthropic:claude-x"}}
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      models = EvoGit.Config.Schema.model_profiles(config)
      assert length(models) == 1
      profile = hd(models)
      assert profile.model == "anthropic:claude-x"

      # The flat [llm].model mirror is also the string (passes through).
      assert get_in(config, [:llm, :model]) == "anthropic:claude-x"
    end

    test "[[llm.models]] profile model string passes through as-is" do
      config =
        %{llm: %{models: [%{id: "default", model: "google:gflash"}]}}
        |> Config.__atomize_enum_values__()

      models = EvoGit.Config.Schema.model_profiles(config)
      assert length(models) == 1
      profile = hd(models)
      assert profile.model == "google:gflash"
    end

    test "atomize_enum_values normalizes an atom-keyed map model with overrides to an atomized map" do
      model_map = %{provider: :openai, id: "x", base_url: "https://u/v1"}

      config =
        %{llm: %{models: [%{id: "default", model: model_map}]}}
        |> Config.__atomize_enum_values__()

      profile = hd(EvoGit.Config.Schema.model_profiles(config))
      assert profile.model == %{provider: :openai, id: "x", base_url: "https://u/v1"}
      assert profile.model.provider == :openai
    end

    test "atomize_enum_values normalizes a string-keyed model map with overrides to an atomized map" do
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

  describe "migrate_llm_models edge cases" do
    # Bug fix: the pattern match `[%{model: default_model} | _]` raised a
    # MatchError when the first profile in the :models list was a map that
    # lacked a :model key (e.g. a manually edited config.toml or an incomplete
    # dashboard profile). These tests verify the crash-safe Map.get approach.

    test "does not crash when first profile lacks :model key" do
      config = %{llm: %{models: [%{id: "profile-1", concurrency: 3}]}}
      result = Config.__migrate_llm_models__(config)

      assert is_map(result)
      assert is_list(result.llm.models)
      # The flat :model field is left unchanged (defaults to nil — absent).
      assert get_in(result, [:llm, :model]) == nil
    end

    test "still mirrors model when first profile has one" do
      config = %{llm: %{models: [%{id: "profile-1", model: "openai:gpt-4"}]}}
      result = Config.__migrate_llm_models__(config)

      assert is_map(result)
      # The flat [llm].model mirror should be set to the first profile's model.
      assert get_in(result, [:llm, :model]) == "openai:gpt-4"
    end

    test "does not crash through full resolve/0 pipeline when first profile lacks :model" do
      # Verify the end-to-end resolve/0 path (defaults + malformed models)
      # does not raise — the schema validator reports the error gracefully.
      malformed_override = %{llm: %{models: [%{id: "profile-1", concurrency: 3}]}}

      config =
        Config.defaults()
        |> Config.__deep_merge__(malformed_override)
        |> Config.__atomize_enum_values__()
        |> Config.__migrate_llm_models__()

      assert is_map(config)
      assert is_list(config.llm.models)
    end
  end

  describe "canonical provider accounts through the config boundary" do
    setup do
      # All config reads happen in this process; no global XDG redirect is needed.
      EvoGit.TestSupport.ConfigDir.isolate!("evogit-provider-config")

      # Named account credentials and ReqLLM's provider-wide fallback are global.
      # Restore absence as well as values so later modules see exactly their state.
      names = ["GENESIS_CONFIG_ACCOUNT_A", "GENESIS_CONFIG_ACCOUNT_B"]
      env_snapshot = Enum.map(names, &{&1, System.get_env(&1)})
      reqllm_snapshot = reqllm_key_snapshot()
      ReqLLM.put_key(:openai_api_key, "provider-wide-key-must-not-leak")
      System.put_env("GENESIS_CONFIG_ACCOUNT_A", "account-a-secret")
      System.put_env("GENESIS_CONFIG_ACCOUNT_B", "account-b-secret")

      on_exit(fn ->
        reqllm_key_restore(reqllm_snapshot)

        for {name, value} <- env_snapshot do
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end
      end)

      :ok
    end

    defp canonical_account(id, env_var) do
      %{
        id: id,
        provider: "openai",
        api_key_env_var: env_var,
        base_url: "http://127.0.0.1:11434/v1",
        concurrency: 7,
        temperature: 0.4,
        max_tokens: 512,
        default_model: "reasoner",
        reasoning_efforts: ["low", "high"],
        default_reasoning_effort: "low",
        models: [
          %{model: "fast", context_window: 32_000},
          %{model: "reasoner", context_window: 96_000, temperature: 0.2, max_tokens: 1024}
        ]
      }
    end

    defp canonical_config do
      Config.defaults()
      |> put_in([:llm, :default_provider_profile], "account-b")
      |> put_in([:llm, :providers], [
        canonical_account("account-a", "GENESIS_CONFIG_ACCOUNT_A"),
        canonical_account("account-b", "GENESIS_CONFIG_ACCOUNT_B")
      ])
    end

    test "save/load keeps canonical accounts and nested models, never runtime mirrors or credentials" do
      config =
        canonical_config()
        |> put_in([:llm, :model], "anthropic:stale-flat-model")
        |> put_in([:llm, :temperature], 0.9)
        |> put_in([:llm, :models], [%{id: "stale", model: "anthropic:stale-model"}])
        |> put_in([:llm, :auth_mode], "api_key")
        |> put_in([:llm, :oauth_file], "/stale/auth.json")
        |> put_in([:llm, :provider_options], %{store: false})
        |> put_in([:llm, :compression_threshold_tokens], 90_000)
        |> put_in([:llm, :tool_result_pruning], false)

      assert :ok = Config.save_user_config(config)
      contents = File.read!(Config.config_path())
      assert {:ok, decoded} = TomlElixir.decode(contents)
      llm = decoded["llm"]
      assert llm["default_provider_profile"] == "account-b"
      assert Enum.map(llm["providers"], & &1["id"]) == ["account-a", "account-b"]

      for account <- llm["providers"] do
        assert account["provider"] == "openai"
        assert account["concurrency"] == 7
        assert account["default_model"] == "reasoner"
        assert account["reasoning_efforts"] == ["low", "high"]

        assert account["models"] == [
                 %{"model" => "fast", "context_window" => 32_000},
                 %{
                   "model" => "reasoner",
                   "context_window" => 96_000,
                   "temperature" => 0.2,
                   "max_tokens" => 1024
                 }
               ]
      end

      for key <-
            ~w(model models temperature max_tokens reasoning_effort auth_mode oauth_file provider_options) do
        refute Map.has_key?(llm, key)
      end

      assert llm["compression_threshold_tokens"] == 90_000
      assert llm["tool_result_pruning"] == false
      refute contents =~ "account-a-secret"
      refute contents =~ "account-b-secret"
      refute contents =~ "provider-wide-key-must-not-leak"

      resolved_config = Config.resolve()
      assert {:ok, resolved} = EvoGit.Config.Schema.resolve_model_spec(resolved_config, nil)
      assert resolved.provider_profile_id == "account-b"
      assert resolved.model == "reasoner"
      assert resolved.reasoning_effort == "low"
      assert resolved.context_window == 96_000
      assert resolved.concurrency == 7
      assert resolved.generation_params[:temperature] == 0.2
      assert resolved.generation_params[:max_tokens] == 1024
      assert resolved.generation_params[:api_key] == "account-b-secret"

      # model_spec is for ReqLLM, not the persisted task-selection vocabulary.
      assert resolved.model_spec == %{
               provider: :openai,
               id: "reasoner",
               base_url: "http://127.0.0.1:11434/v1"
             }

      selection = Map.take(resolved, [:provider_profile_id, :model, :reasoning_effort])

      assert {:ok, selected_again} =
               EvoGit.Config.Schema.resolve_model_spec(resolved_config, selection)

      assert selected_again == resolved

      assert Config.config_status() == %{
               ok?: true,
               missing: [],
               warnings: [],
               validation_errors: []
             }
    end

    test "same-provider accounts resolve their own keys for every model and explicit effort" do
      assert :ok = Config.save_user_config(canonical_config())
      config = Config.resolve()

      for {id, secret} <- [{"account-a", "account-a-secret"}, {"account-b", "account-b-secret"}],
          model <- ["fast", "reasoner"] do
        selection = %{provider_profile_id: id, model: model, reasoning_effort: "high"}
        assert {:ok, resolved} = EvoGit.Config.Schema.resolve_model_spec(config, selection)
        assert resolved.provider_profile_id == id
        assert resolved.model_spec.id == model
        assert resolved.generation_params[:api_key] == secret
        assert resolved.generation_params[:reasoning_effort] == :high
        refute resolved.generation_params[:api_key] == "provider-wide-key-must-not-leak"
      end
    end

    test "a missing account key never borrows another account or the provider-wide fallback" do
      assert :ok = Config.save_user_config(canonical_config())
      System.delete_env("GENESIS_CONFIG_ACCOUNT_B")
      config = Config.resolve()
      assert {:ok, missing} = EvoGit.Config.Schema.resolve_model_spec(config, "account-b")
      assert missing.generation_params[:api_key] == ""
      assert {:ok, other} = EvoGit.Config.Schema.resolve_model_spec(config, "account-a")
      assert other.generation_params[:api_key] == "account-a-secret"

      # The exact configured credential name also works in credentials.toml.
      File.write!(
        Config.credentials_path(),
        "GENESIS_CONFIG_ACCOUNT_B = \"file-account-b-secret\"\n"
      )

      assert {:ok, from_file} =
               EvoGit.Config.Schema.resolve_model_spec(Config.resolve(), "account-b")

      assert from_file.generation_params[:api_key] == "file-account-b-secret"

      assert {:ok, still_other} =
               EvoGit.Config.Schema.resolve_model_spec(Config.resolve(), "account-a")

      assert still_other.generation_params[:api_key] == "account-a-secret"
    end

    test "an invalid canonical default is rejected without replacing the saved config" do
      assert :ok = Config.save_user_config(canonical_config())
      original = File.read!(Config.config_path())
      invalid = put_in(canonical_config(), [:llm, :default_provider_profile], "missing-account")
      assert {:error, errors} = Config.save_user_config(invalid)
      assert Enum.any?(errors, &(&1.key_path == [:llm, :default_provider_profile]))
      assert File.read!(Config.config_path()) == original
    end
  end

  describe "lsp_enabled?/0 ([lsp] tool gate)" do
    # Each test writes (or deliberately omits) config.toml in an isolated
    # XDG_CONFIG_HOME, so the predicate is exercised end-to-end from disk and
    # never reads the developer's own ~/.config/genesis/config.toml.
    setup do
      isolate_xdg!("evogit-config-lsp")

      # config.toml lives at <xdg>/genesis/config.toml.
      File.mkdir_p!(Config.config_dir())

      :ok
    end

    test "is false when there is no [lsp] section at all" do
      refute Config.lsp_enabled?()
    end

    test "is true with enabled = true and a non-empty command" do
      File.write!(Config.config_path(), """
      [lsp]
      enabled = true
      command = "lexical"
      """)

      assert Config.lsp_enabled?()
    end

    test "accepts the string form enabled = \"true\"" do
      File.write!(Config.config_path(), """
      [lsp]
      enabled = "true"
      command = "lexical"
      """)

      assert Config.lsp_enabled?()
    end

    test "is false when enabled = true but the command is an empty string" do
      File.write!(Config.config_path(), """
      [lsp]
      enabled = true
      command = ""
      """)

      refute Config.lsp_enabled?()
    end

    test "is false when enabled = true but the command is blank whitespace" do
      File.write!(Config.config_path(), """
      [lsp]
      enabled = true
      command = "   "
      """)

      refute Config.lsp_enabled?()
    end

    test "is false when enabled = true but the command is absent" do
      File.write!(Config.config_path(), """
      [lsp]
      enabled = true
      """)

      refute Config.lsp_enabled?()
    end

    test "is false when enabled = false even with a command present" do
      File.write!(Config.config_path(), """
      [lsp]
      enabled = false
      command = "lexical"
      """)

      refute Config.lsp_enabled?()
    end
  end
end
