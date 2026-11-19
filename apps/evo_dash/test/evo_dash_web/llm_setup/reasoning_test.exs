defmodule EvoDashWeb.LLMSetup.ReasoningTest do
  @moduledoc """
  Pins the dashboard's SINGLE reasoning vocabulary.

  The ladder itself lives in the core (`EvoGit.Config.Schema.LLM`), so these
  tests assert the delegation's OUTCOME: the six canonical levels in core
  order, the `"default"` pseudo-option, the `"max"` wire alias folding into
  `"xhigh"`, and a total, order-preserving inventory normalizer.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.LLMSetup.Reasoning

  describe "efforts/0 and options/0" do
    test "efforts/0 is exactly the six core levels, in core order" do
      assert Reasoning.efforts() == ["none", "minimal", "low", "medium", "high", "xhigh"]
    end

    test "efforts/0 never offers \"max\" or \"default\"" do
      refute "max" in Reasoning.efforts()
      refute "default" in Reasoning.efforts()
    end

    test "options/0 appends \"default\" last and keeps the ladder order" do
      assert Reasoning.options() == Reasoning.efforts() ++ ["default"]
      assert List.last(Reasoning.options()) == "default"
      refute "max" in Reasoning.options()
    end
  end

  describe "allowed?/1" do
    test "accepts every offered level" do
      for effort <- Reasoning.efforts() do
        assert Reasoning.allowed?(effort)
      end

      assert Reasoning.allowed?(" High ")
      assert Reasoning.allowed?(:high)
    end

    test "accepts the provider-default choice" do
      assert Reasoning.allowed?("default")
    end

    test "\"max\" / \"MAX\" are wire aliases, not offered options" do
      refute Reasoning.allowed?("max")
      refute Reasoning.allowed?("MAX")
      refute Reasoning.allowed?(:max)

      # The alias is still understood by canonical/1 and level?/1.
      assert Reasoning.canonical("MAX") == "xhigh"
      assert Reasoning.level?("max")
    end

    test "rejects a garbage value" do
      refute Reasoning.allowed?("garbage")
      refute Reasoning.allowed?(42)
      refute Reasoning.allowed?(%{})
    end
  end

  describe "canonical/1" do
    test "maps the \"max\" alias to \"xhigh\" from strings and atoms" do
      assert Reasoning.canonical("max") == "xhigh"
      assert Reasoning.canonical("MAX") == "xhigh"
      assert Reasoning.canonical(:max) == "xhigh"
    end

    test "passes canonical levels through as strings" do
      for effort <- Reasoning.efforts() do
        assert Reasoning.canonical(effort) == effort
      end

      assert Reasoning.canonical(" High ") == "high"
      assert Reasoning.canonical(:high) == "high"
    end

    test "keeps \"default\"" do
      assert Reasoning.canonical("default") == "default"
    end

    test "returns nil for nil, blank and garbage input" do
      assert Reasoning.canonical(nil) == nil
      assert Reasoning.canonical("") == nil
      assert Reasoning.canonical("   ") == nil
      assert Reasoning.canonical("ultra") == nil
      assert Reasoning.canonical(42) == nil
      assert Reasoning.canonical(%{}) == nil
    end
  end

  describe "level?/1 and label/1" do
    test "level?/1 is true only for a canonical level" do
      assert Reasoning.level?("high")
      assert Reasoning.level?("max")
      refute Reasoning.level?("default")
      refute Reasoning.level?("ultra")
      refute Reasoning.level?(nil)
    end

    test "label/1 labels the ladder, the default choice and keeps custom spellings" do
      assert Reasoning.label("none") == "None"
      assert Reasoning.label("xhigh") == "Extra high"
      assert Reasoning.label("max") == "Extra high"
      assert Reasoning.label("default") == "Provider default"
      assert Reasoning.label("ultra") == "ultra"
      assert Reasoning.label(nil) == ""
      assert Reasoning.label("  ") == ""
    end
  end

  describe "normalize_inventory/1" do
    test "preserves order, drops blanks, dedups case-insensitively and canonicalizes aliases" do
      assert Reasoning.normalize_inventory(["high", " HIGH ", "max", "", nil, :low]) ==
               ["high", "xhigh", "low"]
    end

    test "keeps unknown configured values and dedups them case-insensitively" do
      assert Reasoning.normalize_inventory(["ultra", "Ultra", :none]) == ["ultra", "none"]
    end

    test "never turns \"xhigh\" into \"max\"" do
      assert Reasoning.normalize_inventory(["xhigh"]) == ["xhigh"]
      refute "max" in Reasoning.normalize_inventory(["xhigh", "max"])
    end

    test "is total for nil, non-list and nested junk" do
      assert Reasoning.normalize_inventory(nil) == []
      assert Reasoning.normalize_inventory("high") == []
      assert Reasoning.normalize_inventory(%{}) == []
      assert Reasoning.normalize_inventory(42) == []
      assert Reasoning.normalize_inventory([42, %{}, [:high], {"low"}]) == []
      assert Reasoning.normalize_inventory([:high, 42, %{}, ["nested"]]) == ["high"]
    end
  end

  describe "inventory_of/1 and default_of/1" do
    test "reads string- and atom-keyed drafts" do
      assert Reasoning.inventory_of(%{"reasoning_efforts" => ["High", "max"]}) ==
               ["high", "xhigh"]

      assert Reasoning.inventory_of(%{reasoning_efforts: ["low"]}) == ["low"]
    end

    test "inventory_of/1 is empty for a draft without the key or a non-map" do
      assert Reasoning.inventory_of(%{}) == []
      assert Reasoning.inventory_of(nil) == []
      assert Reasoning.inventory_of("draft") == []
    end

    test "default_of/1 answers only levels the draft itself advertises" do
      assert Reasoning.default_of(%{
               "reasoning_efforts" => ["low", "xhigh"],
               "default_reasoning_effort" => "max"
             }) == "xhigh"

      assert Reasoning.default_of(%{reasoning_efforts: [:high], default_reasoning_effort: :high}) ==
               "high"
    end

    test "default_of/1 is nil for a stale default, a missing default or a non-map" do
      # The draft no longer advertises "xhigh", so the stale "max" default is nil.
      assert Reasoning.default_of(%{
               "reasoning_efforts" => ["low", "high"],
               "default_reasoning_effort" => "max"
             }) == nil

      assert Reasoning.default_of(%{"reasoning_efforts" => ["low"]}) == nil
      assert Reasoning.default_of(%{"default_reasoning_effort" => "high"}) == nil
      assert Reasoning.default_of(nil) == nil
    end
  end

  describe "input names" do
    test "the inventory and default form names are the one shared pair" do
      assert Reasoning.inventory_input_name() == "reasoning_efforts[]"
      assert Reasoning.default_input_name() == "default_reasoning_effort"
    end
  end
end
