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

  describe "llm_selection/1 — discrete reasoning stops" do
    for {effort, index, label} <- [
          {"low", 0, "Low"},
          {"medium", 1, "Medium"},
          {"high", 2, "High"}
        ] do
      test "#{effort} renders index #{index} with its associated accessible label" do
        tree = render_picker(model_spec: spec(%{"reasoning_effort" => unquote(effort)}))
        group = one(tree, "#llm-selection-reasoning")

        assert_attr(group, "role", "group")
        assert_attr(group, "aria-label", "Reasoning effort")

        selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
        assert_attr(selected, "type", "button")
        assert_attr(selected, "phx-click", "select_reasoning_effort")
        assert_attr(selected, "phx-value-reasoning_effort", Integer.to_string(unquote(index)))
        assert text(selected) == unquote(label)
        assert Floki.attribute(selected, "disabled") == []

        assert text(one(tree, "#llm-selection-reasoning-value")) == unquote(label)

        stops = Floki.find(tree, "#llm-selection-reasoning .capsule-stop")

        assert Enum.map(stops, &Floki.attribute(&1, "phx-value-reasoning_effort")) == [
                 ["0"],
                 ["1"],
                 ["2"]
               ]

        assert Enum.map(stops, &text/1) == ["Low", "Medium", "High"]
      end
    end

    test "singleton effort renders a single disabled stop" do
      tree =
        render_picker(
          model_selections: [
            selection(%{reasoning_efforts: ["high"], default_reasoning_effort: "high"})
          ]
        )

      stop = one(tree, "#llm-selection-reasoning .capsule-stop")

      assert_attr(stop, "phx-value-reasoning_effort", "0")
      assert_attr(stop, "aria-pressed", "true")
      assert_attr(stop, "disabled", "disabled")
      assert text(stop) == "High"
      assert text(one(tree, "#llm-selection-reasoning-value")) == "High"
      assert Floki.attribute(one(tree, "#llm-selection-model"), "disabled") == []
    end

    test "models without advertised efforts omit all reasoning controls" do
      for model <- [
            selection(%{reasoning_efforts: []}),
            selection(%{reasoning_efforts: nil}),
            Map.delete(selection(), :reasoning_efforts)
          ] do
        tree = render_picker(model_selections: [model])

        assert Floki.find(tree, "#llm-selection-reasoning, #llm-selection-reasoning-value") == []
        assert Floki.find(tree, "input[type=range], output, datalist") == []

        assert_attr(
          one(tree, ~s(#llm-selection-model button[aria-selected="true"])),
          "phx-value-model",
          "shared-model"
        )
      end
    end

    test "missing or unsupported requested effort falls back to the advertised default" do
      for model_spec <- [
            spec(),
            spec(%{"reasoning_effort" => "obsolete"}),
            spec(%{"reasoning_effort" => nil})
          ] do
        tree = render_picker(model_spec: model_spec)

        selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
        assert_attr(selected, "phx-value-reasoning_effort", "1")
        assert text(selected) == "Medium"
        assert text(one(tree, "#llm-selection-reasoning-value")) == "Medium"
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

        selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
        assert_attr(selected, "phx-value-reasoning_effort", "0")
        assert text(selected) == "High"
        assert text(one(tree, "#llm-selection-reasoning-value")) == "High"
      end
    end

    test "a supported explicit effort wins over the default" do
      tree = render_picker(model_spec: spec(%{"reasoning_effort" => "low"}))

      selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
      assert_attr(selected, "phx-value-reasoning_effort", "0")
      assert text(selected) == "Low"
      assert text(one(tree, "#llm-selection-reasoning-value")) == "Low"
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

      stops = Floki.find(tree, "#llm-selection-reasoning .capsule-stop")

      assert Enum.map(stops, &text/1) == labels

      assert Enum.map(stops, &Floki.attribute(&1, "phx-value-reasoning_effort")) == [
               ["0"],
               ["1"],
               ["2"],
               ["3"],
               ["4"],
               ["5"],
               ["6"],
               ["7"]
             ]
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

        selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
        assert_attr(selected, "phx-value-reasoning_effort", "0")
        assert text(selected) == "Extra high"
        assert text(one(tree, "#llm-selection-reasoning-value")) == "Extra high"

        assert Enum.map(Floki.find(tree, "#llm-selection-reasoning .capsule-stop"), &text/1) == [
                 "Extra high",
                 "Minimal"
               ]

        assert Enum.map(
                 Floki.find(tree, "#llm-selection-model .capsule-item"),
                 &Floki.attribute(&1, "phx-value-model")
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

      selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
      assert_attr(selected, "phx-value-reasoning_effort", "0")
      assert text(selected) == "Extra high"
      assert text(one(tree, "#llm-selection-reasoning-value")) == "Extra high"
    end
  end

  describe "provider/model controls and reusable picker states" do
    test "uses string-keyed profile labels and spec values without leaking credentials" do
      tree = render_picker()
      assert text(one(tree, ~s(label[for="llm-selection-provider"]))) == "Provider profile"

      provider = one(tree, "#llm-selection-provider")
      assert_attr(provider, "name", "provider_profile_id")
      assert_attr(provider, "phx-change", "select_provider_profile")
      assert_attr(one(provider, "option[selected]"), "value", "primary")
      assert text(one(provider, "option[selected]")) == "Primary account"
      assert text(one(provider, ~s(option[value="secondary"]))) == "secondary"

      model = one(tree, "#llm-selection-model")
      assert_attr(model, "role", "listbox")
      assert_attr(model, "aria-label", "Model")
      selected = one(model, ~s(button[aria-selected="true"]))
      assert_attr(selected, "phx-click", "select_model")
      assert_attr(selected, "phx-value-model", "shared-model")
      assert text(selected) == "shared-model"

      refute text(tree) =~ "secret-not-for-display"
      refute inspect(tree) =~ "secret-not-for-display"
      assert Floki.find(tree, "form") == []
    end

    test "custom ids associate all controls without collisions" do
      tree = render_picker(id: "task-picker") ++ render_picker(id: "assistant-picker")
      ids = Floki.attribute(tree, "[id]", "id")
      assert length(ids) == length(Enum.uniq(ids))

      for id <- ["task-picker", "assistant-picker"] do
        capsule = one(tree, "##{id}")
        one(capsule, ~s(label[for="#{id}-provider"]))
        one(capsule, "##{id}-provider")

        assert_attr(one(capsule, "##{id}-model"), "aria-label", "Model")
        assert_attr(one(capsule, "##{id}-reasoning"), "aria-label", "Reasoning effort")
        one(capsule, "##{id}-reasoning-value")
      end
    end

    test "event overrides change events but preserve payload names" do
      tree =
        render_picker(
          provider_event: "choose_account",
          model_event: "choose_model",
          reasoning_event: "choose_effort"
        )

      provider = one(tree, "#llm-selection-provider")
      assert_attr(provider, "phx-change", "choose_account")
      assert_attr(provider, "name", "provider_profile_id")

      model = one(tree, ~s(#llm-selection-model button[aria-selected="true"]))
      assert_attr(model, "phx-click", "choose_model")
      assert_attr(model, "phx-value-model", "shared-model")

      reasoning = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
      assert_attr(reasoning, "phx-click", "choose_effort")
      assert_attr(reasoning, "phx-value-reasoning_effort", "1")
    end

    test "disabled disables every control without erasing selection" do
      tree = render_picker(disabled: true)

      capsule = one(tree, "#llm-selection")
      classes = Floki.attribute(capsule, "class") |> List.first()
      assert classes =~ "pointer-events-none"
      assert classes =~ "opacity-60"
      assert Floki.attribute(capsule, "disabled") == []

      for control <-
            Floki.find(
              tree,
              "#llm-selection-provider, #llm-selection-model button, #llm-selection-reasoning button"
            ) do
        assert_attr(control, "disabled", "disabled")
      end

      selected = one(tree, ~s(#llm-selection-reasoning button[aria-pressed="true"]))
      assert_attr(selected, "phx-value-reasoning_effort", "1")
      assert text(one(tree, "#llm-selection-reasoning-value")) == "Medium"
    end

    test "empty defaults offer an accessible settings hint and no reasoning controls" do
      tree =
        render_component(&LLMSelectionComponents.llm_selection/1, []) |> Floki.parse_document!()

      provider = one(tree, "#llm-selection-provider")
      assert_attr(provider, "disabled", "disabled")
      assert_attr(provider, "aria-describedby", "llm-selection-empty")
      assert text(one(provider, "option[selected]")) == "Choose a provider profile"

      blank = one(tree, ~s(#llm-selection-model button[aria-selected="true"]))
      assert_attr(blank, "disabled", "disabled")
      assert_attr(blank, "phx-value-model", "")
      assert text(blank) == "Choose a provider first"

      assert text(one(tree, "#llm-selection-empty")) ==
               "No provider profiles configured. Add one in Settings to choose a model."

      assert Floki.find(
               tree,
               "input[type=range], output, datalist, #llm-selection-reasoning, #llm-selection-reasoning-value"
             ) == []
    end

    test "Auto is a selected blank profile and never silently selects a model" do
      tree = render_picker(model_spec: %{}, show_auto_option: true)
      auto = one(tree, "#llm-selection-provider option[selected]")
      assert_attr(auto, "value", "")
      assert text(auto) == "Auto (by rules)"

      blank = one(tree, ~s(#llm-selection-model button[aria-selected="true"]))
      assert_attr(blank, "disabled", "disabled")
      assert_attr(blank, "phx-value-model", "")
      assert text(blank) == "Choose a provider first"

      assert Floki.find(
               tree,
               "input[type=range], #llm-selection-reasoning, #llm-selection-reasoning-value"
             ) == []
    end

    test "a known profile without models renders its own empty state" do
      tree = render_picker(model_selections: [], model_spec: spec(%{"model" => ""}))
      assert Floki.attribute(one(tree, "#llm-selection-provider"), "disabled") == []

      blank = one(tree, ~s(#llm-selection-model button[aria-selected="true"]))
      assert_attr(blank, "disabled", "disabled")
      assert_attr(blank, "phx-value-model", "")
      assert text(blank) == "Choose a model"

      assert text(tree) =~ "No models are available for this provider profile."

      assert Floki.find(
               tree,
               "#llm-selection-empty, input[type=range], #llm-selection-reasoning, #llm-selection-reasoning-value"
             ) == []
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

      model = one(tree, ~s(#llm-selection-model button.capsule-item-placeholder))
      assert_attr(model, "disabled", "disabled")
      assert_attr(model, "aria-invalid", "true")
      assert text(model) == "Unavailable model: removed-model"

      assert Floki.find(
               tree,
               "input[type=range], #llm-selection-reasoning, #llm-selection-reasoning-value"
             ) == []

      refute text(tree) =~ "No models are available for this provider profile."
    end

    test "a stale model within a known profile preserves valid alternatives but has no range" do
      tree = render_picker(model_spec: spec(%{"model" => "removed-model"}))

      selected = one(tree, ~s(#llm-selection-model button.capsule-item-placeholder))
      assert_attr(selected, "disabled", "disabled")
      assert text(selected) == "Unavailable model: removed-model"

      alternative = one(tree, ~s(#llm-selection-model button[phx-value-model="shared-model"]))
      assert Floki.attribute(alternative, "disabled") == []
      assert text(alternative) == "shared-model"

      assert Floki.find(
               tree,
               "input[type=range], #llm-selection-reasoning, #llm-selection-reasoning-value"
             ) == []
    end
  end

  describe "single-panel structure" do
    test "provider, model list and reasoning stops share ONE panel with no nested sub-layer" do
      tree = render_picker()
      panel = one(tree, "#llm-selection .capsule-panel")

      # Every control lives inside the same expanded panel.
      for id <- ["#llm-selection-provider", "#llm-selection-model", "#llm-selection-reasoning"] do
        assert [_] = Floki.find(panel, id)
      end

      # The old two-layer structure is gone: no nested disclosure, no
      # current-model subrow, no list-panel wrapper.
      assert Floki.find(tree, "#llm-selection .capsule-sub") == []
      assert Floki.find(tree, "#llm-selection .capsule-subrow") == []
      assert Floki.find(tree, "#llm-selection .capsule-list-panel") == []
      assert Floki.find(tree, "#llm-selection details") == []
    end

    test "the reasoning group is a panel section, not the removed layer-1 hero group" do
      tree = render_picker()
      group = one(tree, "#llm-selection-reasoning")

      assert_attr(group, "class", "capsule-stops flex flex-wrap gap-1")

      # Nested one level down inside its own labelled section, so the old
      # "first thing in the panel" hero group cannot come back.
      assert Floki.find(tree, "#llm-selection .capsule-panel > #llm-selection-reasoning") == []

      assert [_] =
               Floki.find(
                 tree,
                 "#llm-selection .capsule-panel > div > #llm-selection-reasoning"
               )
    end

    test "the trigger still shows the model name, the reasoning effort and a chevron" do
      tree = render_picker()
      trigger = one(tree, "#llm-selection > summary")

      assert text(one(trigger, ".capsule-main")) == "shared-model"
      assert text(one(trigger, "#llm-selection-reasoning-value")) == "Medium"
      assert [_] = Floki.find(trigger, ".capsule-chevron")
      assert Floki.find(trigger, ".capsule-stop, .capsule-item, #llm-selection-model") == []
    end

    test "no reasoning section at all when the selected model has no effort inventory" do
      tree = render_picker(model_selections: [selection(%{reasoning_efforts: []})])
      panel = one(tree, "#llm-selection .capsule-panel")

      assert Floki.find(tree, "#llm-selection-reasoning, #llm-selection-reasoning-value") == []
      assert Floki.find(panel, ".capsule-stops") == []

      # Provider + model controls still render in the same panel.
      assert [_] = Floki.find(panel, "#llm-selection-provider")
      assert [_] = Floki.find(panel, "#llm-selection-model")
    end

    test "empty profile state renders inside the same single panel" do
      tree =
        render_component(&LLMSelectionComponents.llm_selection/1, []) |> Floki.parse_document!()

      panel = one(tree, "#llm-selection .capsule-panel")

      assert text(one(panel, "#llm-selection-empty")) ==
               "No provider profiles configured. Add one in Settings to choose a model."

      assert Floki.find(tree, "#llm-selection .capsule-sub, #llm-selection details") == []
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
