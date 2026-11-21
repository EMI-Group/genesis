defmodule EvoDashWeb.HomeLive.BrowserUploadTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias EvoDashWeb.HomeLive.Attachments

  # `await_uploads_empty/1` polls an OFF-PROCESS upload/drain cycle and
  # `assigns/1` is a `:sys.get_state` round trip; their old fixed budgets
  # (100 × 5 ms, the 5 s default) expire on a shared host whose scheduling
  # swings 10-30x (test/CONTEXT.md).
  @async_wait_budget_ms 30_000
  @wait_poll_ms 2

  setup do
    EvoDash.Test.ConfigDir.isolate!("browser_upload")
    EvoGit.Config.VersionState.complete_onboarding()
    EvoDash.ChatHistory.reset()
    :ok
  end

  test "the browser chooser is unified and outside the message form", %{conn: conn} do
    {:ok, view, html} = live(conn, "/assistant")

    assert has_element?(
             view,
             "#chat-upload-form input[type=file][multiple][data-phx-auto-upload]"
           )

    assert has_element?(view, "#chat-server-attachment #chat-attach-manual-form")
    assert html =~ "Upload files from this computer"
    assert html =~ "Add from Genesis server path"
    refute has_element?(view, "#chat-form form")
    refute has_element?(view, "[phx-click=chat_attach]")
  end

  test "real browser uploads classify text, PNG and audio and encode media exactly once", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/assistant")
    raw_image = <<137, 80, 78, 71, 0, 255, 11>>
    raw_audio = <<"RIFF", 0, 255, "WAVE">>

    upload =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{name: "notes.txt", content: "Browser notes", type: "text/plain"},
        %{name: "diagram.png", content: raw_image, type: "image/png"},
        %{name: "voice.wav", content: raw_audio, type: "audio/wav"}
      ])

    view |> form("#chat-upload-form") |> render_change(upload)
    for name <- ["notes.txt", "diagram.png", "voice.wav"], do: render_upload(upload, name)
    pending = assigns(view).pending_attachments
    assert Attachments.count(pending) == 3
    assert Enum.map(pending.entries, & &1.kind) == ["text", "image", "audio"]
    assert Enum.map(pending.entries, & &1.name) == ["notes.txt", "diagram.png", "voice.wav"]
    {message, [image, audio]} = Attachments.to_message("Read these", pending)
    assert message =~ "## Attached file: notes.txt"
    assert message =~ "Browser notes"
    assert Base.decode64!(image["data"]) == raw_image
    assert Base.decode64!(audio["data"]) == raw_audio
    assert assigns(view).upload_in_progress == false
    assert assigns(view).uploads.chat_files.entries == []
    refute render(view) =~ Base.encode64(raw_image)
  end

  test "upload progress blocks sending and can be cancelled without staging bytes", %{conn: conn} do
    {:ok, view, _} = live(conn, "/assistant")

    upload =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{name: "partial.txt", content: String.duplicate("upload ", 2000), type: "text/plain"}
      ])

    view |> form("#chat-upload-form") |> render_change(upload)
    render_upload(upload, "partial.txt", 20)
    assert assigns(view).upload_in_progress
    assert has_element?(view, "#chat-upload-progress")
    assert Attachments.count(assigns(view).pending_attachments) == 0
    entry = hd(assigns(view).uploads.chat_files.entries)
    render_click(view, "chat_upload_cancel", %{"ref" => entry.ref})
    refute assigns(view).upload_in_progress
    await_uploads_empty(view)
    assert Attachments.count(assigns(view).pending_attachments) == 0
  end

  test "unsupported and over-limit files fail visibly and leave a retryable chooser", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/assistant")

    upload =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{name: "program.exe", content: "not an attachment", type: "application/octet-stream"}
      ])

    view |> form("#chat-upload-form") |> render_change(upload)
    assert has_element?(view, "#chat-upload-error")
    assert Attachments.count(assigns(view).pending_attachments) == 0
    refute assigns(view).upload_in_progress
    render_click(view, "chat_upload_clear_error")
    refute has_element?(view, "#chat-upload-error")

    too_big =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{
          name: "huge.txt",
          content: :binary.copy("x", Attachments.max_attachment_bytes() + 1),
          type: "text/plain"
        }
      ])

    view |> form("#chat-upload-form") |> render_change(too_big)
    assert has_element?(view, "#chat-upload-error")
    refute assigns(view).upload_in_progress
    assert assigns(view).uploads.chat_files.entries == []
  end

  test "new conversation cancels a partial browser upload", %{conn: conn} do
    {:ok, view, _} = live(conn, "/assistant")
    original = assigns(view).chat_id

    upload =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{
          name: "old-conversation.txt",
          content: String.duplicate("private ", 2000),
          type: "text/plain"
        }
      ])

    view |> form("#chat-upload-form") |> render_change(upload)
    render_upload(upload, "old-conversation.txt", 20)
    assert assigns(view).upload_in_progress
    render_click(view, "new_chat")
    assert assigns(view).chat_id != original
    refute assigns(view).upload_in_progress
    await_uploads_empty(view)
    assert Attachments.count(assigns(view).pending_attachments) == 0
  end

  test "the combined staged and uploading limit is four files", %{conn: conn} do
    {:ok, view, _} = live(conn, "/assistant")

    for index <- 1..4 do
      name = "notes-#{index}.txt"

      upload =
        file_input(view, "#chat-upload-form", :chat_files, [
          %{name: name, type: "text/plain", content: "notes"}
        ])

      view |> form("#chat-upload-form") |> render_change(upload)
      render_upload(upload, name)
    end

    assert Attachments.count(assigns(view).pending_attachments) == 4

    extra =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{name: "extra.txt", type: "text/plain", content: "extra"}
      ])

    view |> form("#chat-upload-form") |> render_change(extra)
    assert has_element?(view, "#chat-upload-error")
    assert Attachments.count(assigns(view).pending_attachments) == 4
    refute assigns(view).upload_in_progress
  end

  test "late completion from another node scope cannot stage in the new conversation", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/assistant")

    upload =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{name: "scoped.txt", type: "text/plain", content: String.duplicate("scope ", 2000)}
      ])

    view |> form("#chat-upload-form") |> render_change(upload)
    render_upload(upload, "scoped.txt", 20)

    :sys.replace_state(view.pid, fn state ->
      %{state | socket: Phoenix.Component.assign(state.socket, current_node: :other_upload@host)}
    end)

    render_upload(upload, "scoped.txt", 80)
    assert Attachments.count(assigns(view).pending_attachments) == 0
    refute assigns(view).upload_in_progress
  end

  test "browser uploads stage on the dashboard for a remote selection but server paths do not fallback",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/assistant")

    :sys.replace_state(view.pid, fn state ->
      %{state | socket: Phoenix.Component.assign(state.socket, current_node: :upload_remote@host)}
    end)

    upload =
      file_input(view, "#chat-upload-form", :chat_files, [
        %{name: "remote-notes.txt", type: "text/plain", content: "browser bytes"}
      ])

    view |> form("#chat-upload-form") |> render_change(upload)
    render_upload(upload, "remote-notes.txt")
    assert Attachments.count(assigns(view).pending_attachments) == 1
    render_submit(view, "chat_attach_manual", %{"path" => "/etc/hosts"})
    assert assigns(view).flash["error"] =~ "unavailable on the selected node"
    assert Attachments.count(assigns(view).pending_attachments) == 1
  end

  @tag :tmp_dir
  test "a pending remote selection cannot read an allowed file from the dashboard", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "local-notes.txt")
    File.write!(path, "DASHBOARD_LOCAL_FILE_SENTINEL")
    {:ok, view, _} = live(conn, "/assistant")

    :sys.replace_state(view.pid, fn state ->
      %{
        state
        | socket:
            Phoenix.Component.assign(state.socket,
              current_node: node(),
              current_node_id: "pending-remote-upload",
              remote_status: :connecting
            )
      }
    end)

    render_submit(view, "chat_attach_manual", %{"path" => path})
    assert Attachments.count(assigns(view).pending_attachments) == 0
    assert assigns(view).flash["error"] =~ "unavailable on the selected node"
    refute render(view) =~ "DASHBOARD_LOCAL_FILE_SENTINEL"
  end

  defp await_uploads_empty(view, budget_ms \\ @async_wait_budget_ms) do
    do_await_uploads_empty(view, System.monotonic_time(:millisecond) + budget_ms, budget_ms)
  end

  defp do_await_uploads_empty(view, deadline, budget_ms) do
    cond do
      assigns(view).uploads.chat_files.entries == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("pending uploads did not drain within #{budget_ms}ms")

      true ->
        # 2 ms cadence: the deadline, not the cadence, is the safety margin.
        Process.sleep(@wait_poll_ms)
        do_await_uploads_empty(view, deadline, budget_ms)
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid, @async_wait_budget_ms).socket.assigns
end
