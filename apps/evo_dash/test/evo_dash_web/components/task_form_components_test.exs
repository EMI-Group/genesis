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
          model_profiles: [%{id: "pro", model: "gpt-x"}],
          selected_model_id: "pro"
        )

      doc = parse(html)
      [option] = Floki.find(doc, "select[name=model_id] option")

      # Label is the bare profile id; the value attribute still carries it.
      assert option |> Floki.text() |> String.trim() == "pro"
      assert option |> Floki.attribute("value") |> List.first() == "pro"
      refute html =~ "pro (gpt-x)"
    end

    test "model select shows Auto (by rules) first when no model is selected" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [auto, pro] = Floki.find(doc, "select[name=model_id] option")

      # The auto option (empty value) leads so the select is never visually
      # empty; the profile option follows.
      assert auto |> Floki.text() |> String.trim() == "Auto (by rules)"
      assert auto |> Floki.attribute("value") |> List.first() == ""
      assert pro |> Floki.attribute("value") |> List.first() == "pro"
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

    test "mode select keeps its four options and task_change event" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      assert html =~ ~s(name="mode")
      assert html =~ ~s(phx-change="task_change")
      assert html =~ "Initialize existing project"
      assert html =~ ~s(value="genesis_existing")
      assert html =~ "Create new project"
      assert html =~ ~s(value="genesis_new")
      assert html =~ "Evolve existing project"
      assert html =~ ~s(value="evolve_simple")
      assert html =~ "Custom Agent"
      assert html =~ ~s(value="custom_agent")
      # The Self-Reflective (reflect) mode was removed with the Home chat page.
      refute html =~ "Self-Reflective"
      refute html =~ ~s(value="reflect")
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

      # custom_agent drives its own violet hover-ring rule via data-mode.
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          mode: "custom_agent"
        )

      assert button_attr(html, "data-mode") == "custom_agent"
    end

    test "custom_agent mode hides the Auto (recommended) option in the agent select" do
      agents = [%{id: "my-agent", name: "Bug Hunter"}]

      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          mode: "custom_agent",
          custom_agents: agents
        )

      # In Custom Agent mode the agent MUST be chosen — the Auto option (empty
      # value) is hidden so the select can never render an empty choice.
      assert html =~ "Bug Hunter"
      refute html =~ "Auto (recommended)"

      # Control: other modes keep the Auto option with the same agents.
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          custom_agents: agents
        )

      assert html =~ "Auto (recommended)"
    end

    test "custom_agent mode renders the no-agents warning hint" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          mode: "custom_agent"
        )

      assert html =~
               "No custom agents defined. Add one in Settings → Agents to use Custom Agent mode."

      assert html =~ "hero-exclamation-triangle"
    end

    test "custom_agent mode renders the with-agents hint" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          mode: "custom_agent",
          custom_agents: [%{id: "my-agent", name: "Bug Hunter"}]
        )

      assert html =~ "Runs the selected custom agent as the root agent of an evolution task."
      assert html =~ "hero-user-circle"
    end

    test "custom_agent mode uses the evolve-family placeholder" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          mode: "custom_agent",
          disabled: false
        )

      assert html =~ ~s(placeholder="Describe what you want to change or improve...")
    end

    test "textarea keeps AdaptiveInput + phx-update=ignore with no per-keystroke server event" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      assert html =~ ~s(phx-hook="AdaptiveInput")
      assert html =~ ~s(phx-update="ignore")

      # The per-keystroke server round-trip was removed — layout switching is
      # client-side (AdaptiveInput hook) and @task_prompt is only updated via
      # the restore_state event (and cleared by task_submit after launch).
      refute html =~ ~s(phx-change="task_prompt_change")
      refute html =~ ~s(phx-debounce="200")
    end

    test "attach-file button renders when a project is active (default)" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      [btn] = Floki.find(parse(html), "button#objective-file-button")

      # FilePicker hook wiring + picker id used by the JS hook to correlate
      # the server's "picker_result:<id>" push.
      assert btn |> Floki.attribute("phx-hook") |> List.first() == "FilePicker"
      assert btn |> Floki.attribute("data-picker-id") |> List.first() == "objective_file"

      # type="button" is critical: inside the task form a button without it
      # would submit the form.
      assert btn |> Floki.attribute("type") |> List.first() == "button"

      assert btn |> Floki.attribute("aria-label") |> List.first() == "Attach file"
      assert btn |> Floki.attribute("title") |> List.first() == "Attach file"

      # Floats at the card's top-right corner (absolute, requires `relative`
      # on .input-card), square ghost button.
      assert btn_class = btn |> Floki.attribute("class") |> List.first() |> to_string()
      assert btn_class =~ "absolute top-2 right-2"
      assert btn_class =~ "btn-square"

      # Paper-clip icon inside the button.
      assert html =~ "hero-paper-clip"
    end

    test "attach-file button is NOT inside the controls row" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # Placement contract: the attach-file button sits between the textarea
      # and .input-controls — NOT inside the row — so the DOM-order test
      # (exactly 3 children: mode | Launch | model) stays valid.
      assert Floki.find(controls, "button#objective-file-button") == []
    end

    test "attach-file button is not rendered in the disabled (no-project) state" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true
        )

      assert Floki.find(parse(html), "button#objective-file-button") == []
    end
  end

  # task_options_tab/1 — the "Task Options" dropdown tab. Mode gating contract:
  # Build System renders for genesis* modes only; Starting Node / Starting
  # Commit / Resume from render for the evolve family (evolve* + custom_agent);
  # the Archive toggle renders for all modes.
  describe "task_options_tab/1 rendering" do
    test "custom_agent mode shows evolve-family advanced options and hides the genesis build-system select" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_options_tab/1, mode: "custom_agent")

      assert html =~ "Starting Node"
      assert html =~ "Starting Commit"
      assert html =~ "Resume from"
      refute html =~ "Build System"
    end

    test "genesis_new mode shows the build-system select and hides advanced options" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_options_tab/1,
          mode: "genesis_new"
        )

      assert html =~ "Build System"
      refute html =~ "Starting Commit"
      refute html =~ "Resume from"
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
