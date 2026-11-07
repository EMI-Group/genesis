defmodule EvoGit.CLITest do
  # Helpers, per-process config save/load and pre-enqueue CLI error paths only;
  # no environment/app-env mutations, global Store or scheduler access.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("evogit-cli")
    :ok
  end

  describe "foreign repo parsing" do
    test "parses name:path format" do
      opts = [foreign_repo: "original:/Source/original-proj"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 1
      repo = hd(repos)
      assert repo.id == "original"
      assert repo.root == Path.expand("/Source/original-proj")
      assert repo.description == nil
    end

    test "parses path-only format (uses basename as id)" do
      opts = [foreign_repo: "/Source/my-project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 1
      repo = hd(repos)
      assert repo.id == "my-project"
      assert repo.root == Path.expand("/Source/my-project")
    end

    test "parses multiple -R flags" do
      opts = [foreign_repo: "original:/Source/a", foreign_repo: "reference:/Source/b"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 2
      ids = Enum.map(repos, & &1.id) |> Enum.sort()
      assert ids == ["original", "reference"]
    end

    test "returns empty list when no -R flags" do
      opts = []
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)
      assert repos == []
    end

    test "handles name with underscores" do
      opts = [foreign_repo: "my_repo:/Source/project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      repo = hd(repos)
      assert repo.id == "my_repo"
    end

    test "handles path with nested directories" do
      opts = [foreign_repo: "proj:/Source/deep/nested/project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      repo = hd(repos)
      assert repo.root == Path.expand("/Source/deep/nested/project")
    end

    test "mixed formats: some with name, some without" do
      opts = [foreign_repo: "original:/Source/a", foreign_repo: "/Source/b-project"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 2

      original = Enum.find(repos, &(&1.id == "original"))
      assert original.root == Path.expand("/Source/a")

      basename = Enum.find(repos, &(&1.id == "b-project"))
      assert basename.root == Path.expand("/Source/b-project")
    end

    test "Windows drive-letter path is not split into id:path (-R C:\\...)" do
      opts = [foreign_repo: "C:\\path\\to\\repo"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 1
      repo = hd(repos)
      refute repo.id == "C"
      refute repo.root == "\\path\\to\\repo"
      assert repo.root == Path.expand("C:\\path\\to\\repo")
      assert repo.id == Path.basename("C:\\path\\to\\repo")
    end

    test "Windows drive-letter path with forward slashes is not split (-R D:/...)" do
      opts = [foreign_repo: "D:/Source/proj"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      assert length(repos) == 1
      repo = hd(repos)
      refute repo.id == "D"
      assert repo.id == "proj"
      assert repo.root == Path.expand("D:/Source/proj")
    end

    test "-R repos are read-only by default (writable false, base_sha nil)" do
      opts = [foreign_repo: "original:/Source/original-proj"]
      repos = EvoGit.CLI.do_parse_foreign_repos(opts)

      repo = hd(repos)
      assert repo.writable == false
      assert repo.base_sha == nil
    end
  end

  describe "agent flag parsing (--agent)" do
    test "parses --agent <id> for evolve" do
      {opts, argv} =
        EvoGit.CLI.Parser.parse_args(["--agent", "code-reviewer", "evolve", "fix x"])

      assert opts[:agent] == "code-reviewer"
      assert argv == ["evolve", "fix x"]
    end

    test "parses --agent <id> for genesis" do
      {opts, argv} =
        EvoGit.CLI.Parser.parse_args(["genesis", "make a thing", "--agent", "architect"])

      assert opts[:agent] == "architect"
      assert argv == ["genesis", "make a thing"]
    end

    test "returns nil when --agent is not passed" do
      {opts, _argv} = EvoGit.CLI.Parser.parse_args(["evolve", "fix x"])
      assert opts[:agent] == nil
    end

    test "supports --agent=<id> syntax" do
      {opts, _argv} = EvoGit.CLI.Parser.parse_args(["evolve", "fix x", "--agent=code-reviewer"])
      assert opts[:agent] == "code-reviewer"
    end
  end

  describe "model flag parsing (-m / --model)" do
    test "bare model string returns nil id" do
      # "provider:model" → {nil, "provider:model"}
      assert EvoGit.CLI.do_parse_model_flag("anthropic:claude-sonnet-4-20250514") ==
               {nil, "anthropic:claude-sonnet-4-20250514"}
    end

    test "id:provider:model syntax extracts the id" do
      assert EvoGit.CLI.do_parse_model_flag("fast:anthropic:claude-haiku") ==
               {"fast", "anthropic:claude-haiku"}
    end

    test "string with no colon returns nil id" do
      assert EvoGit.CLI.do_parse_model_flag("just-a-model-name") ==
               {nil, "just-a-model-name"}
    end

    test "two-part string (provider:model) is treated as bare model" do
      # Only one colon = two parts = not an id prefix
      assert EvoGit.CLI.do_parse_model_flag("google:gemini-flash") ==
               {nil, "google:gemini-flash"}
    end

    test "id:provider:model with empty parts falls back to bare model" do
      # Empty id prefix ":provider:model"
      assert EvoGit.CLI.do_parse_model_flag(":provider:model") == {nil, ":provider:model"}
    end

    test "id with dots and hyphens" do
      assert EvoGit.CLI.do_parse_model_flag("my.profile-1:anthropic:claude") ==
               {"my.profile-1", "anthropic:claude"}
    end
  end

  describe "setup wizard canonical provider writing" do
    test "adds a default account with an unqualified model to empty config" do
      result = EvoGit.CLI.do_add_model_profile(%{llm: %{providers: []}}, "anthropic:test-model")

      assert result.llm.default_provider_profile == "default"
      assert [profile] = result.llm.providers

      assert profile == %{
               id: "default",
               provider: "anthropic",
               concurrency: 3,
               reasoning_efforts: [],
               default_model: "test-model",
               models: [%{model: "test-model"}]
             }

      refute Map.has_key?(result.llm, :model)
      refute Map.has_key?(result.llm, :models)
      assert {:ok, _} = Schema.validate(result)
    end

    test "updates the selected account without losing shared settings or model overrides" do
      profile = selection_config().llm.providers |> hd()
      config = %{llm: %{default_provider_profile: profile.id, providers: [profile]}}
      result = EvoGit.CLI.do_add_model_profile(config, "openai:new-model")

      assert result.llm.default_provider_profile == profile.id

      assert result.llm.providers == [
               %{profile | default_model: "new-model"}
               |> Map.put(:models, profile.models ++ [%{model: "new-model"}])
             ]

      assert {:ok, _} = Schema.validate(result)
    end

    test "choosing another provider appends an account and retains existing accounts" do
      config = selection_config()
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:test-model")

      assert [existing, added] = result.llm.providers
      # Normalization materializes the default API-key auth mode for an
      # untouched account; all its explicit settings remain unchanged.
      assert existing == Map.put(hd(config.llm.providers), :auth_mode, "api_key")
      assert result.llm.default_provider_profile == added.id
      assert added.provider == "anthropic"
      assert added.concurrency == 3
      assert added.default_model == "test-model"
      assert added.models == [%{model: "test-model"}]
      assert {:ok, _} = Schema.validate(result)
    end

    test "legacy inputs migrate to accounts instead of reintroducing flat model mirrors" do
      for llm <- [
            %{model: "anthropic:old-model", temperature: 0.4},
            %{models: [%{id: "default", model: "anthropic:old-model", concurrency: 5}]}
          ] do
        result = EvoGit.CLI.do_add_model_profile(%{llm: llm}, "anthropic:new-model")

        assert result.llm.default_provider_profile == "default"
        assert [profile] = result.llm.providers
        assert profile.default_model == "new-model"
        assert profile.models == [%{model: "old-model"}, %{model: "new-model"}]
        if Map.has_key?(llm, :models), do: assert(profile.concurrency == 5)
        if Map.has_key?(llm, :temperature), do: assert(profile.temperature == 0.4)
        refute Map.has_key?(result.llm, :model)
        refute Map.has_key?(result.llm, :models)
        refute Map.has_key?(result.llm, :temperature)
        assert {:ok, _} = Schema.validate(result)
      end
    end

    test "string and map specs round-trip through actual canonical config serialization" do
      for spec <- [
            "anthropic:test-model",
            %{provider: :anthropic, id: "claude-sonnet-4"},
            %{provider: :openai, id: "gpt-5.6-terra", base_url: "https://x/v1"}
          ] do
        result = EvoGit.CLI.do_add_model_profile(%{}, spec)
        assert {:ok, _} = Schema.validate(result)
        assert :ok = Config.save_user_config(result)
        toml = File.read!(Path.join(Config.config_dir(), "config.toml"))
        assert toml =~ "[[llm.providers]]"
        assert toml =~ "[[llm.providers.models]]"
        refute toml =~ "[[llm.models]]"

        assert {:ok, decoded} = TomlElixir.decode(toml)
        assert Schema.provider_profiles(decoded) == Schema.provider_profiles(result)
        assert Schema.provider_profiles(Config.user_config()) == Schema.provider_profiles(result)
        assert decoded["llm"]["default_provider_profile"] == "default"
        refute Map.has_key?(decoded["llm"], "model")
        refute Map.has_key?(decoded["llm"], "models")

        assert [profile] = result.llm.providers
        assert profile.models == [%{model: profile.default_model}]

        if is_map(spec) && Map.has_key?(spec, :base_url) do
          assert profile.base_url == spec.base_url
          assert profile.provider == "openai"
          assert profile.default_model == spec.id
        end
      end
    end

    test "map spec update keeps account limits and does not duplicate an existing model" do
      config = selection_config()
      spec = %{provider: :openai, id: "review-model", base_url: "https://new.example/v1"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      assert [profile] = result.llm.providers
      original = hd(config.llm.providers)
      assert profile == %{original | default_model: spec.id, base_url: spec.base_url}
      assert {:ok, _} = Schema.validate(result)
    end
  end

  describe "evolve custom-mode dispatch" do
    test "--mode custom without --agent prints a clear error" do
      output =
        capture_io(fn ->
          EvoGit.CLI.main(["evolve", "fix x", "--mode", "custom"])
        end)

      assert output =~ "requires --agent"
    end

    test "invalid evolve mode prints an error" do
      output =
        capture_io(fn ->
          EvoGit.CLI.main(["evolve", "fix x", "--mode", "bogus"])
        end)

      assert output =~ "Invalid mode for evolve. Use 'simple' or 'custom'."
    end

    test "genesis --mode custom prints the evolve-only error" do
      output =
        capture_io(fn ->
          EvoGit.CLI.main(["genesis", "make a thing", "--mode", "custom"])
        end)

      assert output =~ "custom mode is evolve-only"
    end
  end

  describe "resolve_model_opts/2 canonical task selections" do
    test "Auto omits the selection and lock even with a configured default" do
      assert EvoGit.CLI.resolve_model_opts([], selection_config()) == {:ok, []}
    end

    test "legacy account ids, id prefixes and model names select from the canonical inventory" do
      for value <- ["account", "account:ignored:ignored", "openai:fast-model", "fast-model"] do
        assert {:ok, opts} = EvoGit.CLI.resolve_model_opts([model: value], selection_config())

        assert opts == [
                 model_spec: %{
                   "provider_profile_id" => "account",
                   "model" => "fast-model",
                   "reasoning_effort" => "low"
                 },
                 model_id_locked: true
               ]
      end
    end

    test "explicit flags preserve account, model and effort through the real parser" do
      {flags, ["evolve", "fix x"]} =
        EvoGit.CLI.Parser.parse_args([
          "evolve",
          "fix x",
          "--provider-profile",
          "account",
          "--model",
          "review-model",
          "--reasoning-effort",
          "high"
        ])

      config = selection_config()
      assert :ok = Config.save_credentials(%{"EVOGIT_CLI_ACCOUNT_TEST_KEY" => "private-key"})

      selection = %{
        "provider_profile_id" => "account",
        "model" => "review-model",
        "reasoning_effort" => "high"
      }

      assert {:ok, resolved} = Schema.resolve_model_spec(config, selection)
      # This is a ReqLLM identifier/override, NOT the serializable task selection.
      assert resolved.model_spec == %{
               provider: :openai,
               id: "review-model",
               base_url: "https://cli.example/v1"
             }

      assert resolved.generation_params[:api_key] == "private-key"
      assert resolved.generation_params[:temperature] == 0.3
      assert resolved.context_window == 64_000

      assert {:ok, opts} = EvoGit.CLI.resolve_model_opts(flags, config)
      assert opts == [model_spec: selection, model_id_locked: true]
      refute inspect(opts) =~ "private-key"
      refute inspect(opts) =~ "https://cli.example"
    end

    test "explicit selection inherits the model's default effort, not the account default" do
      assert {:ok, opts} =
               EvoGit.CLI.resolve_model_opts(
                 [provider_profile: "account", model: "review-model"],
                 selection_config()
               )

      assert opts[:model_spec] == %{
               "provider_profile_id" => "account",
               "model" => "review-model",
               "reasoning_effort" => "high"
             }
    end

    test "an account with no configured default effort omits effort from the task spec" do
      config = %{
        llm: %{
          default_provider_profile: "plain",
          providers: [
            %{
              id: "plain",
              provider: "openai",
              concurrency: 3,
              default_model: "plain-model",
              reasoning_efforts: [],
              models: [%{model: "plain-model", context_window: 32_000}]
            }
          ]
        }
      }

      assert {:ok, opts} = EvoGit.CLI.resolve_model_opts([model: "plain"], config)

      assert opts == [
               model_spec: %{"provider_profile_id" => "plain", "model" => "plain-model"},
               model_id_locked: true
             ]
    end

    test "invalid explicit flags and unavailable inventory choices do not fall back" do
      for flags <- [
            [provider_profile: "account"],
            [reasoning_effort: "high", model: "review-model"],
            [provider_profile: "", model: "review-model"],
            [provider_profile: "account", model: ""],
            [provider_profile: "account", model: "review-model", reasoning_effort: ""],
            [provider_profile: "missing", model: "review-model"],
            [provider_profile: "account", model: "missing"],
            [provider_profile: "account", model: "review-model", reasoning_effort: "low"]
          ] do
        assert {:error, message} = EvoGit.CLI.resolve_model_opts(flags, selection_config())
        assert is_binary(message) and message != ""
      end
    end
  end

  # Compatibility helper still accepts legacy model-profile lists; live CLI
  # selections above use canonical provider accounts instead.
  describe "resolve_model_id/2 legacy helper" do
    @resolve_profiles [
      %{id: "fast", model: "anthropic:claude-haiku"},
      %{id: "deep", model: "deepseek:deepseek-v4-pro"},
      %{id: "mapy", model: %{provider: :openai, id: "gpt-5", base_url: "https://x/v1"}}
    ]

    test "exact profile id match resolves to that id" do
      assert EvoGit.CLI.resolve_model_id("fast", @resolve_profiles) == {:ok, "fast"}
      assert EvoGit.CLI.resolve_model_id("mapy", @resolve_profiles) == {:ok, "mapy"}
    end

    test "id:provider:model syntax resolves a configured id" do
      assert EvoGit.CLI.resolve_model_id("deep:deepseek:deepseek-v4-pro", @resolve_profiles) ==
               {:ok, "deep"}
    end

    test "id:provider:model with a configured id wins even when the model part matches nothing" do
      assert EvoGit.CLI.resolve_model_id("fast:whatever:model", @resolve_profiles) ==
               {:ok, "fast"}
    end

    test "bare provider:model matching a profile's binary model resolves to that profile id" do
      assert EvoGit.CLI.resolve_model_id("anthropic:claude-haiku", @resolve_profiles) ==
               {:ok, "fast"}
    end

    test "bare model string matching nothing returns an error" do
      assert {:error, msg} = EvoGit.CLI.resolve_model_id("nope:no-such-model", @resolve_profiles)
      assert is_binary(msg)
      assert msg != ""
    end

    test "id:provider:model with an unconfigured id errors and lists available profile ids" do
      assert {:error, msg} =
               EvoGit.CLI.resolve_model_id("ghost:anthropic:claude", @resolve_profiles)

      assert Enum.any?(["fast", "deep", "mapy"], &String.contains?(msg, &1))
    end

    test "no profiles configured returns an error mentioning that nothing is configured" do
      assert {:error, msg} = EvoGit.CLI.resolve_model_id("fast", [])
      assert msg =~ ~r/model/i or msg =~ ~r/profile/i
    end

    test "map-spec profile never matches by model-string but still matches by id" do
      # The mapy profile's model is a map, so a bare provider:model or model
      # string must NOT match it...
      assert {:error, _} = EvoGit.CLI.resolve_model_id("openai:gpt-5", @resolve_profiles)

      # ...but its id resolves, both bare and as an id:provider:model prefix.
      assert EvoGit.CLI.resolve_model_id("mapy", @resolve_profiles) == {:ok, "mapy"}
      assert EvoGit.CLI.resolve_model_id("mapy:openai:gpt-5", @resolve_profiles) == {:ok, "mapy"}
    end
  end

  defp selection_config do
    %{
      llm: %{
        default_provider_profile: "account",
        providers: [
          %{
            id: "account",
            provider: "openai",
            base_url: "https://cli.example/v1",
            api_key_env_var: "EVOGIT_CLI_ACCOUNT_TEST_KEY",
            concurrency: 5,
            temperature: 0.6,
            default_model: "fast-model",
            reasoning_efforts: ["low", "high"],
            default_reasoning_effort: "low",
            models: [
              %{model: "fast-model", context_window: 128_000},
              %{
                model: "review-model",
                context_window: 64_000,
                temperature: 0.3,
                reasoning_efforts: ["high"],
                default_reasoning_effort: "high"
              }
            ]
          }
        ]
      }
    }
  end
end
