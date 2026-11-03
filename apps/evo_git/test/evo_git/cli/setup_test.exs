defmodule EvoGit.CLI.SetupTest do
  # async: true is safe — every case exercises PURE helpers of
  # `EvoGit.CLI.Setup` (profile writing, auth-mode resolution, vendor-login
  # probing with EXPLICIT `opts`) plus Schema/TOML round-trips. No env vars, no
  # app env, no Store/scheduler, no network; the vendor-login probes point at
  # unique temp dirs via `home:` / `codex_home:` and never at the real
  # `~/.codex` / `~/.claude` / config dir.
  use ExUnit.Case, async: true

  alias EvoGit.CLI.Setup
  alias EvoGit.Config.LLMCatalog

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

  describe "add_model_profile/3 — oauth branch" do
    test "creates the default profile with auth_mode oauth" do
      result = Setup.do_add_model_profile(%{llm: %{models: []}}, @codex_spec, "oauth")
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.id == "default"
      assert profile.model == @codex_spec
      assert profile.concurrency == 3
      assert profile.auth_mode == "oauth"
      # Mirrored to llm.model for backward compat.
      assert get_in(result, [:llm, :model]) == @codex_spec
    end

    test "appends an oauth default profile when only non-default profiles exist" do
      config = %{llm: %{models: [%{id: "fast", model: "google:flash", concurrency: 2}]}}
      result = Setup.do_add_model_profile(config, @anthropic_spec, "oauth")
      models = get_in(result, [:llm, :models])
      assert length(models) == 2

      default = Enum.find(models, &(&1.id == "default"))
      assert default.auth_mode == "oauth"
      # The unrelated profile is untouched.
      assert Enum.find(models, &(&1.id == "fast")) == %{
               id: "fast",
               model: "google:flash",
               concurrency: 2
             }
    end

    test "sets auth_mode oauth on an existing default profile, preserving concurrency" do
      config = %{llm: %{models: [%{id: "default", model: "old-model", concurrency: 5}]}}
      result = Setup.do_add_model_profile(config, @codex_spec, "oauth")
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.model == @codex_spec
      assert profile.concurrency == 5
      assert profile.auth_mode == "oauth"
    end

    test "the written profile passes Schema validation" do
      result = Setup.do_add_model_profile(%{llm: %{models: []}}, @anthropic_spec, "oauth")
      assert {:ok, _} = EvoGit.Config.Schema.validate(result)
    end

    test "auth_mode round-trips through TOML serialization" do
      result = Setup.do_add_model_profile(%{llm: %{models: []}}, @anthropic_spec, "oauth")
      stringified = stringify(result)
      assert {:ok, toml} = TomlElixir.encode(stringified)
      assert String.contains?(toml, "auth_mode = \"oauth\"")

      {:ok, decoded} = TomlElixir.decode(toml)
      assert [profile] = get_in(decoded, ["llm", "models"])
      assert profile["id"] == "default"
      assert profile["auth_mode"] == "oauth"
      assert profile["model"] == %{"provider" => "anthropic", "id" => "claude-sonnet-5-5"}
    end
  end

  describe "add_model_profile/3 — api_key branch" do
    test "adds NO auth_mode key at all (absent, not nil)" do
      result = Setup.do_add_model_profile(%{llm: %{models: []}}, @anthropic_spec, nil)
      assert [profile] = get_in(result, [:llm, :models])
      refute Map.has_key?(profile, :auth_mode)
      refute Map.has_key?(profile, "auth_mode")
    end

    test "leaves an existing default profile without an auth_mode key" do
      config = %{llm: %{models: [%{id: "default", model: "old-model", concurrency: 5}]}}
      result = Setup.do_add_model_profile(config, @anthropic_spec, nil)
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.concurrency == 5
      refute Map.has_key?(profile, :auth_mode)
    end

    test "switching an existing default profile from oauth back to api_key CLEARS the stale key" do
      config = %{
        llm: %{
          models: [
            %{id: "default", model: @codex_spec, concurrency: 4, auth_mode: "oauth"}
          ]
        }
      }

      result = Setup.do_add_model_profile(config, @anthropic_spec, nil)
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.model == @anthropic_spec
      assert profile.concurrency == 4
      refute Map.has_key?(profile, :auth_mode)

      stringified = stringify(result)
      assert {:ok, toml} = TomlElixir.encode(stringified)
      refute String.contains?(toml, "auth_mode")
    end
  end

  describe "do_add_model_profile/2 (unchanged api-key default)" do
    test "creates the default profile without auth_mode" do
      result = Setup.do_add_model_profile(%{llm: %{models: []}}, "anthropic:test-model")
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.id == "default"
      assert profile.concurrency == 3
      refute Map.has_key?(profile, :auth_mode)
    end

    test "still updates an existing default profile in place" do
      config = %{llm: %{models: [%{id: "default", model: "old-model", concurrency: 5}]}}
      result = Setup.do_add_model_profile(config, "anthropic:new-model")
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.model == "anthropic:new-model"
      assert profile.concurrency == 5
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

  describe "do_prepare_config/3 (real config.toml shape)" do
    # `[[llm.models]]` decodes to STRING-keyed profile maps, exactly like
    # `EvoGit.Config.user_config/0` hands it to the wizard.
    @decoded_config %{
      "llm" => %{
        "models" => [
          %{
            "id" => "default",
            "model" => %{"provider" => "openai_codex", "id" => "gpt-6.1-sol"},
            "concurrency" => 3,
            "auth_mode" => "oauth"
          }
        ]
      }
    }

    test "updates the existing string-keyed default profile instead of appending a duplicate" do
      result = Setup.do_prepare_config(@decoded_config, @anthropic_spec, nil)
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.id == "default"
      assert profile.model == @anthropic_spec
      assert profile.concurrency == 3
    end

    test "clears a string-keyed stale auth_mode when switching back to an API key" do
      result = Setup.do_prepare_config(@decoded_config, @anthropic_spec, nil)
      assert [profile] = get_in(result, [:llm, :models])
      refute Map.has_key?(profile, :auth_mode)
      refute Map.has_key?(profile, "auth_mode")
    end

    test "carries auth_mode oauth over a string-keyed profile" do
      api_key_config = %{
        "llm" => %{
          "models" => [
            %{
              "id" => "default",
              "model" => %{"provider" => "anthropic", "id" => "claude-haiku-5-5"},
              "concurrency" => 5
            }
          ]
        }
      }

      result = Setup.do_prepare_config(api_key_config, @codex_spec, "oauth")
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.model == @codex_spec
      assert profile.concurrency == 5
      assert profile.auth_mode == "oauth"
    end

    test "an empty config still yields exactly one default profile" do
      result = Setup.do_prepare_config(%{}, @codex_spec, "oauth")
      assert [profile] = get_in(result, [:llm, :models])
      assert profile.auth_mode == "oauth"
    end
  end

  ## Helpers

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
