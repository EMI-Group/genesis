defmodule EvoGit.Config.ProviderProfileValidationTest do
  @moduledoc """
  Canonical provider schema descriptors and raw-input validation. Async-safe:
  only pure schema calls, never account resolution, credentials or global writes.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.ValidationError

  defp account(overrides \\ %{}) do
    Map.merge(%{id: "work", provider: "openai", models: ["alpha", "beta"]}, overrides)
  end

  defp config(profiles), do: %{llm: %{providers: profiles}}

  defp assert_error(config, path, value, rule) do
    assert {:error, errors} = Schema.validate(config)

    assert Enum.any?(errors, fn error ->
             match?(%ValidationError{}, error) and error.key_path == path and
               error.value == value and error.rule == rule and is_binary(error.message) and
               error.message != ""
           end),
           "missing #{inspect({path, value, rule})} in #{inspect(errors)}"
  end

  test "canonical inventory and selector expose schema metadata and defaults" do
    schemas = Schema.all_schemas()

    assert %{type: :provider_profiles, default: [], validation: [], category: :llm} =
             Enum.find(schemas, &(&1.key_path == [:llm, :providers]))

    assert %{type: :string, default: nil, validation: [], category: :llm} =
             Enum.find(schemas, &(&1.key_path == [:llm, :default_provider_profile]))

    assert Schema.defaults().llm.providers == []
    assert Schema.defaults().llm.default_provider_profile == nil
  end

  test "valid shared account settings and nested model overrides are returned unchanged" do
    profile =
      account(%{
        name: "Work",
        api_key_env_var: "WORK_KEY",
        base_url: "https://api.invalid",
        auth_mode: "oauth",
        oauth_file: "account-auth.json",
        concurrency: 4,
        peak_concurrency: 0,
        peak_hours: [%{start: "09:00", end: "17:00", days: ["weekdays"]}],
        off_peak_days: ["sun"],
        timezone: "Asia/Hong_Kong",
        context_window: 80_000,
        extra: %{headers: %{x: "yes"}},
        temperature: 0.8,
        max_tokens: 4096,
        top_p: 0.9,
        top_k: 10,
        frequency_penalty: 0.1,
        presence_penalty: 0.2,
        provider_options: %{custom: true},
        reasoning_efforts: ["high", "low"],
        default_reasoning_effort: "low",
        default_model: "openai:beta",
        models: [
          "alpha",
          %{
            model: "openai:beta",
            context_window: 32_000,
            temperature: 0.0,
            max_tokens: 512,
            reasoning_efforts: ["medium", "low"],
            default_reasoning_effort: "medium",
            provider_options: %{custom: false}
          }
        ]
      })

    config = put_in(config([profile]), [:llm, :default_provider_profile], "work")
    assert Schema.validate(config) == {:ok, config}
  end

  test "nested string-keyed account/model fields and model id alias validate" do
    profile = %{
      "id" => "work",
      "provider" => "openai",
      "auth_mode" => "api_key",
      "models" => [%{"id" => "openai:alpha", "context_window" => 64_000}],
      "default_model" => "alpha"
    }

    config = config([profile])
    assert Schema.validate(config) == {:ok, config}
  end

  test "separate accounts may repeat provider, endpoint and model but not account id" do
    profiles = [account(), account(%{id: "personal"})]
    assert Schema.validate(config(profiles)) == {:ok, config(profiles)}
    assert_error(config([account(), account()]), [:llm, :providers, 1, :id], "work", :unique)
  end

  test "inventory, entries and required account fields reject malformed raw values" do
    for value <- [%{}, "bad", 42] do
      assert_error(config(value), [:llm, :providers], value, :provider_profiles)
    end

    assert_error(config([nil]), [:llm, :providers, 0], nil, :provider_profiles)

    for {field, value} <- [
          {:id, nil},
          {:id, ""},
          {:id, " "},
          {:provider, nil},
          {:provider, ""},
          {:provider, true},
          {:provider, 42}
        ] do
      assert_error(
        config([account(%{field => value})]),
        [:llm, :providers, 0, field],
        value,
        :string
      )
    end
  end

  test "explicit default account must exist, without affecting absent selector or empty inventory" do
    config = put_in(config([account()]), [:llm, :default_provider_profile], "missing")
    assert_error(config, [:llm, :default_provider_profile], "missing", {:in, ["work"]})

    assert Schema.validate(%{llm: %{providers: [], default_provider_profile: "legacy"}}) ==
             {:ok, %{llm: %{providers: [], default_provider_profile: "legacy"}}}

    assert Schema.validate(config([account()])) == {:ok, config([account()])}

    assert_error(
      %{llm: %{default_provider_profile: 1}},
      [:llm, :default_provider_profile],
      1,
      :string
    )
  end

  test "default model must belong to this account, accepting matching provider prefix" do
    for value <- ["missing", "other:alpha"] do
      assert_error(
        config([account(%{default_model: value})]),
        [:llm, :providers, 0, :default_model],
        value,
        {:in, ["alpha", "beta"]}
      )
    end

    for value <- ["alpha", "openai:alpha"] do
      config = config([account(%{default_model: value})])
      assert Schema.validate(config) == {:ok, config}
    end
  end

  test "nested models reject malformed input and duplicate normalized names" do
    assert_error(
      config([account(%{models: "alpha"})]),
      [:llm, :providers, 0, :models],
      "alpha",
      :models
    )

    assert_error(
      config([account(%{models: [42]})]),
      [:llm, :providers, 0, :models, 0],
      42,
      :model
    )

    for model <- ["", %{}, %{model: " "}] do
      value = if is_binary(model), do: model, else: Map.get(model, :model)

      assert_error(
        config([account(%{models: [model]})]),
        [:llm, :providers, 0, :models, 0, :model],
        value,
        :string
      )
    end

    assert_error(
      config([account(%{models: ["alpha", %{id: "openai:alpha"}]})]),
      [:llm, :providers, 0, :models, 1, :model],
      "alpha",
      :unique
    )
  end

  test "ordered effort inventories reject duplicates and non-string values at either level" do
    for {fields, path} <- [
          {%{reasoning_efforts: ["high", "high"]}, [:reasoning_efforts]},
          {%{models: [%{model: "alpha", reasoning_efforts: ["high", "high"]}]},
           [:models, 0, :reasoning_efforts]}
        ] do
      assert_error(
        config([account(fields)]),
        [:llm, :providers, 0] ++ path ++ [1],
        "high",
        :unique
      )
    end

    for value <- ["high", [:high], [""], [" "]] do
      assert_error(
        config([account(%{reasoning_efforts: value})]),
        [:llm, :providers, 0, :reasoning_efforts],
        value,
        :list_of_strings
      )
    end
  end

  test "defaults must belong to effective effort inventory, including inherited provider defaults" do
    assert_error(
      config([account(%{reasoning_efforts: ["low"], default_reasoning_effort: "high"})]),
      [:llm, :providers, 0, :default_reasoning_effort],
      "high",
      {:in, ["low"]}
    )

    profile =
      account(%{
        reasoning_efforts: ["high"],
        default_reasoning_effort: "high",
        models: [%{model: "alpha", reasoning_efforts: ["low", "medium"]}]
      })

    assert_error(
      config([profile]),
      [:llm, :providers, 0, :models, 0, :default_reasoning_effort],
      "high",
      {:in, ["low", "medium"]}
    )

    for override <- [
          %{default_reasoning_effort: "low"},
          %{reasoning_effort: "medium"},
          %{reasoning_efforts: []}
        ] do
      [model] = profile.models
      valid = config([%{profile | models: [Map.merge(model, override)]}])
      assert Schema.validate(valid) == {:ok, valid}
    end
  end

  test "generation, context, auth and concurrency types/ranges are validated on raw accounts" do
    for {field, value, rule} <- [
          {:temperature, 2.1, {:max, 2.0}},
          {:max_tokens, 0, {:min, 1}},
          {:max_tokens, "1024", :pos_integer},
          {:concurrency, 0, :pos_integer},
          {:context_window, -1, :integer},
          {:context_window, "64000", :integer},
          {:provider_options, [], :map},
          {:extra, "bad", :map},
          {:auth_mode, "password", :string},
          {:api_key_env_var, "", :string},
          {:base_url, 42, :string}
        ] do
      assert_error(
        config([account(%{field => value})]),
        [:llm, :providers, 0, field],
        value,
        rule
      )
    end
  end

  test "nested generation/context overrides are validated with their full indexed paths" do
    for {field, value, rule} <- [
          {:temperature, -0.1, {:min, 0.0}},
          {:max_tokens, "512", :pos_integer},
          {:context_window, 0, :integer},
          {:provider_options, "bad", :map}
        ] do
      profile = account(%{models: [%{field => value, model: "alpha"}]})
      assert_error(config([profile]), [:llm, :providers, 0, :models, 0, field], value, rule)
    end
  end
end
