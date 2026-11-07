defmodule EvoDashWeb.TaskFormProviderSelectionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.TaskFormComponents

  # Render the real task form, not the picker alone: these pins protect the
  # integration boundary while leaving all legacy toolbar tests untouched.
  # Fixtures use the production contract: string-keyed profiles/spec, atom-keyed
  # model projections. No scheduler, provider request or application boot needed.
  describe "provider picker branch activation" do
    test "provider profiles alone activate the picker and suppress the legacy select" do
      doc = render_form(provider_profiles: profiles())

      assert_picker(doc)
      assert values(doc, "#task-llm-selection-provider option") == ["", "work", "personal"]
      assert selected_value(doc, "#task-llm-selection-provider") == ""
      assert attr(doc, "#task-llm-selection-model", "disabled") == ["disabled"]
      assert text(doc, "#task-llm-selection-model option") == "Choose a provider first"
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "model selections alone activate the picker with an honest empty-provider state" do
      doc = render_form(model_selections: selections())

      assert_picker(doc)
      assert attr(doc, "#task-llm-selection-provider", "disabled") == ["disabled"]
      assert attr(doc, "#task-llm-selection-model", "disabled") == ["disabled"]

      assert text(doc, "#task-llm-selection-empty") ==
               "No provider profiles configured. Add one in Settings to choose a model."
    end

    test "a spec alone activates the picker and retains both unavailable selections" do
      doc = render_form(model_spec: spec())

      assert_picker(doc)
      assert_unavailable(doc, "provider", "work", "Unavailable profile: work")
      assert_unavailable(doc, "model", "shared-model", "Unavailable model: shared-model")
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "omitted or explicitly empty new data keeps the selected legacy toolbar model" do
      for extra <- [[], [provider_profiles: [], model_selections: [], model_spec: %{}]] do
        doc = render_form(extra)

        assert Floki.find(doc, "#task-llm-selection") == []
        assert selected_value(doc, ".input-controls select[name=model_id]") == "legacy"
        assert text(doc, "select[name=model_id] option[selected]") == "legacy"
        assert attr(doc, "select[name=model_id]", "phx-change") == ["select_model"]
      end
    end

    test "nil spec with empty new lists also falls back to the legacy select" do
      doc = render_form(provider_profiles: [], model_selections: [], model_spec: nil)

      assert Floki.find(doc, "#task-llm-selection") == []
      assert selected_value(doc, "select[name=model_id]") == "legacy"
    end

    test "no new data and no legacy models renders neither model picker" do
      doc = render_form(model_profiles: [])

      assert Floki.find(doc, "#task-llm-selection, select[name=model_id]") == []
      assert length(Floki.find(doc, ".input-controls select[name=mode]")) == 1
      assert length(Floki.find(doc, ".input-controls #task-launch-button")) == 1
    end
  end

  describe "task form layout and event forwarding" do
    test "compact picker is inside the only form and immediately before the toolbar in both layouts" do
      for {prompt, layout} <- [
            {"Short objective", "compact"},
            {String.duplicate("a", 1300), "expanded"}
          ] do
        doc = render_picker(prompt: prompt)

        assert_picker(doc)
        assert length(Floki.find(doc, "form")) == 1
        assert attr(doc, "#task-form", "phx-submit") == ["task_submit"]
        assert attr(doc, "#input-layout", "data-layout") == [layout]
        assert length(Floki.find(doc, "#task-form .input-card > #task-llm-selection")) == 1
        assert length(Floki.find(doc, "#task-llm-selection + .input-controls")) == 1
        assert Floki.find(doc, ".input-controls #task-llm-selection") == []
        assert_classes(doc, "#task-llm-selection", ["p-3", "mx-3", "mb-2"])
        refute "p-4" in classes(doc, "#task-llm-selection")

        assert_classes(doc, "#task-llm-selection > div", [
          "grid-cols-1",
          "sm:grid-cols-2",
          "lg:grid-cols-3"
        ])

        assert_classes(doc, ".input-controls", ["flex-nowrap"])
      end
    end

    test "picker controls retain explicit submit-form ownership, nesting, default events and payload names" do
      doc = render_picker()

      for {suffix, name, event} <- [
            {"provider", "provider_profile_id", "select_provider_profile"},
            {"model", "model", "select_model"},
            {"reasoning", "reasoning_effort", "select_reasoning_effort"}
          ] do
        selector = "#task-form #task-llm-selection-" <> suffix
        assert attr(doc, selector, "name") == [name]
        assert attr(doc, selector, "phx-change") == [event]
        assert attr(doc, selector, "form") == ["task-form"]
      end

      assert attr(doc, "#task-llm-selection-reasoning", "type") == ["range"]
      assert attr(doc, "#task-llm-selection-reasoning", "value") == ["1"]
      assert attr(doc, "#task-llm-selection-reasoning", "min") == ["0"]
      assert attr(doc, "#task-llm-selection-reasoning", "max") == ["2"]
      assert text(doc, "#task-llm-selection-reasoning-value") == "Medium"
    end

    test "all three event overrides pass through without changing payload names or quality events" do
      doc =
        render_picker(
          provider_event: "task_provider_changed",
          model_event: "task_model_changed",
          reasoning_event: "task_reasoning_changed"
        )

      assert attr(doc, "select[name=provider_profile_id]", "phx-change") == [
               "task_provider_changed"
             ]

      assert attr(doc, "select[name=model]", "phx-change") == ["task_model_changed"]
      assert attr(doc, "input[name=reasoning_effort]", "phx-change") == ["task_reasoning_changed"]
      assert attr(doc, "select[name=mode]", "phx-change") == ["task_change"]

      assert attr(doc, "#quality-level-control button", "phx-click") ==
               List.duplicate("select_quality_level", 3)
    end

    test "Auto forwarding changes the blank provider label, never the chosen profile" do
      for show_auto? <- [false, true] do
        doc = render_picker(show_auto_model_option: show_auto?)
        [blank | _] = Floki.find(doc, "#task-llm-selection-provider option")

        assert Floki.attribute(blank, "value") == [""]
        assert Floki.attribute(blank, "selected") == []

        assert String.trim(Floki.text(blank)) ==
                 if(show_auto?, do: "Auto (by rules)", else: "Choose a provider profile")

        assert selected_value(doc, "#task-llm-selection-provider") == "work"
        assert selected_value(doc, "#task-llm-selection-model") == "shared-model"
      end
    end

    test "Auto with an empty spec stays blank instead of silently choosing a configured model" do
      doc = render_picker(model_spec: %{}, show_auto_model_option: true)

      assert selected_value(doc, "#task-llm-selection-provider") == ""
      assert text(doc, "#task-llm-selection-provider option[selected]") == "Auto (by rules)"
      assert selected_value(doc, "#task-llm-selection-model") == ""
      assert values(doc, "#task-llm-selection-model option") == [""]
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "disabled form hides the entire picker even with all new and legacy data present" do
      doc = render_picker(disabled: true, show_auto_model_option: true)

      assert Floki.find(doc, "#task-llm-selection, select[name=model_id], .input-controls") == []

      assert Floki.find(doc, "[name=provider_profile_id], [name=model], [name=reasoning_effort]") ==
               []

      assert text(doc, "#task-form") =~ "Open a project to get started"
      assert attr(doc, "#prompt", "placeholder") == [""]
    end
  end

  describe "provider-scoped models and stale persisted specs" do
    test "same model name uses the exact provider profile's model list and reasoning capabilities" do
      work = render_picker()
      personal = render_picker(model_spec: spec("personal", "shared-model", "xhigh"))

      assert selected_value(work, "#task-llm-selection-provider") == "work"
      assert values(work, "#task-llm-selection-model option") == ["", "shared-model", "work-only"]
      assert selected_value(work, "#task-llm-selection-model") == "shared-model"
      assert text(work, "#task-llm-selection-provider option[selected]") == "Work account"
      assert text(work, "#task-llm-selection-reasoning-value") == "Medium"
      assert attr(work, "#task-llm-selection-reasoning", "max") == ["2"]

      assert selected_value(personal, "#task-llm-selection-provider") == "personal"

      assert values(personal, "#task-llm-selection-model option") == [
               "",
               "shared-model",
               "personal-only"
             ]

      assert selected_value(personal, "#task-llm-selection-model") == "shared-model"
      assert text(personal, "#task-llm-selection-reasoning-value") == "Extra high"
      assert attr(personal, "#task-llm-selection-reasoning", "value") == ["0"]
      assert attr(personal, "#task-llm-selection-reasoning", "disabled") == ["disabled"]
    end

    test "a model belonging only to another profile is retained as unavailable, not borrowed" do
      doc = render_picker(model_spec: spec("work", "personal-only", "xhigh"))

      assert selected_value(doc, "#task-llm-selection-provider") == "work"
      assert_unavailable(doc, "model", "personal-only", "Unavailable model: personal-only")

      assert values(doc, "#task-llm-selection-model option:not([disabled])") == [
               "",
               "shared-model",
               "work-only"
             ]

      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "a removed provider preserves the persisted provider and model without selecting a replacement" do
      doc = render_picker(model_spec: spec("removed-account", "shared-model", "high"))

      assert_unavailable(
        doc,
        "provider",
        "removed-account",
        "Unavailable profile: removed-account"
      )

      assert_unavailable(doc, "model", "shared-model", "Unavailable model: shared-model")

      assert values(doc, "#task-llm-selection-provider option:not([disabled])") == [
               "",
               "work",
               "personal"
             ]

      assert attr(doc, "#task-llm-selection-model", "disabled") == ["disabled"]
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "a removed model on a known provider stays unavailable while valid alternatives remain visible" do
      doc = render_picker(model_spec: spec("work", "retired-model", "high"))

      assert selected_value(doc, "#task-llm-selection-provider") == "work"
      assert_unavailable(doc, "model", "retired-model", "Unavailable model: retired-model")

      assert values(doc, "#task-llm-selection-model option") == [
               "",
               "retired-model",
               "shared-model",
               "work-only"
             ]

      assert attr(doc, "#task-llm-selection-model", "disabled") == []
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "a known provider without models reports the empty state and does not use another profile" do
      doc =
        render_picker(
          model_selections: Enum.reject(selections(), &(&1.provider_profile_id == "work"))
        )

      assert selected_value(doc, "#task-llm-selection-provider") == "work"
      assert_unavailable(doc, "model", "shared-model", "Unavailable model: shared-model")

      assert text(doc, "#task-llm-selection") =~
               "No models are available for this provider profile."

      assert attr(doc, "#task-llm-selection-model", "disabled") == ["disabled"]
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end
  end

  describe "quality and reasoning are independent task controls" do
    test "every quality choice leaves the explicit reasoning choice unchanged" do
      for quality <- ["fast", "balanced", "high_quality"] do
        doc = render_picker(quality_level: quality)

        assert selected_quality(doc) == quality
        assert text(doc, "#task-llm-selection-reasoning-value") == "Medium"
        assert attr(doc, "#task-llm-selection-reasoning", "value") == ["1"]
        assert Floki.find(doc, "#quality-level-control input[name=reasoning_effort]") == []
        assert length(Floki.find(doc, ".input-controls > #quality-level-control")) == 1
      end
    end

    test "changing reasoning does not alter task quality or its three button payloads" do
      for {effort, index, label} <- [
            {"low", "0", "Low"},
            {"medium", "1", "Medium"},
            {"high", "2", "High"}
          ] do
        doc =
          render_picker(quality_level: "fast", model_spec: spec("work", "shared-model", effort))

        assert selected_quality(doc) == "fast"
        assert text(doc, "#task-llm-selection-reasoning-value") == label
        assert attr(doc, "#task-llm-selection-reasoning", "value") == [index]

        assert attr(doc, "#quality-level-control button", "phx-value-level") == [
                 "fast",
                 "balanced",
                 "high_quality"
               ]

        assert attr(doc, "#quality-level-control button", "type") == List.duplicate("button", 3)
      end
    end

    test "a model with no reasoning support still renders the selected quality control" do
      doc =
        render_picker(
          quality_level: "high_quality",
          model_spec: spec("work", "work-only", "high")
        )

      assert selected_value(doc, "#task-llm-selection-model") == "work-only"
      assert Floki.find(doc, "#task-llm-selection-reasoning, [name=reasoning_effort]") == []
      assert selected_quality(doc) == "high_quality"
    end
  end

  defp render_form(extra) do
    defaults = [
      prompt: "Fix the bug",
      model_profiles: [%{id: "legacy", model: "legacy-model"}],
      selected_model_id: "legacy"
    ]

    render_component(&TaskFormComponents.task_form/1, Keyword.merge(defaults, extra))
    |> Floki.parse_document!()
  end

  defp render_picker(extra \\ []) do
    defaults = [provider_profiles: profiles(), model_selections: selections(), model_spec: spec()]
    render_form(Keyword.merge(defaults, extra))
  end

  defp profiles do
    [
      %{"id" => "work", "name" => "Work account", "provider" => "openai"},
      %{"id" => "personal", "name" => "Personal account", "provider" => "openai"}
    ]
  end

  defp selections do
    [
      %{
        provider_profile_id: "work",
        model: "shared-model",
        reasoning_efforts: ["low", "medium", "high"],
        default_reasoning_effort: "low"
      },
      %{provider_profile_id: "work", model: "work-only", reasoning_efforts: []},
      %{
        provider_profile_id: "personal",
        model: "shared-model",
        reasoning_efforts: ["xhigh"],
        default_reasoning_effort: "xhigh"
      },
      %{provider_profile_id: "personal", model: "personal-only", reasoning_efforts: ["xhigh"]}
    ]
  end

  defp spec(provider \\ "work", model \\ "shared-model", effort \\ "medium") do
    %{"provider_profile_id" => provider, "model" => model, "reasoning_effort" => effort}
  end

  defp assert_picker(doc) do
    assert length(Floki.find(doc, "#task-form #task-llm-selection")) == 1
    assert Floki.find(doc, "select[name=model_id]") == []
  end

  defp assert_unavailable(doc, suffix, value, label) do
    selector = "#task-llm-selection-#{suffix} option[selected]"
    assert attr(doc, selector, "value") == [value]
    assert attr(doc, selector, "disabled") == ["disabled"]
    assert text(doc, selector) == label
  end

  defp selected_quality(doc) do
    [value] = attr(doc, "#quality-level-control button[aria-pressed=true]", "phx-value-level")
    value
  end

  defp selected_value(doc, selector) do
    [value] = attr(doc, selector <> " option[selected]", "value")
    value
  end

  defp attr(doc, selector, name), do: doc |> Floki.find(selector) |> Floki.attribute(name)
  defp values(doc, selector), do: attr(doc, selector, "value")
  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> String.trim()

  defp classes(doc, selector) do
    [value] = attr(doc, selector, "class")
    String.split(value)
  end

  defp assert_classes(doc, selector, expected) do
    actual = classes(doc, selector)
    for class <- expected, do: assert(class in actual)
  end
end
