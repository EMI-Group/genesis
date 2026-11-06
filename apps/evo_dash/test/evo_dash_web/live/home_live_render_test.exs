defmodule EvoDashWeb.HomeLiveRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  # Exercise the real page template without mounting /help: a connected mount
  # writes the global ChatHistory hub and must not run in the async cohort.
  # These fixtures are presentation state only; no task or provider is started.
  defp page(overrides \\ []) do
    assigns = [
      flash: %{},
      current_node: node(),
      current_node_id: nil,
      current_node_name: "Local",
      running_tasks: [],
      pending_tasks: [],
      desktop_quit_confirm: false,
      update_status: nil,
      guide: nil,
      model_profiles: [],
      selected_model_id: nil,
      model_selection_enabled: false,
      source_available: true,
      source_busy: nil,
      transcript: [],
      chat_status: :idle,
      chat_task_status: nil,
      thought_process: [],
      raw_entry_ids: MapSet.new(),
      pending_approvals: [],
      approval_error: nil,
      chat_draft: ""
    ]

    render_component(&EvoDashWeb.HomeLive.render/1, Keyword.merge(assigns, overrides))
    |> Floki.parse_document!()
  end

  defp text(dom, selector), do: dom |> Floki.find(selector) |> Floki.text() |> String.trim()
  defp attr(dom, selector, name), do: dom |> Floki.find(selector) |> Floki.attribute(name)

  test "empty chat offers actionable prompts inside the message scroller, not the composer" do
    dom = page()

    assert text(dom, "h1") == "Genesis Assistant"
    assert text(dom, "#chat-messages h2") == "What would you like Genesis to do?"
    prompts = Floki.find(dom, "#chat-messages button[phx-click='send_message']")
    assert length(prompts) == 4

    for prompt <- prompts do
      assert [message] = Floki.attribute(prompt, "phx-value-message")
      assert String.trim(Floki.text(prompt)) == message
      assert message != ""
    end

    assert Floki.find(dom, "#chat-messages #chat-form") == []
    assert attr(dom, "#chat-messages", "phx-hook") == ["AgentHistoryAutoScroll"]
    assert text(dom, "#chat-form button[type='submit']") == "Send"
    assert Floki.text(dom) =~ "Genesis Assistant can make mistakes. Verify important information."
  end

  test "idle composer preserves the draft and exposes keyboard and accessible send controls" do
    dom = page(chat_draft: "Explain <this> & that")

    assert attr(dom, "#chat-form", "phx-submit") == ["send_message"]
    assert attr(dom, "#chat-form", "phx-change") == ["chat_input"]
    assert attr(dom, "#chat-form textarea", "value") == ["Explain <this> & that"]
    assert attr(dom, "#chat-form textarea", "name") == ["message"]
    assert attr(dom, "#chat-form textarea", "aria-label") == ["Message Genesis Assistant…"]
    assert attr(dom, "#chat-form textarea", "placeholder") == ["Message Genesis Assistant…"]
    assert attr(dom, "#chat-form textarea", "phx-keydown") == ["chat_keydown"]
    assert attr(dom, "#chat-form textarea", "phx-keyup") == ["chat_keyup"]

    assert Floki.find(
             dom,
             "#chat-form textarea[disabled], #chat-form button[type='submit'][disabled]"
           ) == []

    assert Floki.find(dom, "#chat-form button[phx-click='stop'][disabled].hidden") != []
    assert Floki.text(dom) =~ "Enter to send · Shift+Enter for a new line"
  end

  test "running chat replaces send with an accessible stop control and locks competing actions" do
    dom = page(chat_status: :running)

    assert Floki.find(dom, "#chat-form textarea[disabled]") != []
    assert Floki.find(dom, "#chat-form button[type='submit'][disabled].hidden") != []
    assert text(dom, "#chat-form button[phx-click='stop']") == "Stop"
    assert Floki.find(dom, "#chat-form button[phx-click='stop'][disabled]") == []
    assert Floki.find(dom, "#chat-form button[phx-click='stop'].hidden") == []
    assert Floki.find(dom, "button[phx-click='new_chat'][disabled]") != []
    refute Floki.text(dom) =~ "Genesis Assistant can make mistakes. Verify important information."
  end

  test "a restored conversation replaces the greeting and prompts while keeping the composer available" do
    dom = page(transcript: [%{id: "user-1", role: :user, text: "Explain the scheduler"}])

    assert text(dom, "#chat-messages") =~ "Explain the scheduler"
    assert Floki.find(dom, "#chat-messages h2") == []
    assert Floki.find(dom, "#chat-messages button[phx-click='send_message']") == []
    assert Floki.find(dom, "#chat-form textarea[disabled]") == []
    assert text(dom, "#chat-form button[type='submit']") == "Send"
    assert Floki.text(dom) =~ "Enter to send · Shift+Enter for a new line"
    refute Floki.text(dom) =~ "Genesis Assistant can make mistakes. Verify important information."
  end

  test "known missing local source replaces suggestion actions with guidance and disables send" do
    dom = page(source_available: false)

    assert text(dom, "#chat-messages") =~ "Download the Genesis source to start chatting."
    assert Floki.find(dom, "#chat-messages button[phx-click='send_message']") == []
    assert Floki.find(dom, "button[phx-click='download_source']") != []
    assert Floki.find(dom, "#chat-form textarea[disabled]") != []
    assert Floki.find(dom, "#chat-form button[type='submit'][disabled]") != []
    # Downloading the source does not prevent starting a fresh conversation.
    assert Floki.find(dom, "button[phx-click='new_chat'][disabled]") == []
  end

  test "unknown availability and remote viewing do not falsely block the composer" do
    for overrides <- [
          [source_available: nil],
          [source_available: false, current_node: :remote@host]
        ] do
      dom = page(overrides)

      assert length(Floki.find(dom, "#chat-messages button[phx-click='send_message']")) == 4
      assert Floki.find(dom, "button[phx-click='download_source']") == []

      assert Floki.find(
               dom,
               "#chat-form textarea[disabled], #chat-form button[type='submit'][disabled]"
             ) == []
    end
  end
end
