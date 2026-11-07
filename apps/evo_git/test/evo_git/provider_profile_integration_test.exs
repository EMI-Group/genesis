defmodule EvoGit.ProviderProfileIntegrationTest do
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.LLM
  alias EvoGit.TestSupport.ConfigDir

  # All reads/writes use the test process' ConfigDir, never global scheduler
  # state, env overrides or metadata seams. Credential names deliberately do
  # NOT end in _API_KEY: Config would publish those to global ReqLLM app env.
  # Unknown fixture model ids keep catalog-dependent capability gates inert.
  setup do
    ConfigDir.isolate!("provider_profile_integration")
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    File.write!(Config.credentials_path(), "")
    suffix = System.unique_integer([:positive])
    key_a = "GENESIS_INTEGRATION_#{suffix}_A_TOKEN"
    key_b = "GENESIS_INTEGRATION_#{suffix}_B_TOKEN"

    for key <- [key_a, key_b] do
      assert System.get_env(key) == nil
      assert Config.credential_key_to_reqllm_key(key) == nil
    end

    providers = accounts(key_a, key_b)
    config = put_in(Config.defaults(), [:llm, :providers], providers)
    config = put_in(config, [:llm, :default_provider_profile], "work")
    %{dir: dir, config: config, providers: providers, key_a: key_a, key_b: key_b}
  end

  describe "canonical config persistence" do
    test "save, TOML decode, resolve and save again retain two independent same-provider accounts",
         %{config: config, providers: providers} do
      assert :ok = Config.save_user_config(config)
      assert {:ok, decoded} = TomlElixir.decode(File.read!(Config.config_path()))
      assert decoded == Config.user_config()
      assert decoded["llm"]["providers"] == providers
      assert decoded["llm"]["default_provider_profile"] == "work"

      resolved = Config.resolve()
      assert resolved.llm.providers == providers
      assert resolved.llm.default_provider_profile == "work"
      assert Schema.provider_profiles(resolved) == providers
      assert :ok = Config.save_user_config(resolved)
      assert Config.user_config() == decoded
      assert Config.resolve() == resolved
    end

    test "canonical inventory strips stale flat and legacy mirrors but retains unrelated LLM settings",
         %{config: config, providers: providers} do
      config =
        update_in(config, [:llm], fn llm ->
          Map.merge(llm, %{
            model: "openai:stale-flat",
            models: [%{id: "stale", model: "openai:stale-legacy", concurrency: 99}],
            temperature: 1.9,
            max_tokens: 123,
            reasoning_effort: "low",
            top_p: 0.1,
            top_k: 8,
            frequency_penalty: 1.0,
            presence_penalty: 1.0,
            auth_mode: "api_key",
            oauth_file: "/stale/auth.json",
            provider_options: %{store: true},
            compression_threshold_tokens: 45_678,
            tool_result_pruning: false,
            tool_result_pruning_target_fraction: 0.4
          })
        end)

      assert :ok = Config.save_user_config(config)
      llm = Config.user_config()["llm"]
      assert llm["providers"] == providers
      assert llm["default_provider_profile"] == "work"
      assert llm["compression_threshold_tokens"] == 45_678
      assert llm["tool_result_pruning"] == false
      assert llm["tool_result_pruning_target_fraction"] == 0.4

      for key <-
            ~w(model models temperature max_tokens reasoning_effort top_p top_k frequency_penalty presence_penalty auth_mode oauth_file provider_options) do
        refute Map.has_key?(llm, key), "persisted stale LLM mirror #{key}"
      end

      loaded = Config.resolve()
      assert Enum.map(LLM.model_profiles(loaded), & &1.id) == ["personal", "work"]
      assert resolve!(loaded, nil).provider_profile_id == "work"
      assert resolve!(loaded, nil).model == "integration-reasoner"
    end

    test "nested atom-keyed programmatic input loads as canonical string-keyed account maps",
         %{config: config} do
      provider = %{
        id: "atom-account",
        name: "Atom account",
        provider: "openai",
        concurrency: 4,
        auth_mode: "api_key",
        default_model: "integration-chat",
        reasoning_efforts: ["high", "low"],
        default_reasoning_effort: "low",
        provider_options: %{integration_custom_option: %{nested_flag: true}},
        models: [
          %{
            model: "integration-chat",
            context_window: 54_321,
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "high",
            max_tokens: 321
          }
        ]
      }

      config =
        config
        |> put_in([:llm, :providers], [provider])
        |> put_in([:llm, :default_provider_profile], "atom-account")

      assert :ok = Config.save_user_config(config)
      [loaded] = Config.resolve().llm.providers
      assert loaded["id"] == "atom-account"

      assert loaded["provider_options"] == %{
               "integration_custom_option" => %{"nested_flag" => true}
             }

      assert loaded["models"] == [
               %{
                 "model" => "integration-chat",
                 "context_window" => 54_321,
                 "reasoning_efforts" => ["low", "high"],
                 "default_reasoning_effort" => "high",
                 "max_tokens" => 321
               }
             ]

      selected = resolve!(Config.resolve(), nil)
      assert selected.context_window == 54_321
      assert selected.reasoning_effort == "high"
      assert selected.generation_params[:max_tokens] == 321
      assert :ok = Config.save_user_config(Config.resolve())
      assert Config.resolve().llm.providers == [loaded]
    end

    test "handwritten TOML normalizes qualified names, model id aliases and implicit defaults" do
      File.write!(Config.config_path(), """
      [llm]
      default_provider_profile = "manual"
      [[llm.providers]]
      id = "manual"
      provider = "openai"
      default_model = "openai:integration-chat"
      reasoning_efforts = ["high", "low"]
      [[llm.providers.models]]
      id = "openai:integration-chat"
      context_window = 87654
      [[llm.providers.models]]
      model = "integration-reasoner"
      max_tokens = 765
      """)

      loaded = Config.resolve()
      [profile] = Schema.provider_profiles(loaded)
      assert profile["default_model"] == "integration-chat"
      assert profile["auth_mode"] == "api_key"
      assert profile["concurrency"] == 3
      assert profile["reasoning_efforts"] == ["high", "low"]

      assert profile["models"] == [
               %{"model" => "integration-chat", "context_window" => 87_654},
               %{"model" => "integration-reasoner", "max_tokens" => 765}
             ]

      selected = resolve!(loaded, nil)
      assert selected.model_spec == "openai:integration-chat"
      assert selected.reasoning_effort == nil
      refute Keyword.has_key?(selected.generation_params, :reasoning_effort)
      assert selected.context_window == 87_654
      assert :ok = Config.save_user_config(loaded)
      assert Schema.provider_profiles(Config.resolve()) == [profile]
    end

    test "same-size rewrites invalidate the config cache and change only the chosen default",
         %{config: config} do
      config = put_in(config, [:llm, :default_provider_profile], "personal")
      assert :ok = Config.save_user_config(config)
      before_size = File.stat!(Config.config_path()).size
      assert resolve!(Config.resolve(), nil).provider_profile_id == "personal"

      renamed =
        config
        |> put_in([:llm, :providers, Access.at(1), "id"], "business")
        |> put_in([:llm, :default_provider_profile], "business")

      # Opposite account-id length changes keep the total TOML byte count
      # unchanged even on filesystems whose mtime resolution cannot distinguish
      # these two saves.
      renamed = put_in(renamed, [:llm, :providers, Access.at(0), "id"], "home")
      assert :ok = Config.save_user_config(renamed)
      assert File.stat!(Config.config_path()).size == before_size
      assert Config.user_config()["llm"]["default_provider_profile"] == "business"
      assert resolve!(Config.resolve(), nil).provider_profile_id == "business"
      assert resolve!(Config.resolve(), "home").model == "integration-chat"
    end
  end

  describe "account/model/effort selection after real save and load" do
    test "ordered selections retain repeated models under distinct accounts", %{config: config} do
      loaded = save_and_load!(config)

      assert Schema.model_selections(loaded) == [
               selection(
                 "personal",
                 "Personal",
                 "integration-chat",
                 64_000,
                 ["low", "high"],
                 "low"
               ),
               selection(
                 "personal",
                 "Personal",
                 "integration-reasoner",
                 96_000,
                 ["high", "low"],
                 "high"
               ),
               selection(
                 "work",
                 "Work",
                 "integration-chat",
                 128_000,
                 ["medium", "high"],
                 "medium"
               ),
               selection(
                 "work",
                 "Work",
                 "integration-reasoner",
                 192_000,
                 ["high", "medium"],
                 "high"
               )
             ]
    end

    test "configured default account and per-account default models are not first-item guesses",
         %{config: config} do
      loaded = save_and_load!(config)
      work = resolve!(loaded, nil)
      assert work.provider_profile_id == "work"
      assert work.model == "integration-reasoner"
      assert work.reasoning_effort == "high"
      assert work.concurrency == 7
      assert work.context_window == 192_000

      personal = resolve!(loaded, "personal")
      assert personal.model == "integration-chat"
      assert personal.reasoning_effort == "low"
      assert personal.concurrency == 2
      assert personal.context_window == 64_000

      no_selector = update_in(config, [:llm], &Map.delete(&1, :default_provider_profile))
      assert resolve!(save_and_load!(no_selector), nil).provider_profile_id == "personal"
    end

    test "atom and persisted string selection maps resolve the same account, model and effort",
         %{config: config} do
      loaded = save_and_load!(config)

      choice = %{
        provider_profile_id: "personal",
        model: "integration-reasoner",
        reasoning_effort: "low"
      }

      json_choice = choice |> Jason.encode!() |> Jason.decode!()
      chosen = resolve!(loaded, choice)
      assert chosen == resolve!(loaded, json_choice)
      assert chosen.model == "integration-reasoner"
      assert chosen.reasoning_effort == "low"
      assert chosen.generation_params[:reasoning_effort] == :low

      assert chosen.model_spec == %{
               provider: :openai,
               id: "integration-reasoner",
               base_url: "https://personal.invalid/v1"
             }

      refute Map.has_key?(chosen.model_spec, :provider_profile_id)
      refute Map.has_key?(chosen.model_spec, :reasoning_effort)
      refute Map.has_key?(chosen.model_spec, :context_window)
      assert Map.take(chosen, Map.keys(choice)) == choice
    end

    test "qualified model selection is unqualified only against its own provider", %{
      config: config
    } do
      loaded = save_and_load!(config)

      assert resolve!(loaded, %{provider_profile_id: "work", model: "openai:integration-chat"}).model ==
               "integration-chat"

      assert Schema.resolve_model_spec(loaded, %{
               provider_profile_id: "work",
               model: "anthropic:integration-chat"
             }) ==
               {:error, {:model_not_found, "work", "anthropic:integration-chat"}}
    end

    test "explicit effort overrides neither mutate saved defaults nor leak into the next resolution",
         %{config: config} do
      loaded = save_and_load!(config)
      original = Config.user_config()
      choice = %{provider_profile_id: "work", model: "integration-chat", reasoning_effort: "high"}
      assert resolve!(loaded, choice).generation_params[:reasoning_effort] == :high

      assert resolve!(loaded, %{provider_profile_id: "work", model: "integration-chat"}).reasoning_effort ==
               "medium"

      assert resolve!(loaded, "personal").reasoning_effort == "low"
      assert Config.user_config() == original
    end

    test "sparse accounts get shared defaults without inventing an effort", %{config: config} do
      sparse = %{"id" => "sparse", "provider" => "openai", "models" => ["integration-chat"]}

      loaded =
        config
        |> put_in([:llm, :providers], [sparse])
        |> put_in([:llm, :default_provider_profile], "sparse")
        |> save_and_load!()

      chosen = resolve!(loaded, nil)
      assert chosen.profile_name == "sparse"
      assert chosen.concurrency == 3
      assert chosen.context_window == LLM.default_context_window()
      assert chosen.reasoning_efforts == []
      assert chosen.default_reasoning_effort == nil
      assert chosen.reasoning_effort == nil
      assert chosen.model_spec == "openai:integration-chat"
      assert chosen.generation_params == [provider_options: [store: false]]
      assert resolve!(loaded, %{reasoning_effort: "high"}).reasoning_effort == "high"
    end

    test "unsupported or malformed selections return errors instead of silently switching accounts",
         %{config: config} do
      loaded = save_and_load!(config)

      for {choice, expected} <- [
            {"missing", {:provider_profile_not_found, "missing"}},
            {%{provider_profile_id: "work", model: "missing"},
             {:model_not_found, "work", "missing"}},
            {%{provider_profile_id: "personal", reasoning_effort: "medium"},
             {:unsupported_reasoning_effort, "medium", ["low", "high"]}},
            {%{provider_profile_id: "work", model: "integration-chat", reasoning_effort: "low"},
             {:unsupported_reasoning_effort, "low", ["medium", "high"]}},
            {%{reasoning_effort: 42}, {:invalid_reasoning_effort, 42}},
            {[], :invalid_model_spec},
            {"", :invalid_model_spec}
          ] do
        assert Schema.resolve_model_spec(loaded, choice) == {:error, expected}
      end
    end

    test "legacy runtime projections resolve account defaults without flattening nested inventories",
         %{config: config} do
      loaded = save_and_load!(config)
      [personal, work] = Schema.effective_model_profiles(loaded)
      assert [personal, work] == LLM.model_profiles(loaded)
      assert personal == resolve!(loaded, "personal").runtime_profile
      assert work == resolve!(loaded, "work").runtime_profile
      assert LLM.get_model_profile(loaded, "personal") == {:ok, personal}
      assert LLM.default_model_profile(loaded) == {:ok, work}
      assert Schema.default_model_profile(loaded) == {:ok, work}
      assert Schema.llm_generation_params(loaded) == resolve!(loaded, nil).generation_params
      assert length(Schema.model_selections(loaded)) == 4
      assert Config.user_config()["llm"]["providers"] == config.llm.providers
    end
  end

  describe "same-provider credentials, scheduling and generation isolation" do
    test "persisted account keys reach generation params for only their selected account",
         %{config: config, key_a: key_a, key_b: key_b} do
      assert :ok =
               Config.save_credentials(%{
                 key_a => "fake-personal-secret",
                 key_b => "fake-work-secret"
               })

      loaded = save_and_load!(config)

      assert Config.credentials() == %{
               key_a => "fake-personal-secret",
               key_b => "fake-work-secret"
             }

      for account <- ["personal", "work"],
          model <- ["integration-chat", "integration-reasoner"] do
        selected = resolve!(loaded, %{provider_profile_id: account, model: model})
        expected = if account == "personal", do: "fake-personal-secret", else: "fake-work-secret"
        assert selected.generation_params[:api_key] == expected
        assert LLM.profile_generation_params(selected.runtime_profile)[:api_key] == expected
        refute inspect(Map.drop(selected, [:generation_params])) =~ expected
      end

      refute File.read!(Config.config_path()) =~ "fake-personal-secret"
      refute File.read!(Config.config_path()) =~ "fake-work-secret"
    end

    test "missing custom credentials fail closed instead of borrowing another account or provider key",
         %{config: config, key_a: key_a} do
      assert :ok = Config.save_credentials(%{key_a => "only-personal"})
      loaded = save_and_load!(config)
      assert resolve!(loaded, "personal").generation_params[:api_key] == "only-personal"
      # The suite supplies ReqLLM's global OpenAI test key; it must NOT be used.
      assert resolve!(loaded, "work").generation_params[:api_key] == ""
      assert :ok = Config.save_credentials(%{key_a => ""})
      assert resolve!(loaded, "personal").generation_params[:api_key] == ""
      assert resolve!(loaded, "work").generation_params[:api_key] == ""
    end

    test "credential cache invalidation and key updates do not change the sibling account",
         %{config: config, key_a: key_a, key_b: key_b} do
      assert :ok = Config.save_credentials(%{key_a => "personal-one", key_b => "work-one"})
      loaded = save_and_load!(config)
      assert resolve!(loaded, "personal").generation_params[:api_key] == "personal-one"
      work = resolve!(loaded, "work")
      assert :ok = Config.save_credentials(%{key_a => "personal-two"})
      assert resolve!(loaded, "personal").generation_params[:api_key] == "personal-two"
      assert resolve!(loaded, "work") == work
      assert Config.credentials()[key_b] == "work-one"
    end

    test "nested generation overrides apply after account defaults and do not alter scheduling",
         %{config: config} do
      loaded = save_and_load!(config)

      personal =
        resolve!(loaded, %{provider_profile_id: "personal", model: "integration-reasoner"})

      work = resolve!(loaded, %{provider_profile_id: "work", model: "integration-reasoner"})

      assert Map.new(personal.generation_params) == %{
               api_key: "",
               temperature: 0.2,
               max_tokens: 2048,
               top_p: 0.75,
               reasoning_effort: :high,
               provider_options: [parallel_tool_calls: false]
             }

      assert Map.new(work.generation_params) == %{
               api_key: "",
               temperature: 0.6,
               max_tokens: 4096,
               top_p: 0.9,
               reasoning_effort: :high,
               provider_options: [parallel_tool_calls: true]
             }

      assert personal.concurrency == 2
      assert personal.peak_concurrency == 0
      assert personal.peak_hours == [%{"start" => "09:00", "end" => "17:00"}]
      assert personal.off_peak_days == ["sun"]
      assert personal.timezone == "UTC"
      assert work.concurrency == 7
      assert work.peak_concurrency == 1
      assert work.peak_hours == [%{"start" => "18:00", "end" => "22:00"}]
      assert work.off_peak_days == ["sat", "sun"]
      assert work.timezone == "Asia/Hong_Kong"

      personal_chat = resolve!(loaded, "personal")
      work_chat = resolve!(loaded, %{provider_profile_id: "work", model: "integration-chat"})
      assert personal_chat.generation_params[:max_tokens] == 1024
      assert personal_chat.generation_params[:temperature] == 0.4
      assert work_chat.generation_params[:max_tokens] == 3072
      assert work_chat.generation_params[:temperature] == 0.8
      assert personal.context_window == 96_000
      assert work.context_window == 192_000
    end

    test "model-specific provider options replace sibling defaults only inside the chosen account",
         %{config: config} do
      config =
        put_in(
          config,
          [:llm, :providers, Access.at(0), "models", Access.at(1), "provider_options"],
          %{"parallel_tool_calls" => true, "integration_marker" => "model"}
        )

      loaded = save_and_load!(config)
      model = resolve!(loaded, %{provider_profile_id: "personal", model: "integration-reasoner"})

      assert Map.new(model.generation_params[:provider_options]) == %{
               "integration_marker" => "model",
               :parallel_tool_calls => true
             }

      assert resolve!(loaded, "personal").generation_params[:provider_options] == [
               parallel_tool_calls: false
             ]

      assert resolve!(loaded, "work").generation_params[:provider_options] == [
               parallel_tool_calls: true
             ]
    end

    test "ReqLLM model identifiers retain account endpoints and extra options, not task selections",
         %{config: config} do
      config =
        put_in(config, [:llm, :providers, Access.at(1), "extra"], %{
          "integration_endpoint" => %{"route" => "work"}
        })

      loaded = save_and_load!(config)
      personal = resolve!(loaded, %{provider_profile_id: "personal", model: "integration-chat"})
      work = resolve!(loaded, %{provider_profile_id: "work", model: "integration-chat"})

      assert personal.model_spec == %{
               provider: :openai,
               id: "integration-chat",
               base_url: "https://personal.invalid/v1"
             }

      assert work.model_spec == %{
               provider: :openai,
               id: "integration-chat",
               base_url: "https://work.invalid/v1",
               extra: %{"integration_endpoint" => %{route: "work"}}
             }

      assert personal.runtime_profile.model == personal.model_spec
      assert work.runtime_profile.model == work.model_spec
      refute Keyword.has_key?(personal.generation_params[:provider_options], :store)
      refute Keyword.has_key?(work.generation_params[:provider_options], :store)
    end

    test "OAuth and API-key accounts of the same provider retain separate auth paths",
         %{config: config, dir: dir, key_a: key_a} do
      file = oauth_file!(dir, "subscription", "subscription-account")

      providers = [
        %{
          "id" => "api",
          "provider" => "anthropic",
          "auth_mode" => "api_key",
          "api_key_env_var" => key_a,
          "concurrency" => 2,
          "models" => ["integration-chat"]
        },
        %{
          "id" => "subscription",
          "provider" => "anthropic",
          "auth_mode" => "oauth",
          "oauth_file" => file,
          "api_key_env_var" => key_a,
          "concurrency" => 5,
          "models" => ["integration-chat"]
        }
      ]

      assert :ok = Config.save_credentials(%{key_a => "fake-api-account-secret"})

      loaded =
        config
        |> put_in([:llm, :providers], providers)
        |> put_in([:llm, :default_provider_profile], "subscription")
        |> save_and_load!()

      api = resolve!(loaded, "api")
      oauth = resolve!(loaded, nil)
      assert api.model_spec == oauth.model_spec
      assert api.generation_params[:api_key] == "fake-api-account-secret"
      refute Keyword.has_key?(api.generation_params, :provider_options)
      assert oauth.generation_params[:provider_options] == [auth_mode: :oauth, oauth_file: file]
      refute Keyword.has_key?(oauth.generation_params, :api_key)
      assert api.concurrency == 2
      assert oauth.concurrency == 5

      assert LLM.oauth_credential_status(oauth.runtime_profile) ==
               {:ok, %{expires: 4_102_444_800_000, account_id: "subscription-account"}}
    end

    test "two subscription accounts use their own managed files even for identical provider/models",
         %{config: config, dir: dir} do
      first = oauth_file!(dir, "first", "first-account")
      second = oauth_file!(dir, "second", "second-account")
      snapshots = Map.new([first, second], &{&1, File.read!(&1)})

      providers =
        for {id, file} <- [{"first", first}, {"second", second}] do
          %{
            "id" => id,
            "provider" => "anthropic",
            "auth_mode" => "oauth",
            "oauth_file" => file,
            "models" => [%{"model" => "integration-chat", "context_window" => 123_456}]
          }
        end

      loaded =
        config
        |> put_in([:llm, :providers], providers)
        |> put_in([:llm, :default_provider_profile], "second")
        |> save_and_load!()

      for {id, file} <- [{"first", first}, {"second", second}] do
        selected = resolve!(loaded, id)

        assert selected.generation_params[:provider_options] == [
                 auth_mode: :oauth,
                 oauth_file: file
               ]

        assert selected.context_window == 123_456

        assert LLM.oauth_credential_status(selected.runtime_profile) ==
                 {:ok, %{expires: 4_102_444_800_000, account_id: "#{id}-account"}}

        assert File.read!(file) == snapshots[file]
      end

      assert resolve!(loaded, nil).provider_profile_id == "second"
      refute File.exists?(Path.join(dir, "auth.json"))
    end
  end

  describe "normalization and generation boundary edge cases" do
    test "an explicit empty model effort inventory permits overrides without changing sibling inventories",
         %{config: config} do
      config =
        put_in(
          config,
          [:llm, :providers, Access.at(0), "models", Access.at(1), "reasoning_efforts"],
          []
        )

      loaded = save_and_load!(config)

      choice = %{
        provider_profile_id: "personal",
        model: "integration-reasoner",
        reasoning_effort: "xhigh"
      }

      selected = resolve!(loaded, choice)
      assert selected.reasoning_efforts == []
      assert selected.reasoning_effort == "xhigh"
      assert selected.generation_params[:reasoning_effort] == :xhigh
      assert resolve!(loaded, "personal").reasoning_efforts == ["low", "high"]
      assert resolve!(loaded, "work").reasoning_efforts == ["high", "medium"]

      assert resolve!(loaded, %{provider_profile_id: "personal", model: "integration-reasoner"}).reasoning_effort ==
               "high"
    end

    test "canonical model overrides still pass through real provider constraints after persistence",
         %{config: config} do
      provider = %{
        "id" => "constrained",
        "provider" => "zai",
        "concurrency" => 4,
        "temperature" => 0.5,
        "max_tokens" => 1024,
        "reasoning_efforts" => ["low", "high"],
        "default_reasoning_effort" => "high",
        "models" => [
          %{
            "model" => "integration-glm",
            "temperature" => 1.5,
            "max_tokens" => 2048,
            "top_p" => 0.8,
            "top_k" => 10,
            "frequency_penalty" => 0.2,
            "presence_penalty" => 0.3
          }
        ]
      }

      loaded =
        config
        |> put_in([:llm, :providers], [provider])
        |> put_in([:llm, :default_provider_profile], "constrained")
        |> save_and_load!()

      ExUnit.CaptureLog.capture_log(fn ->
        selected = resolve!(loaded, nil)
        assert selected.model_spec == "zai:integration-glm"
        assert selected.concurrency == 4

        assert Map.new(selected.generation_params) == %{
                 max_tokens: 2048,
                 top_p: 0.8,
                 reasoning_effort: :high
               }

        assert selected.runtime_profile.temperature == 1.5
        assert selected.runtime_profile.top_k == 10
      end)

      # Filtering affects only request assembly, not the saved operator intent.
      assert Config.user_config()["llm"]["providers"] == [provider]
    end

    test "manually broken default selectors cannot fall back to first account or stale flat model",
         %{config: config} do
      save_and_load!(config)

      raw =
        Config.user_config()
        |> put_in(["llm", "default_provider_profile"], "deleted-account")
        |> put_in(["llm", "model"], "openai:stale-flat")
        |> put_in(["llm", "models"], [
          %{"id" => "deleted-account", "model" => "openai:stale-legacy"}
        ])

      assert {:ok, toml} = TomlElixir.encode(raw)
      File.write!(Config.config_path(), toml)

      ExUnit.CaptureLog.capture_log(fn ->
        loaded = Config.resolve()

        assert Schema.resolve_model_spec(loaded, nil) ==
                 {:error, {:provider_profile_not_found, "deleted-account"}}

        assert LLM.default_model_profile(loaded) == {:error, :not_found}
        assert LLM.llm_generation_params(loaded) == []
        assert Enum.map(Schema.effective_model_profiles(loaded), & &1.id) == ["personal", "work"]
        assert resolve!(loaded, "personal").model == "integration-chat"
      end)
    end

    test "concurrent per-process config and credential caches never cross account directories",
         %{config: config, dir: dir, key_a: key_a} do
      save_and_load!(config)
      original = Config.user_config()

      tasks =
        for id <- ["personal", "work"] do
          Task.async(fn ->
            ConfigDir.activate(Path.join(dir, id))
            File.mkdir_p!(Config.config_dir())
            File.write!(Config.credentials_path(), "")
            # The SAME credential name deliberately has different values in
            # each config directory; no env var or global ReqLLM key is set.
            assert :ok = Config.save_credentials(%{key_a => "secret-#{id}"})

            own =
              config
              |> put_in([:llm, :providers, Access.at(1), "api_key_env_var"], key_a)
              |> put_in([:llm, :default_provider_profile], id)
              |> save_and_load!()

            chosen = resolve!(own, nil)
            assert chosen.provider_profile_id == id
            assert chosen.generation_params[:api_key] == "secret-#{id}"
            {id, Config.config_path(), chosen}
          end)
        end

      [personal, work] = Task.await_many(tasks, 30_000)
      assert elem(personal, 0) == "personal"
      assert elem(work, 0) == "work"
      refute elem(personal, 1) == elem(work, 1)
      assert Config.user_config() == original
      assert resolve!(Config.resolve(), nil).provider_profile_id == "work"
      assert Config.credentials() == %{}
    end
  end

  describe "invalid canonical writes are rejected without damaging saved config" do
    test "account identity, default selection and nested model/effort errors preserve the previous file",
         %{config: config} do
      loaded = save_and_load!(config)
      contents = File.read!(Config.config_path())

      for {invalid, path} <- [
            {put_in(config, [:llm, :default_provider_profile], "missing"),
             [:llm, :default_provider_profile]},
            {put_in(config, [:llm, :providers, Access.at(1), "id"], "personal"),
             [:llm, :providers, 1, :id]},
            {put_in(config, [:llm, :providers, Access.at(0), "concurrency"], 0),
             [:llm, :providers, 0, :concurrency]},
            {put_in(config, [:llm, :providers, Access.at(0), "default_model"], "missing"),
             [:llm, :providers, 0, :default_model]},
            {put_in(
               config,
               [:llm, :providers, Access.at(0), "models", Access.at(1), "model"],
               "integration-chat"
             ), [:llm, :providers, 0, :models, 1, :model]},
            {put_in(
               config,
               [:llm, :providers, Access.at(0), "models", Access.at(1), "context_window"],
               0
             ), [:llm, :providers, 0, :models, 1, :context_window]},
            {put_in(
               config,
               [
                 :llm,
                 :providers,
                 Access.at(0),
                 "models",
                 Access.at(1),
                 "default_reasoning_effort"
               ],
               "medium"
             ), [:llm, :providers, 0, :models, 1, :default_reasoning_effort]}
          ] do
        assert {:error, errors} = Config.save_user_config(invalid)
        assert Enum.any?(errors, &(&1.key_path == path)), inspect(errors)
        assert File.read!(Config.config_path()) == contents
        assert Config.resolve() == loaded
      end
    end
  end

  defp accounts(key_a, key_b) do
    [
      %{
        "id" => "personal",
        "name" => "Personal",
        "provider" => "openai",
        "auth_mode" => "api_key",
        "api_key_env_var" => key_a,
        "base_url" => "https://personal.invalid/v1",
        "concurrency" => 2,
        "peak_concurrency" => 0,
        "peak_hours" => [%{"start" => "09:00", "end" => "17:00"}],
        "off_peak_days" => ["sun"],
        "timezone" => "UTC",
        "context_window" => 64_000,
        "default_model" => "integration-chat",
        "reasoning_efforts" => ["low", "high"],
        "default_reasoning_effort" => "low",
        "temperature" => 0.4,
        "max_tokens" => 1024,
        "top_p" => 0.75,
        "provider_options" => %{"parallel_tool_calls" => false},
        "models" => [
          %{"model" => "integration-chat"},
          %{
            "model" => "integration-reasoner",
            "context_window" => 96_000,
            "reasoning_efforts" => ["high", "low"],
            "default_reasoning_effort" => "high",
            "temperature" => 0.2,
            "max_tokens" => 2048
          }
        ]
      },
      %{
        "id" => "work",
        "name" => "Work",
        "provider" => "openai",
        "auth_mode" => "api_key",
        "api_key_env_var" => key_b,
        "base_url" => "https://work.invalid/v1",
        "concurrency" => 7,
        "peak_concurrency" => 1,
        "peak_hours" => [%{"start" => "18:00", "end" => "22:00"}],
        "off_peak_days" => ["sat", "sun"],
        "timezone" => "Asia/Hong_Kong",
        "context_window" => 128_000,
        "default_model" => "integration-reasoner",
        "reasoning_efforts" => ["medium", "high"],
        "default_reasoning_effort" => "medium",
        "temperature" => 0.8,
        "max_tokens" => 3072,
        "top_p" => 0.9,
        "provider_options" => %{"parallel_tool_calls" => true},
        "models" => [
          %{"model" => "integration-chat"},
          %{
            "model" => "integration-reasoner",
            "context_window" => 192_000,
            "reasoning_efforts" => ["high", "medium"],
            "default_reasoning_effort" => "high",
            "temperature" => 0.6,
            "max_tokens" => 4096
          }
        ]
      }
    ]
  end

  defp selection(id, name, model, window, efforts, default) do
    %{
      provider_profile_id: id,
      profile_name: name,
      provider: "openai",
      model: model,
      context_window: window,
      reasoning_efforts: efforts,
      default_reasoning_effort: default
    }
  end

  defp save_and_load!(config) do
    assert :ok = Config.save_user_config(config)
    Config.resolve()
  end

  defp resolve!(config, choice) do
    assert {:ok, resolved} = Schema.resolve_model_spec(config, choice)
    resolved
  end

  defp oauth_file!(dir, name, account) do
    path = Path.join(dir, "#{name}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "anthropic" => %{
          "type" => "oauth",
          "access" => "fake-#{name}",
          "refresh" => "fake-refresh-#{name}",
          "expires" => 4_102_444_800_000,
          "accountId" => account
        }
      })
    )

    # A future mtime makes the managed entry authoritative over any real vendor
    # CLI file, without a global HOME/auth seam or importing developer tokens.
    File.touch!(path, 4_102_444_800)
    path
  end
end
