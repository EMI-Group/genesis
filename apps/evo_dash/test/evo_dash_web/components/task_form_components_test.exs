defmodule EvoDashWeb.TaskFormComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.TaskFormComponents

  # Unit tests for the server-driven layout decision behind the single-card
  # two-layout task form. Threshold: objective length > 300 graphemes OR
  # > 8 explicit lines → :expanded (Layout B), otherwise :compact (Layout A).
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

    test "exactly at the 300-char boundary is compact" do
      assert TaskFormComponents.layout_for(String.duplicate("a", 300)) == :compact
    end

    test "above the 300-char boundary is expanded" do
      assert TaskFormComponents.layout_for(String.duplicate("a", 301)) == :expanded
    end

    test "exactly 8 lines is compact" do
      prompt = Enum.join(1..8, "\n")
      assert TaskFormComponents.layout_for(prompt) == :compact
    end

    test "9 or more lines is expanded" do
      prompt = Enum.join(1..9, "\n")
      assert TaskFormComponents.layout_for(prompt) == :expanded
    end

    test "short but multiline stays compact" do
      assert TaskFormComponents.layout_for("a\nb\nc") == :compact
    end

    test "long single-line string is expanded" do
      assert TaskFormComponents.layout_for(String.duplicate("x", 400)) == :expanded
    end
  end

  # Render smoke tests: data-layout is server-driven, and the control ORDER
  # differs per layout. Both layouts share the same DOM order (mode | Launch |
  # model); the per-layout visual order is achieved with Tailwind order-*
  # classes (Layout A: model order-2, Launch order-3 → mode | model | Launch;
  # Layout B: Launch order-2, model order-3 → mode | Launch | model), so the
  # tests assert those classes via Floki.
  describe "task_form/1 rendering" do
    test "compact layout renders data-layout=compact with Launch Task" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "Short objective")

      assert html =~ ~s(data-layout="compact")
      assert html =~ "Launch Task"
    end

    test "expanded layout for a long objective" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 400)
        )

      assert html =~ ~s(data-layout="expanded")
    end

    test "Layout A (compact): Launch last (order-3), model before it (order-2)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      # Visual order: mode (order-1) | model (order-2) | Launch (order-3).
      assert button_class(html) =~ "order-3"
      assert model_class(html) =~ "order-2"
    end

    test "Layout B (expanded): Launch in the middle (order-2), model last (order-3)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 400),
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      # Visual order: mode (order-1) | Launch (order-2) | model (order-3).
      assert button_class(html) =~ "order-2"
      assert model_class(html) =~ "order-3"
    end

    test "disabled state renders the welcome overlay" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true
        )

      assert html =~ "Open a project to get started"
    end

    test "mode select keeps its three options and task_change event" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      assert html =~ ~s(name="mode")
      assert html =~ ~s(phx-change="task_change")
      assert html =~ "Initialize Existing"
      assert html =~ "Create New"
      assert html =~ "Evolution"
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

  defp model_class(html) do
    [sel] = Floki.find(parse(html), "select[name=model_id]")
    sel |> Floki.attribute("class") |> List.first() |> to_string()
  end

  # Floki 0.38's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
