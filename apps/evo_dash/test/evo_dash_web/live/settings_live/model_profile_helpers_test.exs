defmodule EvoDashWeb.SettingsLive.ModelProfileHelpersTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.SettingsLive.ModelProfileHelpers.

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, or DB setup is required.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.SettingsLive.ModelProfileHelpers

  describe "add_model_profile/2 with non-nil model" do
    test "drops incomplete draft profiles (no :model key) and adds the new complete one" do
      file_config = %{llm: %{models: [%{id: "profile-1", concurrency: 3}]}}

      result = ModelProfileHelpers.add_model_profile(file_config, "anthropic:claude-sonnet-4")

      models = get_in(result, [:llm, :models])

      # The incomplete draft (no :model key) should be gone.
      refute Enum.any?(models, fn p -> is_nil(Map.get(p, :model)) end),
             "expected incomplete draft profiles to be dropped"

      # The new complete profile should be present with the model set.
      assert Enum.any?(models, fn p -> Map.get(p, :model) == "anthropic:claude-sonnet-4" end),
             "expected the new complete profile to be added"
    end

    test "drops incomplete draft profiles (empty :model) and adds the new complete one" do
      file_config = %{llm: %{models: [%{id: "profile-1", concurrency: 3, model: ""}]}}

      result = ModelProfileHelpers.add_model_profile(file_config, "anthropic:claude-sonnet-4")

      models = get_in(result, [:llm, :models])

      # The incomplete draft (empty :model) should be gone.
      refute Enum.any?(models, fn p -> Map.get(p, :model) == "" end),
             "expected incomplete draft profiles with empty model to be dropped"

      # The new complete profile should be present.
      assert Enum.any?(models, fn p -> Map.get(p, :model) == "anthropic:claude-sonnet-4" end)
    end

    test "keeps complete profiles (existing :model key) when adding a new one" do
      complete_profile = %{id: "profile-1", concurrency: 3, model: "openai:gpt-4o"}
      file_config = %{llm: %{models: [complete_profile]}}

      result = ModelProfileHelpers.add_model_profile(file_config, "anthropic:claude-sonnet-4")

      models = get_in(result, [:llm, :models])

      # The existing complete profile must still be present.
      assert Enum.any?(models, fn p -> Map.get(p, :id) == "profile-1" end),
             "existing complete profile should not be dropped"

      assert Enum.any?(models, fn p ->
               Map.get(p, :id) == "profile-1" and Map.get(p, :model) == "openai:gpt-4o"
             end),
             "existing complete profile model should be preserved"

      # The new complete profile should be present.
      assert Enum.any?(models, fn p -> Map.get(p, :model) == "anthropic:claude-sonnet-4" end)
    end
  end

  describe "add_model_profile/2 with nil model (draft flow)" do
    test "preserves incomplete draft profiles when creating a new draft" do
      existing_draft = %{id: "profile-1", concurrency: 3}
      file_config = %{llm: %{models: [existing_draft]}}

      result = ModelProfileHelpers.add_model_profile(file_config, nil)

      models = get_in(result, [:llm, :models])

      # The existing incomplete draft should still be there (draft flow intact).
      assert Enum.any?(models, fn p -> Map.get(p, :id) == "profile-1" end),
             "existing draft should be preserved when creating a new draft"

      assert Enum.any?(models, fn p ->
               Map.get(p, :id) == "profile-1" and is_nil(Map.get(p, :model))
             end),
             "existing draft without model should be preserved"

      # A new draft should also be added (no :model key).
      new_drafts =
        Enum.filter(models, fn p -> is_nil(Map.get(p, :model)) end)

      assert length(new_drafts) == 2, "expected both drafts (existing + new) to be present"
    end

    test "preserves incomplete draft profiles when creating a new draft (empty string model)" do
      existing_draft = %{id: "profile-1", concurrency: 3, model: ""}
      file_config = %{llm: %{models: [existing_draft]}}

      result = ModelProfileHelpers.add_model_profile(file_config, "")

      models = get_in(result, [:llm, :models])

      # The existing incomplete draft should still be there.
      assert Enum.any?(models, fn p -> Map.get(p, :id) == "profile-1" end),
             "existing draft should be preserved when creating a new draft"
    end
  end

  describe "regression: fresh-install quick setup with existing draft" do
    test "quick setup (non-nil model) does not leave any profile without a :model key" do
      # Simulate: user clicked "Add Profile" (creating a draft with no model),
      # then used Quick Setup / a model shortcut (which calls add_model_profile
      # with a non-nil model value).
      draft = %{id: "profile-1", concurrency: 3}
      file_config = %{llm: %{models: [draft]}}

      result = ModelProfileHelpers.add_model_profile(file_config, "anthropic:claude-sonnet-4")

      models = get_in(result, [:llm, :models])

      # Every resulting profile must have a non-nil, non-empty :model.
      for profile <- models do
        model = Map.get(profile, :model)

        assert not is_nil(model),
               "profile #{inspect(Map.get(profile, :id))} is missing a :model key"

        assert model != "",
               "profile #{inspect(Map.get(profile, :id))} has an empty :model"
      end
    end

    test "quick setup with a map-model spec also drops incomplete drafts" do
      # Model values can also be map specs (provider/id), which are non-nil and
      # should also trigger draft dropping.
      draft = %{id: "profile-1", concurrency: 3}
      file_config = %{llm: %{models: [draft]}}

      model_spec = %{provider: :anthropic, id: "claude-sonnet-4"}
      result = ModelProfileHelpers.add_model_profile(file_config, model_spec)

      models = get_in(result, [:llm, :models])

      refute Enum.any?(models, fn p -> is_nil(Map.get(p, :model)) end),
             "incomplete draft should be dropped even with a map model spec"
    end
  end

  describe "parse_model_profile_params/2 serialization format" do
    test "stores compact string form when no overrides exist" do
      params = %{
        "provider" => "deepseek",
        "model_id" => "deepseek-v4-pro",
        "base_url" => "",
        "extra" => ""
      }

      assert {:ok, profile} = ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
      assert profile.model == "deepseek:deepseek-v4-pro"
    end

    test "stores bare model string when provider is empty and no overrides exist" do
      params = %{"provider" => "", "model_id" => "gpt-4o", "base_url" => "", "extra" => ""}

      assert {:ok, profile} = ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
      assert profile.model == "gpt-4o"
    end

    test "keeps map spec with base_url when a base_url override is present" do
      params = %{
        "provider" => "deepseek",
        "model_id" => "deepseek-v4-pro",
        "base_url" => "https://custom.example.com/v1",
        "extra" => ""
      }

      assert {:ok, profile} = ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert %{
               provider: :deepseek,
               id: "deepseek-v4-pro",
               base_url: "https://custom.example.com/v1"
             } =
               profile.model
    end

    test "keeps map spec with extra when extra JSON is present" do
      params = %{
        "provider" => "deepseek",
        "model_id" => "deepseek-v4-pro",
        "base_url" => "",
        "extra" => ~s({"reasoning_effort": "high"})
      }

      assert {:ok, profile} = ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert %{provider: :deepseek, id: "deepseek-v4-pro"} = profile.model
      assert profile.model.extra == %{"reasoning_effort" => "high"}
    end

    test "round-trips a legacy provider:model string back to the compact string form" do
      # Simulates the edit form pre-fill for a profile whose :model is the
      # compact string "provider:model" — the form splits on the first colon
      # (in the component) and re-saving with no overrides must restore it.
      model = "deepseek:deepseek-v4-pro"
      [provider, model_id] = String.split(model, ":", parts: 2)
      params = %{"provider" => provider, "model_id" => model_id, "base_url" => "", "extra" => ""}

      assert {:ok, profile} = ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
      assert profile.model == model
    end

    test "model ids containing colons survive the round-trip (first-colon-only split)" do
      model = "openai:gpt-4o:extended"
      [provider, model_id] = String.split(model, ":", parts: 2)
      params = %{"provider" => provider, "model_id" => model_id, "base_url" => "", "extra" => ""}

      assert {:ok, profile} = ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
      assert profile.model == model
    end

    test "returns error when model_id is empty" do
      params = %{"provider" => "deepseek", "model_id" => "", "base_url" => "", "extra" => ""}

      assert {:error, "model_id_empty"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
    end
  end

  describe "parse_model_profile_params/2 — peak/off-peak concurrency fields" do
    @peak_params %{
      "provider" => "deepseek",
      "model_id" => "deepseek-v4-pro",
      "base_url" => "",
      "extra" => ""
    }

    test "absent peak fields leave the profile without peak_concurrency/peak_hours keys" do
      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(@peak_params, "profile-1")

      refute Map.has_key?(profile, :peak_concurrency),
             "peak_concurrency key must stay absent when disabled"

      refute Map.has_key?(profile, :peak_hours),
             "peak_hours key must stay absent when disabled"
    end

    test "blank peak_concurrency and fully-blank rows omit both keys" do
      params =
        Map.merge(@peak_params, %{
          "peak_concurrency" => "",
          "peak_hours" => %{
            "0" => %{"start" => "", "end" => ""},
            "1" => %{"start" => "", "end" => ""}
          }
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      refute Map.has_key?(profile, :peak_concurrency)
      refute Map.has_key?(profile, :peak_hours)
    end

    test "peak_concurrency round-trips as a positive integer" do
      params = Map.merge(@peak_params, %{"peak_concurrency" => "8"})

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_concurrency == 8
      refute Map.has_key?(profile, :peak_hours)
    end

    test "peak_concurrency 0 is accepted and round-trips" do
      params = Map.merge(@peak_params, %{"peak_concurrency" => "0"})

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_concurrency == 0

      # parse_peak_fields/1 exposes the same acceptance directly.
      assert {:ok, %{peak_concurrency: 0}} =
               ModelProfileHelpers.parse_peak_fields(%{"peak_concurrency" => "0"})
    end

    test "two windows round-trip preserving form order" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{
            "0" => %{"start" => "09:00", "end" => "12:00"},
            "1" => %{"start" => "14:00", "end" => "18:00"}
          }
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_hours == [
               %{start: "09:00", end: "12:00"},
               %{start: "14:00", end: "18:00"}
             ]

      refute Map.has_key?(profile, :peak_concurrency)
    end

    test "a list-form peak_hours input is accepted" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => [%{"start" => "09:00", "end" => "12:00"}]
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_hours == [%{start: "09:00", end: "12:00"}]
    end

    test "string-index map keys sort numerically (index 10 after 9)" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{
            "10" => %{"start" => "20:00", "end" => "21:00"},
            "9" => %{"start" => "09:00", "end" => "10:00"}
          }
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_hours == [
               %{start: "09:00", end: "10:00"},
               %{start: "20:00", end: "21:00"}
             ]
    end

    test "peak_concurrency and peak_hours merge into one profile" do
      params =
        Map.merge(@peak_params, %{
          "peak_concurrency" => "12",
          "peak_hours" => %{"0" => %{"start" => "08:00", "end" => "10:00"}}
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_concurrency == 12
      assert profile.peak_hours == [%{start: "08:00", end: "10:00"}]
    end

    test "a non-blank timezone is stored trimmed; blank/nil omit the key" do
      params = Map.merge(@peak_params, %{"timezone" => "  Asia/Shanghai  "})

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.timezone == "Asia/Shanghai"

      for blank <- ["", "   ", nil] do
        params = Map.merge(@peak_params, %{"timezone" => blank})

        assert {:ok, profile} =
                 ModelProfileHelpers.parse_model_profile_params(params, "profile-1"),
               "expected blank timezone #{inspect(blank)} to omit the key"

        refute Map.has_key?(profile, :timezone),
               "timezone key must stay absent when blank"
      end
    end

    test "timezone merges with peak_concurrency into one profile" do
      params =
        Map.merge(@peak_params, %{
          "peak_concurrency" => "4",
          "timezone" => "Asia/Shanghai"
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_concurrency == 4
      assert profile.timezone == "Asia/Shanghai"
    end

    test "normalize_peak_hours_draft/1 normalizes nested-map, list, and absent input" do
      # Nested map (Phoenix phx-change shape) — sorted numerically.
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "10" => %{"start" => "20:00", "end" => "21:00"},
               "9" => %{"start" => "09:00", "end" => "10:00"}
             }) == [
               %{start: "09:00", end: "10:00"},
               %{start: "20:00", end: "21:00"}
             ]

      # Atom-keyed rows survive (round-trip from a prior draft).
      assert ModelProfileHelpers.normalize_peak_hours_draft([
               %{start: "09:00", end: "12:00"}
             ]) == [%{start: "09:00", end: "12:00"}]

      # Blank/partially-filled rows keep "" (no data loss).
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "0" => %{"start" => "", "end" => ""}
             }) == [%{start: "", end: ""}]

      # Total — odd/absent input never raises.
      assert ModelProfileHelpers.normalize_peak_hours_draft(nil) == []
      assert ModelProfileHelpers.normalize_peak_hours_draft("garbage") == []
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{}) == []
    end

    test "mixed blank/valid rows drop the blank row and keep the valid one" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{
            "0" => %{"start" => "09:00", "end" => "12:00"},
            "1" => %{"start" => "", "end" => ""}
          }
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_hours == [%{start: "09:00", end: "12:00"}]
    end

    test "invalid peak_concurrency values are rejected" do
      for bad <- ["-1", "abc"] do
        params = Map.merge(@peak_params, %{"peak_concurrency" => bad})

        assert {:error, "peak_concurrency_invalid"} =
                 ModelProfileHelpers.parse_model_profile_params(params, "profile-1"),
               "expected #{inspect(bad)} to be rejected"
      end

      # parse_peak_fields/1 exposes the same validation directly.
      for bad <- ["-1", "abc"] do
        assert {:error, "peak_concurrency_invalid"} =
                 ModelProfileHelpers.parse_peak_fields(%{"peak_concurrency" => bad}),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "valid_clock_time?/1 accepts strict HH:MM and rejects malformed times" do
      for good <- ["00:00", "09:00", "12:30", "23:59"] do
        assert ModelProfileHelpers.valid_clock_time?(good),
               "expected #{inspect(good)} to be valid"
      end

      for bad <- ["9:00", "24:00", "12:60", "12:0", "abc", "12:00am", ""] do
        refute ModelProfileHelpers.valid_clock_time?(bad),
               "expected #{inspect(bad)} to be invalid"
      end

      refute ModelProfileHelpers.valid_clock_time?(nil)
      refute ModelProfileHelpers.valid_clock_time?(930)
    end

    test "malformed clock times in windows are rejected" do
      for bad <- ["9:00", "24:00", "12:60", "12:0", "abc"] do
        params =
          Map.merge(@peak_params, %{
            "peak_hours" => %{"0" => %{"start" => bad, "end" => "12:00"}}
          })

        assert {:error, "peak_hours_invalid_time"} =
                 ModelProfileHelpers.parse_model_profile_params(params, "profile-1"),
               "expected start #{inspect(bad)} to be rejected"
      end
    end

    test "a window with only one of start/end filled is invalid" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{"0" => %{"start" => "09:00", "end" => ""}}
        })

      assert {:error, "peak_hours_invalid_time"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{"0" => %{"start" => "", "end" => "12:00"}}
        })

      assert {:error, "peak_hours_invalid_time"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
    end

    test "a window with start == end is rejected" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "09:00"}}
        })

      assert {:error, "peak_hours_start_equals_end"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
    end

    test "overlapping windows are rejected" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{
            "0" => %{"start" => "09:00", "end" => "12:00"},
            "1" => %{"start" => "11:00", "end" => "13:00"}
          }
        })

      assert {:error, "peak_hours_overlap"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
    end

    test "touching windows (adjacent boundaries) are accepted" do
      params =
        Map.merge(@peak_params, %{
          "peak_hours" => %{
            "0" => %{"start" => "09:00", "end" => "12:00"},
            "1" => %{"start" => "12:00", "end" => "15:00"}
          }
        })

      assert {:ok, profile} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      assert profile.peak_hours == [
               %{start: "09:00", end: "12:00"},
               %{start: "12:00", end: "15:00"}
             ]
    end

    test "an invalid spec/provider_options error wins over a peak error" do
      # model_id_empty is checked before any peak validation.
      params = Map.merge(@peak_params, %{"model_id" => "", "peak_concurrency" => "abc"})

      assert {:error, "model_id_empty"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      # invalid extra JSON beats the peak error.
      params = Map.merge(@peak_params, %{"extra" => "not json", "peak_concurrency" => "abc"})

      assert {:error, "invalid_extra_json"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

      # invalid provider_options JSON beats the peak error.
      params =
        Map.merge(@peak_params, %{
          "provider_options" => "not json",
          "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "09:00"}}
        })

      assert {:error, "invalid_provider_options_json"} =
               ModelProfileHelpers.parse_model_profile_params(params, "profile-1")
    end
  end

  describe "profile id naming from model value" do
    test "derives id from provider:model string" do
      result =
        ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, "deepseek:deepseek-flash")

      assert [%{id: "deepseek-flash"}] = get_in(result, [:llm, :models])
    end

    test "plain model string uses itself as the base id" do
      result = ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, "gpt-4o")
      assert [%{id: "gpt-4o"}] = get_in(result, [:llm, :models])
    end

    test "map spec uses its :id value" do
      result =
        ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, %{
          provider: :anthropic,
          id: "claude-sonnet-4"
        })

      assert [%{id: "claude-sonnet-4"}] = get_in(result, [:llm, :models])
    end

    test "slugifies the model value (downcase, non-alphanumeric runs become dashes)" do
      result = ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, "DeepSeek V3.2")
      assert [%{id: "deepseek-v3-2"}] = get_in(result, [:llm, :models])
    end
  end

  describe "profile id conflict suffixes" do
    test "appends -2 when the base id already exists" do
      # Seeded profile MUST carry a :model key — draft-cleaning would drop it otherwise.
      existing = %{id: "deepseek-flash", concurrency: 3, model: "deepseek:deepseek-flash"}

      result =
        ModelProfileHelpers.add_model_profile(
          %{llm: %{models: [existing]}},
          "deepseek:deepseek-flash"
        )

      models = get_in(result, [:llm, :models])
      assert Enum.map(models, & &1.id) == ["deepseek-flash", "deepseek-flash-2"]
    end

    test "skips to -3 when both the base and -2 exist" do
      existing = [
        %{id: "deepseek-flash", concurrency: 3, model: "deepseek:deepseek-flash"},
        %{id: "deepseek-flash-2", concurrency: 3, model: "deepseek:deepseek-flash-2"}
      ]

      result =
        ModelProfileHelpers.add_model_profile(
          %{llm: %{models: existing}},
          "deepseek:deepseek-flash"
        )

      assert List.last(get_in(result, [:llm, :models])).id == "deepseek-flash-3"
    end
  end

  describe "profile id fallbacks" do
    test "draft flow (nil model) keeps the profile-N scheme" do
      result = ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, nil)
      assert [%{id: "profile-1"}] = get_in(result, [:llm, :models])
    end

    test "unusable model value falls back to the profile-N scheme" do
      result = ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, "!!!")
      assert [%{id: "profile-1"}] = get_in(result, [:llm, :models])
    end
  end

  describe "generate_profile_id/2" do
    test "produces base, base-2, base-3... skipping existing ids" do
      models = [
        %{id: "foo", concurrency: 3, model: "x:foo"},
        %{id: "foo-2", concurrency: 3, model: "x:foo-2"}
      ]

      assert ModelProfileHelpers.generate_profile_id(models, "foo") == "foo-3"
    end

    test "nil base falls back to the profile-N scheme" do
      models = [%{id: "profile-1", concurrency: 3}]
      assert ModelProfileHelpers.generate_profile_id(models, nil) == "profile-2"
    end

    test "one-arity wrapper keeps the profile-N scheme" do
      models = [%{id: "profile-1", concurrency: 3}]
      assert ModelProfileHelpers.generate_profile_id(models) == "profile-2"
    end
  end
end
