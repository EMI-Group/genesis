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
end
