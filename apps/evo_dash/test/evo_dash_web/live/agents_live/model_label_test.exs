defmodule EvoDashWeb.AgentsLive.ModelLabelTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.AgentsLive.ModelLabel` — the derivation
  behind the agent-detail panel's "Model" cell.

  The helper takes plain summary/agent maps, so no LiveView, socket, ETS or DB
  setup is needed. Its contract is TOTAL: every unknown shape degrades to the
  next source (or nil), it never raises and never renders a stray separator for
  an absent part.
  """
  use ExUnit.Case, async: true
  alias EvoDashWeb.AgentsLive.ModelLabel

  # The canonical STRING-keyed task selection the scheduler now stores for an
  # explicit canonical model selection (the case that used to render "N/A").
  @canonical %{
    "provider_profile_id" => "work",
    "model" => "glm-4.6",
    "reasoning_effort" => "high"
  }

  describe "label/1 — canonical model_spec wins" do
    test "explicit canonical selection WITH effort renders profile - model - effort" do
      assert ModelLabel.label(%{model_id: nil, model_spec: @canonical}) == "work - glm-4.6 - high"
    end

    test "canonical selection WITHOUT effort renders profile - model" do
      spec = %{"provider_profile_id" => "work", "model" => "glm-4.6"}

      assert ModelLabel.label(%{model_id: nil, model_spec: spec}) == "work - glm-4.6"
    end

    test "atom-keyed model_spec is accepted (and an atom effort stringified)" do
      spec = %{provider_profile_id: "work", model: "glm-4.6", reasoning_effort: :high}

      assert ModelLabel.label(%{model_spec: spec}) == "work - glm-4.6 - high"
    end

    test "string-keyed source maps are accepted" do
      assert ModelLabel.label(%{"model_spec" => @canonical}) == "work - glm-4.6 - high"
    end

    test "canonical beats llm_model and the legacy model_id" do
      source = %{model_spec: @canonical, llm_model: "zai:glm-4.6", model_id: "legacy-id"}

      assert ModelLabel.label(source) == "work - glm-4.6 - high"
    end

    test "nil/blank parts are skipped, never leaving a stray separator" do
      nil_effort = %{
        "provider_profile_id" => "work",
        "model" => "glm-4.6",
        "reasoning_effort" => nil
      }

      assert ModelLabel.label(%{model_spec: nil_effort}) == "work - glm-4.6"

      blank = %{"provider_profile_id" => "", "model" => "glm-4.6", "reasoning_effort" => "  "}
      assert ModelLabel.label(%{model_spec: blank}) == "glm-4.6"

      blank_model = %{"provider_profile_id" => "work", "model" => ""}
      assert ModelLabel.label(%{model_spec: blank_model}) == "work"
    end

    test "an empty model_spec falls through to llm_model / model_id" do
      assert ModelLabel.label(%{model_spec: %{}, llm_model: "zai:glm-4.6"}) == "zai:glm-4.6"
      assert ModelLabel.label(%{model_spec: %{}, model_id: "legacy-id"}) == "legacy-id"
    end

    test "a non-map model_spec is ignored, falling through to llm_model / model_id" do
      assert ModelLabel.label(%{model_spec: "legacy-id", llm_model: "zai:glm-4.6"}) ==
               "zai:glm-4.6"

      assert ModelLabel.label(%{model_spec: ["not", "a", "map"], model_id: "legacy-id"}) ==
               "legacy-id"

      # A struct is still a map but carries none of the canonical keys — it
      # must degrade to the next source, never be inspected/stringified.
      assert ModelLabel.label(%{model_spec: %URI{}, model_id: "legacy-id"}) == "legacy-id"
    end
  end

  describe "label/1 — llm_model (ReqLLM model input)" do
    test "a provider:model binary passes through as-is" do
      assert ModelLabel.label(%{llm_model: "zai:glm-4.6"}) == "zai:glm-4.6"
    end

    test "an endpoint/model map renders its id when present" do
      endpoint = %{provider: "zai", id: "glm-4.6", base_url: "https://example.invalid"}

      assert ModelLabel.label(%{llm_model: endpoint}) == "glm-4.6"
    end

    test "an endpoint/model map without id combines provider and model" do
      assert ModelLabel.label(%{llm_model: %{provider: "zai", model: "glm-4.6"}}) ==
               "zai:glm-4.6"

      assert ModelLabel.label(%{"llm_model" => %{"provider" => "zai", "model_id" => "glm-4.6"}}) ==
               "zai:glm-4.6"
    end

    test "an unreadable llm_model shape falls through to the legacy model_id" do
      assert ModelLabel.label(%{
               llm_model: %{base_url: "https://example.invalid"},
               model_id: "legacy-id"
             }) ==
               "legacy-id"

      assert ModelLabel.label(%{llm_model: 42, model_id: "legacy-id"}) == "legacy-id"

      assert ModelLabel.label(%{llm_model: "", model_id: "legacy-id"}) == "legacy-id"
    end
  end

  describe "label/1 — legacy model_id and fallbacks" do
    test "a legacy summary carrying only model_id renders that id" do
      assert ModelLabel.label(%{model_id: "1:zai:glm-4.6"}) == "1:zai:glm-4.6"
    end

    test "an empty summary yields nil" do
      assert ModelLabel.label(%{}) == nil
    end

    test "a summary with unrelated keys yields nil" do
      assert ModelLabel.label(%{objective: "do things", status: :running}) == nil
    end

    test "nil/blank legacy ids yield nil (never an empty string)" do
      assert ModelLabel.label(%{model_id: nil}) == nil
      assert ModelLabel.label(%{model_id: ""}) == nil
      assert ModelLabel.label(%{model_id: "   "}) == nil
    end

    test "non-map sources yield nil" do
      assert ModelLabel.label(nil) == nil
      assert ModelLabel.label("zai:glm-4.6") == nil
      assert ModelLabel.label(model_id: "legacy-id") == nil
    end
  end
end
