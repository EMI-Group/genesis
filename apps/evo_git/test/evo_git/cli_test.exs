defmodule EvoGit.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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

  describe "setup wizard model profile writing (map specs)" do
    # Replicate the stringify_keys logic from Config (recurses into maps and
    # lists), then encode and decode to verify round-trip.
    defp stringify(map) when is_map(map) do
      Map.new(map, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), stringify(value)}
        {key, value} -> {key, stringify(value)}
      end)
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Map.new()
    end

    defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
    defp stringify(nil), do: nil
    defp stringify(value), do: value

    test "adds map spec with base_url to empty config as default profile" do
      config = %{llm: %{models: []}}
      spec = %{provider: :openai, id: "gpt-5.5", base_url: "https://x/v1"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      models = get_in(result, [:llm, :models])
      assert length(models) == 1

      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == spec
      assert profile.concurrency == 3
    end

    test "mirrors map spec to llm.model for backward compat" do
      config = %{llm: %{models: []}}
      spec = %{provider: :openai, id: "gpt-5.5", base_url: "https://x/v1"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      assert get_in(result, [:llm, :model]) == spec
    end

    test "updates existing default profile model, preserving concurrency" do
      config = %{llm: %{models: [%{id: "default", model: "old-model", concurrency: 5}]}}
      spec = %{provider: :openai, id: "gpt-5.5", base_url: "https://x/v1"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      models = get_in(result, [:llm, :models])
      assert length(models) == 1

      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == spec
      assert profile.concurrency == 5
    end

    test "map spec with base_url passes Schema validation" do
      config = %{llm: %{models: []}}
      spec = %{provider: :openai, id: "gpt-5.5", base_url: "https://x/v1"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      assert {:ok, _} = EvoGit.Config.Schema.validate(result)
    end

    test "map spec with base_url round-trips through TOML serialization" do
      config = %{llm: %{models: []}}
      spec = %{provider: :openai, id: "gpt-5.5", base_url: "https://x/v1"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      stringified = stringify(result)
      assert {:ok, toml} = TomlElixir.encode(stringified)

      assert String.contains?(toml, "[[llm.models]]")
      assert String.contains?(toml, "[llm.models.model]")
      assert String.contains?(toml, "base_url = \"https://x/v1\"")

      {:ok, decoded} = TomlElixir.decode(toml)
      decoded_models = get_in(decoded, ["llm", "models"])
      assert length(decoded_models) == 1

      profile = hd(decoded_models)
      assert profile["id"] == "default"

      assert profile["model"] == %{
               "provider" => "openai",
               "id" => "gpt-5.5",
               "base_url" => "https://x/v1"
             }
    end

    test "map spec without base_url to empty config as default profile" do
      config = %{llm: %{models: []}}
      spec = %{provider: :anthropic, id: "claude-sonnet-4"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      models = get_in(result, [:llm, :models])
      assert length(models) == 1

      profile = hd(models)
      assert profile.id == "default"
      assert profile.model == spec
      assert profile.concurrency == 3

      assert get_in(result, [:llm, :model]) == spec
    end

    test "map spec without base_url passes Schema validation and round-trips" do
      config = %{llm: %{models: []}}
      spec = %{provider: :anthropic, id: "claude-sonnet-4"}
      result = EvoGit.CLI.do_add_model_profile(config, spec)

      assert {:ok, _} = EvoGit.Config.Schema.validate(result)

      stringified = stringify(result)
      assert {:ok, toml} = TomlElixir.encode(stringified)
      assert String.contains?(toml, "[[llm.models]]")

      {:ok, decoded} = TomlElixir.decode(toml)
      decoded_models = get_in(decoded, ["llm", "models"])
      assert length(decoded_models) == 1

      profile = hd(decoded_models)
      assert profile["id"] == "default"
      assert profile["model"] == %{"provider" => "anthropic", "id" => "claude-sonnet-4"}
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

  describe "resolve_model_id/2" do
    # NOTE: `resolve_model_id/2` is a NEW pure helper added by the CLI +
    # task data-plane refactor. Per the shared contract it lands on
    # `EvoGit.CLI` (the parallel CLI executor was told to put it there); if
    # after the merge it ends up on `EvoGit.CLI.Parser` instead, adjust the
    # module path below.
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
end
