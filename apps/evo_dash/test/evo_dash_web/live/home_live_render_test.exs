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
      provider_profiles: [],
      model_selections: [],
      model_spec: %{},
      model_snapshot: %{node: node(), config: %{}},
      model_select_loading: false,
      model_select_load_error: nil,
      model_selection_error: nil,
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

  test "header renders the shared picker and rule-controlled Auto label" do
    profiles = [%{"id" => "work-account", "name" => "Work", "provider" => "openai"}]

    selections = [
      %{
        provider_profile_id: "work-account",
        model: "reasoned-model",
        reasoning_efforts: ["low", "high"],
        default_reasoning_effort: "low"
      }
    ]

    spec = %{
      "provider_profile_id" => "work-account",
      "model" => "reasoned-model",
      "reasoning_effort" => "high"
    }

    dom =
      page(
        provider_profiles: profiles,
        model_selections: selections,
        model_spec: spec,
        model_selection_enabled: true
      )

    assert attr(dom, "#chat-llm-selection-provider", "phx-change") == ["select_provider_profile"]
    assert attr(dom, "#chat-llm-selection-model", "phx-change") == ["select_model"]
    assert attr(dom, "#chat-llm-selection-reasoning", "phx-change") == ["select_reasoning_effort"]
    assert attr(dom, "#chat-llm-selection-provider option[selected]", "value") == ["work-account"]
    assert attr(dom, "#chat-llm-selection-model option[selected]", "value") == ["reasoned-model"]
    assert attr(dom, "#chat-llm-selection-reasoning", "value") == ["1"]
    assert text(dom, "#chat-llm-selection-provider option[value='']") == "Auto (by rules)"
    assert Floki.find(dom, "#chat-form #chat-llm-selection") == []
    assert Floki.find(dom, "select[name='model_id']") == []

    dom = page(provider_profiles: profiles, model_selections: selections, model_spec: spec)

    assert text(dom, "#chat-llm-selection-provider option[value='']") ==
             "Choose a provider profile"
  end

  test "loading, missing snapshots and invalid selections cannot enable sending" do
    for overrides <- [
          [model_select_loading: true, model_snapshot: nil],
          [model_snapshot: nil],
          [model_selection_error: :invalid_model_spec],
          [model_snapshot: nil, model_select_load_error: :remote_not_connected]
        ] do
      dom = page(overrides)
      assert Floki.find(dom, "#chat-form button[type='submit'][disabled]") != []
      # The draft remains editable while the model load/choice is repaired.
      assert Floki.find(dom, "#chat-form textarea[disabled]") == []
    end

    dom = page(model_snapshot: nil, model_select_load_error: :remote_not_connected)
    assert Floki.find(dom, "#chat-llm-selection[disabled]") != []
    assert text(dom, "[role='alert']") =~ "Model selection is unavailable."
  end

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
