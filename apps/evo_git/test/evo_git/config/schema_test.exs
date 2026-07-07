defmodule EvoGit.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.ValidationError

  describe "all_schemas/0" do
    test "returns all expected key paths" do
      schemas = Schema.all_schemas()
      assert is_list(schemas)
      assert length(schemas) > 0

      paths = Enum.map(schemas, & &1.key_path)

      # Scheduler
      assert [:scheduler, :max_concurrency] in paths
      assert [:scheduler, :max_tool_concurrency] in paths
      assert [:scheduler, :agent_max_retries] in paths
      assert [:scheduler, :max_agent_depth] in paths
      assert [:scheduler, :max_retries] in paths
      assert [:scheduler, :max_turns] in paths
      assert [:scheduler, :max_turns_root] in paths
      assert [:scheduler, :delegation_hint_threshold] in paths
      assert [:scheduler, :read_delegation_hint_threshold] in paths
      assert [:scheduler, :max_tool_timeout] in paths
      assert [:scheduler, :default_tool_timeout] in paths

      # LLM
      assert [:llm, :model] in paths
      assert [:llm, :compression_threshold_tokens] in paths
      assert [:llm, :models] in paths

      # User
      assert [:user, :github_username] in paths

      # Sandbox
      assert [:sandbox, :mode] in paths
      assert [:sandbox, :resources, :cpu_quota] in paths
      assert [:sandbox, :resources, :cpu_weight] in paths
      assert [:sandbox, :resources, :memory_max] in paths
      assert [:sandbox, :resources, :tasks_max] in paths
      assert [:sandbox, :process, :cpu_quota] in paths
      assert [:sandbox, :process, :memory_max] in paths
      assert [:sandbox, :process, :limit_nofile] in paths
      assert [:sandbox, :process, :oom_score_adjust] in paths

      # Truncation
      assert [:truncation, :tool_output_max_bytes] in paths
      assert [:truncation, :tool_output_default_max_bytes] in paths
      assert [:truncation, :tool_output_truncate_size] in paths
      assert [:truncation, :context_max_bytes] in paths

      # Task History
      assert [:task_history, :max_tasks] in paths
      assert [:task_history, :max_age_days] in paths

      # Nix
      assert [:nix, :enabled] in paths
      assert [:nix, :flake_output] in paths

      # Tools
      assert [:tools, :search, :enabled] in paths
      assert [:tools, :search, :provider] in paths
      assert [:tools, :search, :tavily, :api_key_env_var] in paths
      assert [:tools, :search, :tavily, :base_url] in paths
      assert [:tools, :search, :tavily, :search_depth] in paths
      assert [:tools, :search, :tavily, :max_results] in paths
      assert [:tools, :search, :tavily, :timeout] in paths
      assert [:tools, :search, :tavily, :max_bytes] in paths

      # Server
      assert [:server, :listen_ip] in paths
      assert [:server, :listen_port] in paths
    end

    test "every schema has required fields" do
      for schema <- Schema.all_schemas() do
        assert Map.has_key?(schema, :key_path), "missing :key_path in #{inspect(schema.key_path)}"
        assert Map.has_key?(schema, :type), "missing :type in #{inspect(schema.key_path)}"
        assert Map.has_key?(schema, :default) or Map.has_key?(schema, :default), "missing :default in #{inspect(schema.key_path)}"
        assert Map.has_key?(schema, :validation), "missing :validation in #{inspect(schema.key_path)}"
        assert Map.has_key?(schema, :category), "missing :category in #{inspect(schema.key_path)}"
        assert Map.has_key?(schema, :sub_category), "missing :sub_category in #{inspect(schema.key_path)}"
        assert Map.has_key?(schema, :description), "missing :description in #{inspect(schema.key_path)}"
        assert is_binary(schema.description), "description must be a string for #{inspect(schema.key_path)}"
        assert String.length(schema.description) > 0, "description must not be empty for #{inspect(schema.key_path)}"
      end
    end

    test "has exactly 49 schemas" do
      assert length(Schema.all_schemas()) == 49
    end
  end

  describe "defaults/0" do
    test "returns a properly structured defaults map" do
      defaults = Schema.defaults()
      assert is_map(defaults)

      # Scheduler
      assert defaults.scheduler.max_concurrency == 3
      assert defaults.scheduler.max_tool_concurrency == 2
      assert defaults.scheduler.agent_max_retries == 3
      assert defaults.scheduler.max_agent_depth == 8
      assert defaults.scheduler.max_retries == 15
      assert defaults.scheduler.max_turns == 128
      assert defaults.scheduler.max_turns_root == 128
      assert defaults.scheduler.delegation_hint_threshold == 5
      assert defaults.scheduler.read_delegation_hint_threshold == 8
      assert defaults.scheduler.max_tool_timeout == 1_800_000
      assert defaults.scheduler.default_tool_timeout == 10_000

      # LLM
      assert defaults.llm.model == nil
      assert defaults.llm.compression_threshold_tokens == 100_000

      # User
      assert defaults.user.github_username == nil

      # Sandbox
      assert defaults.sandbox.mode == :auto
      assert defaults.sandbox.resources.cpu_quota == "1000%"
      assert defaults.sandbox.resources.cpu_weight == 30
      assert defaults.sandbox.resources.memory_max == "16G"
      assert defaults.sandbox.resources.tasks_max == 8196
      assert defaults.sandbox.process.cpu_quota == "800%"
      assert defaults.sandbox.process.memory_max == "12G"
      assert defaults.sandbox.process.limit_nofile == 65536
      assert defaults.sandbox.process.oom_score_adjust == 1000

      # Truncation
      assert defaults.truncation.tool_output_max_bytes == 131_072
      assert defaults.truncation.tool_output_default_max_bytes == 16_384
      assert defaults.truncation.tool_output_truncate_size == 8_192
      assert defaults.truncation.context_max_bytes == 65_536

      # Task History
      assert defaults.task_history.max_tasks == 100
      assert defaults.task_history.max_age_days == 14

      # Nix
      assert defaults.nix.enabled == false
      assert defaults.nix.flake_output == nil

      # Tools
      assert defaults.tools.search.enabled == false
      assert defaults.tools.search.provider == :tavily
      assert defaults.tools.search.tavily.api_key_env_var == "TAVILY_API_KEY"
      assert defaults.tools.search.tavily.base_url == "https://api.tavily.com/search"
      assert defaults.tools.search.tavily.search_depth == :basic
      assert defaults.tools.search.tavily.max_results == 10
      assert defaults.tools.search.tavily.timeout == 60000
      assert defaults.tools.search.tavily.max_bytes == 16384

      # Server
      assert defaults.server.listen_ip == "127.0.0.1"
      assert defaults.server.listen_port == 4000
    end

    test "llm model has nil default" do
      defaults = Schema.defaults()
      assert Map.has_key?(defaults.llm, :model)
      assert defaults.llm.model == nil
    end

    test "github username has nil default" do
      defaults = Schema.defaults()
      assert Map.has_key?(defaults.user, :github_username)
      assert defaults.user.github_username == nil
    end
  end

  describe "schemas_by_category/0" do
    test "returns correct categories" do
      grouped = Schema.schemas_by_category()
      assert Map.has_key?(grouped, :scheduler)
      assert Map.has_key?(grouped, :llm)
      assert Map.has_key?(grouped, :user)
      assert Map.has_key?(grouped, :sandbox)
      assert Map.has_key?(grouped, :truncation)
      assert Map.has_key?(grouped, :task_history)
      assert Map.has_key?(grouped, :nix)
      assert Map.has_key?(grouped, :server)
      assert Map.has_key?(grouped, :tools)
    end

    test "each category has expected count" do
      grouped = Schema.schemas_by_category()
      assert length(grouped[:scheduler]) == 11
      assert length(grouped[:llm]) == 10
      assert length(grouped[:user]) == 1
      assert length(grouped[:sandbox]) == 9
      assert length(grouped[:truncation]) == 4
      assert length(grouped[:task_history]) == 2
      assert length(grouped[:nix]) == 2
      assert length(grouped[:server]) == 2
      assert length(grouped[:tools]) == 8
    end

    test "sandbox schemas include sub_category metadata" do
      grouped = Schema.schemas_by_category()
      sandbox = grouped[:sandbox]

      resources = Enum.filter(sandbox, &(&1.sub_category == :resources))
      process = Enum.filter(sandbox, &(&1.sub_category == :process))

      assert length(resources) == 4
      assert length(process) == 4
    end
  end

  describe "validate/1" do
    test "returns ok for valid config (defaults)" do
      config = Schema.defaults()
      assert {:ok, _} = Schema.validate(config)
    end

    test "catches pos_integer with negative value" do
      config = put_in(Schema.defaults(), [:scheduler, :max_concurrency], -1)
      assert {:error, errors} = Schema.validate(config)
      assert length(errors) > 0
      error = List.first(errors)
      assert error.key_path == [:scheduler, :max_concurrency]
      assert error.value == -1
      assert error.rule == :pos_integer
    end

    test "catches pos_integer with zero value" do
      config = put_in(Schema.defaults(), [:scheduler, :max_concurrency], 0)
      assert {:error, errors} = Schema.validate(config)
      assert length(errors) > 0
    end

    test "catches non_neg_integer with negative value" do
      config = put_in(Schema.defaults(), [:scheduler, :agent_max_retries], -1)
      assert {:error, errors} = Schema.validate(config)
      assert length(errors) > 0
      error = List.first(errors)
      assert error.key_path == [:scheduler, :agent_max_retries]
    end

    test "accepts non_neg_integer with zero value" do
      config = put_in(Schema.defaults(), [:scheduler, :agent_max_retries], 0)
      assert {:ok, _} = Schema.validate(config)
    end

    test "catches pos_integer with out of range max" do
      config = put_in(Schema.defaults(), [:sandbox, :resources, :cpu_weight], 20_000)
      assert {:error, errors} = Schema.validate(config)
      assert length(errors) > 0
      error = List.first(errors)
      assert error.key_path == [:sandbox, :resources, :cpu_weight]
      assert error.rule == {:max, 10_000}
    end

    test "catches invalid enum value" do
      config = put_in(Schema.defaults(), [:sandbox, :mode], :invalid_mode)
      assert {:error, errors} = Schema.validate(config)
      assert length(errors) > 0
      error = List.first(errors)
      assert error.key_path == [:sandbox, :mode]
      assert error.rule == {:in, [:auto, :enabled, :disabled]}
    end

    test "catches string for integer field" do
      config = put_in(Schema.defaults(), [:scheduler, :max_concurrency], "not_a_number")
      assert {:error, _} = Schema.validate(config)
    end

    test "catches integer for string field" do
      config = put_in(Schema.defaults(), [:sandbox, :resources, :cpu_quota], 1000)
      assert {:error, _} = Schema.validate(config)
    end

    test "collects multiple errors" do
      config =
        Schema.defaults()
        |> put_in([:scheduler, :max_concurrency], -1)
        |> put_in([:sandbox, :resources, :cpu_weight], 20_000)

      assert {:error, errors} = Schema.validate(config)
      assert length(errors) >= 2
    end

    test "nil values are skipped" do
      config = put_in(Schema.defaults(), [:llm, :model], nil)
      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts integer within range" do
      config = put_in(Schema.defaults(), [:sandbox, :process, :oom_score_adjust], 0)
      assert {:ok, _} = Schema.validate(config)
    end

    test "catches integer out of range (min)" do
      config = put_in(Schema.defaults(), [:sandbox, :process, :oom_score_adjust], -2000)
      assert {:error, errors} = Schema.validate(config)
      error = List.first(errors)
      assert error.rule == {:min, -1000}
    end

    test "catches integer out of range (max)" do
      config = put_in(Schema.defaults(), [:sandbox, :process, :oom_score_adjust], 2000)
      assert {:error, errors} = Schema.validate(config)
      error = List.first(errors)
      assert error.rule == {:max, 1000}
    end

    test "catches sandbox cpu_weight out of range" do
      config = put_in(Schema.defaults(), [:sandbox, :resources, :cpu_weight], 20_000)
      assert {:error, errors} = Schema.validate(config)
      error = List.first(errors)
      assert error.rule == {:max, 10_000}
    end

    test "accepts valid sandbox modes" do
      for mode <- [:auto, :enabled, :disabled] do
        config = put_in(Schema.defaults(), [:sandbox, :mode], mode)
        assert {:ok, _} = Schema.validate(config)
      end
    end

    test "ValidationError has all required fields" do
      config = put_in(Schema.defaults(), [:scheduler, :max_concurrency], -1)
      {:error, [error | _]} = Schema.validate(config)

      assert %ValidationError{} = error
      assert error.key_path == [:scheduler, :max_concurrency]
      assert is_binary(error.message)
      assert error.value == -1
      assert is_atom(error.rule) or is_tuple(error.rule)
    end
  end

  describe "model_spec type for [:llm, :model]" do
    test "the schema entry for [:llm, :model] has type: :model_spec" do
      entry =
        Enum.find(Schema.all_schemas(), &(&1.key_path == [:llm, :model]))

      assert entry != nil
      assert entry.type == :model_spec
    end

    test "accepts a string model spec" do
      config = put_in(Schema.defaults(), [:llm, :model], "anthropic:claude-sonnet-4")
      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts an atom-keyed map model spec" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          provider: :openai,
          id: "my-model",
          base_url: "https://x"
        })

      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts a string-keyed map model spec" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          "provider" => "openai",
          "id" => "my-model"
        })

      assert {:ok, _} = Schema.validate(config)
    end

    test "rejects a map missing the provider key" do
      config = put_in(Schema.defaults(), [:llm, :model], %{id: "no-provider"})
      assert {:error, _} = Schema.validate(config)
    end

    test "rejects a map missing the id key" do
      config = put_in(Schema.defaults(), [:llm, :model], %{provider: :openai})
      assert {:error, _} = Schema.validate(config)
    end

    test "rejects a non-string/non-map value" do
      config = put_in(Schema.defaults(), [:llm, :model], 12345)
      assert {:error, _} = Schema.validate(config)
    end

    test "nil is still accepted" do
      config = put_in(Schema.defaults(), [:llm, :model], nil)
      assert {:ok, _} = Schema.validate(config)
    end
  end

  describe "model_spec :extra validation for [:llm, :model]" do
    # The :extra key on a model spec map is optional, but when present it must
    # be a map (carries arbitrary provider-specific metadata, e.g. %{family: "glm"}).

    test "accepts a map with atom-keyed extra" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          provider: :openai,
          id: "my-model",
          extra: %{family: "glm"}
        })

      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts a map with string-keyed extra" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          "extra" => %{family: "glm"},
          provider: :openai,
          id: "my-model"
        })

      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts a map without extra" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          provider: :openai,
          id: "my-model"
        })

      assert {:ok, _} = Schema.validate(config)
    end

    test "rejects a map where extra is a string" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          provider: :openai,
          id: "my-model",
          extra: "not a map"
        })

      assert {:error, errors} = Schema.validate(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e ->
        String.contains?(e.message, "extra")
      end)
    end

    test "rejects a map where extra is a list" do
      config =
        put_in(Schema.defaults(), [:llm, :model], %{
          provider: :openai,
          id: "my-model",
          extra: [1, 2, 3]
        })

      assert {:error, errors} = Schema.validate(config)
      assert is_list(errors)
      assert Enum.any?(errors, fn e ->
        String.contains?(e.message, "extra")
      end)
    end
  end

  describe "model_profiles type for [:llm, :models]" do
    test "the schema entry for [:llm, :models] has type: :model_profiles" do
      entry =
        Enum.find(Schema.all_schemas(), &(&1.key_path == [:llm, :models]))

      assert entry != nil
      assert entry.type == :model_profiles
      assert entry.default == []
    end

    test "accepts an empty list" do
      config = put_in(Schema.defaults(), [:llm, :models], [])
      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts a single valid profile" do
      config = put_in(Schema.defaults(), [:llm, :models], [
        %{id: "default", model: "anthropic:claude-sonnet-4"}
      ])
      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts multiple valid profiles" do
      config = put_in(Schema.defaults(), [:llm, :models], [
        %{id: "default", model: "anthropic:claude-sonnet-4", concurrency: 5},
        %{id: "fast", model: "google:gemini-flash", temperature: 0.5}
      ])
      assert {:ok, _} = Schema.validate(config)
    end

    test "accepts a map-model profile" do
      config = put_in(Schema.defaults(), [:llm, :models], [
        %{id: "openai-custom", model: %{provider: "openai", id: "my-model", base_url: "https://x"}}
      ])
      assert {:ok, _} = Schema.validate(config)
    end

    test "rejects a profile missing id" do
      config = put_in(Schema.defaults(), [:llm, :models], [
        %{model: "anthropic:claude-sonnet-4"}
      ])
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, &(&1.key_path == [:llm, :models, 0, :id]))
    end

    test "rejects a profile with empty id" do
      config = put_in(Schema.defaults(), [:llm, :models], [
        %{id: "", model: "anthropic:claude-sonnet-4"}
      ])
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, &(&1.key_path == [:llm, :models, 0, :id]))
    end

    test "rejects a profile missing model" do
      config = put_in(Schema.defaults(), [:llm, :models], [
        %{id: "default"}
      ])
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, &(&1.key_path == [:llm, :models, 0, :model]))
    end

    test "rejects a non-list value" do
      config = put_in(Schema.defaults(), [:llm, :models], "not-a-list")
      assert {:error, _} = Schema.validate(config)
    end

    test "rejects a profile that is not a map" do
      config = put_in(Schema.defaults(), [:llm, :models], ["not-a-map"])
      assert {:error, _} = Schema.validate(config)
    end
  end

  describe "model_profiles/1" do
    test "returns the list of profiles from config" do
      config = %{llm: %{models: [%{id: "default", model: "x:y"}, %{id: "fast", model: "a:b"}]}}
      profiles = Schema.model_profiles(config)
      assert length(profiles) == 2
      assert Enum.at(profiles, 0).id == "default"
      assert Enum.at(profiles, 1).id == "fast"
    end

    test "returns empty list when no models key" do
      config = %{llm: %{}}
      assert Schema.model_profiles(config) == []
    end

    test "returns empty list when no llm key" do
      config = %{}
      assert Schema.model_profiles(config) == []
    end
  end

  describe "get_model_profile/2" do
    test "returns {:ok, profile} when found" do
      config = %{llm: %{models: [%{id: "default", model: "x:y"}, %{id: "fast", model: "a:b"}]}}

      assert {:ok, profile} = Schema.get_model_profile(config, "fast")
      assert profile.id == "fast"
      assert profile.model == "a:b"
    end

    test "returns {:error, :not_found} when id not present" do
      config = %{llm: %{models: [%{id: "default", model: "x:y"}]}}
      assert {:error, :not_found} = Schema.get_model_profile(config, "nonexistent")
    end

    test "returns {:error, :not_found} when no profiles" do
      config = %{llm: %{}}
      assert {:error, :not_found} = Schema.get_model_profile(config, "default")
    end
  end

  describe "default_model_profile/1" do
    test "returns the first profile" do
      config = %{llm: %{models: [%{id: "first", model: "x:y"}, %{id: "second", model: "a:b"}]}}
      assert {:ok, profile} = Schema.default_model_profile(config)
      assert profile.id == "first"
    end

    test "returns {:error, :not_found} when empty" do
      config = %{llm: %{models: []}}
      assert {:error, :not_found} = Schema.default_model_profile(config)
    end
  end

  describe "llm_generation_params/1 with model profile" do
    test "extracts params from a profile map" do
      profile = %{id: "default", temperature: 0.7, max_tokens: 4096}
      params = Schema.llm_generation_params(profile)
      assert Keyword.get(params, :temperature) == 0.7
      assert Keyword.get(params, :max_tokens) == 4096
    end

    test "filters nil params from profile" do
      profile = %{id: "default", temperature: 0.7, max_tokens: nil}
      params = Schema.llm_generation_params(profile)
      assert Keyword.get(params, :temperature) == 0.7
      refute Keyword.has_key?(params, :max_tokens)
    end

    test "converts reasoning_effort from string to atom in profile" do
      profile = %{id: "default", reasoning_effort: "high"}
      params = Schema.llm_generation_params(profile)
      assert Keyword.get(params, :reasoning_effort) == :high
    end

    test "returns empty list for profile with no gen params" do
      profile = %{id: "default", model: "x:y"}
      assert Schema.llm_generation_params(profile) == []
    end

    test "delegates to default profile when given a config map" do
      config = %{llm: %{models: [%{id: "default", temperature: 0.9}]}}
      params = Schema.llm_generation_params(config)
      assert Keyword.get(params, :temperature) == 0.9
    end

    test "returns empty list when no profiles in config" do
      config = %{llm: %{models: []}}
      assert Schema.llm_generation_params(config) == []
    end
  end
end
