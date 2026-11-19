defmodule EvoGit.Config.OffPeakHolidaysConfigTest do
  @moduledoc """
  `off_peak_holidays` account schedule key: schema validation, canonical
  resolution exposure, legacy `[[llm.models]]` migration, persistence round
  trip and preset/schema agreement.

  Async-safe: only pure schema calls plus the per-process `ConfigDir` seam for
  the persistence round trip (each test gets its own config directory, so the
  path-keyed config cache and TOML writes cannot collide with a sibling).
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Normalization
  alias EvoGit.Config.ProviderPresets
  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.ProviderProfiles
  alias EvoGit.Config.Schema.ValidationError
  alias EvoGit.TestSupport.ConfigDir

  setup do
    ConfigDir.isolate!("off_peak_holidays")
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    File.write!(Config.credentials_path(), "")
    {:ok, dir: dir}
  end

  defp account(overrides \\ %{}) do
    Map.merge(%{id: "work", provider: "openai", models: ["alpha"]}, overrides)
  end

  defp config(profiles), do: %{llm: %{providers: profiles}}

  defp legacy_config(profile) do
    %{llm: %{models: [Map.merge(%{id: "legacy", model: "openai:alpha"}, profile)]}}
  end

  defp single_error(config) do
    assert {:error, [error]} = Schema.validate(config)
    assert %ValidationError{} = error
    error
  end

  describe "acceptance" do
    test "a canonical account with off_peak_holidays passes validation and keeps the key" do
      config = config([account(%{off_peak_holidays: "CN"})])
      assert {:ok, _} = Schema.validate(config)

      assert [profile] = ProviderProfiles.provider_profiles(config)
      assert profile["off_peak_holidays"] == "CN"
    end

    test "the calendar id is case-insensitive and may be an atom or padded string" do
      for value <- ["CN", "cn", :cn, " CN ", :CN] do
        config = config([account(%{off_peak_holidays: value})])
        assert {:ok, _} = Schema.validate(config), "rejected #{inspect(value)}"
      end
    end

    test "nil and an empty string mean unconfigured and are not errors" do
      for value <- [nil, ""] do
        config = config([account(%{off_peak_holidays: value})])
        assert {:ok, _} = Schema.validate(config), "rejected #{inspect(value)}"
      end
    end
  end

  describe "validation errors" do
    test "an unknown calendar id yields exactly ONE error on the canonical account" do
      for value <- ["US", :us, 123] do
        error = single_error(config([account(%{off_peak_holidays: value})]))

        assert error.key_path == [:llm, :providers, 0, :off_peak_holidays]
        assert error.value == value
        assert error.rule == :off_peak_holidays

        assert error.message ==
                 "off_peak_holidays must be a holiday calendar id (CN), got #{inspect(value)}"
      end
    end

    test "an unknown calendar id on a legacy [[llm.models]] profile yields ONE error" do
      for value <- ["US", :us, 123] do
        error = single_error(legacy_config(%{off_peak_holidays: value}))

        assert error.key_path == [:llm, :models, 0, :off_peak_holidays]
        assert error.value == value
        assert error.rule == :off_peak_holidays
      end
    end
  end

  describe "resolution" do
    test "resolve_model_spec exposes the calendar at the top level and in runtime_profile" do
      config = config([account(%{off_peak_holidays: "CN"})])

      assert {:ok, resolved} = Schema.resolve_model_spec(config, nil)
      assert resolved.off_peak_holidays == "CN"
      assert resolved.runtime_profile.off_peak_holidays == "CN"
      assert resolved.provider_profile["off_peak_holidays"] == "CN"
    end

    test "resolve_runtime_profile exposes the calendar" do
      config = config([account(%{off_peak_holidays: "CN", concurrency: 4})])

      assert {:ok, runtime} = ProviderProfiles.resolve_runtime_profile(config, nil)
      assert runtime.off_peak_holidays == "CN"
      assert runtime.concurrency == 4
    end

    test "the key is absent from a runtime profile when the account does not configure it" do
      assert {:ok, runtime} = ProviderProfiles.resolve_runtime_profile(config([account()]), nil)
      refute Map.has_key?(runtime, :off_peak_holidays)
    end
  end

  describe "legacy migration" do
    test "a [[llm.models]] profile keeps off_peak_holidays in the migrated account" do
      config = legacy_config(%{off_peak_holidays: "CN"})

      assert [profile] = ProviderProfiles.provider_profiles(config)
      assert profile["id"] == "legacy"
      assert profile["off_peak_holidays"] == "CN"
      assert {:ok, _} = Schema.validate(config)
    end
  end

  describe "normalization and persistence" do
    test "Normalization.resolve preserves the key on a canonical account" do
      resolved =
        Normalization.resolve(%{llm: %{providers: [account(%{off_peak_holidays: "CN"})]}})

      assert [profile] = resolved.llm.providers
      assert profile["off_peak_holidays"] == "CN"
    end

    test "Normalization.resolve preserves the key on a legacy [[llm.models]] profile" do
      resolved = Normalization.resolve(legacy_config(%{off_peak_holidays: "CN"}))
      assert [profile] = resolved.llm.models
      assert Map.get(profile, :off_peak_holidays) == "CN"
    end

    test "save_user_config persists the key verbatim and resolve reads it back" do
      providers = [account(%{off_peak_holidays: "CN", concurrency: 4})]
      config = put_in(Config.defaults(), [:llm, :providers], providers)

      assert :ok = Config.save_user_config(config)

      assert {:ok, decoded} = TomlElixir.decode(File.read!(Config.config_path()))
      assert [persisted] = decoded["llm"]["providers"]
      assert persisted["off_peak_holidays"] == "CN"

      assert [resolved] = Config.resolve().llm.providers
      assert resolved["off_peak_holidays"] == "CN"
      assert [saved] = Config.user_config()["llm"]["providers"]
      assert saved["off_peak_holidays"] == "CN"
    end
  end

  describe "provider presets" do
    test "every preset schedule merges into a canonical account that validates" do
      presets = ProviderPresets.all()
      assert [_ | _] = presets

      for preset <- presets do
        account =
          %{
            "id" => preset.id,
            "provider" => Atom.to_string(preset.provider),
            "models" => ["preset-model"]
          }
          |> Map.merge(preset.schedule)

        config = %{llm: %{providers: [account]}}

        assert Schema.validate(config) == {:ok, config},
               "preset #{preset.id} does not validate against the account schema"

        assert [profile] = ProviderProfiles.provider_profiles(config)
        assert Map.take(profile, Map.keys(preset.schedule)) == preset.schedule
      end
    end

    test "the CN holiday calendar preset reaches the resolved schedule" do
      preset = ProviderPresets.get("deepseek-standard")
      assert preset.schedule["off_peak_holidays"] == "CN"

      account =
        %{"id" => preset.id, "provider" => Atom.to_string(preset.provider), "models" => ["m"]}
        |> Map.merge(preset.schedule)

      assert {:ok, resolved} =
               Schema.resolve_model_spec(%{llm: %{providers: [account]}}, nil)

      assert resolved.off_peak_holidays == "CN"
      assert resolved.runtime_profile.off_peak_holidays == "CN"
    end
  end
end
