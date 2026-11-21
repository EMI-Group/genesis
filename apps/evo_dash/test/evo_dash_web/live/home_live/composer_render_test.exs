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
    assert attributes["phx-window-keydown"] =~ "workspace-toggle"
    assert attributes["phx-click-away"] =~ "workspace-toggle"
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
end
