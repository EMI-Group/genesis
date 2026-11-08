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
      assert provider_values(doc) == ["", "work", "personal"]
      assert selected_provider(doc) == ""
      assert attr(doc, "#task-llm-selection-model .capsule-item", "disabled") == ["disabled"]
      assert text(doc, "#task-llm-selection-model .capsule-item") == "Choose a provider first"
      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "model selections alone activate the picker with an honest empty-provider state" do
      doc = render_form(model_selections: selections())

      assert_picker(doc)
      assert attr(doc, "#task-llm-selection-provider", "disabled") == ["disabled"]
      assert attr(doc, "#task-llm-selection-model .capsule-item", "disabled") == ["disabled"]

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
      assert length(Floki.find(doc, ".input-controls #mode-speed-capsule")) == 1
      assert length(Floki.find(doc, ".input-controls #task-launch-button")) == 1
    end
  end

  describe "task form layout and event forwarding" do
    test "compact picker is inside the only form and the toolbar in both layouts" do
      for {prompt, layout} <- [
            {"Short objective", "compact"},
            {String.duplicate("a", 1300), "expanded"}
          ] do
        doc = render_picker(prompt: prompt)

        assert_picker(doc)
        assert length(Floki.find(doc, "form")) == 1
        assert attr(doc, "#task-form", "phx-submit") == ["task_submit"]
        assert attr(doc, "#input-layout", "data-layout") == [layout]
        assert length(Floki.find(doc, "#task-form .input-controls #task-llm-selection")) == 1
        assert length(Floki.find(doc, ".input-controls #task-llm-selection")) == 1

        assert_classes(doc, ".input-controls", ["flex-nowrap"])
      end
    end

    test "picker controls stay nested in the form, emit default events and payload names, and need no form owner" do
      doc = render_picker()

      drill = "#task-form #task-llm-selection-provider"
      assert attr(doc, drill, "data-capsule-drill") == ["provider"]
      assert attr(doc, "#task-form #task-llm-selection-provider-list", "role") == ["listbox"]

      assert attr(doc, "#task-llm-selection-provider-list .capsule-item", "phx-click") ==
               List.duplicate("select_provider_profile", 3)

      assert attr(
               doc,
               "#task-llm-selection-provider-list .capsule-item",
               "phx-value-provider_profile_id"
             ) ==
               ["", "work", "personal"]

      assert attr(doc, "#task-form #task-llm-selection-model", "role") == ["listbox"]

      assert attr(doc, "#task-llm-selection-model .capsule-item", "phx-click") ==
               List.duplicate("select_model", 3)

      assert attr(doc, "#task-llm-selection-model .capsule-item", "phx-value-model") == [
               "",
               "shared-model",
               "work-only"
             ]

      assert attr(doc, "#task-form #task-llm-selection-reasoning", "role") == ["group"]

      assert attr(doc, "#task-llm-selection-reasoning .capsule-stop", "phx-click") ==
               List.duplicate("select_reasoning_effort", 3)

      assert attr(
               doc,
               "#task-llm-selection-reasoning .capsule-stop",
               "phx-value-reasoning_effort"
             ) ==
               ["0", "1", "2"]

      assert text(doc, "#task-llm-selection-reasoning-value") == "Medium"

      # No form owner and no form control: the picker never submits, so it
      # carries neither a `form` association nor a `phx-change`.
      assert Floki.find(doc, "#task-llm-selection [form]") == []
      assert Floki.find(doc, "#task-llm-selection [phx-change]") == []
      assert Floki.find(doc, "#task-llm-selection select") == []
    end

    test "all three event overrides pass through without changing payload names or quality events" do
      doc =
        render_picker(
          provider_event: "task_provider_changed",
          model_event: "task_model_changed",
          reasoning_event: "task_reasoning_changed"
        )

      assert attr(doc, "#task-llm-selection-provider-list .capsule-item", "phx-click") ==
               List.duplicate("task_provider_changed", 3)

      assert attr(
               doc,
               "#task-llm-selection-provider-list .capsule-item",
               "phx-value-provider_profile_id"
             ) ==
               ["", "work", "personal"]

      assert attr(doc, "#task-llm-selection-model .capsule-item", "phx-click") ==
               List.duplicate("task_model_changed", 3)

      assert attr(doc, "#task-llm-selection-reasoning .capsule-stop", "phx-click") ==
               List.duplicate("task_reasoning_changed", 3)

      assert attr(doc, "#mode-speed-capsule .capsule-item", "phx-click") ==
               List.duplicate("task_change", 4)

      assert attr(doc, "#mode-speed-capsule .capsule-stop", "phx-click") ==
               List.duplicate("select_quality_level", 3)
    end

    test "Auto forwarding changes the blank provider label, never the chosen profile" do
      for show_auto? <- [false, true] do
        doc = render_picker(show_auto_model_option: show_auto?)
        [blank | _] = provider_items(doc)

        assert Floki.attribute(blank, "phx-value-provider_profile_id") == [""]
        assert Floki.attribute(blank, "aria-selected") == ["false"]

        assert String.trim(Floki.text(blank)) ==
                 if(show_auto?, do: "Auto (by rules)", else: "Choose a provider profile")

        assert selected_provider(doc) == "work"
        assert selected_model(doc) == "shared-model"
      end
    end

    test "Auto with an empty spec stays blank instead of silently choosing a configured model" do
      doc = render_picker(model_spec: %{}, show_auto_model_option: true)

      assert selected_provider(doc) == ""

      assert text(doc, "#task-llm-selection-provider-list [role=option][aria-selected=true]") ==
               "Auto (by rules)"

      assert text(doc, "#task-llm-selection-provider .capsule-drill-value") == "Auto (by rules)"
      assert selected_model(doc) == ""
      assert attr(doc, "#task-llm-selection-model .capsule-item", "phx-value-model") == [""]
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

  describe "fused capsule structure" do
    test "both capsule roots opt into the CapsulePanel hook; only the model capsule is a view pair" do
      doc = render_picker()

      assert attr(doc, "#task-llm-selection", "phx-hook") == ["CapsulePanel"]
      assert attr(doc, "#task-llm-selection", "data-capsule-view") == ["model"]

      assert attr(doc, "#mode-speed-capsule", "phx-hook") == ["CapsulePanel"]
      assert attr(doc, "#mode-speed-capsule", "data-capsule-view") == []
      assert Floki.find(doc, "#mode-speed-capsule .capsule-view") == []
    end

    test "the picker drills down inside ONE panel and renders no provider select" do
      doc = render_picker()

      assert length(Floki.find(doc, "#task-llm-selection .capsule-panel")) == 1
      assert length(Floki.find(doc, "#task-llm-selection .capsule-view")) == 2

      assert [_] = Floki.find(doc, ~s(#task-llm-selection .capsule-view[data-view="model"]))
      assert [_] = Floki.find(doc, ~s(#task-llm-selection .capsule-view[data-view="provider"]))
      assert [_] = Floki.find(doc, ~s(#task-llm-selection [data-capsule-drill="provider"]))
      assert [_] = Floki.find(doc, "#task-llm-selection [data-capsule-back]")

      assert attr(doc, "#task-llm-selection-provider-list", "role") == ["listbox"]
      assert attr(doc, "#task-llm-selection-provider-list", "aria-label") == ["Provider profile"]

      assert Floki.find(doc, "#task-llm-selection select") == []
      assert Floki.find(doc, "select[name=provider_profile_id]") == []
      assert Floki.find(doc, "#task-llm-selection [phx-change]") == []
    end
  end

  describe "provider-scoped models and stale persisted specs" do
    test "same model name uses the exact provider profile's model list and reasoning capabilities" do
      work = render_picker()
      personal = render_picker(model_spec: spec("personal", "shared-model", "xhigh"))

      assert selected_provider(work) == "work"

      assert attr(work, "#task-llm-selection-model .capsule-item", "phx-value-model") == [
               "",
               "shared-model",
               "work-only"
             ]

      assert selected_model(work) == "shared-model"
      assert text(work, "#task-llm-selection-provider .capsule-drill-value") == "Work account"
      assert text(work, "#task-llm-selection-reasoning-value") == "Medium"

      assert attr(
               work,
               "#task-llm-selection-reasoning .capsule-stop",
               "phx-value-reasoning_effort"
             ) ==
               ["0", "1", "2"]

      assert selected_provider(personal) == "personal"

      assert attr(personal, "#task-llm-selection-model .capsule-item", "phx-value-model") == [
               "",
               "shared-model",
               "personal-only"
             ]

      assert selected_model(personal) == "shared-model"
      assert text(personal, "#task-llm-selection-reasoning-value") == "Extra high"

      assert attr(
               personal,
               "#task-llm-selection-reasoning .capsule-stop[aria-pressed=true]",
               "phx-value-reasoning_effort"
             ) == ["0"]

      assert attr(personal, "#task-llm-selection-reasoning .capsule-stop", "disabled") == [
               "disabled"
             ]
    end

    test "a model belonging only to another profile is retained as unavailable, not borrowed" do
      doc = render_picker(model_spec: spec("work", "personal-only", "xhigh"))

      assert selected_provider(doc) == "work"
      assert_unavailable(doc, "model", "personal-only", "Unavailable model: personal-only")

      assert attr(
               doc,
               "#task-llm-selection-model .capsule-item:not([disabled])",
               "phx-value-model"
             ) ==
               [
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

      assert provider_values(doc, ":not([disabled])") == [
               "",
               "work",
               "personal"
             ]

      assert attr(doc, "#task-llm-selection-model button[phx-value-model]", "disabled") == [
               "disabled"
             ]

      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "a removed model on a known provider stays unavailable while valid alternatives remain visible" do
      doc = render_picker(model_spec: spec("work", "retired-model", "high"))

      assert selected_provider(doc) == "work"
      assert_unavailable(doc, "model", "retired-model", "Unavailable model: retired-model")

      assert attr(
               doc,
               "#task-llm-selection-model .capsule-item:not([disabled])",
               "phx-value-model"
             ) ==
               [
                 "",
                 "shared-model",
                 "work-only"
               ]

      assert attr(doc, "#task-llm-selection-model .capsule-item[disabled]", "disabled") == [
               "disabled"
             ]

      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end

    test "a known provider without models reports the empty state and does not use another profile" do
      doc =
        render_picker(
          model_selections: Enum.reject(selections(), &(&1.provider_profile_id == "work"))
        )

      assert selected_provider(doc) == "work"
      assert_unavailable(doc, "model", "shared-model", "Unavailable model: shared-model")

      assert text(doc, "#task-llm-selection") =~
               "No models are available for this provider profile."

      assert attr(
               doc,
               "#task-llm-selection-model .capsule-item:not([disabled])",
               "phx-value-model"
             ) ==
               []

      assert Floki.find(doc, "#task-llm-selection-reasoning") == []
    end
  end

  describe "quality and reasoning are independent task controls" do
    test "every quality choice leaves the explicit reasoning choice unchanged" do
      for quality <- ["fast", "balanced", "high_quality"] do
        doc = render_picker(quality_level: quality)

        assert selected_quality(doc) == quality
        assert text(doc, "#task-llm-selection-reasoning-value") == "Medium"

        assert attr(
                 doc,
                 "#task-llm-selection-reasoning .capsule-stop[aria-pressed=true]",
                 "phx-value-reasoning_effort"
               ) == ["1"]

        assert Floki.find(doc, "#mode-speed-capsule #task-llm-selection-reasoning") == []
        assert length(Floki.find(doc, ".input-controls > #mode-speed-capsule")) == 1
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

        assert attr(
                 doc,
                 "#task-llm-selection-reasoning .capsule-stop[aria-pressed=true]",
                 "phx-value-reasoning_effort"
               ) == [index]

        assert attr(doc, "#mode-speed-capsule .capsule-stop", "phx-value-level") == [
                 "fast",
                 "balanced",
                 "high_quality"
               ]

        assert attr(doc, "#mode-speed-capsule .capsule-stop", "type") ==
                 List.duplicate("button", 3)
      end
    end

    test "a model with no reasoning support still renders the selected quality control" do
      doc =
        render_picker(
          quality_level: "high_quality",
          model_spec: spec("work", "work-only", "high")
        )

      assert selected_model(doc) == "work-only"

      assert Floki.find(
               doc,
               "#task-llm-selection-reasoning, #task-llm-selection-reasoning-value, [name=reasoning_effort]"
             ) == []

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

  defp assert_unavailable(doc, "provider", value, label) do
    selector = "#task-llm-selection-provider-list [aria-invalid]"
    assert attr(doc, selector, "phx-value-provider_profile_id") == [value]
    assert attr(doc, selector, "disabled") == ["disabled"]
    assert attr(doc, selector, "phx-click") == []
    assert attr(doc, "#task-llm-selection-provider", "aria-invalid") == ["true"]
    assert text(doc, selector) == label
    assert text(doc, "#task-llm-selection-provider .capsule-drill-value") == label
  end

  defp assert_unavailable(doc, "model", _value, label) do
    selector = "#task-llm-selection-model button[aria-invalid]"
    assert attr(doc, selector, "disabled") == ["disabled"]
    assert attr(doc, selector, "aria-invalid") == ["true"]
    assert text(doc, selector) == label
  end

  defp selected_quality(doc) do
    [value] = attr(doc, "#mode-speed-capsule button[aria-pressed=true]", "phx-value-level")
    value
  end

  defp selected_model(doc) do
    [value] =
      attr(doc, "#task-llm-selection-model .capsule-item[aria-selected=true]", "phx-value-model")

    value
  end

  # Ordered provider-profile rows of the drill-down's provider view: the
  # blank/Auto row first, then a possible stale-profile row, then every
  # configured profile.
  defp provider_items(doc, filter \\ "") do
    Floki.find(doc, ~s(#task-llm-selection-provider-list [role="option"]) <> filter)
  end

  defp provider_values(doc, filter \\ "") do
    doc
    |> provider_items(filter)
    |> Enum.map(fn item ->
      assert [value] = Floki.attribute(item, "phx-value-provider_profile_id")
      value
    end)
  end

  defp selected_provider(doc) do
    [value] =
      attr(
        doc,
        "#task-llm-selection-provider-list [role=option][aria-selected=true]",
        "phx-value-provider_profile_id"
      )

    value
  end

  defp selected_value(doc, selector) do
    [value] = attr(doc, selector <> " option[selected]", "value")
    value
  end

  defp attr(doc, selector, name), do: doc |> Floki.find(selector) |> Floki.attribute(name)
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
