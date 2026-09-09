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

    test "toolbar DOM order is attach dropdown | mode | model | send (pins real order)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # Interactive controls in document order: the attach-kind dropdown's "+"
      # <summary> trigger first (bottom-left — inside the wrapping
      # <details#objective-file-attach>), then mode select, model select,
      # circular send button LAST (rightmost member of the right-aligned
      # cluster). The hidden .file-manual fallback div is a sibling in the same
      # row but is not an interactive control.
      found =
        Floki.find(
          controls,
          "summary#objective-file-button, select[name=mode], select[name=model_id], button#task-launch-button"
        )

      assert [
               {"summary", attach_attrs, _},
               {"select", mode_attrs, _},
               {"select", model_attrs, _},
               {"button", launch_attrs, _}
             ] = found

      assert {"id", "objective-file-button"} in attach_attrs

      # The summary is the visual trigger of the attach-kind <details
      # class="dropdown"> — the FilePicker hook lives on that wrapping element.
      [details] = Floki.find(controls, "details#objective-file-attach")
      details_class = details |> Floki.attribute("class") |> List.first() |> to_string()
      assert details_class =~ "dropdown"

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

    test "attach-file dropdown renders when a project is active (default)" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")
      doc = parse(html)

      # The attach control is now an attach-kind <details class="dropdown">
      # whose <summary> is the visual "+" trigger. The FilePicker JS hook lives
      # on the <details> (click-delegating on the [data-picker-kind] menu
      # items); a <summary> is the native details toggle and carries NO type
      # attribute — type="button" lives on the three menu buttons instead.
      [details] = Floki.find(doc, "details#objective-file-attach")
      assert details |> Floki.attribute("phx-hook") |> List.first() == "FilePicker"
      details_class = details |> Floki.attribute("class") |> List.first() |> to_string()
      assert details_class =~ "dropdown"
      assert details_class =~ "dropdown-top"

      [summary] = Floki.find(doc, "summary#objective-file-button")
      assert summary |> Floki.attribute("aria-label") |> List.first() == "Attach file"
      assert summary |> Floki.attribute("title") |> List.first() == "Attach file"

      # Bottom-toolbar "+" trigger (bottom-LEFT of the row): square ghost
      # button — no absolute top-right floating over the textarea anymore.
      summary_class = summary |> Floki.attribute("class") |> List.first() |> to_string()
      refute summary_class =~ "absolute"
      refute summary_class =~ "top-2"
      assert summary_class =~ "btn-square"

      # "+" icon inside the trigger (the paper-clip was the old top-right design).
      assert html =~ "hero-plus"
      refute html =~ "hero-paper-clip"

      # The dropdown menu holds exactly three pick-kind items, each a plain
      # type="button" carrying NO phx-click (a bare button without type would
      # submit the task form; the FilePicker hook click-delegates on these
      # items itself).
      items = Floki.find(doc, "details#objective-file-attach ul button[data-picker-kind]")
      assert length(items) == 3

      for {"button", attrs, _} <- items do
        assert {"type", "button"} in attrs
        refute List.keyfind(attrs, "phx-click", 0)
      end
    end

    test "attach-kind menu items pair kind → picker id and render their labels" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")
      doc = parse(html)

      items = Floki.find(doc, "details#objective-file-attach ul button[data-picker-kind]")

      assert [
               {"button", text_attrs, _},
               {"button", image_attrs, _},
               {"button", audio_attrs, _}
             ] = items

      # kind → picker id pairing drives the FilePicker hook's per-kind
      # "file_pick" event ids (text = the existing objective_file pipeline;
      # image/audio are staged server-side).
      assert {"data-picker-kind", "text"} in text_attrs
      assert {"data-picker-id", "objective_file"} in text_attrs
      assert {"data-picker-kind", "image"} in image_attrs
      assert {"data-picker-id", "objective_file_image"} in image_attrs
      assert {"data-picker-kind", "audio"} in audio_attrs
      assert {"data-picker-id", "objective_file_audio"} in audio_attrs

      # Menu labels in document order (gettext msgids in the test locale).
      labels = Enum.map(items, fn item -> item |> Floki.text() |> String.trim() end)
      assert labels == ["Text / PDF", "Image", "Audio"]
    end

    test "attach-file dropdown is the first element inside the controls row" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # Placement contract (INVERTED vs the old top-right design): the attach
      # <details class="dropdown"> (id objective-file-attach) now lives INSIDE
      # .input-controls as its FIRST element child (bottom-left of the
      # toolbar), followed by the hidden .file-manual fallback div — both
      # direct children of the toolbar row.
      element_children =
        controls
        |> Floki.children()
        |> Enum.filter(fn
          {tag, _, _} when is_binary(tag) -> true
          _ -> false
        end)

      assert [{"details", first_attrs, _}, {"div", manual_attrs, _} | _] = element_children
      assert {"id", "objective-file-attach"} in first_attrs
      assert {"id", "objective-file-manual"} in manual_attrs

      # The "<summary id=objective-file-button>" "+" trigger is the details'
      # own first child, so the dropdown remains the row's visual lead.
      [summary] = Floki.find(doc, "details#objective-file-attach > summary#objective-file-button")
      assert summary |> Floki.attribute("id") |> List.first() == "objective-file-button"
    end

    test "attach-file dropdown is not rendered in the disabled (no-project) state" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true
        )

      doc = parse(html)

      # With no project open the whole toolbar row is suppressed: neither the
      # old bare button nor the new <details>/<summary> attach control renders,
      # and no staged-attachments chip row can appear either.
      assert Floki.find(doc, "button#objective-file-button") == []
      assert Floki.find(doc, "summary#objective-file-button") == []
      assert Floki.find(doc, "details#objective-file-attach") == []
      assert Floki.find(doc, ".input-controls") == []
      refute html =~ "staged-attachments"
    end

    test "staged attachment chips render metadata only (kind + basename) with remove buttons" do
      attachments = [
        %{
          "type" => "image",
          "name" => "pic.png",
          "media_type" => "image/png",
          "data" => <<1, 2, 3>>
        },
        %{
          "type" => "audio",
          "name" => "clip.mp3",
          "media_type" => "audio/mpeg",
          "data" => <<4, 5>>
        }
      ]

      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          staged_attachments: attachments
        )

      doc = parse(html)
      [chips] = Floki.find(doc, "div#staged-attachments")

      # Metadata only: the kind label + basename of each staged attachment are
      # rendered (scoped to the chips row — the dropdown menu also carries
      # "Image"/"Audio" labels), never the raw "data" binary.
      chips_text = chips |> Floki.text()
      assert chips_text =~ "Image"
      assert chips_text =~ "pic.png"
      assert chips_text =~ "Audio"
      assert chips_text =~ "clip.mp3"

      # Raw byte content of the staged "data" keys must never leak into the
      # rendered HTML (byte-level check — no metadata attribute holds them).
      assert :binary.match(html, <<1, 2, 3>>) == :nomatch
      assert :binary.match(html, <<4, 5>>) == :nomatch
    end

    test "staged attachment remove buttons carry type/aria-label and integer indexes" do
      attachments = [
        %{
          "type" => "image",
          "name" => "pic.png",
          "media_type" => "image/png",
          "data" => <<1, 2, 3>>
        },
        %{
          "type" => "audio",
          "name" => "clip.mp3",
          "media_type" => "audio/mpeg",
          "data" => <<4, 5>>
        }
      ]

      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          staged_attachments: attachments
        )

      doc = parse(html)

      remove_buttons =
        Floki.find(doc, "div#staged-attachments button[phx-click=\"remove_staged_attachment\"]")

      assert length(remove_buttons) == 2

      for {"button", attrs, _} <- remove_buttons do
        assert {"type", "button"} in attrs
        assert {"aria-label", "Remove attachment"} in attrs
      end

      # phx-value-index is the integer chip index in the list (0, 1) — the
      # remove_staged_attachment server event indexes into the staged list.
      indexes =
        Enum.map(remove_buttons, fn btn ->
          btn |> Floki.attribute("phx-value-index") |> List.first()
        end)

      assert indexes == ["0", "1"]
    end

    test "no staged-attachments row renders when the assign is absent" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      # Regression: the component gates on Map.get(assigns, :staged_attachments)
      # so a render without the assign (all existing callers) emits no chips row.
      assert Floki.find(parse(html), "div#staged-attachments") == []
      refute html =~ "staged-attachments"
    end

    test "disabled state hides the chips row even when staged attachments are passed" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "",
          disabled: true,
          staged_attachments: [
            %{
              "type" => "image",
              "name" => "pic.png",
              "media_type" => "image/png",
              "data" => <<1, 2, 3>>
            }
          ]
        )

      assert Floki.find(parse(html), "div#staged-attachments") == []
      refute html =~ "staged-attachments"
      refute html =~ "pic.png"
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
