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

  test "composer card renders the shared picker and rule-controlled Auto label" do
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

    # Fused-capsule root: the shared client hook owns the active panel view.
    assert attr(dom, "#chat-llm-selection", "phx-hook") == ["CapsulePanel"]
    assert attr(dom, "#chat-llm-selection", "data-capsule-view") == ["model"]

    # ONE panel with two sibling views (model + provider drill-down) — there is
    # no provider `<select>` and no `phx-change` anywhere in the picker.
    assert Floki.find(dom, "#chat-llm-selection .capsule-view[data-view='model']") != []
    assert Floki.find(dom, "#chat-llm-selection .capsule-view[data-view='provider']") != []
    assert Floki.find(dom, "#chat-llm-selection select") == []
    assert Floki.find(dom, "#chat-llm-selection [phx-change]") == []

    # The model view's drill row opens the provider list; the provider view's
    # back row returns to the model list.
    assert attr(dom, "#chat-llm-selection-provider", "data-capsule-drill") == ["provider"]
    assert attr(dom, "#chat-llm-selection-provider-list", "role") == ["listbox"]
    assert Floki.find(dom, "#chat-llm-selection .capsule-back[data-capsule-back]") != []

    assert attr(dom, "#chat-llm-selection-model .capsule-item[aria-selected='true']", "phx-click") ==
             [
               "select_model"
             ]

    assert attr(
             dom,
             "#chat-llm-selection-reasoning .capsule-stop[aria-pressed='true']",
             "phx-click"
           ) == [
             "select_reasoning_effort"
           ]

    # Provider inventory/selection lives in the drill-down provider list: the
    # selected row is the `aria-selected="true"` option carrying its profile id,
    # and the drill row shows that profile's display name.
    assert attr(
             dom,
             "#chat-llm-selection-provider-list [role='option'][aria-selected='true']",
             "phx-value-provider_profile_id"
           ) == ["work-account"]

    assert text(dom, "#chat-llm-selection-provider .capsule-drill-value") == "Work"

    assert attr(
             dom,
             "#chat-llm-selection-model .capsule-item[aria-selected='true']",
             "phx-value-model"
           ) == [
             "reasoned-model"
           ]

    assert attr(
             dom,
             "#chat-llm-selection-reasoning .capsule-stop[aria-pressed='true']",
             "phx-value-reasoning_effort"
           ) ==
             ["1"]

    assert text(
             dom,
             "#chat-llm-selection-provider-list .capsule-item[phx-value-provider_profile_id='']"
           ) ==
             "Auto (by rules)"

    # Placement: the picker lives in the composer card's control bar, inside
    # the ONE `#chat-form` (its items carry their own click bindings, so no
    # nested form or form owner is involved), and is gone from the page header
    # along with its old standalone form.
    assert Floki.find(dom, "#chat-form #chat-composer-controls #chat-llm-selection") != []
    assert Floki.find(dom, "#chat-header #chat-llm-selection") == []
    assert Floki.find(dom, "form#chat-llm-selection-form") == []
    assert Floki.find(dom, "select[name='model_id']") == []

    dom = page(provider_profiles: profiles, model_selections: selections, model_spec: spec)

    assert text(
             dom,
             "#chat-llm-selection-provider-list .capsule-item[phx-value-provider_profile_id='']"
           ) ==
             "Choose a provider profile"

    # A persisted id that no longer exists renders as a disabled, invalid row
    # that is never selected, and the drill row flags it too.
    stale = %{"provider_profile_id" => "removed-account"}

    dom = page(provider_profiles: profiles, model_selections: selections, model_spec: stale)

    assert attr(dom, "#chat-llm-selection-provider", "aria-invalid") == ["true"]

    assert attr(
             dom,
             "#chat-llm-selection-provider-list [role='option'][aria-invalid='true']",
             "phx-value-provider_profile_id"
           ) == ["removed-account"]

    assert Floki.find(
             dom,
             "#chat-llm-selection-provider-list .capsule-item-placeholder[disabled]"
           ) !=
             []

    assert attr(
             dom,
             "#chat-llm-selection-provider-list [role='option'][aria-selected='true']",
             "phx-value-provider_profile_id"
           ) == []

    assert text(dom, "#chat-llm-selection-provider .capsule-drill-value") ==
             "Unavailable profile: removed-account"
  end

  test "composer control bar pairs the picker with the send control inside one form" do
    profiles = [%{"id" => "work-account", "name" => "Work", "provider" => "openai"}]

    selections = [
      %{
        provider_profile_id: "work-account",
        model: "reasoned-model",
        reasoning_efforts: ["low", "high"],
        default_reasoning_effort: "low"
      }
    ]

    spec = %{"provider_profile_id" => "work-account", "model" => "reasoned-model"}
    dom = page(provider_profiles: profiles, model_selections: selections, model_spec: spec)

    # One form owns the whole composer; nothing is nested inside it.
    assert attr(dom, "#chat-form", "phx-submit") == ["send_message"]
    assert attr(dom, "#chat-form", "phx-change") == ["chat_input"]
    assert Floki.find(dom, "#chat-form #chat-form") == []
    assert Floki.find(dom, "#chat-form form") == []

    # Capsule on the left, send/stop on the right, both in the control bar row
    # that sits BELOW the textarea.
    assert Floki.find(dom, "#chat-composer-controls #chat-llm-selection") != []
    assert Floki.find(dom, "#chat-composer-controls button[type='submit']") != []
    assert Floki.find(dom, "#chat-composer-controls button[phx-click='stop']") != []

    assert Floki.find(dom, "#chat-form > textarea") != []
    assert Floki.find(dom, "#chat-form > textarea + #chat-composer-controls") != []

    # Provider rows carry their OWN click bindings, which LiveView dispatches
    # to `select_provider_profile` with the row's profile id; the textarea has
    # no own binding, so typing still hits the enclosing form's `chat_input`.
    assert attr(
             dom,
             "#chat-form #chat-llm-selection-provider-list [phx-click='select_provider_profile']",
             "phx-value-provider_profile_id"
           ) == ["", "work-account"]

    assert attr(dom, "#chat-form textarea", "phx-change") == []
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
    assert Floki.find(dom, "#chat-llm-selection.pointer-events-none.opacity-60") != []
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
