defmodule EvoDashWeb.LLMSelectionComponentsTest do
  @moduledoc """
  Render and resolver contracts for the shared picker, using its actual public API.

  Provider profiles and persisted model specs are string-keyed; the canonical
  model-selections projection is atom-keyed. These tests need neither config
  loading nor a catalog, and deliberately do not exercise LiveView handlers.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.LLMSelectionComponents

  describe "llm_selection/1 — discrete reasoning range" do
    for {effort, index, label} <- [
          {"low", 0, "Low"},
          {"medium", 1, "Medium"},
          {"high", 2, "High"}
        ] do
      test "#{effort} renders index #{index} with its associated accessible label" do
        tree = render_picker(model_spec: spec(%{"reasoning_effort" => unquote(effort)}))
        range = one(tree, "#llm-selection-reasoning")

        assert_attr(range, "type", "range")
        assert_attr(range, "name", "reasoning_effort")
        assert_attr(range, "min", "0")
        assert_attr(range, "max", "2")
        assert_attr(range, "step", "1")
        assert_attr(range, "value", Integer.to_string(unquote(index)))
        assert_attr(range, "phx-change", "select_reasoning_effort")
        assert_attr(range, "aria-valuetext", unquote(label))
        assert Floki.attribute(range, "disabled") == []

        assert text(one(tree, ~s(label[for="llm-selection-reasoning"]))) == "Reasoning effort"
        output = one(tree, "#llm-selection-reasoning-value")
        assert_attr(output, "for", "llm-selection-reasoning")
        assert text(output) == unquote(label)
        assert_attr(range, "aria-describedby", "llm-selection-reasoning-help")

        assert text(one(tree, "#llm-selection-reasoning-help")) ==
                 "Use the arrow keys to select a supported reasoning level. This is independent of task quality."

        assert_attr(range, "list", "llm-selection-reasoning-ticks")
        ticks = Floki.find(tree, "#llm-selection-reasoning-ticks option")
        assert Enum.map(ticks, &Floki.attribute(&1, "value")) == [["0"], ["1"], ["2"]]
        assert Enum.map(ticks, &Floki.attribute(&1, "label")) == [["Low"], ["Medium"], ["High"]]

        endpoints = one(tree, ~s(div[aria-hidden="true"]))
        assert Enum.map(Floki.find(endpoints, "span"), &text/1) == ["Low", "High"]
      end
    end

    test "singleton effort renders a disabled zero-width range, one tick and one endpoint" do
      tree =
        render_picker(
          model_selections: [
            selection(%{reasoning_efforts: ["high"], default_reasoning_effort: "high"})
          ]
        )

      range = one(tree, "input[type=range]")

      for attribute <- ["min", "max", "value"], do: assert_attr(range, attribute, "0")
      assert_attr(range, "step", "1")
      assert_attr(range, "disabled", "disabled")
      assert_attr(range, "aria-valuetext", "High")
      assert text(one(tree, "output")) == "High"
      tick = one(tree, "datalist option")
      assert_attr(tick, "value", "0")
      assert_attr(tick, "label", "High")
      assert Enum.map(Floki.find(tree, ~s(div[aria-hidden="true"] span)), &text/1) == ["High"]
      assert Floki.attribute(one(tree, "#llm-selection-model"), "disabled") == []
    end

    test "models without advertised efforts omit all reasoning controls" do
      for model <- [
            selection(%{reasoning_efforts: []}),
            selection(%{reasoning_efforts: nil}),
            Map.delete(selection(), :reasoning_efforts)
          ] do
        tree = render_picker(model_selections: [model])

        assert Floki.find(tree, "input[type=range], output, datalist") == []
        assert Floki.find(tree, ~s(label[for="llm-selection-reasoning"])) == []
        assert Floki.find(tree, "#llm-selection-reasoning-help") == []
        assert Floki.find(tree, ~s(input[name="reasoning_effort"])) == []
        assert_attr(one(tree, ~s(#llm-selection-model option[selected])), "value", "shared-model")
      end
    end

    test "missing or unsupported requested effort falls back to the advertised default" do
      for model_spec <- [
            spec(),
            spec(%{"reasoning_effort" => "obsolete"}),
            spec(%{"reasoning_effort" => nil})
          ] do
        tree = render_picker(model_spec: model_spec)
        assert_attr(one(tree, "input[type=range]"), "value", "1")
        assert text(one(tree, "output")) == "Medium"
      end
    end

    test "missing or invalid default falls back to the first effort, not a conventional level" do
      for model <- [
            selection(%{
              reasoning_efforts: ["high", "low"],
              default_reasoning_effort: "obsolete"
            }),
            selection(%{reasoning_efforts: ["high", "low"], default_reasoning_effort: nil}),
            selection(%{reasoning_efforts: ["high", "low"]})
            |> Map.delete(:default_reasoning_effort)
          ] do
        tree = render_picker(model_selections: [model])
        assert_attr(one(tree, "input[type=range]"), "value", "0")
        assert text(one(tree, "output")) == "High"
      end
    end

    test "a supported explicit effort wins over the default" do
      tree = render_picker(model_spec: spec(%{"reasoning_effort" => "low"}))
      assert_attr(one(tree, "input[type=range]"), "value", "0")
      assert text(one(tree, "output")) == "Low"
    end

    test "all standard effort labels and unknown catalog labels remain distinguishable" do
      efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "default", "custom-level"]

      labels = [
        "None",
        "Minimal",
        "Low",
        "Medium",
        "High",
        "Extra high",
        "Default",
        "custom-level"
      ]

      tree = render_picker(model_selections: [selection(%{reasoning_efforts: efforts})])

      assert Enum.map(Floki.find(tree, "datalist option"), &Floki.attribute(&1, "label")) ==
               Enum.map(labels, &[&1])

      assert_attr(one(tree, "input[type=range]"), "max", "7")
    end
  end

  describe "resolve_reasoning_effort/3" do
    test "maps integer and string indices at the first, middle and last positions" do
      for {effort, index} <- Enum.with_index(["low", "medium", "high"]),
          value <- [index, Integer.to_string(index)] do
        assert LLMSelectionComponents.resolve_reasoning_effort([selection()], spec(), value) ==
                 {:ok, effort}
      end
    end

    test "accepts already resolved supported strings" do
      for effort <- ["low", "medium", "high"] do
        assert LLMSelectionComponents.resolve_reasoning_effort([selection()], spec(), effort) ==
                 {:ok, effort}
      end
    end

    test "rejects negative and out-of-range indices rather than wrapping or clamping" do
      for value <- [-1, "-1", -3, "-3", 3, "3", 999, "999"] do
        assert_unsupported([selection()], spec(), value)
      end
    end

    test "rejects malformed indices and unsupported value types" do
      for value <- [
            "",
            " ",
            "1tail",
            "1.0",
            "1 ",
            " 1",
            "medium ",
            "unknown",
            nil,
            true,
            false,
            1.0,
            :medium,
            [],
            %{}
          ] do
        assert_unsupported([selection()], spec(), value)
      end
    end

    test "rejects absent, stale and incomplete model selections even for an otherwise valid effort" do
      for model_spec <- [
            spec(%{"model" => "removed-model"}),
            spec(%{"model" => ""}),
            spec(%{"provider_profile_id" => "removed-profile"}),
            spec(%{"provider_profile_id" => ""}),
            %{},
            nil
          ],
          value <- [0, "0", "medium"] do
        assert_unsupported([selection()], model_spec, value)
      end

      assert_unsupported([], spec(), "0")
    end

    test "does not invent an effort for unsupported models" do
      for model <- [
            selection(%{reasoning_efforts: []}),
            selection(%{reasoning_efforts: nil}),
            Map.delete(selection(), :reasoning_efforts)
          ],
          value <- [0, "0", "medium"] do
        assert_unsupported([model], spec(), value)
      end
    end

    test "singleton only resolves its sole index or exact effort string" do
      models = [selection(%{reasoning_efforts: ["high"]})]

      for value <- [0, "0", "high"],
          do:
            assert(
              LLMSelectionComponents.resolve_reasoning_effort(models, spec(), value) ==
                {:ok, "high"}
            )

      for value <- [1, "1", "medium"], do: assert_unsupported(models, spec(), value)
    end
  end

  describe "exact provider-profile scoping" do
    test "duplicate model names use the selected profile's ordered efforts and default" do
      models = duplicate_models()

      for selections <- [models, Enum.reverse(models)] do
        tree =
          render_picker(
            model_selections: selections,
            model_spec: spec(%{"provider_profile_id" => "secondary"})
          )

        assert_attr(one(tree, "input[type=range]"), "max", "1")
        assert_attr(one(tree, "input[type=range]"), "value", "0")
        assert text(one(tree, "output")) == "Extra high"

        assert Enum.map(Floki.find(tree, "datalist option"), &Floki.attribute(&1, "label")) == [
                 ["Extra high"],
                 ["Minimal"]
               ]

        assert Enum.map(
                 Floki.find(tree, "#llm-selection-model option"),
                 &Floki.attribute(&1, "value")
               ) == [[""], ["shared-model"]]

        assert LLMSelectionComponents.resolve_reasoning_effort(selections, spec(), 0) ==
                 {:ok, "low"}

        secondary_spec = spec(%{"provider_profile_id" => "secondary"})

        assert LLMSelectionComponents.resolve_reasoning_effort(selections, secondary_spec, "0") ==
                 {:ok, "xhigh"}

        assert LLMSelectionComponents.resolve_reasoning_effort(selections, secondary_spec, 1) ==
                 {:ok, "minimal"}

        assert_unsupported(selections, secondary_spec, 2)
        assert_unsupported(selections, secondary_spec, "medium")
        assert_unsupported(selections, spec(), "xhigh")
      end
    end

    test "an effort saved for another profile falls back only within the selected profile" do
      tree =
        render_picker(
          model_selections: duplicate_models(),
          model_spec:
            spec(%{"provider_profile_id" => "secondary", "reasoning_effort" => "medium"})
        )

      assert text(one(tree, "output")) == "Extra high"
      assert_attr(one(tree, "input[type=range]"), "value", "0")
    end
  end

  describe "provider/model controls and reusable picker states" do
    test "uses string-keyed profile labels and spec values without leaking credentials" do
      tree = render_picker()
      assert text(one(tree, ~s(label[for="llm-selection-provider"]))) == "Provider profile"
      assert text(one(tree, ~s(label[for="llm-selection-model"]))) == "Model"
      provider = one(tree, "#llm-selection-provider")
      assert_attr(provider, "name", "provider_profile_id")
      assert_attr(provider, "phx-change", "select_provider_profile")
      assert_attr(one(provider, "option[selected]"), "value", "primary")
      assert text(one(provider, "option[selected]")) == "Primary account"
      assert text(one(provider, ~s(option[value="secondary"]))) == "secondary"
      model = one(tree, "#llm-selection-model")
      assert_attr(model, "name", "model")
      assert_attr(model, "phx-change", "select_model")
      assert_attr(one(model, "option[selected]"), "value", "shared-model")
      refute text(tree) =~ "secret-not-for-display"
      refute inspect(tree) =~ "secret-not-for-display"
      assert Floki.find(tree, "form") == []
    end

    test "custom ids associate all controls, output, ticks and help without collisions" do
      tree = render_picker(id: "task-picker") ++ render_picker(id: "assistant-picker")
      ids = Floki.attribute(tree, "[id]", "id")
      assert length(ids) == length(Enum.uniq(ids))

      for id <- ["task-picker", "assistant-picker"] do
        fieldset = one(tree, "##{id}")

        for suffix <- ["provider", "model", "reasoning"] do
          one(fieldset, ~s(label[for="#{id}-#{suffix}"]))
          one(fieldset, "##{id}-#{suffix}")
        end

        assert_attr(one(fieldset, "output"), "for", "#{id}-reasoning")
        assert_attr(one(fieldset, "input[type=range]"), "list", "#{id}-reasoning-ticks")

        assert_attr(
          one(fieldset, "input[type=range]"),
          "aria-describedby",
          "#{id}-reasoning-help"
        )

        one(fieldset, "##{id}-reasoning-ticks")
        one(fieldset, "##{id}-reasoning-help")
      end
    end

    test "event overrides change events but preserve payload names" do
      tree =
        render_picker(
          provider_event: "choose_account",
          model_event: "choose_model",
          reasoning_event: "choose_effort"
        )

      for {selector, event, name} <- [
            {"select#llm-selection-provider", "choose_account", "provider_profile_id"},
            {"select#llm-selection-model", "choose_model", "model"},
            {"input[type=range]", "choose_effort", "reasoning_effort"}
          ] do
        control = one(tree, selector)
        assert_attr(control, "phx-change", event)
        assert_attr(control, "name", name)
      end
    end

    test "disabled disables the fieldset and every control without erasing selection" do
      tree = render_picker(disabled: true)
      assert_attr(one(tree, "fieldset"), "disabled", "disabled")

      for control <- Floki.find(tree, "select, input[type=range]"),
          do: assert_attr(control, "disabled", "disabled")

      assert_attr(one(tree, "input[type=range]"), "value", "1")
      assert text(one(tree, "output")) == "Medium"
    end

    test "empty defaults offer an accessible settings hint and no reasoning controls" do
      tree =
        render_component(&LLMSelectionComponents.llm_selection/1, []) |> Floki.parse_document!()

      provider = one(tree, "#llm-selection-provider")
      assert_attr(provider, "disabled", "disabled")
      assert_attr(provider, "aria-describedby", "llm-selection-empty")
      assert text(one(provider, "option[selected]")) == "Choose a provider profile"
      assert_attr(one(tree, "#llm-selection-model"), "disabled", "disabled")
      assert text(one(tree, "#llm-selection-model option[selected]")) == "Choose a provider first"

      assert text(one(tree, "#llm-selection-empty")) ==
               "No provider profiles configured. Add one in Settings to choose a model."

      assert Floki.find(tree, "input[type=range], output, datalist") == []
    end

    test "Auto is a selected blank profile and never silently selects a model" do
      tree = render_picker(model_spec: %{}, show_auto_option: true)
      auto = one(tree, "#llm-selection-provider option[selected]")
      assert_attr(auto, "value", "")
      assert text(auto) == "Auto (by rules)"
      assert_attr(one(tree, "#llm-selection-model"), "disabled", "disabled")
      assert text(one(tree, "#llm-selection-model option[selected]")) == "Choose a provider first"
      assert Floki.find(tree, "input[type=range]") == []
    end

    test "a known profile without models renders its own empty state" do
      tree = render_picker(model_selections: [], model_spec: spec(%{"model" => ""}))
      assert Floki.attribute(one(tree, "#llm-selection-provider"), "disabled") == []
      assert_attr(one(tree, "#llm-selection-model"), "disabled", "disabled")
      assert text(one(tree, "#llm-selection-model option[selected]")) == "Choose a model"
      assert text(tree) =~ "No models are available for this provider profile."
      assert Floki.find(tree, "#llm-selection-empty, input[type=range]") == []
    end

    test "unavailable profile and model remain visible, selected and disabled, not replaced" do
      tree =
        render_picker(
          model_spec:
            spec(%{"provider_profile_id" => "removed-profile", "model" => "removed-model"})
        )

      provider = one(tree, "#llm-selection-provider option[selected]")
      assert_attr(provider, "value", "removed-profile")
      assert_attr(provider, "disabled", "disabled")
      assert text(provider) == "Unavailable profile: removed-profile"
      model = one(tree, "#llm-selection-model option[selected]")
      assert_attr(model, "value", "removed-model")
      assert_attr(model, "disabled", "disabled")
      assert text(model) == "Unavailable model: removed-model"
      assert Floki.find(tree, "input[type=range]") == []
      refute text(tree) =~ "No models are available for this provider profile."
    end

    test "a stale model within a known profile preserves valid alternatives but has no range" do
      tree = render_picker(model_spec: spec(%{"model" => "removed-model"}))
      assert Floki.attribute(one(tree, "#llm-selection-model"), "disabled") == []
      selected = one(tree, "#llm-selection-model option[selected]")
      assert_attr(selected, "value", "removed-model")
      assert_attr(selected, "disabled", "disabled")
      assert text(selected) == "Unavailable model: removed-model"

      assert text(one(tree, ~s(#llm-selection-model option[value="shared-model"]))) ==
               "shared-model"

      assert Floki.find(tree, "input[type=range]") == []
    end
  end

  defp profiles do
    [
      %{
        "id" => "primary",
        "name" => "Primary account",
        "provider" => "example",
        "api_key" => "secret-not-for-display"
      },
      %{"id" => "secondary", "name" => "", "provider" => "example"}
    ]
  end

  defp selection(overrides \\ %{}) do
    Map.merge(
      %{
        provider_profile_id: "primary",
        model: "shared-model",
        reasoning_efforts: ["low", "medium", "high"],
        default_reasoning_effort: "medium"
      },
      overrides
    )
  end

  defp duplicate_models do
    [
      selection(),
      selection(%{
        provider_profile_id: "secondary",
        reasoning_efforts: ["xhigh", "minimal"],
        default_reasoning_effort: "xhigh"
      })
    ]
  end

  defp spec(overrides \\ %{}) do
    Map.merge(%{"provider_profile_id" => "primary", "model" => "shared-model"}, overrides)
  end

  defp render_picker(overrides \\ []) do
    assigns =
      Keyword.merge(
        [provider_profiles: profiles(), model_selections: [selection()], model_spec: spec()],
        overrides
      )

    render_component(&LLMSelectionComponents.llm_selection/1, assigns) |> Floki.parse_document!()
  end

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  defp text(tree), do: tree |> Floki.text() |> String.trim()

  defp assert_attr(node, name, value), do: assert(Floki.attribute(node, name) == [value])

  defp assert_unsupported(selections, model_spec, value) do
    assert LLMSelectionComponents.resolve_reasoning_effort(selections, model_spec, value) ==
             {:error, :unsupported_reasoning_effort}
  end
end
