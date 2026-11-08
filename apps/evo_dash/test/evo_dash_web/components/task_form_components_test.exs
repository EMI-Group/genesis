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
  # order are attach "+" (bottom-left) → mode+speed capsule (left) → free
  # space → a RIGHT-ALIGNED cluster: (custom-agent select) → model capsule /
  # legacy model select → circular icon-only send button (the cluster's LAST
  # element = the row's far right, with NO auto margin of its own). The row's
  # auto margin (ml-auto) lives on the FIRST element of the right cluster —
  # the model capsule's ml-auto, else the custom-agent select's ml-auto, else
  # the legacy model select's ml-auto. Only the textarea size differs per
  # layout, so the tests assert the unified classes via Floki.
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

    test "Layout A (compact): compact controls + right-aligned cluster (legacy model select ml-auto)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      # Compact controls: the legacy model select is select-sm scale (no
      # select-md) and the send button is a small filled circle at the row's
      # far right. The right-aligned cluster [model | send] is packed right by
      # the legacy model select's ml-auto — the launch button carries NO auto
      # margin (no order-* / mx-auto centering trick anywhere).
      assert model_class(html) =~ "select-sm"
      refute model_class(html) =~ "select-md"
      assert button_class(html) =~ "btn-circle"
      assert button_class(html) =~ "btn-sm"
      assert model_class(html) =~ "ml-auto"
      refute button_class(html) =~ "ml-auto"
      refute model_class(html) =~ "order-"
      refute model_class(html) =~ "mx-auto"
      refute button_class(html) =~ "order-"
      refute button_class(html) =~ "mx-auto"
    end

    test "toolbar DOM order is attach dropdown | mode+speed capsule | model | send (pins real order)" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: "Short",
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      # Interactive controls in document order: the attach-kind dropdown's "+"
      # <summary> trigger first (bottom-left — inside the wrapping
      # <details#objective-file-attach>), then the fused mode+speed capsule,
      # then the legacy model select, then the circular send button LAST
      # (rightmost member of the right-aligned cluster). The hidden
      # .file-manual fallback div is a sibling in the same row but is not an
      # interactive control.
      found =
        Floki.find(
          controls,
          "summary#objective-file-button, details#mode-speed-capsule, select[name=model_id], button#task-launch-button"
        )

      assert [
               {"summary", attach_attrs, _},
               {"details", capsule_attrs, _},
               {"select", model_attrs, _},
               {"button", launch_attrs, _}
             ] = found

      assert {"id", "objective-file-button"} in attach_attrs

      # The summary is the visual trigger of the attach-kind <details
      # class="dropdown"> — the FilePicker hook lives on that wrapping element.
      [details] = Floki.find(controls, "details#objective-file-attach")
      details_class = details |> Floki.attribute("class") |> List.first() |> to_string()
      assert details_class =~ "dropdown"

      # The fused mode+speed capsule is the direct sibling after the attach
      # dropdown (its hidden .file-manual sibling takes no flex space).
      assert {"id", "mode-speed-capsule"} in capsule_attrs
      assert {"class", capsule_class} = List.keyfind(capsule_attrs, "class", 0)
      assert capsule_class =~ "capsule"
      assert capsule_class =~ "min-w-0"
      assert capsule_class =~ "shrink-0"

      assert {"name", "model_id"} in model_attrs
      assert {"id", "task-launch-button"} in launch_attrs
      assert {"type", "submit"} in launch_attrs

      # Free-space placement: the row's auto margin lives on the legacy model
      # select (ml-auto — the cluster lead), NOT on the launch button, so the
      # free space sits before the cluster [model | send] rather than between
      # model and launch.
      assert model_class(html) =~ "ml-auto"
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

    test "Layout B (expanded): identical toolbar — right-aligned cluster: legacy model select ml-auto, send button last" do
      html =
        render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
          prompt: String.duplicate("a", 1300),
          model_profiles: [%{id: "pro", model: "gpt-x"}]
        )

      assert html =~ ~s(data-layout="expanded")

      # The bottom toolbar is identical in both layouts (only the textarea
      # size differs): compact legacy model select in a right-aligned cluster —
      # the model select carries the row's ml-auto (cluster lead), the circular
      # send button is the cluster's last element with no auto margin.
      assert model_class(html) =~ "select-sm"
      assert button_class(html) =~ "btn-circle"
      assert model_class(html) =~ "ml-auto"
      refute button_class(html) =~ "ml-auto"
      refute model_class(html) =~ "mx-auto"
      refute button_class(html) =~ "mx-auto"
    end

    test "toolbar holds without a model select: launch button stays last and carries no auto margin" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      # No model select is rendered when no legacy model profiles exist. The
      # fused mode+speed capsule sits on the LEFT (after the attach dropdown),
      # and the circular send button is still the row's LAST interactive
      # control with no auto margin of its own.
      assert button_class(html) =~ "btn-circle"
      refute button_class(html) =~ "ml-auto"
      refute html =~ ~s(name="model_id")

      doc = parse(html)
      [controls] = Floki.find(doc, ".input-controls")

      found =
        Floki.find(
          controls,
          "summary#objective-file-button, details#mode-speed-capsule, button#task-launch-button"
        )

      assert [
               {"summary", attach_attrs, _},
               {"details", capsule_attrs, _},
               {"button", launch_attrs, _}
             ] = found

      assert {"id", "objective-file-button"} in attach_attrs
      assert {"id", "mode-speed-capsule"} in capsule_attrs
      assert {"id", "task-launch-button"} in launch_attrs
      assert {"type", "submit"} in launch_attrs
    end

    test "disabled state renders the welcome overlay and suppresses every task-launch placeholder" do
      # Regression: with no project open (@disabled) the mode-dependent
      # task-launch hint is an empty placeholder — the centered welcome overlay
      # is the only hint. Covers the genesis_new default branch AND the
      # evolve-family branch (the reported leak).
      for mode <- [nil, "evolve_simple"] do
        html =
          render_component(&EvoDashWeb.TaskFormComponents.task_form/1,
            prompt: "",
            disabled: true,
            mode: mode
          )

        refute html =~ ~s(placeholder="Describe what you want to change or improve...")

        refute html =~ ~s(placeholder="Describe the codebase you want to create...")

        refute html =~
                 ~s(placeholder="Optional — leave empty and click Launch to initialize an existing codebase")

        assert html =~ "Open a project to get started"
      end
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

      # The fused capsule and the legacy model select shrink/truncate instead
      # of forcing the row wider: the capsule carries min-w-0 + shrink-0 on its
      # <details>, with the truncating main label inside, and the legacy model
      # select carries min-w-0 + truncate directly.
      [capsule] = Floki.find(doc, "details#mode-speed-capsule")
      capsule_class = capsule |> Floki.attribute("class") |> List.first() |> to_string()
      assert capsule_class =~ "min-w-0"
      assert capsule_class =~ "shrink-0"

      [main] = Floki.find(doc, "#mode-speed-capsule .capsule-main")
      main_class = main |> Floki.attribute("class") |> List.first() |> to_string()
      assert main_class =~ "min-w-0"
      assert main_class =~ "truncate"

      assert model_class(html) =~ "min-w-0"
      assert model_class(html) =~ "truncate"
    end

    test "mode capsule keeps its four options, order and task_change event" do
      html = render_component(&EvoDashWeb.TaskFormComponents.task_form/1, prompt: "")

      doc = parse(html)
      options = Floki.find(doc, "#mode-speed-capsule .capsule-list button")
      assert length(options) == 4

      assert [
               {"button", existing_attrs, _},
               {"button", new_attrs, _},
               {"button", evolve_attrs, _},
               {"button", custom_attrs, _}
             ] = options

      # Same values and order as the removed mode select, now carried as
      # phx-value-mode on type=button items that fire task_change.
      assert {"id", "mode-option-genesis_existing"} in existing_attrs
      assert {"phx-click", "task_change"} in existing_attrs
      assert {"phx-value-mode", "genesis_existing"} in existing_attrs

      assert {"id", "mode-option-genesis_new"} in new_attrs
      assert {"phx-click", "task_change"} in new_attrs
      assert {"phx-value-mode", "genesis_new"} in new_attrs

      assert {"id", "mode-option-evolve_simple"} in evolve_attrs
      assert {"phx-click", "task_change"} in evolve_attrs
      assert {"phx-value-mode", "evolve_simple"} in evolve_attrs

      assert {"id", "mode-option-custom_agent"} in custom_attrs
      assert {"phx-click", "task_change"} in custom_attrs
      assert {"phx-value-mode", "custom_agent"} in custom_attrs

      labels = Enum.map(options, fn option -> option |> Floki.text() |> String.trim() end)

      assert labels == [
               "Initialize existing project",
               "Create new project",
               "Evolve existing project",
               "Custom Agent"
             ]

      # The Self-Reflective (reflect) mode was removed with the Home chat page.
      refute html =~ "Self-Reflective"
      refute html =~ ~s(phx-value-mode="reflect")
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

  # Speed ↔ quality segmented control — the fused mode+speed capsule's Layer-1
  # hero (.capsule-stops, role="group") in #mode-speed-capsule. The capsule
  # sits on the toolbar LEFT, right after the attach "+" dropdown. It holds
  # three type="button" steps (NEVER submit — they live inside <form
  # id="task-form">), each firing phx-click="select_quality_level" with its
  # phx-value-level. ONLY the step whose level equals the component attr
  # @quality_level (default "balanced") carries capsule-stop-active and
  # aria-pressed="true"; the other two have aria-pressed="false".
  describe "speed ↔ quality segmented control" do
    test "control group is the fused capsule between the attach dropdown and the launch button" do
      html = render_component(&TaskFormComponents.task_form/1, prompt: "")

      doc = parse(html)
      [capsule] = Floki.find(doc, "details#mode-speed-capsule")
      capsule_class = capsule |> Floki.attribute("class") |> List.first() |> to_string()

      assert capsule_class =~ "capsule"
      assert capsule_class =~ "min-w-0"
      assert capsule_class =~ "shrink-0"

      # Layer 1 is the speed/quality hero group (role="group").
      [stops] = Floki.find(doc, "#mode-speed-capsule .capsule-stops")
      assert stops |> Floki.attribute("role") |> List.first() == "group"

      # Placement contract: a DIRECT child of .input-controls, AFTER the
      # attach-kind dropdown (and its hidden .file-manual sibling) and BEFORE
      # the circular send button — the capsule stays bottom-LEFT, left of the
      # right-aligned cluster.
      [controls] = Floki.find(doc, ".input-controls")

      found =
        Floki.find(
          controls,
          "details#objective-file-attach, details#mode-speed-capsule, button#task-launch-button"
        )

      assert [
               {"details", attach_attrs, _},
               {"details", capsule_attrs, _},
               {"button", launch_attrs, _}
             ] = found

      assert {"id", "objective-file-attach"} in attach_attrs
      assert {"id", "mode-speed-capsule"} in capsule_attrs
      assert {"id", "task-launch-button"} in launch_attrs
    end

    test "renders exactly three steps with the contract ids, levels and labels" do
      html = render_component(&TaskFormComponents.task_form/1, prompt: "")

      doc = parse(html)
      steps = Floki.find(doc, "#mode-speed-capsule .capsule-stops button")
      assert length(steps) == 3

      assert [
               {"button", fast_attrs, _},
               {"button", balanced_attrs, _},
               {"button", high_attrs, _}
             ] = steps

      # Each step pairs its id with the select_quality_level event + level.
      assert {"id", "quality-level-fast"} in fast_attrs
      assert {"phx-click", "select_quality_level"} in fast_attrs
      assert {"phx-value-level", "fast"} in fast_attrs

      assert {"id", "quality-level-balanced"} in balanced_attrs
      assert {"phx-click", "select_quality_level"} in balanced_attrs
      assert {"phx-value-level", "balanced"} in balanced_attrs

      assert {"id", "quality-level-high_quality"} in high_attrs
      assert {"phx-click", "select_quality_level"} in high_attrs
      assert {"phx-value-level", "high_quality"} in high_attrs

      # Labels render inside each step (the leading hero-* icon carries no text).
      assert quality_text(html, "fast") == "Fast"
      assert quality_text(html, "balanced") == "Balanced"
      assert quality_text(html, "high_quality") == "High quality"
    end

    test "default (balanced) highlights the balanced step only" do
      html = render_component(&TaskFormComponents.task_form/1, prompt: "")

      assert quality_class(html, "balanced") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium capsule-stop-active"

      assert quality_attr(html, "balanced", "aria-pressed") == "true"

      assert quality_class(html, "fast") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium"

      assert quality_attr(html, "fast", "aria-pressed") == "false"

      assert quality_class(html, "high_quality") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium"

      assert quality_attr(html, "high_quality", "aria-pressed") == "false"
    end

    test "quality_level: fast moves the active highlight to the fast step" do
      html =
        render_component(&TaskFormComponents.task_form/1, prompt: "", quality_level: "fast")

      assert quality_class(html, "fast") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium capsule-stop-active"

      assert quality_attr(html, "fast", "aria-pressed") == "true"

      assert quality_class(html, "balanced") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium"

      assert quality_attr(html, "balanced", "aria-pressed") == "false"

      assert quality_class(html, "high_quality") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium"
    end

    test "quality_level: high_quality moves the active highlight to the high-quality step" do
      html =
        render_component(&TaskFormComponents.task_form/1,
          prompt: "",
          quality_level: "high_quality"
        )

      assert quality_class(html, "high_quality") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium capsule-stop-active"

      assert quality_attr(html, "high_quality", "aria-pressed") == "true"

      assert quality_class(html, "fast") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium"

      assert quality_class(html, "balanced") ==
               "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium"
    end

    test "every step is type=button (never submits the enclosing task form)" do
      html = render_component(&TaskFormComponents.task_form/1, prompt: "")

      for level <- ["fast", "balanced", "high_quality"] do
        assert quality_attr(html, level, "type") == "button"
      end
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

  # --- speed ↔ quality helpers ---

  # The step button for one segment of the fused capsule's speed ↔ quality
  # hero (ids are quality-level-fast / -balanced / -high_quality).
  defp quality_step(html, level) do
    [btn] = Floki.find(parse(html), "button#quality-level-#{level}")
    btn
  end

  defp quality_class(html, level) do
    quality_step(html, level)
    |> Floki.attribute("class")
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp quality_attr(html, level, attr) do
    quality_step(html, level) |> Floki.attribute(attr) |> List.first() |> to_string()
  end

  defp quality_text(html, level) do
    quality_step(html, level) |> Floki.text() |> String.trim()
  end

  # Floki 0.38's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
