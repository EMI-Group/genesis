defmodule EvoDashWeb.HomeLive.ComposerRenderTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.HomeLive.Composer

  defp render_composer(overrides) do
    assigns =
      Map.merge(%{chat_status: :idle, model_snapshot: %{}, chat_draft: "a draft"}, overrides)

    render_component(&Composer.composer/1, assigns) |> LazyHTML.from_fragment()
  end

  test "empty and whitespace-only drafts keep sending disabled while typed text enables it" do
    for text <- ["", "  ", "\n\t  "] do
      html = render_composer(%{chat_draft: text})

      assert Enum.count(LazyHTML.query(html, "button[form=chat-form][type=submit][disabled]")) ==
               1

      assert Enum.count(LazyHTML.query(html, "#chat-message-input[disabled]")) == 0
    end

    html = render_composer(%{chat_draft: "  A message  "})

    assert Enum.count(LazyHTML.query(html, "button[form=chat-form][type=submit]:not([disabled])")) ==
             1
  end

  test "completed binary attachment alone enables sending but upload progress blocks it" do
    pending = %{
      text: "",
      entries: [
        %{
          kind: "image",
          name: "diagram.png",
          block: nil,
          media_type: "image/png",
          data: <<137, 80, 78, 71>>
        }
      ]
    }

    html = render_composer(%{chat_draft: "", pending_attachments: pending})

    assert Enum.count(LazyHTML.query(html, "button[form=chat-form][type=submit]:not([disabled])")) ==
             1

    assert Enum.count(LazyHTML.query(html, "#chat-attachment-chips")) == 1

    for content <- [%{chat_draft: "A message"}, %{chat_draft: "", pending_attachments: pending}] do
      html = render_composer(Map.put(content, :upload_in_progress, true))

      assert Enum.count(LazyHTML.query(html, "button[form=chat-form][type=submit][disabled]")) ==
               1

      assert Enum.count(LazyHTML.query(html, "#chat-message-input[disabled]")) == 0
    end
  end

  test "message form has a bounded textarea and external controls without nested forms" do
    html = render_composer(%{attach_unavailable: true, workspace_open: true})

    assert Enum.count(
             LazyHTML.query(html, "#chat-form.assistant-message-form textarea[rows='3']")
           ) == 1

    assert Enum.count(LazyHTML.query(html, "form form")) == 0

    assert Enum.count(
             LazyHTML.query(html, "#chat-composer-controls button[type=submit][form=chat-form]")
           ) == 1

    assert Enum.count(LazyHTML.query(html, "#chat-composer-controls #workspace-form")) == 1

    assert Enum.count(LazyHTML.query(html, "#chat-composer-controls #chat-attach-manual-form")) ==
             1

    assert Enum.count(LazyHTML.query(html, "#chat-composer-controls #chat-llm-selection")) == 1
    assert Enum.count(LazyHTML.query(html, "#chat-keyboard-hint.sr-only")) == 1
  end

  test "attachments live behind the plus disclosure and disabled states guard every action" do
    html = render_composer(%{chat_status: :ended})

    assert Enum.count(
             LazyHTML.query(
               html,
               "details#chat-attach-menu > summary#chat-attach-button[aria-disabled=true]"
             )
           ) == 1

    assert Enum.count(LazyHTML.query(html, "#chat-attach-menu button[disabled]")) >= 1
    assert Enum.count(LazyHTML.query(html, "#chat-server-attachment input[disabled]")) == 1
    assert Enum.count(LazyHTML.query(html, "[phx-click=chat_attach]")) == 0
    assert LazyHTML.text(html) =~ "Upload files from this computer"
    assert LazyHTML.text(html) =~ "Add from Genesis server path"
  end

  test "project menu closes on Escape and click-away and restores focus" do
    html = render_composer(%{workspace_open: true, workspace_error: "Directory unavailable"})
    [panel] = LazyHTML.query(html, "#workspace-panel[role=dialog]") |> Enum.to_list()
    attributes = LazyHTML.attributes(panel) |> List.first() |> Map.new()
    assert attributes["phx-key"] == "Escape"
    # Click-away and Escape push the IDEMPOTENT close, never the toggle: the
    # panel now stays MOUNTED for its exit, so a keydown anywhere on the page
    # would otherwise OPEN a closed picker.
    for attribute <- ["phx-window-keydown", "phx-click-away"] do
      assert attributes[attribute] =~ ~s("event":"workspace_close")
      # …and the toggle is never pushed by either of them (the focus target
      # `#workspace-toggle` is a different thing than a pushed event).
      refute attributes[attribute] =~ ~s("event":"workspace_toggle")
    end

    assert Enum.count(LazyHTML.query(html, "#workspace-error[role=alert]")) == 1
  end

  test "the upload progress and error chips own a deferred removal fade" do
    # Each chip's `:if` sits ON the chip, so the patch discards that node and
    # LiveView runs its own `phx-remove`: the last upload finishing (or the user
    # dismissing the error) fades the overlay out instead of popping it.
    entry = %Phoenix.LiveView.UploadEntry{ref: "0", client_name: "a.png", progress: 42}

    upload = %Phoenix.LiveView.UploadConfig{
      name: :chat_files,
      ref: "0",
      accept: :any,
      entries: [entry]
    }

    dom =
      render_component(&Composer.attach_menu/1,
        uploads: %{chat_files: upload},
        upload_error: "boom"
      )
      |> Floki.parse_document!()

    for id <- ["#chat-upload-progress", "#chat-upload-error"] do
      assert [js] = dom |> Floki.find(id) |> Floki.attribute("phx-remove")
      assert js =~ "motion-exit-fade"
      assert js =~ "motion-exit-visible"
    end
  end

  test "the chip row, the interrupt button and the followed-tasks strip fade out" do
    # Each puts its `:if` ON the node a patch removes and had no entrance
    # motion, so the shared motion.css section-6 `phx-remove` recipe owns its
    # exit instead of a one-frame pop.
    chips =
      render_component(&Composer.composer/1,
        chat_status: :running,
        pending_attachments: %{
          text: "",
          entries: [
            %{kind: "image", name: "a.png", block: nil, media_type: "image/png", data: <<1>>}
          ]
        }
      )
      |> Floki.parse_document!()

    interrupt =
      render_component(&Composer.interrupt_button/1, chat_status: :running)
      |> Floki.parse_document!()

    tracking =
      render_component(&EvoDashWeb.HomeLive.TaskCard.cards/1,
        tracked_tasks: [
          %{
            id: "t1",
            title: "Task",
            status: "running",
            path: "/repo",
            agent_count: 1,
            updated_at: "now",
            error: nil,
            has_result: false
          }
        ],
        task_tracking_error: nil,
        current_node_id: nil,
        task_action_pending: MapSet.new()
      )
      |> Floki.parse_document!()

    for {id, dom} <- [
          {"#chat-attachment-chips", chips},
          {"#chat-interrupt-button", interrupt},
          {"#assistant-task-tracking", tracking}
        ] do
      assert [js] = dom |> Floki.find(id) |> Floki.attribute("phx-remove")
      assert js =~ "motion-exit-fade"
      assert js =~ "motion-exit-visible"
    end
  end

  test "the project menu stays mounted and states its open/closed intent" do
    # The MotionPanel hook owns `data-motion-state` + `hidden`; the server owns
    # only the intent. An OPEN panel carries no `hidden`, a CLOSED one keeps the
    # same node with `hidden` — presence of `#workspace-panel` no longer means
    # "open".
    open = render_composer(%{workspace_open: true})
    [panel] = LazyHTML.query(open, "#workspace-panel[role=dialog]") |> Enum.to_list()
    open_attrs = LazyHTML.attributes(panel) |> List.first() |> Map.new()
    assert open_attrs["data-motion-want"] == "true"
    assert open_attrs["phx-hook"] == "MotionPanel"
    assert open_attrs["class"] =~ "motion-panel"
    refute Map.has_key?(open_attrs, "hidden")

    closed = render_composer(%{workspace_open: false})
    assert Enum.count(LazyHTML.query(closed, "#workspace-panel[role=dialog]")) == 1
    [panel] = LazyHTML.query(closed, "#workspace-panel[role=dialog]") |> Enum.to_list()
    closed_attrs = LazyHTML.attributes(panel) |> List.first() |> Map.new()
    assert closed_attrs["data-motion-want"] == "false"
    assert closed_attrs["phx-hook"] == "MotionPanel"
    assert Map.has_key?(closed_attrs, "hidden")
    # Focus on open is DECLARATIVE: the `MotionPanel` writer focuses the
    # `[data-motion-focus]` marker once the panel settled open. `phx-mounted`
    # could only ever fire at mount (where the panel is still hidden), so a
    # later open never focused anything.
    refute Map.has_key?(open_attrs, "phx-mounted")
    focus = ~s(#workspace-recent[tabindex="-1"][data-motion-focus])
    assert Enum.count(LazyHTML.query(open, focus)) == 1
    assert Enum.empty?(LazyHTML.query(open, "#workspace-path[data-motion-focus]"))
    # The toggle keeps its expanded/controls contract pointing at that node.
    assert Enum.count(
             LazyHTML.query(
               closed,
               "#workspace-toggle[aria-expanded=false][aria-controls=workspace-panel]"
             )
           ) == 1
  end
end
