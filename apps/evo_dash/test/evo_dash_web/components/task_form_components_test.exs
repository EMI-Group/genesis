defmodule EvoDashWeb.TaskFormComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.TaskFormComponents

  # Unit tests for the server-driven layout decision behind the single-card
  # two-layout task form. Threshold: objective length > 600 graphemes OR
  # > 16 explicit lines → :expanded (Layout B), otherwise :compact (Layout A).
  describe "layout_for/1" do
    test "empty string is compact" do
      assert TaskFormComponents.layout_for("") == :compact
    end

    test "non-binary values fall back to compact" do
      assert TaskFormComponents.layout_for(nil) == :compact
      assert TaskFormComponents.layout_for(%{}) == :compact
      assert TaskFormComponents.layout_for(123) == :compact
    end

    test "short single-line objective is compact" do
      assert TaskFormComponents.layout_for("Fix the login bug") == :compact
    end

    test "exactly at the 600-char boundary is compact" do
      assert TaskFormComponents.layout_for(String.duplicate("a", 600)) == :compact
    end

    test "above the 600-char boundary is expanded" do
      assert TaskFormComponents.layout_for(String.duplicate("a", 601)) == :expanded
    end

    test "exactly 16 lines is compact" do
      prompt = Enum.join(1..16, "\n")
      assert TaskFormComponents.layout_for(prompt) == :compact
    end

    test "17 or more lines is expanded" do
      prompt = Enum.join(1..17, "\n")
      assert TaskFormComponents.layout_for(prompt) == :expanded
    end

    test "short but multiline stays compact" do
      assert TaskFormComponents.layout_for("a\nb\nc") == :compact
    end

    test "long single-line string is expanded" do
      assert TaskFormComponents.layout_for(String.duplicate("x", 700)) == :expanded
    end
  end

  # Render smoke tests: data-layout is server-driven. Control ORDER is now
  # IDENTICAL in both layouts — DOM order AND visual order are mode (order-1) |
  # Launch (order-2, centered via mx-auto) | model (order-3). Only the textarea
  # size differs per layout, so the tests assert the unified classes via Floki.
  describe "task_form/1 rendering" do
    test "compact layout renders data-layout=compact with the rocket Launch button" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "Short objective")

      assert html =~ ~s(data-layout="compact")
      assert html =~ "hero-rocket-launch"
      assert button_text(html) == "Launch"
    end

    test "expanded layout for a long objective" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 700)
        )

      assert html =~ ~s(data-layout="expanded")
    end

    test "Layout A (compact): Launch order-2 centered (mx-auto), model order-3" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      # Visual order: mode (order-1) | Launch (order-2, mx-auto) | model (order-3).
      assert button_class(html) =~ "order-2"
      assert button_class(html) =~ "mx-auto"
      assert model_class(html) =~ "order-3"
    end

    test "DOM order of the controls row is mode | Launch | model (pins real order)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      children =
        controls
        |> Floki.children()
        |> Enum.filter(fn
          {tag, _, _} when is_binary(tag) -> true
          _ -> false
        end)

      # Exactly three element children, in document order: mode select, Launch
      # button, model select.
      assert [mode_el, button_el, model_el] = children

      # Mode select comes FIRST and carries order-1.
      assert {tag, mode_attrs, _} = mode_el
      assert tag == "select"
      assert {"name", "mode"} in mode_attrs
      assert {"class", mode_class} = List.keyfind(mode_attrs, "class", 0)
      assert mode_class =~ "order-1"

      # Launch button is SECOND, carries order-2 + mx-auto.
      assert {tag, button_attrs, _} = button_el
      assert tag == "button"
      assert {"type", "submit"} in button_attrs
      assert {"class", button_class} = List.keyfind(button_attrs, "class", 0)
      assert button_class =~ "order-2"
      assert button_class =~ "mx-auto"

      # Model select comes THIRD and carries order-3.
      assert {tag, model_attrs, _} = model_el
      assert tag == "select"
      assert {"name", "model_id"} in model_attrs
      assert {"class", model_class} = List.keyfind(model_attrs, "class", 0)
      assert model_class =~ "order-3"
    end

    test "model option shows only the profile id as its label" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [option] = Floki.find(doc, "select[name=model_id] option")

      # Label is the bare profile id; the value attribute still carries it.
      assert option |> Floki.text() |> String.trim() == "pro"
      assert option |> Floki.attribute("value") |> List.first() == "pro"
      refute html =~ "pro (gpt-x)"
    end

    test "Layout B (expanded): Launch order-2 centered (mx-auto), model order-3" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 700),
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      # Visual order: mode (order-1) | Launch (order-2, mx-auto) | model (order-3).
      assert button_class(html) =~ "order-2"
      assert button_class(html) =~ "mx-auto"
      assert model_class(html) =~ "order-3"
    end

    test "Launch stays centered (mx-auto) when no model profiles exist" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      assert button_class(html) =~ "mx-auto"
      refute html =~ ~s(name="model_id")
    end

    test "disabled state renders the welcome overlay" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true
        )

      assert html =~ "Open a project to get started"
    end

    test "controls row stays on one line (flex-nowrap)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # One-line contract: flex-nowrap, never flex-wrap.
      controls_class = controls |> Floki.attribute("class") |> List.first() |> to_string()
      assert controls_class =~ "flex-nowrap"
      refute controls_class =~ "flex-wrap"

      # Both selects shrink/truncate instead of forcing the row wider.
      assert mode_class(html) =~ "min-w-0"
      assert mode_class(html) =~ "truncate"
      assert model_class(html) =~ "min-w-0"
      assert model_class(html) =~ "truncate"
    end

    test "mode select keeps its three options and task_change event" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      assert html =~ ~s(name="mode")
      assert html =~ ~s(phx-change="task_change")
      assert html =~ "Initialize Existing"
      assert html =~ "Create New"
      assert html =~ "Evolution"
    end

    test "Launch button carries the server-rendered data-mode attribute" do
      # Default mode is genesis_new when no mode attr is passed.
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")
      assert button_attr(html, "data-mode") == "genesis_new"

      # An explicit mode attr is rendered through to the button.
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          mode: "evolve_simple"
        )

      assert button_attr(html, "data-mode") == "evolve_simple"
    end

    test "textarea carries the task_prompt_change event and keeps AdaptiveInput" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      assert html =~ ~s(phx-change="task_prompt_change")
      assert html =~ ~s(phx-hook="AdaptiveInput")
      assert html =~ ~s(phx-update="ignore")
    end
  end

  # --- helpers ---

  defp button_class(html) do
    [btn] = Floki.find(parse(html), "button[type=submit]")
    btn |> Floki.attribute("class") |> List.first() |> to_string()
  end

  defp button_text(html) do
    [btn] = Floki.find(parse(html), "button[type=submit]")
    btn |> Floki.text() |> String.trim()
  end

  defp button_attr(html, attr) do
    [btn] = Floki.find(parse(html), "button[type=submit]")
    btn |> Floki.attribute(attr) |> List.first() |> to_string()
  end

  defp model_class(html) do
    [sel] = Floki.find(parse(html), "select[name=model_id]")
    sel |> Floki.attribute("class") |> List.first() |> to_string()
  end

  defp mode_class(html) do
    [sel] = Floki.find(parse(html), "select[name=mode]")
    sel |> Floki.attribute("class") |> List.first() |> to_string()
  end

  # Floki 0.38's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
