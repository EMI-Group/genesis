defmodule EvoDashWeb.TaskFormComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.TaskFormComponents

  # Unit tests for the server-driven layout decision behind the single-card
  # two-layout task form. Threshold: objective length > 1200 graphemes OR
  # > 32 explicit lines → :expanded (Layout B), otherwise :compact (Layout A).
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

    test "exactly at the 1200-char boundary is compact" do
      assert TaskFormComponents.layout_for(String.duplicate("a", 1200)) == :compact
    end

    test "above the 1200-char boundary is expanded" do
      assert TaskFormComponents.layout_for(String.duplicate("a", 1201)) == :expanded
    end

    test "exactly 32 lines is compact" do
      prompt = Enum.join(1..32, "\n")
      assert TaskFormComponents.layout_for(prompt) == :compact
    end

    test "33 or more lines is expanded" do
      prompt = Enum.join(1..33, "\n")
      assert TaskFormComponents.layout_for(prompt) == :expanded
    end

    test "short but multiline stays compact" do
      assert TaskFormComponents.layout_for("a\nb\nc") == :compact
    end

    test "long single-line string is expanded" do
      assert TaskFormComponents.layout_for(String.duplicate("x", 1300)) == :expanded
    end
  end

  # Render smoke tests: data-layout is server-driven. The bottom toolbar
  # (.input-controls) is IDENTICAL in both layouts — DOM order AND visual
  # order are attach "+" (bottom-left) → free space → a RIGHT-ALIGNED cluster:
  # mode select → (custom-agent select) → model select → circular icon-only
  # send button (the cluster's LAST element = the row's far right, with NO
  # auto margin of its own). The row's auto margin (ml-auto) lives on the MODE
  # select — it absorbs the free space so the cluster packs at the right edge.
  # Only the textarea size differs per layout, so the tests assert the unified
  # classes via Floki.
  describe "task_form/1 rendering" do
    test "compact layout renders data-layout=compact with the circular send button" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "Short objective")

      assert html =~ ~s(data-layout="compact")
      assert html =~ "hero-arrow-up"
      refute html =~ "hero-rocket-launch"
      assert button_attr(html, "aria-label") == "Launch"
      # Icon-only: no visible text label inside the button.
      assert button_text(html) == ""
    end

    test "expanded layout for a long objective" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 1300)
        )

      assert html =~ ~s(data-layout="expanded")
    end

    test "Layout A (compact): compact selects + right-aligned cluster (mode select ml-auto)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      # Compact controls: the selects are select-sm scale (no select-md), the
      # send button is a small filled circle at the row's far right. The
      # right-aligned cluster [mode | model | send] is packed right by the MODE
      # select's ml-auto — the launch button carries NO auto margin (no order-*
      # / mx-auto centering trick anywhere).
      assert mode_class(html) =~ "select-sm"
      refute mode_class(html) =~ "select-md"
      assert model_class(html) =~ "select-sm"
      refute model_class(html) =~ "select-md"
      assert button_class(html) =~ "btn-circle"
      assert button_class(html) =~ "btn-sm"
      assert mode_class(html) =~ "ml-auto"
      refute button_class(html) =~ "ml-auto"
      refute mode_class(html) =~ "order-"
      refute mode_class(html) =~ "mx-auto"
      refute button_class(html) =~ "order-"
      refute button_class(html) =~ "mx-auto"
    end

    test "toolbar DOM order is attach + | mode | model | send (pins real order)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # Interactive controls in document order: attach "+" first (bottom-left),
      # mode select, model select, circular send button LAST (rightmost member
      # of the right-aligned cluster). The hidden .file-manual fallback div is
      # a sibling in the same row but is not an interactive control.
      found =
        Floki.find(
          controls,
          "button#objective-file-button, select[name=mode], select[name=model_id], button#task-launch-button"
        )

      assert [
               {"button", attach_attrs, _},
               {"select", mode_attrs, _},
               {"select", model_attrs, _},
               {"button", launch_attrs, _}
             ] = found

      assert {"id", "objective-file-button"} in attach_attrs
      assert {"name", "mode"} in mode_attrs
      assert {"name", "model_id"} in model_attrs
      assert {"id", "task-launch-button"} in launch_attrs
      assert {"type", "submit"} in launch_attrs

      # Free-space placement: the row's auto margin lives on the MODE select
      # (ml-auto — the cluster lead), NOT on the launch button, so the free
      # space sits before the cluster [mode | model | send] rather than
      # between model and launch.
      assert mode_class(html) =~ "ml-auto"
      assert {"class", launch_class} = List.keyfind(launch_attrs, "class", 0)
      refute launch_class =~ "ml-auto"
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

    test "Layout B (expanded): identical toolbar — right-aligned cluster: mode select ml-auto, send button last" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 1300),
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      assert html =~ ~s(data-layout="expanded")

      # The bottom toolbar is identical in both layouts (only the textarea
      # size differs): compact selects in a right-aligned cluster — the MODE
      # select carries the row's ml-auto (cluster lead), the circular send
      # button is the cluster's last element with no auto margin.
      assert mode_class(html) =~ "select-sm"
      assert model_class(html) =~ "select-sm"
      assert button_class(html) =~ "btn-circle"
      assert mode_class(html) =~ "ml-auto"
      refute button_class(html) =~ "ml-auto"
      refute mode_class(html) =~ "mx-auto"
      refute button_class(html) =~ "mx-auto"
    end

    test "right-aligned cluster holds when no model profiles exist (mode select ml-auto)" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      # No order-* / mx-auto centering: the MODE select's ml-auto still packs
      # the cluster at the row's right edge even in the 2-control edge case
      # (no model select); the circular send button carries no auto margin.
      assert mode_class(html) =~ "ml-auto"
      assert button_class(html) =~ "btn-circle"
      refute button_class(html) =~ "ml-auto"
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

    test "disabled state suppresses the task-launch placeholder (genesis_new default)" do
      # Regression: with no project open (@disabled) the mode-dependent
      # task-launch hint is an empty placeholder — the centered welcome overlay
      # is the only hint. Covers the genesis_new branch's creation hint.
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true
        )

      refute html =~ ~s(placeholder="Describe what you want to change or improve...")
      refute html =~ ~s(placeholder="Describe the codebase you want to create...")

      refute html =~
               ~s(placeholder="Optional — leave empty and click Launch to initialize an existing codebase")

      assert html =~ "Open a project to get started"
    end

    test "disabled state suppresses the evolve placeholder (evolve_simple)" do
      # Regression for the reported bug: the evolve-family placeholder
      # ("Describe what you want to change or improve...") must NOT leak into
      # the disabled (no-project) state either.
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true,
          mode: "evolve_simple"
        )

      refute html =~ ~s(placeholder="Describe what you want to change or improve...")
      refute html =~ ~s(placeholder="Describe the codebase you want to create...")

      refute html =~
               ~s(placeholder="Optional — leave empty and click Launch to initialize an existing codebase")

      assert html =~ "Open a project to get started"
    end

    test "evolve_simple placeholder renders when a project is open (not disabled)" do
      # Control: with a project open (@disabled == false) the evolve-family
      # task-launch hint is unchanged.
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: false,
          mode: "evolve_simple"
        )

      assert html =~ ~s(placeholder="Describe what you want to change or improve...")
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

      # Bottom-toolbar "+" button (bottom-LEFT of the row): square ghost
      # button — no absolute top-right floating over the textarea anymore.
      assert btn_class = btn |> Floki.attribute("class") |> List.first() |> to_string()
      refute btn_class =~ "absolute"
      refute btn_class =~ "top-2"
      assert btn_class =~ "btn-square"

      # "+" icon inside the button (the paper-clip was the old top-right design).
      assert html =~ "hero-plus"
      refute html =~ "hero-paper-clip"
    end

    test "attach-file button is the first element inside the controls row" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # Placement contract (INVERTED vs the old top-right design): the attach
      # "+" button now lives INSIDE .input-controls as its FIRST element child
      # (bottom-left of the toolbar), followed by the hidden .file-manual
      # fallback div — both direct children of the toolbar row.
      element_children =
        controls
        |> Floki.children()
        |> Enum.filter(fn
          {tag, _, _} when is_binary(tag) -> true
          _ -> false
        end)

      assert [{"button", first_attrs, _}, {"div", manual_attrs, _} | _] = element_children
      assert {"id", "objective-file-button"} in first_attrs
      assert {"id", "objective-file-manual"} in manual_attrs
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
