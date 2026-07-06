defmodule EvoGit.CLITest do
  use ExUnit.Case, async: true

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

  describe "setup wizard model profile writing" do
    test "adds model to empty config as default profile" do
      config = %{llm: %{models: []}}
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:test-model")

      models = get_in(result, [:llm, :models])
      assert length(models) == 1

      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == "anthropic:test-model"
      assert profile.concurrency == 3
    end

    test "updates existing default profile model" do
      config = %{llm: %{models: [%{id: "default", model: "old-model", concurrency: 5}]}}
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:new-model")

      models = get_in(result, [:llm, :models])
      assert length(models) == 1

      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == "anthropic:new-model"
      # concurrency preserved from existing profile
      assert profile.concurrency == 5
    end

    test "appends default profile when only non-default profiles exist" do
      config = %{llm: %{models: [%{id: "fast", model: "google:flash", concurrency: 2}]}}
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:test-model")

      models = get_in(result, [:llm, :models])
      assert length(models) == 2

      default = Enum.find(models, &(&1.id == "default"))
      assert default.model == "anthropic:test-model"
      assert default.concurrency == 3

      fast = Enum.find(models, &(&1.id == "fast"))
      assert fast.model == "google:flash"
    end

    test "mirrors model to llm.model for backward compat" do
      config = %{llm: %{models: []}}
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:test-model")

      assert get_in(result, [:llm, :model]) == "anthropic:test-model"
    end

    test "produces config that passes Schema validation" do
      config = %{llm: %{models: []}}
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:claude-sonnet-4-20250514")

      assert {:ok, _} = EvoGit.Config.Schema.validate(result)
    end

    test "produces valid [[llm.models]] TOML via save_user_config serialization" do
      config = %{llm: %{models: []}}
      result = EvoGit.CLI.do_add_model_profile(config, "anthropic:test-model")

      # Replicate the stringify_keys logic from Config (recurses into maps,
      # but not lists). Then encode and decode to verify round-trip.
      stringify = fn
        map, f when is_map(map) ->
          Map.new(map, fn
            {key, value} when is_atom(key) -> {Atom.to_string(key), f.(value, f)}
            {key, value} -> {key, f.(value, f)}
          end)
          |> Enum.reject(fn {_k, v} -> v == nil end)
          |> Map.new()

        nil, _f ->
          nil

        v, _f ->
          v
      end

      stringified = stringify.(result, stringify)
      assert {:ok, toml} = TomlElixir.encode(stringified)

      # The TOML should contain the array-of-tables header
      assert String.contains?(toml, "[[llm.models]]")

      # Round-trip: decode should restore the models list
      {:ok, decoded} = TomlElixir.decode(toml)
      decoded_models = get_in(decoded, ["llm", "models"])
      assert length(decoded_models) == 1
      assert %{"id" => "default", "model" => "anthropic:test-model"} = hd(decoded_models)
    end
  end
end
