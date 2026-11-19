defmodule EvoGit.Config.ReasoningEffortTest do
  @moduledoc """
  ONE canonical, user-selectable reasoning-effort ladder.

  Async-safe: every call here is pure schema/normalization logic — no process
  state, no app-env seam, no config-directory reads.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config.Normalization
  alias EvoGit.Config.Schema
  alias EvoGit.Config.Schema.LLM
  alias EvoGit.Config.Schema.LLMConstraints

  describe "canonical ladder" do
    test "reasoning_efforts/0 is the ascending level set without :max" do
      assert LLM.reasoning_efforts() == [:none, :minimal, :low, :medium, :high, :xhigh]
      refute :max in LLM.reasoning_efforts()
      assert length(LLM.reasoning_efforts()) == 6
    end

    test "reasoning_effort_options/0 appends :default (provider default)" do
      assert LLM.reasoning_effort_options() ==
               [:none, :minimal, :low, :medium, :high, :xhigh, :default]

      refute :max in LLM.reasoning_effort_options()
    end

    test "allowed?/1 accepts the levels, `default` and nil (atoms and strings)" do
      for effort <- LLM.reasoning_effort_options() do
        assert LLM.allowed?(effort)
        assert LLM.allowed?(Atom.to_string(effort))
      end

      assert LLM.allowed?(nil)
      assert LLM.allowed?(" high ")
      assert LLM.allowed?("XHIGH")
    end

    test "allowed?/1 rejects `max` (an accepted alias, not an offered level) and garbage" do
      refute LLM.allowed?(:max)
      refute LLM.allowed?("max")
      refute LLM.allowed?("MAX")
      refute LLM.allowed?("garbage")
      refute LLM.allowed?("")
      refute LLM.allowed?(42)
      refute LLM.allowed?(%{})
      refute LLM.allowed?({:high})
    end
  end

  describe "alias normalization" do
    test "canonical_reasoning_effort/1 aliases `max` to :xhigh and passes levels through" do
      assert LLM.canonical_reasoning_effort("max") == :xhigh
      assert LLM.canonical_reasoning_effort(:max) == :xhigh
      assert LLM.canonical_reasoning_effort("MAX") == :xhigh
      assert LLM.canonical_reasoning_effort("  max  ") == :xhigh

      for effort <- LLM.reasoning_effort_options() do
        assert LLM.canonical_reasoning_effort(effort) == effort
        assert LLM.canonical_reasoning_effort(Atom.to_string(effort)) == effort
      end

      assert LLM.canonical_reasoning_effort(nil) == nil
      assert LLM.canonical_reasoning_effort("garbage") == nil
      assert LLM.canonical_reasoning_effort(42) == nil
      assert LLM.canonical_reasoning_effort(%{}) == nil
    end

    test "convert_reasoning_effort/1 keeps its contract and adds the max alias" do
      assert LLM.convert_reasoning_effort("max") == :xhigh
      assert LLM.convert_reasoning_effort(:max) == :xhigh
      assert LLM.convert_reasoning_effort("xhigh") == :xhigh
      assert LLM.convert_reasoning_effort("default") == :default
      assert LLM.convert_reasoning_effort(nil) == nil

      # Canonical level atoms pass through as themselves.
      for effort <- LLM.reasoning_effort_options() do
        assert LLM.convert_reasoning_effort(effort) == effort
      end

      # Documented fallback: unknown values are returned unchanged.
      assert LLM.convert_reasoning_effort("garbage") == "garbage"
      assert LLM.convert_reasoning_effort(42) == 42
    end
  end

  describe "LLMConstraints.filter/3 wire aliases" do
    test "GLM-5.3 emits :xhigh as the provider's own \"max\" spelling" do
      for model <- ["zai:glm-5.3", "zai:glm-5.3-flash"] do
        assert LLMConstraints.filter([reasoning_effort: :xhigh], model, nil) ==
                 [reasoning_effort: "max"]

        assert LLMConstraints.filter([reasoning_effort: "xhigh"], model, nil) ==
                 [reasoning_effort: "max"]

        # A legacy "max" input is aliased to :xhigh and then emitted as "max".
        assert LLMConstraints.filter([reasoning_effort: "max"], model, nil) ==
                 [reasoning_effort: "max"]

        assert LLMConstraints.filter([reasoning_effort: :max], model, nil) ==
                 [reasoning_effort: "max"]
      end
    end

    test "GLM-5.3 still drops levels outside low | high | xhigh" do
      assert LLMConstraints.filter([reasoning_effort: :medium], "zai:glm-5.3", nil) == []

      assert LLMConstraints.filter([reasoning_effort: :low], "zai:glm-5.3", nil) ==
               [reasoning_effort: :low]

      assert LLMConstraints.filter([reasoning_effort: :high], "zai:glm-5.3", nil) ==
               [reasoning_effort: :high]
    end

    test "the wire alias keeps keyword order and never touches other params" do
      params = [temperature: 0.4, reasoning_effort: :xhigh, max_tokens: 100]

      assert LLMConstraints.filter(params, "zai:glm-5.3", nil) ==
               [temperature: 0.4, reasoning_effort: "max", max_tokens: 100]
    end

    test "non-GLM models stay byte-identical (no wire alias, no drop)" do
      params = [temperature: 2.0, reasoning_effort: :xhigh, top_k: 10]

      assert LLMConstraints.filter(params, "anthropic:claude-sonnet-4", nil) == params
      assert LLMConstraints.filter(params, nil, nil) == params
      assert LLMConstraints.filter(params, "", nil) == params
    end

    test "the alias also applies on the metadata-free (no capability) path" do
      assert LLMConstraints.filter([reasoning_effort: :xhigh], "zai:glm-5.3-flash", nil) ==
               [reasoning_effort: "max"]

      # Missing metadata never drops the parameter; only the table rules apply.
      assert LLMConstraints.filter([reasoning_effort: :xhigh], "zai:glm-4.6", nil) ==
               [reasoning_effort: "max"]
    end
  end

  describe "schema entry for the flat key" do
    test "[:llm, :reasoning_effort] is a string enum of the canonical set + default" do
      schema = Enum.find(Schema.all_schemas(), &(&1.key_path == [:llm, :reasoning_effort]))

      assert schema.type == :string
      assert schema.default == nil
      assert schema.validation[:in] == ~w(none minimal low medium high xhigh default)
      refute "max" in schema.validation[:in]
      assert schema.description =~ "max"
    end
  end

  describe "config round trip (backward compatibility)" do
    test "a persisted flat `max` normalizes to xhigh on read and validates" do
      resolved = Normalization.resolve(%{llm: %{reasoning_effort: "max"}})

      assert resolved.llm.reasoning_effort == "xhigh"
      assert {:ok, _validated} = Schema.validate(resolved)
    end

    test "an atom `:max` on the flat key also normalizes to xhigh" do
      assert Normalization.resolve(%{llm: %{reasoning_effort: :max}}).llm.reasoning_effort ==
               "xhigh"
    end

    test "unrelated flat values are left untouched so validation reports them" do
      assert Normalization.resolve(%{llm: %{reasoning_effort: "ultra"}}).llm.reasoning_effort ==
               "ultra"
    end

    test "a canonical account carrying `max` validates and normalizes to xhigh" do
      raw = %{
        llm: %{
          providers: [
            %{
              id: "work",
              provider: "openai",
              models: ["alpha"],
              reasoning_efforts: ["low", "max"],
              default_reasoning_effort: "max"
            }
          ]
        }
      }

      assert {:ok, _validated} = Schema.validate(raw)

      [profile] = Schema.provider_profiles(raw)
      assert profile["reasoning_efforts"] == ["low", "xhigh"]
      assert profile["default_reasoning_effort"] == "xhigh"
    end

    test "per-model `max` effort keys and legacy [[llm.models]] migrate to xhigh" do
      canonical = %{
        llm: %{
          providers: [
            %{
              id: "work",
              provider: "openai",
              models: [
                %{
                  model: "alpha",
                  reasoning_efforts: ["max"],
                  default_reasoning_effort: "max"
                }
              ]
            }
          ]
        }
      }

      assert {:ok, _validated} = Schema.validate(canonical)
      [profile] = Schema.provider_profiles(canonical)
      [model] = profile["models"]
      assert model["reasoning_efforts"] == ["xhigh"]
      assert model["default_reasoning_effort"] == "xhigh"

      legacy = %{
        llm: %{
          models: [%{id: "legacy", model: "openai:alpha", reasoning_effort: "max"}]
        }
      }

      assert {:ok, _validated} = Schema.validate(legacy)
      [migrated] = Schema.provider_profiles(legacy)
      assert migrated["default_reasoning_effort"] == "xhigh"
      assert migrated["reasoning_efforts"] == ["xhigh"]
    end
  end
end
