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
      chat_draft: "",
      queued_echoes: [],
      session_list: [],
      session_list_loading: false,
      session_list_error: nil,
      current_session_id: nil
    ]

    render_component(&EvoDashWeb.HomeLive.render/1, Keyword.merge(assigns, overrides))
    |> Floki.parse_document!()
  end

  defp text(dom, selector), do: dom |> Floki.find(selector) |> Floki.text() |> String.trim()
  defp attr(dom, selector, name), do: dom |> Floki.find(selector) |> Floki.attribute(name)

  # Class string of a session-list row's marker dot (the `aria-hidden` span).
  defp dot_class(dom, row_selector) do
    dom
    |> Floki.find("#{row_selector} span[aria-hidden='true']")
    |> Floki.attribute("class")
    |> List.first()
  end

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

  test "a running chat keeps the composer queueable, exposes interrupt and stop, and locks competing actions" do
    dom = page(chat_status: :running)

    # A send during a run is QUEUED for the next turn boundary, so the textarea
    # stays writable instead of being locked by the running status.
    assert Floki.find(dom, "#chat-form textarea[disabled]") == []
    assert Floki.find(dom, "#chat-form textarea[readonly]") == []
    assert attr(dom, "#chat-form textarea", "name") == ["message"]

    # Send stays present and usable for that queued send, but it is not an
    # ACTIVE send: it owns no click binding of its own (it only submits
    # `#chat-form`), and it is not hidden.
    assert length(Floki.find(dom, "#chat-form button[type='submit']")) == 1
    assert attr(dom, "#chat-form button[type='submit']", "phx-click") == []
    assert attr(dom, "#chat-form button[type='submit']", "disabled") == []
    assert Floki.find(dom, "#chat-form button[type='submit'].hidden") == []

    # The send control is still independently UNUSABLE without a usable model
    # snapshot — even while running — and the draft stays editable either way.
    blocked = page(chat_status: :running, model_snapshot: nil)

    assert Floki.find(blocked, "#chat-form button[type='submit'][disabled]") != []
    assert Floki.find(blocked, "#chat-form textarea[disabled]") == []

    # The interrupt affordance is the running-only explicit action.
    assert length(Floki.find(dom, "#chat-interrupt-button")) == 1
    assert attr(dom, "#chat-interrupt-button", "type") == ["button"]
    assert attr(dom, "#chat-interrupt-button", "phx-click") == ["interrupt_turn"]
    assert attr(dom, "#chat-interrupt-button", "disabled") == []
    assert text(dom, "#chat-interrupt-button") == "Send now (interrupt turn)"

    # Stop is a separate, ENABLED control while the turn runs.
    assert text(dom, "#chat-form button[phx-click='stop']") == "Stop"
    assert Floki.find(dom, "#chat-form button[phx-click='stop'][disabled]") == []
    assert Floki.find(dom, "#chat-form button[phx-click='stop'].hidden") == []

    # Competing actions stay locked, and the idle mistakes note stays absent.
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

  test "an awaiting-input session renders an idle-style, writable composer" do
    dom = page(chat_status: :awaiting_input)

    # An idle live session is writable: the draft is accepted and Send is
    # usable once a model snapshot exists.
    assert Floki.find(dom, "#chat-form textarea[disabled]") == []
    assert attr(dom, "#chat-form textarea", "name") == ["message"]

    assert length(Floki.find(dom, "#chat-form button[type='submit']")) == 1
    assert attr(dom, "#chat-form button[type='submit']", "disabled") == []
    assert Floki.find(dom, "#chat-form button[type='submit'].hidden") == []
    assert text(dom, "#chat-form button[type='submit']") == "Send"

    # No turn is in flight: Stop is hidden and the interrupt affordance is gone.
    assert Floki.find(dom, "#chat-form button[phx-click='stop'].hidden") != []
    assert Floki.find(dom, "#chat-interrupt-button") == []
  end

  test "ended and cancelling sessions lock the composer, hide send and disable stop" do
    ended = page(chat_status: :ended)

    assert Floki.find(ended, "#chat-form textarea[disabled]") != []
    assert Floki.find(ended, "#chat-form button[type='submit'].hidden") != []
    assert Floki.find(ended, "#chat-form button[type='submit'][disabled]") != []
    # A finished session can never be stopped again: Stop stays hidden (and
    # disabled) while the only remaining affordance is New chat.
    assert Floki.find(ended, "#chat-form button[phx-click='stop'].hidden") != []
    assert Floki.find(ended, "button[phx-click='new_chat'][disabled]") == []

    cancelling = page(chat_status: :cancelling)

    assert Floki.find(cancelling, "#chat-form textarea[disabled]") != []
    assert Floki.find(cancelling, "#chat-form button[type='submit'].hidden") != []
    assert Floki.find(cancelling, "#chat-form button[type='submit'][disabled]") != []

    # A cancel is already in flight: Stop is the one remaining control, shown
    # but deliberately disabled.
    assert Floki.find(cancelling, "#chat-form button[phx-click='stop'].hidden") == []
    assert Floki.find(cancelling, "#chat-form button[phx-click='stop'][disabled]") != []
    assert text(cancelling, "#chat-form button[phx-click='stop']") == "Stop"
    assert Floki.find(cancelling, "#chat-interrupt-button") == []
  end

  test "queued echoes render in order inside the scroller and never as transcript bubbles" do
    echoes = [%{id: "1", text: "first"}, %{id: "2", text: "second"}]
    dom = page(queued_echoes: echoes)

    # The echo container lives INSIDE the message scroller, after the entries.
    assert Floki.find(dom, "#chat-messages #chat-queued-echoes") != []

    ids =
      dom
      |> Floki.find("#chat-queued-echoes > div")
      |> Enum.map(&Floki.attribute(&1, "id"))

    assert ids == [["chat-queued-echo-1"], ["chat-queued-echo-2"]]

    assert text(dom, "#chat-queued-echo-1") =~ "first"
    assert text(dom, "#chat-queued-echo-2") =~ "second"

    for id <- ["1", "2"] do
      assert text(dom, "#chat-queued-echo-#{id}") =~
               "Queued — sent at the next turn boundary"
    end

    # An echo is NOT a fake transcript bubble: no transcript wrapper exists,
    # and the echo does not carry a bubble's alignment/marker classes.
    assert Floki.find(dom, "#chat-messages [id^='chat-entry-']") == []
    assert Floki.find(dom, "#chat-entry-1") == []

    echo_class =
      dom |> Floki.find("#chat-queued-echo-1") |> Floki.attribute("class") |> List.first()

    refute echo_class =~ "justify-end"
    refute echo_class =~ "chat-entry"
    assert Floki.find(dom, "#chat-queued-echo-1 [phx-click]") == []

    # The empty greeting is still the only thing in the transcript.
    assert text(dom, "#chat-messages h2") == "What would you like Genesis to do?"
  end

  test "an empty queue renders no echo container at all" do
    dom = page(queued_echoes: [])

    assert Floki.find(dom, "#chat-queued-echoes") == []
    assert Floki.find(dom, "#chat-messages [id^='chat-queued-echo-']") == []
  end

  test "the interrupt affordance exists only while a turn runs" do
    for status <- [:idle, :awaiting_input, :ended, :cancelling] do
      assert Floki.find(page(chat_status: status), "#chat-interrupt-button") == []
    end

    running = page(chat_status: :running)
    interrupt = Floki.find(running, "#chat-interrupt-button")

    assert length(interrupt) == 1
    assert Floki.attribute(interrupt, "type") == ["button"]
    assert Floki.attribute(interrupt, "phx-click") == ["interrupt_turn"]
    assert Floki.attribute(interrupt, "disabled") == []
    assert Floki.text(interrupt) |> String.trim() == "Send now (interrupt turn)"
    assert Floki.attribute(interrupt, "title") == ["Send now (interrupt turn)"]
  end

  test "the conversation rail lists awaiting, running and ended sessions in order" do
    rows = [
      %{id: 7, title: "Waiting one", marker: :awaiting_input},
      %{id: 3, title: "Live one", marker: :running},
      %{id: 2, title: "Finished one", marker: :ended}
    ]

    dom = page(session_list: rows, current_session_id: 7, current_node_id: "remote-1")

    assert Floki.find(dom, "#chat-session-list") != []
    assert text(dom, "#chat-session-list h2") == "Conversations"

    ids =
      dom
      |> Floki.find("#chat-session-list a")
      |> Enum.map(&Floki.attribute(&1, "id"))

    assert ids == [["chat-session-7"], ["chat-session-3"], ["chat-session-2"]]

    # Rows navigate with a PATCH to `/help?session=<id>` and carry the viewed
    # node as `&node=<id>` when one is set.
    assert attr(dom, "#chat-session-7", "href") == ["/help?session=7&node=remote-1"]
    assert attr(dom, "#chat-session-3", "href") == ["/help?session=3&node=remote-1"]
    assert attr(dom, "#chat-session-2", "href") == ["/help?session=2&node=remote-1"]
    assert attr(dom, "#chat-session-7", "data-phx-link") == ["patch"]

    # Only the current conversation is marked as the current page.
    assert attr(dom, "#chat-session-7", "aria-current") == ["page"]
    assert attr(dom, "#chat-session-3", "aria-current") == []
    assert attr(dom, "#chat-session-2", "aria-current") == []

    # Marker vocabulary: violet dot + "Waiting for you" for an idle live
    # session, a pulsing warning dot for a running one, and a muted dot with
    # an "Ended" label for a finished conversation.
    assert dot_class(dom, "#chat-session-7") =~ "bg-[oklch(0.68_0.17_290)]"
    assert text(dom, "#chat-session-7") =~ "Waiting for you"

    assert dot_class(dom, "#chat-session-3") =~ "bg-warning animate-pulse"
    assert text(dom, "#chat-session-3") =~ "Running"

    assert dot_class(dom, "#chat-session-2") =~ "bg-base-content/30"
    assert text(dom, "#chat-session-2") =~ "Ended"

    # Without a viewed node the row links carry no `node` param at all.
    dom = page(session_list: rows, current_session_id: 3)
    assert attr(dom, "#chat-session-3", "href") == ["/help?session=3"]
    assert attr(dom, "#chat-session-3", "aria-current") == ["page"]
  end

  test "the conversation rail renders its empty state and its load-error alert" do
    empty = page()

    assert Floki.find(empty, "#chat-session-list") != []
    assert text(empty, "#chat-session-list") =~ "No conversations yet."
    assert Floki.find(empty, "#chat-session-list [role='alert']") == []

    failed = page(session_list_error: :remote_not_connected)

    assert Floki.find(failed, "#chat-session-list [role='alert']") != []
    assert text(failed, "#chat-session-list [role='alert']") =~ "Could not load conversations."
    refute text(failed, "#chat-session-list") =~ "No conversations yet."
  end
end
