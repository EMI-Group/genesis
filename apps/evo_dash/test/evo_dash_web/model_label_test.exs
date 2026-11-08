defmodule EvoDashWeb.ModelLabelTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.ModelLabel` — the shared derivation behind
  the agent-detail panel's "Model" cell and the task card's "Model" line.

  The helper takes plain summary/agent/task maps, so no LiveView, socket, ETS
  or DB setup is needed. Its contract is TOTAL: every unknown shape degrades to
  the next source (or nil), it never raises and never renders a stray separator
  for an absent part.
  """
  use ExUnit.Case, async: true
  alias EvoDashWeb.ModelLabel

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

  describe "task_label/1 — the task card's Model line (canonical selection in opts)" do
    # A stored task row reaches the card with `opts` decoded to a KEYWORD list
    # (`:model_spec` atomized, its inner selection map string-keyed) while the
    # legacy `model_id` column stays nil for canonical selections.
    test "canonical opts model_spec WITH effort renders profile - model - effort" do
      task = %{id: "t1", model_id: nil, opts: [mode: "simple", model_spec: @canonical]}

      assert ModelLabel.task_label(task) == "work - glm-4.6 - high"
    end

    test "canonical opts model_spec WITHOUT effort renders profile - model" do
      spec = %{"provider_profile_id" => "work", "model" => "glm-4.6"}

      assert ModelLabel.task_label(%{model_id: nil, opts: [model_spec: spec]}) == "work - glm-4.6"
    end

    test "the canonical selection beats a legacy model_id" do
      task = %{model_id: "legacy-id", opts: [model_spec: @canonical]}

      assert ModelLabel.task_label(task) == "work - glm-4.6 - high"
    end

    test "a legacy model_id only still renders (top-level, as the summary carries it)" do
      assert ModelLabel.task_label(%{model_id: "1:zai:glm-4.6", opts: [mode: "simple"]}) ==
               "1:zai:glm-4.6"
    end

    test "a model_id inside opts is a fallback (string OR atom keyed opts)" do
      assert ModelLabel.task_label(%{model_id: nil, opts: [{"model_id", "1:zai:glm-4.6"}]}) ==
               "1:zai:glm-4.6"

      assert ModelLabel.task_label(%{model_id: nil, opts: %{"model_id" => "1:zai:glm-4.6"}}) ==
               "1:zai:glm-4.6"

      assert ModelLabel.task_label(%{model_id: nil, opts: %{model_id: "1:zai:glm-4.6"}}) ==
               "1:zai:glm-4.6"
    end

    test "a task with no model information yields nil (the card renders no Model line)" do
      assert ModelLabel.task_label(%{id: "t1", model_id: nil, opts: [mode: "simple"]}) == nil
      assert ModelLabel.task_label(%{id: "t1", opts: nil}) == nil
      assert ModelLabel.task_label(%{id: "t1"}) == nil
      assert ModelLabel.task_label(%{model_id: "", opts: [model_spec: %{}]}) == nil
    end

    test "string-keyed task maps are accepted (wire shapes)" do
      assert ModelLabel.task_label(%{"model_id" => nil, "opts" => %{"model_spec" => @canonical}}) ==
               "work - glm-4.6 - high"
    end

    test "total on odd shapes — never raises, degrades to nil" do
      assert ModelLabel.task_label(nil) == nil
      assert ModelLabel.task_label("task") == nil
      assert ModelLabel.task_label(%{opts: "not-opts"}) == nil

      assert ModelLabel.task_label(%{opts: [:junk, {:model_spec, @canonical}, :more]}) ==
               "work - glm-4.6 - high"

      assert ModelLabel.task_label(%{opts: [model_spec: %URI{}]}) == nil
      assert ModelLabel.task_label(%{opts: [model_spec: ["not", "a", "map"]]}) == nil
    end
  end
end
