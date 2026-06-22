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

      # LLM
      assert [:llm, :model] in paths
      assert [:llm, :compression_threshold_tokens] in paths

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

    test "has exactly 33 schemas" do
      assert length(Schema.all_schemas()) == 33
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
    end

    test "each category has expected count" do
      grouped = Schema.schemas_by_category()
      assert length(grouped[:scheduler]) == 8
      assert length(grouped[:llm]) == 9
      assert length(grouped[:user]) == 1
      assert length(grouped[:sandbox]) == 9
      assert length(grouped[:truncation]) == 4
      assert length(grouped[:task_history]) == 2
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
end
